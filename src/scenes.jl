const DEFAULT_RAMP_ASSET_DIR = normpath(joinpath(@__DIR__, "..", "assets"))

function _ramp_scene_metadata(mass_ratio::Float64,
                              obj_frictions::NTuple{2,Float64},
                              obj_positions::NTuple{2,Float64},
                              slope::Float64,
                              tableRampIntersection::Float64)
    base_dims = [5.0, 1.0, 0.75]
    table_dims = [base_dims[1] + 0.2, base_dims[2] + 0.2, 0.1]
    obj_ramp_dims = [0.15, 0.3, 0.075]
    obj_on_table_dims = [0.2, 0.2, 0.1]
    theta_radians = -atan(slope)
    lift = obj_ramp_dims[3] / 2

    ramp_position = [-2 + tableRampIntersection, -base_dims[2] / 2, 0.0]
    ramp_obj_position = [
        -2 + 2 * obj_positions[1] + tableRampIntersection + lift * cos(theta_radians),
        0.0,
        (2 - 2 * obj_positions[1]) * slope - lift * sin(theta_radians)
    ]
    table_obj_position = [2.5 * (obj_positions[2] - 1), 0.0, obj_on_table_dims[3] / 2]

    return (
        mass_ratio = mass_ratio,
        obj_frictions = obj_frictions,
        obj_positions = obj_positions,
        slope = slope,
        tableRampIntersection = tableRampIntersection,
        base_dims = base_dims,
        table_dims = table_dims,
        ramp_dims = [2.0, base_dims[2], 2.0 * slope],
        ramp_position = ramp_position,
        ramp_orientation = theta_radians,
        obj_ramp_dims = obj_ramp_dims,
        obj_ramp_position = ramp_obj_position,
        obj_ramp_orientation = theta_radians,
        obj_table_dims = obj_on_table_dims,
        obj_table_position = table_obj_position,
        obj_table_orientation = 0.0
    )
end

"""
Create the Galileo ramp scene in PyBullet.

The positional and physical setup follows the original notebook's `ramp`
function. By default this returns `(client, obj_on_ramp_id, obj_on_table_id)`.
Set `return_metadata=true` when downstream plotting needs the scene geometry.
"""
function ramp(mass_ratio::Float64,
              obj_frictions::NTuple{2,Float64}=(0.5, 0.5),
              obj_positions::NTuple{2,Float64}=(0.5, 1.5),
              slope::Float64=2 / 3,
              tableRampIntersection::Float64=0.0;
              connect_mode=pb.DIRECT,
              ramp_asset_dir::AbstractString=DEFAULT_RAMP_ASSET_DIR,
              return_metadata::Bool=false)

    # for debugging
    #client = @pycall pb.connect(pb.GUI)::Int64
    #pb.resetDebugVisualizerCamera(4.5, 0, -40, [0.0, 0.0, 0.0]; physicsClientId=client)

    # Set up the pybullet client and set gravity at -10
    client = @pycall pb.connect(connect_mode)::Int64
    pb.setGravity(0, 0, -10; physicsClientId=client)

    # add a table base (setting mass = 0 makes it a static object)
    grey = [0.5, 0.5, 0.5, 1]
    base_dims = [5, 1, 0.75] # in meters
    table_dims = [base_dims[1] + 0.2, base_dims[2] + 0.2, 0.1]  # Width, depth, height
    table_base_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=base_dims / 2, physicsClientId=client)
    table_base_obj_id = pb.createMultiBody(baseCollisionShapeIndex=table_base_col_id, basePosition=[0, 0, -(base_dims[3] + table_dims[3]) / 2], physicsClientId=client)
    pb.changeDynamics(table_base_obj_id, -1; mass=0.0, restitution=0.9, physicsClientId=client)
    pb.changeVisualShape(table_base_obj_id, -1, rgbaColor=grey, physicsClientId=client)

    # Create the tabletop (a flat box)
    table_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=table_dims / 2, physicsClientId=client)
    table_body_id = pb.createMultiBody(baseCollisionShapeIndex=table_col_id, basePosition=[0, 0, -table_dims[3] / 2], physicsClientId=client)
    pb.changeDynamics(table_body_id, -1; mass=0.0, restitution=0.9, physicsClientId=client)
    pb.changeVisualShape(table_body_id, -1, rgbaColor=grey .+ 0.2, physicsClientId=client)

    # Create the four frame-like boxes around the tabletop
    frame_height = 0.25
    frame_thickness = 0.05

    frame_dims = [
        [table_dims[1] + 2 * frame_thickness, frame_thickness, frame_height], # Longer sides
        [table_dims[1] + 2 * frame_thickness, frame_thickness, frame_height], # Longer sides
        [frame_thickness, table_dims[2], frame_height], # Shorter sides
        [frame_thickness, table_dims[2], frame_height] # Shorter sides
    ]

    frame_positions = [
        [0, table_dims[2] / 2 + frame_thickness / 2, 0], # Top side
        [0, -table_dims[2] / 2 - frame_thickness / 2, 0], # Bottom side
        [table_dims[1] / 2 + frame_thickness / 2, 0, 0], # Right side
        [-table_dims[1] / 2 - frame_thickness / 2, 0, 0] # Left side
    ]

    for (dims, pos) in zip(frame_dims, frame_positions)
        frame_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=dims / 2, physicsClientId=client)::Int64
        frame_obj_id = pb.createMultiBody(baseCollisionShapeIndex=frame_col_id, basePosition=pos, physicsClientId=client)::Int64
        pb.changeVisualShape(frame_obj_id, -1, rgbaColor=grey, physicsClientId=client)
    end

    # add a ramp
    pb.setAdditionalSearchPath(ramp_asset_dir; physicsClientId=client)
    ramp_col_id = pb.createCollisionShape(pb.GEOM_MESH, fileName="ramp.obj", physicsClientId=client, meshScale=[2, base_dims[2], slope * 2])
    ramp_position = [-2 + tableRampIntersection, -base_dims[2] / 2, 0]
    ramp_obj_id = pb.createMultiBody(baseCollisionShapeIndex=ramp_col_id, basePosition=ramp_position, physicsClientId=client)
    pb.changeDynamics(ramp_obj_id, -1; mass=0.0, restitution=0.9, physicsClientId=client)
    pb.changeVisualShape(ramp_obj_id, -1, rgbaColor=[1, 1, 1, 1], physicsClientId=client)

    # add a floor
    floor_col_id = pb.createCollisionShape(pb.GEOM_PLANE, physicsClientId=client)
    floor_obj_id = pb.createMultiBody(baseCollisionShapeIndex=floor_col_id, basePosition=[0, 0, -base_dims[3]], physicsClientId=client)
    pb.changeDynamics(floor_obj_id, -1; mass=0.0, restitution=0.9, physicsClientId=client)

    #  add walls
    wall_dims = [[0.1, 8.0, 5.0], [0.1, 8.0, 5.0], [8.0, 0.1, 5.0]] # Width, length, height
    wall_positions = [
        [4.0, 0.0, 1.0], # Right Wall
        [-4.0, 0.0, 1.0], # Left Wall
        [0, 4, wall_dims[3][3] / 2 - base_dims[3]] # Back Wall
    ]
    for (dims, pos) in zip(wall_dims, wall_positions)
        wall_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=dims ./ 2, physicsClientId=client)
        wall_obj_id = pb.createMultiBody(baseCollisionShapeIndex=wall_col_id, basePosition=pos, physicsClientId=client)
        pb.changeDynamics(wall_obj_id, -1; mass=0.0, restitution=0.9, physicsClientId=client)
        pb.changeVisualShape(wall_obj_id, -1, rgbaColor=grey + [0.2, 0.2, 0.2, 0], physicsClientId=client)
    end

    # add an object on the ramp
    obj_ramp_dims = [0.15, 0.3, 0.075]
    theta_radians = -atan(slope)
    orientation = [cos(theta_radians / 2), 0, sin(theta_radians / 2), 0]

    obj_on_ramp_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=obj_ramp_dims / 2, physicsClientId=client)
    lift = obj_ramp_dims[3] / 2
    position = [
        -2 + 2 * obj_positions[1] + tableRampIntersection + lift * cos(theta_radians),
        0,
        (2 - 2 * obj_positions[1]) * slope - lift * sin(theta_radians)
    ]
    obj_on_ramp_obj_id = pb.createMultiBody(baseCollisionShapeIndex=obj_on_ramp_col_id, basePosition=position, baseOrientation=orientation, physicsClientId=client)
    pb.changeDynamics(obj_on_ramp_obj_id, -1; mass=mass_ratio, restitution=0.9, lateralFriction=obj_frictions[1], physicsClientId=client)

    # add an object on the table that will collide with the object on the ramp as that one slides down
    obj_on_table_dims = [0.2, 0.2, 0.1]
    obj_on_table_col_id = pb.createCollisionShape(pb.GEOM_BOX, halfExtents=obj_on_table_dims / 2, physicsClientId=client)
    obj_on_table_obj_id = pb.createMultiBody(baseCollisionShapeIndex=obj_on_table_col_id, basePosition=[2.5 * (obj_positions[2] - 1), 0, obj_on_table_dims[3] / 2], physicsClientId=client)
    pb.changeDynamics(obj_on_table_obj_id, -1; mass=1.0, restitution=0.9, lateralFriction=obj_frictions[2], physicsClientId=client)

    if return_metadata
        metadata = _ramp_scene_metadata(mass_ratio, obj_frictions, obj_positions, slope, tableRampIntersection)
        return (client, obj_on_ramp_obj_id, obj_on_table_obj_id, metadata)
    end

    return (client, obj_on_ramp_obj_id, obj_on_table_obj_id)
end

function create_ramp_simulation(; mass_ratio::Float64=2.0,
                                obj_frictions::NTuple{2,Float64}=(0.3, 0.3),
                                obj_positions::NTuple{2,Float64}=(0.5, 1.5),
                                slope::Float64=2 / 3,
                                tableRampIntersection::Float64=0.0,
                                connect_mode=pb.DIRECT)
    client, obj_1, obj_2, metadata = ramp(
        mass_ratio,
        obj_frictions,
        obj_positions,
        slope,
        tableRampIntersection;
        connect_mode=connect_mode,
        return_metadata=true
    )

    # create PhySMC and PhyBullet objects
    sim = BulletSim(; client=client)
    obj_r = RigidBody(obj_1) # ramp obj
    obj_t = RigidBody(obj_2) # table obj

    # get an initial state (to be overwritten in the prior function)
    init_state = BulletState(sim, [obj_r, obj_t])

    return (
        client = client,
        obj_1 = obj_1,
        obj_2 = obj_2,
        sim = sim,
        obj_r = obj_r,
        obj_t = obj_t,
        init_state = init_state,
        metadata = metadata
    )
end

function sample_random_scene(; rng::AbstractRNG=Random.default_rng(),
                             mass_ratio_range=(0.5, 5.0),
                             friction_range=(0.1, 0.8),
                             ramp_position_range=(0.25, 0.85),
                             table_position_range=(1.1, 1.8),
                             slope_range=(0.45, 0.9),
                             tableRampIntersection_range=(-0.15, 0.15),
                             connect_mode=pb.DIRECT)
    mass_ratio = rand(rng) * (mass_ratio_range[2] - mass_ratio_range[1]) + mass_ratio_range[1]
    obj_frictions = (
        rand(rng) * (friction_range[2] - friction_range[1]) + friction_range[1],
        rand(rng) * (friction_range[2] - friction_range[1]) + friction_range[1]
    )
    obj_positions = (
        rand(rng) * (ramp_position_range[2] - ramp_position_range[1]) + ramp_position_range[1],
        rand(rng) * (table_position_range[2] - table_position_range[1]) + table_position_range[1]
    )
    slope = rand(rng) * (slope_range[2] - slope_range[1]) + slope_range[1]
    tableRampIntersection = rand(rng) * (tableRampIntersection_range[2] - tableRampIntersection_range[1]) + tableRampIntersection_range[1]

    return create_ramp_simulation(;
        mass_ratio=mass_ratio,
        obj_frictions=obj_frictions,
        obj_positions=obj_positions,
        slope=slope,
        tableRampIntersection=tableRampIntersection,
        connect_mode=connect_mode
    )
end

function simulate_scene_positions(scene, T::Int)
    state = scene.init_state
    positions = Array{Float64}(undef, T, 2, 3)

    for t in 1:T
        state = PhySMC.step(scene.sim, state)
        for obj_idx in 1:2
            positions[t, obj_idx, :] .= state.kinematics[obj_idx].position
        end
    end

    return positions
end
