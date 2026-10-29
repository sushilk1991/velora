# LFM3 fine-tune study: 2026-10-29

The question: LFM3 is well reviewed, yet on our cleanup bench it trails
Qwen3.5 badly. Are we running it wrong, and does fine-tuning close the gap?

## Decision

Nothing is adopted and no production code changed. Fine-tuned on the
shipped 4B's own cleanups, LFM3-1.7B-8bit beats the shipped small tier
(Qwen3.5-2B-4bit) on held-out real takes and ties it on the bench. It is
still far from the 4B on the bench (9–13 failures vs 1), and four things
block shipping it:

- **Training data.** The adapter learned from the owner's dictations. It
  cannot ship to anyone else. A shippable adapter needs a non-owner
  training set.
- **No fair comparator.** The win may come from fine-tuning, not from
  LFM3. The fair rival is a fine-tuned Qwen 2B, and mlx-lm 0.31.3 cannot
  train it in practice (below).
- **Runtime.** `lfm3` is in no mlx-lm release (0.32.2 is the latest;
  support is open PR ml-explore/mlx-lm#2016). These runs used the port
  vendored in [2026-10-27-lfm3-bakeoff/lfm3.py](2026-10-27-lfm3-bakeoff/lfm3.py).
  mlx-vlm `main` (bf02cd0, installs as 0.7.11) has LFM3 support but no
  release yet, and needs mlx 0.32.4 and transformers 5.21; the engine pins
  mlx 0.31.2 and transformers 5.3.
- **License.** LFM Open License v1.0 allows commercial use only below
  US$10M annual revenue.

## Why LFM3 looks weak on our bench

1. **We run it in its non-default mode.** LFM3-1.7B is reasoning-first:
   its chat template opens `<think>` by default, the model card says
   turning thinking off "can be inconsistent", and the vendor scores were
   taken with thinking on (vLLM, BF16, temperature 0.6). Cleanup cannot
   afford a thinking pass, so we turn it off. The model then reasons inside
   its answer ("The user is asking…", "Let me clean this up:", a stray
   `<think>`) and runs into the length guard: 56 of its 74 rejected
   held-out takes are length stops.
2. **The prompt was tuned on Qwen.** Every rule in the cleanup system
   prompt was fitted to Qwen3.5's failures. LFM3 gets the same prompt
   untouched.
3. **The vendor pitches it for fine-tuning.** The card calls it
   designed for domain-specific fine-tuning. The headline gains are
   instruction-following benchmarks (IFBench 73 vs Qwen3.5-4B's 38,
   vendor-reported), not zero-shot rewriting with thinking off. We found
   no independent review (the models came out 2026-10-27).
4. **The bench is a stress test.** 12 of its 27 cases require a list and 3
   are Hindi or Chinese; those are where small models fail most. In the
   owner's real takes, 4.5% of the 4B's outputs are lists (20 of 448) and
   2 are in a non-Latin script. A model can lose the bench and still do
   well on real use, which is what happened here.

LFM3-VL-2B is not the 1.7B with vision added; it was post-trained
separately from the same base. Zero-shot it does better than the 1.7B
(12–14 failures) but no better than Qwen 2B (11).

## Results

Same harness for every arm: the engine's gate builds the production
prompt, the model answers greedily with thinking off, and the engine's
acceptance path (length guard, `check_divergence`, `postprocess`) runs
before scoring. *Bench* is `benchmark_cleanup_quality.py`'s 27 cases.
*Held out* is the newest 10% of the owner's takes (104), never trained
on, scored against the shipped 4B's output: *rejected* means the engine
would have fallen back to raw text, *similarity* is difflib's ratio
between final texts.

| Arm | Bench fails /27 | Held-out rejected /104 | Similarity to 4B |
|---|---:|---:|---:|
| Qwen3.5-4B-8bit (shipped default, the teacher) | 1 | — | — |
| Qwen3.5-2B-4bit (shipped small tier) | 11 | 23 | 0.796 |
| Qwen3.5-2B-4bit, repetition penalty 1.1 | 10 | 20 | 0.802 |
| LFM3-1.7B-8bit, zero-shot | 17 | 74 | 0.795 |
| LFM3-VL-2B-6bit, zero-shot greedy / card sampler | 14 / 12 | — | — |
| LFM3-1.7B-8bit + LoRA, 1 epoch | 14 | 20 | 0.822 |
| LFM3-1.7B-8bit + LoRA, 1 epoch + 59 coverage items | **9** | 2 | 0.841 |
| LFM3-1.7B-8bit + LoRA, 2 epochs | 13 | **0** | **0.868** |
| same, fused into one 8-bit model | 13 | 0 | 0.865 |

Paired against Qwen 2B on the same 104 held-out takes:

| | 2 epochs | 1 epoch + coverage |
|---|---|---|
| Accepted only by LFM3 / only by Qwen 2B | 23 / 0, p = 2.4e-7 | 22 / 1, p = 5.7e-6 |
| Closer to the 4B: LFM3 / Qwen 2B | 57 / 28, p = 0.002 | 48 / 30, p = 0.054 |
| Accepted outputs ≥ 0.95 similar (Qwen 2B: 43) | 64 | 56 |
| Bench: passes only LFM3 / only Qwen 2B | 6 / 8, p = 0.79 | 5 / 3, p = 0.73 |

What fine-tuning changed:

- **Fixed.** Role confusion and runaway answers: held-out rejections went
  from 74 to 0. Half an epoch removed the reasoning-in-the-answer failures
  on the bench. The 1-epoch arm's 20 remaining rejections were all length
  stops, 15 of them repetition loops, and the second epoch removed them. A
  repetition penalty does not replace the second epoch (1 epoch + penalty:
  16 rejected, bench 15).
- **Fixed by coverage items.** Five list cases started passing once 59
  hand-written dictations (lists, prose that must stay prose, each mode,
  romanized Hindi, Hindi and Chinese lists) were added to the 1-epoch
  run (bench 14 → 9, p = 0.062 against the same run without them). They
  were written after seeing which kinds of case failed, on different
  topics, so this bench gain overstates the effect. On held-out takes the
  gain is in acceptance (84 → 102, p = 1.2e-4), not similarity (p = 0.21).
- **Not fixed.** Hindi and Chinese lists, both romanized-Hindi cases, the
  names-and-numbers case, and four multi-item or self-correction cases.
  The training set has almost no multilingual examples.

Not run: 2 epochs with the coverage items (924 steps, about 3 hours of GPU
at run 1's pace), the next arm if this line resumes.

## Cost

Latency on the bench, A-B-C-C-B-A passes (54 calls per arm), load1 7–21.
The harness decodes greedily without copy-draft, so read the ratios, not
the absolute numbers.

| Arm | p50 | p95 | Decode p50 | Active RAM |
|---|---:|---:|---:|---:|
| Qwen3.5-4B-8bit | 1,510 ms | 6,203 ms | 30 tok/s | 4.74 GB |
| Qwen3.5-2B-4bit | 516 ms | 2,999 ms | 97 tok/s | 1.16 GB |
| LFM3-1.7B-8bit, fused LoRA | 646 ms | 3,388 ms | 68 tok/s | 1.96 GB |

RAM is from the [2026-10-27 bakeoff](2026-10-27-lfm3-bakeoff.md). LFM3 is
25% slower than Qwen 2B at p50 and needs 0.8 GB more.

Training on an M4 Max shared with other work: 148 min for 2 epochs of 344
examples, 74 min for 1 epoch of 462, peak 7.05 GB. That rules out
training on the 8–16 GB Macs where the small tier runs.

## Why no fine-tuned Qwen

mlx-lm 0.31.3's `qwen3_5.py` uses the fused Gated DeltaNet kernel only
when not training (`use_kernel=not self.training`); in training it falls
back to a per-token Python loop. Eight LoRA steps on Qwen 2B did not
finish in 11 minutes. Until that changes, a fine-tuned Qwen 2B, which is
the comparison that would tell LFM3's contribution from fine-tuning's,
cannot be run on this stack.

## Method

- **Teacher.** The shipped 4B-8bit, through the same harness, on the
  owner's takes (`~/.velora/history.sqlite3`, opened read-only; Action
  takes skipped). Split by time: the oldest 935 are train, the newest 104
  held out. The teacher labelled 411 train takes; 344 were accepted by the
  engine and fit 4,096 tokens.
- **Coverage items.** [synth.json](2026-10-29-lfm3-finetune/synth.json):
  60 invented dictations (59 reach the model), labelled by the same
  teacher, all 59 accepted. No owner text, and no names from the owner's
  history.
- **Recipe** ([train.py](2026-10-29-lfm3-finetune/train.py)). LoRA on every
  layer, rank 16, scale 20, no dropout; Adam, lr 1e-4 with 20 warm-up
  steps then cosine to 1e-6; batch 1, gradient accumulation 4, gradient
  checkpointing. Each example is the exact production prompt (thinking
  off) plus the teacher's answer and `<|im_end|>`; loss covers only the
  answer. Coverage items are seen twice per epoch.
- **Statistics.** Exact McNemar on discordant pairs; sign test on per-take
  similarity, ties dropped.

## Reproduce

Two venvs, both with the engine installed editable (`--no-deps`):

- **A** (text models): the engine's pinned requirements, plus
  `2026-10-27-lfm3-bakeoff/lfm3.py` copied to
  `site-packages/mlx_lm/models/lfm3.py`.
- **B** (LFM3-VL): the engine's requirements without mlx, plus
  `mlx-vlm` at commit bf02cd0.

```
python evalrun.py qwen2b <model dir> runs/qwen2b.jsonl bench,dev
python evalrun.py teacher <4B dir> runs/teacher.jsonl dev,train
python train.py <LFM3 dir> runs/teacher.jsonl runs/lora --epochs 2
python evalrun.py lfm3-ft <LFM3 dir> runs/lfm3-ft.jsonl bench,dev --adapter runs/lora
python score.py runs/teacher.jsonl runs/qwen2b.jsonl runs/lfm3-ft.jsonl
python paired.py runs/teacher.jsonl runs/lfm3-ft.jsonl runs/qwen2b.jsonl
QWEN4B=<4B dir> sh latency.sh && python latency_summary.py runs/latency
```

Scripts are in [2026-10-29-lfm3-finetune/](2026-10-29-lfm3-finetune/).
Run outputs stay local: they contain owner text.
