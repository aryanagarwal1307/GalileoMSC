"""
A bounded positive distribution whose density peaks at `center` and is symmetric
in log distance from that center.
"""
struct LogSymmetricPeak <: Gen.Distribution{Float64} end

const log_symmetric_peak = LogSymmetricPeak()

function _check_log_symmetric_peak_params(low::Real, high::Real, center::Real, log_std::Real)
    isfinite(low) && isfinite(high) && isfinite(center) || error("log-symmetric peak bounds and center must be finite")
    0 < low < center < high || error("log-symmetric peak parameters must satisfy 0 < low < center < high")
    isfinite(log_std) && log_std > 0 || error("log-symmetric peak log_std must be positive and finite")
end

function _log_symmetric_peak_log_dist(low::Real, high::Real, center::Real, log_std::Real)
    log_center = log(Float64(center))
    sigma = Float64(log_std)
    return Distributions.Truncated(
        Distributions.Normal(log_center + sigma^2, sigma),
        log(Float64(low)),
        log(Float64(high))
    )
end

function Gen.random(::LogSymmetricPeak, low::Real, high::Real, center::Real, log_std::Real)
    _check_log_symmetric_peak_params(low, high, center, log_std)
    return exp(Distributions.rand(_log_symmetric_peak_log_dist(low, high, center, log_std)))
end

function Gen.logpdf(::LogSymmetricPeak, x::Real, low::Real, high::Real, center::Real, log_std::Real)
    _check_log_symmetric_peak_params(low, high, center, log_std)
    mass = Float64(x)
    if !isfinite(mass) || mass < low || mass > high
        return -Inf
    end

    log_mass = log(mass)
    return Distributions.logpdf(_log_symmetric_peak_log_dist(low, high, center, log_std), log_mass) - log_mass
end
