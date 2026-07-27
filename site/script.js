/* Velora — product site.
   Presentation only: no network calls, no storage beyond the theme choice. */
(() => {
  "use strict";

  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const reducedMotion = () => motionQuery.matches;

  /* ---------------------------------------------------------------------
     Theme
     --------------------------------------------------------------------- */

  const root = document.documentElement;
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const themeToggle = document.querySelector("[data-theme-toggle]");

  const activeTheme = () => root.dataset.theme || (darkQuery.matches ? "dark" : "light");

  const describeToggle = () => {
    if (!themeToggle) return;
    const next = activeTheme() === "dark" ? "light" : "dark";
    themeToggle.setAttribute("aria-label", `Switch to ${next} theme`);
  };

  themeToggle?.addEventListener("click", () => {
    const next = activeTheme() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem("velora-theme", next);
    } catch (error) {
      /* Storage can be denied; the choice still applies for this page view. */
    }
    describeToggle();
  });

  darkQuery.addEventListener("change", describeToggle);
  describeToggle();

  /* ---------------------------------------------------------------------
     Header state and scroll reveals
     --------------------------------------------------------------------- */

  const header = document.querySelector(".site-header");
  if (header) {
    const syncHeader = () => header.classList.toggle("is-stuck", window.scrollY > 8);
    syncHeader();
    window.addEventListener("scroll", syncHeader, { passive: true });
  }

  const revealItems = document.querySelectorAll(".reveal");
  const revealAll = () => revealItems.forEach((item) => item.classList.add("is-visible"));

  if (reducedMotion() || !("IntersectionObserver" in window)) {
    revealAll();
  } else {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8%", threshold: 0.08 }
    );

    revealItems.forEach((item) => observer.observe(item));

    /* Safety net. A reveal that never fires is an invisible page, so anything
       already in view when the timer expires is shown regardless. */
    window.setTimeout(() => {
      revealItems.forEach((item) => {
        if (item.classList.contains("is-visible")) return;
        if (item.getBoundingClientRect().top > window.innerHeight) return;
        item.classList.add("is-visible");
        observer.unobserve(item);
      });
    }, 1400);
  }

  /* ---------------------------------------------------------------------
     Dictation demo

     Two shapes of result:
       • "diff"  — a token-level rewrite. Removed tokens collapse to zero
                   width, added tokens expand into the gap they leave.
       • "lines" — structure the speaker never asked for out loud: a
                   numbered list, or a paragraph break on a topic shift.
     --------------------------------------------------------------------- */

  const EXAMPLES = [
    {
      app: "Messages",
      mode: "Message mode",
      caption: "Filler dropped. Self-correction applied. Meaning untouched.",
      hold: 5.4,
      tokens: [
        ["cut", "tell "],
        ["add", "Tell "],
        ["keep", "Maya "],
        ["cut", "um "],
        ["keep", "I can do "],
        ["cut", "three, actually make that three thirty"],
        ["add", "3:30."],
      ],
    },
    {
      app: "Notes",
      mode: "Note mode",
      caption: "Spoken ordinals became a list. You never said “bullet.”",
      hold: 9.1,
      raw: "first pull the logs then second check the retry counter and third file the ticket",
      lines: ["Pull the logs", "Check the retry counter", "File the ticket"],
      ordered: true,
    },
    {
      app: "Mail",
      mode: "Email mode",
      caption: "A topic shift became a paragraph. No sign-off invented.",
      hold: 12.6,
      raw: "thanks for sending that over i read it last night separately we should talk about the pricing page before friday",
      lines: [
        "Thanks for sending that over — I read it last night.",
        "Separately, we should talk about the pricing page before Friday.",
      ],
      ordered: false,
    },
  ];

  const demo = document.querySelector("[data-dictation-demo]");
  const stage = demo?.querySelector("[data-demo-stage]");
  const line = demo?.querySelector("[data-demo-line]");
  const list = demo?.querySelector("[data-demo-list]");
  const status = demo?.querySelector("[data-demo-status]");
  const clock = demo?.querySelector("[data-demo-time]");
  const caption = demo?.querySelector("[data-demo-caption]");
  const appName = demo?.querySelector("[data-demo-app]");
  const modeName = demo?.querySelector("[data-demo-mode]");
  const holdKey = demo?.querySelector("[data-demo-hold]");
  const live = demo?.querySelector("[data-demo-live]");
  const switches = demo ? Array.from(demo.querySelectorAll("[data-demo-example]")) : [];

  if (stage && line && list && status && clock && caption && holdKey) {
    let current = 0;
    let timers = [];
    let ticker = 0;
    let holdStart = 0;
    let listening = false;

    const clearTimers = () => {
      timers.forEach(window.clearTimeout);
      timers = [];
      window.cancelAnimationFrame(ticker);
    };

    const after = (delay, run) => timers.push(window.setTimeout(run, delay));

    const setState = (name) => {
      stage.classList.remove("is-listening", "is-polishing", "is-done");
      if (name) stage.classList.add(`is-${name}`);
    };

    const announce = (message) => {
      status.textContent = message;
      if (live) live.textContent = message;
    };

    const showClock = (seconds) => {
      clock.textContent = `${seconds.toFixed(1)}s`;
    };

    /* Tokens are laid out at their natural width, measured once, and then
       pinned to that width so the collapse and the expand both animate. */
    const measureTokens = () => {
      const tokens = line.querySelectorAll(".tok");
      tokens.forEach((token) => {
        token.style.setProperty("--w", `${token.getBoundingClientRect().width}px`);
      });
      /* Commit the measured width before transitions are switched on, so the
         initial none → px step is not something the browser animates. */
      void line.offsetWidth;
      tokens.forEach((token) => token.classList.add("is-sized"));
    };

    /* Build the markup for one example. */
    const render = (example) => {
      line.innerHTML = "";
      list.innerHTML = "";
      /* A previous "lines" example hides the line when it swaps in its list. */
      line.hidden = false;
      list.classList.remove("is-in");

      if (example.tokens) {
        list.hidden = true;
        example.tokens.forEach(([op, text]) => {
          const token = document.createElement("span");
          token.className = op === "keep" ? "tok" : `tok tok-${op}`;
          const inner = document.createElement("span");
          inner.textContent = text;
          token.append(inner);
          line.append(token);
        });
        measureTokens();
        return;
      }

      list.hidden = false;
      list.classList.toggle("is-ordered", Boolean(example.ordered));
      line.textContent = example.raw;
      example.lines.forEach((text, index) => {
        const item = document.createElement("li");
        item.style.setProperty("--i", String(index));
        const body = document.createElement("span");
        body.textContent = text;
        item.append(body);
        list.append(item);
      });
    };

    /* A collapsed token is zero pixels wide but still in the accessibility
       tree and still copied with a selection, which would read the raw and
       cleaned sentences as one run-on. Hide it properly. */
    const setTokenOut = (token, isOut) => {
      token.classList.toggle("is-out", isOut);
      if (isOut) token.setAttribute("aria-hidden", "true");
      else token.removeAttribute("aria-hidden");
    };

    /* Raw transcript: what the speech model heard, before cleanup. */
    const showRaw = (example) => {
      if (example.tokens) {
        line.querySelectorAll(".tok-cut").forEach((token) => {
          setTokenOut(token, false);
          token.classList.remove("is-marked");
        });
        line.querySelectorAll(".tok-add").forEach((token) => {
          setTokenOut(token, true);
          token.classList.remove("is-in");
        });
      } else {
        line.hidden = false;
        list.classList.remove("is-in");
        list.hidden = true;
      }
    };

    /* Cleaned result: what actually reaches your cursor. */
    const showResult = (example, animate, onCommit = () => {}) => {
      if (example.tokens) {
        const cuts = line.querySelectorAll(".tok-cut");
        const adds = line.querySelectorAll(".tok-add");

        const commit = () => {
          cuts.forEach((token) => setTokenOut(token, true));
          adds.forEach((token) => {
            setTokenOut(token, false);
            token.classList.add("is-in");
          });
          onCommit();
        };

        if (!animate) {
          cuts.forEach((token) => token.classList.remove("is-marked"));
          commit();
          return;
        }

        /* Mark first, then collapse — the viewer gets to see what was cut. */
        cuts.forEach((token) => token.classList.add("is-marked"));
        after(460, commit);
        after(1500, () => cuts.forEach((token) => token.classList.remove("is-marked")));
        return;
      }

      const swap = () => {
        line.hidden = true;
        list.hidden = false;
        /* Reflow rather than rAF: a throttled frame callback would leave the
           list at opacity 0, i.e. an empty card. */
        void list.offsetWidth;
        list.classList.add("is-in");
        onCommit();
      };

      if (!animate) {
        swap();
        return;
      }
      after(260, swap);
    };

    const settle = (example) => {
      clearTimers();
      setState("done");
      showResult(example, false);
      announce("Ready");
      showClock(example.hold);
    };

    const beginListening = (example, simulated) => {
      clearTimers();
      setState("listening");
      showRaw(example);
      announce("Listening — on this Mac");
      holdStart = performance.now();

      const tick = () => {
        const elapsed = (performance.now() - holdStart) / 1000;
        /* A scripted run compresses the spoken duration so the clock reads
           like the real sentence rather than the length of the animation. */
        showClock(simulated ? Math.min(example.hold, elapsed * (example.hold / 2.4)) : elapsed);
        ticker = window.requestAnimationFrame(tick);
      };
      tick();
    };

    const finishListening = (example) => {
      window.cancelAnimationFrame(ticker);
      showClock(example.hold);
      setState("polishing");
      announce("Polishing on device");

      after(520, () => {
        setState("done");
        showResult(example, true, () => announce("Pasted at your cursor"));
      });
    };

    const play = (example) => {
      if (reducedMotion()) {
        settle(example);
        return;
      }
      beginListening(example, true);
      after(2400, () => finishListening(example));
    };

    const load = (index, { autoplay = false } = {}) => {
      current = index;
      const example = EXAMPLES[index] ?? EXAMPLES[0];
      clearTimers();
      listening = false;
      holdKey.classList.remove("is-down");

      switches.forEach((button) => {
        const isActive = Number(button.dataset.demoExample) === index;
        button.classList.toggle("is-active", isActive);
        button.setAttribute("aria-pressed", String(isActive));
      });

      if (appName) appName.textContent = example.app;
      if (modeName) modeName.textContent = example.mode;
      caption.textContent = example.caption;

      render(example);
      settle(example);

      if (autoplay && !reducedMotion()) after(700, () => play(example));
    };

    /* Hold-to-dictate. A real press drives the state machine; a quick tap
       falls back to the scripted run so a plain click always shows it. */
    const startHold = () => {
      if (listening) return;
      const example = EXAMPLES[current];
      listening = true;
      holdKey.classList.add("is-down");
      if (reducedMotion()) {
        settle(example);
        return;
      }
      beginListening(example, false);
    };

    const endHold = () => {
      if (!listening) return;
      const example = EXAMPLES[current];
      listening = false;
      holdKey.classList.remove("is-down");
      if (reducedMotion()) {
        settle(example);
        return;
      }
      if (performance.now() - holdStart < 350) {
        play(example);
        return;
      }
      finishListening(example);
    };

    holdKey.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      holdKey.focus();
      startHold();
    });
    holdKey.addEventListener("pointerup", endHold);
    holdKey.addEventListener("pointercancel", endHold);
    holdKey.addEventListener("pointerleave", endHold);
    holdKey.addEventListener("keydown", (event) => {
      if (event.repeat || (event.key !== " " && event.key !== "Enter")) return;
      event.preventDefault();
      startHold();
    });
    holdKey.addEventListener("keyup", (event) => {
      if (event.key !== " " && event.key !== "Enter") return;
      endHold();
    });

    switches.forEach((button) => {
      button.addEventListener("click", () => {
        load(Number(button.dataset.demoExample), { autoplay: true });
      });
    });

    load(0);

    /* Token widths are pinned in pixels and the demo type is fluid, so a
       width change has to re-measure. Height-only changes (mobile URL bars)
       are ignored. */
    let lastWidth = window.innerWidth;
    let resizeTimer = 0;
    window.addEventListener("resize", () => {
      if (window.innerWidth === lastWidth) return;
      lastWidth = window.innerWidth;
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        if (!listening) load(current);
      }, 220);
    });

    /* Let the hero settle, then play the demo once. Whichever of the two
       triggers fires first wins; `played` keeps it to a single run. */
    if (!reducedMotion()) {
      let played = false;
      const playOnce = () => {
        if (played) return;
        played = true;
        after(900, () => play(EXAMPLES[current]));
      };

      if ("IntersectionObserver" in window) {
        const once = new IntersectionObserver(
          (entries) => {
            if (!entries.some((entry) => entry.isIntersecting)) return;
            once.disconnect();
            playOnce();
          },
          { threshold: 0.25 }
        );
        once.observe(demo);
      }

      window.setTimeout(() => {
        if (demo.getBoundingClientRect().top < window.innerHeight) playOnce();
      }, 1600);
    }
  }

  /* ---------------------------------------------------------------------
     Small utilities
     --------------------------------------------------------------------- */

  document.querySelectorAll("[data-current-year]").forEach((slot) => {
    slot.textContent = String(new Date().getFullYear());
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    const label = button.querySelector(".copy-label");
    const original = label?.textContent ?? "Copy";
    let reset = 0;

    button.addEventListener("click", async () => {
      window.clearTimeout(reset);
      try {
        await navigator.clipboard.writeText(button.dataset.copy ?? "");
        if (label) label.textContent = "Copied";
        button.classList.add("is-done");
        button.setAttribute("aria-label", "Command copied to clipboard");
      } catch (error) {
        if (label) label.textContent = "Select it below";
        button.setAttribute("aria-label", "Copy failed; select the command below");
      }

      reset = window.setTimeout(() => {
        if (label) label.textContent = original;
        button.classList.remove("is-done");
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
