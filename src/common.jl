################################################################################
# Observation model
################################################################################

@gen function observe(state::RigidBodyState)
    position ~ broadcasted_normal(state.position, 0.25)
    return position
end

################################################################################
# Latent update helpers
################################################################################

function update_latents(ls::RigidBodyLatents; mass=nothing, lateralFriction=nothing)
    data = ls.data
    mass === nothing || (data = setproperties(data; mass=Float64(mass)))
    lateralFriction === nothing ||
        (data = setproperties(data; lateralFriction=Float64(lateralFriction)))
    return RigidBodyLatents(data)
end

update_latents(ls::RigidBodyLatents, mass::Real) = update_latents(ls; mass=mass)

function object_mass(ls::RigidBodyLatents)
    return Float64(ls.data.mass)
end

object_lateral_friction(ls::RigidBodyLatents) = Float64(ls.data.lateralFriction)

function is_static_object(ls::RigidBodyLatents)
    return object_mass(ls) == 0.0
end

function is_dynamic_object(ls::RigidBodyLatents)
    return object_mass(ls) > 0.0
end

dynamic_object_indices(latents::AbstractVector) =
    [i for i in eachindex(latents) if latents[i] isa RigidBodyLatents && is_dynamic_object(latents[i])]

dynamic_object_indices(state::BulletState) = dynamic_object_indices(state.latents)

static_object_indices(latents::AbstractVector) =
    [i for i in eachindex(latents) if latents[i] isa RigidBodyLatents && is_static_object(latents[i])]

static_object_indices(state::BulletState) = static_object_indices(state.latents)

function tracked_mass_object(latents::AbstractVector, object_id::Int=1)
    object_id in eachindex(latents) || error("Tracked mass object index $object_id is out of bounds.")
    latents[object_id] isa RigidBodyLatents || error("Tracked mass object $object_id is not a rigid body.")
    is_dynamic_object(latents[object_id]) || error("Tracked mass object $object_id must have positive mass.")
    return object_id
end

tracked_mass_object(state::BulletState, object_id::Int=1) = tracked_mass_object(state.latents, object_id)

################################################################################
# Initial prior
################################################################################

# The bounds are symmetric in log space, so 1.0 is the prior's center.
const MASS_PRIOR_LOW = 0.25
const MASS_PRIOR_CENTER = 1.0
const MASS_PRIOR_HIGH = 4.0
const MASS_PRIOR_LOG_STD = 0.15

const FRICTION_PRIOR_LOW = 0.05
const FRICTION_PRIOR_CENTER = 0.3
const FRICTION_PRIOR_HIGH = 1.25
const FRICTION_PRIOR_LOG_STD = 0.35
const FRICTION_PROPOSAL_STD = 0.05

@gen function sample_mass_object(ls::RigidBodyLatents)
    mass ~ log_symmetric_peak(MASS_PRIOR_LOW, MASS_PRIOR_HIGH, MASS_PRIOR_CENTER, MASS_PRIOR_LOG_STD)
    return update_latents(ls; mass=mass)
end

@gen function sample_object(ls::RigidBodyLatents)
    mass ~ log_symmetric_peak(MASS_PRIOR_LOW, MASS_PRIOR_HIGH, MASS_PRIOR_CENTER, MASS_PRIOR_LOG_STD)
    lateralFriction ~ log_symmetric_peak(FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH, FRICTION_PRIOR_CENTER, FRICTION_PRIOR_LOG_STD)
    return update_latents(ls; mass=mass, lateralFriction=lateralFriction)
end

@gen function sample_friction_object(ls::RigidBodyLatents)
    lateralFriction ~ log_symmetric_peak(FRICTION_PRIOR_LOW, FRICTION_PRIOR_HIGH, FRICTION_PRIOR_CENTER, FRICTION_PRIOR_LOG_STD)
    return update_latents(ls; lateralFriction=lateralFriction)
end

@gen function prior(old_latents::Vector{BulletElemLatents},
                    target_object::Int=1)
    tracked_mass_object(old_latents, target_object)
    friction_objects = Set(dynamic_object_indices(old_latents))
    new_latents = Vector{BulletElemLatents}(undef, length(old_latents))

    for i in eachindex(old_latents)
        if i == target_object
            new_latents[i] = {:obj => i} ~ sample_object(old_latents[i])
        elseif i in friction_objects
            new_latents[i] = {:obj => i} ~ sample_friction_object(old_latents[i])
        else
            new_latents[i] = old_latents[i]
        end
    end

    return new_latents
end

@gen function mass_prior(old_latents::Vector{BulletElemLatents}, target_object::Int)
    tracked_mass_object(old_latents, target_object)
    new_latents = copy(old_latents)
    new_latents[target_object] = {:obj => target_object} ~
        sample_mass_object(old_latents[target_object])
    return new_latents
end

################################################################################
# Truncated normal #TODO: at some point move this to distributions
################################################################################

"""
A truncated normal distribution for random-walk proposals.
"""
struct TruncNorm <: Gen.Distribution{Float64} end

const trunc_norm = TruncNorm()

function Gen.random(::TruncNorm, mu::U, noise::T, low::T, high::T) where {U<:Real,T<:Real}
    d = Distributions.Truncated(Distributions.Normal(mu, noise), low, high)
    return Distributions.rand(d)
end

function Gen.logpdf(::TruncNorm, x::Float64, mu::U, noise::T, low::T, high::T) where {U<:Real,T<:Real}
    d = Distributions.Truncated(Distributions.Normal(mu, noise), low, high)
    return Distributions.logpdf(d, x)
end

################################################################################
# Observation construction
################################################################################

function make_observations(observed_positions; chain_addr::Symbol=:states, object_indices=nothing)
    T = length(observed_positions)
    obs = Vector{Gen.ChoiceMap}(undef, T)

    for t in 1:T
        cm = Gen.choicemap()
        positions_t = observed_positions[t]
        indices = object_indices === nothing ? eachindex(positions_t) : object_indices
        for (j, object_id) in enumerate(indices)
            cm[chain_addr => t => :positions => object_id => :position] = positions_t[j]
        end
        obs[t] = cm
    end

    return obs
end

function template_mass_ratio(template::BulletState)
    return object_mass(template.latents[tracked_mass_object(template)])
end

function template_lateral_frictions(template::BulletState;
                                    object_indices=dynamic_object_indices(template))
    return [object_lateral_friction(template.latents[i]) for i in object_indices]
end

function mass_constraint(mass::Real; object_id::Int=1)
    isfinite(mass) || error("mass ratio must be finite")
    mass > 0 || error("mass ratio must be positive")
    constraints = Gen.choicemap()
    constraints[:latents => :obj => object_id => :mass] = Float64(mass)
    return constraints
end

mass_constraint(mass::Real, template::BulletState) = mass_constraint(mass; object_id=tracked_mass_object(template))

function set_friction_constraints!(constraints, frictions;
                                   object_indices=eachindex(frictions))
    length(frictions) == length(object_indices) ||
        error("frictions and object_indices must have the same length")

    for (j, object_id) in enumerate(object_indices)
        value = frictions isa AbstractDict ? frictions[object_id] : frictions[j]
        friction = Float64(value)
        isfinite(friction) || error("lateral friction must be finite")
        FRICTION_PRIOR_LOW <= friction <= FRICTION_PRIOR_HIGH ||
            error("lateral friction must be within the prior support")
        constraints[:latents => :obj => object_id => :lateralFriction] = friction
    end

    return constraints
end

function friction_constraint(frictions; object_indices=eachindex(frictions))
    return set_friction_constraints!(Gen.choicemap(), frictions;
                                     object_indices=object_indices)
end

friction_constraint(frictions, template::BulletState) =
    friction_constraint(frictions; object_indices=dynamic_object_indices(template))

function add_physical_constraints!(constraints, template::BulletState;
                                   ground_truth_mass=nothing,
                                   ground_truth_frictions=nothing,
                                   infer_friction::Bool=true)
    object_id = tracked_mass_object(template)
    ground_truth_mass === nothing ||
        (constraints[:latents => :obj => object_id => :mass] = Float64(ground_truth_mass))

    if infer_friction && ground_truth_frictions !== nothing
        set_friction_constraints!(constraints, ground_truth_frictions;
                                  object_indices=dynamic_object_indices(template))
    end
    return constraints
end

function observations_from_trace(tr::Gen.Trace; chain_addr::Symbol=:states, object_indices=nothing)
    choices = get_choices(tr)
    T = get_args(tr)[1]
    states = get_retval(tr)
    index_state = hasproperty(states[1], :objects) ? states[1].objects : states[1]
    indices = object_indices === nothing ? dynamic_object_indices(index_state) : object_indices
    out = Vector{Any}(undef, T)

    for t in 1:T
        out[t] = [choices[chain_addr => t => :positions => object_id => :position] for object_id in indices]
    end

    return out
end

"""
    true_positions_from_trace(tr; object_indices=nothing)

Extract noise-free object positions from the simulator states returned by a
trace. This is distinct from `observations_from_trace`, which extracts the
noisy position choices sampled by `observe`.
"""
function true_positions_from_trace(tr::Gen.Trace; object_indices=nothing)
    states = get_retval(tr)
    isempty(states) && return Any[]

    first_objects = hasproperty(states[1], :objects) ? states[1].objects : states[1]
    indices = object_indices === nothing ? dynamic_object_indices(first_objects) : object_indices
    out = Vector{Any}(undef, length(states))

    for t in eachindex(states)
        objects = hasproperty(states[t], :objects) ? states[t].objects : states[t]
        out[t] = [copy(objects.kinematics[object_id].position) for object_id in indices]
    end

    return out
end

################################################################################
# Shared summaries
################################################################################

function detect_collision_time(positions; threshold=0.25)
    T = length(positions)
    for t in 1:T
        p1 = positions[t][1]
        p2 = positions[t][2]
        d = norm(p1 .- p2)
        if d < threshold
            return t
        end
    end
    return nothing
end

function summarize_values(values)
    return (
        mean = mean(values),
        std = std(values),
        q05 = quantile(values, 0.05),
        q25 = quantile(values, 0.25),
        q75 = quantile(values, 0.75),
        q95 = quantile(values, 0.95),
        values = values
    )
end

function summarize_frictions(getter, traces, object_indices)
    return Dict(
        object_id => begin
            values = Float64[getter(tr, object_id) for tr in traces]
            summary = summarize_values(values)
            (; summary.mean, summary.std, summary.q05, summary.q25,
               summary.q75, summary.q95, frictions=values)
        end
        for object_id in object_indices
    )
end
