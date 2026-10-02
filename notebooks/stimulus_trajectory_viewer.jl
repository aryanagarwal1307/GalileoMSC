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

# ╔═╡ 8c1cf982-a33e-45f4-b853-a9e52463e94d
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using JSON
    using PhyBullet
    using Plots
    using PlutoUI
end

# ╔═╡ d88f2d86-34a7-47cf-b50e-43e83f77fd70
md"""
# Stimulus trajectory viewer

Replay an exported stimulus through the existing PyBullet off-screen camera.
The notebook reads the recorded position, quaternion, and velocities from JSON;
it **does not advance or regenerate physics**.

If no files are available, run from the repository root:

```sh
julia --project=. scripts/export_stimulus_trajectories.jl
```
"""

# ╔═╡ 7bcfa65d-02df-476d-af98-68ccb2c7fb30
begin
    trajectory_directory = normpath(joinpath(
        @__DIR__, "..", "stimuli", "generated", "trajectories"
    ))
    trajectory_paths = isdir(trajectory_directory) ? sort(filter(
        path -> endswith(lowercase(path), ".json"),
        readdir(trajectory_directory; join=true),
    )) : String[]

    isempty(trajectory_paths) && error(
        "No trajectory JSON files found in $trajectory_directory. " *
        "Run `julia --project=. scripts/export_stimulus_trajectories.jl` first."
    )

    trajectory_options = [
        path => replace(splitext(basename(path))[1], "_" => " ")
        for path in trajectory_paths
    ]
end

# ╔═╡ 0fad0139-bb84-4101-a638-9269988b018c
md"""
Condition: $(@bind selected_trajectory_path Select(trajectory_options))
"""

# ╔═╡ 86768a75-803c-41a4-865a-ad250519077e
begin
    trajectory = JSON.parsefile(selected_trajectory_path)
    get(trajectory, "schema_version", nothing) == 1 ||
        error("Unsupported trajectory schema version in $selected_trajectory_path")

    frames = trajectory["frames"]
    frame_count = length(frames)
    frame_count == trajectory["timing"]["frame_count"] ||
        error("JSON frame_count does not match the number of stored frames")
    all(frame["frame"] == i - 1 for (i, frame) in enumerate(frames)) ||
        error("JSON frames must be contiguous and zero-based")

    stimulus_spec = StimulusSpec(;
        (Symbol(key) => value for (key, value) in trajectory["stimulus"])...
    )
    collision_frame = Int(trajectory["collision"]["video_frame"])
    default_playback_frame = clamp(collision_frame + 1, 1, frame_count)
end

# ╔═╡ 9fda4087-27f1-48ca-bea4-f63808d29eef
md"""
Frame: $(@bind playback_frame ScenePlaybackSlider(
    frame_count;
    default=default_playback_frame,
    fps=min(stimulus_spec.video_fps, 15),
))

Camera yaw: $(@bind camera_yaw Slider(-60:5:60; default=0, show_value=true))

Camera pitch: $(@bind camera_pitch Slider(-70:5:-10; default=-35, show_value=true))
"""

# ╔═╡ 1513fe9e-1328-4843-96b3-94de9d4011ea
begin
    """
    Restore one JSON sample into a fresh DIRECT scene and render it.

    A fresh scene makes every Pluto reevaluation independent. The client is
    disconnected in `finally`, including when rendering fails. No call to
    `stepSimulation` or `PhySMC.step` occurs here.
    """
    function render_trajectory_frame(trajectory, spec::StimulusSpec, json_frame::Int;
                                     yaw::Real=0, pitch::Real=-35,
                                     width::Int=960, height::Int=540)
        frames = trajectory["frames"]
        0 <= json_frame < length(frames) || throw(BoundsError(frames, json_frame + 1))
        sample = frames[json_frame + 1]

        scene = create_ramp_simulation(;
            stimulus_scene_kwargs(spec)...,
            connect_mode=pb.DIRECT,
        )
        try
            for (name, body_id) in (
                ("ramp_object", scene.obj_1),
                ("table_object", scene.obj_2),
            )
                object = sample["objects"][name]
                pb.resetBasePositionAndOrientation(
                    body_id,
                    object["position"],
                    object["quaternion_xyzw"];
                    physicsClientId=scene.client,
                )
                pb.resetBaseVelocity(
                    body_id;
                    linearVelocity=object["linear_velocity"],
                    angularVelocity=object["angular_velocity"],
                    physicsClientId=scene.client,
                )
            end

            # Capture all bodies after restoring the two dynamic-object poses.
            # bullet_camera_plot synchronizes this state once before rendering.
            restored_state = BulletState(scene.sim, scene.init_state.elements)
            return bullet_camera_plot(
                scene,
                restored_state;
                frame=json_frame,
                show_particles=false,
                yaw=yaw,
                pitch=pitch,
                width=width,
                height=height,
            )
        finally
            pb.disconnect(; physicsClientId=scene.client)
        end
    end
end

# ╔═╡ 4364ca63-63e0-43f0-9671-18a71c8496ed
begin
    json_frame = playback_frame - 1
    selected_sample = frames[playback_frame]
    render_trajectory_frame(
        trajectory,
        stimulus_spec,
        json_frame;
        yaw=camera_yaw,
        pitch=camera_pitch,
    )
end

# ╔═╡ c97b72d7-eaee-4244-b555-12e8412cd00d
md"""
### Current sample

- **Condition:** `$(trajectory["condition_id"])`
- **JSON frame:** `$json_frame` (frame zero is the initial state)
- **Time:** `$(round(selected_sample["time_seconds"], digits=6)) s`
- **Physics substep:** `$(selected_sample["physics_substep"])`
- **First contact:** frame `$(trajectory["collision"]["video_frame"])`, substep `$(trajectory["collision"]["first_contact_substep"])`, `$(round(trajectory["collision"]["first_contact_time_seconds"], digits=6)) s`
- **Sampling:** `$(trajectory["timing"]["physics_hz"]) Hz` physics, `$(trajectory["timing"]["video_fps"]) fps` output, `$(trajectory["timing"]["substeps_per_frame"])` substeps/frame
- **Ramp object:** `$(stimulus_spec.ramp_material)`, mass `$(stimulus_spec.mass_ratio)`, position `$(round.(selected_sample["objects"]["ramp_object"]["position"], digits=4))`
- **Table object:** `$(stimulus_spec.table_material)`, mass `1.0`, position `$(round.(selected_sample["objects"]["table_object"]["position"], digits=4))`

The playback button is capped at 15 displayed frames per second because each
selection performs an off-screen render. It still visits the original 60 fps
samples in order and never changes their timestamps or poses.
"""

# ╔═╡ Cell order:
# ╠═8c1cf982-a33e-45f4-b853-a9e52463e94d
# ╠═d88f2d86-34a7-47cf-b50e-43e83f77fd70
# ╠═7bcfa65d-02df-476d-af98-68ccb2c7fb30
# ╠═0fad0139-bb84-4101-a638-9269988b018c
# ╠═86768a75-803c-41a4-865a-ad250519077e
# ╠═9fda4087-27f1-48ca-bea4-f63808d29eef
# ╠═1513fe9e-1328-4843-96b3-94de9d4011ea
# ╠═4364ca63-63e0-43f0-9671-18a71c8496ed
# ╠═c97b72d7-eaee-4244-b555-12e8412cd00d
