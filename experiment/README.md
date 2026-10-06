# Relative mass experiment

This TypeScript/Vite/jsPsych 8 experiment uses the existing MP4s in
`../stimuli/generated/videos/`. Those files and `video_manifest.json` must be
present locally. From this `experiment/` directory, with Node.js and npm:

```sh
npm install
npm run dev       # open the URL Vite prints
npm run build     # checks configuration and creates static dist/
npm run preview   # serves dist/ locally
```

From the repository root, first run `cd experiment`. Open `/?preview=1` for
researcher controls and assignments. Use `/?condition_group=1`, `2`, or `3` to
preselect a group; combine them as `/?preview=1&condition_group=2`. The start
screen has a group selector in local and preview runs. In an ordinary JATOS
run, one group is assigned at random and the selector is hidden. A
`condition_group` parameter on the JATOS launch URL overrides that assignment
for testing. This is independent random assignment, not a quota-balanced
allocation across participants. JATOS participants see a brief video-loading
message and then the welcome page automatically, with no Start button.
Preview mode shows the shuffled trial order,
lets you replay the current trial, switch groups, and restart. Normal mode hides
those controls.

After loading, participants see a welcome page and short task instructions,
followed by a practice trial using one ordinary video. The practice trial
pauses after the collision and uses the same mass and confidence sliders as the
main trials. Two multiple-choice questions follow. Both must be correct to
continue; otherwise the welcome, instructions, and practice repeat. The four
main trials then run as before. An optional two-question debrief appears before
the completion message.
After both quiz answers are correct, a five-second countdown leads into the
first trial's fixation screen. On each response screen, participants must move
both the mass and confidence sliders before Continue is enabled.

Edit **[`app/experiment.config.ts`](app/experiment.config.ts)** for video names,
scene IDs, ordinary/violation status, the three group rotations, probe frames,
the final trial's random collision/post-collision choices, instructions, response
wording, slider values, fixation duration, freeze-frame duration
(`freezeFrameMs`, in milliseconds), and completion text. Set `freezeFrameMs`
to `0` to show the slider immediately. Frames are
zero-based MP4 frames. In the current metadata, first contact is frame 79 at
60 fps; the current pre/collision/post cuts are frames 67/87/100. The current
videos have no start hold. If you rebuild them with holds, update the probe
frames by the manifest's trajectory-frame offset. `npm run build` checks that
configured video files exist and that probe frames fit their manifest entries.
The `onboarding` section of the same file contains the welcome and instruction
pages, practice scene and probe, quiz questions and correct answer indexes, and
countdown duration (`countdown.seconds`), and optional debrief prompts. The practice scene may reuse an ordinary video; it
does not change the four main-trial assignments.

The mass slider's negative positions mean the ramp object is heavier; positive
positions mean the table object is heavier. Zero means equal mass. The separate
confidence slider runs from 0% to 100%, starting at 50%. At 0%, its solid range
bar spans the full mass scale; at 100%, it collapses to the mass estimate. The
response labels are editable in `app/experiment.config.ts`.

The app fetches and decodes all four required videos before the instructions.
Playback uses `requestVideoFrameCallback()` and the manifest FPS to cut at the
configured frame; older browsers use `currentTime` with an animation-frame
check. A canvas masks the source video, so late callbacks cannot reveal later
frames. After the cut, the video element is removed and the canvas holds the
last displayed frame for `freezeFrameMs` before the slider appears. A busy
browser may cut one displayed frame early.

## JATOS setup

The build contains `index.html`, the bundled app, fonts, and MP4s. JATOS serves
`jatos.js` automatically, so that file is intentionally absent from `dist/`.
In your local JATOS GUI, create a study and copy the **contents** of
`experiment/dist/` into that study's assets directory under
`/Users/aryanagarwal/Downloads/jatos/study_assets_root/`. Add one component
whose HTML file is `index.html`, then run that component through JATOS. Do not
copy files into `study_assets_root/` before creating the study: JATOS creates a
separate assets directory for each study. The downloaded JATOS installation is
not modified by this repository.

JATOS must initialize before the experiment starts. At completion, the app
submits `jsPsych.data.get().json()` and ends the study without redirecting away
from the completion message. If submission fails, the page offers a retry and
keeps the data in memory. The JATOS launch URL may include `PROLIFIC_PID`,
`STUDY_ID`, and `SESSION_ID`; missing values are recorded as `null`. No Prolific
redirect is implemented.

## Recorded data

Each JATOS result is a JSON array of jsPsych records. Every record includes a
schema version, run ID, counterbalancing group, Prolific IDs, JATOS IDs, and
preview status. The `session` record contains the randomized trial order,
timing and slider settings, preload errors, and browser information.
`scene_trial` records contain the scene, video, `behavioral_trial_type`
(ordinary/violation/practice), probe, requested frame and time, observed cut frame and time, last canvas
frame shown, stop method, playback attempts and errors, mass estimate, mass
ratio, confidence, and response timings. `comprehension_quiz` records contain
each attempt and answer; `debrief` contains the optional text responses; the
`summary` contains the number of quiz attempts and instruction loops. Time
durations are in milliseconds, video times in seconds, and timestamps are UTC.
On a time-based fallback, frame numbers are estimates from the manifest FPS.
The `group_assignment_method` field identifies a random assignment, URL
override, or researcher selection.

Outside JATOS, including `npm run dev`, `npm run preview`, and a static host,
the experiment runs but does not save or submit data. Data remains in memory
until the page is refreshed. A static host is suitable for instructor review;
use JATOS to record results. Serve the build over HTTP(S), since opening
`index.html` directly as `file://` is unsupported.
