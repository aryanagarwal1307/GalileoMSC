import { experimentConfig as config, materialPairs, type MaterialPair, type ProbeName, type Scene, type StudyType } from "./experiment.config";

export type TrialPhase = "baseline" | "congruent" | "incongruent" | "practice";
export type PlannedTrial = { scene: Scene; probe: ProbeName; phase: TrialPhase };

export function shuffle<T>(items: readonly T[], random = Math.random): T[] {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

export function trialCount(type: StudyType): number { return type === "pre" ? 12 : 13; }

export function planTrials(type: StudyType, criticalPair: MaterialPair | null, random = Math.random): PlannedTrial[] {
  const congruent = config.scenes.filter((scene) => scene.kind === "congruent");
  const plan: PlannedTrial[] = shuffle([
    ...congruent.map((scene) => ({ scene, probe: "baseline" as const, phase: "baseline" as const })),
    ...congruent.map((scene) => ({ scene, probe: config.studyProbes[type], phase: "congruent" as const })),
  ], random);
  if (type !== "pre") {
    if (!criticalPair || !materialPairs.includes(criticalPair)) throw new Error("An incongruent material pair is required.");
    const scene = config.scenes.find((item) => item.kind === "incongruent" && item.sceneId === criticalPair)!;
    plan.push({ scene, probe: config.studyProbes[type], phase: "incongruent" });
  }
  return plan;
}
