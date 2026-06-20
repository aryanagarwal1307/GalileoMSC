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
    ramp = _rotated_box_shape(
        metadata.ramp_position[1] + metadata.ramp_dims[1] / 2,
        metadata.ramp_position[3] + metadata.ramp_dims[3] / 2,
        metadata.ramp_dims[1],
        metadata.ramp_dims[3],
        metadata.ramp_orientation
    )

    Plots.plot!(p, table_base; label="", color=:gray65, linecolor=:gray35, alpha=0.8)
    Plots.plot!(p, table_top; label="", color=:gray80, linecolor=:gray35, alpha=0.9)
    Plots.plot!(p, ramp; label="", color=:white, linecolor=:black, alpha=0.95)
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
        0.0
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
