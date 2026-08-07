################################################################################
# Collision capsule
################################################################################

# Shortest vector from A's AABB to B's AABB. Each component is zero on axes
# where the boxes overlap, positive when B is above A, and negative otherwise.
@inline function _aabb_axis_separation(a_min::Real, a_max::Real, b_min::Real, b_max::Real)
    a_max < b_min && return b_min - a_max
    b_max < a_min && return b_max - a_min
    return 0.0
end

@inline function bounding_box_separation(aabb_a, aabb_b, eps::Float64=0.0)
    a_min, a_max = aabb_a
    b_min, b_max = aabb_b

    @inbounds begin
        sx = _aabb_axis_separation(a_min[1], a_max[1], b_min[1], b_max[1])
        sy = _aabb_axis_separation(a_min[2], a_max[2], b_min[2], b_max[2])
        sz = _aabb_axis_separation(a_min[3], a_max[3], b_min[3], b_max[3])
    end

    gap = sqrt(sx * sx + sy * sy + sz * sz)
    if gap > eps
        inv_gap = 1.0 / gap
        return (gap = gap, nx = sx * inv_gap, ny = sy * inv_gap, nz = sz * inv_gap, separated = true)
    end

    return (gap = gap, nx = 0.0, ny = 0.0, nz = 0.0, separated = false)
end

@inline _sigmoid(z::Real) = 1.0 / (1.0 + exp(-z))

# Helper to calculate collision birth and death probability
function collision_helper(objects::BulletState, a::Int, b::Int, params::MSCParams;
                          separation=nothing)
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
    distance = sqrt(dx * dx + dy * dy + dz * dz)

    # Use the same shortest AABB separating direction for gap and closing speed.
    # Positive closing speed means the AABB surface gap is shrinking.
    sep = separation === nothing ? bounding_box_separation(ka.aabb, kb.aabb, params.eps) : separation
    gap = sep.gap
    v_closing = sep.separated ? -(dvx * sep.nx + dvy * sep.ny + dvz * sep.nz) : 0.0

    # Constant velocity time to contact 
    if sep.separated && v_closing > params.birth_v_min
        tau = gap / v_closing
    else
        tau = NaN               # If the objects are not separated & approaching, tau is meaningless 
    end

    # Sigmoidal scores 
    p_gap = _sigmoid((params.birth_gap_max - gap) / params.birth_gap_scale)
    p_closing = _sigmoid((v_closing - params.birth_v_min) / params.birth_v_scale)

    if isnan(tau)
        p_ttc = 0.0
    else
        p_ttc = _sigmoid((params.birth_T_contact - tau) / params.birth_tau_scale)
    end

    # Final collision birth probability for this pair.
    birth_prob = params.birth_base * p_gap * p_closing * p_ttc

    return (
        distance = distance,
        gap = gap,
        normal = (sep.nx, sep.ny, sep.nz),
        separated = sep.separated,
        v_closing = v_closing,
        tau = tau,

        p_gap = p_gap,
        p_closing = p_closing,
        p_ttc = p_ttc,

        birth_prob = birth_prob
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

    @inbounds begin
        sx = _aabb_axis_separation(a_min[1], a_max[1], b_min[1], b_max[1])
        sy = _aabb_axis_separation(a_min[2], a_max[2], b_min[2], b_max[2])
        sz = _aabb_axis_separation(a_min[3], a_max[3], b_min[3], b_max[3])
    end

    return sqrt(sx * sx + sy * sy + sz * sz)
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

    separation = bounding_box_separation(
        st.objects.kinematics[a].aabb,
        st.objects.kinematics[b].aabb,
        params.eps
    )
    if separation.gap <= params.birth_aabb_window
        features = collision_helper(st.objects, a, b, params; separation=separation)
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

# Helper to calculate the survival probability for a collision capsule
function collision_survival_probability(st::MSCState, cap::CollisionMSC, params::MSCParams)
    # Check if the minimum number of steps has passed yet 
    if cap.age <= params.min_active_steps
        return params.min_age_survival
    end

    ## Time of Life Component ## 
    age_excess = max(cap.age - params.min_active_steps, 0)
    age_penalty = exp(-age_excess / params.age_decay_steps)

    return age_penalty
end

# Active collision capsules sample an absolute mass, then encode it as a diff.
@gen function msc_collision_clause(prev_objects::BulletState, cap::MSC, params::MSCParams)
    collision = cap::CollisionMSC
    prev_mass = object_mass(prev_objects.latents[collision.a])
    mass = {:obj => collision.a => :mass} ~ trunc_norm(prev_mass, params.collision_mass_drift_std, 0.0, Inf)
    log_mass_delta = log(mass / prev_mass)
    return CapsuleDiff(collision.id, [LatentDelta(collision.a, :log_mass, log_mass_delta)])
end
