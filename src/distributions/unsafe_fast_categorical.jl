################################################################################
# Unsafe fast categorical distribution
################################################################################

"""
A categorical distribution for already-normalized weights.

Unlike `Gen.categorical`, this distribution does not validate or wrap the input
weights. Sampling is a single cumulative scan and assumes `sum(weights) == 1`.
"""
struct UnsafeFastCategorical <: Gen.Distribution{Int} end

const unsafe_fast_categorical = UnsafeFastCategorical()

struct SparseCategoricalWeights{I<:AbstractVector{Int}, W<:AbstractVector{Float64}} <: AbstractVector{Float64}
    n_choices::Int
    explicit_indices::I
    explicit_weights::W
    first_weight::Float64
    default_weight::Float64
end

Base.size(weights::SparseCategoricalWeights) = (weights.n_choices,)
Base.length(weights::SparseCategoricalWeights) = weights.n_choices
Base.IndexStyle(::Type{<:SparseCategoricalWeights}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(weights::SparseCategoricalWeights, i::Int)
    @boundscheck checkbounds(weights, i)

    i == 1 && return weights.first_weight

    indices = weights.explicit_indices
    @inbounds for j in eachindex(indices)
        index = indices[j]
        index == i && return weights.explicit_weights[j]
        index > i && break
    end

    return weights.default_weight
end

@inline function Gen.random(::UnsafeFastCategorical, weights::AbstractVector{<:Real})
    u = rand()
    cumulative = 0.0
    n = length(weights)

    @inbounds for i in 1:n
        cumulative += weights[i]
        if u <= cumulative
            return i
        end
    end

    return n
end

@inline function Gen.random(::UnsafeFastCategorical, weights::SparseCategoricalWeights)
    u = rand()
    cumulative = 0.0
    n = weights.n_choices
    explicit_pos = 1
    n_explicit = length(weights.explicit_indices)

    @inbounds for i in 1:n
        if i == 1
            mass = weights.first_weight
        elseif explicit_pos <= n_explicit && weights.explicit_indices[explicit_pos] == i
            mass = weights.explicit_weights[explicit_pos]
            explicit_pos += 1
        else
            mass = weights.default_weight
        end

        cumulative += mass
        if u <= cumulative
            return i
        end
    end

    return n
end

@inline function Gen.logpdf(::UnsafeFastCategorical, x::Int, weights::AbstractVector{<:Real})
    if 1 <= x <= length(weights)
        @inbounds return log(weights[x])
    end
    return -Inf
end

function Gen.logpdf_grad(::UnsafeFastCategorical, x::Int, weights::AbstractVector{<:Real})
    return (nothing, nothing)
end

Gen.is_discrete(::UnsafeFastCategorical) = true
Gen.has_output_grad(::UnsafeFastCategorical) = false
Gen.has_argument_grads(::UnsafeFastCategorical) = (false,)

(dist::UnsafeFastCategorical)(weights) = Gen.random(dist, weights)
