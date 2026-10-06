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
    ready: "+",
    responseQuestion: "Which object is heavier?",
    confidenceQuestion: "How confident are you in your estimate?",
    rampObjectName: "ramp object",
    tableObjectName: "table object",
    rangeLabel: "Your Answer",
    leftLabel: "ramp object heavier",
    centerLabel: "Equal mass",
    rightLabel: "table object heavier",
    continueButton: "Continue",
  },
  // Welcome, instruction, practice, quiz, and debrief wording all live here.
  // Practice repeats one ordinary video and does not change the four main trials.
  onboarding: {
    welcome: {
      title: "Hi, welcome to our study!",
      paragraphs: [
        "Please adjust your seating so you can comfortably watch the screen and use your mouse or keyboard.",
        "If helpful, dim the lights, close the door, and silence your phone to reduce distractions.",
        "When you are ready, continue to the instructions.",
      ],
    },
    instructionPages: [
      {
        title: "Instructions",
        paragraphs: [
          "This task can be challenging. Sometimes you will be certain about what you saw; other times you may not be. Give your best estimate each time.",
          "There are four short trials. Please stay focused while each scene plays.",
        ],
      },
      {
        title: "What you will do",
        paragraphs: [
          "You will watch an object on a ramp move towards another object on a table. The video will pause before, during, or after their collision.",
          "After it pauses, use the first slider to estimate how heavy the ramp object is compared with the table object. Use the second slider to show how confident you are in that estimate.",
          "There's no need to think for too long on each trial - just provide your best guess.",
        ],
      },
      {
        title: "Practice",
        paragraphs: [
          "Next, you will see a practice scene and try both sliders. The practice scene will not count as one of the four trials.",
        ],
      },
    ],
    nextButton: "Next",
    practice: {
      sceneId: "wood_to_brick",
      probe: "postCollision",
      label: "Practice",
    },
    quiz: {
      title: "Check your understanding",
      questions: [
        {
          prompt: "What should you estimate after a video pauses?",
          options: [
            "How heavy the ramp object is",
            "How fast the ramp object was moving",
            "How heavy the ramp object is compared with the table object",
          ],
          correctIndex: 2,
        },
        {
          prompt: "What should you do when you are unsure?",
          options: [
            "Skip the trial",
            "Give your best estimate and indicate your confidence",
            "Wait for the video to play again",
          ],
          correctIndex: 1,
        },
      ],
      submitButton: "Continue",
      retryMessage: "Please review the instructions and practice scene, then try again.",
      retryButton: "Review instructions",
    },
    countdown: {
      title: "The experiment begins in",
      seconds: 5,
    },
    debrief: {
      title: "Before you finish",
      optionalNote: "Both questions are optional.",
      strategyQuestion: "Did you use any strategies while doing this task?",
      commentsQuestion: "Do you have any additional comments?",
      finishButton: "Finish",
    },
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
