# Performance and writing-quality validation — 2026-07-11

## Constraints

The optimization kept this M4 Max test device's configured production models and precision unchanged:

- Speech: `mlx-community/whisper-large-v3-turbo`
- Cleanup: `mlx-community/Qwen3.5-4B-MLX-8bit`

No model-size, quantization, output-token, quality, or model-selection code change was used to obtain the results below. First-run model selection on lower-memory Macs remains a separate existing product policy.

## Device conditions

The test device is a 14-core Apple M4 Max MacBook Pro with 36 GB unified memory. It was on AC power with `powermode 2` (High Power), so Low Power mode was not the cause. Memory pressure was a material environmental factor: after both models loaded, the system showed roughly 34 GB used, 9.3 GB compressed, and less than 1 GB unused. Quitting the previous Velora process recovered about 6 GB of free memory. The M5 Max has a platform advantage, but the larger same-device gap came from the avoidable software costs fixed in this change.

## What changed

- The exact Qwen prompt prefix is prepared while recording. Generation forks an immutable MLX cache snapshot, so preview, chunk, and final jobs cannot consume or corrupt one another's cache state; the transient working cache is released after each generation instead of being retained as a duplicate.
- Volatile app/entity context follows stable cleanup instructions, increasing the reusable prefix.
- Superseded preview/chunk tasks receive cooperative cancellation instead of continuing to occupy the single inference executor.
- A short first segment no longer disables streaming cleanup for an otherwise long Terminal dictation; the engine probes the mode's long-text path without applying command transforms at segment seams.
- The soft output deadline starts at the first generated token; an independent watchdog still bounds stuck prefill or inference.
- A hard-wedged Python inference thread poisons its cleanup engine: Velora first sends the raw fallback (or cancellation confirmation), then restarts the sidecar instead of queueing every later dictation behind an unkillable worker.
- Whisper warms the same `ModelHolder` instance used for transcription and adds preview-only decodes that cannot mutate committed/final state. Preview and segment decoding materialize only the overlapping undecoded audio chunks instead of repeatedly concatenating the complete recording.
- A speech-bearing tail that decodes empty forces an authoritative whole-clip retry, and rejected Whisper segments can no longer re-enter through the aggregate fallback.
- The HUD stops all perpetual idle animations and displays up to two readable lines using whole-word/sentence selection.
- Complete prose receives conservative punctuation and clear grammar repairs. Terminal input below 12 words stays model-free and command-safe (while explicit spoken line/paragraph controls still work); Terminal prose at or above 12 words receives conservative cleanup and retains sentence-ending punctuation.

## Exact-model cleanup benchmark

All cases used the exact Qwen model above, temperature zero, and a prepared-prefix cache hit. Prefix preparation took 0.97–1.05 seconds during recording; it is excluded from stop-side generation because that work is deliberately moved off the release path. The committed runner is reproducible with `cd engine && uv run python scripts/benchmark_cleanup_quality.py`; `--list` prints every input and assertion without loading MLX.

| Case | Words | Stop-side cleanup | Result check |
|---|---:|---:|---|
| Declarative | 14 | 427 ms | final full stop present |
| Grammar repair | 18 | 466 ms | agreement/tense repaired conservatively |
| Question | 16 | 489 ms | question mark present |
| Terminal prose | 22 | 553 ms | final full stop retained |
| Names/numbers | 20 | 619 ms | names, Q3, time, and currency retained |
| Long prose | 45 | 1,023 ms | meaning and details retained |

Observed prior-build cleanup logs on the same Mac were 1.85–2.96 seconds for 12–96 words, including two timeouts. The committed six-case benchmark measured a new stop-side range of 0.43–1.02 seconds for 14–45 words.

## End-to-end engine proof

`scripts/engine-smoke.py` streamed a synthesized 7.8-second, 16 kHz mono clip through a private production-protocol socket in Terminal context:

- Whisper transcript: 649 ms after stop
- Qwen cleanup: 607 ms (`prepared_hit=True`, 1,304 prefix tokens)
- Final event: 1,259 ms after stop
- Final text: `Please inspect all the performance issues in this branch and fix the grammar and punctuation without changing either model or reducing output quality.`

This proves the complete audio → Whisper → Qwen → punctuated final-text path, rather than only isolated model calls.

## Idle CPU

Before the HUD fix, the installed app was observed at 9.3% CPU while idle. A 12-sample `top` run on the rebuilt app measured 0.2% idle CPU with 26 MB resident memory and 9 threads. A five-second stack sample found the main thread blocked in the event loop and no waveform, canvas, timeline, or HUD rendering frames. The idle target remains below 1% CPU.

## Automated verification

- Python engine suite: 233 passed
- Swift release build: passed
- Swift self-test: 69 checks passed

The local development build was ad-hoc signed, which reset its TCC identity. Consequently, the hotkey-driven visible HUD could not be screen-captured in that validation pass. HUD clipping/selection/layout and idle behavior are covered by Swift self-tests and process sampling; the final distribution build must be signed with the stable release identity before installation.
