# Galileo-MSC

This project is a temporally structured generative model for intuitive physics scenes. 

## Four-trial visual prototype

The participant-facing web prototype, its configuration, and its run instructions
are in [`experiment/`](experiment/README.md).

Build all eight complete experimental videos with
`python stimuli/build_stimuli.py --all`. See the
[stimulus build guide](stimuli/README.md) for the editable master parameters,
endpoint holds, resumable builds, and the generated video manifest.

Human-experiment stimuli are defined in [`stimuli/config/stimuli.toml`](stimuli/config/stimuli.toml).
The file contains shared defaults and eight conditions; `load_stimuli()` returns
validated `StimulusSpec` values in file order. The canonical master build applies
its shared parameter overrides through a derived config. A different config path can be
passed explicitly. Per-condition entries override shared defaults.

```julia
using GalileoMSC
specs = load_stimuli()
spec = only(filter(s -> s.condition_id == "wood_to_metal_violation", specs))
scene = create_ramp_simulation(; stimulus_scene_kwargs(spec)...)
# Disconnect the PyBullet client when finished:
GalileoMSC.pb.disconnect(; physicsClientId=scene.client)
```

`mass_ratio` means **ramp-object mass / table-object mass**, with the table
object normalized to **1.0**. Appearance predicts ratios from wood:brick:metal
relative masses of 1:2:4. Thus the wood-to-metal violation has
`appearance_mass_ratio == 0.25` and simulated `mass_ratio == 4.0`.
`congruent == false` denotes a violation.

Both stimulus objects have full dimensions `[0.20, 0.20, 0.10]` meters.
The general scene APIs retain their original defaults: ramp object
`[0.15, 0.30, 0.075]` and table object `[0.20, 0.20, 0.10]`. Override them with
the `obj_ramp_dims` and `obj_table_dims` keywords on `ramp` or
`create_ramp_simulation`. Metadata records the geometry used for construction.

`obj_positions` retains the scene API's two scalar placement parameters:
for `(r, t)`, ramp placement starts at `x = -2 + 2r + table_ramp_intersection`,
`z = (2 - 2r) * slope` before the existing height offset, and table placement
is `x = 2.5(t - 1)`, `z = table_object_height / 2`. Slope is rise/run;
the table–ramp intersection is an x offset in meters.

The initial timing settings are 240 Hz physics, 60 fps video, a 10-second
maximum duration, 2 seconds after collision, and seed 42. Durations are seconds;
frequencies must be positive integers, with `physics_hz` divisible by `video_fps`.
Dimensions, masses, and durations must be finite and positive; restitution is
in `[0, 1]`, and friction is finite and nonnegative. Configuration loading also
checks material names, unique condition IDs, and congruence with appearance.

`stimulus_scene_kwargs` passes geometry and physical properties to the scene API.
Loading a configuration does not seed the global RNG or render a video.

Run the configuration and headless scene tests with
`julia --project=. test/runtests.jl`.

Export all enabled trajectories from the repository root:

```sh
julia --project=. scripts/export_stimulus_trajectories.jl
```

The exporter writes human-readable JSON to
`stimuli/generated/trajectories/<condition_id>.json` (ignored by Git).
Use `--config PATH` or `--output-dir PATH` to override the input or destination.
Set `enabled = false` on a condition to skip it; all conditions default to enabled.
Disabled conditions remain validated by the configuration loader. Existing files
are replaced only after successful simulation and serialization. Skipping a
disabled condition does not delete an older export for it.

60 fps provides smooth animation with exactly four 1/240-second physics steps
per frame. The exporter uses PyBullet DIRECT, sets the timestep explicitly,
records frame zero before stepping, and checks contact between the two dynamic
objects after every substep. It fails if they never collide. After contact it
records through the first full video frame at or after the configured interval,
capped at `floor(max_duration * video_fps)`. The cap may truncate that interval;
the JSON reports this. Frame count includes frame zero, so it equals
`duration_seconds * video_fps + 1`. The last sample time is the motion duration;
a video that displays every sample for a full frame lasts one frame longer.

**Model-clock alignment must be handled separately before fitting human data.**
The exporter bypasses `PhySMC.step`, whose inclusive substep loop can execute five
ticks instead of four. No inference-model timing is changed by this exporter.

Each JSON file contains a schema version, all resolved stimulus fields, object
materials/masses/dimensions, scene geometry, physics settings and software
versions, frame times, collision substep/time/video frame, stop reason, and both
objects' position, quaternion, linear velocity, and angular velocity at each frame.
The provenance also records the SHA-256 identity of the ramp mesh used by the
scene, including visual face winding and normals.
No random draws occur; the seed is saved for provenance. Repeatability applies
to the same software build and platform, not bitwise equality across platforms.

For Blender, load the JSON using Python's standard `json` module. Coordinates
are right-handed, Z-up, and in meters; use an identity axis mapping and unit
scale 1. Create boxes with the supplied **full** local dimensions and mesh origins
at their centers. Use the recorded transforms as animation, with rigid-body
simulation disabled. Material names are appearance labels for the renderer.
PyBullet quaternions are `(x,y,z,w)`;
[Blender expects `(w,x,y,z)`](https://docs.blender.org/api/main/mathutils.html#mathutils.Quaternion).
For existing unparented Blender objects named `ramp_object` and `table_object`:

```python
import json
import bpy

with open(trajectory_path, encoding="utf-8") as f:
    data = json.load(f)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.scale_length = 1.0
scene.render.fps = data["timing"]["video_fps"]
scene.render.fps_base = 1.0
scene.frame_start = 1
scene.frame_end = data["timing"]["frame_count"]
for frame in data["frames"]:
    for name, state in frame["objects"].items():
        obj = bpy.data.objects[name]
        obj.rotation_mode = "QUATERNION"
        obj.location = state["position"]
        x, y, z, w = state["quaternion_xyzw"]
        obj.rotation_quaternion = (w, x, y, z)
        obj.keyframe_insert("location", frame=frame["frame"] + 1)
        obj.keyframe_insert("rotation_quaternion", frame=frame["frame"] + 1)
```

Key every recorded sample and use linear interpolation for any between-frame
evaluation. The JSON preserves actual PyBullet poses, including quaternion signs;
an importer doing interpolation may choose equivalent signs for continuity.
No Blender runtime or renderer is needed to generate these files.

For a complete Blender scene with procedural materials and pose replay, use
[the scripted renderer](stimuli/blender/README.md). It includes background-mode
commands for one/all conditions and a three-frame smoke render, with PNGs and
render metadata saved separately from trajectory exports.

Encode all eight complete PNG sequences into browser-compatible H.264 MP4s with
`python3 stimuli/video/encode_videos.py --all`. The
[video encoding documentation](stimuli/video/README.md) covers preflight checks,
dry runs, explicit overwrites, FFprobe verification, and the generated video manifest.
