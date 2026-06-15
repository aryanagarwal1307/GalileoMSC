################################################################################
# MSC model
################################################################################

#### GENERATIVE FUNCTIONS ####

# A generative function to track all persisting capsules
@gen function capsule_persistence(prev::MSCState, params::MSCParams)
    # Track all capsules that survive
    persisted = Vector{MSC}(undef, length(prev.capsules))
    n_persisted = 0

    # Track the number of capsules that died
    n_died = 0

    # Loop over all capsules in the previous state
    for i in eachindex(prev.capsules)
        @inbounds cap = prev.capsules[i]
        if cap isa CollisionMSC
            # Calculate survival probability
            p_survive = collision_survival_probability(prev, cap, params)

            # Sample whether this capsule survives with bernoulli
            survived = {:survived => i} ~ bernoulli(p_survive)

            # If it survived, increment age. Else, kill.
            if Bool(survived)
                n_persisted += 1
                @inbounds persisted[n_persisted] = increment_age(cap)
            else
                n_died += 1
            end
        else
            # Placeholder until others are made
            error("Unknown capsule type: $(typeof(cap))")
        end
    end

    resize!(persisted, n_persisted)

    return (
        capsules = persisted,
        n_died = n_died
    )
end

# A generative function to sample new capsules (at most one)
@gen function sample_new_capsule(t::Int, prev::MSCState, persisted_capsules::Vector{MSC}, params::MSCParams)

    # Build sparse normalized weights over no_birth and inactive collision pairs.
    weights = all_collision_birth_weights(prev, persisted_capsules, params)

    # Case: no possible new capsule.
    if weights.n_choices - 1 == 0
        return (
            born = false,
            capsule = nothing,
            birth_prob = 0.0
        )
    end

    choice ~ unsafe_fast_categorical(weights)

    # choice == 1 means no birth.
    if choice == 1
        return (
            born = false,
            capsule = nothing,
            birth_prob = 1.0 - weights[1]
        )
    end

    a, b = collision_birth_candidate_pair(prev, persisted_capsules, choice - 1)
    new_capsule = CollisionMSC(msc_capsule_id(:collision, a, b), a, b, t, 1)

    return (
        born = true,
        capsule = new_capsule,
        birth_prob = weights[choice]
    )
end

# A generative function to combine capsule birth, persistence, and death
@gen function capsule_kernel(t::Int, prev::MSCState, params::MSCParams)
    persisted_result ~ capsule_persistence(prev, params)

    birth_result ~ sample_new_capsule(t, prev, persisted_result.capsules, params)

    n_persisted = length(persisted_result.capsules)
    n_active = n_persisted + (birth_result.born ? 1 : 0)
    capsules = Vector{MSC}(undef, n_active)

    @inbounds for i in 1:n_persisted
        capsules[i] = persisted_result.capsules[i]
    end

    if birth_result.born
        @inbounds capsules[n_active] = birth_result.capsule
    end

    stats = MSCEventStats(
        n_active,
        n_persisted,
        persisted_result.n_died,
        birth_result.birth_prob,
        birth_result.born
    )

    return (
        capsules = capsules,
        stats = stats
    )
end

# Detect the first collision capsule. #TODO: this should probably be all capsules, not just the first 
function first_collision_capsule(capsules::Vector{MSC})
    @inbounds for cap in capsules
        cap isa CollisionMSC && return cap
    end
    return nothing
end

# Pick a branch to switch to.
function msc_physics_branch(capsules::Vector{MSC})
    return first_collision_capsule(capsules) === nothing ? :no_capsule : :collision
end

# When there's no collision capsule, just update physics normally. No sampling.
@gen function msc_no_capsule_clause(prev_objects::BulletState, sim::BulletSim, capsules::Vector{MSC}, params::MSCParams)
    return PhySMC.step(sim, prev_objects)
end

# A function that drifts the mass latent during collision
@gen function msc_collision_mass_drift(ls::RigidBodyLatents, params::MSCParams)
    prev_mass = ls.data.mass
    mass ~ trunc_norm(prev_mass, params.collision_mass_drift_std, 0.0, Inf)
    return update_latents(ls, mass)
end

# Active collision capsules drift object a's mass before stepping physics.
@gen function msc_collision_clause(prev_objects::BulletState, sim::BulletSim, capsules::Vector{MSC}, params::MSCParams)
    cap = first_collision_capsule(capsules)
    cap === nothing && error("collision clause selected without an active collision capsule")
    collision = cap::CollisionMSC

    obj_a = {:obj => collision.a} ~ msc_collision_mass_drift(prev_objects.latents[collision.a], params)
    obj_b = update_latents(prev_objects.latents[collision.b], 1.0)

    # Keep untouched object latents persistent while the active collision drifts mass.
    new_latents = Vector{BulletElemLatents}(undef, length(prev_objects.latents))
    copyto!(new_latents, prev_objects.latents)
    new_latents[collision.a] = obj_a
    new_latents[collision.b] = obj_b

    updated_objects = Accessors.setproperties(prev_objects; latents=new_latents)
    return PhySMC.step(sim, updated_objects)
end

# Switch combinator for clauses 
const msc_physics_clause = Gen.Switch(
    MSC_PHYSICS_BRANCHES,
    msc_no_capsule_clause,
    msc_collision_clause
)

# A generative function that does the capsule step and physics update.
@gen function msc_physics_step(t::Int, prev::MSCState, sim::BulletSim, params::MSCParams)

    capsule_update ~ capsule_kernel(t, prev, params)

    branch = msc_physics_branch(capsule_update.capsules)
    next_objects ~ msc_physics_clause(branch, prev.objects, sim, capsule_update.capsules, params)

    positions ~ Gen.Map(observe)(next_objects.kinematics)

    checkpoint_t = prev.last_mass_checkpoint_t
    checkpoint_object = prev.last_mass_checkpoint_object
    if branch == :collision
        cap = first_collision_capsule(capsule_update.capsules)::CollisionMSC
        checkpoint_t = t
        checkpoint_object = cap.a
    end

    return MSCState(
        next_objects,
        capsule_update.capsules,
        capsule_update.stats,
        checkpoint_t,
        checkpoint_object
    )
end

const msc_chain = Gen.Unfold(msc_physics_step)

# Complete MSC model code
@gen (static) function msc_model(T::Int, sim::BulletSim, template::BulletState, params::MSCParams)
    # Sample latents from the prior
    latents ~ prior(template.latents)

    # Set a template for initial scene
    init_objects = Accessors.setproperties(template; latents=latents)

    # Initial state
    init_state = initial_msc_state(init_objects, params)

    # Final physics and likelihood
    states ~ msc_chain(T, init_state, sim, params)

    return states
end

################################################################################
# Rejuvenation proposal for MSC v0
################################################################################

# Get the last point in time where the mass variable was sampled 
function msc_last_mass_checkpoint(tr::Gen.Trace, t::Int)
    states = get_retval(tr)
    state = states[min(t, length(states))]
    return (state.last_mass_checkpoint_t, state.last_mass_checkpoint_object)
end

# Create a capsule aware proposal for rejuvenation
@gen function msc_proposal(tr::Gen.Trace, checkpoint_t::Int, object_id::Int)
    choices = get_choices(tr)
    if checkpoint_t == 0
        prev_mass = choices[:latents => :obj1 => :mass]
        mass = {:latents => :obj1 => :mass} ~ trunc_norm(prev_mass, 1.0, 0.0, Inf)
    else
        prev_mass = choices[:states => checkpoint_t => :next_objects => :obj => object_id => :mass]
        mass = {:states => checkpoint_t => :next_objects => :obj => object_id => :mass} ~ trunc_norm(prev_mass, 1.0, 0.0, Inf)
    end
    return mass
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
            checkpoint = msc_last_mass_checkpoint(state.traces[i], t)
            state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, checkpoint)
        end
    end

    return Gen.sample_unweighted_traces(state, particles)
end

function extract_msc_capsules(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].capsules
end

function extract_msc_event_stats(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].event_stats
end

function extract_current_msc_mass(tr::Gen.Trace, t::Int, params::MSCParams=DEFAULT_MSC_PARAMS)
    object_id = params.tracked_mass_object
    return Float64(get_retval(tr)[t].objects.latents[object_id].data.mass)
end

function summarize_msc_masses(traces, t::Int, params::MSCParams=DEFAULT_MSC_PARAMS)
    ms = Float64[extract_current_msc_mass(tr, t, params) for tr in traces]
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

function _mean_active_capsule_age(capsules::Vector{MSC})
    isempty(capsules) && return 0.0
    return mean(Float64[cap.age for cap in capsules])
end

function summarize_msc_capsules(traces, t::Int)
    capsules_by_trace = [extract_msc_capsules(tr, t) for tr in traces]
    event_stats = [extract_msc_event_stats(tr, t) for tr in traces]
    active_counts = [length(capsules) for capsules in capsules_by_trace]
    active = active_counts .> 0

    birth_events = [stats.born for stats in event_stats]
    death_counts = [stats.n_died for stats in event_stats]
    death_events = death_counts .> 0
    switch_events = birth_events .| death_events

    return (
        capsule_active_prob = mean(Float64.(active)),
        capsule_switch_prob = mean(Float64.(switch_events)),
        capsule_birth_prob = mean(Float64.(birth_events)),
        capsule_death_prob = mean(Float64.(death_events)),
        capsule_mean_active_count = mean(Float64.(active_counts)),
        capsule_mean_death_count = mean(Float64.(death_counts)),
        capsule_mean_age = mean(Float64[_mean_active_capsule_age(capsules) for capsules in capsules_by_trace]),
        capsule_mean_birth_probability = mean(Float64[stats.birth_prob for stats in event_stats])
    )
end

function msc_inference_with_history(gm_args::Tuple,
                                    obs::Vector{Gen.ChoiceMap},
                                    particles::Int=20,
                                    rejuv_moves::Int=1)

    get_args(t) = (t, gm_args[2:4]...)
    params = gm_args[4]::MSCParams
    state = Gen.initialize_particle_filter(msc_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles
            for s in 1:rejuv_moves
                checkpoint = msc_last_mass_checkpoint(state.traces[i], t)
                state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, checkpoint)
            end
            capsules = get_retval(state.traces[i])[t].capsules
            println("t=$(t), particle=$(i), capsules=$(capsules), log_score=$(Gen.get_score(state.traces[i]))")
        end

        current_traces = Gen.sample_unweighted_traces(state, particles)
        mass_summary = summarize_msc_masses(current_traces, t, params)
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
            capsule_mean_active_count = capsule_summary.capsule_mean_active_count,
            capsule_mean_death_count = capsule_summary.capsule_mean_death_count,
            capsule_mean_age = capsule_summary.capsule_mean_age,
            capsule_mean_birth_probability = capsule_summary.capsule_mean_birth_probability,
            traces = current_traces
        )
    end

    return history
end

################################################################################
# Timing spec
################################################################################

function msc_timing_spec(; label="MSC v0", params::MSCParams=DEFAULT_MSC_PARAMS)
    return make_pf_timing_spec(
        label = label,
        pf_model = msc_model,
        gm_args_builder = (T, sim, template) -> (T, sim, template, params),
        online_args = gm_args -> (t -> (t, gm_args[2:4]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                checkpoint = msc_last_mass_checkpoint(state.traces[i], t)
                state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, checkpoint)
            end
            return nothing
        end
    )
end
