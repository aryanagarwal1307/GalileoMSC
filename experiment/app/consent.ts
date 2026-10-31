import externalHtml from "@jspsych/plugin-external-html";

/** Keep the supplied consent document separate so Vite ships it as an asset. */
export function createConsentTrial(url: string, display: HTMLElement) {
  return {
    type: externalHtml,
    url,
    cont_btn: "start",
    cont_key: null,
    execute_script: false,
    data: { record_type: "consent", consent_form: "consent.html" },
    on_start: () => { display.classList.add("consent-active"); },
    on_load: () => {
      const checkbox = display.querySelector<HTMLInputElement>("#consent_checkbox")!;
      checkbox.setAttribute("aria-label", "I agree to take part in this study.");
      checkbox.setAttribute("aria-describedby", "consent-error");
      const error = document.createElement("p");
      error.id = "consent-error";
      error.className = "status-error";
      error.setAttribute("role", "alert");
      display.querySelector("#start")!.after(error);
      checkbox.addEventListener("change", () => { error.textContent = ""; });
    },
    check_fn: (content: HTMLElement) => {
      const checkbox = content.querySelector<HTMLInputElement>("#consent_checkbox");
      if (checkbox?.checked) return true;
      content.querySelector<HTMLElement>("#consent-error")!.textContent =
        "To participate, please check the agreement box before selecting Begin.";
      checkbox?.focus();
      return false;
    },
    on_finish: (data: Record<string, unknown>) => {
      data.consented = true;
      data.consented_at = new Date().toISOString();
      display.classList.remove("consent-active");
    },
  };
}
