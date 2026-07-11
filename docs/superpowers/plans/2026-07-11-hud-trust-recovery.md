# HUD Trust Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Velora's trusted waveform-first recording experience, remove non-authoritative HUD text and inference work, preserve exact model quality, and ensure short spoken Terminal prose receives grammatical cleanup while real commands remain verbatim.

**Architecture:** Keep authoritative transcription and cleanup in the existing Python engine and keep the Swift client as a truthful state renderer. Remove only the HUD-only preview lane, cooperatively cancel optional Qwen prefix preparation before final work, route short Terminal text through the existing command-versus-prose branches, and restore the known-good v0.4.5 HUD motion without restoring its transcript row.

**Tech Stack:** Swift 6.1 / SwiftUI / AppKit, Python 3.12 / asyncio, pytest / pytest-asyncio, MLX Whisper, MLX-LM Qwen, SwiftPM, SQLite inspection, Developer ID signing and Apple notarization.

## Global Constraints

- Keep `mlx-community/whisper-large-v3-turbo` and `mlx-community/Qwen3.5-4B-MLX-8bit` unchanged, including final decoding quality.
- Preserve committed 10/25-second long-dictation segmentation and streamed cleanup; remove only non-authoritative HUD display previews.
- Preserve the clipboard-before-insertion guarantee introduced in 0.4.6.
- Restore the original v0.4.5 motion and visual hierarchy, but never show raw or provisional transcript text in the HUD.
- Show the actual mode: supported terminals say `Terminal`; editors say `Code`.
- Keep shell commands byte-for-byte unchanged. The deterministic classifier chooses an existing branch; it never rewrites text.
- Optional prefill must never sit ahead of final cleanup after stop.
- Every implementation task starts with a failing intent test and ends with its focused tests passing.
- Do not claim success from unit tests alone. The installed, signed app must be dogfooded with the exact acceptance phrases and real HUD states.
- A timed-out or unavailable reviewer is not approval. Resolve every concrete review finding or record why it is invalid with evidence.
- Do not commit temporary preview harnesses, recordings, screenshots, databases, logs, credentials, or release intermediates.

---

## Task 1: Fix Short Terminal Prose Routing

**Files:**

- Modify: `engine/tests/test_formatting.py`
- Modify: `engine/src/velora_engine/formatting.py`

- [ ] **Step 1: Add failing prose-versus-command tests**

  Add parameterized tests proving that these short Terminal utterances select the existing smart-Terminal cleanup branch:

  - `I just tested it is just putting the random text`
  - `what this request section is do we even need it now`
  - `please rerun the tests and show me the failures`
  - `this design is looking really bad`

  Add or retain parameterized tests proving these remain verbatim:

  - `git status`
  - `git rebase --interactive HEAD~3`
  - `python -m pytest`
  - `rm -rf build`
  - `npm run build`
  - `docker compose up`

- [ ] **Step 2: Run the focused test and verify the new prose cases fail**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_formatting.py -q
  ```

  Expected: the new short natural-language cases fail because the current `< 12` word rule returns the verbatim Terminal branch.

- [ ] **Step 3: Add the smallest deterministic prose gate**

  In `formatting.py`, add a private helper such as `_short_terminal_is_prose(text: str) -> bool` and use it only to choose between the existing verbatim and `smart_terminal` branches.

  The helper must be conservative:

  - Shell flags, paths, assignments, pipes, redirects, command substitution, globbing, and command-shaped operator syntax stay verbatim.
  - Natural pronoun-led statements, ordinary questions, and polite requests without shell syntax route to smart cleanup.
  - Useful prose indicators include `I`, `we`, `this`, `that`, `it`, `please`, `can you`, `could you`, `would you`, `do you`, `did you`, `why`, `what`, `when`, `where`, `who`, `how`, `is`, `are`, `should`, `tell me`, and `help me`.
  - Keep ambiguous short fragments verbatim rather than guessing.

  Do not add a rewriting parser, regex punctuation layer, or new model call.

- [ ] **Step 4: Run focused formatting and divergence tests**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_formatting.py tests/test_divergence.py -q
  ```

  Expected: all pass; commands are exactly preserved and prose selects `smart_terminal`.

- [ ] **Step 5: Commit the isolated routing change**

  ```bash
  git add engine/src/velora_engine/formatting.py engine/tests/test_formatting.py
  git commit -m "fix: clean short terminal prose"
  ```

---

## Task 2: Give Authoritative Cleanup Priority Over Optional Prefill

**Files:**

- Modify: `engine/tests/test_server.py`
- Modify: `engine/src/velora_engine/server.py`

- [ ] **Step 1: Add a failing cancellation-order integration test**

  Create a fake cleanup backend whose `prepare_prefix` blocks until its cancellation event is set and whose final `cleanup` records whether cancellation had already happened. Drive a real socket session through start, audio, and stop.

  Assert all of the following:

  - Prefix preparation began during recording.
  - Stop sets the prefix cancellation event before final cleanup is invoked or queued behind it.
  - Final cleanup completes and its output is returned.
  - The cleanup engine is not marked unhealthy and the session does not request a restart.

- [ ] **Step 2: Run the focused server test and verify ordering fails**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_server.py -k 'prefix and cancel' -q
  ```

  Expected: the new assertion fails because cancellation currently occurs in finalization's `finally` block, after cleanup has already tried to run.

- [ ] **Step 3: Cancel prefix preparation at finalization entry**

  Call `_cancel_prefix_preparation(session)` at the beginning of `_finalize_session`, before `_finalize_session_inner`. Remove the late duplicate from `finally` unless another lifecycle path demonstrably needs the idempotent safety call.

  Keep the change local: do not add executors, priorities, or alternate cleanup paths unless the test proves early cooperative cancellation is insufficient.

- [ ] **Step 4: Run server and cleanup regression tests**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_server.py tests/test_server_streaming.py tests/test_cleanup.py -q
  ```

  Expected: all pass, including timeout, disconnect, crash, and long-session cleanup cases.

- [ ] **Step 5: Commit the finalization-priority fix**

  ```bash
  git add engine/src/velora_engine/server.py engine/tests/test_server.py
  git commit -m "fix: prioritize final cleanup over prefill"
  ```

---

## Task 3: Disable HUD-Only Whisper Preview Inference

**Files:**

- Modify: `engine/tests/test_stt_segmenting.py`
- Modify: `engine/src/velora_engine/stt.py`
- Modify only if required: `engine/tests/test_server.py`

- [ ] **Step 1: Add a failing default-behavior test**

  Add a test proving a normally constructed production `WhisperBackend` does not queue or run a two-second display preview. Keep the existing preview mechanics testable by explicitly setting `preview_enabled = True` in preview-specific fixtures.

  Preserve tests proving 10/25-second committed segment transcription and final segment draining still occur.

- [ ] **Step 2: Run the segmenting test and verify the default assertion fails**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_stt_segmenting.py -q
  ```

  Expected: the new default test fails while existing preview tests continue to describe the opt-in diagnostic behavior.

- [ ] **Step 3: Disable previews by default**

  Set the backend's production default `preview_enabled` to `False`. Do not change model identifiers, decode options, committed-segment thresholds, overlap handling, or final transcription.

- [ ] **Step 4: Run STT and streaming regression tests**

  Run:

  ```bash
  cd engine
  uv run pytest tests/test_stt_segmenting.py tests/test_server_streaming.py tests/test_server.py -q
  ```

  Expected: all pass. Explicit opt-in preview tests pass, production default emits no display-only decode, and committed segments remain intact.

- [ ] **Step 5: Commit the inference removal**

  ```bash
  git add engine/src/velora_engine/stt.py engine/tests/test_stt_segmenting.py engine/tests/test_server.py
  git commit -m "perf: remove production HUD preview inference"
  ```

  If `engine/tests/test_server.py` was not changed, omit it from `git add`.

---

## Task 4: Make the Displayed Mode Truthful

**Files:**

- Modify: `Sources/Velora/Config/ModeCategories.swift`
- Modify: `Sources/Velora/Context/ScreenContext.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

- [ ] **Step 1: Change selftest expectations first**

  Add or change selftests so:

  - Apple Terminal, iTerm2, Ghostty, Warp, Alacritty, Kitty, and cmux resolve to `ModeCategory.terminal` with display name `Terminal`.
  - VS Code, Cursor, and Zed resolve to `ModeCategory.code` with display name `Code`.
  - Existing Chat, Email, Notes, and Browser mappings remain unchanged.

- [ ] **Step 2: Run the Swift selftest and verify the Terminal expectation fails**

  Run:

  ```bash
  swift build
  .build/debug/Velora --selftest
  ```

  Expected: compile or assertion failure because `.terminal` does not yet exist and terminals currently map to `.code`.

- [ ] **Step 3: Add `ModeCategory.terminal` and update exhaustive consumers**

  Map these bundle identifiers to `.terminal`:

  - `com.apple.Terminal`
  - `com.googlecode.iterm2`
  - `com.mitchellh.ghostty`
  - `dev.warp.Warp-Stable`
  - `org.alacritty`
  - `net.kovidgoyal.kitty`
  - `com.cmuxterm.app`

  Give the new case display name `Terminal`. In `ScreenContext`, share code-oriented title parsing only where behavior is genuinely common (`case .code, .terminal`) without relabeling the mode.

- [ ] **Step 4: Run the full Swift selftest**

  Run:

  ```bash
  swift build
  .build/debug/Velora --selftest
  ```

  Expected: all selftests pass and Ghostty displays `Terminal`.

- [ ] **Step 5: Commit mode truth separately**

  ```bash
  git add Sources/Velora/Config/ModeCategories.swift Sources/Velora/Context/ScreenContext.swift Sources/Velora/Selftest/Selftest.swift
  git commit -m "fix: distinguish terminal mode from code"
  ```

---

## Task 5: Restore the Waveform-First HUD Without Transcript Text

**Files:**

- Modify: `Sources/Velora/HUD/HUDView.swift`
- Modify: `Sources/Velora/HUD/HUDStyle.swift`
- Modify: `Sources/Velora/HUD/HUDPanel.swift`
- Modify: `Sources/Velora/HUD/HUDModel.swift`
- Modify: `Sources/Velora/HUD/WaveformView.swift`
- Modify: `Sources/Velora/App/DictationController.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`
- Reference only: commit `4106d53` versions of the HUD files

- [ ] **Step 1: Replace transcript-card selftests with approved geometry tests**

  Remove tests that enshrine transcript selection, transcript tail lengths, the 312 x 58 transcript card, or the seven-bar mark. Add tests for:

  - 56-point capsule height.
  - 280-point minimum listening width and 420-point maximum if retained from the original.
  - 120 x 32-point waveform strip.
  - 24 rendered bars backed by 12 unique mirrored spectrum bands.
  - 56-point inserted-state diameter.
  - A host panel large enough for the capsule, error surface, border, and shadow without clipping.

- [ ] **Step 2: Run the selftest and verify the restored contract fails**

  Run:

  ```bash
  swift build
  .build/debug/Velora --selftest
  ```

  Expected: failures against the current 312 x 58 transcript card, 28 x 20 waveform, and seven-bar store.

- [ ] **Step 3: Restore the original waveform data path**

  In `HUDModel` and `WaveformView`:

  - Restore `WaveformLevelStore.barCount = 24` and `halfCount = 12`.
  - Render the mirrored 24-bar waveform using all 12 spectrum bands.
  - Restore 30 fps display updates.
  - Remove transcript selection, stable/provisional text, truncation, and tail helpers that become dead after the HUD stops rendering words.

- [ ] **Step 4: Restore the original state choreography**

  Adapt the known-good implementation from `4106d53` into a permanently single-row capsule:

  - Leading app icon and actual mode label.
  - Red recording dot, 120 x 32 waveform, and timer during listening.
  - Restrained rotating ring and entrance spring.
  - Waveform settle and shimmer while transcribing.
  - Brief green waveform flash followed by the compact checkmark morph on insertion.
  - Existing actionable error capsule, notice, and learned-correction states.
  - Pause hidden or irrelevant animation timelines.

  Do **not** restore the old expanding transcript row. Do **not** add a generic `Polishing` claim before the engine reports cleanup.

- [ ] **Step 5: Stop rendering protocol partials**

  In `DictationController`:

  - Treat `.partial` as protocol-compatible telemetry only; do not update HUD text.
  - Continue storing authoritative `.transcript` raw text and refreshing timeout/progress behavior as required, but do not display it in the HUD.
  - Preserve clipboard staging and insertion behavior exactly.

- [ ] **Step 6: Restore panel sizing and hit testing**

  Use a transparent host large enough for the widest error state and shadows (the original 480 x 160 host is acceptable). Keep the visible recording surface compact. Ensure hit testing follows the visible card/error footprint and no invisible host area steals clicks.

- [ ] **Step 7: Build and run all Swift selftests**

  Run:

  ```bash
  swift build
  .build/debug/Velora --selftest
  swift build -c release
  .build/release/Velora --selftest
  ```

  Expected: all pass with no transcript-card assertions or dead transcript model state.

- [ ] **Step 8: Inspect a temporary real SwiftUI preview capture**

  If a temporary preview/debug harness is needed, render listening, transcribing, inserted, and error states using production views. Capture them with macOS screen capture and inspect spacing, clipping, animation state, icon, and mode label. Delete the harness and generated artifacts before committing.

- [ ] **Step 9: Commit the cohesive HUD restoration**

  ```bash
  git add Sources/Velora/HUD Sources/Velora/App/DictationController.swift Sources/Velora/Selftest/Selftest.swift
  git commit -m "fix: restore waveform-first dictation HUD"
  ```

---

## Task 6: Run Full Quality and Regression Validation

**Files:**

- Modify only if an assertion needs correction: `engine/scripts/benchmark_cleanup_quality.py`
- Do not commit generated logs or databases.

- [ ] **Step 1: Run the complete automated suite**

  Run:

  ```bash
  cd engine
  uv run pytest -q
  cd ..
  swift build -c release
  .build/release/Velora --selftest
  git diff --check
  ```

  Expected: all Python tests, the release build, Swift selftests, and whitespace checks pass.

- [ ] **Step 2: Run exact-model cleanup quality fixtures**

  Run:

  ```bash
  cd engine
  uv run python scripts/benchmark_cleanup_quality.py
  ```

  Record total and per-case latency. Verify punctuation, grammar, names, numbers, and intended meaning. Treat any semantic rewrite or missing full stop as a blocker.

- [ ] **Step 3: Review the complete diff for scope and regressions**

  Inspect:

  ```bash
  git status --short
  git diff 799046e...HEAD --stat
  git diff 799046e...HEAD
  ```

  Confirm every changed line traces to routing, prefill priority, preview removal, mode truth, HUD restoration, tests, or release metadata. Confirm model identifiers and clipboard staging did not change.

- [ ] **Step 4: Request an adversarial Claude Code review through `yoyo ask`**

  Ask the reviewer to falsify these claims using the actual diff and callers:

  - Commands remain byte-for-byte preserved.
  - Optional prefill cannot delay final cleanup.
  - Production no longer performs HUD-only Whisper previews.
  - Long-session committed segmentation still works.
  - HUD contains no provisional transcript and uses all 12 bands.
  - Mode and clipboard behavior remain truthful.

  Spot-check every finding locally. Fix valid findings and rerun affected tests. A timeout does not count as review completion.

- [ ] **Step 5: Commit any evidence-backed review fixes**

  Use a focused commit message describing the actual correction; do not create a generic review-cleanup commit if no code changed.

---

## Task 7: Build, Install, and Dogfood the Signed App

**Files:**

- Modify: `VERSION`
- Generated but not committed: `build/Velora-0.4.7.dmg` and notarization logs

- [ ] **Step 1: Bump the patch version exactly once**

  Run the release pipeline with a single patch bump. Confirm `VERSION` becomes `0.4.7`; do not invoke another bumping command afterward.

  ```bash
  ./scripts/make-dmg.sh release patch
  ```

  Expected: release app is Developer ID-signed, DMG submission is accepted, and the image is stapled.

- [ ] **Step 2: Verify the DMG and release identity**

  Run:

  ```bash
  ./scripts/verify-dmg.sh build/Velora-0.4.7.dmg
  codesign --verify --deep --strict --verbose=2 build/Velora.app
  spctl --assess --type execute --verbose=4 build/Velora.app
  ```

  Also record the DMG SHA-256 and notarization submission id.

- [ ] **Step 3: Install the release build over `/Applications/Velora.app`**

  Quit the current app cleanly, replace it using the verified release artifact, relaunch it, and confirm:

  - The running executable is `/Applications/Velora.app/Contents/MacOS/Velora`.
  - `CFBundleShortVersionString` is `0.4.7`.
  - Build number and code signature match the just-built artifact.
  - The supervised engine starts successfully and uses the bundled expected source/runtime.

- [ ] **Step 4: Capture real installed HUD states**

  Record the actual installed HUD through listening, stop/transcribing, inserted, and an actionable error/retry state. Inspect the recording rather than relying on code geometry alone.

  Acceptance criteria:

  - No provisional words appear.
  - Capsule remains compact with no transcript-sized empty area.
  - App icon and `Terminal` are visible in Ghostty.
  - 24-bar waveform reacts smoothly and settles on stop.
  - No jarring width jumps, clipping, misalignment, or idle animation burn.
  - Success green flash/checkmark morph matches the original quality bar.

- [ ] **Step 5: Dogfood exact Terminal phrases**

  In Ghostty, dictate and inspect both inserted text and the matching `~/.velora/history.sqlite3` raw/final rows:

  - `please rerun the tests and show me the failures` -> cleaned, capitalized, punctuated prose.
  - `I just tested it is putting random text` -> cleaned, capitalized, punctuated prose.
  - `git status` -> exactly `git status`.
  - `git rebase --interactive HEAD~3` -> exactly preserved.

  Also dictate one 8-10 second natural sentence and verify grammar and sentence-final punctuation.

- [ ] **Step 6: Inspect performance logs for the regression signals**

  For the warm 8-10 second session, verify logs show:

  - No HUD preview decode.
  - Prefix preparation does not repeat the observed 15.7-second stall.
  - Stop does not wait behind optional prefix work.
  - Final Whisper and Qwen timing are materially lower than 0.4.6's roughly 6.97-second total on this Mac.
  - No cleanup-engine unhealthy, crash, or restart state.

  If a result is still slow, collect timing evidence and diagnose before shipping; do not weaken model quality.

- [ ] **Step 7: Commit release metadata after all installed checks pass**

  ```bash
  git add VERSION Resources/Info.plist
  git commit -m "build: prepare 0.4.7 release"
  ```

  Include only files actually changed by the release pipeline.

---

## Task 8: Land and Prove Main

- [ ] **Step 1: Re-run the final clean-tree gate**

  Run:

  ```bash
  cd engine && uv run pytest -q
  cd ..
  swift build -c release
  .build/release/Velora --selftest
  git diff --check
  git status --short --branch
  ```

  Expected: all checks pass and the worktree is clean.

- [ ] **Step 2: Integrate the implementation branch into local `main`**

  Use a non-destructive merge or fast-forward, preserving the approved design and plan commits. Re-run the clean-tree gate on `main` so validation is against the exact branch being pushed.

- [ ] **Step 3: Push `main` and verify the remote SHA**

  ```bash
  git push origin main
  git rev-parse HEAD
  git ls-remote origin refs/heads/main
  ```

  Expected: local and remote `main` SHAs match.

- [ ] **Step 4: Report concrete proof**

  Report:

  - Final pushed SHA and version/build.
  - Python and Swift test results.
  - Exact-model benchmark result and observed installed stop latency.
  - Installed app path/PID and Gatekeeper/notarization result.
  - Dogfood raw/final outcomes for prose and commands.
  - Visual QA result for each HUD state.
  - Any residual risk or explicitly deferred true cursor-level streaming work.
