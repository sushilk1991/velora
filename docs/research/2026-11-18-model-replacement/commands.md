# Reproducible commands

Run from the study checkout on this Apple M4 Max. Keep Velora closed and the
ML lane exclusive. The runner itself waits for 30 seconds of stable host
telemetry and each worker also takes `/tmp/velora-bench.lock`.

The measured interpreter is the existing Python 3.12 environment at
`/Users/sushil/Code/Github/velora/engine/.venv/bin/python`; runtime versions are
MLX 0.31.2, MLX-LM 0.31.3 and Transformers 5.3.0. Each run records the command,
source hashes, complete artifact hashes and immutable snapshot revision.

```sh
baton status --json
baton run --lane ml --mem 7G --label velora-model-five-cycle-study -- \
  env PYTHONPATH=engine/src HF_HUB_OFFLINE=1 \
  /Users/sushil/Code/Github/velora/engine/.venv/bin/python \
  engine/scripts/run_model_replacement_study.py \
  --output docs/research/2026-11-18-model-replacement/raw/reproduction
```

The output directory must be new. The final run used `--resume-from docs/research/2026-11-18-model-replacement/raw/repaired-study --rerun-cycles 2,4 --output docs/research/2026-11-18-model-replacement/raw/final-study`. The five-cycle runner uses the exact pinned
paths listed in its source; all cached checkpoints are read-only. If needed,
a missing public checkpoint is downloaded without authentication to the
task-owned temporary model cache. The runner starts fresh worker processes,
uses the same 27 cases and two repeats, and records each early rejection.
Survivors receive A-B-B-A runs. `--resume-from PRIOR_OUTPUT` reuses only valid
quality-rejected screens; failed adapters are rerun, and a fresh baseline is
collected for the resumed study. `--rerun-cycles 2,4` forces repaired adapters to rerun. The fifth cycle tests Compact copy drafts and
allocator bounds if Compact retained quality; otherwise it tests general 2B8.
The screen deliberately cannot authorize production promotion.

The task-owned 2B8 cache was removed after measurement; the full runner reacquires it. For one arm with its snapshot present, copy its exact `command` array from `result.json`, changing only
`--output` to a new directory, and wrap it in `baton run --lane ml --mem 7G --`.
For a full paired comparison:

```sh
PYTHONPATH=engine/src \
  /Users/sushil/Code/Github/velora/engine/.venv/bin/python \
  engine/scripts/compare_model_replacement.py A1 B1 B2 A2
```

Native engine gate (the Apple-dependent paths cannot qualify on Linux):

```sh
cd engine
baton run --lane ml --mem 3G --label velora-model-native-engine-gate -- \
  env PYTHONPATH=src HF_HUB_OFFLINE=1 \
  /Users/sushil/Code/Github/velora/engine/.venv/bin/python -m pytest -q
```

Swift and macOS script gates, from the unchanged base checkout:

```sh
baton run --lane build --mem 3G --label velora-model-mac-gates -- \
  env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  make test-swift test-site test-sublime-plugin test-release-scripts test-update-lifecycle
```

Focused CPU harness checks ran on retained Instabox `build` using the reusable
`.venv-cpu` environment (pytest 9.1.1, pytest-asyncio 1.4.0, numpy 2.4.6,
soundfile 0.14.0, huggingface-hub 1.22.0, constriction 0.5.0):

```sh
boxrun --lane build --mem 2G \
  --exclude 'docs/research/**' --exclude '.orca/**' \
  --exclude 'training/cleanup/data/**' --exclude '.context/**' -- \
  'set -eu; PYTHONPATH="$PWD/engine/src" .venv-cpu/bin/python -m pytest -q engine/tests/test_benchmark_model_replacement.py engine/tests/test_benchmark_cleanup_quality.py engine/tests/test_benchmark_cleanup_resources.py engine/tests/test_benchmark_decisions.py'
```

These native engine and Swift/script targets together cover `make test`.
An earlier broad Linux attempt lacked Apple dependencies/tools and was
interrupted after collecting failures. Its raw logs are retained, never
counted as a successful gate.
