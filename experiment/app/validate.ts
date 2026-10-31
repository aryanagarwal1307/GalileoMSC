import { materialPairs, type ExperimentConfig, type ProbeName, type Scene } from "./experiment.config";

export type VideoEntry = {
    condition_id: string;
    video_path: string;
    fps: number;
    frame_count: number;
    first_contact_time_seconds?: number;
    trajectory_frame_offset?: number;
    probes?: Partial<Record<ProbeName, { frame: number; trajectory_frame: number; time_seconds: number; offset_ms: number; image_path: string }>>;
};

export type VideoManifest = {
  conditions: VideoEntry[];
  practice?: VideoEntry;
};

export function videoEntryFor(scene: Scene, manifest: VideoManifest) {
  return scene.kind === "practice" ? manifest.practice :
    manifest.conditions.find((item) => item.video_path === scene.video);
}

export function probeFor(scene: Scene, probe: ProbeName, manifest: VideoManifest) {
  const entry = videoEntryFor(scene, manifest);
  const target = entry?.probes?.[probe];
  if (!target) throw new Error(`${scene.video}: missing probe metadata; rebuild with build_stimuli.py ${scene.kind === "practice" ? "--practice" : "--all"}.`);
  return target;
}

export function validateExperiment(config: ExperimentConfig, manifest: VideoManifest): string[] {
  const errors: string[] = [];
  const scenes = config.scenes;
  const names = Object.keys(config.probeOffsetsMs) as ProbeName[];
  const ordinary = scenes.filter((scene) => scene.kind === "congruent");
  const violations = scenes.filter((scene) => scene.kind === "incongruent");
  if (scenes.length !== 12 || ordinary.length !== 6 || violations.length !== 6) {
    errors.push("Configure six congruent and six incongruent scenes.");
  }
  if (new Set(scenes.map((scene) => `${scene.sceneId}:${scene.kind}`)).size !== scenes.length) {
    errors.push("Each sceneId must occur once per congruence condition.");
  }
  if (new Set(scenes.map((scene) => scene.video)).size !== scenes.length) {
    errors.push("Each configured video must occur once.");
  }
  const byVideo = new Map(manifest.conditions.map((entry) => [entry.video_path, entry]));
  for (const scene of [...scenes, config.onboarding.practice.scene]) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*\.mp4$/.test(scene.video)) {
      errors.push(`${scene.video} must be a plain MP4 filename.`);
    }
    const entry = scene.kind === "practice" ? manifest.practice : byVideo.get(scene.video);
    if (!entry) {
      errors.push(`${scene.video} is missing from the video manifest.`);
      continue;
    }
    const conditionId = scene.kind === "practice" ? scene.sceneId :
      `${scene.sceneId}_${scene.kind === "congruent" ? "congruent" : "violation"}`;
    if (entry.condition_id !== conditionId || entry.video_path !== scene.video) {
      errors.push(`${scene.video} does not match scene ${scene.sceneId} and its trial kind.`);
    }
    for (const name of names) {
      const target = entry.probes?.[name];
      if (!target) {
        errors.push(`${scene.video}: missing ${name} probe; rebuild with build_stimuli.py ${scene.kind === "practice" ? "--practice" : "--all"}.`);
        continue;
      }
      const frame = target.frame;
      const expectedFrame = entry.first_contact_time_seconds === undefined || entry.trajectory_frame_offset === undefined ? NaN :
        entry.trajectory_frame_offset + Math.floor((entry.first_contact_time_seconds + config.probeOffsetsMs[name] / 1000) * entry.fps + 0.5 + 1e-9);
      if (target.offset_ms !== config.probeOffsetsMs[name] || frame !== expectedFrame ||
          Math.abs(target.time_seconds - frame / entry.fps) > 1e-8 ||
          !/^[A-Za-z0-9][A-Za-z0-9_-]*\.png$/.test(target.image_path)) {
        errors.push(`${scene.video}: invalid ${name} probe metadata.`);
      }
      if (!Number.isInteger(frame) || frame < 0 || frame >= entry.frame_count) {
        errors.push(`${name} frame ${frame} is outside ${scene.video} (0–${entry.frame_count - 1}).`);
      }
    }
    if (!(entry.fps > 0)) errors.push(`${scene.video} has invalid FPS in the manifest.`);
  }
  for (const pair of materialPairs) {
    if (!ordinary.some((scene) => scene.sceneId === pair) || !violations.some((scene) => scene.sceneId === pair)) {
      errors.push(`Missing congruent or incongruent scene for ${pair}.`);
    }
  }
  for (const [type, probe] of Object.entries(config.studyProbes)) {
    if (!(probe in config.probeOffsetsMs)) errors.push(`Invalid study probe for ${type}.`);
  }
  const practice = config.onboarding.practice;
  if (new Set<string>(scenes.map((scene) => scene.sceneId)).has(practice.scene.sceneId) ||
      new Set<string>(scenes.map((scene) => scene.video)).has(practice.scene.video)) {
    errors.push("Practice must use a separate scene and video from the main trials.");
  }
  if (!names.includes(practice.probe)) {
    errors.push("Practice probe must be one of the configured probe positions.");
  }
  if (config.onboarding.quiz.questions.length !== 2 ||
      config.onboarding.quiz.questions.some((question) => question.options.length < 2 ||
        !Number.isInteger(question.correctIndex) || question.correctIndex < 0 ||
        question.correctIndex >= question.options.length)) {
    errors.push("Configure two quiz questions with valid answer indexes.");
  }
  if (!Number.isInteger(config.onboarding.countdown.seconds) || config.onboarding.countdown.seconds < 1) {
    errors.push("Countdown seconds must be a positive whole number.");
  }
  const slider = config.slider;
  if (!(slider.min < 0 && slider.max > 0 && slider.step > 0 &&
        slider.initialMean >= slider.min && slider.initialMean <= slider.max && slider.maxMultiple > 1 &&
        slider.confidenceMin === 0 && slider.confidenceMax === 100 && slider.confidenceStep > 0 &&
        slider.initialConfidence >= slider.confidenceMin && slider.initialConfidence <= slider.confidenceMax)) {
    errors.push("Mass and confidence slider settings are invalid.");
  }
  if (!Number.isFinite(config.fixationMs) || config.fixationMs < 0) {
    errors.push("fixationMs must be a nonnegative duration.");
  }
  if (!Number.isFinite(config.freezeFrameMs) || config.freezeFrameMs < 0) {
    errors.push("freezeFrameMs must be a nonnegative duration.");
  }
  return errors;
}
