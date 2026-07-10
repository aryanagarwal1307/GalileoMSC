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
    latents ~ prior(template.latents, tracked_mass_object(template))
    init_state = Accessors.setproperties(template; latents=latents)

    # simulate `T` timesteps; kind of like a for-loop
    states ~ sm_chain(T, init_state, sim)
    return states
end

@gen (static) function particle_filter_mass_model(T::Int, sim::BulletSim, template::BulletState)
    object_id = tracked_mass_object(template)
    latents ~ mass_prior(template.latents, object_id)
    init_state = Accessors.setproperties(template; latents=latents)
    states ~ sm_chain(T, init_state, sim)
    return states
end

const model = particle_filter_model

################################################################################
# Rejuvenation proposal for static mass model
################################################################################

@gen function particle_filter_mass_proposal(tr::Gen.Trace)
    choices = get_choices(tr)
    object_id = tracked_mass_object(get_args(tr)[3])
    previous = choices[:latents => :obj => object_id => :mass]
    mass = {:latents => :obj => object_id => :mass} ~
        trunc_norm(previous, 1.0, 0.0, Inf)
    return mass
end

@gen function particle_filter_proposal(tr::Gen.Trace)
    choices = get_choices(tr)
    template = get_args(tr)[3]
    object_id = tracked_mass_object(template)
    previous = choices[:latents => :obj => object_id => :mass]
    mass = {:latents => :obj => object_id => :mass} ~
        trunc_norm(previous, 1.0, 0.0, Inf)

    for friction_object_id in dynamic_object_indices(template)
        previous = choices[:latents => :obj => friction_object_id => :lateralFriction]
        lateralFriction = {:latents => :obj => friction_object_id => :lateralFriction} ~
            trunc_norm(previous, FRICTION_PROPOSAL_STD,
                       FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH)
    end

    return mass
end

const proposal = particle_filter_proposal

particle_filter_for(infer_friction::Bool) =
    infer_friction ? particle_filter_model : particle_filter_mass_model

function particle_filter_move(tr::Gen.Trace; infer_friction::Bool=true)
    if infer_friction
        return Gen.mh(tr, particle_filter_proposal, ())
    else
        return Gen.mh(tr, particle_filter_mass_proposal, ())
    end
end

"""
    inference_procedure

Performs particle filter inference with MH rejuvenation.
`gm_args` should be `(T, sim, template)`.
`obs` should be a vector of ChoiceMaps, one per time step.
"""
function inference_procedure(gm_args::Tuple,
                             obs::Vector{Gen.ChoiceMap},
                             particles::Int=20,
                             rejuv_moves::Int=1;
                             infer_friction::Bool=true)

    # model arguments are (T, sim, template), and only T changes online
    get_args(t) = (t, gm_args[2:3]...)

    # initialize particle filter at t = 0
    pf_model = particle_filter_for(infer_friction)
    state = Gen.initialize_particle_filter(pf_model, get_args(0), EmptyChoiceMap(), particles)

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
            state.traces[i], _ = particle_filter_move(state.traces[i]; infer_friction=infer_friction)
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

function summarize_particle_filter_frictions(traces)
    isempty(traces) && return Dict{Int,NamedTuple}()
    template = get_args(traces[1])[3]
    indices = dynamic_object_indices(template)
    return summarize_frictions(traces, indices) do tr, object_id
        get_choices(tr)[:latents => :obj => object_id => :lateralFriction]
    end
end

################################################################################
# Sequential inference with stored history
################################################################################

function inference_with_history(gm_args::Tuple,
                                obs::Vector{Gen.ChoiceMap},
                                particles::Int=20,
                                rejuv_moves::Int=1;
                                infer_friction::Bool=true)

    get_args(t) = (t, gm_args[2:3]...)

    pf_model = particle_filter_for(infer_friction)
    state = Gen.initialize_particle_filter(pf_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = particle_filter_move(state.traces[i]; infer_friction=infer_friction)
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
            frictions = infer_friction ? summarize_particle_filter_frictions(current_traces) : Dict{Int,NamedTuple}(),
            traces = current_traces
        )
    end

    return history
end

################################################################################
# Synthetic smoke tests
################################################################################

function run_smoke_test(T::Int, sim, template;
                        particles=20,
                        rejuv_moves=1,
                        ground_truth_mass=nothing,
                        ground_truth_frictions=nothing,
                        infer_friction::Bool=true)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    true_frictions = ground_truth_frictions === nothing ? template_lateral_frictions(template) : ground_truth_frictions
    constraints = add_physical_constraints!(Gen.choicemap(), template;
                                            ground_truth_mass=true_mass,
                                            ground_truth_frictions=true_frictions,
                                            infer_friction=infer_friction)
    pf_model = particle_filter_for(infer_friction)
    tr, = Gen.generate(pf_model, (T, sim, template), constraints)
    observed_positions = observations_from_trace(tr)
    obs = make_observations(observed_positions)

    traces = inference_procedure((T, sim, template), obs, particles, rejuv_moves;
                                 infer_friction=infer_friction)

    return (
        true_trace = tr,
        ground_truth_mass = true_mass,
        observed_positions = observed_positions,
        obs = obs,
        posterior_traces = traces,
        summary = summarize_masses(traces)
    )
end

function run_history_smoke_test(T::Int, sim, template;
                                particles=30,
                                rejuv_moves=2,
                                ground_truth_mass=nothing,
                                ground_truth_frictions=nothing,
                                infer_friction::Bool=true)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    true_frictions = ground_truth_frictions === nothing ? template_lateral_frictions(template) : ground_truth_frictions
    constraints = add_physical_constraints!(Gen.choicemap(), template;
                                            ground_truth_mass=true_mass,
                                            ground_truth_frictions=true_frictions,
                                            infer_friction=infer_friction)
    pf_model = particle_filter_for(infer_friction)
    true_trace, = Gen.generate(pf_model, (T, sim, template), constraints)
    observed_positions = observations_from_trace(true_trace)
    obs = make_observations(observed_positions)

    history = inference_with_history((T, sim, template), obs, particles, rejuv_moves;
                                     infer_friction=infer_friction)
    collision_time = detect_collision_time(true_trace)

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
function particle_filter_timing_spec(; label="particle filter",
                                     proposal_fn=nothing,
                                     infer_friction::Bool=true)
    return make_pf_timing_spec(
        label = label,
        pf_model = particle_filter_for(infer_friction),
        gm_args_builder = (T, sim, template) -> (T, sim, template),
        online_args = gm_args -> (t -> (t, gm_args[2:3]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                state.traces[i], _ = if proposal_fn === nothing
                    particle_filter_move(state.traces[i];
                                         infer_friction=infer_friction)
                else
                    Gen.mh(state.traces[i], proposal_fn, ())
                end
            end
            return nothing
        end
    )
end
