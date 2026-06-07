### A Pluto.jl notebook ###
# v0.20.24

using Markdown
using InteractiveUtils

# ╔═╡ 33879e2e-23f7-4cb7-83f4-b42db2ce8d4b
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using Gen
    using Plots
    using Random
end

# ╔═╡ 4d8b2738-ff70-4894-bc79-50caec176811
begin
    Random.seed!(17)
    weights = [0.12, 0.28, 0.60]
    draws = 50_000
    counts = zeros(Int, length(weights))

    for _ in 1:draws
        counts[unsafe_fast_categorical(weights)] += 1
    end

    empirical = counts ./ draws
    max_abs_error = maximum(abs.(empirical .- weights))
    distribution_sanity = max_abs_error < 0.02
end

# ╔═╡ 8a8a5139-c048-4a5a-80fb-f434d049ed99
bar(
    string.(1:length(weights)),
    [weights empirical];
    label = ["target" "empirical"],
    xlabel = "index",
    ylabel = "probability",
    title = "Unsafe fast categorical sanity",
    ylim = (0, 0.7)
)

# ╔═╡ 3bf779bf-caf7-4cca-b193-fce99f8f55bd
(counts = counts, empirical = empirical, max_abs_error = max_abs_error, passed = distribution_sanity)

# ╔═╡ 8b662d10-f31d-41c4-b80a-d2157e889ae6b
begin
    scene = create_ramp_simulation(
        mass_ratio = 2.0,
        obj_frictions = (0.3, 0.3),
        obj_positions = (0.5, 1.5)
    )

    params = MSCParams(no_birth_weight = 0.1, birth_background_weight = 1e-6)
    prev = initial_msc_state(scene.init_state, params)
    birth_trace = Gen.simulate(GalileoMSC.sample_new_capsule, (prev, GalileoMSC.MSC[], params))
    birth_result = Gen.get_retval(birth_trace)
    birth_choice = Gen.get_choices(birth_trace)[:choice]
    birth_sampling_sanity = birth_choice >= 1 && 0.0 <= birth_result.birth_prob <= 1.0
end

# ╔═╡ e84e3999-43df-482c-810e-7793adf148e1
(choice = birth_choice, result = birth_result, passed = birth_sampling_sanity)

# ╔═╡ Cell order:
# ╠═33879e2e-23f7-4cb7-83f4-b42db2ce8d4b
# ╠═4d8b2738-ff70-4894-bc79-50caec176811
# ╠═8a8a5139-c048-4a5a-80fb-f434d049ed99
# ╠═3bf779bf-caf7-4cca-b193-fce99f8f55bd
# ╠═8b662d10-f31d-41c4-b80a-d2157e889ae6b
# ╠═e84e3999-43df-482c-810e-7793adf148e1
