################################################################################
# Static mass particle-filter model
################################################################################

@gen (static) function particle_filter_physics_step(t::Int, prev::BulletState, sim::BulletSim)
    # run a deterministic forward function via PhySMC
    next_state = PhySMC.step(sim, prev)

    # get the true positions + some gaussian noise
    positions ~ Gen.Map(observe)(next_state.kinematics)

    return next_state
end

const sm_chain = Gen.Unfold(particle_filter_physics_step)

@gen (static) function particle_filter_model(T::Int, sim::BulletSim, template::BulletState)
    # Sample physical latents once, then keep them fixed through the rollout.
    latents ~ prior(template.latents)
    init_state = Accessors.setproperties(template; latents=latents)

    # simulate `T` timesteps; kind of like a for-loop
    states ~ sm_chain(T, init_state, sim)
    return states
end

const model = particle_filter_model

################################################################################
# Rejuvenation proposal for static mass model
################################################################################

"""
This proposal function implements random walks for the initial mass and object frictions.

The proposals are truncated so sampled physical parameters stay valid.
"""
@gen function particle_filter_proposal(tr::Gen.Trace)
    choices = get_choices(tr)
    template = get_args(tr)[3]
    object_id = tracked_mass_object(template)

    prev_mass = choices[:latents => :obj => object_id => :mass]
    mass = {:latents => :obj => object_id => :mass} ~ trunc_norm(prev_mass, 1.0, 0.0, Inf)

    for friction_object_id in dynamic_object_indices(template)
        prev_friction = choices[:latents => :obj => friction_object_id => :lateralFriction]
        lateralFriction = {:latents => :obj => friction_object_id => :lateralFriction} ~
            trunc_norm(prev_friction, FRICTION_PROPOSAL_STD, FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH)
    end

    return mass
end

const proposal = particle_filter_proposal

"""
    inference_procedure

Performs particle filter inference with MH rejuvenation.
`gm_args` should be `(T, sim, template)`.
`obs` should be a vector of ChoiceMaps, one per time step.
"""
function inference_procedure(gm_args::Tuple,
                             obs::Vector{Gen.ChoiceMap},
                             particles::Int=20,
                             rejuv_moves::Int=1)

    # model arguments are (T, sim, template), and only T changes online
    get_args(t) = (t, gm_args[2:3]...)

    # initialize particle filter at t = 0
    state = Gen.initialize_particle_filter(particle_filter_model, get_args(0), EmptyChoiceMap(), particles)

    # only the first argument (T) changes from step to step
    argdiffs = (UnknownChange(), NoChange(), NoChange())

    # increment through each observation step
    for (t, o) in enumerate(obs)
        # STEP 1: update with next observation
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)

        # STEP 2: resample if ESS gets too low
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        # STEP 3: rejuvenation moves
        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], particle_filter_proposal, ())
        end
    end

    # return an unweighted sample of posterior traces
    return Gen.sample_unweighted_traces(state, particles)
end

################################################################################
# Posterior summaries over time
################################################################################

function extract_particle_filter_masses(traces)
    [get_choices(tr)[:latents => :obj => tracked_mass_object(get_args(tr)[3]) => :mass] for tr in traces]
end

function summarize_masses(traces)
    ms = extract_particle_filter_masses(traces)
    return (
        mean = mean(ms),
        std = std(ms),
        min = minimum(ms),
        max = maximum(ms),
        masses = ms
    )
end

function summarize_trace_set(traces)
    ms = extract_particle_filter_masses(traces)
    return (
        mean = mean(ms),
        std = std(ms),
        q25 = quantile(ms, 0.25),
        q75 = quantile(ms, 0.75),
        q05 = quantile(ms, 0.05),
        q95 = quantile(ms, 0.95),
        masses = ms
    )
end

function extract_particle_filter_frictions(traces; object_indices=nothing)
    isempty(traces) && return Dict{Int,Vector{Float64}}()
    template = get_args(traces[1])[3]
    indices = object_indices === nothing ? dynamic_object_indices(template) : object_indices

    return Dict(
        object_id => [
            get_choices(tr)[:latents => :obj => object_id => :lateralFriction]
            for tr in traces
        ]
        for object_id in indices
    )
end

function summarize_particle_filter_frictions(traces; object_indices=nothing)
    fs = extract_particle_filter_frictions(traces; object_indices=object_indices)
    return Dict(
        object_id => (
            mean = mean(values),
            std = std(values),
            q05 = quantile(values, 0.05),
            q25 = quantile(values, 0.25),
            q75 = quantile(values, 0.75),
            q95 = quantile(values, 0.95),
            frictions = values
        )
        for (object_id, values) in fs
    )
end

################################################################################
# Sequential inference with stored history
################################################################################

function inference_with_history(gm_args::Tuple,
                                obs::Vector{Gen.ChoiceMap},
                                particles::Int=20,
                                rejuv_moves::Int=1)

    get_args(t) = (t, gm_args[2:3]...)

    state = Gen.initialize_particle_filter(particle_filter_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], particle_filter_proposal, ())
        end

        current_traces = Gen.sample_unweighted_traces(state, particles)
        summ = summarize_trace_set(current_traces)

        history[t] = (
            t = t,
            mean = summ.mean,
            std = summ.std,
            q25 = summ.q25,
            q75 = summ.q75,
            q05 = summ.q05,
            q95 = summ.q95,
            frictions = summarize_particle_filter_frictions(current_traces),
            traces = current_traces
        )
    end

    return history
end

################################################################################
# Synthetic smoke tests
################################################################################

function run_smoke_test(T::Int, sim, template; particles=20, rejuv_moves=1, ground_truth_mass=nothing)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    constraints = mass_constraint(true_mass, template)
    set_friction_constraints!(constraints, template_lateral_frictions(template);
                              object_indices=dynamic_object_indices(template))
    tr, = Gen.generate(particle_filter_model, (T, sim, template), constraints)
    observed_positions = observations_from_trace(tr)
    obs = make_observations(observed_positions)

    traces = inference_procedure((T, sim, template), obs, particles, rejuv_moves)

    return (
        true_trace = tr,
        ground_truth_mass = true_mass,
        observed_positions = observed_positions,
        obs = obs,
        posterior_traces = traces,
        summary = summarize_masses(traces)
    )
end

function run_history_smoke_test(T::Int, sim, template; particles=30, rejuv_moves=2, ground_truth_mass=nothing)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    constraints = mass_constraint(true_mass, template)
    set_friction_constraints!(constraints, template_lateral_frictions(template);
                              object_indices=dynamic_object_indices(template))
    true_trace, = Gen.generate(particle_filter_model, (T, sim, template), constraints)
    observed_positions = observations_from_trace(true_trace)
    obs = make_observations(observed_positions)

    history = inference_with_history((T, sim, template), obs, particles, rejuv_moves)
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

"""
Convenience constructor for the static particle-filter model.
"""
function particle_filter_timing_spec(; label="particle filter", proposal_fn=particle_filter_proposal)
    return make_pf_timing_spec(
        label = label,
        pf_model = particle_filter_model,
        gm_args_builder = (T, sim, template) -> (T, sim, template),
        online_args = gm_args -> (t -> (t, gm_args[2:3]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                state.traces[i], _ = Gen.mh(state.traces[i], proposal_fn, ())
            end
            return nothing
        end
    )
end
