import { initJsPsych, ParameterType, type JsPsych } from "jspsych";
import "jspsych/css/jspsych.css";
import "@fontsource/literata/latin-300.css";
import "@fontsource/literata/latin-400.css";
import "@fontsource/literata/latin-600.css";
import "@fontsource/literata/latin-700.css";
import { experimentConfig as config, materialPairs, type MaterialPair, type StudyType, type ProbeName, type Scene } from "./experiment.config";
import { probeFor, validateExperiment, videoEntryFor, type VideoManifest } from "./validate";
import { planTrials, trialCount, type PlannedTrial } from "./design";
import { allocateProbe, completeProbe, type ProbeAllocation } from "./allocation";
import { createMassResponseControl } from "./slider";
import { createConsentTrial } from "./consent";
import { PreparationPlugin } from "./preparation";
import consentUrl from "../assets/consent.html?url";
import type { JatosApi } from "./jatos";
import manifest from "../../stimuli/generated/videos/video_manifest.json";
import "./style.css";

type Assignment = PlannedTrial & { frame: number };
const app = document.querySelector<HTMLElement>("#app")!;
const params = new URLSearchParams(location.search);
let previewMode = params.get("preview") === "1";
let requestedType = params.get("experiment_type");
const studyTypes: StudyType[] = ["pre", "during", "post"];
const videoUrls = new Map<string, string>();
const probeImages = new Map<string, HTMLImageElement>();
const targetFor = (scene: Scene, probe: ProbeName) => probeFor(scene, probe, manifest as VideoManifest);
let previewPanel: HTMLElement | null = null;
let previewPlan: HTMLElement | null = null;
let activeReplay: (() => void) | null = null;
let selectedType: StudyType = studyTypes.includes(requestedType as StudyType) ? requestedType as StudyType : config.defaultStudyType;
let assignmentMethod = "researcher_selection";
let probeAllocation: ProbeAllocation | null = null;
let criticalPair: MaterialPair | null = null;
let jsPsych: JsPsych;
let quizPassed = false;
let quizAttempts = 0;
let failedQuizAttempts = 0;
let jatosApi: JatosApi | null = null;
const preloadErrors: string[] = [];
let fullscreenRequired = false;
let fullscreenOverlay: HTMLElement | null = null;
let pausedForFullscreen: HTMLVideoElement | null = null;
let resumeAfterFullscreen = false;

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", text = ""): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

function fullscreenCapabilityError(): string | null {
  if (!document.fullscreenEnabled) return "Fullscreen is unavailable in this browser window.";
  return null;
}

async function enterRequiredFullscreen(): Promise<string | null> {
  const capabilityError = fullscreenCapabilityError();
  if (capabilityError) return capabilityError;
  try {
    if (!document.fullscreenElement) await document.documentElement.requestFullscreen();
  } catch {
    return "Fullscreen was blocked. Allow fullscreen and try again.";
  }
  if (!document.fullscreenElement) return "Fullscreen did not start. Please try again.";
  return null;
}

document.addEventListener("fullscreenchange", () => {
  if (!fullscreenRequired) return;
  if (document.fullscreenElement) {
    fullscreenOverlay?.remove();
    fullscreenOverlay = null;
    if (resumeAfterFullscreen && pausedForFullscreen?.isConnected) {
      void pausedForFullscreen.play().catch(() => {});
    }
    pausedForFullscreen = null;
    resumeAfterFullscreen = false;
    return;
  }
  pausedForFullscreen = document.querySelector<HTMLVideoElement>(".video-source");
  resumeAfterFullscreen = Boolean(pausedForFullscreen && !pausedForFullscreen.paused);
  pausedForFullscreen?.pause();
  if (fullscreenOverlay) return;
  const overlay = element("div", "fullscreen-overlay");
  const card = element("div", "start-card");
  card.append(element("h2", "", "Return to fullscreen"));
  card.append(element("p", "muted", "The experiment requires fullscreen. Playback is paused until you return."));
  const status = element("p", "status-error");
  status.setAttribute("role", "alert");
  const button = element("button", "primary-button", "Return to fullscreen") as HTMLButtonElement;
  button.addEventListener("click", async () => {
    button.disabled = true;
    const error = await enterRequiredFullscreen();
    status.textContent = error ?? "";
    button.disabled = false;
  });
  card.append(status, button);
  overlay.append(card);
  document.body.append(overlay);
  fullscreenOverlay = overlay;
});

function planFor(type: StudyType): Assignment[] {
  return planTrials(type, criticalPair).map((assignment) => ({
    ...assignment, frame: targetFor(assignment.scene, assignment.probe).frame,
  }));
}

function describeAssignment(assignment: Assignment): string {
  return `${assignment.scene.sceneId} · ${assignment.phase} · ${assignment.probe} · frame ${assignment.frame}`;
}

function showPreviewPlan(plan: Assignment[], currentIndex = -1): void {
  if (!previewPlan) return;
  previewPlan.replaceChildren(element("h3", "", `Study: ${selectedType} · ${plan.length} trials`));
  const list = element("ol", "assignment-list");
  plan.forEach((assignment, index) => {
    const item = element("li", index === currentIndex ? "is-current" : "", describeAssignment(assignment));
    list.append(item);
  });
  previewPlan.append(list);
}

function setReplayAvailable(available: boolean): void {
  const replay = (previewPanel as (HTMLElement & { replayButton?: HTMLButtonElement }) | null)?.replayButton;
  if (replay) replay.disabled = !available;
}

function showStart(error = ""): void {
  app.replaceChildren();
  previewPanel = null;
  previewPlan = null;
  activeReplay = null;
  if (jatosApi && !previewMode && !error) {
    startExperiment();
    return;
  }
  const card = element("section", "start-card");
  card.append(element("p", "eyebrow", "Visual prototype"), element("h1", "", config.instructions.title));
  card.append(element("p", "muted", `${trialCount(selectedType)} short trials`));
  const label = element("label", "field-label", "Experiment type");
  const select = element("select") as HTMLSelectElement;
  for (const type of studyTypes) {
    const option = document.createElement("option");
    option.value = type;
    option.textContent = type;
    option.selected = type === selectedType;
    select.append(option);
  }
  label.append(select);
  const showTypeSelect = !jatosApi || previewMode;
  if (showTypeSelect) card.append(label);
  select.addEventListener("change", () => { assignmentMethod = "researcher_selection"; });
  if (previewMode) {
    card.append(element("p", "preview-badge", "Researcher preview mode"));
    const note = element("p", "muted", "Six baseline trials and six congruent trials are shuffled together across the first 12 trials. During/post studies end with one incongruent trial.");
    card.append(note);
    const probeLabel = element("label", "field-label", "Preview incongruent pair");
    const probeSelect = element("select");
    materialPairs.forEach((pair) => {
      const option = element("option", "", pair);
      option.value = pair;
      option.selected = pair === (params.get("probe_pair") ?? materialPairs[0]);
      probeSelect.append(option);
    });
    probeSelect.addEventListener("change", () => { criticalPair = probeSelect.value as MaterialPair; });
    criticalPair = probeSelect.value as MaterialPair;
    probeLabel.append(probeSelect);
    card.append(probeLabel);
  }

  const status = element("p", "status-error", error);
  status.setAttribute("role", "alert");
  card.append(status);
  const start = element("button", "primary-button", "Start prototype") as HTMLButtonElement;
  start.disabled = Boolean(error);
  start.addEventListener("click", () => {
    if (showTypeSelect) selectedType = select.value as StudyType;
    startExperiment();
  });
  card.append(start);
  app.append(card);
}

async function loadVideo(scene: Scene): Promise<void> {
  const url = new URL(scene.video, document.baseURI).href;
  const entry = videoEntryFor(scene, manifest as VideoManifest)!;
  const response = await fetch(url, { cache: "default" });
  if (!response.ok) throw new Error(`${scene.video}: HTTP ${response.status}`);
  const blob = await response.blob();
  if (!blob.size) throw new Error(`${scene.video}: empty file`);
  const objectUrl = URL.createObjectURL(blob);
  try {
    await new Promise<void>((resolve, reject) => {
      const video = document.createElement("video");
      const timeout = window.setTimeout(() => reject(new Error(`${scene.video}: decoding timed out`)), 15000);
      const finish = (error?: Error) => {
        clearTimeout(timeout);
        video.removeAttribute("src");
        video.load();
        error ? reject(error) : resolve();
      };
      video.preload = "auto";
      video.muted = true;
      video.onloadeddata = () => {
        if (video.videoWidth <= 0 || !Number.isFinite(video.duration) ||
            video.duration <= targetFor(scene, "postCollision").frame / entry.fps) {
          finish(new Error(`${scene.video}: missing video frames or too short for configured probes`));
        } else {
          finish();
        }
      };
      video.onerror = () => finish(new Error(`${scene.video}: the browser cannot decode this MP4`));
      video.src = objectUrl;
      video.load();
    });
    await Promise.all((Object.keys(config.probeOffsetsMs) as ProbeName[]).map(async (probe) => {
      const image = new Image();
      image.src = new URL(targetFor(scene, probe).image_path, document.baseURI).href;
      await image.decode();
      probeImages.set(`${scene.video}:${probe}`, image);
    }));
    videoUrls.set(scene.video, objectUrl);
  } catch (error) {
    preloadErrors.push(error instanceof Error ? error.message : String(error));
    URL.revokeObjectURL(objectUrl);
    throw error;
  }
}

function startExperiment(): void {
  let plan: Assignment[] = [];
  const prepare = async () => {
    if (jatosApi && !previewMode) {
      probeAllocation = await allocateProbe(jatosApi, selectedType);
      criticalPair = probeAllocation?.pair ?? null;
      assignmentMethod = selectedType === "pre" ? "study_configuration" : "jatos_balanced_quota";
    } else if (selectedType !== "pre" && !criticalPair) {
      criticalPair = materialPairs[Math.floor(Math.random() * materialPairs.length)];
    }
    if (selectedType === "pre") criticalPair = null;
    plan = planFor(selectedType);
    const scenes = new Map([...plan.map((a) => a.scene), config.onboarding.practice.scene].map((scene) => [scene.video, scene]));
    for (const scene of scenes.values()) {
      if (!videoUrls.has(scene.video)) await loadVideo(scene);
    }
    jsPsych.data.addProperties({
      assignment_method: assignmentMethod,
      incongruent_probe_pair: criticalPair,
      quota_key: probeAllocation?.key ?? null,
    });
    showPreviewPlan(plan);
  };
  const practiceScene = config.onboarding.practice.scene;
  const practiceAssignment: Assignment = {
    scene: practiceScene,
    phase: "practice",
    probe: config.onboarding.practice.probe,
    frame: targetFor(practiceScene, config.onboarding.practice.probe).frame,
  };
  app.replaceChildren();
  const shell = element("div", "experiment-shell");
  const participant = element("section", "participant-surface");
  shell.append(participant);
  if (previewMode) {
    previewPanel = element("aside", "preview-panel");
    previewPanel.append(element("p", "preview-badge", "Researcher preview mode"));
    const typeLabel = element("label", "field-label", "Experiment type");
    const select = element("select") as HTMLSelectElement;
    for (const type of studyTypes) {
      const option = document.createElement("option");
      option.value = type;
      option.textContent = type;
      option.selected = type === selectedType;
      select.append(option);
    }
    select.addEventListener("change", () => {
      location.search = `?preview=1&experiment_type=${select.value}&probe_pair=${criticalPair ?? materialPairs[0]}`;
    });
    typeLabel.append(select);
    previewPanel.append(typeLabel);
    previewPlan = element("div", "preview-plan");
    previewPanel.append(previewPlan);
    const actions = element("div", "preview-actions");
    const replay = element("button", "secondary-button", "Replay current trial") as HTMLButtonElement;
    replay.disabled = true;
    replay.addEventListener("click", () => activeReplay?.());
    const restart = element("button", "secondary-button", "Restart experiment") as HTMLButtonElement;
    restart.addEventListener("click", () => location.reload());
    actions.append(replay, restart);
    previewPanel.append(actions);
    shell.append(previewPanel);
    previewPlan.append(element("p", "muted", "Trial assignments will appear after consent and loading."));
    (previewPanel as HTMLElement & { replayButton?: HTMLButtonElement }).replayButton = replay;
  }
  app.append(shell);
  jsPsych = initJsPsych({
    display_element: participant,
    on_finish: () => { void finishExperiment(participant); },
  });
  jsPsych.data.addProperties({
    run_id: globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    experiment_type: selectedType,
    assignment_method: assignmentMethod,
    incongruent_probe_pair: criticalPair,
    quota_key: probeAllocation?.key ?? null,
    prolific_pid: jatosApi?.urlQueryParameters.PROLIFIC_PID ?? null,
    prolific_study_id: jatosApi?.urlQueryParameters.STUDY_ID ?? null,
    prolific_session_id: jatosApi?.urlQueryParameters.SESSION_ID ?? null,
    jatos_study_id: jatosApi?.studyId ?? null,
    jatos_component_id: jatosApi?.componentId ?? null,
    jatos_batch_id: jatosApi?.batchId ?? null,
    jatos_worker_id: jatosApi?.workerId ?? null,
    jatos_study_result_id: jatosApi?.studyResultId ?? null,
    jatos_component_result_id: jatosApi?.componentResultId ?? null,
    researcher_preview: previewMode,
  });
  quizPassed = false;
  quizAttempts = 0;
  failedQuizAttempts = 0;
  jsPsych.run([
    createConsentTrial(consentUrl, participant),
    { type: PreparationPlugin, prepare },
    { type: FullscreenGatePlugin },
    { type: SessionPlugin, plan: () => plan },
    {
      timeline: [
        { type: IntroPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
        { type: SceneTrialPlugin, assignment: practiceAssignment, index: -1, practice: true,
          on_start: () => { showPreviewPlan(plan); setReplayAvailable(true); } },
        { type: PracticeFeedbackPlugin },
        { type: QuizPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
      ],
      loop_function: () => !quizPassed,
    },
    { type: CountdownPlugin },
    ...Array.from({ length: trialCount(selectedType) }, (_, index) => ({ type: SceneTrialPlugin, assignment: () => plan[index], index, on_start: () => {
      showPreviewPlan(plan, index);
      setReplayAvailable(true);
    } })),
    { type: DebriefPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
    { type: SummaryPlugin },
  ] as any);
}

async function finishExperiment(participant: HTMLElement): Promise<void> {
  fullscreenRequired = false;
  fullscreenOverlay?.remove();
  fullscreenOverlay = null;
  activeReplay = null;
  setReplayAvailable(false);
  for (const url of videoUrls.values()) URL.revokeObjectURL(url);
  videoUrls.clear();
  if (!jatosApi) {
    participant.replaceChildren(element("div", "complete-screen", config.completionMessage));
    return;
  }
  const payload = jsPsych.data.get().json();
  const submit = async () => {
    participant.replaceChildren(element("div", "complete-screen", "Submitting responses…"));
    try {
      await jatosApi!.submitResultData(payload);
      if (probeAllocation) await completeProbe(jatosApi!, probeAllocation, selectedType);
      // JATOS follows the End Redirect URL configured in the study properties.
      jatosApi!.endStudy();
    } catch {
      const screen = element("div", "complete-screen");
      screen.append(element("p", "status-error", "Responses could not be submitted. Please keep this page open and retry."));
      const retry = element("button", "primary-button", "Retry submission");
      retry.addEventListener("click", () => { void submit(); });
      screen.append(retry);
      participant.replaceChildren(screen);
    }
  };
  await submit();
}

class FullscreenGatePlugin {
  static info = { name: "experiment-fullscreen-gate", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const screen = element("div", "intro-screen");
    screen.append(element("h1", "", "Fullscreen required"));
    screen.append(element("p", "intro-copy", "The experiment will enter fullscreen when you continue."));
    const status = element("p", "status-error", fullscreenCapabilityError() ?? "");
    status.setAttribute("role", "alert");
    const button = element("button", "primary-button", "Enter fullscreen") as HTMLButtonElement;
    button.disabled = Boolean(fullscreenCapabilityError());
    button.addEventListener("click", async () => {
      button.disabled = true;
      const error = await enterRequiredFullscreen();
      if (error) {
        status.textContent = error;
        button.disabled = false;
        return;
      }
      fullscreenRequired = true;
      this.jsPsych.finishTrial({
        record_type: "fullscreen_check",
        fullscreen_width: innerWidth,
        fullscreen_height: innerHeight,
      });
    });
    screen.append(status, button);
    display.replaceChildren(screen);
  }
}

class SessionPlugin {
  static info = { name: "experiment-session", version: "1.0.0", parameters: {
    plan: { type: ParameterType.OBJECT, default: undefined },
  }, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(_display: HTMLElement, trial: { plan: Assignment[] }): void {
    this.jsPsych.finishTrial({
      record_type: "session",
      started_at: new Date().toISOString(),
      trial_order: trial.plan.map((assignment, index) => ({
        trial_number: index + 1,
        scene_id: assignment.scene.sceneId,
        stimulus_video: assignment.scene.video,
        behavioral_trial_type: assignment.scene.kind,
        trial_phase: assignment.phase,
        probe_offset_ms: config.probeOffsetsMs[assignment.probe],
        probe_condition: assignment.probe,
        requested_stop_frame: assignment.frame,
      })),
      preload_errors: [...preloadErrors],
      settings: {
        probe_offsets_ms: config.probeOffsetsMs,
        fixation_ms: config.fixationMs,
        freeze_frame_ms: config.freezeFrameMs,
        countdown_seconds: config.onboarding.countdown.seconds,
        slider: config.slider,
        practice: config.onboarding.practice,
      },
      browser: {
        user_agent: navigator.userAgent,
        language: navigator.language,
        platform: navigator.platform,
        screen_width: screen.width,
        screen_height: screen.height,
        viewport_width: innerWidth,
        viewport_height: innerHeight,
        device_pixel_ratio: devicePixelRatio,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        timezone_offset_minutes: new Date().getTimezoneOffset(),
        video_frame_callback_supported: "requestVideoFrameCallback" in HTMLVideoElement.prototype,
      },
    });
  }
}

class IntroPlugin {
  static info = { name: "prototype-intro", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const shownAt = performance.now();
    const pages = [config.onboarding.welcome, ...config.onboarding.instructionPages];
    let pageIndex = 0;
    const showPage = () => {
      const page = pages[pageIndex];
      const screen = element("div", "intro-screen");
      if (pageIndex > 0) screen.append(element("p", "eyebrow", `Instructions ${pageIndex} of ${pages.length - 1}`));
      screen.append(element("h1", "", page.title));
      for (const paragraph of page.paragraphs) screen.append(element("p", "intro-copy", paragraph.replace("{trialCount}", String(trialCount(selectedType)))));
      const button = element("button", "primary-button", config.onboarding.nextButton);
      button.addEventListener("click", () => {
        pageIndex++;
        if (pageIndex < pages.length) showPage();
        else this.jsPsych.finishTrial({ record_type: "instructions", instruction_round: quizAttempts + 1, duration_ms: performance.now() - shownAt });
      });
      screen.append(button);
      display.replaceChildren(screen);
    };
    showPage();
  }
}

class PracticeFeedbackPlugin {
  static info = { name: "practice-feedback", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    activeReplay = null;
    setReplayAvailable(false);
    const screen = element("div", "intro-screen");
    screen.append(element("h1", "", "Practice feedback"));
    screen.append(element("p", "intro-copy", config.onboarding.practice.feedback));
    const button = element("button", "primary-button", config.onboarding.nextButton);
    button.addEventListener("click", () => this.jsPsych.finishTrial({ record_type: "practice_feedback" }));
    screen.append(button);
    display.replaceChildren(screen);
  }
}

class QuizPlugin {
  static info = { name: "prototype-quiz", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const shownAt = performance.now();
    const attemptNumber = ++quizAttempts;
    const screen = element("div", "quiz-screen");
    screen.append(element("h1", "", config.onboarding.quiz.title));
    const selected: Array<number | null> = config.onboarding.quiz.questions.map(() => null);
    const submit = element("button", "primary-button", config.onboarding.quiz.submitButton) as HTMLButtonElement;
    submit.disabled = true;
    config.onboarding.quiz.questions.forEach((question, questionIndex) => {
      const group = element("fieldset", "quiz-question");
      group.append(element("legend", "", question.prompt));
      question.options.forEach((option, optionIndex) => {
        const label = element("label", "quiz-option");
        const radio = document.createElement("input");
        radio.type = "radio";
        radio.name = `quiz-question-${questionIndex}`;
        radio.value = String(optionIndex);
        radio.addEventListener("change", () => {
          selected[questionIndex] = optionIndex;
          submit.disabled = selected.some((answer) => answer === null);
        });
        label.append(radio, document.createTextNode(option));
        group.append(label);
      });
      screen.append(group);
    });
    submit.addEventListener("click", () => {
      const correct = selected.every((answer, index) => answer === config.onboarding.quiz.questions[index].correctIndex);
      const result = {
        record_type: "comprehension_quiz",
        attempt_number: attemptNumber,
        passed: correct,
        response_time_ms: performance.now() - shownAt,
        answers: config.onboarding.quiz.questions.map((question, index) => ({
          question: question.prompt,
          selected_index: selected[index],
          selected_answer: selected[index] === null ? null : question.options[selected[index]],
          correct_index: question.correctIndex,
          correct: selected[index] === question.correctIndex,
        })),
      };
      if (correct) {
        quizPassed = true;
        this.jsPsych.finishTrial(result);
      } else {
        quizPassed = false;
        failedQuizAttempts++;
        screen.replaceChildren(element("p", "intro-copy", config.onboarding.quiz.retryMessage));
        const retry = element("button", "primary-button", config.onboarding.quiz.retryButton);
        retry.addEventListener("click", () => this.jsPsych.finishTrial(result));
        screen.append(retry);
      }
    });
    screen.append(submit);
    display.replaceChildren(screen);
  }
}

class CountdownPlugin {
  static info = { name: "prototype-countdown", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const startedAt = performance.now();
    const screen = element("div", "countdown-screen");
    const number = element("div", "countdown-number");
    screen.append(element("h1", "", config.onboarding.countdown.title), number);
    display.replaceChildren(screen);
    const deadline = performance.now() + config.onboarding.countdown.seconds * 1000;
    const tick = () => {
      const remaining = Math.ceil((deadline - performance.now()) / 1000);
      if (remaining <= 0) {
        clearInterval(interval);
        this.jsPsych.finishTrial({ record_type: "countdown", planned_duration_ms: config.onboarding.countdown.seconds * 1000, actual_duration_ms: performance.now() - startedAt });
      } else {
        number.textContent = String(remaining);
      }
    };
    const interval = window.setInterval(tick, 100);
    tick();
  }
}

class DebriefPlugin {
  static info = { name: "prototype-debrief", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const shownAt = performance.now();
    const screen = element("div", "debrief-screen");
    screen.append(element("h1", "", config.onboarding.debrief.title));
    const requiredAnswers: Array<"yes" | "no" | null> = config.onboarding.debrief.requiredQuestions.map(() => null);
    const finish = element("button", "primary-button", config.onboarding.debrief.finishButton);
    finish.disabled = true;
    config.onboarding.debrief.requiredQuestions.forEach((question, questionIndex) => {
      const group = element("fieldset", "quiz-question");
      group.append(element("legend", "", question.prompt));
      if ("detail" in question) group.append(element("p", "debrief-detail", question.detail));
      for (const [value, labelText] of [["yes", config.onboarding.debrief.yesLabel], ["no", config.onboarding.debrief.noLabel]] as const) {
        const label = element("label", "quiz-option", labelText);
        const radio = document.createElement("input");
        radio.type = "radio";
        radio.name = `debrief-${question.id}`;
        radio.value = value;
        radio.addEventListener("change", () => {
          requiredAnswers[questionIndex] = value;
          finish.disabled = requiredAnswers.some((answer) => answer === null);
        });
        label.prepend(radio);
        group.append(label);
      }
      screen.append(group);
    });
    screen.append(element("p", "", config.onboarding.debrief.optionalNote));
    const answers: HTMLTextAreaElement[] = [];
    for (const prompt of [config.onboarding.debrief.strategyQuestion, config.onboarding.debrief.commentsQuestion]) {
      const label = element("label", "debrief-question", prompt);
      const answer = document.createElement("textarea");
      answer.rows = 4;
      answer.autocomplete = "off";
      answers.push(answer);
      label.append(answer);
      screen.append(label);
    }
    finish.addEventListener("click", () => {
      if (requiredAnswers.some((answer) => answer === null)) return;
      const strategies = answers[0].value.trim();
      const additionalComments = answers[1].value.trim();
      screen.replaceChildren();
      this.jsPsych.finishTrial({
        record_type: "debrief",
        required_feedback: config.onboarding.debrief.requiredQuestions.map((question, index) => ({
          id: question.id,
          question: question.prompt,
          answer: requiredAnswers[index],
        })),
        strategies,
        additional_comments: additionalComments,
        response_time_ms: performance.now() - shownAt,
        quiz_attempts: quizAttempts,
        failed_quiz_attempts: failedQuizAttempts,
        instruction_loops: failedQuizAttempts,
      });
    });
    screen.append(finish);
    display.replaceChildren(screen);
  }
}

class SummaryPlugin {
  static info = { name: "experiment-summary", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(_display: HTMLElement): void {
    this.jsPsych.finishTrial({
      record_type: "summary",
      completed_at: new Date().toISOString(),
      quiz_attempts: quizAttempts,
      failed_quiz_attempts: failedQuizAttempts,
      instruction_loops: failedQuizAttempts,
    });
  }
}

class SceneTrialPlugin {
  static info = {
    name: "prototype-scene",
    version: "1.0.0",
    parameters: {
      assignment: { type: ParameterType.OBJECT, default: undefined },
      index: { type: ParameterType.INT, default: undefined },
      practice: { type: ParameterType.BOOL, default: false },
    },
    data: {},
  };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement, trial: { assignment: Assignment; index: number; practice?: boolean }): void {
    const trialLabel = trial.practice ? config.onboarding.practice.label : `Trial ${trial.index + 1} of ${trialCount(selectedType)}`;
    const trialStartedAt = performance.now();
    const trialStartedIso = new Date().toISOString();
    const playbackErrors: Array<{ attempt: number; elapsed_ms: number; message: string; media_error_code: number | null }> = [];
    let playbackAttempts = 0;
    let massFirstMoveRt: number | null = null;
    let confidenceFirstMoveRt: number | null = null;
    let generation = 0;
    let timer: number | null = null;
    let animation: number | null = null;
    let video: HTMLVideoElement | null = null;
    let frameCallback: number | null = null;
    let receivedFrame = false;
    const clean = () => {
      if (timer !== null) clearTimeout(timer);
      if (animation !== null) cancelAnimationFrame(animation);
      if (video) {
        if (frameCallback !== null && "cancelVideoFrameCallback" in video) video.cancelVideoFrameCallback(frameCallback);
        video.onerror = null;
        video.onended = null;
        video.onloadeddata = null;
        video.onplaying = null;
        video.pause();
        video.removeAttribute("src");
        video.load();
        video.remove();
      }
      timer = animation = frameCallback = null;
      video = null;
    };
    const fail = (message: string, mediaErrorCode: number | null = null) => {
      playbackErrors.push({
        attempt: playbackAttempts,
        elapsed_ms: performance.now() - trialStartedAt,
        message,
        media_error_code: mediaErrorCode,
      });
      clean();
      display.replaceChildren(element("p", "status-error", message));
      const retry = element("button", "secondary-button", "Replay trial");
      retry.addEventListener("click", ready);
      display.append(retry);
    };
    const response = () => {
      clean();
      const responseShownAt = performance.now();
      const screen = element("div", "response-screen");
      screen.append(element("p", "eyebrow", trialLabel));
      screen.append(element("h2", "", config.instructions.responseQuestion));
      const continueButton = element("button", "primary-button", config.instructions.continueButton) as HTMLButtonElement;
      continueButton.disabled = true;
      const control = createMassResponseControl(config.slider, config.instructions, (moved, bothMoved) => {
        const rt = performance.now() - responseShownAt;
        if (moved === "mass" && massFirstMoveRt === null) massFirstMoveRt = rt;
        if (moved === "confidence" && confidenceFirstMoveRt === null) confidenceFirstMoveRt = rt;
        if (bothMoved) continueButton.disabled = false;
      });
      screen.append(control.element);
      screen.append(continueButton);
      continueButton.addEventListener("click", () => {
        const values = control.getResponse();
        const entry = videoEntryFor(trial.assignment.scene, manifest as VideoManifest)!;
        activeReplay = null;
        setReplayAvailable(false);
        this.jsPsych.finishTrial({
          record_type: "scene_trial",
          trial_number: trial.practice ? 0 : trial.index + 1,
          instruction_round: trial.practice ? quizAttempts + 1 : null,
          is_practice: Boolean(trial.practice),
          behavioral_trial_type: trial.practice ? "practice" : trial.assignment.scene.kind,
          scene_kind: trial.assignment.scene.kind,
          trial_phase: trial.assignment.phase,
          probe_offset_ms: config.probeOffsetsMs[trial.assignment.probe],
          scene_id: trial.assignment.scene.sceneId,
          stimulus_video: trial.assignment.scene.video,
          probe_condition: trial.assignment.probe,
          video_fps: entry.fps,
          video_frame_count: entry.frame_count,
          video_condition_id: entry.condition_id,
          requested_stop_frame: trial.assignment.frame,
          requested_stop_time_s: trial.assignment.frame / entry.fps,
          playback_attempts: playbackAttempts,
          playback_error_count: playbackErrors.length,
          playback_errors: playbackErrors,
          response_screen_rt_ms: responseShownAt - trialStartedAt,
          mass_first_move_rt_ms: massFirstMoveRt,
          confidence_first_move_rt_ms: confidenceFirstMoveRt,
          response_time_ms: performance.now() - responseShownAt,
          trial_duration_ms: performance.now() - trialStartedAt,
          trial_started_at: trialStartedIso,
          submitted_at: new Date().toISOString(),
          mass_estimate_raw: values.massEstimate,
          heavier_object: values.heavierObject,
          estimated_mass_ratio: values.massRatio,
          confidence_percent: values.confidence,
        });
      });
      display.replaceChildren(screen);
    };
    const play = (run: number) => {
      if (run !== generation) return;
      const source = videoUrls.get(trial.assignment.scene.video);
      if (!source) { fail("The required video is unavailable. Reload the prototype."); return; }
      const screen = element("div", "video-screen");
      screen.append(element("p", "eyebrow", trialLabel));
      const stage = element("div", "video-stage");
      const canvas = element("canvas") as HTMLCanvasElement;
      canvas.setAttribute("aria-label", "Two objects interacting on a ramp and table");
      video = document.createElement("video");
      const playingVideo = video;
      playingVideo.className = "video-source";
      playingVideo.muted = true;
      playingVideo.playsInline = true;
      playingVideo.controls = false;
      playingVideo.preload = "auto";
      playingVideo.src = source;
      const paused = element("div", "pause-indicator");
      paused.hidden = true;
      paused.setAttribute("role", "status");
      const pauseIcon = element("span", "pause-icon");
      pauseIcon.setAttribute("aria-hidden", "true");
      paused.append(pauseIcon, element("span", "", "Paused"));
      stage.append(playingVideo, canvas, paused);
      screen.append(stage);
      display.replaceChildren(screen);
      const stageWidth = stage.getBoundingClientRect().width || 960;
      const pixelRatio = Math.min(Math.max(window.devicePixelRatio || 1, 1), 2);
      canvas.width = Math.max(1, Math.round(stageWidth * pixelRatio));
      canvas.height = Math.max(1, Math.round(canvas.width * 9 / 16));
      const context = canvas.getContext("2d");
      if (!context) { fail("Canvas is unavailable in this browser."); return; }
      const entry = videoEntryFor(trial.assignment.scene, manifest as VideoManifest)!;
      const cutAt = trial.assignment.frame / entry.fps;
      const cut = () => {
        if (run !== generation) return;
        const still = probeImages.get(`${trial.assignment.scene.video}:${trial.assignment.probe}`);
        if (!still) { fail("The probe image is unavailable. Rebuild the stimuli and reload."); return; }
        context.drawImage(still, 0, 0, canvas.width, canvas.height);
        clean();
        paused.hidden = false;
        timer = window.setTimeout(() => {
          if (run === generation) response();
        }, config.freezeFrameMs);
      };
      const fallback = () => {
        if (run !== generation || !video) return;
        if (playingVideo.currentTime >= cutAt) {
          cut();
          return;
        }
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        animation = requestAnimationFrame(fallback);
      };
      const frames = (_now: number, metadata: VideoFrameCallbackMetadata) => {
        if (run !== generation || !video) return;
        receivedFrame = true;
        const frame = Math.round(metadata.mediaTime * entry.fps);
        if (frame >= trial.assignment.frame) { cut(); return; }
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        frameCallback = playingVideo.requestVideoFrameCallback(frames);
      };
      playingVideo.onerror = () => fail(`Playback failed for ${trial.assignment.scene.video}.`, playingVideo.error?.code ?? null);
      playingVideo.onended = () => fail(`Playback ended before probe frame ${trial.assignment.frame}.`);
      const beginPlayback = () => {
        if (run !== generation || video !== playingVideo) return;
        if (!document.fullscreenElement) {
          timer = window.setTimeout(beginPlayback, 100);
          return;
        }
        playingVideo.currentTime = 0;
        if ("requestVideoFrameCallback" in playingVideo) {
          frameCallback = playingVideo.requestVideoFrameCallback(frames);
          // Some browsers suppress callbacks for hidden videos. If that happens,
          // switch to the time-based fallback while keeping the canvas mask.
          timer = window.setTimeout(() => {
            if (run === generation && !receivedFrame && frameCallback !== null && playingVideo.currentTime > 0.15) {
              playingVideo.cancelVideoFrameCallback(frameCallback);
              frameCallback = null;
              fallback();
            }
          }, 500);
        } else {
          fallback();
        }
        void playingVideo.play().catch(() => {
          if (run === generation && video === playingVideo) fail("Automatic playback was blocked. Use Replay trial to try again.");
        });
      };
      playingVideo.onloadeddata = () => {
        if (run !== generation) return;
        // The MP4 contains the entire acclimation intro; start immediately.
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        beginPlayback();
      };
      playingVideo.load();
    };
    const ready = () => {
      generation++;
      playbackAttempts++;
      receivedFrame = false;
      clean();
      massFirstMoveRt = null;
      confidenceFirstMoveRt = null;
      const run = generation;
      const screen = element("div", "fixation-screen");
      screen.append(element("p", "eyebrow", trialLabel));
      screen.append(element("div", "fixation-mark", config.instructions.ready));
      display.replaceChildren(screen);
      timer = window.setTimeout(() => play(run), config.fixationMs);
    };
    activeReplay = ready;
    ready();
  }
}

const errors = validateExperiment(config, manifest as VideoManifest);
function bootstrap(api: JatosApi | null): void {
  jatosApi = api;
  if (api) {
    previewMode = api.urlQueryParameters.preview === "1" || previewMode;
    requestedType = api.urlQueryParameters.experiment_type ?? requestedType;
  }
  const startupErrors = [...errors];
  if (api && !previewMode) {
    const configuredType = api.studyInput?.experiment_type;
    if (!studyTypes.includes(configuredType as StudyType)) {
      startupErrors.push('Set experiment_type to pre, during, or post in the JATOS study JSON input.');
    } else {
      selectedType = configuredType as StudyType;
      assignmentMethod = "study_configuration";
    }
  } else if (requestedType !== null) {
    if (!studyTypes.includes(requestedType as StudyType)) startupErrors.push("experiment_type must be pre, during, or post.");
    else { selectedType = requestedType as StudyType; assignmentMethod = "url_override"; }
  }
  showStart(startupErrors.join(" "));
}

// JATOS must initialize before its URL parameters or submission API are used.
// JATOS participants preload automatically; local and preview runs use the
// researcher start button to choose an experiment type before running the timeline.
if (window.jatos) window.jatos.onLoad(() => bootstrap(window.jatos!));
else bootstrap(null);
