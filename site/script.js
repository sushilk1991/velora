(() => {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const revealItems = document.querySelectorAll(".reveal");

  if (reducedMotion || !("IntersectionObserver" in window)) {
    revealItems.forEach((item) => item.classList.add("is-visible"));
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -8%", threshold: 0.08 });

    revealItems.forEach((item) => observer.observe(item));
  }

  const dictationDemo = document.querySelector("[data-dictation-demo]");
  const demoStage = dictationDemo?.querySelector("[data-demo-stage]");
  const demoStatus = dictationDemo?.querySelector("[data-demo-status]");
  const demoTime = dictationDemo?.querySelector("[data-demo-time]");
  const demoSpoken = dictationDemo?.querySelector("[data-demo-spoken]");
  const demoTyped = dictationDemo?.querySelector("[data-demo-typed]");
  const demoButtons = dictationDemo?.querySelectorAll("[data-demo-example]") ?? [];
  const examples = [
    {
      spoken: "“Send Maya the launch notes, uh, before lunch.”",
      typed: "Send Maya the launch notes before lunch.",
      time: "00:04",
    },
    {
      spoken: "“New line decisions: launch Friday. New line owners: Sam and me.”",
      typed: "Decisions:\n• Launch Friday\n• Owners: Sam and me",
      time: "00:07",
    },
    {
      spoken: "“The idea is, um, writing should feel as fast as thinking.”",
      typed: "Writing should feel as fast as thinking.",
      time: "00:05",
    },
  ];
  let demoTimers = [];

  const clearDemoTimers = () => {
    demoTimers.forEach((timer) => window.clearTimeout(timer));
    demoTimers = [];
  };

  const setDemoExample = (index, animate = true) => {
    if (!demoStage || !demoStatus || !demoTime || !demoSpoken || !demoTyped) return;
    const example = examples[index] ?? examples[0];
    clearDemoTimers();

    demoButtons.forEach((button) => {
      const isActive = Number(button.dataset.demoExample) === index;
      button.classList.toggle("is-active", isActive);
      button.setAttribute("aria-pressed", String(isActive));
    });

    if (reducedMotion || !animate) {
      demoSpoken.textContent = example.spoken;
      demoTyped.textContent = example.typed;
      demoTime.textContent = example.time;
      demoStatus.textContent = "Ready — kept on-device";
      demoStage.classList.remove("is-listening", "is-processing", "is-swapping");
      demoStage.classList.add("is-ready");
      return;
    }

    demoStage.classList.remove("is-listening", "is-processing", "is-ready");
    demoStage.classList.add("is-swapping");
    demoStatus.textContent = "Listening on-device";

    demoTimers.push(window.setTimeout(() => {
      demoSpoken.textContent = example.spoken;
      demoTyped.textContent = example.typed;
      demoTime.textContent = example.time;
      demoStage.classList.remove("is-swapping");
      demoStage.classList.add("is-listening");
    }, 220));

    demoTimers.push(window.setTimeout(() => {
      demoStatus.textContent = "Cleaning up on-device";
      demoStage.classList.remove("is-listening");
      demoStage.classList.add("is-processing");
    }, 1050));

    demoTimers.push(window.setTimeout(() => {
      demoStatus.textContent = "Ready — kept on-device";
      demoStage.classList.remove("is-processing");
      demoStage.classList.add("is-ready");
    }, 2050));
  };

  demoButtons.forEach((button) => {
    button.addEventListener("click", () => {
      setDemoExample(Number(button.dataset.demoExample));
    });
  });

  setDemoExample(0, !reducedMotion);

  const precisePointer = window.matchMedia("(pointer: fine)").matches;
  if (demoStage && precisePointer && !reducedMotion) {
    demoStage.addEventListener("pointermove", (event) => {
      const bounds = demoStage.getBoundingClientRect();
      const x = (event.clientX - bounds.left) / bounds.width - 0.5;
      const y = (event.clientY - bounds.top) / bounds.height - 0.5;
      demoStage.style.setProperty("--tilt-x", `${(x * 2.4).toFixed(2)}deg`);
      demoStage.style.setProperty("--tilt-y", `${(y * -2.4).toFixed(2)}deg`);
    });

    demoStage.addEventListener("pointerleave", () => {
      demoStage.style.removeProperty("--tilt-x");
      demoStage.style.removeProperty("--tilt-y");
    });
  }

  document.querySelectorAll("[data-current-year]").forEach((item) => {
    item.textContent = String(new Date().getFullYear());
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const label = button.querySelector(".copy-label");
      const originalLabel = label?.textContent ?? "Copy command";

      try {
        await navigator.clipboard.writeText(button.dataset.copy ?? "");
        if (label) label.textContent = "Copied";
        button.setAttribute("aria-label", "Command copied to clipboard");
      } catch {
        if (label) label.textContent = "Select command below";
        button.setAttribute("aria-label", "Copy failed; select the command below");
      }

      window.setTimeout(() => {
        if (label) label.textContent = originalLabel;
        button.removeAttribute("aria-label");
      }, 2200);
    });
  });

  document.querySelectorAll(".mobile-nav a").forEach((link) => {
    link.addEventListener("click", () => {
      link.closest("details")?.removeAttribute("open");
    });
  });
})();
