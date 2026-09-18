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

**Live extraction is proven at `e81c35d5`.** The signed live gate ran on an
unlocked session at head
`e81c35d55ef8f51b635212583b55bf2f9b72ad20` and exited 0 across 2,284 checks:

```
caffeinate -di env VELORA_LIVE_CONTEXT_SELFTEST=1 VELORA_CONTEXT_DIAGNOSTICS=1 \
  VELORA_CONTEXT_CORPUS=".../context_glossary.json" \
  .build/context-live-fixed/build/Velora.app/Contents/MacOS/Velora --selftest
```

What it read: a **separate** TextEdit process, not the test process, with
Accessibility and Screen Recording granted. What it extracted: the near-cursor
AX stage returned 2 source strings and the extractor produced 4 terms, the
on-screen names and technical term the fixture placed there. No
`GlossaryRefusal` case rejected a stage after the pin; the only refusal logged
was `refused=noWindow stage=pin` from the deliberate no-window probe. Logs:
`.build/context-fixed-package.log` (build) and `.build/context-fixed-live.log`
(run), with the result recorded in `.build/context-live-proof.json`.

**Still unproven live**, and unchanged by that run:

- **Image-recognition-only capture.** No live app was driven that renders its
  text to a canvas, so the Vision OCR stage has only ever run against the
  fixture corpus.
- **Suppression inside a password field.** `secureField` refusal is covered as
  a pure policy decision by `testGlossaryWindowIdentity`; no live secure text
  field has been focused mid-capture.
- **Switching windows mid-dictation.** `windowChanged` and `focusChanged` are
  likewise covered as policy only; no live capture has been raced against a
  real window switch.

The live gate needs an **unlocked graphical session with Accessibility
granted** — at the login window no app is frontmost and `glossaryWindow` cannot
pin a target by construction. That is why it stays behind
`VELORA_LIVE_CONTEXT_SELFTEST=1` and is deliberately **not** part of the
default `make test` run: making the standard gate depend on an unlocked desktop
would break it on every headless and CI machine. Window identity, the part that
can be decided without a desktop, is covered in the standard suite by
`testGlossaryWindowIdentity`.

## Stage budget reservation on 2026-09-18 (provisional, constant-derived)

Review finding `window-fallback-shares-exhausted-ax-deadline`: the near-cursor
sweep, the intervening title/deep-URL read (`entities(for:deepURL:)`) and the
window sweep all consumed the single `glossaryAXSeconds` (0.6 s) deadline
created before the first stage. In a slow-AX app the window stage opened with
no budget and returned `[]` before reading its root node, and that looked
identical to a window with no text. Decision 027 asked for a measured split;
decision 028 supersedes it and authorizes a constant-derived reservation now,
with measured tuning as a separate follow-up.

**Reservation.** `ScreenContext.GlossaryBudget` splits the unchanged 0.6 s
total into two deadlines from one start:

```
axTimeout             = 0.25 s   per-element AX messaging timeout every helper sets
glossaryWindowReserve = axTimeout = 0.25 s   one AX messaging round for the window
in-flight allowance   = axTimeout = 0.25 s   the one call a sweep may have issued
                                              just before noticing its deadline
nearby cutoff         = 0.6 - 0.25 - 0.25 = 0.10 s after start
window deadline       = 0.6 s after start (the total; never extended)
```

The nearby stage is handed the cutoff, the window stage the total. Decision
029 keeps these constants; the ratio is settled, not tuned.

**Per-message bound.** `axTimeout` caps one AX message, not one helper call:
a secure-field check is three messages (subrole, role, protected content), a
frame is two (position, size), and one sweep node issues up to ten. Each is
separately timed, so a block of N messages issued after one deadline check can
run N x 0.25 s. The glossary sweep therefore no longer checks its deadline per
helper or per node: every message in `glossaryNearby`, `glossarySecure` and
`collectGlossaryText` is preceded by a check of the fake-able clock against the
stage deadline (`GlossaryMessages.open`, or `send`, which performs that check
and returns nil instead of issuing the message). A nil from a gated secure
check stops the node before any text read. The largest block that can start before the cutoff and finish after
it is one message, bounded by `axTimeout`; that is what the in-flight allowance
covers, and why the window still opens with `glossaryWindowReserve` remaining
when the nearby stage is the only consumer between start and the window read.
The title/deep-URL read, which has its own timeouts and was between the two
stages only as a carry-over from when it seeded the window stage's text
(`4758824`), runs after every reader stage, so it cannot consume the
reservation; `ContextGlossary.capture` already merged it after stage selection.

This split is **provisional**: it guarantees a window attempt under the bound
above, it does not optimise either stage, and it has no measured basis.
Residual paths that are still outside the per-message gate:

- The two identity/permission checks (`valid()`) that run between the nearby
  and window reads: each is one `CGWindowListCopyWindowInfo` plus up to five
  AX messages (focused window, focused element, three secure-field reads), all
  ungated, each AX message bounded by `axTimeout`. They are kept deliberately,
  because a revoked lease or a window switch must stop the capture before the
  next read. In an app that answers within the reservation they cost
  milliseconds; if they stall, the window stage opens late and is logged
  `skipped=budget` rather than misreported as empty.
- The application, focused-window and focused-element reads that precede the
  budget's start, and the messages inside `valid()` before the first stage.
- The per-stage geometry re-read: `live().frame` issues one
  `CGWindowListCopyWindowInfo` call before each stage's gated sweep begins.
  It is a WindowServer call, not an AX message, and is outside
  `GlossaryMessages`.
- In an app that hits the 0.25 s messaging timeout on consecutive reads no AX
  stage can read anything, reservation or not.
- The nearby sweep is cut at its 0.10 s issue window in any app whose sweep
  needs longer, then tagged `budget=exhausted`. The cursor text has priority
  (its secure-field, range and string-for-range messages are issued first)
  but shares the cutoff, so it is skipped or truncated when those messages
  cannot complete before it; the neighbouring-label sweep is cut after it.

**Diagnostics** (`VELORA_CONTEXT_DIAGNOSTICS=1`, counts and milliseconds
only): each stage logs `stage=<source> strings=N ms=T`; a stage whose read
finished at or after its deadline appends `budget=exhausted`, covering both a
root guard that failed before the first read (`strings=0 ... budget=exhausted`)
and a sweep cut off after N strings. A stage opening after the total logs
`skipped=budget`. The title/URL read logs `named entities=N ms=T`. An `ms`
value on an exhausted stage is clipped by the deadline and is not a complete
stage cost. `testGlossaryBudget` (standard `--selftest`) drives the real
nearby sweep over a fake AX tree in which every message costs a fixed
synthetic delay (fractions of `axTimeout`, not measured app timings) on a fake
clock, and covers: for every message position of the fake editor's complete
trace, exactly the messages that fit start before the nearby cutoff and the
sweep returns within one in-flight message of it; the window keeps its
reserved round after a stalled multi-message sweep; a completed sweep reads
both the cursor text and the neighbouring label; the total is never extended and a
late window stage is skipped with OCR still running; exhausted versus empty
completed reads; and the named read running after every stage. With the
earlier per-helper checks in place the same test failed: further messages
started after the cutoff and, at a 62.5 ms per-message delay, consumed the
window's reserved round.

**Tuning follow-up.** On an unlocked session with the signed app granted
Accessibility, run the live gate against TextEdit and, for a slow-AX sample,
with an Electron app frontmost, and read the per-stage `ms` and `named` costs:

```
caffeinate -di env VELORA_LIVE_CONTEXT_SELFTEST=1 VELORA_CONTEXT_DIAGNOSTICS=1 \
  build/Velora.app/Contents/MacOS/Velora --selftest 2>&1 | grep 'Velora: glossary'
```

A probe during the fix round read `CGSSessionScreenIsLocked = 1`, frontmost
`com.apple.loginwindow`, and `AXIsProcessTrusted() == false`, so no timings
exist yet. Disregard `ms` values on lines carrying `budget=exhausted` when
tuning; they are clipped.

## Remaining validation

- **Word-list precision.** All-lowercase Latin tokens are accepted as terms
  when `/usr/share/dict/words` does not know them. That list is web2 — English
  base forms only. It therefore misses ordinary non-English words, so on a
  Spanish or German screen plain prose can be labelled as technical terms; and
  it misses modern derivations, so tokens like `config` can be accepted too.
  An accepted lowercase token is reader output and counts toward the
  sparseness threshold, so every false acceptance also risks suppressing the
  window and OCR stages; the terms are still real on-screen strings and the
  budgets still bound them. A hyphenated or possessive
  token is decomposed to its parts, a plural is resolved through its singular,
  a contraction tail (`n't`, `'ll`, `'ve`, `'re`, `'d`, straight or curly
  apostrophe) is stripped before the split, and an `ed`, `d` or `ing`
  inflection is resolved through its stem, so `doesn't`, `deployed` and
  `updated` read as prose and no longer fill the sparseness quota.
  An `es` plural, an `ies`/`ied` form (resolved through `y`) and a doubled
  final consonant before `ed`/`ing` are likewise resolved through their stem,
  so `fixes`, `queries`, `verified` and `committed` read as prose. There is
  no `er` rule.
  Accepted trade: a real term whose stem is an ordinary word (`systemd` ->
  `system`, `classes` -> `class`, `aliases` -> `alias`) reads as ordinary
  and is missed. A missed term degrades quietly; a false term is injected as
  an authoritative spelling and suppresses the remaining reading stages.
  There is no exception list for it.
  Decision (inbox 018): `docker` and `minified` are rejected, and stay
  rejected. Evidence: `/usr/share/dict/words` holds `docker` at line 56443
  and `minify` at line 116641, and `minified` reaches `minify` through
  `ied` -> `y`. `docker` was rejected by direct membership from the moment
  the word list replaced the spelling checker; no `er` rule was ever
  involved, and none is added. The product decision is to omit glossary
  hints for spellings the dictionary already knows rather than maintain
  exceptions for them; dictionary membership is the verified fact here, not
  a measurement of how the speech model spells those words. `newer`,
  `slower` and `larger` remain accepted as bounded false positives because
  further stemming is out of scope for this run.
- The `e81c35d5` live proof above is for the reader as it stood at that head.
  The later window-stage change (`4758824`, the window reader no longer seeds
  its output with title/URL values) is covered by `testGlossaryStages` in the
  standard `--selftest` suite, not by a re-run of the live gate.
- Authorized validation scope for the retry pipeline: non-GUI repository checks
  only (`make test`). No supplemental OCR-only live fixture, and no watch or
  wait for an unlocked session. The signed native TextEdit proof satisfies the
  live requirement; OCR-only, secure-field and window-switch stay the named
  limits listed above and are not default-gate dependencies.
- Live audio remains unverified. The prior performance run exited 0 with 2,264
  checks (`.build/context-perf.log`). The prior iPhone 17 Pro / iOS 26.5 run
  exited 0 (`.build/context-ios-pinned.log`); `make test-ios` itself could not
  resolve that phone with `OS=latest`. Neither was rerun in this session.
