################################################################################
# MSC model
################################################################################

#### GENERATIVE FUNCTIONS ####

function capsule_survival_probability(prev::MSCState, cap::CollisionMSC, params::MSCParams)
    return collision_survival_probability(prev, cap, params)
end

function capsule_survival_probability(prev::MSCState, cap::MSC, params::MSCParams)
    error("Unknown capsule type: $(typeof(cap))")
end

@gen function persist_capsule(cap::MSC, p_survive::Float64)
    survived ~ bernoulli(p_survive)
    return Bool(survived) ? increment_age(cap) : nothing
end

const capsule_persistence_map = Gen.Map(persist_capsule)

# A generative function to track all persisting capsules
@gen function capsule_persistence(prev::MSCState, params::MSCParams)
    survival_probs = Float64[capsule_survival_probability(prev, cap, params) for cap in prev.capsules]
    persistence_results ~ capsule_persistence_map(prev.capsules, survival_probs)
    persisted = MSC[cap for cap in persistence_results if cap !== nothing]

    return (
        capsules = persisted,
        n_died = length(prev.capsules) - length(persisted)
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

# Pick the per-capsule clause. #TODO: this can porbably be a capsule property
function msc_clause_branch(cap::MSC)
    error("Unknown capsule type: $(typeof(cap))")
end

msc_clause_branch(::CollisionMSC) = :collision

# Switch combinator for active capsule clauses.
const msc_capsule_clause = Gen.Switch(
    MSC_CLAUSE_BRANCHES,
    msc_collision_clause
)

# A generative function that does the capsule step and physics update.
@gen function msc_physics_step(t::Int, prev::MSCState, sim::BulletSim, params::MSCParams)

    capsule_update ~ capsule_kernel(t, prev, params)

    capsule_diffs = Vector{CapsuleDiff}(undef, length(capsule_update.capsules))
    for i in eachindex(capsule_update.capsules)
        cap = capsule_update.capsules[i]
        branch = msc_clause_branch(cap)
        capsule_diffs[i] = {:msc_switch => cap.id => :clause} ~ msc_capsule_clause(branch, prev.objects, cap, params)
    end

    diffed_objects = apply_capsule_diffs(prev.objects, capsule_diffs)
    next_objects = PhySMC.step(sim, diffed_objects)

    positions ~ Gen.Map(observe)(next_objects.kinematics)

    checkpoint_t = prev.last_clause_checkpoint_t
    checkpoint_msc_id = prev.last_clause_checkpoint_msc_id
    if !isempty(capsule_update.capsules)
        cap = capsule_update.capsules[end]
        checkpoint_t = t
        checkpoint_msc_id = cap.id
    end

    return MSCState(
        next_objects,
        capsule_update.capsules,
        capsule_update.stats,
        checkpoint_t,
        checkpoint_msc_id
    )
end

const msc_chain = Gen.Unfold(msc_physics_step)

# Complete MSC model code
@gen (static) function msc_model(T::Int, sim::BulletSim, template::BulletState, params::MSCParams)
    # Sample latents from the prior
    latents ~ prior(template.latents, params.tracked_mass_object)

    # Set a template for initial scene
    init_objects = Accessors.setproperties(template; latents=latents)

    # Initial state
    init_state = initial_msc_state(init_objects, params)

    # Final physics and likelihood
    states ~ msc_chain(T, init_state, sim, params)

    return states
end

@gen (static) function msc_mass_model(T::Int, sim::BulletSim,
                                      template::BulletState, params::MSCParams)
    latents ~ mass_prior(template.latents, params.tracked_mass_object)
    init_objects = Accessors.setproperties(template; latents=latents)
    init_state = initial_msc_state(init_objects, params)
    states ~ msc_chain(T, init_state, sim, params)
    return states
end

################################################################################
# Rejuvenation proposal for MSC v0
################################################################################

function msc_last_clause_checkpoint(tr::Gen.Trace, t::Int)
    states = get_retval(tr)
    state = states[min(t, length(states))]
    return (state.last_clause_checkpoint_t, state.last_clause_checkpoint_msc_id)
end

msc_last_mass_checkpoint(tr::Gen.Trace, t::Int) = msc_last_clause_checkpoint(tr, t)

@gen function msc_initial_mass_proposal(tr::Gen.Trace, object_id::Int)
    choices = get_choices(tr)
    previous = choices[:latents => :obj => object_id => :mass]
    mass = {:latents => :obj => object_id => :mass} ~
        trunc_norm(previous, 1.0, 0.0, Inf)
    return mass
end

@gen function msc_initial_latents_proposal(tr::Gen.Trace,
                                           mass_object_id::Int,
                                           friction_object_ids::Vector{Int})
    choices = get_choices(tr)
    previous = choices[:latents => :obj => mass_object_id => :mass]
    mass = {:latents => :obj => mass_object_id => :mass} ~
        trunc_norm(previous, 1.0, 0.0, Inf)

    for object_id in friction_object_ids
        previous = choices[:latents => :obj => object_id => :lateralFriction]
        lateralFriction = {:latents => :obj => object_id => :lateralFriction} ~
            trunc_norm(previous, FRICTION_PROPOSAL_STD,
                       FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH)
    end

    return mass
end

@gen function msc_initial_friction_proposal(tr::Gen.Trace,
                                            friction_object_ids::Vector{Int})
    choices = get_choices(tr)
    frictions = Vector{Float64}(undef, length(friction_object_ids))

    for (i, object_id) in enumerate(friction_object_ids)
        previous = choices[:latents => :obj => object_id => :lateralFriction]
        frictions[i] = {:latents => :obj => object_id => :lateralFriction} ~
            trunc_norm(previous, FRICTION_PROPOSAL_STD,
                       FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH)
    end

    return frictions
end

# Create an MSC-aware rejuvenation move by resampling a clause subtree.
function msc_proposal_selection(checkpoint_t::Int, msc_id::Int)
    return Gen.select(:states => checkpoint_t => :msc_switch => msc_id => :clause)
end

msc_model_for(infer_friction::Bool) = infer_friction ? msc_model : msc_mass_model

function msc_initial_latent_move(tr::Gen.Trace; infer_friction::Bool=true)
    template = get_args(tr)[3]
    params = get_args(tr)[4]::MSCParams
    mass_object_id = tracked_mass_object(template, params.tracked_mass_object)

    if infer_friction
        friction_object_ids = dynamic_object_indices(template)
        return Gen.mh(tr, msc_initial_latents_proposal,
                      (mass_object_id, friction_object_ids))
    else
        return Gen.mh(tr, msc_initial_mass_proposal, (mass_object_id,))
    end
end

function msc_proposal(tr::Gen.Trace, checkpoint_t::Int, msc_id::Int;
                      infer_friction::Bool=true)
    if checkpoint_t == 0
        return msc_initial_latent_move(tr; infer_friction=infer_friction)
    end

    if infer_friction
        friction_object_ids = dynamic_object_indices(get_args(tr)[3])
        tr, _ = Gen.mh(tr, msc_initial_friction_proposal,
                       (friction_object_ids,))
    end

    return Gen.mh(tr, msc_proposal_selection(checkpoint_t, msc_id))
end

################################################################################
# Sequential inference with stored history
################################################################################

function msc_inference_procedure(gm_args::Tuple,
                                 obs::Vector{Gen.ChoiceMap},
                                 particles::Int=20,
                                 rejuv_moves::Int=1;
                                 infer_friction::Bool=true)

    get_args(t) = (t, gm_args[2:4]...)
    pf_model = msc_model_for(infer_friction)
    state = Gen.initialize_particle_filter(pf_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles, s in 1:rejuv_moves
            checkpoint = msc_last_clause_checkpoint(state.traces[i], t)
            state.traces[i], _ = msc_proposal(
                state.traces[i], checkpoint...;
                infer_friction=infer_friction
            )
        end
    end

    return Gen.sample_unweighted_traces(state, particles)
end

function msc_inference_with_history(gm_args::Tuple,
                                    obs::Vector{Gen.ChoiceMap},
                                    particles::Int=20,
                                    rejuv_moves::Int=1;
                                    infer_friction::Bool=true)

    get_args(t) = (t, gm_args[2:4]...)
    params = gm_args[4]::MSCParams
    pf_model = msc_model_for(infer_friction)
    state = Gen.initialize_particle_filter(pf_model, get_args(0), EmptyChoiceMap(), particles)
    argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange())

    history = Vector{NamedTuple}(undef, length(obs))

    for (t, o) in enumerate(obs)
        Gen.particle_filter_step!(state, get_args(t), argdiffs, o)
        Gen.maybe_resample!(state, ess_threshold=particles / 2)

        for i in 1:particles
            for s in 1:rejuv_moves
                checkpoint = msc_last_clause_checkpoint(state.traces[i], t)
                state.traces[i], _ = msc_proposal(
                    state.traces[i], checkpoint...;
                    infer_friction=infer_friction
                )
            end
            capsules = get_retval(state.traces[i])[t].capsules
            #println("t=$(t), particle=$(i), capsules=$(capsules), log_score=$(Gen.get_score(state.traces[i]))")
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
            frictions = infer_friction ? summarize_msc_frictions(current_traces, t) : Dict{Int,NamedTuple}(),
            traces = current_traces
        )
    end

    return history
end
