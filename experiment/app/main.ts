import { initJsPsych, ParameterType, type JsPsych } from "jspsych";
import "jspsych/css/jspsych.css";
import "@fontsource/literata/latin-300.css";
import "@fontsource/literata/latin-400.css";
import "@fontsource/literata/latin-600.css";
import "@fontsource/literata/latin-700.css";
import { experimentConfig as config, type GroupName, type ProbeName, type Scene } from "./experiment.config";
import { validateExperiment, type VideoManifest } from "./validate";
import { createMassResponseControl } from "./slider";
import type { JatosApi } from "./jatos";
import manifest from "../../stimuli/generated/videos/video_manifest.json";
import "./style.css";

type Assignment = { scene: Scene; probe: ProbeName; frame: number };
type StopObservation = {
  method: "video_frame_callback" | "time_fallback";
  actualFrame: number;
  actualTimeSeconds: number;
  lastVisibleFrame: number;
  lastVisibleTimeSeconds: number;
};
const app = document.querySelector<HTMLElement>("#app")!;
const params = new URLSearchParams(location.search);
let previewMode = params.get("preview") === "1";
let requestedGroup = params.get("condition_group");
const groups = Object.keys(config.groups) as GroupName[];
const videoUrls = new Map<string, string>();
let previewPanel: HTMLElement | null = null;
let previewPlan: HTMLElement | null = null;
let activeReplay: (() => void) | null = null;
let selectedGroup: GroupName = groups.includes(requestedGroup as GroupName) ? requestedGroup as GroupName : "1";
let groupAssignmentMethod = "researcher_selection";
let jsPsych: JsPsych;
let quizPassed = false;
let quizAttempts = 0;
let failedQuizAttempts = 0;
let jatosApi: JatosApi | null = null;
const preloadErrors: string[] = [];

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", text = ""): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

function shuffle<T>(items: T[]): T[] {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

function planFor(group: GroupName): Assignment[] {
  const ordinary = shuffle(config.scenes.filter((scene) => scene.kind === "ordinary"));
  const assignments: Assignment[] = ordinary.map((scene) => {
    const probe = config.groups[group][scene.sceneId as keyof typeof config.groups[GroupName]] as ProbeName;
    return { scene, probe, frame: config.probeFrames[probe] };
  });
  const critical = config.scenes.find((scene) => scene.kind === "violation")!;
  const probe = config.violationProbeChoices[Math.floor(Math.random() * config.violationProbeChoices.length)] as ProbeName;
  assignments.push({ scene: critical, probe, frame: config.probeFrames[probe] });
  return assignments;
}

function describeAssignment(assignment: Assignment): string {
  return `${assignment.scene.sceneId} · ${assignment.scene.kind} · ${assignment.probe} · frame ${assignment.frame}`;
}

function showPreviewPlan(plan: Assignment[], currentIndex = -1): void {
  if (!previewPlan) return;
  previewPlan.replaceChildren(element("h3", "", `Group ${selectedGroup} assignments`));
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
    const loading = element("section", "start-card");
    const status = element("p", "status-loading", "Loading all four videos…");
    status.setAttribute("role", "status");
    const retry = element("button", "primary-button", "Retry loading") as HTMLButtonElement;
    retry.hidden = true;
    retry.addEventListener("click", () => {
      retry.hidden = true;
      void startExperiment(loading, retry, status);
    });
    loading.append(status, retry);
    app.append(loading);
    void startExperiment(loading, retry, status);
    return;
  }
  const card = element("section", "start-card");
  card.append(element("p", "eyebrow", "Visual prototype"), element("h1", "", config.instructions.title));
  card.append(element("p", "muted", "Four short trials"));
  const label = element("label", "field-label", "Counterbalancing group");
  const select = element("select") as HTMLSelectElement;
  for (const group of groups) {
    const option = document.createElement("option");
    option.value = group;
    option.textContent = `Group ${group}`;
    option.selected = group === selectedGroup;
    select.append(option);
  }
  label.append(select);
  const showGroupSelect = !jatosApi || previewMode;
  if (showGroupSelect) card.append(label);
  select.addEventListener("change", () => { groupAssignmentMethod = "researcher_selection"; });
  if (previewMode) {
    card.append(element("p", "preview-badge", "Researcher preview mode"));
    const note = element("p", "muted", "The ordinary trial order is randomized when you start. Trial 4 remains last.");
    card.append(note);
    const mapping = element("div", "preview-mapping");
    const update = () => {
      const group = select.value as GroupName;
      mapping.replaceChildren(element("h3", "", `Group ${group} probe rotation`));
      const list = element("ul", "assignment-list");
      for (const scene of config.scenes.filter((item) => item.kind === "ordinary")) {
        const probe = config.groups[group][scene.sceneId as keyof typeof config.groups[GroupName]] as ProbeName;
        list.append(element("li", "", `${scene.sceneId}: ${probe} (frame ${config.probeFrames[probe]})`));
      }
      list.append(element("li", "", `wood_to_metal: collision or postCollision (chosen at random)`));
      mapping.append(list);
    };
    select.addEventListener("change", update);
    update();
    card.append(mapping);
  }
  const status = element("p", "status-error", error);
  status.setAttribute("role", "alert");
  card.append(status);
  const start = element("button", "primary-button", "Start prototype") as HTMLButtonElement;
  start.disabled = Boolean(error);
  start.addEventListener("click", () => {
    if (showGroupSelect) selectedGroup = select.value as GroupName;
    void startExperiment(card, start, status);
  });
  card.append(start);
  app.append(card);
}

async function loadVideo(scene: Scene): Promise<void> {
  const url = new URL(scene.video, document.baseURI).href;
  const entry = (manifest as VideoManifest).conditions.find((item) => item.video_path === scene.video)!;
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
            video.duration <= config.probeFrames.postCollision / entry.fps) {
          finish(new Error(`${scene.video}: missing video frames or too short for configured probes`));
        } else {
          finish();
        }
      };
      video.onerror = () => finish(new Error(`${scene.video}: the browser cannot decode this MP4`));
      video.src = objectUrl;
      video.load();
    });
    videoUrls.set(scene.video, objectUrl);
  } catch (error) {
    preloadErrors.push(error instanceof Error ? error.message : String(error));
    URL.revokeObjectURL(objectUrl);
    throw error;
  }
}

async function startExperiment(card: HTMLElement, button: HTMLButtonElement, status: HTMLElement): Promise<void> {
  button.disabled = true;
  status.className = "status-loading";
  status.textContent = "Loading all four videos…";
  try {
    for (const scene of config.scenes) {
      if (!videoUrls.has(scene.video)) await loadVideo(scene);
    }
  } catch (error) {
    status.className = "status-error";
    status.textContent = `Video loading failed: ${error instanceof Error ? error.message : String(error)}. Check the stimulus files and reload.`;
    button.disabled = false;
    button.hidden = false;
    return;
  }
  const plan = planFor(selectedGroup);
  const practiceScene = config.scenes.find((scene) => scene.sceneId === config.onboarding.practice.sceneId)!;
  const practiceAssignment: Assignment = {
    scene: practiceScene,
    probe: config.onboarding.practice.probe,
    frame: config.probeFrames[config.onboarding.practice.probe],
  };
  app.replaceChildren();
  const shell = element("div", "experiment-shell");
  const participant = element("section", "participant-surface");
  shell.append(participant);
  if (previewMode) {
    previewPanel = element("aside", "preview-panel");
    previewPanel.append(element("p", "preview-badge", "Researcher preview mode"));
    const groupLabel = element("label", "field-label", "Counterbalancing group");
    const select = element("select") as HTMLSelectElement;
    for (const group of groups) {
      const option = document.createElement("option");
      option.value = group;
      option.textContent = `Group ${group}`;
      option.selected = group === selectedGroup;
      select.append(option);
    }
    select.addEventListener("change", () => {
      location.search = `?preview=1&condition_group=${select.value}`;
    });
    groupLabel.append(select);
    previewPanel.append(groupLabel);
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
    showPreviewPlan(plan);
    (previewPanel as HTMLElement & { replayButton?: HTMLButtonElement }).replayButton = replay;
  }
  app.append(shell);
  jsPsych = initJsPsych({
    display_element: participant,
    on_finish: () => { void finishExperiment(participant); },
  });
  jsPsych.data.addProperties({
    data_schema_version: 1,
    run_id: globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    condition_group: selectedGroup,
    group_assignment_method: groupAssignmentMethod,
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
    { type: SessionPlugin, plan },
    {
      timeline: [
        { type: IntroPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
        { type: SceneTrialPlugin, assignment: practiceAssignment, index: -1, practice: true,
          on_start: () => { showPreviewPlan(plan); setReplayAvailable(true); } },
        { type: QuizPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
      ],
      loop_function: () => !quizPassed,
    },
    { type: CountdownPlugin },
    ...plan.map((assignment, index) => ({ type: SceneTrialPlugin, assignment, index, on_start: () => {
      showPreviewPlan(plan, index);
      setReplayAvailable(true);
    } })),
    { type: DebriefPlugin, on_start: () => { activeReplay = null; setReplayAvailable(false); } },
    { type: SummaryPlugin },
  ] as any);
  card.remove();
}

async function finishExperiment(participant: HTMLElement): Promise<void> {
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
      await jatosApi!.endStudyWithoutRedirect();
      participant.replaceChildren(element("div", "complete-screen", config.completionMessage));
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
        probe_condition: assignment.probe,
        requested_stop_frame: assignment.frame,
      })),
      preload_errors: [...preloadErrors],
      settings: {
        probe_frames: config.probeFrames,
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
      for (const paragraph of page.paragraphs) screen.append(element("p", "intro-copy", paragraph));
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
    const finish = element("button", "primary-button", config.onboarding.debrief.finishButton);
    finish.addEventListener("click", () => {
      const strategies = answers[0].value.trim();
      const additionalComments = answers[1].value.trim();
      screen.replaceChildren();
      this.jsPsych.finishTrial({
        record_type: "debrief",
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
    const trialLabel = trial.practice ? config.onboarding.practice.label : `Trial ${trial.index + 1} of 4`;
    const trialStartedAt = performance.now();
    const trialStartedIso = new Date().toISOString();
    const playbackErrors: Array<{ attempt: number; elapsed_ms: number; message: string; media_error_code: number | null }> = [];
    let playbackAttempts = 0;
    let playbackStartedAt: number | null = null;
    let cutAtPerformance: number | null = null;
    let stopObservation: StopObservation | null = null;
    let lastVisibleFrame = 0;
    let lastVisibleTimeSeconds = 0;
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
        const entry = (manifest as VideoManifest).conditions.find((item) => item.video_path === trial.assignment.scene.video)!;
        activeReplay = null;
        setReplayAvailable(false);
        this.jsPsych.finishTrial({
          record_type: "scene_trial",
          trial_number: trial.practice ? 0 : trial.index + 1,
          instruction_round: trial.practice ? quizAttempts + 1 : null,
          is_practice: Boolean(trial.practice),
          behavioral_trial_type: trial.practice ? "practice" : trial.assignment.scene.kind,
          scene_kind: trial.assignment.scene.kind,
          scene_id: trial.assignment.scene.sceneId,
          stimulus_video: trial.assignment.scene.video,
          probe_condition: trial.assignment.probe,
          video_fps: entry.fps,
          video_frame_count: entry.frame_count,
          video_condition_id: entry.condition_id,
          requested_stop_frame: trial.assignment.frame,
          requested_stop_time_s: trial.assignment.frame / entry.fps,
          actual_stop_frame: stopObservation?.actualFrame ?? null,
          actual_stop_time_s: stopObservation?.actualTimeSeconds ?? null,
          last_visible_frame: stopObservation?.lastVisibleFrame ?? null,
          last_visible_time_s: stopObservation?.lastVisibleTimeSeconds ?? null,
          stop_method: stopObservation?.method ?? null,
          playback_attempts: playbackAttempts,
          playback_error_count: playbackErrors.length,
          playback_errors: playbackErrors,
          playback_started_rt_ms: playbackStartedAt === null ? null : playbackStartedAt - trialStartedAt,
          video_cut_rt_ms: cutAtPerformance === null ? null : cutAtPerformance - trialStartedAt,
          freeze_hold_actual_ms: cutAtPerformance === null ? null : responseShownAt - cutAtPerformance,
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
      canvas.width = 960;
      canvas.height = 540;
      canvas.setAttribute("aria-label", "Two objects interacting on a ramp and table");
      video = document.createElement("video");
      const playingVideo = video;
      playingVideo.className = "video-source";
      playingVideo.muted = true;
      playingVideo.playsInline = true;
      playingVideo.controls = false;
      playingVideo.preload = "auto";
      playingVideo.src = source;
      stage.append(playingVideo, canvas);
      screen.append(stage);
      display.replaceChildren(screen);
      const context = canvas.getContext("2d");
      if (!context) { fail("Canvas is unavailable in this browser."); return; }
      const entry = (manifest as VideoManifest).conditions.find((item) => item.video_path === trial.assignment.scene.video)!;
      const cutAt = trial.assignment.frame / entry.fps;
      const cut = (method: StopObservation["method"], actualFrame: number, actualTimeSeconds: number) => {
        if (run !== generation) return;
        cutAtPerformance = performance.now();
        stopObservation = { method, actualFrame, actualTimeSeconds, lastVisibleFrame, lastVisibleTimeSeconds };
        // The source video sits behind an opaque canvas, so no frame after the
        // cut can appear even if the browser delivers a callback late. Remove
        // the video now; the canvas retains its last drawn frame for the hold.
        clean();
        timer = window.setTimeout(() => {
          if (run === generation) response();
        }, config.freezeFrameMs);
      };
      const fallback = () => {
        if (run !== generation || !video) return;
        if (playingVideo.currentTime >= cutAt) {
          cut("time_fallback", Math.round(playingVideo.currentTime * entry.fps), playingVideo.currentTime);
          return;
        }
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        lastVisibleTimeSeconds = playingVideo.currentTime;
        lastVisibleFrame = Math.round(lastVisibleTimeSeconds * entry.fps);
        animation = requestAnimationFrame(fallback);
      };
      const frames = (_now: number, metadata: VideoFrameCallbackMetadata) => {
        if (run !== generation || !video) return;
        receivedFrame = true;
        const frame = Math.round(metadata.mediaTime * entry.fps);
        if (frame >= trial.assignment.frame) { cut("video_frame_callback", frame, metadata.mediaTime); return; }
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        lastVisibleFrame = frame;
        lastVisibleTimeSeconds = metadata.mediaTime;
        frameCallback = playingVideo.requestVideoFrameCallback(frames);
      };
      playingVideo.onerror = () => fail(`Playback failed for ${trial.assignment.scene.video}.`, playingVideo.error?.code ?? null);
      playingVideo.onended = () => fail(`Playback ended before probe frame ${trial.assignment.frame}.`);
      playingVideo.onplaying = () => { playbackStartedAt = performance.now(); };
      const beginPlayback = () => {
        if (run !== generation || video !== playingVideo) return;
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
        // Show frame zero on the same canvas used for playback, then start the
        // video from zero after the configured freeze-frame interval.
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        lastVisibleFrame = 0;
        lastVisibleTimeSeconds = 0;
        timer = window.setTimeout(beginPlayback, config.freezeFrameMs);
      };
      playingVideo.load();
    };
    const ready = () => {
      generation++;
      playbackAttempts++;
      receivedFrame = false;
      clean();
      playbackStartedAt = null;
      cutAtPerformance = null;
      stopObservation = null;
      lastVisibleFrame = 0;
      lastVisibleTimeSeconds = 0;
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
    requestedGroup = api.urlQueryParameters.condition_group ?? requestedGroup;
  }
  const startupErrors = [...errors];
  if (requestedGroup !== null && !groups.includes(requestedGroup as GroupName)) {
    startupErrors.push("condition_group must be 1, 2, or 3.");
  } else if (requestedGroup !== null) {
    selectedGroup = requestedGroup as GroupName;
    groupAssignmentMethod = "url_override";
  } else if (api && !previewMode) {
    selectedGroup = groups[Math.floor(Math.random() * groups.length)];
    groupAssignmentMethod = "random";
  }
  showStart(startupErrors.join(" "));
}

// JATOS must initialize before its URL parameters or submission API are used.
// JATOS participants preload automatically; local and preview runs use the
// researcher start button to choose a group before running the timeline.
if (window.jatos) window.jatos.onLoad(() => bootstrap(window.jatos!));
else bootstrap(null);
