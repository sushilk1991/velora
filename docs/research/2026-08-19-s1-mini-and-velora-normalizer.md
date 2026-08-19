# S1-mini and a Velora-owned normalizer — 2026-08-19

## Decision

Do not ship S1-mini as a Velora cleanup model yet. Keep the current
`mlx-community/Qwen3.5-4B-MLX-8bit` production model and keep S1-mini as a
pinned benchmark candidate.

S1-mini is much faster and smaller on this development Mac, but an honest
production-shaped run failed 16 of Velora's 27 cleanup requirements. A model
that breaks grammar, multilingual output, Romanization, and automatic
structure is not a lower-end tier; it is a different and narrower product.

Training a Velora-specific 0.6–1B normalizer is feasible as a fine-tuning and
distillation project. Training a useful 1B language model from scratch is a
different, data-heavy program and is not justified before the narrow
fine-tune proves that data—not the base model—is the remaining constraint.

## What was verified

Official sources:

- S1-mini model card and exact weights:
  <https://huggingface.co/superwhisper/s1-mini/tree/65f84bcda1d13df582c4a8443c1c5aa53c0c66db>
- S1-mini license:
  <https://huggingface.co/superwhisper/s1-mini/blob/65f84bcda1d13df582c4a8443c1c5aa53c0c66db/LICENSE>
- S1-mini Q4_K_M repository:
  <https://huggingface.co/superwhisper/s1-mini-GGUF/tree/8eab4779866f477ae6e7f237ca45fc2c65153f50>
- Qwen3-0.6B base card:
  <https://huggingface.co/Qwen/Qwen3-0.6B>
- Qwen3 technical report (36T-token family pretraining corpus):
  <https://arxiv.org/abs/2505.09388>
- Chinchilla compute/data scaling study:
  <https://arxiv.org/abs/2203.15556>
- QLoRA paper:
  <https://arxiv.org/abs/2305.14314>
- NVIDIA H100 specifications:
  <https://www.nvidia.com/en-us/data-center/h100/>
- Lambda's current on-demand instance prices:
  <https://lambda.ai/instances>

S1-mini is a Qwen3-0.6B fine-tune with 596M unique parameters (0.44B
non-embedding), 28 layers, and English-only scope. It is a fixed ASR text
normalizer, not a chat or arbitrary-instruction model. Its documented input
requires the exact system prompt plus a style/structure/context control line.

The BF16 file is 1,503,300,328 bytes. The official Q4_K_M GGUF is 484,219,808
bytes. Velora's run used the pinned BF16 checkpoint through the existing MLX
cleanup process; it did not establish Q4_K_M performance or parity.

The card reports 94.8% token accuracy on 7,519 held-out English cases. That is
a vendor claim, not a reproducible result: no dataset, per-cohort results,
outputs, confidence interval, annotation protocol, or training-data ledger is
published. Token accuracy also underweights the product cost of changing one
name, time, or amount.

The card recommends `revision="v1"`, but that ref does not currently exist.
Velora's benchmark therefore pins the immutable weight commit above. It also
pins the Qwen baseline rather than comparing S1 against a moving `main`.

The repository is labelled `license: other`: its Apache 2.0 text adds a clause
requiring every use, derivative, distribution, or product integration to keep
the exact identification “S1-mini” by “Superwhisper”. Commercial use is stated
as allowed, but product-visible placement and derivative-distribution duties
need written licensor or legal confirmation before shipping.

## Local benchmark

Command (one screening repeat, M4 Max 36 GB):

```sh
cd engine
uv run python scripts/benchmark_cleanup_quality.py \
  --model mlx-community/Qwen3.5-4B-MLX-8bit \
  --model superwhisper/s1-mini \
  --repeats 1
```

The S1 adapter uses only production-observable app context. It does not choose
`Structure: lists` from the fixture's expected answer. Both repositories are
resolved before the worker loads them, and every summary emits the commit plus
the SHA-256 of each safetensors file:

| Model | Pinned commit | `model.safetensors` SHA-256 |
|---|---|---|
| Qwen3.5 4B MLX 8-bit | `5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d` | `87c362fdb36bdee8e32ff5961bdceca58d26c2d9b00738543cc0e17e985b46ce` |
| S1-mini BF16 | `65f84bcda1d13df582c4a8443c1c5aa53c0c66db` | `69d2057077ab4dc738aaaab75d2a8ffa141e3a09fb9d956198cfce46f381131a` |

| Model | Failed cases | p50 wall | p95 wall | Active MLX | Process footprint |
|---|---:|---:|---:|---:|---:|
| Qwen3.5 4B 8-bit | 0 / 27 | 764 ms | 1,172 ms | 4.74 GB | 5.55 GB |
| S1-mini BF16 | 16 / 27 | 249 ms | 453 ms | 1.22 GB | 1.97 GB |

S1 reduced median latency by 67%, p95 by 61%, and active MLX memory by 74%.
It passed the user's “3 p.m., no, 6 p.m.” correction example, names/numbers,
ordinary punctuation, and several prose cases. It failed subject-verb grammar,
both Romanization cases, multilingual cases, line structure, and most cases
where Velora must infer a list from speech. The current zero-regression gate
correctly rejects it.

The model also cannot replace Qwen for custom Mode prompts, Voice Edit,
Actions, or meeting-note generation. Keeping both models resident would add
about 1.22 GB of active MLX allocation and more Metal contention; it would not
create a lower-memory machine tier unless Qwen were genuinely unloadable for
the full session.

## Gate for any S1 experiment

Do not add S1 to the model picker until all of these hold:

1. A separate English-normalization route has deterministic eligibility;
   multilingual, Romanization, custom prompts, Voice Edit, Actions, and
   meetings stay on Qwen.
2. The eligible English corpus has zero invented, omitted, translated, or
   structurally lost content and 100% preservation of protected names,
   numbers, dates, times, money, and email addresses.
3. Filler-only empty output is distinguished from a worker/integration failure.
4. Pinned BF16 MLX and official Q4_K_M are compared on raw model output and
   postprocessed output; postprocessing cannot hide a model miss.
5. Saved-audio installed-app replay proves final text, cold/warm latency,
   combined Whisper contention, energy, and fallback behavior on an actual
   lower-end Mac.
6. Net resident footprint does not exceed the current single-Qwen baseline.
7. The naming clause is cleared in writing for Velora's intended UI,
   distribution, and any converted weights.

## Velora-owned model: the smallest credible program

Parameter count is not the goal. The goal is zero-regression normalization at
lower latency and memory. Start from the Apache-2.0 Qwen3-0.6B base (or another
base that wins the same audit), train the narrow transformation, and let the
benchmark decide whether 0.6B, roughly 1B, or a larger teacher is necessary.

### Data contract

Each example should contain:

- raw ASR transcript;
- authoritative written target;
- language and script;
- style, structure, destination, and feature-route labels;
- protected spans for names, numbers, dates, times, currency, email, code,
  commands, and quoted speech;
- provenance, exact license/consent, transformation version, and PII status;
- speaker/document/template group IDs for leakage-safe splits.

Build the first dataset from auditable sources only:

1. Deterministic synthetic corruptions of owned, public-domain, or explicitly
   compatible text: remove casing/punctuation, verbalize structured values,
   and inject fillers, repeats, restarts, corrections, lists, and emails.
2. Teacher-generated candidates from a model whose terms permit training,
   followed by hard-field validation and human review. Teacher output never
   enters the frozen test set.
3. Separately licensed speech corpora only after a row-level license and split
   audit. A dataset name or “open” label is not enough.
4. Opt-in Velora pairs where the user explicitly chooses to contribute the raw
   ASR and their edited final. Existing private history is not training data by
   default, and raw audio requires a separate opt-in.

The contribution surface must offer local redaction, a preview of the exact
payload, export, deletion, retention limits, and a visible provenance receipt.
Do not scrape Reddit, private messages, email, or current history.

Split by speaker/document/template before generating variants. Near-deduplicate
across splits. Freeze a human-authored adversarial evaluation set covering
English, Indian English, Hindi, Hinglish/Romanization, corrections, quoted
correction language, prompts/control injection, code/Terminal text, and all
protected fields.

### Training sequence

1. Establish learning curves with a LoRA/QLoRA supervised fine-tune on the
   smallest auditable corpus. Run the full gate after every checkpoint.
2. Distill the current Qwen behavior only where the teacher output passes
   deterministic and human checks. Oversample rare hard fields and negative
   rewrite cases, not merely easy punctuation.
3. Compare LoRA, merged/full SFT, and 4/8-bit inference. Quantization is a new
   candidate and must repeat the quality gate.
4. Add direct-preference or error-focused tuning only after the supervised
   failure taxonomy is stable; do not optimize a vague aggregate score.
5. Canary as an explicit local experimental tier, then run blinded dogfood
   comparisons and installed saved-audio replay before changing defaults.

Local Apple Silicon is sufficient for inference, corpus tooling, and initial
LoRA experiments. Repeated full fine-tunes may justify rented GPUs, which
requires an explicit budget and data-handling approval; access to code and the
internet is not authorization to buy compute or upload private data.

### Quantified compute and cost envelope

These are planning bounds, not quotes or promised training times. They use the
common dense-transformer estimate `training FLOPs ≈ 6 × parameters × training
tokens`, one H100 at an assumed 30% end-to-end utilization of roughly 756
TFLOP/s dense BF16, and Lambda's current single-H100 PCIe list price of
$3.29/GPU-hour. Taxes, storage, data work, annotation, failed jobs, and
engineering time are excluded. Re-price immediately before any purchase.

**Auditable SFT on a permissive base.** Start with 100,000–1,000,000 examples
at an average 256 tokens for three epochs: about 77M–768M training tokens. For
a 0.6B base, the arithmetic lower bound is roughly 0.3–3.4 H100-hours. A useful
budget is 10–50 H100-hours per training/evaluation round to cover short-sequence
inefficiency, checkpointing, held-out generation, and retries: about $33–$165.
Ten deliberately varied rounds would therefore be capped at 100–500 H100-hours,
or about $329–$1,645, before tax. QLoRA is the first experiment because its
published method freezes a 4-bit base and trains adapters, reducing memory;
quality and actual throughput still have to be measured on this task.

What is auditable in this route: the exact base-weight commit and license,
Velora's adapter code/config, every SFT row, consent/license receipt, split,
checkpoint, and evaluation output. What is *not* row-level auditable is the
base model's original pretraining corpus. The Qwen report describes aggregate
construction and 36T tokens, not a public source-by-source ledger. This route
is legally cleaner than using private data, but it is not equivalent to a
fully provenance-controlled foundation model.

**Provenance-controlled 1B pretraining.** A Chinchilla-style 20-tokens-per-
parameter screening run means roughly 20B tokens and `1.2e20` training FLOPs.
Under the same hardware assumption, the arithmetic lower bound is about 147
H100-hours, or $484 for one perfectly prepared run. That is a compute lower
bound, not a credible project budget: tokenizer experiments, data ablations,
validation, restarts, and lower utilization make 500–2,000 H100-hours
($1,645–$6,580) a more honest proof-model envelope, and 20B tokens may still be
far below the knowledge/language coverage Velora needs.

A stronger 1T-token 1B run is about `6e21` FLOPs, 7,350 H100-hours, and $24,200
for one run under the same assumptions. Three to five serious runs/ablations
are roughly 22,000–36,750 H100-hours, or $72,000–$121,000, before people and
data costs. Qwen3's reported 36T-token family training is useful scale context:
we should not imply that a small legal corpus plus one GPU run recreates a
modern multilingual base.

What can be audited in a from-scratch route: tokenizer sources, accepted corpus
documents, source URL/version, license or consent, transformations, dedup,
deletions, splits, trainer, and checkpoints. “Publicly downloadable” is not a
license. Sources with unclear authorship, downstream redistribution rights, or
personal data are excluded even if that makes the corpus smaller. This route
only becomes preferable if that end-to-end provenance requirement is worth the
large quality, data, time, and cash penalty.

### Why not train 1B from scratch now

A from-scratch 1B base needs a large, diverse, legally documented pretraining
corpus and many training/ablation runs before task fine-tuning. The bottleneck
is acquiring and validating that corpus, not writing the trainer. A narrow SFT
on an existing permissive base can test the product thesis with orders of
magnitude less data and risk. Start-from-scratch becomes rational only if base
model provenance is a hard requirement or every audited base fails the target
after the clean-data fine-tune.

## Next evidence milestone

The next model milestone is not “integrated into production”. It is a pinned,
reproducible English-specialist corpus of at least hundreds of human-audited
cases, plus real lower-end-Mac saved-audio measurements. If S1 still has a
quality failure, the project moves directly to the clean Velora fine-tune; if
it passes, its dual-model footprint and license still have to clear the gates
above.
