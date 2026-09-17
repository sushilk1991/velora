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

## Remaining gates

- Signed packaging: `./scripts/make-app.sh release none` compiled successfully
  but codesigning bundled `uv` failed with `errSecInternalComponent`.
  `security find-identity` lists the configured Developer ID identity
  `2A29C6049D25A393166E25FA99819FD8EBF74997`; the signing failure's cause is not
  established. No ad-hoc signing fallback was attempted.
- Real AX, OCR-only window, secure-field and same-app window-switch checks are
  implemented behind `VELORA_LIVE_CONTEXT_SELFTEST=1`. Run from the signed
  `build/Velora.app/Contents/MacOS/Velora --selftest`; both Accessibility and
  Screen Recording must already be granted. These checks are not yet verified.
- Live audio, performance gate, and iOS results need final review. `make test-ios`
  could not resolve `iPhone 17 Pro, OS=latest` because the newest installed
  runtime has a different phone model. An equivalent test run explicitly using
  the existing iPhone 17 Pro / iOS 26.5 simulator was started.
- The packaging script stamped `Resources/Info.plist`'s build number. Restore
  that incidental source change after final packaging; `VERSION` is unchanged.
- No-mistakes has not started. Firstmate runs that phase after the feature is
  committed and reported complete.
