# Velora Performance, Writing Quality, and Live HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. If work is
> delegated, use `superpowers:subagent-driven-development`; this run executes
> inline because no delegation was requested.

**Goal:** Remove avoidable inference and idle-UI latency while preserving the
exact models/final-quality path, restore punctuation and conservative grammar,
and provide an earlier readable live transcript.

**Architecture:** Prepare an exact, stable Qwen prompt prefix at session start,
reuse it without trimming on the hybrid cache, and separate prefill/TTFT from
the generation quality deadline. Make streaming cleanup cancellation reach the
executor thread. Warm Whisper through its real model holder and add a
preview-only decode lane that cannot mutate committed finalization state. Move
HUD text into a word-boundary two-row capsule and pause every hidden timeline.

**Tech stack:** Python 3.12, pytest/pytest-asyncio, MLX/MLX-LM,
mlx-whisper, Swift 5 mode, SwiftUI, SwiftPM, shell release tooling.

**Execution rule:** Complete each red-green-refactor slice before starting the
next. Use `apply_patch` for source edits. Do not change model IDs, quantization,
temperature, or final segment thresholds.

---

### Task 1: Establish isolated baseline

**Files:**

- Modify: `.gitignore`
- Add: `docs/plans/2026-07-11-performance-quality-hud-design.md`
- Add: `docs/superpowers/plans/2026-07-11-performance-quality-hud.md`

1. Commit the approved design, this plan, and `.worktrees/` ignore entry on
   `main`.
2. Create branch `fix/performance-quality-hud` at `.worktrees/performance-quality-hud`.
3. Run baseline checks from the worktree:

   ```bash
   cd engine && uv run pytest -q
   swift build -c release
   .build/release/Velora --selftest
   ```

4. Record any pre-existing failure before source edits. Expected result: all
   checks pass.

### Task 2: Preserve smart-Terminal sentences and strengthen grammar contract

**Files:**

- Modify: `engine/tests/test_formatting.py`
- Modify: `engine/src/velora_engine/formatting.py`
- Test: `engine/tests/test_divergence.py`

1. Add a failing test proving a `smart_terminal` gate retains a Qwen-produced
   terminal period while a sub-12-word Terminal command still strips one.
2. Run `uv run pytest tests/test_formatting.py -q`; confirm the new assertion
   fails because `postprocess` strips the period.
3. Scope code-category period stripping to gates whose reason is not
   `smart_terminal`.
4. Add prompt assertions for conservative subject/verb agreement, tense, and
   obvious grammatical errors plus explicit no-paraphrase constraints.
5. Update `STATIC_SYSTEM_PROMPT` and terminal prose instructions with the
   minimum text that satisfies those assertions.
6. Run:

   ```bash
   uv run pytest tests/test_formatting.py tests/test_divergence.py -q
   ```

7. Commit: `fix: preserve terminal prose punctuation and grammar`.

### Task 3: Make Qwen prompt caching exact and reusable

**Files:**

- Modify: `engine/tests/test_cleanup.py` (create if absent)
- Modify: `engine/src/velora_engine/cleanup.py`
- Modify: `engine/tests/test_formatting.py`
- Modify: `engine/src/velora_engine/formatting.py`

1. Add fake-tokenizer/cache tests for these public invariants:
   - prompt preparation returns an exact prefix shared with the final request;
   - stable mode/app/vocabulary context is before volatile entity/transcript
     content;
   - a non-trimmable cache is reused when the requested tokens extend it;
   - the last sampled token is not claimed as cached;
   - a genuine mismatch resets safely.
2. Run the focused tests and confirm they fail against `_warm` /
   `_generate_locked`.
3. Add an async `prepare_prefix(system_prompt, user_text_prefix)` API backed by
   the single cleanup executor and lock. Prefill the exact supplied tokens
   without generating semantic output; if MLX requires one generated token,
   track only tokens known to have entered the cache.
4. Refactor `_generate_locked` into small token/cache helpers so extension,
   trimmable rollback, and non-trimmable reset are explicit and testable.
5. Move volatile entity hints to the end of `build_system_prompt`, after stable
   mode/app/vocabulary/soft-correction instructions. Preserve the final prompt
   text semantics and add prompt-order assertions.
6. Log prefix token count, reuse/reset reason, and prefill milliseconds without
   logging prompt/transcript content.
7. Run focused tests, then all Python tests.
8. Commit: `perf: reuse exact qwen session prefixes`.

### Task 4: Prefill at session start and separate timeout phases

**Files:**

- Modify: `engine/tests/test_cleanup.py`
- Modify: `engine/tests/test_server.py`
- Modify: `engine/src/velora_engine/cleanup.py`
- Modify: `engine/src/velora_engine/server.py`

1. Add a failing cleanup test in which prefill consumes the old soft budget but
   fast output still succeeds; add a second test proving a true hard wedge
   returns the raw fallback.
2. Add a failing server test proving `start` schedules prefix preparation from
   the resolved mode/app/start entities and does not delay audio acceptance.
3. Start the soft output deadline when the first generation token arrives.
   Retain an independent outer hard watchdog that covers prefill plus output.
4. At `_cmd_start`, compute the same session gate/prompt shape used at final,
   launch a tracked prefill task, and let finalization await it only when it is
   still relevant. Romanization, non-LLM gates, model replacement, cancel, or a
   prompt mismatch safely skip/reset the cache.
5. Log prefill, TTFT, decode, output-token, cache-hit, and hard-watchdog metrics.
6. Run focused tests and all Python tests.
7. Commit: `perf: prefill cleanup while recording`.

### Task 5: Preempt obsolete streaming cleanup

**Files:**

- Modify: `engine/tests/test_server_streaming.py`
- Modify: `engine/src/velora_engine/server.py`
- Modify: `engine/src/velora_engine/cleanup.py`

1. Replace the fake cleanup delay with a cooperative fake that records a
   per-task cancel event. Add failing tests proving:
   - session cancel sets every worker event;
   - retraction replacement sets only the replaced chunk's event;
   - whole-text fallback cancels stale workers before final cleanup;
   - a new/final request is not queued behind the obsolete worker.
2. Give each chunk task a paired `threading.Event` stored by task identity or a
   small chunk-work record. Centralize cancellation so it calls both
   `task.cancel()` and `event.set()`.
3. Pass the event into `CleanupEngine.cleanup`; retain its between-token check.
   Distinguish cancellation from a quality timeout in metrics/reason text.
4. Run `uv run pytest tests/test_server_streaming.py tests/test_cleanup.py -q`,
   then the full Python suite.
5. Commit: `perf: preempt stale streaming cleanup`.

### Task 6: Warm Whisper once and add non-authoritative early previews

**Files:**

- Modify: `engine/tests/test_stt_segmenting.py`
- Modify: `engine/src/velora_engine/stt.py`

1. Add a failing load test with fake `mlx_whisper.transcribe.ModelHolder` that
   proves `load()` caches/evaluates the same object later used by transcribe.
2. Implement loading through `ModelHolder.get_model(local_path, mx.float16)`;
   do not alter the exact model, dtype, or decode arguments.
3. Add failing preview tests proving:
   - a pause after roughly four seconds can emit a partial before 10 seconds;
   - preview does not change `_decoded_samples`, `_segments`, or
     `take_new_segments()`;
   - the later 10-second committed decode still covers the full undecoded span;
   - short finalization still re-decodes the whole clip;
   - long finalization still uses only 10/25-second committed segments;
   - repeated near-identical preview attempts are throttled.
4. Add separate preview thresholds and cursor/backoff state. Decode the current
   undecoded span for display only; never call the segment commit logic from
   the preview path.
5. Keep `MIN_SEGMENT_S`, `SEGMENT_SILENCE_S`, `HARD_SEGMENT_S`, and
   `LONG_DICTATION_S` unchanged.
6. Run the focused file and full Python suite.
7. Commit: `perf: warm whisper and stream earlier previews`.

### Task 7: Make the HUD transcript readable and hidden HUD idle

**Files:**

- Modify: `Sources/Velora/Selftest/Selftest.swift`
- Modify: `Sources/Velora/HUD/HUDModel.swift`
- Modify: `Sources/Velora/HUD/HUDStyle.swift`
- Modify: `Sources/Velora/HUD/HUDPanel.swift`
- Modify: `Sources/Velora/HUD/HUDView.swift`
- Modify: `Sources/Velora/HUD/WaveformView.swift`

1. Extract a pure phrase-selection function and add failing selftests for:
   newline flattening, whole-word tails, complete-sentence preference, no
   mid-word start, bounded length, and empty updates preserving current text.
2. Replace the character suffix with that phrase selection and publish clear
   `liveTranscript` / truncation state names.
3. Rebuild recording content as a conditional two-row layout: up to two lines
   of transcript above the unchanged control row. Set a larger listening height
   only when transcript exists and increase `HUDPanel.panelSize` for shadows.
   Keep error/learned/notice and inserted-circle sizes unchanged.
4. Pass `active` into `WaveformView`; pause its timeline whenever recording
   content is hidden. Pause the transcript shimmer outside `.transcribing`,
   render a static timer while not listening, and start/stop/reset dot pulse on
   state transitions rather than permanent `.repeatForever` on appearance.
5. Add selftestable geometry assertions for maximum transcript width/height and
   panel containment.
6. Run:

   ```bash
   swift build -c release
   .build/release/Velora --selftest
   ```

7. Commit: `fix: show readable live dictation without idle redraws`.

### Task 8: Document and benchmark the exact-model result

**Files:**

- Modify: `docs/SPEC.md`
- Modify: `docs/ARCHITECTURE.md`
- Add: `docs/research/2026-07-11-performance-quality-validation.md`
- Add/Modify: benchmark helper under `engine/scripts/` only if a reusable
  existing helper is insufficient.

1. Update the contracts for smart Terminal, quality-first timeout phases,
   session prefill, cancellation, preview-only HUD decodes, and final
   segmentation invariants.
2. With the exact installed models, capture before/after-equivalent metrics for
   representative 12, 20, 50, and 90-word cleanup inputs: prefix tokens,
   prefill, TTFT, decode, total, output, punctuation, and divergence result.
3. Run golden quality fixtures containing declarative sentences, questions,
   agreement/tense repairs, names/numbers, Terminal prose, and short shell
   commands. Manually inspect outputs; do not accept a speedup with meaning or
   detail loss.
4. Build a Release app and measure the hidden process twice over at least 10
   seconds using `top` plus `sample`. Target under 1% CPU after HUD dismissal;
   report the exact device power/memory context.
5. Record results and remaining environmental constraints in the validation
   document.
6. Run full verification:

   ```bash
   cd engine && uv run pytest -q
   swift build -c release
   .build/release/Velora --selftest
   git diff --check
   ```

7. Commit: `docs: record exact-model performance validation`.

### Task 9: Adversarial review, integrate, install, and ship

**Files:** all changed files and release artifacts.

1. Run a read-only falsification review:

   ```bash
   yoyo ask codex,claude --role review --read-only --background \
     "Review the fix/performance-quality-hud diff. Find any model-quality, cache-correctness, cancellation-race, final-segmentation, punctuation, HUD clipping, idle-CPU, or release blocker. Cite files and tests; do not modify files."
   ```

2. Read both reports, reproduce material findings locally, fix with TDD, and
   rerun focused plus full checks.
3. Use `superpowers:verification-before-completion`, then
   `superpowers:finishing-a-development-branch`. Merge the verified branch into
   local `main` without discarding unrelated user changes.
4. Run `./scripts/make-app.sh release patch` exactly once to create a new
   version. Quit existing Velora, replace `/Applications/Velora.app`, and launch
   the installed app.
5. Verify live proof:
   - installed and running bundle reports the new version/build;
   - engine PID belongs to the new app and reports both exact model IDs;
   - setup/onboarding is complete;
   - short Terminal remains verbatim and long Terminal prose retains sentence
     punctuation in an end-to-end dictation or deterministic socket fixture;
   - a HUD partial appears as whole words in the two-row layout;
   - idle CPU target is met after dismissal.
6. Create/sign/notarize/verify the DMG only if release credentials are present;
   never weaken signing or Gatekeeper. At minimum package and verify the app
   bundle used locally.
7. Commit the bumped `VERSION` and release artifacts that are intentionally
   tracked, tag according to repository convention if the release script does
   so, and push `main` plus the new tag to `origin`.
8. Report exact test counts, benchmark deltas, installed version, running PIDs,
   commit SHA, pushed ref/tag, and any remaining device-level caveat.
