# LFM3 adapter export and bounded long-context experiments

The exporter is independently authored and local-only. It defaults to inspection, importing no MLX and reading only safetensors headers plus input hashes. `--execute` loads and fuses the model and therefore belongs in the root-owned serialized GPU window. It supports only the audited `LiquidAI/LFM3-1.7B-MLX-8bit` revision `4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099` and this repository's hash-checked LFM3 port. It does not invoke or copy Phonon application code.

## Export

Set the variables below to the selected, immutable adapter and fresh output paths. Use Python 3.12 in the isolated training environment. `ADAPTER_SHA` must identify the actual selected `adapters.safetensors`.

```sh
training/cleanup/.venv/bin/python training/cleanup/scripts/export_lfm3_native.py \
  --base "$BASE_SNAPSHOT" --adapter "$SELECTED_ADAPTER" \
  --adapter-sha256 "$ADAPTER_SHA" --output "$NEW_HF_EXPORT"
```

Review the inspection report, then run the same command with `--execute` in the reserved model-operation slot. Output is first written to a fresh `.partial` directory and renamed only after completion; partial or existing destinations are never overwritten. Failed partial exports remain for inspection. No network calls or upload operations are used.

Fusion uses the installed mlx-lm LoRA module's `fuse(dequantize=True)`, then dequantizes remaining linear/embedding modules. This follows the library's fusion arithmetic, including its rounding. The inverse of the audited port's sanitize operation restores depthwise convolution tensors from MLX `[out,7,1]` to HF `[out,1,7]`. Every key and shape is checked against the architecture, quantization metadata and remote-code mappings are removed, and the tied embedding is retained without inventing a separate output head. Export uses BF16 safetensors with `format=pt`, a weight index, copied byte-identical tokenizer/template files, copied license/notice files when present, and source/input/output hashes. Nonfinite weights fail before activation.

This is an export of an **8-bit-derived, adapter-fused model**. It cannot reconstruct original BF16 base weights. Fusion and subsequent GGUF quantization may change greedy decisions; each is a qualification boundary.

The pinned converter already supports this exact architecture:

```sh
engine/.venv/bin/python native/cleanup/verify_source.py \
  /tmp/velora-native-research/llama.cpp native/cleanup/UPSTREAM.json
PYTHONDONTWRITEBYTECODE=1 "$CONVERSION_PYTHON" /tmp/velora-native-research/llama.cpp/convert_hf_to_gguf.py \
  "$NEW_HF_EXPORT" --outtype bf16 --outfile "$NEW_BF16_GGUF"
"$LLAMA_QUANTIZE" "$NEW_BF16_GGUF" "$NEW_Q8_GGUF" Q8_0
```

`CONVERSION_PYTHON` needs the pinned converter's dependencies, including torch; do not alter the running engine environment. `LLAMA_QUANTIZE` must be built from the same verified source pin. Quantize Q4 only as a separate model-quality experiment. Retain file hashes and commands. The converter's [LFM3 implementation](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/conversion/lfm3.py) handles convolution squeezing, per-layer sliding attention and full-attention partial RoPE. License obligations for LiquidAI weights and the LFM3 port remain separate from llama.cpp's MIT license; the export does not grant new model redistribution rights.

Keep `PYTHONDONTWRITEBYTECODE=1` on every Python command that imports from the pinned upstream tree, including conversion help and inspections. Strict source verification rejects generated `.pyc` files as extras; they are not ignored. The canonical clean-archive tree hash is `9ed56cfe2f6554d6ff40e137b609e1f9e152bc58c9db0c9d51b87891bdf1bd0d`. The original pin accidentally included local bytecode. Historical result artifacts retain their recorded old hash; the runtime commit and original source-archive hash did not change.

Minimum root-owned inference gates: unfused adapter versus fused-HF on identical public tokenized prompts; HF versus BF16 GGUF with identical prompt token IDs and EOS; then Q8/Q4 quality separately. Compare full generated token IDs, statuses, guarded outputs, and recovery. A near-tie mismatch requires measurement, not a claim of exact parity. Only after public gates should the frozen private cohort be replayed.

## Runtime controls

The worker and supervisor accept `--prefill-batch` values 16, 32, 64, 128, 256, 512 (worker spelling `--prefill-batch=N`). It sets both requested logical batch and microbatch; ready metadata reports actual allocated batch/microbatch and requested prefill chunk. The scheduler retains the same prompt token sequence, inserting no new prompt boundaries. Copy verification still uses its independently selected `--draft-max` (1–8). Prefix identity includes the batch allocation, and each run starts a new worker.

`--bounded-swa` opts into the pinned runtime's smaller sliding-window KV allocation. The default remains upstream `swa_full=true`. Ready metadata reports both flags, and prefix identity includes the allocation mode. At microbatch128, LFM3's five sliding layers use512 cells rather than the full context; for F16 K/V the calculated savings are35/75/155MiB at4k/8k/16k. These are tensor-allocation estimates, not process-memory measurements or speedup claims. Fused KV-row selection may already limit attention reads even with full allocation. Test window-boundary token parity, prefix restore, cancellation/recovery, and copy rollback separately before qualification; a bounded cache cannot support arbitrary rewind after old positions are discarded.

Default context/output caps remain 4096/512. `--research-long-context` explicitly permits context 8192 or 16384 and `--max-output-tokens` up to 2048. The JSON request must still request the desired `max_tokens`; startup cap does not force generation length. Deadline remains bounded by 120 seconds; RSS supervision, 1 MiB frames, 64 KiB user/draft fields, cancellation, state clearing and 32 MiB snapshot limits remain intact. Large-context draft snapshots can exceed the unchanged 32 MiB cap and fall back to scalar decoding; that is recorded, not hidden. First measure long-note scalar generation before pursuing copy acceptance for a summarization task.

`benchmark.py` forwards these controls and adds `--max-tokens` (default256) and `--deadline-ms` (default10000). Example same-token prefill arm:

```sh
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python native/cleanup/benchmark.py \
  --binary /tmp/velora-native-research/build/velora-cleanup-native \
  --model "$GGUF" --sha256 "$GGUF_SHA" --data "$PUBLIC_JSONL" --out "$FRESH_REPORT" \
  --prefill-batch 32 --trace-runtime
```

Repeat serially for the six chunk values, holding model, messages, context, output cap, cache/copy flags and binary constant. Counterbalance order and repeat promising arms without tracing. The public benchmark renders the short cleanup contract; meeting summarization requires an explicitly recorded meeting prompt through the same supervisor, not relabeling cleanup output as a meeting summary.

With tracing enabled, `first_decision_ms` measures request start through the first sampled token, including EOS, tokenization, prefix work, prefill and the existing GPU completion wait. No new GPU synchronization is introduced. Existing prefill-submit timers alone do not isolate GPU prefill time. Compare first-decision and total latency plus decode batch counts, tokens, cache hit/snapshot bytes, draft acceptance, RSS and status. Empty/failed generations retain null first-decision timing when no sample completed.

## Cheapest locating tests

1. A fixed long public prompt and one generated token: six prefill chunk values, prefix cache off, copy off. This isolates chunk-shape effects on essentially the same work. Preserve every input token ID; length status is expected for this diagnostic and never accepted as a completed summary.
2. The same prompt with a fixed meaningful output budget: distinguish first-decision improvements from decode throughput. Require EOS for usable output. Test 4k/8k/16k context as separate allocation arms, not by silently truncating the prompt.
3. Prefix cache off/on on repeated and changed system prompts, followed by context overflow and recovery. Keep user text out of the static snapshot.
4. Only after attribution, compare semantic document chunking or hierarchical summaries. These change model inputs, available cross-section evidence and quality; evaluate topic/evidence coverage and fabricated decisions/owners separately from same-token runtime parity.

Earlier short-cleanup traces put host snapshot save/restore below 1% of total latency. They do not justify new fused kernels for long prompts. Establish actual long-prompt prefill/decode costs first; batch shape can also perturb near-tied logits.
