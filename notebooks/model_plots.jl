### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 7bcde7f4-0d2b-4bd6-a8e8-19b81b7f2f10
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using Revise
    using GalileoMSC
    using Plots
end

# ╔═╡ c0d50c0e-578f-48c6-a145-59ab2699dc0d
begin
    Revise.revise()
    selected_models = [:particle_filter, :drift, :msc]
    T = 120
    n_runs = 5
    n_scenes = 1
    particles = 30
    rejuv_moves = 1
    drift_std = 1.0
    proposal_drift_std = 1.0
    true_mass_ratio = 1.75
end

# ╔═╡ 83f320e0-8bf0-4373-9fc8-4ff0f2ff8f4b
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = (0.3, 0.3),
    obj_positions = (0.5, 1.5)
);

# ╔═╡ 14e46806-d244-4cc0-9d75-f97b31f24a7e
runtime_cmp = plot_step_runtime_comparison(
    selected_models;
    T = T,
    sim = scene.sim,
    template = scene.init_state,
    n_scenes = n_scenes,
    n_runs = n_runs,
    scene_model = :particle_filter,
    ground_truth_mass = true_mass_ratio,
    particles = particles,
    rejuv_moves = rejuv_moves,
    drift_std = drift_std,
    proposal_drift_std = proposal_drift_std,
    seed = 7,
    summary = :mean
);

# ╔═╡ 8932b855-87c4-4f6a-8f0f-7bb39cd127b1
runtime_cmp.plot

# ╔═╡ c6c2ef4d-c67d-4c34-a191-8daac383abb5
[r.label for r in runtime_cmp.results]

# ╔═╡ 6ea7e06b-6693-4150-92c2-993c26fb098d
timing_spec(:msc).label

# ╔═╡ Cell order:
# ╠═7bcde7f4-0d2b-4bd6-a8e8-19b81b7f2f10
# ╠═c0d50c0e-578f-48c6-a145-59ab2699dc0d
# ╠═83f320e0-8bf0-4373-9fc8-4ff0f2ff8f4b
# ╠═14e46806-d244-4cc0-9d75-f97b31f24a7e
# ╠═8932b855-87c4-4f6a-8f0f-7bb39cd127b1
# ╠═c6c2ef4d-c67d-4c34-a191-8daac383abb5
# ╠═6ea7e06b-6693-4150-92c2-993c26fb098d
