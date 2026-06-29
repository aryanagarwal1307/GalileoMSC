################################################################################
# Drift model
################################################################################

"""
Drift the unknown object's mass around its previous value.
"""
@gen function drift_object(ls::RigidBodyLatents, drift_std::Float64)
    prev_mass = ls.data.mass
    mass ~ trunc_norm(prev_mass, drift_std, 0.0, Inf)
    return update_latents(ls, mass)
end

"""
Apply latent drift before the next physics step.
Only the tracked dynamic object's mass drifts; all other latents persist.
"""
@gen function drift_step(prev::BulletState, drift_std::Float64)
    object_id = tracked_mass_object(prev)
    new_latents = Vector{BulletElemLatents}(undef, length(prev.latents))
    copyto!(new_latents, prev.latents)
    new_latents[object_id] = {:obj => object_id} ~ drift_object(prev.latents[object_id], drift_std)
    new_state = Accessors.setproperties(prev; latents=new_latents)
    return new_state
end

const drift_positions = Gen.Map(observe)

"""
Drift latents, then run deterministic physics, then get noisy observations.
"""
@gen (static) function drift_physics_step(t::Int, prev::BulletState, sim::BulletSim, drift_std::Float64)
    drift ~ drift_step(prev, drift_std)
    next_state::BulletState = PhySMC.step(sim, drift)
    positions ~ drift_positions(next_state.kinematics)
    return next_state
end

const drift_chain = Gen.Unfold(drift_physics_step)

@gen (static) function drift_model(T::Int, sim::BulletSim, template::BulletState, drift_std::Float64)
    latents ~ prior(template.latents)
    init_state = Accessors.setproperties(template; latents=latents)
    states ~ drift_chain(T, init_state, sim, drift_std)
    return states
end

################################################################################
# Rejuvenation proposal for drift model
################################################################################

"""
MH proposal for the drifted mass at a specific time t.
Address path is:
:states => t => :drift => :obj => object_id => :mass
"""
@gen function drift_proposal(tr::Gen.Trace, t::Int, proposal_drift_std::Float64)
    choices = get_choices(tr)
    object_id = tracked_mass_object(get_args(tr)[3])
    prev_mass = choices[:states => t => :drift => :obj => object_id => :mass]
    mass = {:states => t => :drift => :obj => object_id => :mass} ~ trunc_norm(prev_mass, proposal_drift_std, 0.0, Inf)
    return mass
end

function drift_inference_procedure(gm_args::Tuple,
                                   obs::Vector{Gen.ChoiceMap},
                                   particles::Int=20,
                                   rejuv_moves::Int=1;
                                   proposal_drift_std::Float64=0.25)

    # gm_args = (T, sim, template, drift_std)
    get_args(t) = (t, gm_args[2:4]...)

    state = Gen.initialize_particle_filter(drift_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], drift_proposal, (t, proposal_drift_std))
        end
    end

    return Gen.sample_unweighted_traces(state, particles)
end

################################################################################
# Posterior summaries over time
################################################################################

function extract_current_drift_mass(tr::Gen.Trace, t::Int)
    state = get_retval(tr)[t]
    return object_mass(state.latents[tracked_mass_object(state)])
end

function summarize_drift_masses(traces, t::Int)
    ms = [extract_current_drift_mass(tr, t) for tr in traces]
    return (
        mean = mean(ms),
        std = std(ms),
        q05 = quantile(ms, 0.05),
        q25 = quantile(ms, 0.25),
        q75 = quantile(ms, 0.75),
        q95 = quantile(ms, 0.95),
        masses = ms
    )
end

function drift_inference_with_history(gm_args::Tuple,
                                      obs::Vector{Gen.ChoiceMap},
                                      particles::Int=20,
                                      rejuv_moves::Int=1;
                                      proposal_drift_std::Float64=0.25)

    get_args(t) = (t, gm_args[2:4]...)

    state = Gen.initialize_particle_filter(drift_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], drift_proposal, (t, proposal_drift_std))
        end

        current_traces = Gen.sample_unweighted_traces(state, particles)
        summ = summarize_drift_masses(current_traces, t)

        history[t] = (
            t = t,
            mean = summ.mean,
            std = summ.std,
            q05 = summ.q05,
            q25 = summ.q25,
            q75 = summ.q75,
            q95 = summ.q95,
            traces = current_traces
        )
    end

    return history
end

################################################################################
# Synthetic smoke test for drift model
################################################################################

function run_drift_smoke_test(T::Int, sim, template, drift_std::Float64;
                              particles=30,
                              rejuv_moves=2,
                              ground_truth_mass=nothing,
                              proposal_drift_std::Float64=0.25)
    true_mass = ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
    true_trace, = Gen.generate(drift_model, (T, sim, template, drift_std), mass_constraint(true_mass, template))
    observed_positions = observations_from_trace(true_trace)
    obs = make_observations(observed_positions)

    history = drift_inference_with_history((T, sim, template, drift_std), obs, particles, rejuv_moves;
                                           proposal_drift_std=proposal_drift_std)
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

function drift_timing_spec(; label="drift model",
                           drift_std::Float64=1.5,
                           proposal_drift_std::Float64=0.25)
    return make_pf_timing_spec(
        label = label,
        pf_model = drift_model,
        gm_args_builder = (T, sim, template) -> (T, sim, template, drift_std),
        online_args = gm_args -> (t -> (t, gm_args[2:4]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                state.traces[i], _ = Gen.mh(
                    state.traces[i],
                    drift_proposal,
                    (t, proposal_drift_std)
                )
            end
            return nothing
        end
    )
end
