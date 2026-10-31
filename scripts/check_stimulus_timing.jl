#!/usr/bin/env julia
# Two short DIRECT checks only: no trajectory export, rendering or model runs.
using GalileoMSC
using PhyBullet: pb

spec = first(load_stimuli())
for (label, ratio) in (("main", spec.mass_ratio), ("equal-mass practice", 1.0))
    scene = create_ramp_simulation(; merge(stimulus_scene_kwargs(spec), (; mass_ratio=ratio))...)
    try
        pb.setRealTimeSimulation(0; physicsClientId=scene.client)
        pb.setTimeStep(1 / spec.physics_hz; physicsClientId=scene.client)
        pb.setPhysicsEngineParameter(; numSubSteps=0, numSolverIterations=50,
            deterministicOverlappingPairs=1, physicsClientId=scene.client)
        contact_tick = nothing
        for tick in 1:round(Int, spec.action_duration * spec.physics_hz)
            pb.stepSimulation(; physicsClientId=scene.client)
            if !isempty(pb.getContactPoints(; bodyA=scene.obj_1, bodyB=scene.obj_2, physicsClientId=scene.client))
                contact_tick = tick
                break
            end
        end
        isnothing(contact_tick) && error("No object-object contact in $label")
        contact = contact_tick // spec.physics_hz
        frame_count = round(Int, spec.action_duration * spec.video_fps)
        probes = [floor(Int, (contact + offset // 1000) * spec.video_fps + 1 // 2)
                  for offset in (-1000, -200, 200, 1000)]
        all(frame -> 0 <= frame < frame_count, probes) || error("Probe outside the action in $label: $probes")
        println(label, ": contact=", Float64(contact), " s; action frames=", frame_count,
            "; probes=", probes, "; placement=", spec.obj_positions,
            "; physics step=1/", spec.physics_hz, " s")
    finally
        pb.disconnect(; physicsClientId=scene.client)
    end
end
