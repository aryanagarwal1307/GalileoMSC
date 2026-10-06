/**
 * Researcher editing point for the visual prototype.
 *
 * Video names must match ../stimuli/generated/videos/video_manifest.json. Scene IDs
 * identify physical setups: use each ID only once in a four-trial run. Frames
 * are zero-based MP4 frames at the manifest's 60 fps. First physical contact is
 * frame 79 in the current trajectory metadata. The configured collision frame
 * is a few frames later so the effect is visible before the cut.
 *
 * The ramp object moves; the table object is initially stationary.
 * Changing text, frame targets, videos, groups, slider, or timing needs no edits
 * elsewhere. `npm run build` checks the manifest and files.
 */
export const experimentConfig = {
  scenes: [
    { sceneId: "wood_to_brick", kind: "ordinary", video: "wood_to_brick_congruent.mp4" },
    { sceneId: "brick_to_wood", kind: "ordinary", video: "brick_to_wood_congruent.mp4" },
    { sceneId: "metal_to_wood", kind: "ordinary", video: "metal_to_wood_congruent.mp4" },
    { sceneId: "wood_to_metal", kind: "violation", video: "wood_to_metal_violation.mp4" },
  ],
  // Each group uses all three probe positions once among the ordinary scenes.
  // Ordinary scene order is shuffled anew when Start is pressed.
  groups: {
    "1": { wood_to_brick: "preCollision", brick_to_wood: "collision", metal_to_wood: "postCollision" },
    "2": { wood_to_brick: "collision", brick_to_wood: "postCollision", metal_to_wood: "preCollision" },
    "3": { wood_to_brick: "postCollision", brick_to_wood: "preCollision", metal_to_wood: "collision" },
  },
  probeFrames: {
    preCollision: 67,
    collision: 87,
    postCollision: 100,
  },
  // Trial 4 always uses one of these, chosen at random for each run.
  violationProbeChoices: ["collision", "postCollision"],
  fixationMs: 1500,
  // Hold the last visible video frame before showing the response slider.
  // Set to 0 for an immediate transition. Duration is in milliseconds.
  freezeFrameMs: 1500,
  instructions: {
    title: "Estimate the objects' relative mass",
    body: "You will watch two objects interact. The video will randomly pause at some point. After each video pauses, you will be asked about the relative mass of the two objects.",
    startButton: "Begin",
    ready: "+",
    responseQuestion: "How heavy is the ramp object compared with the table object?",
    confidenceQuestion: "How confident are you in your estimate?",
    rampObjectName: "ramp object",
    tableObjectName: "table object",
    rangeLabel: "Your Answer",
    leftLabel: "ramp object heavier",
    centerLabel: "Equal mass",
    rightLabel: "table object heavier",
    continueButton: "Continue",
  },
  slider: {
    // Negative = ramp object heavier; positive = table object heavier.
    min: -100,
    max: 100,
    step: 1,
    initialMean: 0,
    maxMultiple: 4,
    confidenceMin: 0,
    confidenceMax: 100,
    confidenceStep: 1,
    initialConfidence: 50,
    valueUnit: "%",
  },
  completionMessage: "You have completed the experiment. Thank you.",
} as const;

export type ExperimentConfig = typeof experimentConfig;
export type ProbeName = keyof ExperimentConfig["probeFrames"];
export type GroupName = keyof ExperimentConfig["groups"];
export type Scene = ExperimentConfig["scenes"][number];
