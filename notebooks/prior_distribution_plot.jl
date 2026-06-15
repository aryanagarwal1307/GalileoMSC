### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 8f927f80-28ab-4c5d-b9e1-95b6c8b8f611
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using Gen
    using Plots
end

# ╔═╡ c07a541b-9f6c-42f4-bb33-b07efb0f2323
prior_params = (
    low = GalileoMSC.MASS_PRIOR_LOW,
    high = GalileoMSC.MASS_PRIOR_HIGH,
    center = GalileoMSC.MASS_PRIOR_CENTER,
    log_std = GalileoMSC.MASS_PRIOR_LOG_STD,
)

# ╔═╡ dccf908f-1899-4954-9865-80b2fb095e2d
begin
    masses = range(0.0, 5.0; length = 1000)
    densities = [
        exp(Gen.logpdf(
            GalileoMSC.log_symmetric_peak,
            m,
            prior_params.low,
            prior_params.high,
            prior_params.center,
            prior_params.log_std,
        ))
        for m in masses
    ]
end

# ╔═╡ e6fb41d0-8ef2-46d9-80d7-88398832cf19
begin
    p = plot(
        masses,
        densities;
        xlabel = "mass",
        ylabel = "probability density",
        title = "Current mass prior",
        label = "log-symmetric prior",
        lw = 3,
        legend = :topright,
    )

    vline!(p, [prior_params.low, prior_params.high]; label = "bounds", ls = :dash, lw = 2)
    vline!(p, [prior_params.center]; label = "center", ls = :dot, lw = 2, color = :black)
    p
end

# ╔═╡ Cell order:
# ╠═8f927f80-28ab-4c5d-b9e1-95b6c8b8f611
# ╠═c07a541b-9f6c-42f4-bb33-b07efb0f2323
# ╠═dccf908f-1899-4954-9865-80b2fb095e2d
# ╠═e6fb41d0-8ef2-46d9-80d7-88398832cf19
