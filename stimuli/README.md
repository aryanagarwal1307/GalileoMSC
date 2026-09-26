# Build all eight stimulus videos

From the repository root:

```sh
python stimuli/build_stimuli.py --all
```

On this Mac, activate the existing environment first (`source py-env/bin/activate`)
to make `python` available. Python 3.8+ works; versions below 3.11 need `tomli`.
The script checks Python dependencies, the Julia project and its actual PyCall
Python/PyBullet installation, Blender 4.2+, FFmpeg/libx264 and FFprobe before
simulation or rendering. Blender was previously tested at 5.2.2 LTS. Override its
executable with `--blender /Applications/Blender.app/Contents/MacOS/Blender` if needed.

The command generates and validates trajectories, renders and validates every
PNG, then encodes and probes every complete MP4. It reuses the existing Julia
exporter, Blender trajectory validator/renderer, and FFmpeg encoder; Blender never
simulates physics. Logs identify the build stage and condition. Any failure stops
the build with a nonzero exit code.

Final deliverables are exactly:

```text
stimuli/generated/videos/<condition_id>.mp4    # eight files
stimuli/generated/videos/video_manifest.json
```

Intermediate JSONs remain in `stimuli/generated/trajectories/`, and PNGs in
`results/stimuli/final/pngs/`. Checkpoints and the derived configuration live in
`stimuli/generated/build/`. All generated outputs are ignored by Git.

## Edit parameters in one place

Edit the clearly marked `SIMULATION`, `RENDERING` and `ENCODING` dictionaries at
the top of **[build_stimuli.py](build_stimuli.py)**:

| Parameter | Default | Meaning |
|---|---:|---|
| `physics_hz` | 240 | Physics timestep is `1 / physics_hz` seconds |
| `video_fps` | 60 | Must divide `physics_hz`; four physics substeps per frame |
| `post_collision_duration` | 2.0 s | Simulation continues this long after first contact |
| `max_duration` | 10.0 s | Simulation safety limit, excluding display holds |
| `hold_start_seconds` | 0.5 s | Extra display time at the first frame |
| `hold_end_seconds` | 0.5 s | Extra display time at the last frame |
| `resolution` | 960×540 | Common even output dimensions |
| `samples` | 64 | Common Blender render sample count |
| `crf`, `preset` | 15, slow | Common H.264 encoding settings |

Dimensions, friction, restitution, positions, slope and seed are also exposed
there. Condition IDs, materials and mass ratios remain in
`config/stimuli.toml`. The master overrides its listed simulation fields for every
condition in a derived TOML file passed to the exporter. It does not rewrite the
source config or change defaults used by standalone analyses. FPS flows from
that configuration into trajectories, Blender and FFmpeg without resampling.
The renderer owns the shared camera, lights, materials and bevels; its source is
fingerprinted so edits there invalidate renders.

Increase `post_collision_duration` to extend simulated motion after contact;
increase `max_duration` if its safety cap would otherwise intervene. All eight
trajectories must share the same first pose, frame indices, FPS and duration.
If new physics settings produce unequal lengths, the build fails before rendering;
it does not trim or pad individual motion sequences to hide the mismatch.

## Endpoint holds and jsPsych

FFmpeg adds holds by cloning the first and last images. Set either hold to `0`
to disable it. Holds must be exact whole-frame intervals: 0.5 s at 60 fps adds
30 frames at each end. Every original trajectory frame is retained in order.
Holds do not change PyBullet timing or require extra Blender frames.

For the current 200-frame trajectories, the defaults produce **260-frame,
4.333333-second** videos at 60 fps: `(200 + 30 + 30) / 60`. Without holds, the
duration is `200 / 60 = 3.333333` seconds. The final source frame already has its
normal one-frame display interval; the configured hold is additional time.

There are no trial-specific cuts or short copies. **jsPsych applies stopping
frames during playback**, using the full video for every observation condition.
The manifest records `trajectory_frame_count`, `hold_start_frames`,
`hold_end_frames` and `trajectory_frame_offset`. A zero-based trajectory frame
`n` occurs at video frame `n + hold_start_frames`, or time
`(n + hold_start_frames) / fps`. The initial hold occupies the preceding frames.
Model-clock alignment for fitting human data remains separate from this pipeline.

## Resume, force and checks

```sh
python stimuli/build_stimuli.py --all --dry-run  # Check dependencies and print the plan
python stimuli/build_stimuli.py --all            # Resume/rebuild only stale work
python stimuli/build_stimuli.py --all --force    # Explicitly rebuild everything
```

Resume uses content hashes, resolved settings, implementation hashes and software
versions, not file existence or timestamps. A completed trajectory stage can be
reused; renders and videos are checkpointed per condition. Missing frames,
incomplete metadata, bad PNG checksums or changed output hashes trigger rebuilding
the affected work. Every final video is freshly checked with FFprobe even on a
fully cached build. A CRF/hold change re-encodes videos; a render-setting change
rebuilds renders and dependent videos; simulation/configuration changes rerun the
trajectory stage and rebuild dependent outputs as needed. `--force` bypasses all
reuse. Changing code or relevant tool versions also invalidates affected stages.

Existing outputs from before this orchestrator have no build checkpoint proving
which exporter inputs produced them. **The first tracked build conservatively
regenerates those outputs once**; subsequent builds resume normally. Keep
`stimuli/generated/build/state.json` to retain that provenance.

Stages publish validated temporary outputs, preserving the previous version if
generation/validation fails. Unexpected unrelated files in managed output folders
cause an error rather than being deleted. Stale `.build.lock`/`.encode.lock` files
must only be removed after confirming the recorded process has stopped. Do not
run the standalone exporter/renderer concurrently with the master build.

The combined manifest contains all eight video records, complete source render
metadata, source PNG/video hashes, resolved build settings, software versions,
stage fingerprints and the trajectory-to-video mapping. The terminal summary
lists all eight paths, frame counts, durations and file sizes.

Cheap regression tests (tiny synthetic four-frame inputs; Julia and Blender are
stubbed, FFmpeg/FFprobe are real):

```sh
python test/test_stimuli_build.py
```

These test the orchestration, hold contents, resume, force, incomplete-output
recovery and failure handling without running the full experimental build.
