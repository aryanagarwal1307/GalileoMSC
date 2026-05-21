################################################################################
# Minimal collision-capsule MSC model
################################################################################

Base.@kwdef struct MSCParams
    birth_base::Float64 = 0.005                 # starting prob for capsule birth
    birth_max::Float64 = 0.65                   # maximum prob to add to base if objects will collide
    birth_distance_scale::Float64 = 0.55        # controls how capsule prob scaled with object distance
    approach_speed_scale::Float64 = 0.25        # controls how capsule prob scales if objects are approaching each other
    cooldown_steps::Int = 2                     # "death" cooldown
    cooldown_birth_scale::Float64 = 0.2         # scales (reduces) prob of rebirth after death
    survival_base::Float64 = 0.2                # baseline prob a capsule survives
    survival_near_boost::Float64 = 0.75         # boost survival prob is objects are close by
    survival_distance_scale::Float64 = 0.45     # scale for near collision
    min_active_steps::Int = 3                   # minimum steps for capsule to be active
    min_age_survival::Float64 = 0.95            # min survival prob early on
    age_decay_steps::Float64 = 8.0              # gradual decay of survival
end

"""
A single collision capsule for the two-object ramp scene.

When `active == false`, `age` counts steps since the capsule was last active.
When `active == true`, `age` counts how long the capsule has persisted.
"""
struct CollisionMSC
    a::Int
    b::Int
    active::Bool
    age::Int
end

struct MSCEventStats
    birth_prob::Float64
    survival_prob::Float64
    switch_prob::Float64
end

struct MSCState
    objects::BulletState
    capsule::CollisionMSC
    event_stats::MSCEventStats
end

const msc_positions = Gen.Map(observe)
const DEFAULT_MSC_PARAMS = MSCParams()

function default_msc_capsule(params::MSCParams=DEFAULT_MSC_PARAMS)
    return CollisionMSC(1, 2, false, params.cooldown_steps)
end

function default_msc_event_stats()
    return MSCEventStats(0.0, 0.0, 0.0)
end

function initial_msc_state(objects::BulletState, params::MSCParams=DEFAULT_MSC_PARAMS)
    return MSCState(objects, default_msc_capsule(params), default_msc_event_stats())
end

function _clamp_probability(p::Real)
    return clamp(Float64(p), 1e-4, 1.0 - 1e-4)
end

function _collision_features(objects::BulletState, a::Int, b::Int, params::MSCParams)
    ka = objects.kinematics[a]
    kb = objects.kinematics[b]
    offset = kb.position .- ka.position
    distance = norm(offset)
    direction = distance > 1e-8 ? offset ./ distance : zero(offset)
    relative_velocity = ka.linear_vel .- kb.linear_vel
    closing_speed = dot(relative_velocity, direction)

    close_score = exp(-((distance / params.birth_distance_scale)^2))
    near_score = exp(-((distance / params.survival_distance_scale)^2))
    approach_score = 1.0 / (1.0 + exp(-closing_speed / params.approach_speed_scale))

    return (
        distance = distance,
        closing_speed = closing_speed,
        close_score = close_score,
        near_score = near_score,
        approach_score = approach_score
    )
end

function collision_birth_probability(prev::MSCState, params::MSCParams)
    cap = prev.capsule
    features = _collision_features(prev.objects, cap.a, cap.b, params)
    cooldown_scale = cap.age < params.cooldown_steps ? params.cooldown_birth_scale : 1.0
    approach_weight = 0.35 + 0.65 * features.approach_score
    p = params.birth_base + params.birth_max * features.close_score * approach_weight
    return _clamp_probability(cooldown_scale * p)
end

function collision_survival_probability(prev::MSCState, params::MSCParams)
    cap = prev.capsule
    features = _collision_features(prev.objects, cap.a, cap.b, params)
    age_excess = max(cap.age - params.min_active_steps, 0)
    age_penalty = exp(-age_excess / params.age_decay_steps)
    p = (params.survival_base + params.survival_near_boost * features.near_score) * age_penalty

    if cap.age < params.min_active_steps
        p = max(p, params.min_age_survival)
    end

    return _clamp_probability(p)
end

@gen function collision_capsule_step(prev::MSCState, params::MSCParams)
    cap = prev.capsule

    if cap.active
        survival_prob = collision_survival_probability(prev, params)
        survived ~ bernoulli(survival_prob)
        active = Bool(survived)
        next_age = active ? cap.age + 1 : 0
        next_capsule = CollisionMSC(cap.a, cap.b, active, next_age)
        stats = MSCEventStats(0.0, survival_prob, 1.0 - survival_prob)
    else
        birth_prob = collision_birth_probability(prev, params)
        born ~ bernoulli(birth_prob)
        active = Bool(born)
        next_age = active ? 1 : cap.age + 1
        next_capsule = CollisionMSC(cap.a, cap.b, active, next_age)
        stats = MSCEventStats(birth_prob, 0.0, birth_prob)
    end

    return (capsule = next_capsule, stats = stats)
end

@gen function msc_physics_step(t::Int, prev::MSCState, sim::BulletSim, params::MSCParams)
    capsule_update ~ collision_capsule_step(prev, params)
    next_objects = PhySMC.step(sim, prev.objects)
    positions ~ msc_positions(next_objects.kinematics)

    return MSCState(next_objects, capsule_update.capsule, capsule_update.stats)
end

const msc_chain = Gen.Unfold(msc_physics_step)

@gen function msc_model(T::Int, sim::BulletSim, template::BulletState, params::MSCParams)
    latents ~ prior(template.latents)
    init_objects = Accessors.setproperties(template; latents=latents)
    init_state = initial_msc_state(init_objects, params)
    states ~ msc_chain(T, init_state, sim, params)
    return states
end

################################################################################
# Rejuvenation proposal for MSC v0
################################################################################

@gen function msc_proposal(tr::Gen.Trace)
    choices = get_choices(tr)
    prev_log_mass = choices[:latents => :obj1 => :log_mass]
    log_mass = {:latents => :obj1 => :log_mass} ~ normal(prev_log_mass, 1.0)
    return log_mass
end

################################################################################
# Sequential inference with stored history
################################################################################

function msc_inference_procedure(gm_args::Tuple,
                                 obs::Vector{Gen.ChoiceMap},
                                 particles::Int=20,
                                 rejuv_moves::Int=1)

    get_args(t) = (t, gm_args[2:4]...)
    state = Gen.initialize_particle_filter(msc_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, ())
        end
    end

    return Gen.sample_unweighted_traces(state, particles)
end

function extract_msc_capsule(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].capsule
end

function extract_msc_event_stats(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].event_stats
end

function summarize_msc_capsules(traces, t::Int)
    capsules = [extract_msc_capsule(tr, t) for tr in traces]
    event_stats = [extract_msc_event_stats(tr, t) for tr in traces]
    prev_active = t == 1 ? falses(length(traces)) : [extract_msc_capsule(tr, t - 1).active for tr in traces]
    active = [cap.active for cap in capsules]

    birth_events = [!prev_active[i] && active[i] for i in eachindex(active)]
    death_events = [prev_active[i] && !active[i] for i in eachindex(active)]
    switch_events = [prev_active[i] != active[i] for i in eachindex(active)]

    return (
        capsule_active_prob = mean(Float64.(active)),
        capsule_switch_prob = mean(Float64.(switch_events)),
        capsule_birth_prob = mean(Float64.(birth_events)),
        capsule_death_prob = mean(Float64.(death_events)),
        capsule_mean_age = mean(Float64[cap.age for cap in capsules]),
        capsule_mean_birth_probability = mean(Float64[stats.birth_prob for stats in event_stats]),
        capsule_mean_survival_probability = mean(Float64[stats.survival_prob for stats in event_stats]),
        capsule_mean_switch_probability = mean(Float64[stats.switch_prob for stats in event_stats])
    )
end

function msc_inference_with_history(gm_args::Tuple,
                                    obs::Vector{Gen.ChoiceMap},
                                    particles::Int=20,
                                    rejuv_moves::Int=1)

    get_args(t) = (t, gm_args[2:4]...)
    state = Gen.initialize_particle_filter(msc_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, ())
        end

        current_traces = Gen.sample_unweighted_traces(state, particles)
        mass_summary = summarize_trace_set(current_traces)
        capsule_summary = summarize_msc_capsules(current_traces, t)

        history[t] = (
            t = t,
            mean = mass_summary.mean,
            std = mass_summary.std,
            q05 = mass_summary.q05,
            q25 = mass_summary.q25,
            q75 = mass_summary.q75,
            q95 = mass_summary.q95,
            capsule_active_prob = capsule_summary.capsule_active_prob,
            capsule_switch_prob = capsule_summary.capsule_switch_prob,
            capsule_birth_prob = capsule_summary.capsule_birth_prob,
            capsule_death_prob = capsule_summary.capsule_death_prob,
            capsule_mean_age = capsule_summary.capsule_mean_age,
            capsule_mean_birth_probability = capsule_summary.capsule_mean_birth_probability,
            capsule_mean_survival_probability = capsule_summary.capsule_mean_survival_probability,
            capsule_mean_switch_probability = capsule_summary.capsule_mean_switch_probability,
            traces = current_traces
        )
    end

    return history
end

################################################################################
# Synthetic smoke test and timing spec
################################################################################

function run_msc_smoke_test(T::Int, sim, template, params::MSCParams=DEFAULT_MSC_PARAMS;
                            particles=30,
                            rejuv_moves=2,
                            ground_truth_mass=nothing)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    true_trace, = Gen.generate(msc_model, (T, sim, template, params), mass_constraint(true_mass))
    observed_positions = observations_from_trace(true_trace)
    obs = make_observations(observed_positions)

    history = msc_inference_with_history((T, sim, template, params), obs, particles, rejuv_moves)
    collision_time = detect_collision_time(observed_positions)

    return (
        true_trace = true_trace,
        ground_truth_mass = true_mass,
        observed_positions = observed_positions,
        obs = obs,
        history = history,
        collision_time = collision_time
    )
end

function msc_timing_spec(; label="MSC v0", params::MSCParams=DEFAULT_MSC_PARAMS)
    return make_pf_timing_spec(
        label = label,
        pf_model = msc_model,
        gm_args_builder = (T, sim, template) -> (T, sim, template, params),
        online_args = gm_args -> (t -> (t, gm_args[2:4]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, ())
            end
            return nothing
        end
    )
end
