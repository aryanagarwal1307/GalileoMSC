### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 0a5df1d8-4b68-4d52-a5e5-05ee26c93db1
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using Revise
    using GalileoMSC
    using LinearAlgebra
    using PhySMC
    using Plots
    using Statistics
end

# ╔═╡ b56e82db-c569-473a-82d6-93bb0c7ab56d
md"""
# Collision Geometry Diagnostics

This notebook checks two related geometry signals:

1. The collision marker used in plots: `detect_collision_time`, which scans object positions and returns the first timestep where center-to-center distance is below a threshold.
2. The MSC collision helper and AABB distance, which use richer geometry features during capsule birth/survival scoring.
"""

# ╔═╡ f3a6d42e-2317-4485-89c3-0fbb6dd0c9d8
begin
    T = 120
    true_mass_ratio = 2.5
    obj_frictions = (0.3, 0.3)
    obj_positions = (0.5, 1.5)
    distance_threshold = 0.25
    aabb_contact_eps = 1e-9
    msc_params = DEFAULT_MSC_PARAMS
end

# ╔═╡ 3f1b59bd-b7d1-48c3-8788-a61c19c4070b
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = obj_frictions,
    obj_positions = obj_positions,
);

# ╔═╡ 7d9230c5-8226-4ab0-9f4b-fcfc805f2614
begin
    Revise.revise()

    println("GalileoMSC loaded from: ", pathof(GalileoMSC))
    println("T = ", T)
    println("center-distance collision threshold = ", distance_threshold)
end

# ╔═╡ 68ebd0c4-265a-4312-826d-6e3171f8b0de
md"""
## Helper Functions

`collision_helper` uses the two object centers to compute Euclidean distance. It then subtracts bounding-sphere radii from `MSCParams.obj_dims` to get a surface gap:

`gap = center_distance - (radius_a + radius_b)`

The plot collision marker is different: `detect_collision_time` returns the first timestep where center distance is below `distance_threshold`.
"""

# ╔═╡ c0e9f94d-0575-4de4-8efd-1cc501dfe290
begin
    function observed_positions_from_array(positions)
        return [[vec(positions[t, 1, :]), vec(positions[t, 2, :])] for t in axes(positions, 1)]
    end

    function first_time(rows, predicate)
        for row in rows
            predicate(row) && return row.t
        end
        return nothing
    end

    function rounded_tau(tau)
        return isfinite(tau) ? round(tau, digits = 4) : tau
    end

    function simulate_scene_diagnostics(scene, T::Int, params::MSCParams)
        states = Vector{Any}(undef, T)
        dynamic_indices = dynamic_object_indices(scene.init_state)
        positions = Array{Float64}(undef, T, length(dynamic_indices), 3)
        rows = Vector{NamedTuple}(undef, T)
        state = scene.init_state
        a = dynamic_indices[1]
        b = dynamic_indices[2]

        for t in 1:T
            state = PhySMC.step(scene.sim, state)
            states[t] = state

            pos1 = vec(state.kinematics[a].position)
            pos2 = vec(state.kinematics[b].position)
            positions[t, 1, :] .= pos1
            positions[t, 2, :] .= pos2

            helper = GalileoMSC.collision_helper(state, a, b, params)
            aabb_distance = GalileoMSC.bounding_box_distance(
                state.kinematics[a].aabb,
                state.kinematics[b].aabb,
            )

            rows[t] = (
                t = t,
                center_distance = norm(pos2 .- pos1),
                helper_distance = helper.distance,
                helper_surface_gap = helper.gap,
                helper_v_closing = helper.v_closing,
                helper_tau = helper.tau,
                helper_p_gap = helper.p_gap,
                helper_p_closing = helper.p_closing,
                helper_p_ttc = helper.p_ttc,
                helper_birth_prob = helper.birth_prob,
                helper_near_score = helper.near_score,
                aabb_distance = aabb_distance,
            )
        end

        return (
            states = states,
            positions = positions,
            observed_positions = observed_positions_from_array(positions),
            diagnostics = rows,
        )
    end
end

# ╔═╡ 09fd8360-cf44-4ae0-a9f0-0177d88fb414
trajectory = simulate_scene_diagnostics(scene, T, msc_params);

# ╔═╡ e4e17f5e-b108-48f6-9206-10e85fca98f6
begin
    diagnostic_rows = trajectory.diagnostics
    ts = [row.t for row in diagnostic_rows]
    center_distances = [row.center_distance for row in diagnostic_rows]
    aabb_distances = [row.aabb_distance for row in diagnostic_rows]

    center_threshold_collision_time = detect_collision_time(
        trajectory.observed_positions;
        threshold = distance_threshold,
    )

    closest_center_time = diagnostic_rows[argmin(center_distances)].t
    first_aabb_contact_time = first_time(
        diagnostic_rows,
        row -> row.aabb_distance <= aabb_contact_eps,
    )
    first_aabb_window_time = first_time(
        diagnostic_rows,
        row -> row.aabb_distance <= msc_params.birth_aabb_window,
    )

    calculated_collision_frame = if center_threshold_collision_time === nothing
        closest_center_time
    else
        center_threshold_collision_time
    end

    aabb_collision_frame = if first_aabb_contact_time === nothing
        calculated_collision_frame
    else
        first_aabb_contact_time
    end

    (
        center_threshold_collision_time = center_threshold_collision_time,
        plotted_collision_frame = calculated_collision_frame,
        closest_center_time = closest_center_time,
        first_aabb_window_time = first_aabb_window_time,
        first_aabb_contact_time = first_aabb_contact_time,
        birth_aabb_window = msc_params.birth_aabb_window,
        aabb_contact_or_collision_frame = aabb_collision_frame,
    )
end

# ╔═╡ 44d597ec-cb93-4570-81cf-b3ed139ec157
md"""
## (i) Center Distance and Collision Helper

The vertical collision marker in the existing history plots comes from the center-distance threshold above. The helper values below show what the MSC birth code sees at that same time: center distance, sphere-based surface gap, closing velocity, time-to-contact, gate scores, and AABB distance.
"""

# ╔═╡ c99db741-8716-41b0-87be-a0ef2d2c0158
begin
    collision_row = diagnostic_rows[calculated_collision_frame]

    (
        t = collision_row.t,
        center_threshold = distance_threshold,
        center_distance = round(collision_row.center_distance, digits = 4),
        helper_distance = round(collision_row.helper_distance, digits = 4),
        helper_surface_gap = round(collision_row.helper_surface_gap, digits = 4),
        aabb_distance = round(collision_row.aabb_distance, digits = 4),
        helper_v_closing = round(collision_row.helper_v_closing, digits = 4),
        helper_tau = rounded_tau(collision_row.helper_tau),
        helper_birth_prob = round(collision_row.helper_birth_prob, digits = 6),
        helper_near_score = round(collision_row.helper_near_score, digits = 4),
    )
end

# ╔═╡ 776b4551-2ca1-4939-89eb-af0ad77e3e94
begin
    distance_plot = plot(
        ts,
        center_distances;
        label = "center distance",
        xlabel = "time",
        ylabel = "distance",
        title = "Collision marker distance",
        lw = 3,
    )
    hline!(distance_plot, [distance_threshold]; label = "detect threshold", lw = 2, ls = :dash)
    vline!(distance_plot, [calculated_collision_frame]; label = "calculated collision", lw = 2, ls = :dot)

    helper_gap_plot = plot(
        ts,
        [row.helper_surface_gap for row in diagnostic_rows];
        label = "helper sphere surface gap",
        xlabel = "time",
        ylabel = "distance",
        title = "Helper geometry distances",
        lw = 3,
    )
    plot!(
        helper_gap_plot,
        ts,
        aabb_distances;
        label = "AABB distance",
        lw = 3,
    )
    hline!(helper_gap_plot, [0.0]; label = "contact/overlap", lw = 2, ls = :dash)
    vline!(helper_gap_plot, [calculated_collision_frame]; label = "calculated collision", lw = 2, ls = :dot)

    plot(distance_plot, helper_gap_plot; layout = (2, 1), size = (900, 650))
end

# ╔═╡ 52b69ff4-55b6-4681-937b-adfac728e14c
begin
    helper_gate_plot = plot(
        ts,
        [row.helper_p_gap for row in diagnostic_rows];
        label = "p_gap",
        xlabel = "time",
        ylabel = "probability / score",
        title = "MSC collision helper gates",
        lw = 3,
        ylim = (-0.02, 1.02),
    )
    plot!(helper_gate_plot, ts, [row.helper_p_closing for row in diagnostic_rows]; label = "p_closing", lw = 3)
    plot!(helper_gate_plot, ts, [row.helper_p_ttc for row in diagnostic_rows]; label = "p_ttc", lw = 3)
    plot!(helper_gate_plot, ts, [row.helper_birth_prob for row in diagnostic_rows]; label = "birth_prob", lw = 3)
    vline!(helper_gate_plot, [calculated_collision_frame]; label = "calculated collision", lw = 2, ls = :dot)
    helper_gate_plot
end

# ╔═╡ 7dbfc45f-fd8d-4588-97d9-c45533d6df50
begin
    function three_frame_scene_plot(scene, positions, middle_frame::Int; middle_label::AbstractString)
        initial_plot = visualize_scene(scene; title = "initial setup (t=0)")
        middle_plot = visualize_scene(
            scene;
            positions = positions,
            frame = middle_frame,
            title = "$(middle_label) (t=$(middle_frame))",
        )
        final_plot = visualize_scene(
            scene;
            positions = positions,
            frame = size(positions, 1),
            title = "final simulated frame (t=$(size(positions, 1)))",
        )

        return plot(initial_plot, middle_plot, final_plot; layout = (1, 3), size = (1200, 360))
    end

    three_frame_scene_plot(
        scene,
        trajectory.positions,
        calculated_collision_frame;
        middle_label = "center-threshold collision",
    )
end

# ╔═╡ f8a53dc6-313a-459a-ac8e-426a40e48e08
md"""
## (ii) Bounding Box Distance

`bounding_box_distance` computes the shortest separation between the two axis-aligned bounding boxes stored in each object's kinematics. It is zero when the AABBs touch or overlap.

The MSC birth weighting code uses `birth_aabb_window` as an early gate. If AABB distance is larger than that window, the pair gets only the background candidate weight.
"""

# ╔═╡ 02a8f5bc-ed54-42bd-9596-b96eb8d66321
begin
    aabb_row = diagnostic_rows[aabb_collision_frame]

    (
        birth_aabb_window = msc_params.birth_aabb_window,
        first_aabb_window_time = first_aabb_window_time,
        first_aabb_contact_time = first_aabb_contact_time,
        contact_or_collision_frame = aabb_collision_frame,
        aabb_distance_at_frame = round(aabb_row.aabb_distance, digits = 6),
        center_distance_at_frame = round(aabb_row.center_distance, digits = 4),
        helper_surface_gap_at_frame = round(aabb_row.helper_surface_gap, digits = 4),
    )
end

# ╔═╡ 78e8b958-e0e4-428b-bffc-a632e804a504
begin
    aabb_plot = plot(
        ts,
        aabb_distances;
        label = "AABB distance",
        xlabel = "time",
        ylabel = "distance",
        title = "Bounding box distance over time",
        lw = 3,
    )
    hline!(aabb_plot, [0.0]; label = "touching / overlapping", lw = 2, ls = :dash)
    hline!(aabb_plot, [msc_params.birth_aabb_window]; label = "birth AABB window", lw = 2, ls = :dash)
    vline!(aabb_plot, [calculated_collision_frame]; label = "center-threshold collision", lw = 2, ls = :dot)
    first_aabb_window_time === nothing ||
        vline!(aabb_plot, [first_aabb_window_time]; label = "first inside birth window", lw = 2, ls = :dash)
    first_aabb_contact_time === nothing ||
        vline!(aabb_plot, [first_aabb_contact_time]; label = "first AABB contact", lw = 2, ls = :dash)
    aabb_plot
end

# ╔═╡ bb724048-2736-4d32-afba-ab9e37b4f2e1
three_frame_scene_plot(
    scene,
    trajectory.positions,
    calculated_collision_frame;
    middle_label = "center-threshold collision",
)

# ╔═╡ Cell order:
# ╠═0a5df1d8-4b68-4d52-a5e5-05ee26c93db1
# ╟─b56e82db-c569-473a-82d6-93bb0c7ab56d
# ╠═f3a6d42e-2317-4485-89c3-0fbb6dd0c9d8
# ╠═3f1b59bd-b7d1-48c3-8788-a61c19c4070b
# ╠═7d9230c5-8226-4ab0-9f4b-fcfc805f2614
# ╟─68ebd0c4-265a-4312-826d-6e3171f8b0de
# ╠═c0e9f94d-0575-4de4-8efd-1cc501dfe290
# ╠═09fd8360-cf44-4ae0-a9f0-0177d88fb414
# ╠═e4e17f5e-b108-48f6-9206-10e85fca98f6
# ╟─44d597ec-cb93-4570-81cf-b3ed139ec157
# ╠═c99db741-8716-41b0-87be-a0ef2d2c0158
# ╠═776b4551-2ca1-4939-89eb-af0ad77e3e94
# ╠═52b69ff4-55b6-4681-937b-adfac728e14c
# ╠═7dbfc45f-fd8d-4588-97d9-c45533d6df50
# ╟─f8a53dc6-313a-459a-ac8e-426a40e48e08
# ╠═02a8f5bc-ed54-42bd-9596-b96eb8d66321
# ╠═78e8b958-e0e4-428b-bffc-a632e804a504
# ╠═bb724048-2736-4d32-afba-ab9e37b4f2e1
