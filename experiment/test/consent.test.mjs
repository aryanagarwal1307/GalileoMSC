import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";
import { JSDOM } from "jsdom";

test("external HTML requires consent before preparation; failed setup can retry and resolves the prepared plan", async () => {
  const directory = mkdtempSync(join(tmpdir(), "galileo-consent-test-"));
  const dom = new JSDOM('<main id="app"></main>', { url: "http://localhost/", pretendToBeVisual: true });
  const originals = new Map();
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "fetch"]) {
    originals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    if (key !== "fetch") Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
  }
  dom.window.scrollTo = () => {};
  const consent = readFileSync(new URL("../assets/consent.html", import.meta.url), "utf8");
  globalThis.fetch = async (url) => {
    assert.equal(url, "consent-test.html");
    return new Response(consent);
  };
  const waitFor = async (condition) => {
    for (let i = 0; i < 200; i++) {
      if (condition()) return;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.fail("Timed out waiting for the experiment state");
  };
  try {
    await build({ stdin: { contents: "export { initJsPsych, ParameterType } from 'jspsych'; export * from './app/consent'; export * from './app/preparation';", resolveDir: new URL("..", import.meta.url).pathname }, bundle: true, platform: "node", format: "cjs", outfile: join(directory, "consent.cjs") });
    const { initJsPsych, ParameterType, createConsentTrial, PreparationPlugin } = createRequire(import.meta.url)(join(directory, "consent.cjs"));
    const display = document.querySelector("#app");
    const jsPsych = initJsPsych({ display_element: display });
    let attempts = 0;
    let plan;
    class AfterPreparation {
      static info = { name: "test-prepared-plan", version: "1.0.0", parameters: { assignment: { type: ParameterType.OBJECT, default: undefined } }, data: {} };
      constructor(instance) { this.jsPsych = instance; }
      trial(_display, trial) { this.jsPsych.finishTrial({ record_type: "prepared_plan", assignment: trial.assignment }); }
    }
    const run = jsPsych.run([
      createConsentTrial("consent-test.html", display),
      { type: PreparationPlugin, prepare: async () => {
        attempts++;
        if (attempts === 1) throw new Error("Temporary loading failure");
        plan = { scene: "wood_to_brick", phase: "baseline" };
      } },
      { type: AfterPreparation, assignment: () => plan },
    ]);
    await waitFor(() => document.querySelector("#consent-error"));
    const checkbox = document.querySelector("#consent_checkbox");
    const begin = document.querySelector("#start");
    assert.equal(checkbox.checked, false);
    begin.click();
    assert.match(document.querySelector("#consent-error").textContent, /agreement box/);
    assert.equal(attempts, 0);
    assert.equal(jsPsych.data.get().count(), 0);
    checkbox.checked = true;
    checkbox.dispatchEvent(new dom.window.Event("change"));
    assert.equal(document.querySelector("#consent-error").textContent, "");
    // Checking once must not permit proceeding after subsequently unchecking.
    checkbox.checked = false;
    begin.click();
    assert.equal(attempts, 0);
    checkbox.checked = true;
    begin.click();
    await waitFor(() => [...display.querySelectorAll("button")].some((button) => button.textContent === "Retry setup" && !button.hidden));
    const consentRecord = jsPsych.data.get().values()[0];
    assert.equal(consentRecord.record_type, "consent");
    assert.equal(consentRecord.trial_type, "external-html");
    assert.equal(consentRecord.consented, true);
    assert.equal(consentRecord.url, "consent-test.html");
    assert.ok(Number.isFinite(Date.parse(consentRecord.consented_at)));
    assert.ok(consentRecord.rt >= 0);
    assert.match(display.textContent, /Temporary loading failure/);
    assert.equal(attempts, 1);
    [...display.querySelectorAll("button")].find((button) => button.textContent === "Retry setup").click();
    await run;
    assert.equal(attempts, 2);
    assert.equal(jsPsych.data.get().filter({ record_type: "consent" }).count(), 1);
    assert.deepEqual(jsPsych.data.get().last(1).values()[0].assignment, plan);
    assert.equal(display.classList.contains("consent-active"), false);
  } finally {
    dom.window.close();
    for (const [key, descriptor] of originals) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    rmSync(directory, { recursive: true, force: true });
  }
});
