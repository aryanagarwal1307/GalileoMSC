# Stimulus generation

Run from the repository root:

```sh
source py-env/bin/activate
python stimuli/build_stimuli.py --all --dry-run
python stimuli/build_stimuli.py --all
```

The controller validates configuration, exports PyBullet trajectories, renders
Blender PNGs, and encodes H.264 MP4s with four exact probe stills per condition.
It builds every enabled condition in `config/stimuli.toml`: **12 conditions**,
covering six directed distinct-material pairs, each congruent and incongruent.
No model generation or inference runs are involved. Every selected condition is
rebuilt; there is no hash cache, checkpoint schema, pilot, or parameter sweep.

Generate the separate practice scene without rebuilding the 12 conditions:

```sh
python stimuli/build_stimuli.py --practice
```

`[practice]` in the same config inherits every physics/timing default. Both
blocks use one shared solid-gray material and each has mass 1 kg.
The camera, lighting, geometry, friction, render and encode settings are the
same as the main stimuli. Its video is `generated/videos/practice_equal_mass.mp4`;
its four probes are recorded under `practice` in the existing video manifest.
Practice and main builds preserve each other's manifest entries. `--all`
continues to generate only the 12 main conditions. The experiment automatically
uses the practice video once generation finishes. `--practice --preview` makes
only the practice still preview.

Python 3.11+ uses standard-library TOML; Python 3.8–3.10 needs `tomli`. Julia
uses this repository's project and its configured PyCall/PyBullet installation.
Blender 4.2+, FFmpeg/libx264 and FFprobe must be installed. The controller finds
Blender on PATH or at `/Applications/Blender.app/Contents/MacOS/Blender`; use
`--blender PATH` to override it. A build lock prevents concurrent controller runs.

## Parameters

Physics and condition settings have one source: **`config/stimuli.toml`**.
Render and video intro settings live at the top of **`build_stimuli.py`**.
Camera, lighting and appearance live in **`blender/render_stimuli.py`**.

| Parameter | Setting |
|---|---|
| Appearance masses, wood:brick:metal | 1:2:8 |
| Simulated masses | Table = 1; ramp = configured ramp/table ratio |
| Physics / video | 240 Hz / 60 fps; four physics ticks per action frame |
| Physics timestep | 4.166667 ms |
| Action display duration | 4.5 s, 270 frames |
| Intro | 800 ms empty scene + 200 ms stationary objects |
| Complete MP4 | 5.5 s, 330 frames; no final hold |
| Both boxes, full dimensions | 0.24 × 0.24 × 0.12 m |
| Placement parameters, ramp/table | 0.5 / 1.45 |
| Ramp normal clearance | 0.001 m |
| Object lateral friction, both | 0.3 |
| Ramp / table lateral friction | 2.0 / 0.08333333333333333 |
| Effective object/surface friction | 0.6 ramp / 0.025 table |
| Restitution, each body | 0.5; Bullet combines contact values |
| Gravity / slope | −10 m/s² / 2/3 rise/run |
| Solver iterations | 50, fixed; no sweep or internal substeps |
| Render / encode | 1920×1080, Eevee 64 samples; H.264 CRF 15, slow, yuv420p, faststart |

The ramp object's center is offset along the ramp normal, correcting the old
initial penetration. The placement leaves room for the
1000 ms baseline probe; the low tabletop friction retains post-contact motion.
Timing adjustment: `action_duration` changes from **5.0 to 4.5 s** and
`obj_positions` from **[0.25, 1.5] to [0.5, 1.45]**. The ramp block moves
0.5 m downhill in world X (1/3 m lower); the table block moves 0.125 m
toward the ramp. Targeted DIRECT simulations at ratios 0.125, 0.5, 1, and 8
found first contact at **3.275 s**, leaving the +1000 ms probe at **4.275 s**.
Moving only the ramp block left that probe too late for the shorter clip.
The physics timestep, solver, friction, restitution and FPS are unchanged.

Appearance changes only the renderer's material, not friction or geometry.
Violations use the reciprocal of the appearance-predicted mass ratio.

The 270 action samples cover times 0 through 269/60 s. The final sample is
shown for one frame interval, making exactly 4.5 seconds of action display.
`max_duration=10` is a configuration ceiling for `action_duration`, not an
extra simulation phase. The seed is 42; these scenes make no random draws.

## Probes and outputs

Contact is detected between the two objects after every physics tick. For each
probe offset `d` in seconds (−1.000, −0.200, +0.200, +1.000), its zero-based MP4 frame is:

```text
60 + floor((first_contact_time_seconds + d) * 60 + 0.5)
```

Rounding uses exact contact time and ties go to the later frame. The 60-frame
intro is added afterwards. Frame quantization contributes at most 8.333 ms;
contact detection has 4.167 ms resolution. The probe key `collision`
means **200 ms after** contact. Out-of-range probes or absent collisions stop
that condition with a short error rather than silently choosing another frame.

| Output | Contents |
|---|---|
| `stimuli/generated/trajectories/<id>.json` | 270 poses, geometry, parameters, contact time, software/engine settings |
| `results/stimuli/final/pngs/<id>/` | 270 action PNGs, `empty_scene.png`, render metadata |
| `stimuli/generated/videos/<id>.mp4` | Complete 5.5-second video |
| `stimuli/generated/videos/<id>_<probe>.png` | Four stills decoded from the exact MP4 probe frames |
| `stimuli/generated/videos/video_manifest.json` | Video dimensions/FPS/count/duration and per-condition probe frames/still paths |

The encoder checks frame availability, video format, FPS, count and duration.
Blender replays recorded poses without physics and checks three transforms.
There are no corner/camera bounds scans, full playback reviews, diagnostic
reports, or software/source fingerprints. The manifest updates after each video;
`complete_condition_set` is true once all enabled conditions have been built.

## Small checks and individual stages

```sh
# One trajectory and four stills (empty, initial, contact, final); no production MP4/manifest.
python stimuli/build_stimuli.py --condition wood_to_metal_violation --preview

# One full video. This replaces the manifest with this build's selected set.
python stimuli/build_stimuli.py --condition brick_to_metal_congruent

# Cheap synthetic encoding/timing and manifest checks; no physics/model/Blender.
python test/test_stimuli_build.py

# Two short physics checks (main/practice); no saved trajectories or rendering.
julia --startup-file=no --compiled-modules=existing --project=. scripts/check_stimulus_timing.jl
```

Preview outputs go to `results/stimuli/preview/{trajectories,pngs}/`.
A one-condition production build advertises only that fresh condition; run
`--all` before building the experiment. Existing unselected files remain on disk.
Interrupted builds can be restarted, but selected conditions are rebuilt from
scratch. Only remove a stale `stimuli/generated/build.lock` after verifying that
its process is no longer running. Do not run standalone stages concurrently.

Standalone stage instructions: [renderer](blender/README.md),
[encoder](video/README.md). **Inference/PhySMC clock repair remains separate**;
this pipeline directly steps PyBullet and does not change the model clock.
The experiment uses all six congruent pairs for baseline and assigned-timing phases;
during/post also show one quota-assigned incongruent pair.
