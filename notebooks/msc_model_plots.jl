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
    using Statistics
end

# ╔═╡ a62867f7-cad0-443b-9135-58cdd6561e06
begin
    selected_models = [:particle_filter, :msc]
    T = 150
    particles = 20
    rejuv_moves = 1
    true_mass_ratio = 2.0
    obj_frictions = (0.05, 0.2)
    obj_positions = (0.5, 1.5)
    slope = 0.9
    tableRampIntersection = 0.0
    restitution = 0.5
    time_bin_size = 3
    rng_seed = 11
end

# ╔═╡ 109177a5-67d9-42b4-8db0-23c9c929894f
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = obj_frictions,
    obj_positions = obj_positions,
    slope = slope,
    tableRampIntersection = tableRampIntersection,
    restitution = restitution,
);

# ╔═╡ 4a1a9a03-6e00-4e8c-8d52-fd8277af218e
begin
    Revise.revise()

    (
        package = pathof(GalileoMSC),
        mass_ratio = scene.metadata.mass_ratio,
        frictions = scene.metadata.obj_frictions,
        positions = scene.metadata.obj_positions,
        slope = scene.metadata.slope,
        restitution = scene.metadata.restitution,
    )
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

# ╔═╡ 73b9f4f8-2820-4d75-ad41-4e31a23f58e6
begin
    function variance_rate_history(history, bin_size::Int)
        sorted_history = sort(collect(history); by=h -> h.t)
        isempty(sorted_history) && return NamedTuple[]

        variance_history = if bin_size <= 1
            [(t = Float64(h.t), variance = h.std^2) for h in sorted_history]
        else
            binned = NamedTuple[]
            first_t = minimum([h.t for h in sorted_history])
            last_t = maximum([h.t for h in sorted_history])

            for bin_start in first_t:bin_size:last_t
                bin_stop = bin_start + bin_size - 1
                rows = [h for h in sorted_history if bin_start <= h.t <= bin_stop]
                isempty(rows) && continue

                push!(binned, (
                    t = Float64(mean([h.t for h in rows])),
                    variance = mean([h.std^2 for h in rows])
                ))
            end

            binned
        end

        rates = NamedTuple[]
        for i in 2:length(variance_history)
            prev = variance_history[i - 1]
            curr = variance_history[i]
            dt = curr.t - prev.t
            dt == 0 && continue

            push!(rates, (
                t = (prev.t + curr.t) / 2,
                rate = (curr.variance - prev.variance) / dt
            ))
        end

        return rates
    end

    p = plot(
        xlabel = "time",
        ylabel = "variance change per step",
        title = "Posterior variance rate of change",
        legend = :topright
    )

    for item in mass_and_msc_cmp.results
        rates = variance_rate_history(item.history, time_bin_size)
        isempty(rates) && continue

        plot!(
            p,
            [r.t for r in rates],
            [r.rate for r in rates];
            label = item.label,
            lw = 3,
            marker = :circle,
            ms = 3
        )
    end

    hline!(p, [0.0]; label = "", color = :black, ls = :dot, lw = 1)

    if collision_time !== nothing
        vline!(p, [collision_time]; label = "collision time", lw = 2, ls = :dash)
    end

    p
end

# ╔═╡ ce9ce75e-9b12-4a98-a85a-e89ec3722d98
begin
    trace_inspection_t = clamp(
        collision_time === nothing ? length(msc_result.history) : collision_time,
        1,
        length(msc_result.history)
    )
    trace_inspection_particle = 1
    trace_to_inspect = msc_result.history[trace_inspection_t].traces[trace_inspection_particle]
    trace_inspection_state = Gen.get_retval(trace_to_inspect)[trace_inspection_t]

    (
        t = trace_inspection_t,
        particle = trace_inspection_particle,
        score = Gen.get_score(trace_to_inspect),
        checkpoint = (
            trace_inspection_state.last_clause_checkpoint_t,
            trace_inspection_state.last_clause_checkpoint_msc_id
        ),
        trace = trace_to_inspect,
        choices = Gen.get_choices(trace_to_inspect)
    )
end

# ╔═╡ de13c5a2-f8c7-4eb0-a218-d990718fc9a6
md"""
## Particle trajectory debugger

The x-z side view now uses the same static scene geometry as the collision
diagnostics. Dark blue and orange mark the two true object centres; light blue
and light orange are their respective MSC particle inferences. Before collision
the inferences usually overlap because the candidate masses have not yet
produced different collision outcomes.
"""

# ╔═╡ f3808d50-4d33-4f8a-8aa7-f55093072774
begin
    true_trajectory = mass_and_msc_cmp.true_trace
    particle_trajectories = msc_result.history
    particle_scene_T = length(particle_trajectories)
    particle_scene_default_t = collision_time === nothing ? 1 : collision_time
    particle_scene_axes = particle_scene_limits(
        true_trajectory,
        particle_trajectories;
        scene=scene,
    )
end

# ╔═╡ 5fdedfff-8c7e-42e7-b64e-55ad4b261578
md"""
Time: $(@bind particle_scene_t Slider(1:particle_scene_T; default=particle_scene_default_t, show_value=true))

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
    scene=scene,
)

# ╔═╡ 8026dd8e-18d8-4bbb-bd4e-05501378eb51
md"""
### Bullet 3D camera

This uses the same off-screen Bullet camera and playback control as the
collision-geometry notebook. The dark markers are the true object centres;
the lighter dots are the MSC particles projected through the same camera
matrices, so they remain registered while the camera moves.

3D timeline: $(@bind bullet_particle_scene_t ScenePlaybackSlider(particle_scene_T; default=particle_scene_default_t, fps=6))

Camera yaw: $(@bind bullet_particle_camera_yaw Slider(-45:5:45; default=0, show_value=true))

Camera pitch: $(@bind bullet_particle_camera_pitch Slider(-60:5:-20; default=-35, show_value=true))
"""

# ╔═╡ e38e9943-9f08-4106-9ab0-c3f309e52e21
begin
    bullet_particle_positions = particle_object_positions(
        particle_trajectories,
        bullet_particle_scene_t,
    )
    bullet_camera_plot(
        scene,
        get_retval(true_trajectory)[bullet_particle_scene_t];
        frame=bullet_particle_scene_t,
        particle_positions=bullet_particle_positions,
        show_particles=show_particles,
        yaw=bullet_particle_camera_yaw,
        pitch=bullet_particle_camera_pitch,
    )
end

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
    scene=scene,
)
  ╠═╡ =#

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
# ╠═73b9f4f8-2820-4d75-ad41-4e31a23f58e6
# ╠═ce9ce75e-9b12-4a98-a85a-e89ec3722d98
# ╟─de13c5a2-f8c7-4eb0-a218-d990718fc9a6
# ╠═f3808d50-4d33-4f8a-8aa7-f55093072774
# ╟─5fdedfff-8c7e-42e7-b64e-55ad4b261578
# ╠═c5e8d9ec-e79f-49f0-85d1-50c0cd671a90
# ╟─8026dd8e-18d8-4bbb-bd4e-05501378eb51
# ╠═e38e9943-9f08-4106-9ab0-c3f309e52e21
# ╠═77374e9f-b4fd-4b74-8b76-d6a7ba5a8ed2
