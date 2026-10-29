# Cleanup latency investigation — 2026-10-29

## Done

- Branch `perf/cleanup-latency-roofline-20261029`; main unchanged at
  `79de9dba6d245f71758af2859df60f047da62dc7`.
- Evaluated six levers in isolated scratch environments. No new worktrees.
- Added opt-in numeric spans, Swift signposts and read-only replay/copy probes.
- Wrote the research report, portable review and sanitized numeric evidence.
- No speed lever passes; keep MLX and the shipped models.

## Verified

- Copy bandwidth 277.4 GB/s; 556 replay records retain load and hashes.
- Primed worker Metal trace: 94 ms extra after idle, inside prefill/wait.
  Historical 963 ms TTFT remains partly unattributed.
- 4-bit cleanup stays 1/27 failures; decisions fall 56/62 to 55/62.
  Prepared-prefix llama.cpp is 130% slower. No production model/dependency change.
- Final `make test`: 3,751 Swift checks, 1,774 pytest tests, site/signing/release
  checks all pass. Traced versus original greedy/final bytes match on 32 replays.
- `/Applications/Velora.app` restarted. Control API confirms app running,
  engine ready and access enabled. Benchmark workers/servers stopped.

## Next

Review the research PR. Do not push main or merge.

Native microphone-to-insertion tracing, privileged idle-watt measurement,
instrumentation-overhead isolation, and multi-day engine.log confirmation
remain unverified. Detailed Python tracing defaults off. The installed CLI
symlink misdispatches; its accidentally started extra instance was stopped.
That separate CLI issue was not changed.

Scratch: `/tmp/velora-latency-20261029`. No owner transcript text in the repo.
