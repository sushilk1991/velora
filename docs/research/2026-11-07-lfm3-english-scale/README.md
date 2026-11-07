# English-first LFM3 research artifacts

Read [the report](../2026-11-07-lfm3-english-scale.md) for decisions, measurement scope and limits.

The selected English adapter is G6144; naive Q4 is retained. The native candidate is faster and uses less sampled cleanup-process memory than the 4B benchmark, but it misses the owner no-regression condition. App model defaults stay unchanged. The named-example email prompt is replaced in source with a generic rule and a migration for unchanged built-ins. No app release was published.

## Data and frozen selection

- `data-small`: 3,101 reviewed English examples, 2,525 train / 576 dev.
- `data-large`: 7,631 examples, 6,204 train / 1,427 dev. The small corpus is an exact prefix with preserved splits.
- `data-calibration`: 2,000 preservation-calibration training examples and the same 1,427 dev examples. Both F checkpoints failed the repair gate.
- `challenge`: frozen public examples and training exclusions. Never use them for training, calibration activations or checkpoint selection. The historical terminal annotations have an erratum in `terminal-gate-audit.json`: 47 exact bypasses, five Smart Terminal requests. All52 stay outside the primary256 model-level score.
- `checkpoints.json`, `final-selection.json`, `run-protocol.json`: sanitized recipes, counts, source identities and decisions.

The four frozen data directories include complete SHA256 inventories and source ledgers. Counts include linked identity augmentation rather than independent scenarios. Frozen revision2 email instructions retain the existing public example names; original files are preserved after the source prompt moved to revision3. New teacher labels use Muse through YoYo plus independent Terra review. Sotto raw inputs are synthetic public data; no original Sotto target or Qwen4B cleanup output was used as a new teacher label. Source licenses remain per source, not blanket CC0.

## Results

- `fresh-strict.json`, `fresh-quality.json`, `fresh-secondary-audit.json`: untouched written-challenge diagnostics, blind model review and targeted Muse cross-audit.
- `owner-quality.json`, `owner-source-audit.json`, `owner-secondary-audit.json`: all300 supported references and separate305 uncertain-reference source audit; only aggregate results are public.
- `owner-mlx-quality.json`:600 secondary-MLX pairs, comprising525 judgments re-derived from exact already-reviewed outputs and75 new blind output judgments.
- `final-performance.json`: full614/605 coverage and counterbalanced cleanup timings, failures retained; excludes capture, STT and paste from cleanup intervals.
- `accents-short.json`, `owner-asr.json`: acoustic sanity check and owner-corpus ASR diagnostics. Small public clips reach a ceiling; owner references remain fallible and model-assisted.
- `native-export-qualification.json`, `native-cache-regressions.json`: export evidence and the public selected-G header-cache deadline failure. Header cache stays OFF; no numerical-bug root cause was established.
- `quantization.json`, `quantization-selection-rule.json`: train-only importance calibration, coverage/policy checks and dev ties retaining naive Q4.
- `copy-anchor.json`, `experiments/single-anchor.patch`: unselected native prototype. Exact dev and matched parity passed;4.26% gain missed the preregistered5% threshold. No full614 candidate run or source promotion.
- `phonon-matched44.json`: Phonon remains faster on this model-level diagnostic; different prompts, models and warmups.
- `long-notes.json`: failed structured summaries and prompt probes; separately verified full-request batch comparison.
- `email-prompt-study.json`, `email-cohort-counterfactual.json`: development prompt study and a post-hoc51-email diagnostic separating example-name leakage from model training. No205-case extrapolation.
- [Inference findings and remaining gaps](inference-next.md).

The preparation/training entrypoints are in `training/cleanup`; see its README. Reproduce the original source-bound benchmarks from commit09e870d, retaining pinned model/port/runtime revisions and all heldout guards. Re-running a known test after tuning on it does not create a new untouched estimate.

The owner-local kit is under `~/.velora/benchmarks/lfm3-english-scale-20261107/artifacts/lfm3-english-g-20261107/`. It contains the selected adapter, Q4 artifact, measured worker, licenses and lineage, marked `quality_qualified:false`. Original exports remain separately required for full lineage checks. Weights, owner recordings, private references and per-case outputs are not included in this repository or bundled with the app. File size does not establish RAM requirements.
