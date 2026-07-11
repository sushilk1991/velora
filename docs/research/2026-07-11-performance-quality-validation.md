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
- The HUD stops all perpetual idle animations. Installed-app dogfooding showed
  that the initial 348 x 72 two-line card left too much empty space, so the
  final fixed shell is 312 x 58 with one rolling whole-word line, a 28 x 20
  waveform, and the frontmost app icon plus detected mode retained below it.
- Every non-command final is staged on the clipboard before any insertion
  branch. A change-count guard still lets a newer user copy win.
- The engine preserves its active app connection when another local client
  probes the socket. The newcomer receives a fatal protocol error instead of
  displacing an in-flight dictation and triggering a false crash/restart HUD.
- Complete prose receives conservative punctuation and clear grammar repairs. Terminal input below 12 words stays model-free and command-safe (while explicit spoken line/paragraph controls still work); Terminal prose at or above 12 words receives conservative cleanup and retains sentence-ending punctuation.
- Explicit prose modes now take precedence over an app's broad code category:
  a `Default` dictation in Terminal no longer loses its final period. Code,
  short-command, Message, romanization, and auto-punctuation-off exceptions
  remain unchanged.

## Exact-model cleanup benchmark

All cases used the exact Qwen model above, temperature zero, and a prepared-prefix cache hit. Prefix preparation took 0.98–1.08 seconds during recording; it is excluded from stop-side generation because that work is deliberately moved off the release path. The committed runner is reproducible with `cd engine && uv run python scripts/benchmark_cleanup_quality.py`; `--list` prints every input and assertion without loading MLX.

| Case | Words | Stop-side cleanup | Result check |
|---|---:|---:|---|
| Declarative | 14 | 418 ms | final full stop present |
| Grammar repair | 18 | 493 ms | agreement/tense repaired conservatively |
| Question | 16 | 442 ms | question mark present |
| Terminal prose | 22 | 579 ms | final full stop retained |
| Names/numbers | 20 | 675 ms | names, Q3, time, and currency retained |
| Long prose | 45 | 1,049 ms | meaning and details retained |

Observed prior-build cleanup logs on the same Mac were 1.85–2.96 seconds for 12–96 words, including two timeouts. The final six-case benchmark measured a new stop-side range of 0.42–1.05 seconds for 14–45 words, with every punctuation, grammar, entity, and meaning assertion passing.

## End-to-end engine proof

`scripts/engine-smoke.py` streamed a synthesized 8.2-second, 16 kHz mono clip through a private production-protocol socket using the final engine, in Terminal app context with explicit `Default` mode. Four preview events arrived while audio was still streaming. In the controlled run:

- Whisper transcript: 865 ms after stop
- Qwen cleanup: 622 ms (`prepared_hit=True`)
- Final event: 1,489 ms after stop
- Final text: `Please verify that the live transcript appears early, and then fix the grammar and punctuation of this complete sentence without changing model quality.`

This proves the complete audio → Whisper → Qwen → punctuated final-text path, rather than only isolated model calls.

A deliberately contention-heavy repeat remained correct but took 2,360 ms
(Whisper 887 ms, Qwen 1,471 ms). At that moment the 36 GB Mac had roughly
320 MB free, a second 6.5 GB model process for the private smoke, a running VM,
an unrelated ESLint process at about 139% CPU, and both review agents. Qwen
first-token time alone rose to 1,085 ms. This is direct evidence that unified
memory pressure and competing work explain part of the M4-versus-M5 gap; the
duplicate smoke engine was stopped immediately afterward.

## Idle CPU

Before the HUD fix, the installed app was observed at 9.3% CPU while idle. A 12-sample `top` run on installed 0.4.6 build 82 measured 0.0% in every sample for both the Swift app and loaded model sidecar. The app held 20 MB with 9 threads; the sidecar held 6.47 GB with 30 threads and both exact models loaded. A prior five-second stack sample found the main thread blocked in the event loop and no waveform, canvas, timeline, or HUD rendering frames. The idle target remains below 1% CPU.

## Automated verification

- Python engine suite: 241 passed
- Swift release build: passed
- Swift self-test: 76 checks passed

## Distribution and installed-runtime proof

- Installed dogfood app: `/Applications/Velora.app`, version 0.4.6 build 82, Developer ID team `JZFVKGDPU4`, hardened runtime enabled
- Running executable: `/Applications/Velora.app/Contents/MacOS/Velora`
- Bundled and Application Support engine stamps both matched commit `a54723b1849fe9b31e0a9ccc3b22f7ec5b1e773a`
- A live second-client probe returned `Engine already has an active client`; app and engine PIDs remained unchanged
- Live engine status: idle, cleanup loaded, exact Whisper and Qwen model IDs above
- Stable signing identity restored the existing microphone, Input Monitoring, and Accessibility grants; the hotkey event tap installed successfully

The final notarized DMG identifiers, hash, and Gatekeeper result are reported in the release handoff so the committed source remains the artifact's exact input.

The HUD's whole-word selection, 312 x 58 bounds, 34-character rolling-tail budget, compact copied state, long-token elision, and paused-idle timelines are covered by the 76 Swift self-checks. Offscreen rendering of the actual SwiftUI view verified the listening and copied states without shipping the temporary snapshot harness. The final non-activating HUD panel is not exposed as a normal Accessibility window.
