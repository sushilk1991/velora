# Current-Model Whole-Flow Performance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Measure and improve Velora’s complete dictation flow using the existing Whisper Large v3 Turbo and Qwen3.5 4B 8-bit models, with real local history/audio and no model or output-quality change.

**Architecture:** Establish privacy-preserving baselines from the read-only history database, engine logs, controlled real-audio replay, and Swift microbenchmarks. Optimize only bottlenecks that reproduce and pass explicit latency, output-equivalence, ordering, and full-suite gates. Keep raw fallback and “never lose words” behavior unchanged.

**Tech Stack:** Swift 6/AppKit/AVFoundation/Accelerate, Python 3.12+/asyncio/MLX, AF_UNIX framed PCM protocol, SQLite read-only analytics, Swift selftests, pytest.

---

## Non-negotiable constraints

- Keep `mlx-community/Qwen3.5-4B-MLX-8bit` unchanged.
- Keep `mlx-community/whisper-large-v3-turbo` unchanged.
- Do not upload audio or transcript text; all analysis is local.
- Benchmark reports contain aggregate timing/length metadata, not transcript bodies.
- Do not change cleanup prompts, generation parameters, or formatting decisions.
- Do not drop microphone audio in the Swift client. Control/audio ordering remains lossless.
- Do not mutate history rows during corpus evaluation.

## Acceptance gates

- Exact PCM bytes/chunk order remain identical in buffering and IPC tests.
- Existing 602 engine tests and 1,276 Swift checks remain green.
- Real-audio replay text is byte-identical before/after for the selected corpus, except an explicitly documented nondeterministic STT result is investigated rather than accepted.
- A performance change ships only with repeatable improvement: at least 10% in its targeted microbenchmark or elimination of a demonstrated multi-second tail, with no p50/p95 regression in controlled replay.
- Release packaging is not run until the optimized development build passes installed-runtime dogfooding.

### Task 1: Create a privacy-preserving history performance report

**Files:**
- Create: `engine/scripts/benchmark_history_performance.py`
- Create: `engine/tests/test_benchmark_history_performance.py`
- Modify: `docs/TESTING.md`

**Steps:**
1. Write failing pytest coverage for read-only SQLite URI use, quantiles, duration buckets, recovery-wait derivation, missing legacy metrics, deterministic stratified corpus selection, and transcript redaction.
2. Run the focused test and verify RED.
3. Implement the minimal report tool. It accepts explicit `--db`, `--audio-root`, `--json`, and `--select-corpus` paths; it never prints raw/final text or writes the database.
4. Run focused tests and verify GREEN.
5. Run it against `~/.velora/history.sqlite3` and save only aggregate JSON under `/tmp`.
6. Document the local command and privacy behavior.
7. Commit.

### Task 2: Establish controlled real-audio and runtime baselines

**Files:**
- Create: `engine/scripts/benchmark_installed_replay.py`
- Create: `engine/tests/test_benchmark_installed_replay.py`
- Modify: `docs/TESTING.md`

**Steps:**
1. Write failing tests for corpus-manifest validation, subprocess timeout/error handling, output hashing/redaction, repeat aggregation, and refusal to run if the installed engine is not the required model pair.
2. Verify RED.
3. Implement a local runner over the installed CLI `transcribe FILE --mode NAME --json`; retain output only as an in-memory SHA-256 and timing/length metadata.
4. Verify GREEN.
5. Select a deterministic corpus across duration buckets and modes from Task 1.
6. Run warm controlled repeats with no active dictation and record wall/STT/cleanup p50/p95 plus output hashes.
7. Capture current app/engine footprint and idle CPU samples.
8. Commit the reusable runner, tests, and documentation; do not commit private manifests/results.

### Task 3: Benchmark and optimize Swift PCM accumulation

**Files:**
- Modify: `Sources/Velora/Capture/AudioCapture.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Steps:**
1. Add a failing selftest for a testable PCM accumulator: arbitrary input segmentation must emit identical 1,600-frame chunks and exact tail bytes without `removeFirst`-style shifting.
2. Verify RED through `.build/debug/Velora --selftest`.
3. Add a baseline opt-in benchmark that feeds at least one hour of irregular buffers and records elapsed time without printing audio.
4. Implement a bounded-head/read-offset accumulator with periodic compaction, preserving exact bytes and tail flushing.
5. Verify GREEN and compare repeated release microbenchmarks.
6. Keep only the implementation if it clears the 10% gate and Instruments/sample evidence shows allocation reduction; otherwise revert it while retaining useful benchmark coverage.
7. Commit.

### Task 4: Benchmark and optimize spectrum scratch allocation

**Files:**
- Modify: `Sources/Velora/Capture/SpectrumAnalyzer.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Steps:**
1. Add a failing equivalence test covering silence, tones, short zero-padded input, and irregular windows against fixed expected band tolerances.
2. Verify RED for the new reusable-scratch API/diagnostics.
3. Add a release microbenchmark for repeated 1,024-frame analysis.
4. Reuse input/real/imag/magnitude scratch arrays inside the serial analyzer while continuing to return a caller-owned band array.
5. Verify exact/tolerance equivalence and measure repeated release runs.
6. Keep only if it clears the performance/allocation gate; otherwise revert.
7. Commit.

### Task 5: Measure socket framing/backlog before changing it

**Files:**
- Modify: `Sources/Velora/EngineClient/EngineClient.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Steps:**
1. Add a loopback-socket benchmark/test seam that validates exact framed bytes and start → audio → stop ordering under partial writes.
2. Verify RED.
3. Measure the existing allocation/copy cost and queue delay at 10x and 100x production traffic.
4. If framing is material, implement a reusable header plus scatter/gather partial-write loop or another proven lower-copy design; do not add audio dropping.
5. Add bounded backlog telemetry/fail-closed behavior only if a stalled-reader reproduction proves growth; preserve all audio and surface the failure rather than silently dropping words.
6. Verify GREEN and retain only measured wins.
7. Commit.

### Task 6: Bound cleanup-recovery impact on foreground finalization

**Files:**
- Modify: `engine/src/velora_engine/server.py`
- Modify: `engine/src/velora_engine/cleanup_process.py` only if required by the reproduced cause
- Modify: `engine/tests/test_server.py`
- Modify: `engine/tests/test_cleanup_process.py`

**Steps:**
1. Build a deterministic test where a chunk cleanup hard-times out, replacement warm-up is deferred during dictation, and final STT completes while recovery is still unavailable.
2. Assert the current multi-second recovery wait and verify RED against the desired bounded fallback contract.
3. Use history/log evidence to choose the smallest bound consistent with the product target; do not alter normal loaded-worker cleanup.
4. Implement immediate or tightly bounded raw fallback when recovery cannot become ready within that budget, then recover only after the user-facing final is sent.
5. Verify normal cleanup remains byte-identical and the failure case no longer blocks finalization.
6. Add phase timings for recovery wait, STT, cleanup queue, TTFT, and total without transcript content.
7. Run engine tests and controlled fault-injection benchmarks.
8. Commit.

### Task 7: Measure hotkey-to-first-audio and Accessibility context cost

**Files:**
- Modify: `Sources/Velora/App/DictationController.swift`
- Modify: `Sources/Velora/Context/ScreenContext.swift` only if evidence requires it
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Steps:**
1. Add privacy-safe signposts/timings for hotkey accepted, minimal context completed, capture start requested, first PCM, and engine start command.
2. Benchmark TextEdit, Ghostty, Chrome, Slack/another Electron target, and a deliberately unavailable AX target.
3. If minimal context exceeds 20 ms p95 or produces material outliers, add a context-update protocol/test so capture and engine start can happen from cached app metadata while AX entities arrive during recording.
4. Preserve prompt-prefix preparation and stop-attached rich context; do not simply remove context and regress names.
5. Verify ordering, cancellation, stale-generation rejection, and real-app dogfooding.
6. Commit only if the gate is met.

### Task 8: Full regression, after/before replay, and adversarial review

**Files:**
- Modify: `docs/research/2026-08-06-current-model-performance-validation.md`

**Steps:**
1. Run `make test`.
2. Run `swift build -c release` and `.build/release/Velora --selftest`.
3. Run focused performance tests repeatedly on an otherwise idle machine.
4. Run the same private audio manifest from Task 2 and compare output hashes and p50/p95 phase timing.
5. Run fault injection for socket stalls, cleanup recovery, cancellation, engine restart, and long audio.
6. Audit the diff with independent reviewers; fix confirmed Critical/Important findings test-first.
7. Write the validation report with exact commands, device conditions, before/after measurements, kept/reverted experiments, and limitations. Do not include private text/audio paths.
8. Only after approval, package/install using the required patch version bump; do not reuse 0.16.0.
