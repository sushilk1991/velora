# Public cleanup student pipeline

This directory is isolated from the engine environment. From the repository root, run `uv sync --project training/cleanup --extra train --extra acquire --extra test --locked`. Never install into `engine/.venv`. No personal dictation or private examples belong in a shared training set. Only public rows with source revision, license and approved review can train. The first reproducible, model-reviewed corpus is in [data/pilot_v1](data/pilot_v1/README.md).

The latest [pilot v3](data/pilot_v3/README.md) contains 1,605 reviewed public/synthetic examples. Two 2B adapters were trained and checked on fresh public tests and saved owner recordings; neither passed the replacement gate. See the [complete results and limitations](../../docs/research/2026-11-06-cleanup-push-v3.md). Personal recordings remain evaluation-only and outside Git.

JSONL records contain `id`, `raw`, `target`, `mode` (default/message/email/note/code/terminal), `language`, `scenario_group`, `split` (train/dev), `source` object (`name`, `revision`, `license`), `teacher` object (`name`, `revision`), `visibility` (`public`), and `quality_review` object (`status`, `reviewer`). Optional `romanize` is boolean, `instructions` is a string, and `vocabulary` is a list of strings. Generated labels may be inspected and split, but training requires status `approved`. See TEACHER.md for the task and review rubric. Record whether the reviewer is a model or a person.

Run from this directory:

```
python -m cleanup split --data candidates.jsonl --holdout frozen-holdout.jsonl --ledger ledger.json --out split.jsonl
python -m cleanup validate --data split.jsonl --holdout frozen-holdout.jsonl --ledger ledger.json
python -m cleanup train --data split.jsonl --holdout frozen-holdout.jsonl --ledger ledger.json --base /path/to/snapshots/COMMIT --base-revision COMMIT --out /new/adapter
python -m cleanup generate-eval --data frozen-holdout.jsonl --base /path/to/snapshots/COMMIT --base-revision COMMIT --adapter /new/adapter --out predictions.jsonl
```

Supply an external holdout, keep it frozen before training, and hide it from data teachers. Include any benchmark template strings in its `template` field. Validation rejects exact and eight-word overlaps with holdout raw, target, and templates, duplicates, and cross-split scenario groups. These checks are conservative, cannot prove absence of paraphrased contamination, and do not replace provenance review. Split is stable by seeded group hash; review flagged meaning changes before approval. Training fails on oversized sequences instead of silently truncating, uses answer-only loss including EOS, and writes configuration, input hashes, versions and result metadata. Base revision must identify immutable model weights; preserve the holdout and manifest alongside results. Evaluation writes predictions only; judge separately against the frozen holdout.

The source ledger is a JSON object such as `{"allowed_licenses":["CC0-1.0"],"sources":{"synthetic-v1":{"kind":"synthetic","revision":"1","license":"CC0-1.0"}}}`. Every row's source must match the ledger; allowed kinds are `public` and `synthetic`. JSON `null` is rejected. This is an explicit provenance assertion and does not replace human source review. The holdout requires unique `id` values.

Use the complete 40-character Hugging Face commit as the base revision. A local base must be the corresponding `snapshots/<commit>` directory; a repository ID is downloaded at that exact revision. Snapshot config, tokenizer and weights are hashed. The runner seeds MLX and NumPy, sorts examples by ID, and reports overlength examples before training; `--skip-overlength` explicitly permits excluding them. Evaluation is greedy, has a bounded output limit, and writes timing, memory and provenance to `<out>.meta.json`.

Tokenizer loading is local-only and disables remote code separately from the model architecture loader. Adapter loads require the complete expected LoRA tensor keys and shapes. Checkpoint scoring requires the exact snapshot file set recorded during training; adding a tokenizer template is a mismatch too. Generation metadata distinguishes EOS from a length ceiling. Treat partial output as a failure, and judge meaning independently of loss or runtime.

The trainer records device information and runs a one-example loss and gradient finiteness preflight before training. Reported train and validation losses must remain finite. `--gated-delta-source PATH` is an optional, version-checked compatibility hook for a supported Qwen3.5 training experiment; omit it for standard models. Its provenance is written to the manifest. This diagnostic does not replace a full quality evaluation.

## Acquire and curate reviewed public data

Install the isolated acquisition extra (`uv pip install --python .venv/bin/python -e '.[acquire]'`). Acquire the pinned MIT-licensed Sotto snapshot, exporting its raw `input` column only; the acquisition manifest records snapshot file and export hashes. The original Sotto target column is never exported as a teacher label. The export contains unreviewed candidate inputs and cannot be fed directly to training.

```
python -m cleanup acquire-sotto --out sotto-raw.jsonl
# Create teacher labels and independently review them using TEACHER.md.
python -m cleanup curate --input reviewed-synthetic.jsonl --input reviewed-sotto.jsonl \
  --sotto-raw sotto-raw.jsonl --holdout exclusion-holdout.jsonl --ledger ledger.json \
  --out curated.jsonl --report curation-report.json
python -m cleanup validate --data curated.jsonl --holdout exclusion-holdout.jsonl --ledger ledger.json
```

The `--input` order establishes precedence when normalized content repeats. The curation command checks every source against the ledger, verifies Sotto raw text occurs in the acquired export, excludes unapproved, duplicate and holdout-overlapping rows, and unions scenario groups and shared eight-word sequences transitively before the seeded split. It records input hashes, exclusions and split counts. The exclusion holdout must include both the frozen external holdout and any legacy benchmark examples or templates; use unique IDs. Acquisition and curation do not generate labels or grant approval. The raw export and ledger are local assertions, so retain their acquisition manifest and independently verify their provenance. To reproduce a prior dataset, use the same ordered reviewed inputs, exclusion holdout, ledger, seed and development percentage; row counts depend on those exact inputs.

Training masks loss to answer tokens and EOS, excluding padding. `--lora-scale` defaults to 20, `--clip-grad-norm` to 1, and `--warmup-updates` to 0; `--lr-schedule cosine` enables decay after warmup, measured in optimizer updates rather than examples. The iteration count must be divisible by gradient accumulation. To select a checkpoint without using frozen test outcomes, score every checkpoint on the full dev split with one base-model load:

```
python -m cleanup score-checkpoints --data curated.jsonl --holdout exclusion-holdout.jsonl --ledger ledger.json \
  --base /path/to/snapshots/COMMIT --base-revision COMMIT --adapter /path/to/adapter \
  --checkpoint /path/to/adapter/0000100_adapters.safetensors \
  --checkpoint /path/to/adapter/0000200_adapters.safetensors --max-seq 1024 --out selection.json
```

The holdout serves only as a contamination guard. The report records each checkpoint hash and dev loss and chooses the minimum; use the frozen test only after selection. Checkpoint keys must match the adapter in `--adapter`.

## Experimental cached student decoding

`scripts/benchmark_student_decoder.py` compares uncached streaming with the
isolated `StudentEngine` wrapper around Velora's cache/decoding code. Inputs
must explicitly declare public visibility. Qualification requires 64 unique
case IDs, EOS on every case, exact prompt/output token IDs and guarded results,
plus the bounded-context recovery probe. This checks decoder parity, not
semantic model quality. Private cached-decoder replays require the resulting
report to match the exact current source, model, adapter and package versions.

Copy drafts follow production routing: romanization and other transformations
with `check_ratio=False` use scalar generation. The public runner requests
copying only for non-romanization cases, and `StudentEngine` independently
enforces the same restriction. Earlier diagnostic trials that forced copying
on romanization do not qualify this routing and retain their original hashes.

The experimental MLX-LM 0.32.2 cache bridge restores the complete state tuple,
including KV offsets and recurrent padding/lengths. It patches only an
isolated process for one serial model lifetime; the installed engine and its
dependencies remain unchanged. An unhealthy model thread causes the replay
process to exit before its architecture/cache contexts are released.

Stream and engine trials have different timeout policies: the simple stream
wrapper's cooperative budget includes prefill, while the engine's soft budget
starts at first output and has a separate worker watchdog. Both policies are
recorded in replay metadata. Differences in timeout/fallback counts therefore
need separate analysis; they do not establish a model-quality change. Private
replay statuses distinguish partial piece cleanup from complete fallback and
use the server's final result after any successful seam retry. Failed attempts
remain visible in the per-call records.

All student evaluation decoders explicitly set the MLX allocator cache cap to
512 MiB before loading a model. The cap is part of public/private provenance
and qualification checks; training is unaffected. Stream results sample actual
MLX active, peak and cached allocation instead of reporting default zeros.
Public and private case records also sample allocation after each case timer.
CPU tests use injected metric providers or explicitly unavailable model-less
snapshots and never import MLX for resource sampling.

Private incumbent and student replays write a separate owner-only resource
artifact at the end, while their model is still resident. It retains only
`vmmap -summary` physical-footprint lines, peak process RSS and MLX allocation
metrics; raw mapping inventories are discarded. Sampling runs outside case
timers. Peak allocation/RSS are process-lifetime observations, and allocator
usage, process RSS and physical footprint are distinct measurements, not
interchangeable estimates of a model's RAM requirement. Unhealthy processes
skip further MLX/resource probes and retire through the existing failure path.

## Reproduce the LFM3 A/B/C research recipes

Use [scripts/run_lfm3.py](scripts/run_lfm3.py) for LFM3 `train` and
`generate-eval`. The pinned environment cannot load this architecture through
bare `python -m cleanup`: the wrapper registers the audited port for the whole
operation, then removes that registration. It accepts only the audited local
`snapshots/4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099` base with `model_type=lfm3`.
It never downloads a base. `train --help` and `generate-eval --help` forward to
the underlying CLI without loading a model or writing provenance.

This is a new portable counterpart to the historical ignored operator wrapper,
not the script that produced the reported checkpoints. Historical
`architecture.json` files retain that operator wrapper's actual SHA. New runs
write their own wrapper/port hashes and invocation to
`<out>.lfm3-architecture.json`, and successful training copies that record into
`<out>/architecture.json`. Existing outputs, sidecars and evaluation metadata
are rejected. A failed attempt retains its sidecar; choose a fresh output for
a retry. The 512 MiB MLX allocator cache cap applies to evaluation only; the
wrapper does not change training allocation, mathematics, or the port.

Run from the repository root, using the isolated locked training environment
and an already cached `LiquidAI/LFM3-1.7B-MLX-8bit` snapshot:

```sh
PY=training/cleanup/.venv/bin/python
REV=4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099
BASE="$HOME/.cache/huggingface/hub/models--LiquidAI--LFM3-1.7B-MLX-8bit/snapshots/$REV"
RUN=/absolute/path/to/new-lfm3-run
mkdir -p "$RUN"

train_lfm3() {
  "$PY" training/cleanup/scripts/run_lfm3.py train \
    --base "$BASE" --base-revision "$REV" \
    --rank 16 --lora-scale 8 --grad-accum 4 --warmup-updates 20 \
    --lr-schedule cosine --clip-grad-norm 1 --seed 42 \
    --val-batches -1 --report-every 100 "$@"
}
train_lfm3 --data training/cleanup/data/pilot_v4/baseline_reviewed.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v4.jsonl \
  --ledger training/cleanup/data/pilot_v4/sources.json \
  --iters 2488 --lr 1e-5 --max-seq 1536 --eval-every 624 --save-every 624 --out "$RUN/a"
train_lfm3 --data training/cleanup/data/pilot_v4/reviewed.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v4.jsonl \
  --ledger training/cleanup/data/pilot_v4/sources.json \
  --iters 2952 --lr 1e-5 --max-seq 1536 --eval-every 740 --save-every 740 --out "$RUN/b"
```

A and B use the same 362-row development set. Select the minimum **full-dev**
validation loss from each run's `metrics.jsonl`, then preserve that saved
checkpoint as `adapters.safetensors` in a fresh selected directory alongside its
`adapter_config.json`, `manifest.json`, and `architecture.json`. Record the
checkpoint SHA, eligible losses and selection rule in `selection.json`. The
historical selected sample counts were A=1,872 and B=1,480; reruns must select
from their own dev results rather than hardcoding those outcomes. Checkpoint
filename counts are one greater than the zero-based callback iteration.

C continues the selected B adapter using [pilot_v5](data/pilot_v5/README.md):
2,216 reviewed rows, including 1,799 train and 417 dev. All original 362 dev rows
remain unchanged; the expanded dev set adds 55 rows.

```sh
train_lfm3 --data training/cleanup/data/pilot_v5/reviewed.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v5.jsonl \
  --ledger training/cleanup/data/pilot_v5/sources.json \
  --adapter "$RUN/b-selected" --iters 3600 --lr 3e-6 --max-seq 2048 \
  --eval-every 900 --save-every 900 --out "$RUN/c"
```

C selection includes the initial B checkpoint's loss on **all 417 dev rows**
at iteration zero, alongside every saved C candidate. If initial B has the
lowest loss, retain B; selection must not force a new checkpoint. A/B losses on
362 rows and C losses on 417 rows are different comparisons. Freeze final test
inputs before training, and never use their outputs or owner recordings to
choose a checkpoint. The historical C minimum was 0.144486 versus initial B's
0.158287 on the same expanded dev set. Lower dev loss did not qualify a default
model change: additional meaning regressions remained in private evaluation.

After selection, generate fresh public challenge predictions separately:

```sh
"$PY" training/cleanup/scripts/run_lfm3.py generate-eval \
  --data training/cleanup/evaluation/qualification_v5.jsonl \
  --base "$BASE" --base-revision "$REV" --adapter "$RUN/c-selected" \
  --max-tokens 1024 --out "$RUN/c-v5-predictions.jsonl"

# Explicit original-adapter qualification with complete token/status records.
"$PY" training/cleanup/scripts/qualify_lfm3_artifacts.py run \
  --data training/cleanup/evaluation/qualification_v5.jsonl \
  --base "$BASE" --base-revision "$REV" --adapter "$RUN/c-selected" \
  --max-output 1024 --output "$RUN/c-original.json" \
  --native-reference "$RUN/c-native-prompts.json"
```

Judge generated meaning separately from EOS/runtime qualification. Export,
fusion, GGUF quantization and native execution each require their own exact
prompt/output and recovery checks; fusion or quantization can change outputs.
[scripts/export_lfm3_native.py](scripts/export_lfm3_native.py) defaults to
CPU-only inspection, while `--execute` explicitly performs export.
[scripts/qualify_lfm3_artifacts.py](scripts/qualify_lfm3_artifacts.py) also accepts
`--fused PATH --export-provenance PATH/export-provenance.json` for a separate
fused run, then `compare --left ... --right ... --output ...` reports parity.
These are research commands; they do not activate an application model.
