# Current-model whole-flow performance validation

**Date:** 2026-08-06
**Branch:** `perf/current-model-flow`
**Machine:** Apple M4 Max, 36 GB, macOS 26.5.2 (25F84)

## Scope and invariants

This round measured the complete local dictation path and kept the production
model pair unchanged:

- STT: `mlx-community/whisper-large-v3-turbo`
- cleanup: `mlx-community/Qwen3.5-4B-MLX-8bit`

No prompt, generation parameter, quantization, audio ordering, or fallback-text
policy changed. Real history and audio were used only on this Mac. Reports under
`/tmp` were mode `0600`, contained hashes/aggregates rather than transcript
bodies, and were not committed.

## Baseline

The read-only history report covered 432 dictations and 432 available archived
recordings. Newer timing columns were available for 280 finalizations.

| Metric | p50 | p95 | max |
|---|---:|---:|---:|
| stop-to-final (`finalization_ms`) | 2,061 ms | 10,736 ms | 22,909 ms |
| STT | 699 ms | 5,956 ms | 19,662 ms |
| cleanup wall | 1,309 ms | 4,502 ms | 7,159 ms |
| derived recovery residual | 1 ms | 1 ms | 10,000 ms |

The recovery residual is
`max(0, finalization_ms - stt_ms - cleanup_wall_ms)`. Six sessions had explicit
multi-second residuals: 7.060, 7.179, 7.189, 7.293, 7.635, and 10.000 seconds.
Logs confirmed that final STT had already completed, then finalization awaited a
replacement cleanup model for up to ten seconds.

A smaller six-file installed-runtime replay spanning roughly 2, 5, 10, 20, 40,
and 60 seconds ran twice before implementation. All six output hashes were
stable across repeats. Subprocess wall time was 2,758 ms p50 / 6,369 ms p95.
The current CLI field named `stt_ms` covers file inference through explicit-mode
cleanup, so it is not reported here as STT-only.

The reusable 15-case x 3-repeat runner later measured 4,475 / 32,997 ms wall
p50/p95 and 3,805 / 32,697 ms engine-total p50/p95. Only 8/15 cases were
repeat-hash-stable. That stress run was strongly run-order noisy and is retained
as diagnostic evidence, not accepted as clean before/after evidence.

## Kept optimization: never wait for cleanup recovery before final

A cleanup hard timeout during recording used to defer replacement while Whisper
owned Metal, then resume and await that replacement for up to ten seconds after
STT. The change now:

1. sends the lossless deterministic fallback immediately when cleanup is
   unavailable;
2. resumes model recovery only after the `final` event;
3. reports `cleanup_recovery_pending` and a zero
   `cleanup_recovery_wait_ms` on the engine wire/privacy-safe log;
4. escalates after three recovery warm-ups are interrupted by rapid successive
   dictations, preventing indefinite raw-fallback starvation;
5. retains the existing engine-restart backstop and normal healthy cleanup path.

The explicit recovery fields are engine-wire/log diagnostics only. Swift does
not persist them; history validation intentionally continues to use the derived
residual above. Cleanup TTFT remains available in privacy-safe engine inference
logs, while exact queue/TTFT fields are not yet carried into history.

### Fault-injection result

The old behavior deterministically missed a 50 ms final deadline even when its
production ten-second wait was shortened to 200 ms for the RED test. After the
change:

- the same fake-worker final arrives with `total_ms < 1,000` and zero recovery
  wait;
- a real subprocess worker hard-timeout test finalizes in under one second,
  preserves the complete synthetic transcript, warms a replacement after final,
  and applies cleanup on the next dictation;
- repeated recovery cancellation escalates after three deferrals instead of
  remaining silently unavailable forever;
- healthy streaming and whole-text exact-output guards remain unchanged.

This eliminates the demonstrated 7–10 second recovery barrier. It does not claim
to eliminate Whisper or cleanup inference stalls themselves.

## Measured candidates not changed

The acceptance gate required a repeatable >=10% targeted win or removal of a
multi-second tail. These candidates did not clear it:

| Candidate | Measurement | Decision |
|---|---|---|
| PCM `removeFirst` replacement | one-hour-equivalent median 0.038062 s current vs 0.038529 s offset buffer (1.2% slower) | keep current code |
| Spectrum scratch reuse | 36,000 analyses: 0.046874 s current vs 0.066242 s reused arrays (41.3% slower) | keep current code |
| Socket frame construction | 100,000 6.4 KB frames in 0.026142 s (~0.261 us/frame; ~2.6 us/s at production rate) | no copy refactor |
| Synchronous AX title read | p95: Ghostty 0.049 ms, Chrome 0.073 ms, Slack 0.036 ms, cmux 0.058 ms; cold max 33 ms | below 20 ms gate; no protocol reorder |

A private streaming-on/off live replay was aborted as comparative evidence after
an unrelated local MLX/GPU workload was detected. Its severe timing inflation
matched the noisy 45-run stress baseline, so using it to choose a streaming
policy would have been misleading. Velora was relaunched afterward. No model or
streaming setting was changed in the installed app.

## Privacy and benchmark tooling

Two committed tools make the work reproducible without exporting content:

- `engine/scripts/benchmark_history_performance.py` opens SQLite with URI
  `mode=ro`, never loads transcript bodies into Python, and produces aggregate
  timing/length buckets plus a deterministic private corpus manifest.
- `engine/scripts/benchmark_installed_replay.py` confines relative audio paths
  beneath an explicit root, proves the exact configured model pair plus live
  installed readiness without displacing the app-owned engine socket, hashes
  text in memory, sanitizes errors, and atomically writes owner-only JSON.

## Verification

- Focused recovery/server/process tests: **81 passed**.
- Task 1 + Task 2 benchmark tests: **31 passed**.
- Full engine suite: **635 passed**, 2 third-party deprecation warnings.
- Swift selftest: **1,276 checks passed** (debug and release).
- `make test`: passed Swift, engine, site, Sublime plugin, and signing gates.
- `swift build -c release`: passed.
- `.build/release/Velora --selftest`: passed.
- Independent Codex/Claude review found no issue with the core fallback, then
  identified recovery-starvation/test/telemetry gaps. Those were fixed and a
  final read-only review reported no remaining Critical or Important issues.

## Commits

- `1b35b01` — implementation/validation plan
- `9a8b9ac` — privacy-safe history baseline
- `7311fc6` — fallback before cleanup recovery
- `97ed1fa` — prevent cleanup recovery starvation
- `39a78eb` — installed private-corpus replay baseline
- `712c59f` — report post-format recovery state

## Remaining limitations and next measurement

The optimized checkout has not replaced the installed v0.16.0 app and no
release version was bumped. A clean after-replay must be run when the Mac has no
other MLX/GPU workload, using the same smaller stable corpus. Shipping remains
gated on identical hashes for repeat-stable cases, investigation (not blanket
acceptance) of nondeterministic Whisper cases, and installed-runtime dogfooding.
