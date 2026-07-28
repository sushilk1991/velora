# Local STT and cleanup model evaluation — 2026-07-28

## Decision

Keep `mlx-community/Qwen3.5-4B-MLX-8bit` as the quality-tier default. The
same-parent 4-bit build is materially faster and smaller, but it missed one
existing structural-cleanup requirement, so it is not a safe default yet.
Smaller off-the-shelf candidates failed more requirements.

All measurements below ran locally on the M4 Max 36 GB development Mac. They
are model-selection evidence for this machine, not a universal Apple Silicon
claim.

Human review remains part of the gate. An initial automated pass accepted
`Maine` for source `मुझे`; that changes the pronoun/case rather than merely its
script. The Romanization prompt and fixture now require direct word-by-word
transliteration (`Mujhe`, never `Maine`), and the exact production model passed
both Hindi Romanization cases after that correction.

| Cleanup model | Failed cases | p50 wall | p95 wall | MLX active after suite | Physical footprint |
|---|---:|---:|---:|---:|---:|
| Qwen3.5 4B 8-bit (baseline) | 0 / 26 | 753 ms | 1,157 ms | 4.73 GB | 5.64 GB |
| Qwen3.5 4B 4-bit | 1 / 26 | 587 ms | 838 ms | 2.63 GB | 3.59 GB |
| Qwen3.5 2B 4-bit | 9 / 26 | 297 ms | 414 ms | 1.16 GB | 1.97 GB |
| Qwen3 4B Instruct 4-bit | 12 / 26 | 528 ms | 881 ms | 2.97 GB | 4.10 GB |

The Qwen3.5 4B 4-bit candidate improved p50 by 22.0%, p95 by 27.6%, and active
MLX memory by 44.4%. It failed the mismatched-ordinal case: the speaker said
three items but mislabeled the last item as fourth; the baseline correctly
produced a sequential three-item list, while the candidate left the speech as
prose. That single semantic-structure miss disqualifies it under the
zero-regression gate.

A focused Qwen3.5 0.8B 4-bit probe was much faster (about 220 ms total with
roughly 499 MB active MLX memory) but failed basic subject-verb agreement. It
does not merit a full default-model bakeoff unless it is task-fine-tuned.

## What the runner now measures

`engine/scripts/benchmark_cleanup_quality.py` accepts repeated `--model`
arguments and runs each model in a fresh child process. It reports:

- every deterministic quality failure, including app mode prompts and
  Romanization;
- p50 and p95 cleanup wall time and time to first token;
- MLX active, peak, and cache bytes from inside the model-owning worker;
- macOS current and peak physical footprint from `/usr/bin/footprint`;
- a candidate verdict requiring zero absolute quality failures, at least 10%
  p50 and p95 speedup, and at least 10% active-memory reduction.

Do not use `ps` RSS as the model-memory gate. MLX and Metal allocations can
move while RSS falls. MLX allocator counters are the deterministic per-model
measure; macOS physical footprint is the process-level cross-check.

The current measurements are memory-capacity proxies, not a direct memory
bandwidth counter. Contended end-to-end latency is the practical product-level
signal for bandwidth pressure. A direct bandwidth investigation should use a
separate Instruments/Metal capture and must not be substituted with RSS.

Run the quality-tier comparison:

```sh
cd engine
uv run python scripts/benchmark_cleanup_quality.py \
  --model mlx-community/Qwen3.5-4B-MLX-8bit \
  --model mlx-community/Qwen3.5-4B-MLX-4bit \
  --repeats 5
```

The one-repeat numbers above are useful screening results. A release decision
requires at least five repeats on an otherwise idle machine and the contended
end-to-end pass described below.

## Three evaluation layers

### 1. STT-only

Use `engine/scripts/benchmark_stt_backends.py` with a private local manifest.
The strict suite requires at least 18 clips spanning Indian English, Hindi,
Hinglish, silence/noise, and one dictation of at least 45 seconds.

For each cohort, gate on:

- WER and CER, using worst-of-repeat quality rather than the best decode;
- glossary recall and no glossary hallucination on silence/noise;
- no new empty-output, repeated-tail, or stitch failures;
- live ingestion RTF at or below 0.9;
- p50 and p95 stop-side latency;
- exact model revision and artifact hash.

WER alone is insufficient for Devanagari and Romanized Hinglish, so the runner
now also emits normalized character error rate and rejects a cohort-level CER
regression.

The runner accepts `--baseline-model` and `--candidate-model`; both IDs must be
registered Velora models. This makes the already-listed Hindi Apex checkpoint
testable without changing the script:

```sh
cd engine
uv run python scripts/benchmark_stt_backends.py /path/to/private-manifest.json \
  --baseline-model mlx-community/whisper-large-v3-turbo \
  --candidate-model knownsense/whisper-hindi-apex-mlx \
  --repeats 5
```

No STT replacement is cleared yet because a gold owner-speech manifest does
not exist. Machine transcripts in history are inputs for review, not ground
truth. The research order is:

1. Same Whisper Turbo at Q6_K and Q5_K_M through transcribe.cpp. These retain
   initial-prompt glossary biasing and segment metadata while reducing model
   bytes.
2. `knownsense/whisper-hindi-apex-mlx`, already in the registry, against the
   default on Hindi/Hinglish and Indian-English cohorts.
3. Full Whisper Large v3 lower quants if Turbo is confirmed as the Hindi
   accuracy ceiling.

Qwen3-ASR 0.6B is research-only for now. Its transcribe.cpp route was locally
confirmed to omit `initial_prompt`, timestamps, and long-form segmentation,
which removes Velora's glossary and segment-guard contracts. The separate MLX
implementation exposes context biasing and streaming, but it adds a dependency
and its published Hindi result is among its weakest language results. It needs
corpus evidence before adapter work.

### 2. Cleanup-only

The cleanup suite must cover punctuation, grammar, questions, names and
numbers, self-corrections, lists and counterexamples, multilingual input,
custom mode prompts, Terminal safety, and Romanization. A candidate fails on
one invented, omitted, translated, or structurally lost content slot.

Free-form mode instructions are composed only for model-backed dictation
routes. Formatting Off and command-shaped Terminal text remain model-free.
Romanization receives mode formatting preferences with transliteration
precedence; it deliberately does not promote its unrelated prefix into the
normal cleanup cache.

### 3. Saved-audio end to end

Model adoption is not complete after isolated wins. Replay the same saved audio
through the production engine and measure:

- STT finalization, cleanup wall time, and stop-to-final p50/p95;
- prompt-cache hit and prefix-token counts;
- concurrent Whisper/cleanup behavior, because both contend for unified memory
  and Metal even though cleanup runs in a separate process;
- final transcript WER/CER, hard-field preservation, and cleanup assertions;
- combined MLX active/peak memory and each process's physical footprint.

The release gate should retain the product target of less than 1.5 seconds
stop-to-final for utterances up to 15 seconds, while also requiring no
regression relative to the currently shipped model on the private corpus.
Report cold process/model load separately from warm stop-side latency.

## Human review and release gate

Automated assertions are necessary but do not catch every meaning-preserving
failure. For candidates that pass all hard gates:

1. Produce blinded baseline/candidate pairs from the saved-audio corpus.
2. Review fidelity first, then readability; a prettier rewrite that changes
   meaning loses.
3. Require no hard-field loss and no statistically meaningful preference
   regression.
4. Canary the candidate as an explicit local option before changing the
   hardware-tier default.

Benchmark and ship the same pinned Hugging Face revision. A moving `main`
snapshot makes a passing result non-reproducible.
