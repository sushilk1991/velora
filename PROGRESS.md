# Progress

## Cleanup latency and model studies (2026-10-29/30)

### Done

- Latency study (#32): no speed lever passes; keep MLX, the shipped models
  and mlx 0.31.2. Report: `docs/research/2026-10-29-cleanup-latency-roofline.md`.
  Opt-in tracing: `VELORA_TRACE_CLEANUP=1` logs numeric engine spans; the
  app emits `StopToFinal` signposts (subsystem `com.velora`, category
  `Latency`). Neither logs transcript text.
- Model study: keep Qwen3.5-4B-MLX-8bit for cleanup and Action Mode, and
  Qwen3.5-2B-MLX-4bit for the Compact tier. 14 existing alternatives and a
  public-only LoRA fail the frozen bar on owner gold and EdAcc accents.
  Report: `docs/research/2026-10-29-cleanup-model-decision.md`.

### Verified

- Both studies pass `make test` and CI on their PRs.
- No owner transcript text is in either report or its data files.

### Next

- A list-bypass content guard (fall back to the gate text when cleanup
  drops an aligned content word) passed offline: 4B harms 91→83/303 on
  owner takes and 164→86/593 on EdAcc, term fixes unchanged. The owner
  deferred building it on 2026-10-30. Do not build it unprompted. Before
  any dogfood it needs native latency/RAM checks.
- Correction capture observes 1.2% of takes. Fix its coverage before using
  edit rate as a dogfood metric.
- Unverified: native mic-to-insertion latency under low load, 8 GB Mac
  tiers, broad accent coverage (Common Voice access is gated).
