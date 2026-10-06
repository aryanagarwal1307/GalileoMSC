import { initJsPsych, ParameterType, type JsPsych } from "jspsych";
import "jspsych/css/jspsych.css";
import "@fontsource/literata/latin-300.css";
import "@fontsource/literata/latin-400.css";
import "@fontsource/literata/latin-600.css";
import "@fontsource/literata/latin-700.css";
import { experimentConfig as config, type GroupName, type ProbeName, type Scene } from "./experiment.config";
import { validateExperiment, type VideoManifest } from "./validate";
import { createMassResponseControl } from "./slider";
import manifest from "../../stimuli/generated/videos/video_manifest.json";
import "./style.css";

type Assignment = { scene: Scene; probe: ProbeName; frame: number };
const app = document.querySelector<HTMLElement>("#app")!;
const params = new URLSearchParams(location.search);
const previewMode = params.get("preview") === "1";
const requestedGroup = params.get("condition_group");
const groups = Object.keys(config.groups) as GroupName[];
const videoUrls = new Map<string, string>();
let previewPanel: HTMLElement | null = null;
let previewPlan: HTMLElement | null = null;
let activeReplay: (() => void) | null = null;
let selectedGroup: GroupName = groups.includes(requestedGroup as GroupName) ? requestedGroup as GroupName : "1";
let jsPsych: JsPsych;

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

function showStart(error = ""): void {
  app.replaceChildren();
  previewPanel = null;
  previewPlan = null;
  activeReplay = null;
  const card = element("section", "start-card");
  card.append(element("p", "eyebrow", "Visual prototype"), element("h1", "", config.instructions.title));
  card.append(element("p", "muted", "Four short trials · no responses are saved"));
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
  card.append(label);
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
  start.addEventListener("click", () => {
    selectedGroup = select.value as GroupName;
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
    return;
  }
  const plan = planFor(selectedGroup);
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
    on_data_update: () => jsPsych.data.reset(),
    on_finish: () => {
      activeReplay = null;
      if (previewPanel) {
        const replay = (previewPanel as HTMLElement & { replayButton?: HTMLButtonElement }).replayButton;
        if (replay) replay.disabled = true;
      }
      participant.replaceChildren(element("div", "complete-screen", config.completionMessage));
      for (const url of videoUrls.values()) URL.revokeObjectURL(url);
      videoUrls.clear();
    },
  });
  jsPsych.run([
    { type: IntroPlugin },
    ...plan.map((assignment, index) => ({ type: SceneTrialPlugin, assignment, index, on_start: () => {
      showPreviewPlan(plan, index);
      const replay = (previewPanel as (HTMLElement & { replayButton?: HTMLButtonElement }) | null)?.replayButton;
      if (replay) replay.disabled = false;
    } })),
  ] as any);
  card.remove();
}

class IntroPlugin {
  static info = { name: "prototype-intro", version: "1.0.0", parameters: {}, data: {} };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement): void {
    const screen = element("div", "intro-screen");
    screen.append(element("h1", "", config.instructions.title));
    screen.append(element("p", "intro-copy", config.instructions.body));
    const button = element("button", "primary-button", config.instructions.startButton);
    button.addEventListener("click", () => this.jsPsych.finishTrial({}));
    screen.append(button);
    display.replaceChildren(screen);
  }
}

class SceneTrialPlugin {
  static info = {
    name: "prototype-scene",
    version: "1.0.0",
    parameters: {
      assignment: { type: ParameterType.OBJECT, default: undefined },
      index: { type: ParameterType.INT, default: undefined },
    },
    data: {},
  };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement, trial: { assignment: Assignment; index: number }): void {
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
        video.pause();
        video.removeAttribute("src");
        video.load();
        video.remove();
      }
      timer = animation = frameCallback = null;
      video = null;
    };
    const fail = (message: string) => {
      clean();
      display.replaceChildren(element("p", "status-error", message));
      const retry = element("button", "secondary-button", "Replay trial");
      retry.addEventListener("click", ready);
      display.append(retry);
    };
    const response = () => {
      clean();
      const screen = element("div", "response-screen");
      screen.append(element("p", "eyebrow", `Trial ${trial.index + 1} of 4`));
      screen.append(element("h2", "", config.instructions.responseQuestion));
      const continueButton = element("button", "primary-button", config.instructions.continueButton) as HTMLButtonElement;
      continueButton.disabled = true;
      screen.append(createMassResponseControl(config.slider, config.instructions, () => { continueButton.disabled = false; }));
      screen.append(continueButton);
      continueButton.addEventListener("click", () => {
        activeReplay = null;
        const replay = (previewPanel as (HTMLElement & { replayButton?: HTMLButtonElement }) | null)?.replayButton;
        if (replay) replay.disabled = true;
        this.jsPsych.finishTrial({});
      });
      display.replaceChildren(screen);
    };
    const play = (run: number) => {
      if (run !== generation) return;
      const source = videoUrls.get(trial.assignment.scene.video);
      if (!source) { fail("The required video is unavailable. Reload the prototype."); return; }
      const screen = element("div", "video-screen");
      screen.append(element("p", "eyebrow", `Trial ${trial.index + 1} of 4`));
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
      const cut = () => {
        if (run !== generation) return;
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
        if (playingVideo.currentTime >= cutAt) { cut(); return; }
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
      playingVideo.onerror = () => fail(`Playback failed for ${trial.assignment.scene.video}.`);
      playingVideo.onended = () => fail(`Playback ended before probe frame ${trial.assignment.frame}.`);
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
          if (run === generation) fail("Automatic playback was blocked. Use Replay trial to try again.");
        });
      };
      playingVideo.onloadeddata = () => {
        if (run !== generation) return;
        // Show frame zero on the same canvas used for playback, then start the
        // video from zero after the configured freeze-frame interval.
        context.drawImage(playingVideo, 0, 0, canvas.width, canvas.height);
        timer = window.setTimeout(beginPlayback, config.freezeFrameMs);
      };
      playingVideo.load();
    };
    const ready = () => {
      generation++;
      receivedFrame = false;
      clean();
      const run = generation;
      const screen = element("div", "fixation-screen");
      screen.append(element("p", "eyebrow", `Trial ${trial.index + 1} of 4`));
      screen.append(element("div", "fixation-mark", config.instructions.ready));
      display.replaceChildren(screen);
      timer = window.setTimeout(() => play(run), config.fixationMs);
    };
    activeReplay = ready;
    ready();
  }
}

const errors = validateExperiment(config, manifest as VideoManifest);
if (requestedGroup !== null && !groups.includes(requestedGroup as GroupName)) {
  errors.push("condition_group must be 1, 2, or 3.");
}
showStart(errors.join(" "));
