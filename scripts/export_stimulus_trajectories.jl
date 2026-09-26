#!/usr/bin/env julia

using GalileoMSC
using PhyBullet: pb
using PyCall: pyimport
using JSON
using SHA

const DEFAULT_TRAJECTORY_DIR = normpath(joinpath(@__DIR__, "..", "stimuli", "generated", "trajectories"))
const RAMP_ASSET_PATH = normpath(joinpath(@__DIR__, "..", "assets", "ramp.obj"))

# MODEL-CLOCK ALIGNMENT IS REQUIRED BEFORE FITTING HUMAN DATA.
# This exporter deliberately bypasses PhySMC.step: its inclusive dt <= step_dur
# loop can advance five 1/240 s substeps for an intended 1/60 s model step.
# Only the exporter clock is corrected here. Inference/model clocks must be
# aligned separately; these trajectories do not make existing model timing valid.

resolved_fields(value) = (; (name => getfield(value, name) for name in fieldnames(typeof(value)))...)

function object_sample(client, body)
    position, quaternion = pb.getBasePositionAndOrientation(body; physicsClientId=client)
    linear, angular = pb.getBaseVelocity(body; physicsClientId=client)
    # Preserve PyBullet values, including quaternion signs and xyzw order.
    return (; position=Float64[position...], quaternion_xyzw=Float64[quaternion...],
            linear_velocity=Float64[linear...], angular_velocity=Float64[angular...])
end

function trajectory_frame(scene, spec, frame, substep)
    return (; frame, physics_substep=substep, time_seconds=frame / spec.video_fps,
            objects=(; ramp_object=object_sample(scene.client, scene.obj_1),
                       table_object=object_sample(scene.client, scene.obj_2)))
end

"""
    simulate_stimulus_trajectory(spec::StimulusSpec)

Return a renderer-independent trajectory using exact integer counts of PyBullet
steps. Frame zero precedes all steps. Contact means contact between the two
dynamic objects, not either object touching a surface. No RNG is used: all
initial conditions are explicit; the configured seed is retained for provenance.
"""
function simulate_stimulus_trajectory(spec::StimulusSpec)
    substeps_per_frame = spec.physics_hz ÷ spec.video_fps
    max_frame = floor(Int, spec.max_duration * spec.video_fps)
    max_frame >= 1 || throw(ArgumentError("$(spec.condition_id): max_duration must allow a full video frame"))
    post_collision_substeps = ceil(Int, spec.post_collision_duration * spec.physics_hz)
    scene = create_ramp_simulation(; stimulus_scene_kwargs(spec)..., connect_mode=pb.DIRECT)
    try
        pb.setRealTimeSimulation(0; physicsClientId=scene.client)
        pb.setTimeStep(1 / spec.physics_hz; physicsClientId=scene.client)
        # No internal subdivision: each explicit stepSimulation is one physics tick.
        pb.setPhysicsEngineParameter(; numSubSteps=0, numSolverIterations=50,
            deterministicOverlappingPairs=1, physicsClientId=scene.client)
        engine_parameters = pb.getPhysicsEngineParameters(; physicsClientId=scene.client)

        frames = [trajectory_frame(scene, spec, 0, 0)]
        substep = 0
        first_contact_substep = nothing
        stop_reason = "maximum_duration"
        for frame in 1:max_frame
            for _ in 1:substeps_per_frame
                pb.stepSimulation(; physicsClientId=scene.client)
                substep += 1
                contacts = pb.getContactPoints(; bodyA=scene.obj_1, bodyB=scene.obj_2,
                    physicsClientId=scene.client)
                if first_contact_substep === nothing && !isempty(contacts)
                    first_contact_substep = substep
                end
            end
            push!(frames, trajectory_frame(scene, spec, frame, substep))
            if first_contact_substep !== nothing &&
               substep >= first_contact_substep + post_collision_substeps
                stop_reason = "post_collision_duration"
                break
            end
        end
        first_contact_substep === nothing && error(
            "$(spec.condition_id): no collision between dynamic objects within " *
            "$(last(frames).time_seconds) seconds ($(substep) physics substeps); trajectory not saved")

        first_contact_time = first_contact_substep / spec.physics_hz
        collision_frame = cld(first_contact_substep, substeps_per_frame)
        completed_post_duration = stop_reason == "post_collision_duration"
        return (;
            schema_version=1,
            condition_id=spec.condition_id,
            stimulus=resolved_fields(spec),
            objects=(;
                ramp_object=(; material=spec.ramp_material, mass=spec.mass_ratio,
                              dimensions=spec.obj_ramp_dims),
                table_object=(; material=spec.table_material, mass=1.0,
                               dimensions=spec.obj_table_dims)),
            scene_geometry=resolved_fields(scene.metadata),
            conventions=(;
                coordinates="right-handed world coordinates; +Z up; +X along table/ramp travel; +Y transverse",
                length_unit="meter", time_unit="second", mass_unit="kilogram (table normalized to 1.0)",
                dimensions="full local box extents [x,y,z], not half extents",
                position="world-space center of mass; coincides with the box mesh origin",
                quaternion="[x,y,z,w], PyBullet world orientation of the local body frame",
                linear_velocity="world-space [vx,vy,vz], meters/second",
                angular_velocity="world-space [wx,wy,wz], radians/second",
                frame_index="zero-based; frame 0 is the initial state, before any physics step",
                blender=(; axis_mapping="identity; use meters, scene.unit_settings.scale_length = 1.0",
                           quaternion_order="[w,x,y,z] = [q[3],q[0],q[1],q[2]] using Python indexing",
                           rotation_mode="QUATERNION", frame_mapping="Blender frame = JSON frame + 1",
                           fps=spec.video_fps, fps_base=1.0,
                           animation="keyframe both objects at every sample; use linear interpolation; do not resimulate rigid bodies")),
            timing=(; physics_hz=spec.physics_hz, video_fps=spec.video_fps,
                      physics_timestep_seconds=1 / spec.physics_hz, substeps_per_frame,
                      total_physics_substeps=substep, frame_count=length(frames),
                      duration_seconds=last(frames).time_seconds,
                      requested_max_duration_seconds=spec.max_duration,
                      maximum_output_frame=max_frame,
                      stop_reason, post_collision_duration_completed=completed_post_duration,
                      recorded_post_collision_seconds=(substep - first_contact_substep) / spec.physics_hz,
                      stop_policy="first full video frame at/after the post-contact interval, capped at floor(max_duration * video_fps); frame count includes frame zero"),
            collision=(; body_a="ramp_object", body_b="table_object",
                         first_contact_substep, first_contact_time_seconds=first_contact_time,
                         video_frame=collision_frame,
                         video_frame_time_seconds=collision_frame / spec.video_fps,
                         detection="getContactPoints after every physics substep; video_frame is the first sampled frame at/after contact"),
            provenance=(; simulator="PyBullet DIRECT", pybullet_api_version=pb.getAPIVersion(),
                          pybullet_package_version=pyimport("importlib.metadata").version("pybullet"),
                          julia_version=string(VERSION), platform=string(Sys.KERNEL), architecture=string(Sys.ARCH),
                          ramp_asset=(; path="assets/ramp.obj",
                                       sha256=bytes2hex(SHA.sha256(read(RAMP_ASSET_PATH))),
                                       geometry="closed triangular prism with outward-facing normals"),
                          engine_parameters, deterministic_overlapping_pairs=true,
                          seed=spec.seed, randomness="none; fully specified initial conditions",
                          reproducibility="numerically deterministic for the same software build and platform; cross-platform bitwise equality is not guaranteed",
                          model_clock_warning="Exporter-only timing correction. Align inference/model clocks separately before fitting human data."),
            frame_times_seconds=[frame.time_seconds for frame in frames],
            frames)
    finally
        pb.disconnect(; physicsClientId=scene.client)
    end
end

"""Export all enabled conditions. Files are replaced only after a successful simulation."""
function export_stimulus_trajectories(; config_path=DEFAULT_STIMULI_CONFIG,
                                      output_dir=DEFAULT_TRAJECTORY_DIR)
    specs = filter(s -> s.enabled, load_stimuli(config_path))
    # Condition IDs become file basenames; disallow path separators/traversal.
    for spec in specs
        occursin(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", spec.condition_id) ||
            throw(ArgumentError("unsafe trajectory filename for condition_id: $(spec.condition_id)"))
    end
    mkpath(output_dir)
    paths = String[]
    for spec in specs
        println("Generating trajectory: ", spec.condition_id)
        flush(stdout)
        trajectory = simulate_stimulus_trajectory(spec)
        path = joinpath(output_dir, spec.condition_id * ".json")
        # Stage in the destination directory so a failed write leaves prior output intact.
        temp_path, io = mktemp(output_dir)
        try
            JSON.print(io, trajectory, 2)
            println(io)
            close(io)
            mv(temp_path, path; force=true)
        finally
            isopen(io) && close(io)
            isfile(temp_path) && rm(temp_path)
        end
        push!(paths, path)
        println(spec.condition_id, ": ", trajectory.timing.frame_count, " frames, ",
            trajectory.timing.duration_seconds, " s; contact at substep ",
            trajectory.collision.first_contact_substep, " (",
            trajectory.collision.first_contact_time_seconds, " s), frame ",
            trajectory.collision.video_frame, "; stop=", trajectory.timing.stop_reason)
    end
    isempty(specs) && println("No enabled stimulus conditions; no trajectories exported.")
    return paths
end

function main(args=ARGS)
    config_path = DEFAULT_STIMULI_CONFIG
    output_dir = DEFAULT_TRAJECTORY_DIR
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("--help", "-h")
            println("Usage: julia --project=. scripts/export_stimulus_trajectories.jl [--config PATH] [--output-dir PATH]")
            return
        end
        arg in ("--config", "--output-dir") || throw(ArgumentError("unknown option: $arg"))
        i < length(args) || throw(ArgumentError("missing value for $arg"))
        if arg == "--config"
            config_path = args[i + 1]
        else
            output_dir = args[i + 1]
        end
        i += 2
    end
    export_stimulus_trajectories(; config_path, output_dir)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
