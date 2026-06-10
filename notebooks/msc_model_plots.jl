### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 9f5b47fc-1f86-4e7d-8fd0-1600866ef6d5
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using Plots
    using Gen
end

# ╔═╡ a62867f7-cad0-443b-9135-58cdd6561e06
begin
    selected_models = [:particle_filter, :msc]
    T = 100
    particles = 20
    rejuv_moves = 1
    true_mass_ratio = 4.0
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

# ╔═╡ 2f029d12-2c25-42ec-b089-db8a6733165c
begin
    using Statistics 
    
    time_window = 50:70

    msc_result = only(filter(r -> r.key == :msc, mass_and_msc_cmp.results))

    ts = Int[]
    active_mean_scores = Float64[]
    inactive_mean_scores = Float64[]

    for h in msc_result.history
        t = Int(h.t)
        t in time_window || continue

        active_scores = Float64[]
        inactive_scores = Float64[]

        for tr in h.traces
            score = Gen.get_score(tr)
            capsules = get_retval(tr)[t].capsules

            if isempty(capsules)
                push!(inactive_scores, score)
            else
                push!(active_scores, score)
            end
        end

        push!(ts, t)
        push!(active_mean_scores, isempty(active_scores) ? NaN : mean(active_scores))
        push!(inactive_mean_scores, isempty(inactive_scores) ? NaN : mean(inactive_scores))
    end

    plot(
        ts,
        active_mean_scores;
        label = "active capsule",
        xlabel = "time",
        ylabel = "mean particle log score",
        lw = 3,
        marker = :circle
    )
    plot!(
        ts,
        inactive_mean_scores;
        label = "no active capsule",
        lw = 3,
        marker = :circle
    )
end

# ╔═╡ 091847d1-a86d-4664-9262-f85436e67886
plot_mass_ratio_history_comparison(
    mass_and_msc_cmp;
    time_bin_size = time_bin_size,
    title = "Particle filter vs MSC posterior mass ratio"
)

# ╔═╡ b81746d1-128a-418d-826a-694d1e9d4cc9
begin
    collision_time = mass_and_msc_cmp.collision_time
        println("collision time = ", collision_time)
        collision_time
end

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
# ╠═2f029d12-2c25-42ec-b089-db8a6733165c
# ╠═091847d1-a86d-4664-9262-f85436e67886
# ╠═b81746d1-128a-418d-826a-694d1e9d4cc9
# ╠═74e366ec-8f05-4235-a4e7-b4e17725ee21
# ╠═d5995f77-6cf6-4867-b21d-72febed2fb8e
