# Frozen replacement protocol

Base: fb700ce (main at study start). Branch: study/smaller-model-2026-11-18.
Target: Apple M4 Max, 36 GiB unified memory. Scope: shared cleanup LLM;
Whisper STT remains a separate model and is not being replaced.

Frozen before any inference on this study:
- Fewer actual decoded language-model parameters AND fewer complete model-artifact bytes.
- P95 cleanup wall latency <= 75% of baseline; P50 and P99 strictly lower.
- Peak worker RSS AND physical footprint <= 80% of baseline; MLX peak reported
  separately, never added to unified memory. Include startup memory and sustained
  fixture passes. No OOM, worker failures, swapout increase, swap-used growth,
  pressure warning, or load1 >=20 anywhere in a qualifying round.
- Quality: no new failures on any existing public cleanup predicate and no
  decrease in passing cases; no lost correct Action decision or aggregate/category
  score decrease. Side-by-side outputs on all 27 public edge cases, with qualitative
  review of all changed outputs. These finite checks cannot prove universal quality.
- All existing repository tests must pass before any production replacement.
- Up to five candidate/refinement cycles. Fresh isolated worker per run,
  immutable model snapshots, greedy production prompting/guards/postprocessing,
  equal raw inputs and runtime. Production baseline retains its copy-draft and
  allocator policies. Compare paired A-B-B-A rounds, two measured repeats per
  fixture per worker. Report every raw request, including errors/timeouts; no
  percentile-of-medians or success-only denominators. Initial single-arm quality
  screening may reject a candidate early; only complete A-B-B-A evidence can
  establish a performance gate. Model warmup/load measured
  separately; first measured request retained.
- GPU serialized with Baton and /tmp/velora-bench.lock. No live app socket,
  config writes, app restarts, personal history/audio/dictionary reads, training,
  or access to owner transcript text. Model cache reads only; any new artifacts
  go to task-owned scratch, not ~/.velora or existing model metadata.

Linux-compatible tests run on retained Instabox build; Apple/MLX/Swift checks
run locally. Host is shared: initial 15 GiB swap used makes controlled memory
proof uncertain. Contaminated rounds remain diagnostic and cannot pass gates.

User steering: after this protocol was frozen, the user explicitly requested
stopping Velora to free RAM. App and all four descendant processes exited on
SIGTERM; proof is in raw/stop-velora.json. The app remains stopped. Gates and
workload are unchanged.
