import assert from "node:assert/strict";
import { after, test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";

const temporary = mkdtempSync(join(tmpdir(), "galileo-experiment-test-"));
after(() => rmSync(temporary, { recursive: true, force: true }));
await build({ stdin: { contents: ["experiment.config", "design", "allocation", "validate"].map((name) => `export * from './app/${name}';`).join("\n"), resolveDir: new URL("..", import.meta.url).pathname }, bundle: true, platform: "node", format: "cjs", outfile: join(temporary, "logic.cjs") });
const { experimentConfig: config, materialPairs, planTrials, quotaCounts, reserveInState, allocateProbe, completeProbe, validateExperiment } = createRequire(import.meta.url)(join(temporary, "logic.cjs"));

test("all study types shuffle baseline and congruent trials together and keep the incongruent probe last", () => {
  for (const type of ["pre", "during", "post"]) for (const pair of materialPairs) {
    const plan = planTrials(type, type === "pre" ? null : pair, () => 0.5);
    assert.equal(plan.length, type === "pre" ? 12 : 13);
    const firstTwelve = plan.slice(0, 12);
    for (const phase of ["baseline", "congruent"]) {
      const trials = firstTwelve.filter((a) => a.phase === phase);
      assert.equal(trials.length, 6);
      assert.deepEqual(new Set(trials.map((a) => a.scene.sceneId)), new Set(materialPairs));
      assert.ok(trials.every((a) => a.scene.kind === "congruent"));
      assert.ok(trials.every((a) => a.probe === (phase === "baseline" ? "baseline" : config.studyProbes[type])));
    }
    // This deterministic draw mixes both phases across the former block boundary.
    for (const half of [firstTwelve.slice(0, 6), firstTwelve.slice(6)]) {
      assert.deepEqual(new Set(half.map((a) => a.phase)), new Set(["baseline", "congruent"]));
    }
    if (type !== "pre") assert.deepEqual(plan[12], { scene: config.scenes.find((s) => s.sceneId === pair && s.kind === "incongruent"), probe: config.studyProbes[type], phase: "incongruent" });
  }
});

test("quotas balance 120 starts, keep reloads stable, and permit an explicit dropout replacement", () => {
  const state = { type: "during", target: 20, reservations: {} };
  for (let i = 0; i < 120; i++) reserveInState(state, `p${i}`);
  assert.ok(quotaCounts(state).every((c) => c.reserved === 20));
  assert.strictEqual(reserveInState(state, "p0"), state.reservations.p0);
  assert.throws(() => reserveInState(state, "overflow"), /places/);
  const pair = state.reservations.p0.pair;
  state.reservations.p0.status = "released";
  assert.equal(reserveInState(state, "replacement").pair, pair);
  assert.ok(quotaCounts(state).every((c) => c.reserved === 20));
});

function batchServer() {
  const data = new Map();
  let version = 0;
  const client = (pid) => {
    let seenVersion;
    return { urlQueryParameters: { PROLIFIC_PID: pid }, batchSession: {
      get(key) { seenVersion = version; return structuredClone(data.get(key)); },
      async set(key, value) {
        const requestedVersion = seenVersion;
        await new Promise((resolve) => setTimeout(resolve, Math.random() * 3));
        if (requestedVersion !== version) throw new Error("Stale JATOS batch version");
        data.set(key, structuredClone(value));
        version++;
      },
    } };
  };
  return { data, client };
}

test("concurrent JATOS arrivals cannot double-claim slots; completion and reloads are idempotent", async () => {
  const server = batchServer();
  const target = config.recruitment.quotaPerPair;
  for (const type of ["during", "post"]) {
    const clients = Array.from({ length: target * materialPairs.length }, (_, i) => server.client(`${type}${i}`));
    const allocations = await Promise.all(clients.map((api) => allocateProbe(api, type)));
    assert.ok(clients.every((api) => api.batchSessionVersioning === true));
    assert.ok(quotaCounts(server.data.get(allocations[0].key)).every((c) => c.reserved === target));
    assert.deepEqual(await allocateProbe(clients[0], type), allocations[0]);
    await Promise.all(clients.map((api, i) => completeProbe(api, allocations[i], type)));
    await completeProbe(clients[0], allocations[0], type);
    assert.ok(quotaCounts(server.data.get(allocations[0].key)).every((c) => c.completed === target && c.reserved === 0));
    await assert.rejects(allocateProbe(server.client("overflow"), type), /places/);
  }
  assert.equal(await allocateProbe({ urlQueryParameters: {} }, "pre"), null);
});

test("manifest validation accepts new exact probes and rejects obsolete probe timing", () => {
  const entryFor = (scene) => ({
    condition_id: scene.kind === "practice" ? scene.sceneId : `${scene.sceneId}_${scene.kind === "congruent" ? "congruent" : "violation"}`,
    video_path: scene.video, fps: 60, frame_count: 330, trajectory_frame_offset: 60, first_contact_time_seconds: 3.275,
    probes: Object.fromEntries(Object.entries(config.probeOffsetsMs).map(([probe, offset]) => {
      const trajectoryFrame = Math.floor((3.275 + offset / 1000) * 60 + 0.5 + 1e-9);
      return [probe, { frame: trajectoryFrame + 60, trajectory_frame: trajectoryFrame, time_seconds: (trajectoryFrame + 60) / 60, offset_ms: offset, image_path: `${scene.sceneId}_${probe}.png` }];
    })),
  });
  const manifest = { conditions: config.scenes.map(entryFor), practice: entryFor(config.onboarding.practice.scene) };
  assert.deepEqual(validateExperiment(config, manifest), []);
  manifest.conditions[0].probes.collision.offset_ms = 250;
  delete manifest.conditions[0].probes.baseline;
  assert.ok(validateExperiment(config, manifest).some((e) => e.includes("baseline")));
  assert.ok(validateExperiment(config, manifest).some((e) => e.includes("invalid collision")));
});
