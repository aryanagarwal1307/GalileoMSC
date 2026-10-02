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

# ╔═╡ 0a5df1d8-4b68-4d52-a5e5-05ee26c93db1
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using Revise
    using GalileoMSC

    using LinearAlgebra
    using PhySMC
    using Plots
    using PlutoUI
    using Printf
end

# ╔═╡ b56e82db-c569-473a-82d6-93bb0c7ab56d
md"""
# Collision Geometry Diagnostics

Small diagnostic for one fixed ramp scene. The notebook first shows the motion, then inspects the collision helper signals used by the capsule birth predicate.

**AABB** means axis-aligned bounding box. **TTC** means time to contact. **MSC** refers to the GalileoMSC collision-capsule model.
"""

# ╔═╡ f3a6d42e-2317-4485-89c3-0fbb6dd0c9d8
begin
    T = 120
    true_mass_ratio = 1.5
    obj_frictions = (0.05, 0.2)
    obj_positions = (0.5, 1.5)
    slope = 0.5
    tableRampIntersection = 0.0
    restitution = DEFAULT_SCENE_RESTITUTION
    distance_threshold = 0.25
    aabb_contact_eps = 1e-9
    msc_params = DEFAULT_MSC_PARAMS
    diagnostic_log_radius = 8
end

# ╔═╡ 3f1b59bd-b7d1-48c3-8788-a61c19c4070b
scene = create_ramp_simulation(
    mass_ratio = true_mass_ratio,
    obj_frictions = obj_frictions,
    obj_positions = obj_positions,
    slope = slope,
    tableRampIntersection = tableRampIntersection,
    restitution = restitution,
);

# ╔═╡ 7d9230c5-8226-4ab0-9f4b-fcfc805f2614
begin
    Revise.revise()

    (
        package = pathof(GalileoMSC),
        steps = T,
        mass_ratio = true_mass_ratio,
        frictions = obj_frictions,
        slope = slope,
        restitution = scene.metadata.restitution,
    )
end

# ╔═╡ 68ebd0c4-265a-4312-826d-6e3171f8b0de
md"""
## Diagnostic Helpers

The helper code below simulates the exact scene above once and records the values returned by `collision_helper`. The AABB gap and AABB-normal closing speed should describe the same separating geometry.
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

    function tau_string(tau)
        return isfinite(tau) ? @sprintf("%.4f", tau) : "NaN"
    end

    function closest_aabb_points(aabb_a, aabb_b)
        a_min, a_max = aabb_a
        b_min, b_max = aabb_b

        function axis_points(a_lo, a_hi, b_lo, b_hi)
            a_hi < b_lo && return (a_hi, b_lo)
            b_hi < a_lo && return (a_lo, b_hi)
            midpoint = (max(a_lo, b_lo) + min(a_hi, b_hi)) / 2
            return (midpoint, midpoint)
        end

        axis_pairs = ntuple(axis -> axis_points(a_min[axis], a_max[axis], b_min[axis], b_max[axis]), 3)
        point_a = [axis_pairs[axis][1] for axis in 1:3]
        point_b = [axis_pairs[axis][2] for axis in 1:3]
        return point_a, point_b
    end

    function rounded_aabb_outline(aabb, radius::Real; points_per_corner::Int=10)
        a_min, a_max = aabb
        x_min, x_max = a_min[1], a_max[1]
        z_min, z_max = a_min[3], a_max[3]
        corners = (
            (x_max, z_min, -pi / 2, 0.0),
            (x_max, z_max, 0.0, pi / 2),
            (x_min, z_max, pi / 2, pi),
            (x_min, z_min, pi, 3pi / 2),
        )

        xs = Float64[]
        zs = Float64[]
        for (corner_x, corner_z, angle_start, angle_stop) in corners
            for angle in range(angle_start, angle_stop; length=points_per_corner)
                push!(xs, corner_x + radius * cos(angle))
                push!(zs, corner_z + radius * sin(angle))
            end
        end
        push!(xs, first(xs))
        push!(zs, first(zs))
        return xs, zs
    end

    function draw_aabb_outline!(plot_handle, aabb; label, color)
        a_min, a_max = aabb
        xs = [a_min[1], a_max[1], a_max[1], a_min[1], a_min[1]]
        zs = [a_min[3], a_min[3], a_max[3], a_max[3], a_min[3]]
        plot!(plot_handle, xs, zs; label=label, color=color, lw=2.5, ls=:dash)
        return plot_handle
    end

    function collision_scene_plot(scene, state, params::MSCParams;
                                  frame::Int,
                                  title::AbstractString,
                                  show_metrics::Bool=true,
                                  show_legend::Bool=true)
        dynamic_indices = dynamic_object_indices(state)
        a, b = dynamic_indices[1], dynamic_indices[2]
        ka = state.kinematics[a]
        kb = state.kinematics[b]
        helper = GalileoMSC.collision_helper(state, a, b, params)
        positions = [[collect(state.kinematics[index].position) for index in dynamic_indices]]

        display_v_closing = abs(helper.v_closing) < 5e-4 ? 0.0 : helper.v_closing
        ttc_label = isfinite(helper.tau) ? @sprintf("%.3f s", helper.tau) : "not defined"
        plot_title = show_metrics ? @sprintf(
                "%s\nAABB gap %.3f m | closing speed %.3f m/s | TTC %s",
                title,
                helper.gap,
                display_v_closing,
                ttc_label,
            ) : title
        plot_handle = visualize_scene(
            scene;
            positions=positions,
            frame=1,
            title=plot_title,
        )

        draw_aabb_outline!(plot_handle, ka.aabb; label="ramp-object AABB", color=:navy)
        draw_aabb_outline!(plot_handle, kb.aabb; label="table-object AABB", color=:darkred)

        gate_xs, gate_zs = rounded_aabb_outline(ka.aabb, params.birth_gap_max)
        plot!(
            plot_handle,
            gate_xs,
            gate_zs;
            label=@sprintf("gap-gate midpoint (%.2f m)", params.birth_gap_max),
            color=:darkgreen,
            lw=2,
            ls=:dot,
        )

        point_a, point_b = closest_aabb_points(ka.aabb, kb.aabb)
        if helper.separated
            plot!(
                plot_handle,
                [point_a[1], point_b[1]],
                [point_a[3], point_b[3]];
                label="shortest AABB separation",
                color=:black,
                lw=3,
                arrow=true,
            )
            scatter!(plot_handle, [point_a[1], point_b[1]], [point_a[3], point_b[3]];
                     label="", color=:black, ms=4)
        else
            scatter!(plot_handle, [point_a[1]], [point_a[3]];
                     label="AABB contact/overlap", color=:black, marker=:diamond, ms=6)
        end

        velocity_scale = 0.15
        quiver!(
            plot_handle,
            [ka.position[1]],
            [ka.position[3]];
            quiver=([velocity_scale * ka.linear_vel[1]], [velocity_scale * ka.linear_vel[3]]),
            label="ramp velocity x 0.15 s",
            color=:navy,
            lw=2,
        )
        quiver!(
            plot_handle,
            [kb.position[1]],
            [kb.position[3]];
            quiver=([velocity_scale * kb.linear_vel[1]], [velocity_scale * kb.linear_vel[3]]),
            label="table velocity x 0.15 s",
            color=:darkred,
            lw=2,
        )

        plot!(
            plot_handle;
            legend=show_legend ? :topright : false,
            legendfontsize=8,
            titlefontsize=11,
            size=(1000, 520),
        )

        return plot_handle
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
                helper_normal = helper.normal,
                helper_separated = helper.separated,
                helper_v_closing = helper.v_closing,
                helper_tau = helper.tau,
                helper_p_gap = helper.p_gap,
                helper_p_closing = helper.p_closing,
                helper_p_ttc = helper.p_ttc,
                helper_birth_prob = helper.birth_prob,
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

    function three_frame_scene_plot(scene, states, middle_frame::Int, params::MSCParams;
                                    middle_label::AbstractString)
        initial_plot = collision_scene_plot(
            scene,
            scene.init_state,
            params;
            frame=0,
            title="Initial (t=0)",
            show_metrics=false,
            show_legend=false,
        )
        middle_plot = collision_scene_plot(
            scene,
            states[middle_frame],
            params;
            frame=middle_frame,
            title="$(middle_label) (t=$(middle_frame))",
            show_metrics=false,
            show_legend=false,
        )
        final_frame = length(states)
        final_plot = collision_scene_plot(
            scene,
            states[final_frame],
            params;
            frame=final_frame,
            title="Final (t=$(final_frame))",
            show_metrics=false,
            show_legend=false,
        )

        return plot(initial_plot, middle_plot, final_plot; layout = (1, 3), size = (1200, 360))
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
    tau_values = [isfinite(row.helper_tau) ? row.helper_tau : NaN for row in diagnostic_rows]

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
    true_collision_frame = first_aabb_contact_time === nothing ? closest_center_time : first_aabb_contact_time
    precontact_frame = max(firstindex(diagnostic_rows), true_collision_frame - 1)

    (
        center_distance_threshold_frame = center_threshold_collision_time,
        closest_center_frame = closest_center_time,
        first_aabb_birth_window_frame = first_aabb_window_time,
        first_aabb_contact_frame = first_aabb_contact_time,
        diagnostic_collision_frame = true_collision_frame,
        precontact_frame = precontact_frame,
    )
end

# ╔═╡ 4b696a9f-bbdb-4f6f-acdc-f9d00361f710
md"""
## 1. Sliding Scene View

Use the slider to inspect the simulated x-z side view. Solid shapes are the scene geometry; dashed rectangles are the exact **AABBs** used by the predicate. The dotted green border is where the gap gate reaches its midpoint, and the black arrow is the shortest separating vector. Velocity arrows show 0.15 seconds of motion at the current velocity.
"""

# ╔═╡ 78afe1f7-66b7-4e51-b6de-681f70667c28
md"""
Timestep: $(@bind diagnostic_scene_t Slider(1:size(trajectory.positions, 1); default=true_collision_frame, show_value=true))
"""

# ╔═╡ 9c2f2b2f-12fe-4029-990e-d23f7fd8a499
collision_scene_plot(
    scene,
    trajectory.states[diagnostic_scene_t],
    msc_params;
    frame=diagnostic_scene_t,
    title="Collision geometry at t=$(diagnostic_scene_t)",
)

# ╔═╡ 3dbf92f7-f971-4adc-a8ef-4d7f7d27e4df
md"""
### Bullet 3D Camera

This is Bullet's own rendered scene with an independent timeline, so 3D rendering does not slow down the 2D slider. Drag the timeline or use play/pause to render successive stored timesteps. The off-screen renderer is used because the native Bullet GUI is a separate window and cannot be embedded directly in Pluto.

3D timeline: $(@bind bullet_scene_t ScenePlaybackSlider(length(trajectory.states); default=true_collision_frame, fps=6))

Camera yaw: $(@bind bullet_camera_yaw Slider(-45:5:45; default=0, show_value=true))

Camera pitch: $(@bind bullet_camera_pitch Slider(-60:5:-20; default=-35, show_value=true))
"""

# ╔═╡ ebd06af6-7897-4c99-a130-e29d52033d46
bullet_camera_plot(
    scene,
    trajectory.states[bullet_scene_t];
    frame=bullet_scene_t,
    yaw=bullet_camera_yaw,
    pitch=bullet_camera_pitch,
)

# ╔═╡ 7dbfc45f-fd8d-4588-97d9-c45533d6df50
md"""
## 2. Static View Panel

These three snapshots show the initial state, the diagnostic contact frame, and the final state using the same scene trajectory.
"""

# ╔═╡ bb724048-2736-4d32-afba-ab9e37b4f2e1
three_frame_scene_plot(
    scene,
    trajectory.states,
    true_collision_frame,
    msc_params;
    middle_label = "AABB contact",
)

# ╔═╡ 44d597ec-cb93-4570-81cf-b3ed139ec157
md"""
## 3. Collision Helper Signals

The birth predicate combines three gates: AABB gap, AABB-normal closing speed, and TTC. The final birth score is their product with `birth_base`.
"""

# ╔═╡ c99db741-8716-41b0-87be-a0ef2d2c0158
begin
    function helper_snapshot(row)
        return (
            frame = row.t,
            center_distance = round(row.center_distance, digits = 4),
            aabb_gap = round(row.aabb_distance, digits = 4),
            helper_gap = round(row.helper_surface_gap, digits = 4),
            helper_normal = Tuple(round.(row.helper_normal, digits = 4)),
            separated = row.helper_separated,
            closing_speed = round(row.helper_v_closing, digits = 4),
            time_to_contact = rounded_tau(row.helper_tau),
            gap_gate = round(row.helper_p_gap, digits = 4),
            closing_speed_gate = round(row.helper_p_closing, digits = 4),
            time_to_contact_gate = round(row.helper_p_ttc, digits = 4),
            birth_score = round(row.helper_birth_prob, digits = 6),
        )
    end

    (
        precontact = helper_snapshot(diagnostic_rows[precontact_frame]),
        contact = helper_snapshot(diagnostic_rows[true_collision_frame]),
    )
end

# ╔═╡ 776b4551-2ca1-4939-89eb-af0ad77e3e94
begin
    gap_plot = plot(
        ts,
        aabb_distances;
        label = "AABB surface gap",
        xlabel = "time step",
        ylabel = "meters",
        title = "Axis-aligned bounding-box gap",
        lw = 3,
    )
    hline!(gap_plot, [0.0]; label = "touching or overlapping", lw = 2, ls = :dash)
    hline!(gap_plot, [msc_params.birth_gap_max]; label = "birth close-gap threshold", lw = 2, ls = :dash)
    vline!(gap_plot, [true_collision_frame]; label = "AABB contact frame", lw = 2, ls = :dot)

    closing_plot = plot(
        ts,
        [row.helper_v_closing for row in diagnostic_rows];
        label = "AABB-normal closing speed",
        xlabel = "time step",
        ylabel = "meters / second",
        title = "Closing speed along shortest AABB separation",
        lw = 3,
    )
    hline!(closing_plot, [msc_params.birth_v_min]; label = "minimum closing speed", lw = 2, ls = :dash)
    hline!(closing_plot, [0.0]; label = "not closing", lw = 1, ls = :dot)
    vline!(closing_plot, [true_collision_frame]; label = "AABB contact frame", lw = 2, ls = :dot)

    ttc_plot = plot(
        ts,
        tau_values;
        label = "time to contact",
        xlabel = "time step",
        ylabel = "seconds",
        title = "TTC from AABB gap / closing speed",
        lw = 3,
    )
    hline!(ttc_plot, [msc_params.birth_T_contact]; label = "birth contact horizon", lw = 2, ls = :dash)
    vline!(ttc_plot, [true_collision_frame]; label = "AABB contact frame", lw = 2, ls = :dot)

    gate_plot = plot(
        ts,
        [row.helper_p_gap for row in diagnostic_rows];
        label = "gap gate",
        xlabel = "time step",
        ylabel = "score",
        title = "Birth predicate gates and final birth score",
        lw = 3,
        ylim = (-0.02, 1.02),
    )
    plot!(gate_plot, ts, [row.helper_p_closing for row in diagnostic_rows]; label = "closing-speed gate", lw = 3)
    plot!(gate_plot, ts, [row.helper_p_ttc for row in diagnostic_rows]; label = "time-to-contact gate", lw = 3)
    plot!(gate_plot, ts, [row.helper_birth_prob for row in diagnostic_rows]; label = "birth score", lw = 3)
    vline!(gate_plot, [true_collision_frame]; label = "AABB contact frame", lw = 2, ls = :dot)

    plot(gap_plot, closing_plot, ttc_plot, gate_plot; layout = (4, 1), size = (950, 950))
end

# ╔═╡ f8a53dc6-313a-459a-ac8e-426a40e48e08
md"""
## 4. Local Birth Window

This compact log shows the raw helper values around contact. The gate columns are the smooth scores multiplied to form the birth score.
"""

# ╔═╡ ecaeb586-9533-4bdb-b5cf-d727535851f2
begin
    function log_birth_predicate_window(rows, collision_frame::Int; radius::Int=8)
        window_start = max(firstindex(rows), collision_frame - radius)
        window_stop = min(lastindex(rows), collision_frame + radius)

        println("Collision helper window: t=$(window_start):$(window_stop), AABB contact t=$(collision_frame)")
        println(" t   AABB_gap  closing_speed       TTC  gap_gate  closing_gate  TTC_gate  birth_score")

        for t in window_start:window_stop
            row = rows[t]
            @printf(
                "%3d %10.4f %14.4f %9s %9.3f %13.3f %9.3f %12.6f\n",
                t,
                row.aabb_distance,
                row.helper_v_closing,
                tau_string(row.helper_tau),
                row.helper_p_gap,
                row.helper_p_closing,
                row.helper_p_ttc,
                row.helper_birth_prob,
            )
        end
    end

    log_birth_predicate_window(
        diagnostic_rows,
        true_collision_frame;
        radius = diagnostic_log_radius,
    )
end

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
# ╟─4b696a9f-bbdb-4f6f-acdc-f9d00361f710
# ╟─78afe1f7-66b7-4e51-b6de-681f70667c28
# ╠═9c2f2b2f-12fe-4029-990e-d23f7fd8a499
# ╟─3dbf92f7-f971-4adc-a8ef-4d7f7d27e4df
# ╠═ebd06af6-7897-4c99-a130-e29d52033d46
# ╟─7dbfc45f-fd8d-4588-97d9-c45533d6df50
# ╠═bb724048-2736-4d32-afba-ab9e37b4f2e1
# ╟─44d597ec-cb93-4570-81cf-b3ed139ec157
# ╠═c99db741-8716-41b0-87be-a0ef2d2c0158
# ╠═776b4551-2ca1-4939-89eb-af0ad77e3e94
# ╟─f8a53dc6-313a-459a-ac8e-426a40e48e08
# ╠═ecaeb586-9533-4bdb-b5cf-d727535851f2
