# Phonon audit and Velora efficiency experiments

## Decision

Phonon has useful engineering ideas and a substantially smaller specialized
cleanup model. Its headline key-release time does not establish that its whole
pipeline is faster, cheaper, or more accurate for Velora's workload. Keep the
existing model choice until a candidate passes Velora's language, formatting,
custom-mode, and content-preservation checks. Retain only measured runtime
improvements. A measured 512 MiB allocator-cache budget is retained for the
Quality model; the model choice and recording scheduler remain unchanged.
No paid inference or training is part of this experiment.

## Evidence and scope

- Velora starting commit: `23436eb` (0.31.0), clean `main`.
- Phonon: [`342b641c`](https://github.com/Infatoshi/phonon/tree/342b641c093f103e9aec9bed98865844e9c041fa),
  620 tracked files. The repository tree was inventoried, and the recording,
  ASR, refinement, native kernels, orchestration, model delivery, training,
  evaluation, app integration, and distribution paths were traced. This is a
  targeted engineering audit, not a claim that every line or platform was tested.
- Shipped refiner: `Infatoshi/phonon-refiner-1.7b`, pinned
  `2b0ab74bee7ab7cf364695bbe44f64ce4c47439e`. The native target and drafter
  checksums are recorded by the new benchmark.
- Hardware: Apple M5 Max, 36 GiB unified memory. GPU experiments run sequentially
  with isolated workers; the installed Velora and other local model applications
  remain open and idle. This is a development-machine comparison, not an energy
  measurement or a controlled reproduction of the author's M4 Max result.
- The [linked post](https://x.com/elliotarledge/status/2118386115170496855)
  was retrieved with its text and 54.5-second promotional video. Representative
  frames were inspected. It illustrates the architecture; frames cannot verify
  a 65 ms latency claim. No audio transcription was available through the local
  video skill installation, so no spoken claims are inferred.

## Why Phonon feels fast

### It spends work before key release

`sidecar/stream_asr.py` retranscribes the pending audio every 0.4 seconds,
with overlap and bounded history. `sidecar/polish_server.py` simultaneously
maintains a rewrite of the latest transcript. At release, it can reuse a
completed rewrite when the exact final prompt matches, with no model forwards.
Otherwise it rolls state back to an exact common prefix and verifies a draft
against the final request.

This explains the distinction between full inference time and the work left
after releasing the key. More GPU work during speech can lower release latency
while increasing total work and energy. The author's README reports an engine
median around 30 ms on 40 dictations, while the post quotes about 65 ms to paste;
these have different endpoints. Neither is reproduced by a text-only benchmark.

Primary paths:
[`stream_asr.py`](https://github.com/Infatoshi/phonon/blob/342b641c093f103e9aec9bed98865844e9c041fa/sidecar/stream_asr.py),
[`stream_decode.py`](https://github.com/Infatoshi/phonon/blob/342b641c093f103e9aec9bed98865844e9c041fa/sidecar/stream_decode.py),
[`polish_server.py`](https://github.com/Infatoshi/phonon/blob/342b641c093f103e9aec9bed98865844e9c041fa/sidecar/polish_server.py).

### The model supports thinking; this application disables it

Liquid's base LFM3 template enables reasoning by default. Phonon passes
`enable_thinking=False`; its pinned template then emits a closed thought block.
The model card explicitly prescribes greedy decoding, thinking off, and no
repetition penalty. The application's speed is not an example of generating a
long reasoning trace unusually quickly.

Velora already passes `enable_thinking=False` in `CleanupEngine._prompt_tokens`.
There is no additional win from repeating that setting.

Sources: [Liquid's model card](https://huggingface.co/LiquidAI/LFM3-1.7B),
[pinned Phonon model card](https://huggingface.co/Infatoshi/phonon-refiner-1.7b/blob/2b0ab74bee7ab7cf364695bbe44f64ce4c47439e/README.md).

### Smaller task-specific weights and a much shorter prompt

The refiner is fine-tuned from LFM3-1.7B. It has 24 layers: 13 short-convolution,
five sliding-attention, and six global-attention layers. The native target is
988,453,696 bytes; the separate DFlash2 drafter is 214,803,168 bytes. The app also
downloads a 1,133,072,561-byte MLX fallback. Those duplicate formats explain much
of the advertised refiner download size; they are not all necessarily loaded.

Velora's configured Quality cleanup model is general Qwen3.5-4B, eight-bit.
Its static cleanup instructions alone tokenize to 2,398 Qwen tokens in the
pinned tokenizer. Phonon's specialization permits a short instruction plus one
writing-mode line. Velora already caches its static prefix, so removing these
tokens primarily helps loading, cold preparation, changed context, and model
working state rather than saving the full prefill on every request.

### Model-specific Metal execution and two kinds of speculation

`engine/mk.metal` executes an entire target decoding step in one persistent
GPU launch, fusing the 24-layer stack and using fixed arenas. `engine/pe.mm`
uses patched llama.cpp for larger prefills, transfers state to its native
decoder, and verifies batches of draft tokens. Its native target context is
2,048 tokens, irrespective of the base model's advertised context window.

The native one-shot path has a separately trained DFlash2 network proposing up
to seven tokens, verified by the target. Streaming also proposes tokens from
the previous rewrite and raw transcript. These lookup drafts cost no additional
model weights. Only target-verified prefixes are accepted.

Velora already speculates from transcript n-grams. Its Qwen-specific limit of
three input tokens per verification pass comes from earlier measurements; a
larger Phonon block cannot be transplanted safely across model/kernel shapes.

Recognition is also custom: `engine/asr/pa.mm` and `pa.metal` implement
Parakeet log-mel, encoder, and TDT decoding, with GPU-side token/duration
control and reusable scratch. It is more than a Rust wrapper around stock MLX.

Sources:
[`engine/`](https://github.com/Infatoshi/phonon/tree/342b641c093f103e9aec9bed98865844e9c041fa/engine),
[`stream_draft.py`](https://github.com/Infatoshi/phonon/blob/342b641c093f103e9aec9bed98865844e9c041fa/sidecar/stream_draft.py).

## Memory and correctness tradeoffs

- Phonon's MLX ASR fallback bounds unused allocator buffers at 1 GiB rather
  than clearing them every request. Its source comments report runaway cache
  growth on varied clip shapes; those reported measurements are not our result.
- Native execution lazily loads fallback weights, avoiding two active copies
  when the preferred backend works. Fixed arenas reduce allocation churn but
  retain capacity for short recordings too.
- Hybrid convolution state is not free: arbitrary rollback requires stored
  convolution history, additional snapshots, and native/llama contexts.
- Native weights use memory mapping. macOS physical footprint omits some
  reclaimable file-backed pages; compare footprint and RSS separately, and
  never call weight-file size or either process metric a total RAM requirement.
- Streaming past roughly 200 words freezes older corrected text and works on
  a tail of about 80 words. A late correction to an old sentence may therefore
  have different semantics from Velora's whole-recording cleanup.
- The author's 16 GiB streaming threshold is a product policy, not a proven
  optimal threshold for Velora's different model pair.

## Training: useful methods and limits

The current pinned model card documents 76,960 public/synthetic examples,
half with four writing modes and half without. Targets came from DeepSeek;
mode labels used its hosted API. The recipe is rank-16 all-linear LoRA,
learning rate 2e-4, two epochs, batch 16, and maximum training length 1,024.
The merged model uses mixed precision for MLX and importance-aware GGUF
quantization for native execution.

The most useful data ideas are conservative edits, unrelated-vocabulary hard
negatives, no-change examples, ASR-generated error distributions, and source
or speaker splits before labeling. Evaluate damage, invented glossary terms,
lost entities/numbers, and content retention alongside word error rate.

The codebase's `ml/AGENTS.md` and `ml/SPEC.md` still describe older LFM2.5
research and off-repository datasets/reports. They do not constitute a complete
reproduction recipe for the shipped LFM3 weights. Published evidence also has
limits: the current card describes one-speaker real-dictation checks,
increased deletions on lecture captions, and only roughly half of a synthetic
self-correction probe resolved. The model's own supported language is English,
despite broader language support in its base model.

A Velora fine-tune is worth pursuing only after a smaller specialist passes a
held-out contract covering Hindi/Hinglish, romanization, custom modes, numbers,
technical vocabulary, self-corrections, long input, and quoted instructions.
Use a local teacher or public licensed targets; do not upload private
dictations for labeling. Training the existing latency test fixtures would
invalidate the quality comparison. No fine-tune is launched merely to mask
allocator or scheduling costs.

## What to import into Velora

| Idea | Current Velora state | Decision |
| --- | --- | --- |
| Suppress thinking | Already implemented | No change |
| Prefix caching and transcript copy drafts | Already implemented | Preserve; benchmark model-specific changes |
| Bound unused Metal cache | Previously no explicit cleanup cap | Retain measured 512 MiB budget for Quality only |
| Small specialist with short mode prompt | General model serves cleanup and other work | Isolated candidate; require language/custom-mode parity |
| Reuse exact completed rewrite | Segment streaming exists; short final usually rechecks whole input | Next experiment needs full request identity |
| Previous rewrite as a verified draft | Transcript lookup only | Promising follow-up; measure acceptance and rollback cost |
| Continuous 0.4 s ASR/refinement | Stable segment cleanup, backend-dependent final reuse | Requires concurrent-work and energy budget |
| Native model-specific megakernels | General MLX runtime | Large separate project after model selection |
| Train DFlash drafter | No learned drafter | Defer until target specialization is justified |

Recording-start prefill was deliberately removed in Velora commit `5221c3e`;
`test_recording_never_runs_cleanup_prefill_against_live_stt` protects that
choice. A fake delayed task cannot establish a speed win under actual GPU
contention. No recording-time prefill is restored in this work.

Safe short-final reuse would require an already-completed successful cleanup
of the entire final raw text, with identical normalized model input, system
prompt, model revision, vocabulary, and decoding/validation settings. Current
chunk results do not retain that identity. Raw-string equality alone is
insufficient because stop-time context and normalization can differ.

Phonon's application code is GPL-3.0 and Velora is MIT. These experiments run
the reference engine separately; the benchmark client is independently written.
No Phonon implementation is copied into the product. The model carries its own
LFM license, separate from the application source.

## Experiments and reproduction

Results are recorded in the accompanying JSON summary and the local experiment
log under `.context/compound-engineering/ce-optimize/phonon-efficiency/`.
Public fixtures are used throughout; personal history is not a training or
benchmark input. Full cleanup timings exclude audio recognition and insertion.
Candidate adoption requires no additional quality failures; same-model memory
changes additionally require matching outputs and stable latency.

### Native refiner result

On the same 22 supported English fixtures, Phonon native one-shot cleanup took
70.14 ms median versus 521 ms for the initial Qwen run (three repetitions per
case). Its p95 was 123.42 ms. This sequential comparison shows a substantial
speed opportunity; it does not reproduce 65 ms microphone-to-paste latency,
and no speed confidence interval or energy comparison was measured.

Fourteen of those 22 fixtures failed Velora's contract. Eleven concern required
list/layout behavior; their words often remain in prose. Three concern grammar,
number formatting, or meta-edit handling. These are compatibility failures,
not a blanket ranking of model quality. Five additional fixtures were counted
as unsupported: custom mode instructions and Hindi/Chinese/romanization.
The native candidate therefore fails the replacement gate.

Native post-inference footprint was 517 MB and RSS 1.325 GB. Its mapped target
plus drafter files total 1.203 GB. Neither footprint nor RSS is a total working
RAM requirement; the native mapping strategy makes footprint alone especially
misleading. No MLX fallback weights were loaded in this benchmark.

### Allocator experiments

The 256 MiB candidate reduced footprint from 6.362 to 5.726 GB, but median
cleanup rose from 485 to 995 ms and an additional Chinese fixture timed out
in one repetition. It was rejected. A 1 GiB budget retained nearly the same
0.96 GB allocator cache and demonstrated no material memory benefit.

The intermediate 512 MiB budget consistently left about 0.537 GB in unused
Metal buffers instead of roughly 0.95 GB. Live weights and prepared prompt
state stayed at the same 4.745 GB. The resulting production change applies
only to `mlx-community/Qwen3.5-4B-MLX-8bit`, on its dedicated model thread before
loading; other model processes retain their prior policy. It does not call
`clear_cache()` after every token or discard the warm prompt.

Confirmation used three independent uncapped workers and three capped workers,
each running all 27 cases three times. Across their run summaries:

| Metric | Uncapped | Retained policy |
| --- | ---: | ---: |
| Median cleanup wall time | 468 ms | 469 ms |
| Median of run p95 wall times | 629.7 ms | 625 ms |
| Post-inference footprint | 6.362 GB | 5.968 GB |
| Unused allocator cache | 0.953 GB | 0.537 GB |
| Additional failed fixtures / changed outputs | — | 0 / 0 |

Footprint decreased 394,149,984 bytes (6.2%). The 1 ms median latency difference
is within the declared 5% comparison threshold. Individual run medians were
446–485 ms uncapped and 458–588 ms capped, so no speed improvement or latency
confidence bound is claimed. The optimization decision accepts the memory
improvement while treating timing as inconclusive. The existing ordinal
fixture failure persisted identically.

All 62 revision-2 decision predictions and rounded gold probabilities matched
the uncapped run: 58/62 correct in each. That unchanged score includes existing
misses. Decision medians were 238.1 and 215.3 ms, respectively; the evidence is
used as a regression check rather than a general speed claim.

Two synthetic multi-turn planner scenarios also produced identical validated
turns. A 1,120-word synthetic meeting chunk produced identical valid notes JSON
in 1,685.0 ms uncapped and 1,689.7 ms capped. These are smoke checks, not a claim
about arbitrary long plans, whole meetings, or simultaneous recording.

The default production model already misses the mismatched-ordinal list fixture
under copy-draft decoding. Baseline failures are reported rather than erased;
they do not license a candidate to add new failures. Per-case medians of three
repetitions form the timing distribution.

```sh
cd engine
uv run python scripts/benchmark_cleanup_resources.py --repeats 3
uv run python scripts/benchmark_cleanup_resources.py --uncapped --repeats 3
uv run python scripts/benchmark_cleanup_resources.py --stress --repeats 3
uv run python scripts/benchmark_cleanup_resources.py --stress --cache-limit-mb 1024 --repeats 3
uv run python scripts/benchmark_phonon_refiner.py \
  --engine /tmp/velora-phonon-audit/target/engine/pe \
  --model-dir "$HOME/.cache/huggingface/hub/models--Infatoshi--phonon-refiner-1.7b/snapshots/2b0ab74bee7ab7cf364695bbe44f64ce4c47439e" \
  --repeats 3
```

The reference engine was built from the pinned checkout using its
`scripts/build-engine.sh`, with isolated `cmake` and `ninja` packages. Runtime
`PE_DIR` must point to the engine binary directory containing its Metal sources.
These build tools and reference engine are not new Velora runtime dependencies.

## Validation

- Independent review found no production lifecycle defect. Model switches,
  hibernation, and recovery create dedicated children, so another model does
  not inherit this model's allocator policy.
- Full `make test`: 3,932 Swift checks; 2,039 Python tests passed, three skipped;
  site, Sublime plugin, signing, publish-release, bootstrap, and update checks
  passed. The Python suite reported two third-party deprecation warnings.
- This machine's Command Line Tools macOS 27 SDK failed to find its
  `SwiftUIMacros.StateMacro` plugin. The installed 26.5 SDK completed the gate:

  ```sh
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk make test
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/make-app.sh release none
  ```

Four candidate policies/models were evaluated; the 512 MiB cache policy is
the retained change. The 256 MiB policy and native model failed adoption
checks; 1 GiB showed no material memory benefit. The run stops at the declared
four-candidate limit. Remaining work is model specialization and carefully
budgeted speculative rewrite, with the language/mode contracts above.
