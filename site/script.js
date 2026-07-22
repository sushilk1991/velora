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
  const demoCaption = dictationDemo?.querySelector("[data-demo-caption]");
  const demoButtons = dictationDemo?.querySelectorAll("[data-demo-example]") ?? [];
  const examples = [
    {
      spoken: "“Tell Maya I can do three—actually, make that three thirty.”",
      typed: "Tell Maya I can do 3:30.",
      caption: "Changed your mind? Velora fixes the sentence.",
      time: "00:05",
    },
    {
      spoken: "“For Friday’s launch, Sam owns the release, Maya will send the notes before lunch, and I’ll check metrics after we ship.”",
      typed: "For Friday’s launch:\n1. Sam owns the release.\n2. Maya will send the notes before lunch.\n3. I’ll check metrics after we ship.",
      caption: "Three clear actions. No formatting commands.",
      time: "00:10",
    },
    {
      spoken: "“The idea is, um, your voice should work like a keyboard, only faster.”",
      typed: "Your voice should work like a keyboard—only faster.",
      caption: "Filler gone. The thought stays yours.",
      time: "00:05",
    },
  ];
  let demoTimers = [];

  const clearDemoTimers = () => {
    demoTimers.forEach((timer) => window.clearTimeout(timer));
    demoTimers = [];
  };

  const setDemoExample = (index, animate = true) => {
    if (!demoStage || !demoStatus || !demoTime || !demoSpoken || !demoTyped || !demoCaption) return;
    const example = examples[index] ?? examples[0];
    clearDemoTimers();

    demoButtons.forEach((button) => {
      const isActive = Number(button.dataset.demoExample) === index;
      button.classList.toggle("is-active", isActive);
      button.setAttribute("aria-pressed", String(isActive));
    });
    if (reducedMotion || !animate) {
      demoStage.classList.toggle("is-structured", index === 1);
      demoSpoken.textContent = example.spoken;
      demoTyped.textContent = example.typed;
      demoCaption.textContent = example.caption;
      demoTime.textContent = example.time;
      demoStatus.textContent = "Ready to paste";
      demoStage.classList.remove("is-listening", "is-processing", "is-swapping");
      demoStage.classList.add("is-ready");
      return;
    }

    demoStage.classList.remove("is-listening", "is-processing", "is-ready");
    demoStage.classList.add("is-swapping");
    demoStatus.textContent = "Listening — stays on this Mac";

    demoTimers.push(window.setTimeout(() => {
      demoStage.classList.toggle("is-structured", index === 1);
      demoSpoken.textContent = example.spoken;
      demoTyped.textContent = example.typed;
      demoCaption.textContent = example.caption;
      demoTime.textContent = example.time;
      demoStage.classList.remove("is-swapping");
      demoStage.classList.add("is-listening");
    }, 160));

    demoTimers.push(window.setTimeout(() => {
      demoStatus.textContent = "Polishing on this Mac";
      demoStage.classList.remove("is-listening");
      demoStage.classList.add("is-processing");
    }, 1420));

    demoTimers.push(window.setTimeout(() => {
      demoStatus.textContent = "Ready to paste";
      demoStage.classList.remove("is-processing");
      demoStage.classList.add("is-ready");
    }, 1840));
  };

  demoButtons.forEach((button) => {
    button.addEventListener("click", () => {
      setDemoExample(Number(button.dataset.demoExample));
    });
  });

  setDemoExample(0, !reducedMotion);

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
