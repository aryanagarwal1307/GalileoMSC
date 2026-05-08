################################################################################
# Drift model
################################################################################

"""
Drift the unknown object's mass around its previous value.
"""
@gen function drift_object(ls::RigidBodyLatents, drift_std::Float64)
    prev_mass = ls.data.mass
    mass ~ trunc_norm(prev_mass, drift_std, 0.0, Inf) #TODO give an upper bound
    return update_latents(ls, mass)
end

"""
Apply latent drift before the next physics step.
Only obj1 drifts; obj2 is kept fixed at mass=1.
"""
@gen function drift_step(prev::BulletState, drift_std::Float64)
    obj1 ~ drift_object(prev.latents[1], drift_std)
    obj2 = update_latents(prev.latents[2], 1.0)
    new_latents = BulletElemLatents[obj1, obj2]
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
:states => t => :drift => :obj1 => :mass
"""
@gen function drift_proposal(tr::Gen.Trace, t::Int)
    choices = get_choices(tr)
    prev_mass = choices[:states => t => :drift => :obj1 => :mass]
    mass = {:states => t => :drift => :obj1 => :mass} ~ trunc_norm(prev_mass, 0.25, 0.0, Inf) # TODO upper bound (same as above)
    return mass
end

function drift_inference_procedure(gm_args::Tuple,
                                   obs::Vector{Gen.ChoiceMap},
                                   particles::Int=20,
                                   rejuv_moves::Int=1)

    # gm_args = (T, sim, template, drift_std)
    get_args(t) = (t, gm_args[2:4]...)

    state = Gen.initialize_particle_filter(drift_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            # state.traces[i], _ = Gen.mh(state.traces[i], drift_proposal, (t,)) # use selection instead of a proposal function;
            state.traces[i], _ = Gen.mh(state.traces[i], Gen.select(:states => t => :drift => :obj1 => :mass)) # use selection instead of a proposal function;
        end
    end

    return Gen.sample_unweighted_traces(state, particles)
end

################################################################################
# Posterior summaries over time
################################################################################

function extract_current_drift_mass(tr::Gen.Trace, t::Int)
    get_choices(tr)[:states => t => :drift => :obj1 => :mass]
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
                                      rejuv_moves::Int=1)

    get_args(t) = (t, gm_args[2:4]...)

    state = Gen.initialize_particle_filter(drift_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], drift_proposal, (t,))
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

function run_drift_smoke_test(T::Int, sim, template, drift_std::Float64; particles=30, rejuv_moves=2)
    true_trace, = Gen.generate(drift_model, (T, sim, template, drift_std))
    observed_positions = observations_from_trace(true_trace)
    obs = make_observations(observed_positions)

    history = drift_inference_with_history((T, sim, template, drift_std), obs, particles, rejuv_moves)
    collision_time = detect_collision_time(observed_positions)

    return (
        true_trace = true_trace,
        observed_positions = observed_positions,
        obs = obs,
        history = history,
        collision_time = collision_time
    )
end

function drift_timing_spec(; label="drift model", drift_std::Float64=0.25)
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
                    Gen.select(:states => t => :drift => :obj1 => :mass)
                )
            end
            return nothing
        end
    )
end
