# Complete stimulus videos

For the complete resumable workflow, use
`python stimuli/build_stimuli.py --all`; see the [master build guide](../README.md).
The commands below expose the encoding stage separately.

Run from the repository root with Python 3.8+ and FFmpeg/FFprobe on `PATH`.
FFmpeg must include `libx264`; the installed FFmpeg 7.0.1 supports it.
No additional Python packages are needed.

```sh
# Inspect all eight encoding commands without writing files.
python3 stimuli/video/encode_videos.py --all --dry-run

# Encode one complete condition.
python3 stimuli/video/encode_videos.py --condition wood_to_metal_violation

# Encode and verify all eight complete conditions.
python3 stimuli/video/encode_videos.py --all

# Explicitly replace existing selected videos.
python3 stimuli/video/encode_videos.py --all --overwrite
```

Inputs default to `stimuli/generated/trajectories/*.json` and
`results/stimuli/final/pngs/<condition_id>/`. There is currently no separate
generated trajectory manifest: condition IDs and enabled status come from the
trajectory JSON metadata, not a hard-coded list or PNG directory names. `--all`
requires exactly eight unique enabled conditions. Duplicate trajectory IDs,
missing exports, incomplete renders, smoke renders, missing/extra PNGs, stale
trajectory hashes, or inconsistent resolution/FPS/frame counts fail preflight.
Every PNG header is checked against its render metadata; FFmpeg decodes the
images during encoding. `--condition` validates the named condition and any
previously manifested videos retained alongside it.

Use `--trajectory-dir`, `--frames-dir`, or `--output-dir` to override directories.
For renders in the renderer's default directory, pass
`--frames-dir stimuli/generated/frames`. Output defaults to:

```text
stimuli/generated/videos/<condition_id>.mp4
stimuli/generated/videos/video_manifest.json
```

The output directory is ignored by Git. The newer video pipeline uses this
location, rather than the earlier reserved `results/stimuli/final/videos/` folder.
An existing selected MP4 is never silently overwritten, including during a dry
run: use `--overwrite` explicitly. A dry run performs source preflight and prints
shell-quoted FFmpeg commands but does not encode, probe existing videos, or write
files. Actual encodes use temporary files in the output directory and publish
each video only after verification. No temporary partial encode replaces a good
existing video. A `.encode.lock` prevents concurrent encoders from racing on the
manifest; an interrupted process may leave a lock, which should be removed only
after confirming that process has stopped.

## Timing and encoding

Each video contains **every frame, including frame zero and the final frame**.
There is no collision-based truncation, stopping-frame option, or trial-specific
duration variant. Trial-specific stopping belongs in jsPsych. CFR comes from render metadata,
and all eight videos must share FPS, frame count, resolution, and exact duration.

Current inputs are 200 frames at 60 fps, 960×540. Each MP4 therefore lasts
**200 / 60 = 3.333333… seconds**. The last trajectory sample is at 199 / 60 seconds;
the final frame is displayed for one additional frame interval in the video.
These standalone defaults have no endpoint holds. Pass `--hold-start 0.5 --hold-end 0.5`
to clone each endpoint for 30 additional frames at 60 fps, producing 260 frames
and 4.333333 seconds. The master defaults to these holds. Durations must be exact
whole-frame intervals; no original frames are dropped. The manifest records the
hold counts and `trajectory_frame_offset` for jsPsych's stopping-frame mapping.

Settings are H.264 (`libx264`), `yuv420p`, CRF **15**, preset **slow**, no audio,
and MP4 `faststart` for browser playback. Use `--crf 0..51` to change quality;
use `--preset` to change encoding speed. There is no frame-rate override.
Encoding uses one codec/filter thread, fixed
options and timebases, bitexact flags, and removes inherited metadata. Repeated
encodes are deterministic with unchanged PNGs, settings, and FFmpeg/libx264 build
on the same platform; identical bytes across software versions are not promised.
PNG input is lossless; H.264 at CRF 15 is visually high quality but lossy.

FFprobe decodes each output to verify H.264, `yuv420p`, dimensions, nominal and
average FPS, frame count, exact stream duration, container duration, absence of
audio, and every presentation timestamp for CFR. The script also checks that the
MP4 `moov` atom precedes `mdat` for faststart. It fails if outputs differ in frame
count or duration. Validation does not change PyBullet trajectories or model clocks.

## Manifest and unattended execution

The manifest stores condition IDs, video paths relative to its directory, FPS,
frame count, resolution, duration, video hashes, FFmpeg/FFprobe versions, commands,
and a full copy of each source render's metadata with its path and SHA-256 hash.
It updates atomically after each verified video. `complete_eight_conditions: true`
means all eight records are present and match; a failed run may leave a partial
manifest and previously verified videos. A one-condition invocation preserves and
re-probes unselected manifest entries instead of discarding them.

To run without keeping a terminal attached:

```sh
mkdir -p results/stimuli/final
nohup python3 -u stimuli/video/encode_videos.py --all \
  > results/stimuli/final/encode_all.log 2>&1 < /dev/null &
```

On success the log ends with `Complete: 8 video(s) encoded and verified.`
Errors produce a nonzero exit code and an `ERROR:` message. Rerunning a partial
job requires `--overwrite` for files already produced, or individual commands for
the remaining conditions.
