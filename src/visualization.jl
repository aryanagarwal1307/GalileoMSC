################################################################################
# Scene visualization
################################################################################

scene_metadata(scene) = hasproperty(scene, :metadata) ? scene.metadata : scene

function _rotated_box_shape(center_x::Real, center_z::Real, width::Real, height::Real, angle::Real)
    corners = [
        (-width / 2, -height / 2),
        ( width / 2, -height / 2),
        ( width / 2,  height / 2),
        (-width / 2,  height / 2)
    ]

    xs = Float64[]
    zs = Float64[]
    for (x, z) in corners
        push!(xs, center_x + x * cos(angle) - z * sin(angle))
        push!(zs, center_z + x * sin(angle) + z * cos(angle))
    end

    return Plots.Shape(xs, zs)
end

function _ramp_side_shape(metadata)
    x_min = metadata.ramp_position[1]
    x_max = x_min + metadata.ramp_dims[1]
    z_min = metadata.ramp_position[3]
    z_max = z_min + metadata.ramp_dims[3]
    return Plots.Shape([x_min, x_min, x_max], [z_min, z_max, z_min])
end

function _positions_at_frame(positions, frame::Int)
    if positions === nothing
        return nothing
    elseif positions isa AbstractArray && ndims(positions) == 3
        return [vec(positions[frame, i, :]) for i in axes(positions, 2)]
    else
        return positions[frame]
    end
end

function _draw_scene_base!(p, metadata)
    base_dims = metadata.base_dims
    table_dims = metadata.table_dims

    table_base = _rotated_box_shape(0.0, -(base_dims[3] + table_dims[3]) / 2, base_dims[1], base_dims[3], 0.0)
    table_top = _rotated_box_shape(0.0, -table_dims[3] / 2, table_dims[1], table_dims[3], 0.0)
    ramp = _ramp_side_shape(metadata)
    frame_thickness = 0.05
    frame_height = 0.25
    rail_x = metadata.table_dims[1] / 2 + frame_thickness / 2
    left_rail = _rotated_box_shape(-rail_x, 0.0, frame_thickness, frame_height, 0.0)
    right_rail = _rotated_box_shape(rail_x, 0.0, frame_thickness, frame_height, 0.0)

    Plots.plot!(p, table_base; label="", color=:gray65, linecolor=:gray35, alpha=0.8)
    Plots.plot!(p, table_top; label="", color=:gray80, linecolor=:gray35, alpha=0.9)
    Plots.plot!(p, ramp; label="", color=:white, linecolor=:black, alpha=0.95)
    Plots.plot!(p, left_rail; label="", color=:gray45, linecolor=:gray20, alpha=0.9)
    Plots.plot!(p, right_rail; label="", color=:gray45, linecolor=:gray20, alpha=0.9)
    return p
end

function _draw_scene_objects!(p, metadata, positions_at_frame)
    ramp_position = positions_at_frame === nothing ? metadata.obj_ramp_position : positions_at_frame[1]
    table_position = positions_at_frame === nothing ? metadata.obj_table_position : positions_at_frame[2]

    ramp_obj = _rotated_box_shape(
        ramp_position[1],
        ramp_position[3],
        metadata.obj_ramp_dims[1],
        metadata.obj_ramp_dims[3],
        positions_at_frame === nothing ? metadata.obj_ramp_orientation : 0.0
    )
    table_obj = _rotated_box_shape(
        table_position[1],
        table_position[3],
        metadata.obj_table_dims[1],
        metadata.obj_table_dims[3],
        metadata.obj_table_orientation
    )

    Plots.plot!(p, ramp_obj; label="ramp object", color=:steelblue, linecolor=:steelblue4, alpha=0.85)
    Plots.plot!(p, table_obj; label="table object", color=:darkorange, linecolor=:saddlebrown, alpha=0.85)
    return p
end

"""
Visualize a Galileo ramp scene in the x-z side view.

Pass `positions=simulate_scene_positions(scene, T)` and choose `frame` to draw
the objects at a simulated timestep. With no positions, the initial scene is
shown from the random or explicit `ramp` parameters.
"""
function visualize_scene(scene; positions=nothing, frame::Int=1, title::AbstractString="Galileo ramp scene")
    metadata = scene_metadata(scene)
    positions_at_frame = _positions_at_frame(positions, frame)

    p = Plots.plot(
        aspect_ratio=:equal,
        xlim=(-3.2, 3.2),
        ylim=(-1.0, max(1.8, 2.0 * metadata.slope + 0.4)),
        xlabel="x position",
        ylabel="z position",
        title=title,
        legend=:topright
    )

    _draw_scene_base!(p, metadata)
    _draw_scene_objects!(p, metadata, positions_at_frame)

    return p
end

function plot_scene_trajectory(scene, positions; title::AbstractString="Galileo scene trajectory")
    metadata = scene_metadata(scene)
    p = visualize_scene(scene; title=title)

    dynamic_indices = dynamic_object_indices(scene.init_state)
    colors = [:steelblue4, :saddlebrown, :darkgreen, :purple]
    for (plot_idx, object_id) in enumerate(dynamic_indices)
        xs = [positions[t, object_id, 1] for t in axes(positions, 1)]
        zs = [positions[t, object_id, 3] for t in axes(positions, 1)]
        Plots.plot!(p, xs, zs;
                    label="object $object_id path",
                    lw=2,
                    color=colors[mod1(plot_idx, length(colors))])
    end

    final_positions = [vec(positions[end, object_id, :]) for object_id in dynamic_indices]
    _draw_scene_objects!(p, metadata, final_positions)

    return p
end

################################################################################
# Particle trajectory debugger
################################################################################

const _PARTICLE_SCENE_AXIS_NAMES = Dict(1 => "x", 2 => "y", 3 => "z")

_trajectory_states(trajectory::Gen.Trace) = get_retval(trajectory)
_trajectory_states(trajectory) = trajectory

function _positions_from_trajectory(trajectory, t::Int; object_indices=nothing)
    states = _trajectory_states(trajectory)
    t in axes(states, 1) || throw(BoundsError(states, t))

    if states isa AbstractArray && ndims(states) == 3
        indices = object_indices === nothing ? axes(states, 2) : object_indices
        return [collect(@view states[t, object_id, :]) for object_id in indices]
    end

    state = states[t]
    objects = hasproperty(state, :objects) ? state.objects : state

    if hasproperty(objects, :kinematics)
        indices = object_indices === nothing ? dynamic_object_indices(objects) : object_indices
        return [copy(objects.kinematics[object_id].position) for object_id in indices]
    elseif state isa AbstractVector
        # Also accept the repo's `true_positions_from_trace` result.
        indices = object_indices === nothing ? eachindex(state) : object_indices
        return [copy(state[object_id]) for object_id in indices]
    end

    error("Unsupported trajectory state $(typeof(state)); expected a BulletState, MSCState, or position vector.")
end

"""
    true_object_positions(true_trajectory, t; object_indices=nothing)

Return the true 3D positions at frame `t` from a stored Galileo trace/state
trajectory. By default only dynamic objects are returned.
"""
true_object_positions(true_trajectory, t::Int; object_indices=nothing) =
    _positions_from_trajectory(true_trajectory, t; object_indices=object_indices)

function _particle_trajectories_at(particle_trajectories, t::Int)
    source = hasproperty(particle_trajectories, :history) ? particle_trajectories.history : particle_trajectories
    hasproperty(source, :traces) && return source.traces

    if source isa AbstractVector && !isempty(source) && hasproperty(source[firstindex(source)], :traces)
        t in eachindex(source) || throw(BoundsError(source, t))
        return source[t].traces
    end

    return source
end

"""
    particle_object_positions(particle_trajectories, t; object_indices=nothing)

Return one vector of 3D object positions per particle at frame `t`.
`particle_trajectories` may be a vector of traces or one of the repo's
inference-history vectors, whose entries contain `.traces`.
"""
function particle_object_positions(particle_trajectories, t::Int; object_indices=nothing)
    trajectories = _particle_trajectories_at(particle_trajectories, t)
    return [
        _positions_from_trajectory(trajectory, t; object_indices=object_indices)
        for trajectory in trajectories
    ]
end

function _trajectory_frame_count(trajectory)
    states = _trajectory_states(trajectory)
    return size(states, 1)
end

function _padded_axis_limits(values::AbstractVector{<:Real}, padding::Real)
    lo, hi = extrema(values)
    span = hi - lo
    margin = span == 0 ? max(abs(lo) * 0.1, 0.5) : max(Float64(padding), 0.08 * span)
    return (lo - margin, hi + margin)
end

"""
    particle_scene_limits(true_trajectory, particle_trajectories;
                          plane=(1, 3), object_indices=nothing, padding=0.35,
                          scene=nothing)

Compute fixed limits over the entire true and particle histories. The default
`(1, 3)` plane is the x-z side view used by the ramp collision scene.
Pass the ramp `scene` to include its static geometry in those limits.
"""
function particle_scene_limits(true_trajectory, particle_trajectories;
                               plane::Tuple{Int,Int}=(1, 3),
                               object_indices=nothing,
                               padding::Real=0.35,
                               scene=nothing)
    all(axis -> axis in 1:3, plane) || error("plane axes must be in 1:3")
    plane[1] != plane[2] || error("plane axes must be distinct")
    padding >= 0 || error("padding must be nonnegative")

    xs = Float64[]
    ys = Float64[]

    if scene !== nothing && plane == (1, 3)
        metadata = scene_metadata(scene)
        append!(xs, (
            -metadata.table_dims[1] / 2,
            metadata.table_dims[1] / 2,
            metadata.ramp_position[1],
            metadata.ramp_position[1] + metadata.ramp_dims[1],
        ))
        append!(ys, (
            -(metadata.base_dims[3] + metadata.table_dims[3]),
            metadata.ramp_position[3],
            metadata.ramp_position[3] + metadata.ramp_dims[3],
        ))
    end

    T = _trajectory_frame_count(true_trajectory)

    for t in 1:T
        true_positions = true_object_positions(true_trajectory, t; object_indices=object_indices)
        particle_positions = particle_object_positions(particle_trajectories, t; object_indices=object_indices)
        for position in Iterators.flatten((true_positions, Iterators.flatten(particle_positions)))
            push!(xs, Float64(position[plane[1]]))
            push!(ys, Float64(position[plane[2]]))
        end
    end

    isempty(xs) && error("No object positions were found for the particle scene.")
    return (xlim=_padded_axis_limits(xs, padding), ylim=_padded_axis_limits(ys, padding))
end

"""
    draw_scene_svg(true_trajectory, particle_trajectories, t;
                   show_particles=true, limits=nothing, collision_time=nothing,
                   plane=(1, 3), object_indices=nothing, scene=nothing)

Draw a lightweight, fixed-axis 2D particle-debugging view. True objects 1 and
2 are dark blue and orange; their particle predictions are light blue and
light orange respectively.
Plots uses SVG output when this value is displayed in Pluto.
"""
function draw_scene_svg(true_trajectory, particle_trajectories, t::Int;
                        show_particles::Bool=true,
                        limits=nothing,
                        collision_time=nothing,
                        plane::Tuple{Int,Int}=(1, 3),
                        object_indices=nothing,
                        scene=nothing)
    T = _trajectory_frame_count(true_trajectory)
    t in 1:T || throw(BoundsError(1:T, t))
    fixed_limits = limits === nothing ?
        particle_scene_limits(true_trajectory, particle_trajectories;
                              plane=plane, object_indices=object_indices, scene=scene) : limits
    true_positions = true_object_positions(true_trajectory, t; object_indices=object_indices)
    length(true_positions) >= 2 || error("Particle scene visualization requires two true objects.")

    collision_suffix = collision_time === nothing ? "" : "  |  collision t=$(collision_time)"
    p = Plots.plot(
        ;
        xlim=fixed_limits.xlim,
        ylim=fixed_limits.ylim,
        aspect_ratio=:equal,
        xlabel="$(_PARTICLE_SCENE_AXIS_NAMES[plane[1]]) position",
        ylabel="$(_PARTICLE_SCENE_AXIS_NAMES[plane[2]]) position",
        title="Particle scene — t=$t / $T$collision_suffix",
        legend=:topright,
        grid=true,
        size=(700, 420),
        fmt=:svg
    )

    if scene !== nothing && plane == (1, 3)
        _draw_scene_base!(p, scene_metadata(scene))
    end

    true_colors = (:steelblue, :darkorange)
    true_markers = (:circle, :diamond)
    for object_index in 1:2
        position = true_positions[object_index]
        Plots.scatter!(
            p,
            [position[plane[1]]],
            [position[plane[2]]];
            label="true object $object_index",
            color=true_colors[object_index],
            marker=true_markers[object_index],
            markerstrokecolor=:black,
            markerstrokewidth=1.5,
            markersize=9
        )
    end

    if show_particles
        particle_positions = particle_object_positions(
            particle_trajectories,
            t;
            object_indices=object_indices
        )
        particle_colors = ("#79BDF2", "#FFB766")

        # Draw these after the true markers. Before collision the predictions
        # often coincide exactly, so a small dot on each true marker makes the
        # otherwise-hidden particles visible without perturbing their positions.
        for object_index in 1:2
            positions = [positions[object_index] for positions in particle_positions]
            isempty(positions) && continue
            Plots.scatter!(
                p,
                [position[plane[1]] for position in positions],
                [position[plane[2]] for position in positions];
                label="object $object_index particles",
                color=particle_colors[object_index],
                markerstrokewidth=0,
                markersize=4,
                alpha=0.55
            )
        end
    end

    if collision_time !== nothing && t == collision_time
        midpoint = (true_positions[1] .+ true_positions[2]) ./ 2
        Plots.scatter!(
            p,
            [midpoint[plane[1]]],
            [midpoint[plane[2]]];
            label="collision",
            color=:black,
            marker=:xcross,
            markersize=10,
            markerstrokewidth=2
        )
    end

    return p
end

################################################################################
# Bullet camera with projected particle overlays
################################################################################

function _bullet_camera_matrices(; yaw::Real, pitch::Real, width::Int, height::Int)
    view_matrix = pb.computeViewMatrixFromYawPitchRoll(
        cameraTargetPosition=[0.0, 0.0, 0.15],
        distance=4.5,
        yaw=Float64(yaw),
        pitch=Float64(pitch),
        roll=0.0,
        upAxisIndex=2,
    )
    projection_matrix = pb.computeProjectionMatrixFOV(
        fov=55.0,
        aspect=width / height,
        nearVal=0.05,
        farVal=20.0,
    )
    return view_matrix, projection_matrix
end

function _project_camera_point(position, view_matrix, projection_matrix, width::Int, height::Int)
    view = reshape(Float64.(collect(view_matrix)), 4, 4)
    projection = reshape(Float64.(collect(projection_matrix)), 4, 4)
    clip = projection * view * [position[1], position[2], position[3], 1.0]
    clip[4] > 0 || return nothing

    ndc = clip[1:3] ./ clip[4]
    all(isfinite, ndc) || return nothing
    all(-1.0 <= coordinate <= 1.0 for coordinate in ndc) || return nothing

    pixel_x = (ndc[1] + 1.0) * 0.5 * (width - 1) + 1.0
    pixel_y = (1.0 - (ndc[2] + 1.0) * 0.5) * (height - 1) + 1.0
    return (pixel_x, pixel_y)
end

function _scatter_projected_positions!(plot_handle, positions,
                                       view_matrix, projection_matrix, width::Int, height::Int;
                                       label, color, marker=:circle, markersize=4,
                                       alpha=0.6, markerstrokewidth=0)
    projected = Tuple{Float64,Float64}[]
    for position in positions
        length(position) >= 3 || continue
        point = _project_camera_point(position, view_matrix, projection_matrix, width, height)
        point === nothing || push!(projected, point)
    end
    isempty(projected) && return plot_handle

    Plots.scatter!(
        plot_handle,
        first.(projected),
        last.(projected);
        label=label,
        color=color,
        marker=marker,
        markersize=markersize,
        alpha=alpha,
        markerstrokecolor=:black,
        markerstrokewidth=markerstrokewidth,
    )
    return plot_handle
end

"""
    bullet_camera_plot(scene, state; frame, particle_positions=nothing,
                       show_particles=true, yaw=0, pitch=-35)

Render a stored state with Bullet's off-screen camera. True dynamic-object
centres and optional per-particle inferred positions are projected through the
same camera matrices and drawn as registered overlays.
"""
function bullet_camera_plot(scene, state;
                            frame::Int,
                            particle_positions=nothing,
                            show_particles::Bool=true,
                            yaw::Real=0.0,
                            pitch::Real=-35.0,
                            width::Int=640,
                            height::Int=360)
    width > 0 || error("camera width must be positive")
    height > 0 || error("camera height must be positive")

    objects = hasproperty(state, :objects) ? state.objects : state
    PhySMC.sync!(scene.sim, objects)
    view_matrix, projection_matrix = _bullet_camera_matrices(
        yaw=yaw,
        pitch=pitch,
        width=width,
        height=height,
    )
    rgba = pb.getCameraImage(
        width,
        height;
        viewMatrix=view_matrix,
        projectionMatrix=projection_matrix,
        renderer=pb.ER_TINY_RENDERER,
        physicsClientId=scene.client,
    )[3]
    image = [
        RGB{Float64}(rgba[y, x, 1] / 255, rgba[y, x, 2] / 255, rgba[y, x, 3] / 255)
        for y in axes(rgba, 1), x in axes(rgba, 2)
    ]

    plot_handle = Plots.heatmap(
        image;
        xlim=(0.5, width + 0.5),
        ylim=(0.5, height + 0.5),
        yflip=true,
        aspect_ratio=:equal,
        colorbar=false,
        axis=nothing,
        ticks=nothing,
        border=:none,
        legend=:topright,
        size=(960, 540),
        title="Bullet 3D camera at t=$(frame)",
    )

    dynamic_indices = dynamic_object_indices(objects)
    true_positions = [objects.kinematics[index].position for index in dynamic_indices]
    true_colors = (:steelblue, :darkorange)
    true_markers = (:circle, :diamond)
    for object_index in eachindex(true_positions)
        _scatter_projected_positions!(
            plot_handle,
            [true_positions[object_index]],
            view_matrix,
            projection_matrix,
            width,
            height;
            label="true object $object_index",
            color=true_colors[mod1(object_index, length(true_colors))],
            marker=true_markers[mod1(object_index, length(true_markers))],
            markersize=7,
            alpha=0.95,
            markerstrokewidth=1.5,
        )
    end

    if show_particles && particle_positions !== nothing
        particle_colors = ("#79BDF2", "#FFB766")
        object_count = isempty(particle_positions) ? 0 : minimum(length, particle_positions)
        for object_index in 1:object_count
            positions = [particle[object_index] for particle in particle_positions]
            _scatter_projected_positions!(
                plot_handle,
                positions,
                view_matrix,
                projection_matrix,
                width,
                height;
                label="object $object_index inference particles",
                color=particle_colors[mod1(object_index, length(particle_colors))],
            )
        end
    end

    return plot_handle
end


struct ScenePlaybackSlider
    max_value::Int
    default::Int
    interval_ms::Int
end

function ScenePlaybackSlider(max_value::Int; default::Int=1, fps::Real=6)
    max_value > 0 || error("ScenePlaybackSlider requires at least one frame.")
    default in 1:max_value || error("ScenePlaybackSlider default must be in 1:max_value.")
    fps > 0 || error("ScenePlaybackSlider fps must be positive.")
    return ScenePlaybackSlider(max_value, default, round(Int, 1000 / fps))
end

Base.get(widget::ScenePlaybackSlider) = widget.default

function Base.show(io::IO, ::MIME"text/html", widget::ScenePlaybackSlider)
    write(io, """
    <galileo-playback-slider style="display:flex;align-items:center;gap:0.65rem;max-width:38rem">
      <button type="button" title="Play or pause 3D playback" style="width:2.4rem;height:2rem">&#9654;</button>
      <input type="range" min="1" max="$(widget.max_value)" value="$(widget.default)" step="1" style="flex:1">
      <output style="min-width:3rem;font-variant-numeric:tabular-nums">$(widget.default)</output>
    </galileo-playback-slider>
    <script>
      const root = currentScript.previousElementSibling
      const button = root.querySelector("button")
      const slider = root.querySelector("input")
      const output = root.querySelector("output")
      const intervalMs = $(widget.interval_ms)
      let timer = null

      const publish = () => {
        root.value = slider.valueAsNumber
        output.value = slider.value
        root.dispatchEvent(new CustomEvent("input"))
      }
      const stop = () => {
        clearInterval(timer)
        timer = null
        button.innerHTML = "&#9654;"
      }

      slider.addEventListener("input", publish)
      button.addEventListener("click", () => {
        if (timer === null) {
          button.innerHTML = "&#10074;&#10074;"
          timer = setInterval(() => {
            slider.value = slider.valueAsNumber >= Number(slider.max) ? 1 : slider.valueAsNumber + 1
            publish()
          }, intervalMs)
        } else {
          stop()
        }
      })
      root.value = slider.valueAsNumber
      invalidation.then(stop)
    </script>
    """)
end

"""
    save_particle_scene_gif(path, true_trajectory, particle_trajectories;
                            fps=10, show_particles=true, kwargs...)

Save all frames of `draw_scene_svg` to `path` with one set of fixed axes.
"""
function save_particle_scene_gif(path::AbstractString,
                                 true_trajectory,
                                 particle_trajectories;
                                 fps::Real=10,
                                 show_particles::Bool=true,
                                 limits=nothing,
                                 plane::Tuple{Int,Int}=(1, 3),
                                 object_indices=nothing,
                                 collision_time=nothing,
                                 scene=nothing)
    fps > 0 || error("fps must be positive")
    fixed_limits = limits === nothing ?
        particle_scene_limits(true_trajectory, particle_trajectories;
                              plane=plane, object_indices=object_indices, scene=scene) : limits
    animation = Plots.Animation()

    for t in 1:_trajectory_frame_count(true_trajectory)
        frame_plot = draw_scene_svg(
            true_trajectory,
            particle_trajectories,
            t;
            show_particles=show_particles,
            limits=fixed_limits,
            collision_time=collision_time,
            plane=plane,
            object_indices=object_indices,
            scene=scene,
        )
        Plots.frame(animation, frame_plot)
    end

    return Plots.gif(animation, path; fps=fps)
end
