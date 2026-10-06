import type { ExperimentConfig } from "./experiment.config";

type SliderSettings = ExperimentConfig["slider"];
type Wording = ExperimentConfig["instructions"];

/** DOM-only mass and confidence controls. Neither response is stored. */
export function createMassResponseControl(settings: SliderSettings, words: Wording, onInteract: () => void): HTMLElement {
  const root = document.createElement("div");
  root.className = "interval-control";

  const readout = document.createElement("div");
  readout.className = "interval-readout";
  readout.setAttribute("role", "status");
  readout.setAttribute("aria-live", "polite");
  const readoutLabel = document.createElement("span");
  readoutLabel.className = "interval-readout-label";
  readoutLabel.textContent = words.rangeLabel;
  const answer = document.createElement("strong");
  answer.className = "interval-value";
  readout.append(readoutLabel, answer);

  const track = document.createElement("div");
  track.className = "interval-track";
  const band = document.createElement("div");
  band.className = "interval-band";
  const zeroMarker = document.createElement("div");
  zeroMarker.className = "interval-zero-marker";
  zeroMarker.style.left = `${(-settings.min / (settings.max - settings.min)) * 100}%`;
  const mean = document.createElement("input");
  mean.type = "range";
  mean.className = "interval-handle";
  mean.min = String(settings.min);
  mean.max = String(settings.max);
  mean.step = String(settings.step);
  mean.value = String(settings.initialMean);
  mean.setAttribute("aria-label", words.responseQuestion);
  track.append(band, zeroMarker, mean);

  const labels = document.createElement("div");
  labels.className = "scale-labels";
  for (const [text, detail] of [
    [words.leftLabel, `upto ${settings.maxMultiple}x heavier`],
    [words.centerLabel, ""],
    [words.rightLabel, `upto ${settings.maxMultiple}x heavier`],
  ]) {
    const node = document.createElement("span");
    const heading = document.createElement("strong");
    heading.textContent = text;
    node.append(heading);
    if (detail) {
      const subline = document.createElement("small");
      subline.textContent = detail;
      node.append(subline);
    }
    labels.append(node);
  }

  const confidenceControl = document.createElement("div");
  confidenceControl.className = "confidence-control";
  const confidenceHeading = document.createElement("div");
  confidenceHeading.className = "confidence-heading";
  const confidenceLabel = document.createElement("label");
  confidenceLabel.htmlFor = "confidence-slider";
  confidenceLabel.textContent = words.confidenceQuestion;
  const confidenceValue = document.createElement("output");
  confidenceValue.htmlFor = "confidence-slider";
  confidenceHeading.append(confidenceLabel, confidenceValue);
  const confidence = document.createElement("input");
  confidence.id = "confidence-slider";
  confidence.type = "range";
  confidence.className = "confidence-slider";
  confidence.min = String(settings.confidenceMin);
  confidence.max = String(settings.confidenceMax);
  confidence.step = String(settings.confidenceStep);
  confidence.value = String(settings.initialConfidence);
  const confidenceScale = document.createElement("div");
  confidenceScale.className = "confidence-scale";
  for (const text of [`${settings.confidenceMin}%`, `${settings.confidenceMax}%`]) {
    const node = document.createElement("span");
    node.textContent = text;
    confidenceScale.append(node);
  }
  confidenceControl.append(confidenceHeading, confidence, confidenceScale);

  let meanMoved = false;
  let confidenceMoved = false;

  const render = () => {
    const estimate = Number(mean.value);
    const confidencePercent = Number(confidence.value);
    const span = settings.max - settings.min;
    // At 0% confidence the band covers the full scale. At 100% it collapses
    // to the estimate. Between those points it is centered unless near an edge.
    const width = span * (1 - confidencePercent / 100);
    const lower = Math.max(settings.min, Math.min(estimate - width / 2, settings.max - width));
    const upper = lower + width;
    band.style.left = `${(lower - settings.min) / span * 100}%`;
    band.style.width = `${width / span * 100}%`;
    const sideMaximum = estimate < 0 ? -settings.min : settings.max;
    const multiplier = `${Number((1 + Math.abs(estimate) / sideMaximum * (settings.maxMultiple - 1)).toFixed(1))}x`;
    answer.textContent = estimate === 0
      ? `The ${words.rampObjectName} and the ${words.tableObjectName} have equal mass with ${confidencePercent}% confidence`
      : estimate < 0
        ? `The ${words.rampObjectName} is ${multiplier} heavier than the ${words.tableObjectName} with ${confidencePercent}% confidence`
        : `The ${words.tableObjectName} is ${multiplier} heavier than the ${words.rampObjectName} with ${confidencePercent}% confidence`;
    mean.setAttribute("aria-valuetext", estimate === 0 ? words.centerLabel : estimate < 0
      ? `${words.rampObjectName} ${multiplier} heavier than ${words.tableObjectName}`
      : `${words.tableObjectName} ${multiplier} heavier than ${words.rampObjectName}`);
    confidenceValue.textContent = `${confidencePercent}${settings.valueUnit}`;
  };
  mean.addEventListener("input", () => {
    meanMoved = true;
    render();
    if (confidenceMoved) onInteract();
  });
  confidence.addEventListener("input", () => {
    confidenceMoved = true;
    render();
    if (meanMoved) onInteract();
  });
  root.append(readout, track, labels, confidenceControl);
  render();
  return root;
}
