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
and `.build/context-diagnostic-build.log`. Diagnostic source edits were removed;
the current debug app bundle still contains them and must be rebuilt before
further validation. No screen text was logged.

The source build-number stamp was restored; `VERSION` is unchanged.

## Remaining gates

- Repair or replace the live fixture, then verify near-cursor AX, OCR-only,
  secure-field, and same-app window-switch behavior from the signed bundle.
  Stopped after the second failure under the worker retry limit.
- Live audio remains unverified. The prior performance run exited 0 with 2,264
  checks (`.build/context-perf.log`). The prior iPhone 17 Pro / iOS 26.5 run
  exited 0 (`.build/context-ios-pinned.log`); `make test-ios` itself could not
  resolve that phone with `OS=latest`. Neither was rerun in this session.
- No-mistakes has not started. The implementation is committed, but live-context
  validation is blocked.
