# Relative mass experiment

This TypeScript/Vite/jsPsych app uses MP4s and exact probe PNGs from
`../stimuli/generated/videos/`. Rebuild both the 12 main stimuli and the separate
practice stimulus before building the app. Old manifests are deliberately rejected:
they lack the baseline probe and use different pre/during offsets.

```sh
# Repository root; run these yourself when ready to regenerate stimuli.
python stimuli/build_stimuli.py --all
python stimuli/build_stimuli.py --practice
cd experiment
npm install
npm test
npm run build
npm run dev
```

Local preview: `/?preview=1&experiment_type=during` (also `pre` or `post`).
The start screen selects the study type and, in preview mode, the incongruent
pair. `probe_pair=brick_to_metal` can preselect a preview pair. Preview displays
the shuffled plan, replay and restart controls. Local/static runs keep data in
memory; use JATOS for saved results. Serve over HTTP(S), not `file://`.

## Trial design

Each participant belongs to one study type for the entire experiment. The six
baseline trials and six assigned-timing congruent trials are shuffled together
across the first 12 trials. Each trial type includes all six directed
distinct-material pairs once: wood→brick, brick→wood, wood→metal, metal→wood,
brick→metal, metal→brick. The incongruent probe remains last for during/post.

| Phase | Trials | Stimuli | Freeze relative to first contact |
|---|---:|---|---|
| Baseline, every study | Mixed within 1–12 | Six congruent videos | −1000 ms |
| Assigned study timing | Mixed within 1–12 | Six congruent videos | pre: −200 ms; during: +200 ms; post: +1000 ms |
| Incongruent probe | 13, during/post only | One of six incongruent videos | Same timing as the assigned study phase |

The pre study ends after 12 main trials. During/post have 13. Practice is separate.
The old within-participant timing rotations and `condition_group` are removed.
The filename suffix `violation` still identifies an incongruent video.

Participants first read the supplied consent form and check its agreement box
before selecting **Begin**. The form is loaded with `@jspsych/plugin-external-html`
from `assets/consent.html`; Vite includes it in the built app automatically. The
copy preserves the supplied HTML text, agreement checkbox, Begin button, and
print button. Edit that repository copy for future consent-form updates.

After consent, the app allocates the incongruent probe (when applicable), preloads
videos, and requests fullscreen. Participants then read instructions and complete the equal-mass gray
practice trial and see: “The two blocks had equal mass. You will not receive any
more feedback during the main experiment.” They then answer two comprehension
questions. Failed quizzes repeat instructions/practice. A **3-second** countdown
leads into the main trials. Both response sliders must be moved before Continue.
The debrief contains three required yes/no questions and two optional written
questions. No main-trial correctness feedback is given.

`app/experiment.config.ts` contains wording, scene selection, the four offsets,
fixation (2000 ms), freeze duration (`freezeFrameMs`, 1500 ms), and sliders.
The mass scale permits 10× in either direction; zero is equal mass. Confidence
ranges from 0–100%. The video includes an 800 ms empty scene and 200 ms stationary
objects. Canvas playback switches to the exact decoded probe still at the cut.
A **pause icon and “Paused” badge** appear in the upper right only during the
freeze, without covering the blocks. The response screen follows the freeze.
Exiting fullscreen blocks progression and pauses active video playback.

## JATOS and Prolific: three studies, balanced probes

Create three JATOS studies using the same build. Set each study's **JSON input**
(as an object, not a string) to one of:

```json
{"experiment_type":"pre"}
```

```json
{"experiment_type":"during"}
```

```json
{"experiment_type":"post"}
```

In ordinary JATOS runs this setting is required and authoritative. URL parameters
cannot switch a participant's type. Local/preview selections do not consume quotas.
Copy the contents of `dist/` into each study's JATOS-created assets directory and
create a component whose HTML file is `index.html`. JATOS supplies `jatos.js`.

For the **240 incongruent-probe participants**, recruit **120 in the during study
and 120 in the post study**, using one production batch per study. This is two
Prolific studies, not twelve. The pre study needs an additional, separately chosen
sample size because it contributes no incongruent probes. Prolific launch URLs may
include `PROLIFIC_PID`, `STUDY_ID`, and `SESSION_ID`; these are recorded. In each
JATOS study's **Study Properties**, set **End Redirect URL** to the matching
Prolific completion URL (which includes its completion code). After responses
and probe quotas are saved, the app calls `jatos.endStudy()` to follow that
redirect. If the field is left empty, JATOS displays its default end page.

The app automatically creates a shared Batch Session entry named
`galileo_probe_quotas_v1_during` or `galileo_probe_quotas_v1_post`. For each arrival,
it reserves a pair among those with the fewest completed-plus-reserved places,
breaking ties randomly. Each pair has a cap of **20**. Thus every block of six
allocations covers all six pairs, and 120 assignments give exactly 20 per pair.
The key and participant reservation persist on the JATOS server. Reloads/retries
reuse the assignment. JATOS versioning rejects conflicting simultaneous writes;
the app re-reads and recomputes before retrying. It never falls back to unbalanced
random allocation on a quota/network error. This uses the documented
[JATOS Batch Session/versioning API](https://www.jatos.org/jatos.js-Reference.html#jatosbatchsessionversioning).

A reservation becomes `completed` after results are submitted successfully, before
the study ends. Submission/quota failures offer a retry with data retained in
memory. A full quota prevents further allocations. The relevant namespace has this
shape (the app initializes it automatically):

```json
{
  "type": "during",
  "target": 20,
  "reservations": {
    "participant_EXAMPLE_PID": {
      "pair": "wood_to_brick",
      "status": "reserved",
      "reservedAt": "2026-10-22T12:00:00.000Z"
    }
  }
}
```

**Attrition/top-ups:** 240 starts cannot guarantee 240 completed responses. In
JATOS's Batch Session editor, inspect `reservations`; count `completed` entries
per pair. After confirming that an abandoned run cannot resume and has no usable
response, change only that participant's `status` from `reserved` to `released`.
Recruit replacement places in the same study/batch; the allocator fills those
vacancies. An excluded completed record can likewise be released after review.
Do not delete/reset the namespace during recruitment. Reservations do not expire
automatically, preventing late participants from overrunning reallocated slots.
Make these edits between recruitment waves, after active runs have finished.
Use a separate batch for testing so test reservations do not consume live places.

## Recorded data and checks

Every result record includes `experiment_type`, `assignment_method`, incongruent
pair/quota key, run ID, Prolific IDs, JATOS IDs, and preview status. `session`
contains the actual trial order and settings. Each `scene_trial` includes
`trial_phase` (baseline/congruent/incongruent/practice), scene and condition,
`probe_condition`, `probe_offset_ms`, exact requested frame/time, response values,
confidence, response timings and playback attempts/errors. The `consent` record
includes the loaded form URL, response time (`rt`), `consented: true`, and
`consented_at`. Consent is shown once, before preparation/fullscreen, and is
outside the quiz retry loop. It is submitted with the other records at completion.
Quiz, practice-feedback,
debrief and summary records are also saved. Durations are milliseconds, video times
are seconds, and timestamps are UTC.

`npm test` checks consent gating and setup retry/progression in a DOM test,
plus all study plans, stale probe metadata, quotas, idempotence and
simulated concurrent JATOS arrivals/completions. `npm run build` also checks all
required video/probe assets. Rebuild stimuli before expecting that production
check to pass. Fullscreen/playback behavior should be checked in your deployed
JATOS browser before recruitment.
