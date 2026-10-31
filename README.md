# Galileo-MSC

A temporally structured generative model for intuitive physics scenes, with
PyBullet stimulus generation and a jsPsych relative-mass experiment.

## Generate stimuli

From the repository root:

```sh
source py-env/bin/activate
python stimuli/build_stimuli.py --all --dry-run
python stimuli/build_stimuli.py --all
# Separate equal-mass solid-gray practice; keeps existing main stimuli.
python stimuli/build_stimuli.py --practice
```

The controller exports trajectories, renders Blender PNGs, and encodes all
**12 conditions**: six directed distinct-material pairs × congruent/incongruent.
Wood:brick:metal appearance masses are **1:2:8**. Simulation uses table mass 1
and ramp mass equal to the configured ramp/table ratio; violations invert the
appearance ratio. Both stimulus boxes are 0.24 × 0.24 × 0.12 m.

Physics is **240 Hz**, video **60 fps**, with exactly four physics steps per
sample interval. Each MP4 contains 800 ms empty scene, 200 ms stationary objects,
and 4.5 seconds of action: **330 frames, 5.5 seconds**. Probe stills target
−1000 ms (baseline), −200 ms (pre), +200 ms (during), and +1000 ms (post)
relative to exact first object-to-object contact.
The generated manifest supplies per-condition frame numbers and decoded stills.

Edit physics/conditions in [`stimuli/config/stimuli.toml`](stimuli/config/stimuli.toml),
render/intro settings in [`stimuli/build_stimuli.py`](stimuli/build_stimuli.py),
and camera/materials in [`stimuli/blender/render_stimuli.py`](stimuli/blender/render_stimuli.py).
See the [build guide](stimuli/README.md) for every parameter, output path,
individual stages, and a one-condition still preview.

`load_stimuli()` returns validated `StimulusSpec` values in config order.
`stimulus_scene_kwargs(spec)` passes that condition's geometry and physical
settings to `create_ramp_simulation`. General scene APIs retain their original
object dimension and position defaults; stimulus overrides are explicit.
Ramp placement now offsets the center along the correct surface normal.

The exporter directly calls `pb.stepSimulation`, detects contact on each tick,
and records PyBullet poses/velocities. Blender replays the recorded transforms
without rigid-body simulation. Physics clocks are independent of rendering.
**The PhySMC/inference clock is deliberately unchanged and requires later repair
before fitting human data.** Its current inclusive stepping loop can advance
five ticks instead of four. The new stimulus ratios also require reviewing
model prior support before fitting.

## Experiment

The [experiment guide](experiment/README.md) describes the Vite/jsPsych app and
JATOS setup. Each study uses one timing (pre/during/post): six baseline and six
congruent trials shuffled together, then one final incongruent trial for
during/post only.
Shared JATOS quotas allocate 20 participants per incongruent pair: recruit 120
during + 120 post; choose a separate sample size for the pre study. The mass slider
allows estimates up to 10× in either direction. Rebuild all stimuli before
running the app because previous manifests do not contain the new probe stills.

## Lightweight checks

```sh
python test/test_stimuli_build.py
npm test --prefix experiment
julia --startup-file=no --compiled-modules=existing --project=. test/runtests.jl
```

These check synthetic video intro/probe encoding and the 12-condition
configuration respectively; neither runs physics, models, or Blender.
