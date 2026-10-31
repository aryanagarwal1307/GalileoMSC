import { ParameterType, type JsPsych } from "jspsych";

/** Allocate and load only after consent, with an idempotent retry on failure. */
export class PreparationPlugin {
  static info = {
    name: "experiment-preparation", version: "1.0.0",
    parameters: { prepare: { type: ParameterType.FUNCTION, default: undefined } }, data: {},
  };
  constructor(private jsPsych: JsPsych) {}
  trial(display: HTMLElement, trial: { prepare: () => Promise<void> }): void {
    const screen = document.createElement("div");
    screen.className = "intro-screen";
    const status = document.createElement("p");
    status.setAttribute("role", "status");
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "primary-button";
    retry.textContent = "Retry setup";
    const prepare = async () => {
      retry.hidden = true;
      status.className = "status-loading";
      status.textContent = "Loading practice and trial videos…";
      try {
        await trial.prepare();
        this.jsPsych.finishTrial({ record_type: "preparation" });
      } catch (error) {
        status.className = "status-error";
        status.textContent = `Experiment setup failed: ${error instanceof Error ? error.message : String(error)}.`;
        retry.hidden = false;
      }
    };
    retry.addEventListener("click", () => { void prepare(); });
    screen.append(status, retry);
    display.replaceChildren(screen);
    void prepare();
  }
}
