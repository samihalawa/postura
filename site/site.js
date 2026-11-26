if (navigator.clipboard) {
  document.querySelectorAll(".command").forEach((command) => {
    const button = command.querySelector("button");
    const text = command.querySelector("code");
    let reset;
    button.hidden = false;
    button.setAttribute("aria-live", "polite");
    button.addEventListener("click", async () => {
      clearTimeout(reset);
      try {
        await navigator.clipboard.writeText(text.textContent);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select to copy";
      }
      reset = setTimeout(() => { button.textContent = "Copy"; }, 1800);
    });
  });
}
