/** Probe offsets are relative to exact first physical contact. */
export const materialPairs = [
  "wood_to_brick", "brick_to_wood", "wood_to_metal",
  "metal_to_wood", "brick_to_metal", "metal_to_brick",
] as const;
export type MaterialPair = typeof materialPairs[number];
export type StudyType = "pre" | "during" | "post";
export type Scene = { sceneId: string; kind: "congruent" | "incongruent" | "practice"; video: string };

export const experimentConfig = {
  scenes: materialPairs.flatMap((sceneId): Scene[] => [
    { sceneId, kind: "congruent", video: `${sceneId}_congruent.mp4` },
    { sceneId, kind: "incongruent", video: `${sceneId}_violation.mp4` },
  ]),
  // Set experiment_type in each JATOS study's JSON input. This is a local default.
  defaultStudyType: "pre" as StudyType,
  studyProbes: { pre: "preCollision", during: "collision", post: "postCollision" },
  probeOffsetsMs: {
    baseline: -1000,
    preCollision: -200,
    collision: 200,
    postCollision: 1000,
  },
  recruitment: { quotaPerPair: 40, batchSessionKey: "galileo_probe_quotas_v1" },
  fixationMs: 2000,
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
  // Practice uses a separate equal-mass solid-gray scene.
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
          "This task can be challenging. Sometimes you will be certain about your response; other times you may not be. Give your best estimate each time.",
          "There are {trialCount} short trials. Please stay focused while each scene plays.",
        ],
      },
      {
        title: "What you will do",
        paragraphs: [
          "You will watch an object on a ramp move towards another object on a table. The video will pause before or after their collision.",
          "After it pauses, use the first slider to estimate how heavy the ramp object is compared with the table object. Use the second slider to show how confident you are in that estimate.",
          "There's no need to think for too long on each trial - just provide your best guess.",
        ],
      },
      {
        title: "Practice",
        paragraphs: [
          "Next, you will see a practice scene and try both sliders. The practice scene will not count as one of the main trials.",
        ],
      },
    ],
    nextButton: "Next",
    practice: {
      scene: { sceneId: "practice_equal_mass", kind: "practice", video: "practice_equal_mass.mp4" },
      probe: "postCollision",
      label: "Practice",
      feedback: "The two blocks had equal mass. You will not receive any more feedback during the main experiment.",
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
      retryMessage: "You answered one or more questions incorrectly. Please review the instructions and practice scene, then try again.",
      retryButton: "Review instructions",
    },
    countdown: {
      title: "The experiment begins in",
      seconds: 3,
    },
    debrief: {
      title: "Before you finish",
      requiredQuestions: [
        {
          id: "understood_instructions",
          prompt: "Were you able to understand the instructions?",
        },
        {
          id: "undivided_attention",
          prompt: "Were you able to give the task your full attention throughout?",
          detail: "Please select No if you had any distractions, such as a phone call. You will receive full credit regardless of your answer. Please answer honestly to help us assess data quality.",
        },
        {
          id: "noticed_materials_and_weights",
          prompt: "Did you notice that the objects differed in their materials and weights?",
        },
      ],
      yesLabel: "Yes",
      noLabel: "No",
      optionalNote: "The two written questions below are optional.",
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
    maxMultiple: 10,
    confidenceMin: 0,
    confidenceMax: 100,
    confidenceStep: 1,
    initialConfidence: 50,
    valueUnit: "%",
  },
  completionMessage: "You have completed the experiment. Thank you.",
} as const;

export type ExperimentConfig = typeof experimentConfig;
export type ProbeName = keyof ExperimentConfig["probeOffsetsMs"];
