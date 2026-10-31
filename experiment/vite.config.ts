import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import manifest from "../stimuli/generated/videos/video_manifest.json";
import { experimentConfig } from "./app/experiment.config";
import { validateExperiment, videoEntryFor, type VideoManifest } from "./app/validate";

const videoDirectory = fileURLToPath(new URL("../stimuli/generated/videos/", import.meta.url));
const errors = validateExperiment(experimentConfig, manifest);
for (const scene of [...experimentConfig.scenes, experimentConfig.onboarding.practice.scene]) {
  if (!existsSync(fileURLToPath(new URL(`../stimuli/generated/videos/${scene.video}`, import.meta.url)))) {
    errors.push(`${scene.video} is missing from ../stimuli/generated/videos/.`);
  }
  const entry = videoEntryFor(scene, manifest as VideoManifest);
  for (const probe of Object.values(entry?.probes ?? {})) {
    if (!existsSync(fileURLToPath(new URL(`../stimuli/generated/videos/${probe.image_path}`, import.meta.url)))) {
      errors.push(`${probe.image_path} is missing from ../stimuli/generated/videos/.`);
    }
  }
}
if (errors.length) throw new Error(`Experiment configuration:\n${errors.join("\n")}`);

export default defineConfig({
  base: "./",
  publicDir: videoDirectory,
});
