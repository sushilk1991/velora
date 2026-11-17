# Candidate research and current audit

Verified 2026-11-18 local date; source API snapshots retained alongside this file.
Active config names `mlx-community/Qwen3.5-4B-MLX-8bit` for cleanup and
`mlx-community/whisper-large-v3-turbo` for STT. Native trial was not enabled.
Only the shared cleanup LLM is in scope. Host: Apple M4 Max, 36 GiB unified RAM.
Runtime: MLX 0.31.2, MLX-LM 0.31.3, Transformers 5.3.0. Generation is greedy,
thinking disabled; production caches prompt prefixes, requests target-verified
copy drafts for an allowlist, and caps Quality's unused-buffer cache at 512 MiB.
Inputs pass through formatting gates, token neutralization, chat-template
encoding, inference guards and postprocessing. No personal corpus is accessed.

## Ranked initial shortlist

1. **Qwen3.5 2B MLX 4-bit**, revision
   `93760be4f1f69842a46bc13dbdc0f19e291392a3`: same architecture family, tokenizer
   and general instruction contract as the baseline, with 24 rather than 32
   layers and narrower hidden/MLP dimensions. Already supported as Compact.
   Lowest integration risk and broadest role compatibility. Its smaller logical
   parameter count meets the user's criterion that quantization alone cannot.
   Risk: weaker multilingual, grammar, list and action behavior. The card's
   "4-bit" is mixed precision; artifact bytes are measured, not inferred from
   nominal bits. [Source](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit).
2. **Muesli Qwen3.5 2B cleanup v12, MLX 8-bit**, revision
   `0fbfa48e98f1f8f28a0e3ca692066c823812db4e`: task-specific LoRA fused into the
   2B base. A plausible way to retain cleanup quality at fewer parameters while
   avoiding 4-bit quantization error. Card reports 155,081 cleanup training pairs.
   Exact manually encoded single-user-turn prompt, no chat-template engine,
   no system role, greedy decoding and no repetition penalty are required; the benchmark adapts that request only
   inside its isolated worker. Risk: explicitly English only and not trained
   for Velora's custom-mode, edit/action/summary contracts.
   [Source](https://huggingface.co/Muesli-HQ/qwen35-2b-muesli-cleanup-v12-mlx-8bit).
3. **Vedu Scribe 0.8B, mixed 4/8-bit**, revision
   `7dced5841c58d7d6e0118c4c123f222b35057871`: fused specialist with trained tone,
   format and vocabulary controls. Fewer parameters and a smaller packed
   artifact offer a strong memory/latency hypothesis. Its mandatory system
   message is `Clean up this dictation.`; the harness supplies supported formal
   notes controls without reading expected answers. Risk: English-only,
   about 400 input-token recommendation, no general Action/notes capability.
   Vendor timings are not Velora measurements.
   [Source](https://huggingface.co/heyvedu/vedu-scribe-0.8b).

**Additional cycle candidate:** Muesli Qwen3.5 0.8B v12 MLX 8-bit,
`d557e9528ba42a47026372d372e071e6f2db33e2`, shares Muesli's exact prompt contract
with a smaller language model. Useful to separate task fine-tuning from capacity.
[Source](https://huggingface.co/Muesli-HQ/qwen35-0.8b-muesli-cleanup-v12-mlx-8bit).

**Fifth-cycle option:** Qwen3.5 2B MLX 8-bit, revision
`e6ffd0033d03c9efa880984e611028e0da63905f`. If the general 4-bit model
regresses, hold architecture/capacity fixed and raise precision. This isolates
quantization loss from capacity loss and retains general task compatibility.
Only this new public checkpoint is acquired into task-owned temporary storage.
[Source](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-8bit).

S1-mini was considered but deprioritized: it is another English-only
specialist, while the fifth cycle can test the general model's quantization
hypothesis directly. Its pre-existing helper was corrected to preserve gated
input, independently of whether it is benchmarked.

**Potential runtime refinement:** enable target-verified copy drafts on Compact
and bound its unused-buffer allocator to 512 MiB in the experimental worker.
This is not currently production-qualified for that ID. Require unchanged
per-request outputs versus unmodified Compact before crediting a speed-only win.
Do not alter the benchmark's timeouts or suppress failures to claim speed.

## Architectures and runtimes screened out initially

- **Liquid LFM3 1.7B:** attractive 1.73B tri-hybrid design; available MLX8/4,
  GGUF and ONNX. Current official model card says no MLX-LM release supports it,
  with support still open in upstream PR 2016. The pinned Velora runtime has no
  LFM3 architecture module. Loading it here would require a separate integration
  and runtime qualification, while Qwen candidates use the actual production
  engine. Existing native trial is a separate explicitly gated specialist.
  [Model](https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-8bit),
  [upstream support](https://github.com/ml-explore/mlx-lm/pull/2016).
- **Qwen4B 4-bit only:** disk/RAM may fall but parameter count is unchanged,
  failing the explicit size gate before inference.
- **TensorRT/INT8 NVIDIA engines:** the target has Apple Metal, not an NVIDIA
  CUDA GPU. Benchmarks on a Linux CUDA box would not be identical hardware.
  [NVIDIA installation targets](https://docs.nvidia.com/deeplearning/tensorrt/latest/installing-tensorrt/installing.html).
- **GGUF/CoreML/ONNX conversions:** require their own tokenizer/template,
  hybrid recurrent-cache, output-equality and production-routing qualification.
  No current evidence says a conversion is faster for this workload. Keep the
  current runtime for the first candidates to isolate the model-size hypothesis.

MLX uses unified memory on Apple Silicon. Physical footprint and RSS are
reported separately from MLX allocator peaks; adding these together would
count overlapping allocations. There is no separate discrete VRAM pool.
[MLX documentation](https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html).

## Qualification audit

Independent Muse code review is retained in `raw/independent-audit.txt`.
The legacy 27-case script measures per-case medians, not raw latency tails;
compares active allocator bytes instead of peak process memory; and disables
production copy drafts by default. The new harness fixes those measurement
issues and preserves all raw failures. The 62 decision cases are only a
secondary metric: they bypass current production action confidence/routing.
No candidate can be globally promoted on cleanup predicates alone. A candidate
surviving screening still requires semantic output review, the full repository
gate, and shared edits/actions/notes qualification. Existing gaps cannot be
silently reinterpreted as a passing 0%-regression guarantee.
