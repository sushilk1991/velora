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
