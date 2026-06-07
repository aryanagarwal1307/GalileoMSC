################################################################################
# Minimal collision-capsule MSC model
################################################################################

Base.@kwdef struct MSCParams
    # Epsilon for numerical stability
    eps::Float64 = 1e-9

    # Collision Birth Features: 
    birth_gap_max::Float64 = 0.05               # Maximum gap for which objects are 'close'
    birth_gap_scale::Float64 = 0.02             # Gap gate parameter 
    birth_v_min::Float64 = 0.02                 # Minimum closing speech for which objects are 'appraching'
    birth_v_scale::Float64 = 0.02               # Closing speed gate parameter 
    birth_T_contact::Float64 = 0.01             # Contact prediction horizon
    birth_tau_scale::Float64 = 0.04             # Time to contact gate parameter
    birth_base::Float64 = 0.99                  # Base probability of collision when all predicates are satisfied
    birth_aabb_window::Float64 = 1.0            # AABB distance window for full birth predicate evaluation
    birth_background_weight::Float64 = 1e-8     # Uniform candidate weight outside the AABB window

    # Object dimensions 
    obj_dims  = [[0.15, 0.3, 0.075], [0.2,  0.2, 0.1]] # ramp, then table 

    # Collision Death Features 
    min_active_steps::Int = 5                   # minimum steps for capsule to be active
    min_age_survival::Float64 = 1.0             # min survival prob early on
    age_decay_steps::Float64 = 9.0              # gradual decay of survival
    survival_distance_scale::Float64 = 0.45     # scale for near collision
    death_v_min::Float64 = 0.02                 # velocity parameter 
    death_v_scale::Float64 = 0.02               # Velocity parameter

    no_birth_weight::Float64 = 0.3              # weight of having no capsule births
    collision_mass_drift_std::Float64 = 1.5     # std for active-collision mass drift
    tracked_mass_object::Int = 1                # object to summarize in mass history
end

const DEFAULT_MSC_PARAMS = MSCParams()

const MSC_PHYSICS_BRANCHES = Dict(:no_capsule => 1, :collision => 2)

# This is the abstract type for a capsule.
abstract type MSC end

# This struct is some diagnostic / functional stats for the entire state
struct MSCEventStats
    n_active::Int
    n_persisted::Int
    n_died::Int
    birth_prob::Float64           # Birth prob of the new capsule; in case of no birth – total prob of any birth
    born::Bool
end

# This is a capsule kind - collision of two objects (by ID)
struct CollisionMSC <: MSC
    a::Int
    b::Int
    age::Int
end

# This is a capsule kind - sliding of one object (by ID) (just an example for now)
struct SlidingMSC <: MSC
    a::Int
    surface::Int
    age::Int
end

# Here we track the state of the entire scene
struct MSCState
    # Vector of all (interacting) objects in the scene as a Bullet State
    objects::BulletState
    # Vector of all active capsules in the scene
    capsules::Vector{MSC}
    # Statistics for diagnostoc / plotting reasons
    event_stats::MSCEventStats
end

# A diff structure for one object, all latents to be updated
struct ObjectDiff
    object_id::Int
    changes::Dict{Symbol, Float64}
end

# A diff structure for all objects in a capsule, all latents to be updated
struct CapsuleDiff
    diffs::Vector{ObjectDiff}
end


#### Helpers to manage capsules ####

# Initializer
function default_msc_event_stats()
    return MSCEventStats(0, 0, 0, 0.0, false)
end

# Initializer
function initial_msc_state(objects::BulletState, params::MSCParams=MSCParams())
    return MSCState(objects, MSC[], default_msc_event_stats())
end

# Helper to calculate collision birth and death probability
function collision_helper(objects::BulletState, a::Int, b::Int, params::MSCParams)
    # Extract kinematic properties from the bullet state
    ka = objects.kinematics[a]
    kb = objects.kinematics[b]

    @inbounds begin
        dx = kb.position[1] - ka.position[1]
        dy = kb.position[2] - ka.position[2]
        dz = kb.position[3] - ka.position[3]

        dvx = kb.linear_vel[1] - ka.linear_vel[1]
        dvy = kb.linear_vel[2] - ka.linear_vel[2]
        dvz = kb.linear_vel[3] - ka.linear_vel[3]
    end

    # Relative distance and velocity in 3D.
    distance = sqrt(dx^2 + dy^2 + dz^2)
    inv_distance = 1.0 / max(distance, params.eps)

    # Positive means the surface gap is shrinking.
    v_closing = -(dvx * dx + dvy * dy + dvz * dz) * inv_distance

    # Surface Gap using bounding-sphere radii.
    R_ramp  = norm(params.obj_dims[a]) / 2
    R_table = norm(params.obj_dims[b]) / 2
    R_sum = R_ramp + R_table

    gap = distance - R_sum

    # Constant velocity time to contact 
    if gap > 0.0 && v_closing > params.birth_v_min
        tau = gap / v_closing
    else
        tau = NaN               # If the objects are not separated & approaching, tau is meaningless 
    end

    # Sigmoidal scores 
    sigmoid(z) = 1 / (1 + exp(-z))

    p_gap = sigmoid((params.birth_gap_max - gap) / params.birth_gap_scale)
    p_closing = sigmoid((v_closing - params.birth_v_min) / params.birth_v_scale)

    if isnan(tau)
        p_ttc = 0.0
    else
        p_ttc = sigmoid((params.birth_T_contact - tau) / params.birth_tau_scale)
    end

    # Final collision birth probability for this pair.
    birth_prob = params.birth_base * p_gap * p_closing * p_ttc

    # Survival probability 
    near_gap = max(gap, 0.0)
    near_score = exp(-((near_gap / params.survival_distance_scale)^2))

    return (
        distance = distance,
        gap = gap,
        v_closing = v_closing,
        tau = tau,

        p_gap = p_gap,
        p_closing = p_closing,
        p_ttc = p_ttc,

        birth_prob = birth_prob,
        near_score = near_score
    )
end

# Helper to check if a collision capsule is equal to the proposed one
function is_same_collision(cap::MSC, a::Int, b::Int)
    return cap isa CollisionMSC &&
           ((cap.a == a && cap.b == b) || (cap.a == b && cap.b == a))
end

# Helper to check if a collision capsule is already in the given vector
function has_active_collision(capsules::Vector{MSC}, a::Int, b::Int)
    @inbounds for i in eachindex(capsules)
        is_same_collision(capsules[i], a, b) && return true
    end
    return false
end

# Helper to increase the age of a capsule
function increment_age(cap::CollisionMSC)
    return CollisionMSC(cap.a, cap.b, cap.age + 1)
end

# Calculate a quick bounding box distance between objects 
function bounding_box_distance(aabb_a, aabb_b)
    a_min, a_max = aabb_a
    b_min, b_max = aabb_b
    sep_sq = 0.0

    @inbounds for i in 1:3
        sep = max(a_min[i] - b_max[i], b_min[i] - a_max[i], 0.0)
        sep_sq += sep^2
    end

    return sqrt(sep_sq)
end

# Sparse normalized birth weights. Choice index 1 is reserved for no_birth;
# choices 2:end map deterministically to inactive collision pairs.
function collision_birth_weight(st::MSCState, a::Int, b::Int, params::MSCParams, default_weight::Float64)
    aabb_distance = bounding_box_distance(st.objects.kinematics[a].aabb, st.objects.kinematics[b].aabb)
    if aabb_distance <= params.birth_aabb_window
        features = collision_helper(st.objects, a, b, params)
        return max(Float64(features.birth_prob), default_weight)
    end

    return default_weight
end

# Get weights for all collision pairs. Inefficient (2 passes) but highly memory efficient – has sparse arrays. 
function all_collision_birth_weights(st::MSCState, active_capsules::Vector{MSC}, params::MSCParams)
    n_objects = length(st.objects.kinematics)
    default_weight = params.birth_background_weight
    total_weight = Float64(params.no_birth_weight)
    n_candidates = 0
    n_explicit = 0

    for a in 1:(n_objects - 1)
        for b in (a + 1):n_objects
            has_active_collision(active_capsules, a, b) && continue

            n_candidates += 1
            total_weight += default_weight

            weight = collision_birth_weight(st, a, b, params, default_weight)
            if weight > default_weight
                n_explicit += 1
                total_weight += weight - default_weight
            end
        end
    end

    if total_weight <= 0.0
        return SparseCategoricalWeights(n_candidates + 1, Int[], Float64[], 1.0, 0.0)
    end

    inv_total = 1.0 / total_weight

    explicit_indices = Vector{Int}(undef, n_explicit)
    explicit_weights = Vector{Float64}(undef, n_explicit)

    if n_explicit > 0
        candidate_index = 0
        explicit_index = 0

        for a in 1:(n_objects - 1)
            for b in (a + 1):n_objects
                has_active_collision(active_capsules, a, b) && continue

                candidate_index += 1
                weight = collision_birth_weight(st, a, b, params, default_weight)
                if weight > default_weight
                    explicit_index += 1
                    @inbounds begin
                        explicit_indices[explicit_index] = candidate_index + 1
                        explicit_weights[explicit_index] = weight * inv_total
                    end
                end
            end
        end
    end

    return SparseCategoricalWeights(
        n_candidates + 1,
        explicit_indices,
        explicit_weights,
        Float64(params.no_birth_weight) * inv_total,
        default_weight * inv_total
    )
end

function collision_birth_candidate_pair(st::MSCState, active_capsules::Vector{MSC}, candidate_index::Int)
    n_objects = length(st.objects.kinematics)
    seen = 0

    for a in 1:(n_objects - 1)
        for b in (a + 1):n_objects
            has_active_collision(active_capsules, a, b) && continue

            seen += 1
            if seen == candidate_index
                return a, b
            end
        end
    end

    error("Invalid collision birth candidate index: $candidate_index")
end

# Helper to clamp probability for numerical stability
function _clamp_probability(p::Real)
    return clamp(Float64(p), 1e-4, 1.0 - 1e-4)
end

# Helper to calculate the survival probability for a collision capsule
function collision_survival_probability(st::MSCState, cap::CollisionMSC, params::MSCParams)
    # Get the collision features
    features = collision_helper(st.objects, cap.a, cap.b, params)

    # Check if the minimum number of steps has passed yet 
    if cap.age <= params.min_active_steps
        return params.min_age_survival
    end

    ## Time of Life Component ## 
    age_excess = max(cap.age - params.min_active_steps, 0)
    age_penalty = exp(-age_excess / params.age_decay_steps)

    ## Distance Component ##
    # near_gap = max(features.gap, 0.0)
    # near_score = exp(-((near_gap / params.survival_distance_scale)^2))

    ## Velocity Component 
    # v_separating = -features.v_closing
    # sigmoid(z) = 1 / (1 + exp(-z))
    # p_separating = sigmoid((v_separating - params.death_v_min) / params.death_v_scale)
    # velocity_survival = 1.0 - p_separating

    # Survival prob is e^(-distance/scale)*e^((-age_excess/scale)^2)*(1 - sigmoid((-closing_speed - min_v)/v_scale))
    p = age_penalty # * near_score * velocity_survival

    return p
end

#### GENERATIVE FUNCTIONS ####

# A generative function to track all persisting capsules #TODO: Fix this categorical distribution 
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
@gen function sample_new_capsule(prev::MSCState, persisted_capsules::Vector{MSC}, params::MSCParams)

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
    new_capsule = CollisionMSC(a, b, 1)

    return (
        born = true,
        capsule = new_capsule,
        birth_prob = weights[choice]
    )
end

# A generative function to combine capsule birth, persistence, and death
@gen function capsule_kernel(prev::MSCState, params::MSCParams)
    persisted_result ~ capsule_persistence(prev, params)

    birth_result ~ sample_new_capsule(prev, persisted_result.capsules, params)

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

# Detect the first collision capsule.
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

# A function that drifts the mass latent 
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

    capsule_update ~ capsule_kernel(prev, params)

    branch = msc_physics_branch(capsule_update.capsules)
    next_objects ~ msc_physics_clause(branch, prev.objects, sim, capsule_update.capsules, params)

    positions ~ Gen.Map(observe)(next_objects.kinematics)

    return MSCState(
        next_objects,
        capsule_update.capsules,
        capsule_update.stats
    )
end

# Complete MSC model code
@gen function msc_model(T::Int, sim::BulletSim, template::BulletState, params::MSCParams)
    # Sample latents from the prior
    latents ~ prior(template.latents)

    # Set a template for initial scene
    init_objects = Accessors.setproperties(template; latents=latents)

    # Initial state
    init_state = initial_msc_state(init_objects, params)

    # Final physics and likelihood
    states ~ Gen.Unfold(msc_physics_step)(T, init_state, sim, params)

    return states
end

################################################################################
# Rejuvenation proposal for MSC v0
################################################################################

@gen function msc_proposal(tr::Gen.Trace)
    choices = get_choices(tr)
    prev_mass = choices[:latents => :obj1 => :mass]
    mass = {:latents => :obj1 => :mass} ~ trunc_norm(prev_mass, 1.0, 0.0, Inf)
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
            state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, ())
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

        for i in 1:particles, s in 1:rejuv_moves
            state.traces[i], _ = Gen.mh(state.traces[i], msc_proposal, ())
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
