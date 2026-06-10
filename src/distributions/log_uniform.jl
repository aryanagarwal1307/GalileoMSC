"""
A positive, finite log-uniform distribution.
"""
struct LogUniform <: Gen.Distribution{Float64} end

const log_uniform = LogUniform()

function _check_log_uniform_bounds(low::Real, high::Real)
    isfinite(low) && isfinite(high) || error("log-uniform bounds must be finite")
    0 < low < high || error("log-uniform bounds must satisfy 0 < low < high")
end

function Gen.random(::LogUniform, low::Real, high::Real)
    _check_log_uniform_bounds(low, high)
    log_low = log(Float64(low))
    log_high = log(Float64(high))
    return exp(log_low + rand() * (log_high - log_low))
end

function Gen.logpdf(::LogUniform, x::Real, low::Real, high::Real)
    _check_log_uniform_bounds(low, high)
    mass = Float64(x)
    if !isfinite(mass) || mass < low || mass > high
        return -Inf
    end

    return -log(mass) - log(log(Float64(high) / Float64(low)))
end
