# Video encoding

Use `python stimuli/build_stimuli.py --all` for the whole pipeline. To re-encode
already exported and rendered conditions, run from the repository root:

```sh
source py-env/bin/activate
python stimuli/video/encode_videos.py --all
```

The encoder reads enabled IDs from `stimuli/config/stimuli.toml`, trajectories
from `stimuli/generated/trajectories/`, and complete rendered sequences from
`results/stimuli/final/pngs/<id>/`. Each render must include `empty_scene.png`,
270 action PNGs, and complete render metadata with matching stimulus settings.
Use `--trajectory-dir`, `--frames-dir`, or `--output-dir` to override paths.

Default output: `stimuli/generated/videos/`, with 12 MP4s, 48 decoded probe PNGs,
and `video_manifest.json`. MP4s are 60 fps, 5.5 seconds, H.264/yuv420p, CRF 15,
preset slow, faststart, without audio. Each contains 48 empty-scene frames,
12 additional initial-object frames, then all 270 action frames. There is no
endpoint hold or trial-specific trimming.

Optional `--empty-scene-seconds`, `--object-preview-seconds`, `--crf`, and
`--preset` change encoding settings. Intro durations must be whole-frame
intervals. Physics and video FPS come from the input metadata.

The four probe targets use the exact first-contact time plus −1000/−200/+200/+1000 ms,
rounded to the nearest action frame (ties later), then shifted by the intro.
The probe PNGs are decoded from those exact MP4 frames. jsPsych preloads them
and displays the requested still at the cut, even if a browser callback is late.
The manifest records frames, times, offsets and still filenames per condition.

Encoding verifies format, dimensions, FPS, decoded frame count and duration.
Videos and stills are prepared in a temporary directory before publication.
There are no source/video hashes, schemas, or full timestamp reports. A selected
build replaces its outputs; `--condition ID` produces a manifest containing only
that condition, so re-run `--all` before building the experiment.
