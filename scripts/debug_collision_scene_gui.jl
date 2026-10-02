import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using GalileoMSC
using PhyBullet

function env_float(name::AbstractString, default::Float64)
    value = get(ENV, name, "")
    isempty(value) && return default
    return parse(Float64, value)
end

connect_mode_name = uppercase(get(ENV, "GALILEO_DEBUG_CONNECT_MODE", "GUI"))
connect_mode = if connect_mode_name == "GUI"
    pb.GUI
elseif connect_mode_name == "DIRECT"
    pb.DIRECT
else
    error("GALILEO_DEBUG_CONNECT_MODE must be GUI or DIRECT.")
end

scene = create_ramp_simulation(
    mass_ratio = env_float("GALILEO_DEBUG_MASS_RATIO", 1.25),
    obj_frictions = (
        env_float("GALILEO_DEBUG_RAMP_FRICTION", 0.05),
        env_float("GALILEO_DEBUG_TABLE_FRICTION", 0.2),
    ),
    obj_positions = (
        env_float("GALILEO_DEBUG_RAMP_POSITION", 0.5),
        env_float("GALILEO_DEBUG_TABLE_POSITION", 1.5),
    ),
    slope = env_float("GALILEO_DEBUG_SLOPE", 0.9),
    tableRampIntersection = env_float("GALILEO_DEBUG_TABLE_RAMP_INTERSECTION", 0.0),
    connect_mode = connect_mode,
)

debug_restitution = env_float("GALILEO_DEBUG_RESTITUTION", 0.0)
for body_index in 0:(pb.getNumBodies(physicsClientId = scene.client) - 1)
    body_id = pb.getBodyUniqueId(body_index; physicsClientId = scene.client)
    pb.changeDynamics(body_id, -1; restitution = debug_restitution, physicsClientId = scene.client)
end

pb.resetDebugVisualizerCamera(
    4.5,
    0,
    -35,
    [0.0, 0.0, 0.0];
    physicsClientId = scene.client,
)

println("PyBullet $(connect_mode_name) client: ", scene.client)
println("Scene objects: ramp object=", scene.obj_1, ", table object=", scene.obj_2)

try
    if connect_mode == pb.DIRECT
        for _ in 1:120
            pb.stepSimulation(physicsClientId = scene.client)
        end
        println("DIRECT smoke check complete.")
    else
        println("Close the PyBullet window or press Ctrl-C here to exit.")
        while pb.isConnected(scene.client) == 1
            pb.stepSimulation(physicsClientId = scene.client)
            sleep(1 / 60)
        end
    end
catch err
    err isa InterruptException || rethrow()
    println()
    println("Exiting PyBullet GUI.")
finally
    pb.isConnected(scene.client) == 1 && pb.disconnect(scene.client)
end
