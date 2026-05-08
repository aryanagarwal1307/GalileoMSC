################################################################################
# Observation model
################################################################################

@gen function observe(state::RigidBodyState)
    position ~ broadcasted_normal(state.position, 0.05)
    return position
end

################################################################################
# Latent update helpers
################################################################################

function update_latents(ls::RigidBodyLatents, mass::Float64)
    RigidBodyLatents(setproperties(ls.data; mass=mass))
end

################################################################################
# Initial prior
################################################################################

@gen function sample_object(ls::RigidBodyLatents)
    mass ~ gamma(1.2, 10.0)
    return update_latents(ls, mass)
end

@gen function prior(old_latents::Vector{BulletElemLatents})
    obj1 ~ sample_object(old_latents[1])
    obj2 = update_latents(old_latents[2], 1.0)
    return BulletElemLatents[obj1, obj2]
end

################################################################################
# Truncated normal
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

function make_observations(observed_positions)
    T = length(observed_positions)
    obs = Vector{Gen.ChoiceMap}(undef, T)

    for t in 1:T
        cm = Gen.choicemap()
        cm[:states => t => :positions => 1 => :position] = observed_positions[t][1]
        cm[:states => t => :positions => 2 => :position] = observed_positions[t][2]
        obs[t] = cm
    end

    return obs
end

function observations_from_trace(tr::Gen.Trace)
    choices = get_choices(tr)
    T = get_args(tr)[1]
    out = Vector{Any}(undef, T)

    for t in 1:T
        p1 = choices[:states => t => :positions => 1 => :position]
        p2 = choices[:states => t => :positions => 2 => :position]
        out[t] = [p1, p2]
    end

    return out
end

################################################################################
# Shared summaries
################################################################################

function detect_collision_time(observed_positions; threshold=0.25)
    T = length(observed_positions)
    for t in 1:T
        p1 = observed_positions[t][1]
        p2 = observed_positions[t][2]
        d = norm(p1 .- p2)
        if d < threshold
            return t
        end
    end
    return nothing
end

"""
Choose Gamma(shape, scale) parameters from a target mean and standard deviation.
"""
function gamma_from_mean_std(mean_mass::Real, std_mass::Real)
    mu = Float64(mean_mass)
    sigma = Float64(std_mass)
    mu > 0 || error("mean_mass must be positive")
    sigma > 0 || error("std_mass must be positive")

    shape = (mu / sigma)^2
    scale = (sigma^2) / mu
    return (shape=shape, scale=scale)
end
