# Progress

## Updater and release notes (2026-11-03)

### Done

- Bare binaries no longer check for app updates. `make run` builds and runs
  the signed app, with its icon, current version, permissions, and updater.
- Packaging re-signs stripped bytes before the metadata probe executes them.
- AGENTS.md, CLAUDE.md, and release guidance require short, user-facing
  changelogs. Rewrote the 0.30.0 and 0.30.1 notes.

### Verified

- Both regressions failed before their fixes: bare-binary update eligibility
  and the invalid signature after stripping.
- `make test`: 3,899 Swift checks, 1,860 engine tests, and all script checks.
- The signed app passes selftest, including the real Install Update action.
  A disposable copy downloads, verifies, and stages the live 0.30.1 DMG.
- Homebrew upgraded `/Applications/Velora.app` to 0.30.1. The old bare
  process quit gracefully; the installed app is running with its engine ready.
- Native Settings reports "This is the latest version." Developer ID,
  Gatekeeper, local agent access, and restart readiness checks pass.

### Next

- Native update/relaunch awaits a newer release. The installed 0.30.1 app
  is current and running; this upgrade used Homebrew.

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

- Both studies pass `make test` and CI on their PRs. #32 passed on its
  third CI run; the first two each timed out in a different test
  (`test_long_dictation.py::test_cancel_wedge_deletes`,
  `test_server_downloads.py::test_cleanup_source_removed[recovery]`).
  Both pass locally; treat them as CI timing flakes to fix.
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
