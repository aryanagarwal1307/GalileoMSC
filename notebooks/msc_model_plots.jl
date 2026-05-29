### A Pluto.jl notebook ###
# v0.20.24

using Markdown
using InteractiveUtils

# ╔═╡ 9f5b47fc-1f86-4e7d-8fd0-1600866ef6d5
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using Plots
end

# ╔═╡ a62867f7-cad0-443b-9135-58cdd6561e06
begin
    selected_models = [:particle_filter, :msc]
    T = 120
    particles = 20
    rejuv_moves = 1
    true_mass_ratio = 2.0
    time_bin_size = 10
    rng_seed = 11
end

# ╔═╡ 109177a5-67d9-42b4-8db0-23c9c929894f
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = (0.3, 0.3),
    obj_positions = (0.5, 1.5)
);

# ╔═╡ b9a22540-5d70-47dd-8398-1c8878eef1fb
mass_and_msc_cmp = run_mass_ratio_history_comparison(
    selected_models;
    T = T,
    sim = scene.sim,
    template = scene.init_state,
    scene_model = :particle_filter,
    ground_truth_mass = true_mass_ratio,
    particles = particles,
    rejuv_moves = rejuv_moves,
    seed = rng_seed
);

# ╔═╡ 091847d1-a86d-4664-9262-f85436e67886
plot_mass_ratio_history_comparison(
    mass_and_msc_cmp;
    time_bin_size = time_bin_size,
    title = "Particle filter vs MSC posterior mass ratio"
)

# ╔═╡ 74e366ec-8f05-4235-a4e7-b4e17725ee21
plot_capsule_activation_history(
    mass_and_msc_cmp;
    title = "MSC capsule activation history"
)

# ╔═╡ d5995f77-6cf6-4867-b21d-72febed2fb8e
plot_capsule_flame_graph(
    mass_and_msc_cmp;
    title = "MSC capsule flame graph"
)

# ╔═╡ Cell order:
# ╠═9f5b47fc-1f86-4e7d-8fd0-1600866ef6d5
# ╠═a62867f7-cad0-443b-9135-58cdd6561e06
# ╠═109177a5-67d9-42b4-8db0-23c9c929894f
# ╠═b9a22540-5d70-47dd-8398-1c8878eef1fb
# ╠═091847d1-a86d-4664-9262-f85436e67886
# ╠═74e366ec-8f05-4235-a4e7-b4e17725ee21
# ╠═d5995f77-6cf6-4867-b21d-72febed2fb8e
