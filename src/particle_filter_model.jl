################################################################################
# Static mass particle-filter model
################################################################################

@gen function particle_filter_physics_step(t::Int, prev::BulletState, sim::BulletSim)
    # run a deterministic forward function via PhySMC
    next_state = PhySMC.step(sim, prev)

    # get the true positions + some gaussian noise
    positions ~ Gen.Map(observe)(next_state.kinematics)

    return next_state
end

@gen function particle_filter_model(T::Int, sim::BulletSim, template::BulletState)
    # distribution over mass and restitution for objects from the prior
    latents ~ prior(template.latents)
    init_state = Accessors.setproperties(template; latents=latents)

    # simulate `T` timesteps; kind of like a cool for-loop
    states ~ Gen.Unfold(particle_filter_physics_step)(T, init_state, sim)
    return states
end

const model = particle_filter_model

################################################################################
# Rejuvenation proposal for static mass model
################################################################################

"""
This proposal function implements a random walk for the ramp object's mass.

The proposal is truncated so the sampled mass stays physically valid.
"""
@gen function particle_filter_proposal(tr::Gen.Trace)
    choices = get_choices(tr)

    # Only obj1 mass is random in the prior.
    prev_mass = choices[:latents => :obj1 => :mass]

    mass = {:latents => :obj1 => :mass} ~ trunc_norm(prev_mass, 1.0, 0.0, Inf)

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
    [get_choices(tr)[:latents => :obj1 => :mass] for tr in traces]
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
    tr, = Gen.generate(particle_filter_model, (T, sim, template), mass_constraint(true_mass))
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
    true_trace, = Gen.generate(particle_filter_model, (T, sim, template), mass_constraint(true_mass))
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
