################################################################################
# Collision capsule
################################################################################

# Helper to calculate collision birth and death probability
function collision_helper(objects::BulletState, a::Int, b::Int, params::MSCParams;
                          surface_gap::Union{Nothing,Float64}=nothing)
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

    # AABB separation is exact for axis-aligned boxes and tighter than the
    # previous diagonal bounding-sphere approximation.
    gap = isnothing(surface_gap) ? bounding_box_distance(ka.aabb, kb.aabb) : surface_gap

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

# Helper to check if a collision capsule is already in the given vector
function has_active_collision(active_ids::Set{Int}, a::Int, b::Int)
    return msc_capsule_id(:collision, a, b) in active_ids
end

# Helper to increase the age of a capsule
function increment_age(cap::CollisionMSC)
    return CollisionMSC(cap.id, cap.a, cap.b, cap.birth_t, cap.age + 1)
end

# AABB separation shared by MSC birth scoring and trace-based collision plots.
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

"""
    detect_collision_time(tr::Gen.Trace; object_indices=nothing, aabb_tolerance=0.0)

Return the first frame at which the noise-free AABBs of the first two selected
dynamic objects touch or overlap. The trace's stored simulator states are used;
no sampled observations enter this calculation.
"""
function detect_collision_time(tr::Gen.Trace;
                               object_indices=nothing,
                               aabb_tolerance::Real=0.0)
    aabb_tolerance >= 0 || error("aabb_tolerance must be nonnegative")

    states = get_retval(tr)
    isempty(states) && return nothing

    first_objects = hasproperty(states[1], :objects) ? states[1].objects : states[1]
    indices = object_indices === nothing ? dynamic_object_indices(first_objects) : collect(object_indices)
    length(indices) >= 2 || error("Collision detection requires at least two objects.")
    a, b = indices[1], indices[2]

    for t in eachindex(states)
        objects = hasproperty(states[t], :objects) ? states[t].objects : states[t]
        distance = bounding_box_distance(
            objects.kinematics[a].aabb,
            objects.kinematics[b].aabb
        )
        distance <= aabb_tolerance && return t
    end

    return nothing
end

# Sparse normalized birth weights. Choice index 1 is reserved for no_birth;
# choices 2:end map deterministically to inactive collision pairs.
function collision_birth_weight(st::MSCState, a::Int, b::Int, params::MSCParams, default_weight::Float64)
    if !is_dynamic_object(st.objects.latents[a]) || !is_dynamic_object(st.objects.latents[b])
        return 0.0
    end

    aabb_distance = bounding_box_distance(st.objects.kinematics[a].aabb, st.objects.kinematics[b].aabb)
    if aabb_distance <= params.birth_aabb_window
        features = collision_helper(st.objects, a, b, params; surface_gap=aabb_distance)
        return max(Float64(features.birth_prob), default_weight)
    end

    return default_weight
end

# Get weights for all collision pairs. Inefficient (2 passes) but highly memory efficient – has sparse arrays. 
function all_collision_birth_weights(st::MSCState, active_capsules::Vector{MSC}, params::MSCParams)
    object_indices = dynamic_object_indices(st.objects)
    active_ids = active_capsule_ids(active_capsules)
    default_weight = params.birth_background_weight
    total_weight = Float64(params.no_birth_weight)
    n_candidates = 0
    n_explicit = 0

    for i in 1:(length(object_indices) - 1)
        a = object_indices[i]
        for j in (i + 1):length(object_indices)
            b = object_indices[j]
            has_active_collision(active_ids, a, b) && continue

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

        for i in 1:(length(object_indices) - 1)
            a = object_indices[i]
            for j in (i + 1):length(object_indices)
                b = object_indices[j]
                has_active_collision(active_ids, a, b) && continue

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
    object_indices = dynamic_object_indices(st.objects)
    active_ids = active_capsule_ids(active_capsules)
    seen = 0

    for i in 1:(length(object_indices) - 1)
        a = object_indices[i]
        for j in (i + 1):length(object_indices)
            b = object_indices[j]
            has_active_collision(active_ids, a, b) && continue

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

# Active collision capsules sample an absolute mass, then encode it as a diff.
@gen function msc_collision_clause(prev_objects::BulletState, cap::MSC, params::MSCParams)
    collision = cap::CollisionMSC
    prev_mass = object_mass(prev_objects.latents[collision.a])
    mass = {:obj => collision.a => :mass} ~ trunc_norm(prev_mass, params.collision_mass_drift_std, 0.0, Inf)
    log_mass_delta = log(mass / prev_mass)
    return CapsuleDiff(collision.id, [LatentDelta(collision.a, :log_mass, log_mass_delta)])
end
