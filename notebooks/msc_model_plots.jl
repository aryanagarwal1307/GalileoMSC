### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ 9f5b47fc-1f86-4e7d-8fd0-1600866ef6d5
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using Revise
    using GalileoMSC
    using Plots
    using PlutoUI
    using Gen
end

# ╔═╡ a62867f7-cad0-443b-9135-58cdd6561e06
begin
    selected_models = [:particle_filter, :msc]
    T = 120
    particles = 20
    rejuv_moves = 1
    true_mass_ratio = 1.8
    time_bin_size = 10
    rng_seed = 11
end

# ╔═╡ 109177a5-67d9-42b4-8db0-23c9c929894f
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = (0.3, 0.3),
    obj_positions = (0.5, 1.5)
);

# ╔═╡ 4a1a9a03-6e00-4e8c-8d52-fd8277af218e
begin
    Revise.revise()

    common_jl = joinpath(dirname(pathof(GalileoMSC)), "common.jl")
    lines = readlines(common_jl)
    prior_line = strip(lines[findfirst(line -> occursin("mass ~", line), lines)])

    println("GalileoMSC loaded from: ", pathof(GalileoMSC))
    println("Prior mass draw: ", prior_line)
end

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

# ╔═╡ 8678d0a3-f37e-4391-937e-058a3e794052
plot_mass_ratio_variance_comparison(
    mass_and_msc_cmp;
    time_bin_size = time_bin_size,
    title = "Particle filter vs MSC posterior variance"
)

# ╔═╡ de13c5a2-f8c7-4eb0-a218-d990718fc9a6
md"""
## Particle trajectory debugger

The x-z side view follows the ramp/collision plane. Dark blue and orange are
the two true objects; light blue and light orange are their respective MSC
particle predictions. Before collision the predictions usually overlap because
the candidate masses have not yet produced different collision outcomes.
"""

# ╔═╡ f3808d50-4d33-4f8a-8aa7-f55093072774
begin
    true_trajectory = mass_and_msc_cmp.true_trace
    particle_trajectories = msc_result.history
    particle_scene_T = length(particle_trajectories)
    particle_scene_axes = particle_scene_limits(true_trajectory, particle_trajectories)
end

# ╔═╡ 5fdedfff-8c7e-42e7-b64e-55ad4b261578
md"""
Time: $(@bind particle_scene_t Slider(1:particle_scene_T; default=1, show_value=true))

Show particle predictions: $(@bind show_particles CheckBox(default=true))
"""

# ╔═╡ c5e8d9ec-e79f-49f0-85d1-50c0cd671a90
draw_scene_svg(
    true_trajectory,
    particle_trajectories,
    particle_scene_t;
    show_particles=show_particles,
    limits=particle_scene_axes,
    collision_time=collision_time,
)

# ╔═╡ 77374e9f-b4fd-4b74-8b76-d6a7ba5a8ed2
# ╠═╡ disabled = true
#=╠═╡
save_particle_scene_gif(
    "/tmp/msc_particle_scene.gif", # replace with your output path
    true_trajectory,
    particle_trajectories;
    fps=10,
    show_particles=true,
    limits=particle_scene_axes,
    collision_time=collision_time,
)
  ╠═╡ =#

# ╔═╡ 3ab8ee7b-61f8-4650-aaf5-19e140f5abf0
begin
    true_positions = true_positions_from_trace(mass_and_msc_cmp.true_trace)
    time_to_show = 62
    visualize_scene(
        scene;
        positions=true_positions,
        frame=time_to_show,
        title="True scene at T=$time_to_show",
    )
end

# ╔═╡ Cell order:
# ╠═9f5b47fc-1f86-4e7d-8fd0-1600866ef6d5
# ╠═a62867f7-cad0-443b-9135-58cdd6561e06
# ╠═109177a5-67d9-42b4-8db0-23c9c929894f
# ╠═4a1a9a03-6e00-4e8c-8d52-fd8277af218e
# ╠═b9a22540-5d70-47dd-8398-1c8878eef1fb
# ╠═2f029d12-2c25-42ec-b089-db8a6733165c
# ╠═091847d1-a86d-4664-9262-f85436e67886
# ╠═b81746d1-128a-418d-826a-694d1e9d4cc9
# ╠═74e366ec-8f05-4235-a4e7-b4e17725ee21
# ╠═d5995f77-6cf6-4867-b21d-72febed2fb8e
# ╠═8678d0a3-f37e-4391-937e-058a3e794052
# ╟─de13c5a2-f8c7-4eb0-a218-d990718fc9a6
# ╠═f3808d50-4d33-4f8a-8aa7-f55093072774
# ╟─5fdedfff-8c7e-42e7-b64e-55ad4b261578
# ╠═c5e8d9ec-e79f-49f0-85d1-50c0cd671a90
# ╠═77374e9f-b4fd-4b74-8b76-d6a7ba5a8ed2
# ╠═3ab8ee7b-61f8-4650-aaf5-19e140f5abf0
