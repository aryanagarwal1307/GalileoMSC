# Scripted stimulus rendering

For the complete resumable workflow, use
`python stimuli/build_stimuli.py --all`; see the [master build guide](../README.md).
The commands below expose the rendering stage separately.

`render_stimuli.py` builds the complete scene and replays exported PyBullet poses.
It requires no `.blend` file, Python packages, or Blender physics. Tested with
the installed **Blender 5.2.2 LTS** on macOS. Run commands from the repository root.

```sh
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender

# One condition: all frames, with the requested final-results layout.
"$BLENDER" --background --factory-startup --python-exit-code 1 \
  --python stimuli/blender/render_stimuli.py -- \
  --trajectory stimuli/generated/trajectories/wood_to_metal_violation.json \
  --output-dir results/stimuli/final/pngs --resolution 960 540 --engine EEVEE

# All enabled conditions in stimuli/config/stimuli.toml.
"$BLENDER" --background --factory-startup --python-exit-code 1 \
  --python stimuli/blender/render_stimuli.py -- \
  --all --output-dir results/stimuli/final/pngs

# Fast visual check: frame zero, collision frame, and final frame per condition.
"$BLENDER" --background --factory-startup --python-exit-code 1 \
  --python stimuli/blender/render_stimuli.py -- --all --smoke
```

Each output root gets a `<condition_id>/` subdirectory containing
`frame_0000.png`, subsequent selected frames, and `render_metadata.json`.
Without `--output-dir`, full renders use `stimuli/generated/frames/` and smoke
renders use `results/stimuli/smoke/`. These generated directories are ignored by
Git. This renderer produces only lossless PNGs. The
[video encoder](../video/README.md) writes complete MP4s and a manifest to
`stimuli/generated/videos/`. Smoke renders use the same quality and scene settings
as full renders, but select only three frames.

All script options go **after `--`**. Use `--frame-range 0 20` for an inclusive,
zero-based range instead of `--smoke`. `--resolution WIDTH HEIGHT` defaults to
960×540. `--samples` defaults to 64. `--engine EEVEE` is the default and validated rendering path; `CYCLES`
is an optional alternative, not visually equivalent. FPS comes from the JSON
(60 for the configured conditions); there is no resampling or FPS override.
Rerunning a command replaces its selected PNGs and metadata, leaving other files
alone. Use separate output roots when comparing render settings or frame subsets.

For JSON validation without starting Blender:

```sh
python3 stimuli/blender/render_stimuli.py --all --validate-only
```

This requires Python 3.11+ for `--all` (standard-library `tomllib`). Blender's
bundled Python also works. Invalid timing, dimensions, masses, poses, collision
metadata, or frame ranges fail before any output is written. Missing enabled
exports fail clearly; regenerate them with
`julia --project=. scripts/export_stimulus_trajectories.jl`.

## Geometry, animation, and appearance

The ramp is a closed, outward-facing triangular prism built from JSON scene
geometry, with no dependency on an imported collision OBJ's visual normals. The
table and base also use JSON dimensions. Both moving cuboids use their exact
full dimensions, centered origins, a common 3 mm bevel, and weighted normals.
The bevel cuts inward; it does not enlarge the physical object's envelope.

Positions copy directly in meters, with Z up and no axis remapping. Quaternions
change only storage order from PyBullet `(x,y,z,w)` to Blender `(w,x,y,z)`.
Every pose is keyed in `QUATERNION` mode, with linear location and quaternion
F-curves. JSON frame `n` maps to Blender frame `n+1` and PNG `frame_nnnn.png`.
The script checks all evaluated poses, allows only Blender's float32 rounding
(less than 1e-6 per component), and checks that both objects stay inside the
fixed camera. It never steps a simulator or creates rigid bodies. Velocities
remain in the trajectory JSON; the render animation uses the recorded poses.

One orthographic three-quarter camera, two soft area lights, a neutral background,
AgX color management, exposure zero, and 64 Eevee samples apply to every condition.
Motion blur and depth of field are disabled. Modern Eevee uses virtual shadow maps
and jittered area-light shadows for contact shading. Camera placement is fixed,
not fitted per condition; trajectories leaving its view fail with an explanation.

Wood has directional grain, brick has a muted mortar pattern on all face
orientations, and metal is neutral gray with metallic response. Procedural
coordinates use local meters, so texture scale is shared and textures move with
their objects. Material parameters depend only on the appearance label, never
the mass ratio or congruence. All scene settings are explicit or factory defaults
from the recorded Blender build; cross-version visual equality is not promised.

## Render provenance

Each `render_metadata.json` records Blender version/build, source trajectory and
renderer SHA-256 hashes, resolution, FPS, engine, camera transform, light settings,
material parameters, bevel settings, color management, scene geometry, selected
and completed frames, and pose-verification errors. A shared `policy_sha256`
identifies camera/lighting/material/render settings across conditions. `status`
is `complete` only after all selected PNGs have been written; failures propagate
to Blender's `--python-exit-code 1`.

These rendering changes do not change the exported trajectories and do not require
JSON regeneration. **Model-clock alignment must still be handled separately before
fitting human data**; this renderer does not change inference timing.
