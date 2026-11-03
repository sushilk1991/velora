# English-first STT: implementation and verification

This implements the three priority groups from the Woof artifact investigation,
without importing proprietary app integration code. The model loaders under
`engine/src/velora_engine/vendor_bark/` are pinned public Conway Research source
with CC BY 4.0 attribution. Velora's capture, framing, ownership, recovery,
context, formatting, and meeting protocols remain authoritative.

## What shipped in source

| Group | Result | Implementation |
|---|---|---|
| 1 | Language-scope onboarding before acquisition | `OnboardingModel`, `AppDelegate`, `models.recommended_stt_model` |
| 1 | Included compact English source weights | `scripts/prepare-bundled-model.py`, `make-app.sh`, `bundled_models.py` |
| 1 | Local RAM-fitted precision | Bark int4 / int8 / FP16; Parakeet derived caches in `quant_cache.py` |
| 1 | Optional Neural Engine backend | `bark.load_bark_coreml`: stable compiled directory, warm both windows |
| 2 | English native Whisper choices | Base/Small ggml artifacts through the existing transcribe-cpp adapter |
| 2 | Warm/cache before readiness | Both Bark adapters; immutable source/dependency identities and verified derived bytes |
| 2 | Quiet-span segmentation | Bark's bounded pieces; existing Velora pause segmentation retained |
| 2 | Per-model storage and guarded removal | `ModelStorage`, `model_storage.py`, `DownloadCoordinator.remove` |
| 3 | Output ducking | Device-bound CoreAudio lease, respects manual volume changes |
| 3 | Recording recovery | Existing crash-readable PCM spool and History retry preserved; not duplicated |
| 3 | Clean recognition / no-LLM fast path | Bark Clean, optional smart writing at setup, Fast dictation setting |
| Extra | Use existing Whisper files in place | Header-checked ggml/GGUF routing and a Models file picker |

English uses the included Bark source; multilingual uses Whisper Turbo (Q4 below
10 GiB). Existing installs are not automatically switched. Copied portable
settings and custom models on a new Mac are preserved unless the user changes
the language answer. Small-RAM first runs default smart writing off; everyone can
choose it before any writing-model acquisition starts.

The included speech weights do **not** mean zero-network installation: uv still
bootstraps Python/dependencies, and optional writing/multilingual models need
downloads. No model weights are tracked in Git. Packaging fetches and verifies
them into ignored `build/bundled-models` before signing. CC BY license/NOTICE
files ship with the app and imported source.

## Measurements on this machine

2026-11-03, **Apple M5 Max, 36 GiB unified memory**. Earlier conversational
notes called this machine an M4; `sysctl -n machdep.cpu.brand_string` establishes
M5 Max. Audio durations are measured after conversion, not guessed from text:
8.1015 s and 31.7674 s. Samples were synthesized with macOS `say`; these are
runtime smoke tests, **not** a representative accent/noise/accuracy benchmark.
Numbers exclude recording and insertion, and do not include an optional writing
LLM. They must not be advertised as universal speed or accuracy guarantees.

### Bark English precision tiers

Same pinned 163.4 MB packed source, three local derived caches. Three warm
decodes per precision, short sample:

| Precision | First preparation in this run | Derived weights | Warm decode seconds |
|---|---:|---:|---|
| INT4 | 15.98 s (new cache) | 471.90 MB | 0.0677, 0.0646, 0.0637 |
| INT8 | 15.30 s (new cache) | 744.02 MB | 0.0681, 0.0649, 0.0664 |
| FP16 | 0.46 s (existing cache) | 1254.18 MB | 0.0887, 0.0803, 0.0775 |

These are file sizes, not measured total resident memory. Initial unpack runs in
a child so its temporary working set is released; a failed low-RAM build fails
visibly rather than silently substituting a larger precision. Actual 8 GiB
hardware and battery/power measurements remain necessary before making claims
about the minimum-memory or energy benefit. Here INT4 and INT8 retained the same
words; INT4 lowercased the final “Mac”. All Bark variants misrecognized
“benchmark” as “binge a mark” on this sample.

### Optional Clean and Neural Engine paths

Through Velora's `BarkBackend` and `transcribe_clip`, not Woof's workers:

- Bark Clean: new FP16 preparation + warmup 18.06 s; cached load 0.35 s.
  A 31.77-second clip decoded in about 0.29 s after warm load.
- Bark ANE: initial preparation + both window warmups 332.01 s; cached load
  0.71 s. The short clip decoded in 0.098 s and the long clip in 0.31 s.
- Both returned coherent long-audio results through their piece boundaries.
  New regression tests force an empty audible interior piece: neither adapter
  may return an apparently successful transcript missing that piece. The guard
  uses Velora's existing 100 ms / 0.003 RMS energy floor, not a digital-silence
  peak test: real INT4 decoding also passed speech, 75 seconds of −55 dBFS room
  tone, and more speech.
- ANE's first preparation is deliberately allowed a longer bounded backend
  load budget. It is optional, never the automatic first-run choice.

Whisper Base's native backend was separately exercised using `transcribe-cpp`
with the pinned ggml file and returned the intended “benchmark”. This is a
single example, not evidence that Base is generally more accurate.

## Review-driven regression coverage

Independent read-only Codex reviews through yoyo found and drove fixes for:

1. Catalog selectors containing `:` must be mapped at **every** Hub boundary:
   coordinator validation, API metadata, legacy probes/import, and URL creation.
   Shipped SHA-256 pins also remain enforced in persisted owned manifests.
2. A changed language scope must not reuse the old status recommendation.
3. Audio restore must target the original device and respect manual changes.
4. Empty audible interior pieces must fail rather than disappear in stitching.
5. Derived-cache reuse must check recorded hashes, not just sizes.
6. A new machine's onboarding flag must not override imported/custom settings.

Valid older cache identities are retained until explicit engine-coordinated
removal; an automatic rebuild must not prune files another process may hold.

Focused regressions live in `test_english_downloads.py`,
`test_bark_regressions.py`, `test_model_storage.py`, `test_fast_dictation.py`,
`test_stt_language_scope.py`, and the Swift selftest. Backend/importer tests
fake heavy libraries and network transports; the separate real-artifact smokes
above establish actual MLX/CoreML execution on this Mac.

Run the full gate with `make test`. On this host the installed Command Line
Tools lack the SwiftUI macro plugin; use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` without
changing system configuration. Package a signed development app without a
version bump using `./scripts/make-app.sh release none` under the same toolchain.

## Remaining validation boundaries

- No claim of corpus-level WER, accent robustness, battery benefit, or actual
  8 GiB-device success follows from synthetic speech on a 36 GiB Mac.
- Physical output-device routing was not changed during automated tests;
  fake-device tests cover route switching, manual volume changes and restore
  ownership. Unsupported hardware volumes safely skip ducking.
- CoreML is optional and unavailable when the installed Python lacks a supported
  coremltools wheel. MLX remains the default and model-selection failure keeps
  the saved serving model rather than adopting unusable weights.
- This work packages a local signed app for validation. It does not publish a
  new release, notarize a DMG, or bump the shipped version.
