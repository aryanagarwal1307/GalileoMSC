import type { ExperimentConfig, ProbeName } from "./experiment.config";

export type VideoManifest = {
  conditions: Array<{
    condition_id: string;
    video_path: string;
    fps: number;
    frame_count: number;
  }>;
};

export function validateExperiment(config: ExperimentConfig, manifest: VideoManifest): string[] {
  const errors: string[] = [];
  const scenes = config.scenes;
  const names = Object.keys(config.probeFrames) as ProbeName[];
  const ordinary = scenes.filter((scene) => scene.kind === "ordinary");
  const violations = scenes.filter((scene) => scene.kind === "violation");
  if (scenes.length !== 4 || ordinary.length !== 3 || violations.length !== 1) {
    errors.push("Configure exactly three ordinary scenes and one violation scene.");
  }
  if (new Set(scenes.map((scene) => scene.sceneId)).size !== scenes.length) {
    errors.push("Each physical sceneId must occur once.");
  }
  if (new Set(scenes.map((scene) => scene.video)).size !== scenes.length) {
    errors.push("Each configured video must occur once.");
  }
  const byVideo = new Map(manifest.conditions.map((entry) => [entry.video_path, entry]));
  for (const scene of scenes) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*\.mp4$/.test(scene.video)) {
      errors.push(`${scene.video} must be a plain MP4 filename.`);
    }
    const entry = byVideo.get(scene.video);
    if (!entry) {
      errors.push(`${scene.video} is missing from the video manifest.`);
      continue;
    }
    if (entry.condition_id !== `${scene.sceneId}_${scene.kind === "ordinary" ? "congruent" : "violation"}`) {
      errors.push(`${scene.video} does not match scene ${scene.sceneId} and its trial kind.`);
    }
    for (const name of names) {
      const frame = config.probeFrames[name];
      if (!Number.isInteger(frame) || frame < 0 || frame >= entry.frame_count) {
        errors.push(`${name} frame ${frame} is outside ${scene.video} (0–${entry.frame_count - 1}).`);
      }
    }
    if (!(entry.fps > 0)) errors.push(`${scene.video} has invalid FPS in the manifest.`);
  }
  if (!(config.probeFrames.preCollision < config.probeFrames.collision &&
        config.probeFrames.collision < config.probeFrames.postCollision)) {
    errors.push("Probe frames must be ordered pre-collision < collision < post-collision.");
  }
  for (const [group, assignments] of Object.entries(config.groups)) {
    const assignedScenes = Object.keys(assignments);
    if (assignedScenes.length !== ordinary.length ||
        ordinary.some((scene) => !assignedScenes.includes(scene.sceneId))) {
      errors.push(`Group ${group} must assign every ordinary scene exactly once.`);
    }
    const probes = Object.values(assignments);
    if (probes.length !== names.length || new Set(probes).size !== names.length ||
        probes.some((probe) => !names.includes(probe as ProbeName))) {
      errors.push(`Group ${group} must use each probe position once.`);
    }
  }
  if (Object.keys(config.groups).sort().join(",") !== "1,2,3") {
    errors.push("Counterbalancing groups must be 1, 2, and 3.");
  }
  if (!config.violationProbeChoices.length ||
      config.violationProbeChoices.some((probe) => probe !== "collision" && probe !== "postCollision")) {
    errors.push("Violation probes must be collision and/or postCollision.");
  }
  const practice = config.onboarding.practice;
  if (!ordinary.some((scene) => scene.sceneId === practice.sceneId)) {
    errors.push("Practice sceneId must identify one configured ordinary scene.");
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
