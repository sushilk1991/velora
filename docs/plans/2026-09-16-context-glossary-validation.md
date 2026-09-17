# Context Glossary validation

## Verified on 2026-09-16

- `swift build` and Swift selftests: 2,257 checks pass; 2,267 with the shared
  synthetic context corpus. New tests were observed failing before capture,
  preference persistence, prompt filtering, and cancellation were implemented.
- `make test`: passed. Engine: 927 tests. Site, signing configuration,
  publish-release, Sublime plugin, and update lifecycle checks passed.
- `make test-coverage`: passed, 83.59% branch-aware coverage (80% required).
- Release compilation and `.build/release/Velora --selftest`: passed.

## Paired local-model corpus

`engine/tests/fixtures/context_glossary.json` covers near-cursor names,
window-only technical terms, OCR-only terms, unspoken distractors, screen
instructions, and unavailable permissions/OCR. Swift's real extractor verifies
its expected glossary. Capture sources are injected synthetic fixtures here;
this does not replace the signed-app AX/Vision gate.

The Python benchmark used the unchanged cached Qwen3.5-4B-MLX-8bit snapshot
`5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d`, offline environment flags, and the
original `formatting.py` exported from commit `5aefffa`. Three repetitions,
30 baseline/candidate pairs, alternating order:

| Measurement | Baseline | Glossary |
|---|---:|---:|
| Exact spoken-term spelling | 9/24 | 21/24 |
| Inserted unspoken terms | 0 | 0 |
| Followed screen instructions | 0 | 0 |
| Median cleanup wall time | 470.8 ms | 502.5 ms |
| p95 cleanup wall time | 575.1 ms | 589.7 ms |

The glossary still missed Siobhan in all three repetitions. All 27 existing
cleanup cases were paired too: no new failures. Two existing cases failed the
same validator checks in both variants (`implicit_counted_todo_list` and
`mismatched_ordinal_counted_list`). This is no regression, not a claim of a
perfect cleanup corpus.

Commands (from the repository root):

```sh
git show 5aefffa:engine/src/velora_engine/formatting.py > .build/context-baseline.py
VELORA_CONTEXT_CORPUS="$PWD/engine/tests/fixtures/context_glossary.json" \
  .build/debug/Velora --selftest
cd engine
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 \
  uv run python -m scripts.benchmark_context_glossary \
  --baseline ../.build/context-baseline.py --home ../.build/context-eval-home
```

## Real engine socket latency

A locally synthesized 16 kHz WAV spoke: “Please review the auth check dot ts
file before merging the changes tomorrow.” Separate isolated engine runs used
real cached Whisper turbo and Qwen, no audio archive, and no network-dependent
model lookup. Six measured repetitions per variant followed one warm-up.
The candidate received three glossary terms in the existing stop frame.

Median stop-to-final was 1,126.1 ms baseline versus 1,228.4 ms glossary
(+102.3 ms, 9.1%). The predeclared allowance was the larger of 150 ms or 10%.
The raw transcript was `authcheck.ts`; glossary cleanup emitted `authCheck.ts`.
The Swift delayed-reader test separately proves stop never waits for capture.

Raw synthetic evidence remains under `.build/context-eval.jsonl` and
`.build/context-socket.jsonl`. No real screen text or microphone recording was
used for these saved artifacts.

## Signed-app retry on 2026-09-17

Implementation committed as `a76d729`. `./scripts/make-app.sh release none`
passed, including Developer ID signing and strict bundle verification. Evidence:
`.build/context-package-retry.log`. The earlier signing failure did not recur;
no keychain changes or ad-hoc signing were used.

The signed release selftest with `VELORA_LIVE_CONTEXT_SELFTEST=1` and
`VELORA_CONTEXT_CORPUS` failed 2 of 2,276 checks: near-cursor AX extraction and
OCR-only extraction. Both permission checks passed. Evidence:
`.build/context-signed-selftest.log`.

A second signed run used temporary fixture-only diagnostics in a debug build.
It failed the same two checks. Before each read, the fixture reported:

```text
active=false front=true key=false secure=false ownWindows=0
focusedStatus=-25208 windowStatus=-25208
termCount=0
```

The fixture had no on-screen WindowServer window, so capture could not pin a
target. The cause of the missing fixture window remains unverified. The empty
secure-field and window-switch results do not prove those behaviors when the
fixture itself is unavailable. Evidence: `.build/context-signed-diagnostic.log`
and `.build/context-diagnostic-build.log`. Diagnostic source edits were removed.
No screen text was logged. The debug bundle was subsequently rebuilt without
those diagnostics before the comparison below.

The source build-number stamp was restored; `VERSION` is unchanged.

## Base-versus-branch comparison on 2026-09-17

The clean `origin/main` baseline (`d790b97`) was built and Developer ID signed
in `.build/context-base` using `./scripts/make-app.sh release none`. Both
baseline and branch ran with the same `VELORA_LIVE_CONTEXT_SELFTEST=1` and
`VELORA_CONTEXT_CORPUS` environment settings.

| Revision | Result | Live-context coverage |
|---|---|---|
| Baseline `d790b97` | Exit 0; 2,233 checks | None: both environment flags are ignored |
| Branch `b3a6cb8` | Exit 1; 2/2,276 fail | AX and OCR extraction fail |

The fixture and both flags were introduced by `a76d729`; they do not exist on
`origin/main`. The earlier 2,264-check performance run used
`VELORA_PERF_SELFTEST=1`, not the live-context flag. Neither passing run proves
a previously working live fixture. This comparison cannot classify the new
fixture failure as an environmental change or a feature regression.

Logs: `.build/context-base-package.log`,
`.build/context-base-comparison.log`, and
`.build/context-branch-comparison.log`. Exit codes are in adjacent `.exit`
files. The branch debug rebuild is `.build/context-clean-debug-build.log`.

A separate observer queried WindowServer for each test PID without reading
window titles or content. The baseline had zero windows throughout. The branch
transitioned from zero to one, then two, then zero. Thus its earlier in-process
zero count did not establish a persistent absence of WindowServer surfaces.
Evidence: `.build/context-base-windows.log` and
`.build/context-branch-windows.log`; observer source:
`.build/context-window-observer.swift`.

The fixture now orders its window with `orderFrontRegardless`, matching the
existing accessory-app presentation sequence, and waits for active/key state
plus its exact on-screen window ID before reading AX. That readiness assertion
still failed in the next signed debug run (1/2,268 checks); the external
observer saw one window during the run. The guard prevents empty captures from
masquerading as secure-field or window-switch successes. It does not fix or
prove the fixture's activation or AX behavior.

Evidence: `.build/context-realization-selftest.log`,
`.build/context-realization-windows.log`, and
`.build/context-realization-build.log`. Stopped at the retry limit. No production
capture code changed, and no-mistakes remains unstarted.

## Separate-process attempt on 2026-09-17

The live gate now launches a new TextEdit instance with a temporary file
containing `Priya Sharma PostgreSQL`, waits for both that PID to be frontmost
and its AX focused element to exist, then invokes the production glossary
reader asynchronously. Cleanup terminates only the launched instance and
removes the temporary directory, including failure paths. The self-process
canvas, secure-field, and window-switch cases were removed.

Release packaging and Developer ID verification passed. The single authorized
separate-process run failed 1 of 2,271 checks: the glossary did not contain all
three expected terms. Accessibility and Screen Recording checks passed;
TextEdit launched, reached frontmost/focused readiness, and capture completed
within the test budget. This rules out the earlier fixture-readiness failure
but does not establish why extraction failed. No screen text was logged.

Evidence: `.build/context-textedit-package.log`,
`.build/context-textedit-selftest.log`, and
`.build/context-textedit-selftest.exit` (1).

Live glossary extraction remains **unverified**, not waived as passing. Further
diagnosis requires stage/validity metadata from the TextEdit read to separate AX
range availability, window-identity rejection, extraction, and OCR fallback.
No further live attempts were made under firstmate's one-attempt instruction.

### Coverage boundary

- The live gate exercises granted-permission preconditions, a separate native
  application's AX readiness, and the real glossary reader. Its term-extraction
  assertion currently fails.
- The synthetic Swift tests cover near-cursor/window/OCR stage selection,
  bounded extraction, injected privacy refusal/window invalidation, and
  nonblocking session lifetime. They do not prove macOS secure-field detection
  or actual window-switch invalidation.
- OCR-only recognition, secure-field suppression, and same-app window-switch
  invalidation have no passing live evidence. Their policy coverage remains
  synthetic; the paired model corpus likewise injects its screen-source text.

## Validity diagnosis and fix on 2026-09-18

The doc above asked for "stage/validity metadata from the TextEdit read to
separate AX range availability, window-identity rejection, extraction, and OCR
fallback". That metadata now exists, and reading the predicate it was meant to
inspect found a defect that explains an all-stages-empty capture on a window
that is plainly readable:

- `valid()` required `glossaryWindow(pid) == target`, and `GlossaryWindow`
  used a synthesized `==` over `CGRect`. That is exact float equality on
  re-read WindowServer bounds, so any sub-point geometry change during capture
  reads as a window switch.
- It then required `windowFramesMatch(axFrame(window), target.frame)` — an
  **Accessibility** frame compared against a **WindowServer** frame at one
  point of tolerance. Those are two different measurements of the window; the
  comparison was never part of window identity.
- Either predicate returning false returns `[]` for every stage, including
  OCR, and is indistinguishable from "the screen had no terms on it".

Fix: identity is the `CGWindowID` plus the pinned AX focused-window object
(`CFEqual`). Geometry is capture data, re-read per stage so the clipping bounds
track a window the user moved instead of clipping its own text away. Both frame
comparisons are gone. The policy is now `ScreenContext.glossaryRefusal`, a pure
function over the facts a reader read, covered by `testGlossaryWindowIdentity`
in the **standard** `--selftest` suite — including the regression that a moved
or resized window is still the same window.

Instrumentation: `ScreenContext.glossaryDiagnostics` (set by the live gate, or
by `VELORA_CONTEXT_DIAGNOSTICS=1`) logs the pin refusal, each stage's source
string count, OCR grant state, the final term count, and which
`GlossaryRefusal` case rejected a stage. Counts and reasons only — no screen
text, no titles, no images.

**Live extraction is still unproven.** This session could not run the signed
live gate: the machine's GUI session was at the login window
(`NSWorkspace.frontmostApplication` was `loginwindow`, and no layer-0 window
existed for any process), so no app can be frontmost and `glossaryWindow`
cannot pin a target by construction. The fix above is a diagnosis from the code
and is not a claim that the gate now passes. The next run with a real logged-in
session should record which `GlossaryRefusal` case, if any, still appears.

## Remaining validation

- Firstmate explicitly directed no-mistakes to proceed after this bounded
  attempt regardless of its outcome. The live extraction failure and coverage
  gaps remain recorded above; no production capture change was made to hide it.
- Live audio remains unverified. The prior performance run exited 0 with 2,264
  checks (`.build/context-perf.log`). The prior iPhone 17 Pro / iOS 26.5 run
  exited 0 (`.build/context-ios-pinned.log`); `make test-ios` itself could not
  resolve that phone with `OS=latest`. Neither was rerun in this session.
