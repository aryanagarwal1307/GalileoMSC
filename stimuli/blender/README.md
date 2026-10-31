# Scripted stimulus rendering

## Inspect and edit a stimulus in the Blender app

Blender is installed as `/Applications/Blender.app`. The production renderer
creates a scene from Python each run and does not save a `.blend` file. Make a
preview scene from any existing trajectory (run from the repository root):

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python stimuli/blender/preview_scene.py -- \
  --trajectory stimuli/generated/trajectories/wood_to_metal_congruent.json \
  --output results/stimuli/preview/wood_to_metal_congruent.blend \
  --png results/stimuli/preview/wood_to_metal_congruent.png --frame 220
open results/stimuli/preview/wood_to_metal_congruent.blend
```

This saves the full keyframed animation and opens near the collision. The
preview and final build default to 1920×1080 (Full HD); add
`--resolution 960 540` for a faster low-resolution inspection. The
`--frame` value is a zero-based JSON frame; Blender's timeline uses frame+1.
Change the trajectory name to inspect another condition. The generated `.blend`
is a scratch preview; use File > Save As with a new filename before experimenting
so regenerating the preview does not overwrite your edits. Subsequent scripted
builds recreate the scene from source.

In Blender, use the camera view (`Numpad 0`, or View > Cameras > Active Camera),
drag the timeline to inspect motion, and choose **Material Preview** or
**Rendered** shading with the viewport shading icons. Material Preview responds
quickly to material edits; Rendered uses the scene lights and is closer to the
final PNG. `F12` renders the current frame with the exact render engine and
camera settings.

Select `ramp_object` or `table_object` in the Outliner, then use **Material
Properties** or the **Shading** workspace. `metal` uses the Principled BSDF Base
Color, Metallic and Roughness inputs. `wood` gets its visible color from the
Color Ramp nodes, stretched Noise fibers, Wave growth bands, and pore
bump/roughness variation. All four side faces use the striped side grain,
including the inner faces; their fiber coordinates rotate to run along those
faces. There is no circular end-grain layer. `brick` loads the authored material from
[`materials/my_brick.blend`](materials/my_brick.blend), with its single UV-mapped
Brick Texture, noise-driven brick/mortar colors, dark mottling, and fine bumps.
The renderer copies the donor cube's `UVMap` to the existing simulation box by
face orientation and corner, preserving the pattern count on every face. The
shorter side faces compress the pattern vertically. All shader values, including
pattern size, colors, roughness, and bumps, come directly from the permanent asset.
The asset is a copy of the latest `results/stimuli/preview/my_brick.blend`;
refreshing it replaces earlier material adjustments with the saved authoring values.
Practice
uses a uniform dark gray (legacy material ID `white_ceramic`) for contrast
against the ramp. Metal parameters and nodes are unchanged. The static tabletop, ramp, base and ground use Principled
BSDF colors. Camera and lights can be selected and adjusted in the viewport or
Object Data Properties. Take note of numerical values you like.

Transfer chosen values to [render_stimuli.py](render_stimuli.py): `MATERIALS`,
`CAMERA`, `LIGHTS`, `BEVEL`, `RENDER`, or the four static-material calls in
`configure_scene`. The `material()` function sets Principled inputs; the
`procedural_material()` function builds the wood nodes. To change brick, edit
the permanent `materials/my_brick.blend` asset and retain its mesh `Cube`,
material `Material`, and UV map `UVMap`. `load_brick_appearance()` appends that
material without importing the donor object, camera, or lights; all dimensions,
bevels, and recorded motion still come from the simulation scene. The asset was
authored and verified in Blender 5.2.2 LTS; older Blender compatibility has not
been checked. Changes to scratch preview `.blend` files do not affect scripted
rebuilds. The original `results/stimuli/preview/my_brick.blend` is a separate
copy. Material assignments and mass
ratios for each condition live in [stimuli.toml](../config/stimuli.toml). Moving
objects are keyframed from the trajectory JSON, so changes to their geometry or
motion belong in [stimuli.toml](../config/stimuli.toml) and require new
trajectories. Keep visual and physical changes coordinated across conditions.

After changing renderer values, preview a few frames with `--smoke` (below),
then run `python stimuli/build_stimuli.py --all` when ready to regenerate the
final PNGs and videos. The controller rebuilds all selected conditions.

For the complete workflow, use
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
  --output-dir results/stimuli/final/pngs --resolution 1920 1080 --engine EEVEE

# All enabled conditions in stimuli/config/stimuli.toml.
"$BLENDER" --background --factory-startup --python-exit-code 1 \
  --python stimuli/blender/render_stimuli.py -- \
  --all --output-dir results/stimuli/final/pngs

# One-condition visual check: empty scene, frame zero, contact, and final frame.
"$BLENDER" --background --factory-startup --python-exit-code 1 \
  --python stimuli/blender/render_stimuli.py -- \
  --trajectory stimuli/generated/trajectories/wood_to_metal_violation.json --smoke
```

Each output root gets a `<condition_id>/` subdirectory containing
`frame_0000.png`, subsequent selected frames, `empty_scene.png`, and `render_metadata.json`.
Without `--output-dir`, full renders use `stimuli/generated/frames/` and smoke
renders use `results/stimuli/smoke/`. These generated directories are ignored by
Git. This renderer produces only lossless PNGs. The
[video encoder](../video/README.md) writes complete MP4s and a manifest to
`stimuli/generated/videos/`. Smoke renders use the same quality and scene settings
as full renders, but select only three frames.

All script options go **after `--`**. Use `--frame-range 0 20` for an inclusive,
zero-based range instead of `--smoke`. `--resolution WIDTH HEIGHT` defaults to
1920×1080. `--samples` defaults to 64. `--engine EEVEE` is the default and validated rendering path; `CYCLES`
is an optional alternative, not visually equivalent. FPS comes from the JSON
(60 for the configured conditions); there is no resampling or FPS override.
Rerunning removes prior `frame_*.png` and empty-scene PNGs in that condition
folder, then writes the requested frames and metadata. Unrelated files remain. Use separate output roots when comparing render settings or frame subsets.

For JSON validation without starting Blender:

```sh
python3 stimuli/blender/render_stimuli.py --all --validate-only
```

Python below 3.11 needs `tomli` for `--all`. Blender's
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
The script checks three evaluated poses, allowing Blender's float32 rounding
(less than 1e-6 per component). It never steps a simulator or creates rigid bodies.
Velocities
remain in the trajectory JSON; the render animation uses the recorded poses.

One long-lens perspective camera, two soft area lights, a solid warm-gray
backdrop, AgX color
management, exposure zero, and 64 Eevee samples apply to every condition.
Motion blur and depth of field are disabled. Modern Eevee uses virtual shadow maps
and jittered area-light shadows for contact shading. Camera placement is fixed,
not fitted per condition.
The camera is a rectilinear pinhole projection with no radial lens distortion.
Parallel lines can converge toward a vanishing point under perspective; the
long lens and distant camera make this effect gentle. The previous orthographic
camera preserved parallelism but did not have a perspective viewpoint.

Wood keeps its original top/bottom grain and uses horizontal bands on all four
sides. Brick uses the saved shader and face-local UV layout from
`materials/my_brick.blend`; its noise uses Generated coordinates as authored.
Metal is neutral gray with metallic response. Wood coordinates use local
meters. Both wood and brick textures move with their objects. Materials depend
only on the appearance label, never
the mass ratio or congruence. All scene settings are explicit or factory defaults
from the recorded Blender build; cross-version visual equality is not promised.

## Render metadata

Each `render_metadata.json` records the stimulus settings, Blender version,
resolution, FPS, camera/lighting/materials, geometry, and completed frame indices.
It has no hashes or schema versions. `status` becomes `complete` after all
selected PNGs and the empty scene have been written. Empty-scene rendering hides
both moving objects and their shadows, using the same fixed scene and camera.
The encoder repeats that image for 800 ms and the initial object frame for 200 ms.

Appearance-only changes require new renders/videos; physics changes require new
trajectories too. The controller handles both. Inference timing is unchanged.
