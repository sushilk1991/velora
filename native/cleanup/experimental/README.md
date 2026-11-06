# Runtime locating experiments

These options are opt-in worker experiments. They do not change Velora's app
settings, model or engine dependencies. The implementation was built against
the existing verified llama.cpp pin, and CPU protocol/argument/helper checks
passed. Those checks do **not** establish GPU correctness or speed. The parent
benchmark owns all model loading and serial GPU qualification.

## Options

Append these after the worker's five positional startup arguments:

| Flag | Hypothesis / behavior |
| --- | --- |
| `--draft-max=N` | Verification length 1..8, default 3; 1 uses scalar decoding. Alignment still uses a 3/2-token suffix. |
| `--recurrent-rollback` | Requires copy drafts and N>=2. Reserve N-1 upstream recurrent snapshots and truncate rejected draft suffixes on device, replacing host serialization and accepted-prefix replay. |
| `--direct-argmax` | Scan the returned float logits directly, avoiding the standalone upstream sampler's temporary vocabulary-sized `llama_token_data` allocation/fill. Retains strict greater-than, first-index tie behavior. |
| `--backend-sampling` | Attach a persistent upstream greedy sampler chain to sequence zero, read backend sampled-token outputs, and accept only committed output tokens. Fails if a sampled token is unavailable. Cannot combine with direct argmax. |
| `--backend-token-only` | Requires backend sampling. Append a stateless metadata filter after greedy that retains the sampled token and suppresses unused logits/probability/candidate readback. Does not change argmax kernels or output-head computation. |
| `--trace-runtime` | Add per-request CPU-clock spans and decode batch-size counts; does not insert additional GPU synchronization. |

Worker `ready` reports the selected modes, effective recurrent snapshot count,
draft maximum, sampler output reserve, and trace flag. Backend sampling reserves
at most N output slots per sequence (one without copy drafts), matching this
worker's actual output demand. Upstream defaults the per-sequence cap to one,
so increasing it is required for batched verification with backend sampling.
Copy statistics also report cumulative serialized
snapshot bytes. Existing worker default policy is unchanged.

The plain backend greedy flag is an argmax experiment: upstream preserves
`data.logits` after selecting a token, then extracts it through
`t_sampled_logits`. It can still copy full vocabulary logits. Token-only mode
is a separate ablation, implemented by the independently authored
`backend_output_filter.h`, without modifying upstream source or kernels.

The filter clears `data.logits`, `data.probs` and `data.candidates` only after
the preceding greedy sampler supplies `data.sampled`. It retains diagnostics
when no token was produced; the worker then fails with
`backend_sampling_unavailable`, without falling back to CPU logits. The
sampled tensor still depends on the full GPU output-head calculation. Removing
its host outputs does not remove that calculation or promise a speedup.

For each backend token read, token-only mode checks the upstream copied-element
counts for logits/probabilities/candidates and rejects nonzero counts as
`backend_token_only_output_leak`. These bookkeeping accessors execute after
the sampled-token accessor's existing completion wait. They add CPU calls but
do not enqueue GPU work. Result metadata reports `backend_sampling.enabled`,
`token_only`, `sampled_tokens` and `filtered_rows_checked`; a successful
token-only request must have a nonzero sampled count equal to the checked
count. These are observed sampled rows, not a claim that every computed
verification row was consumed. The comparison runner verifies this evidence.

## Why device rollback is bounded

Each proposed batch has at most N tokens and remains inside one 128-token
ubatch. The first proposal must equal the target token sampled before the
batch, so at least one token is accepted. A mismatch therefore removes at
most N-1 trailing positions. The worker calls
`llama_memory_seq_rm(memory, 0, position + accepted, -1)`, checks both its
success and the new maximum position, then decodes only the corrected target
token. It never asks to roll back an entire batch or mutate shared sequences.
There is only one sequence. Failed truncation ends the request and clears all
live state; it cannot fall through to sampling corrupted state.

The context must report exactly N-1 enabled recurrent snapshots. Startup fails
if the architecture clamps that count to zero. This flag is intended for LFM3
and Qwen3.5 hybrid models; a plain Qwen3 transformer is rejected by this gate.
Per-token state storage adds work and memory even when proposals are accepted,
so this remains an empirical tradeoff, especially for larger Qwen recurrent
states. The baseline host-serialization path remains available.

Primary source evidence at the pinned revision:

- [Architecture rollback allowlist](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-arch.cpp#L1393-L1412)
  includes LFM3 and Qwen3.5.
- [Recurrent rollback validation](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-memory-recurrent.cpp#L166-L223)
  requires an unshared cell, a single pending rollback and the current
  ubatch's snapshot range. `rs_max` is set from the actual ubatch token count.
- [Convolution snapshot stores](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-graph.cpp#L4033-L4098)
  retain recent per-token convolution windows. This is materially different
  from retaining only attention KV positions.
- [PR 31368](https://github.com/ggml-org/llama.cpp/pull/31368) describes the
  last-ubatch bound; the pinned source has the `rs_max` guard.
  [Issue 26695](https://github.com/ggml-org/llama.cpp/issues/26695) reports
  whole-last-decode rollback returning success without restored state; this
  experiment explicitly avoids whole-batch rollback. Neither a code guard
  nor a success return substitutes for target-token parity testing.
- [CPU and backend greedy sampling](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-sampler.cpp#L896-L1100)
  show the temporary CPU candidate buffer and backend `ggml_argmax`.
- [Sampling graph construction](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-graph.cpp#L4364-L4458)
  preserves sampled logits; [extraction](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-context.cpp#L2356-L2364)
  copies them along with tokens. Metal argmax itself can use multiple
  dispatches for a large vocabulary, so moving selection to the GPU is not
  automatically faster than a direct CPU scan.
- For token-only mode, the same graph constructor leaves
  `t_sampled_logits/probs/candidates` rows null after the filter clears them.
  [Host row extraction](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-context.cpp#L1949-L2001)
  skips null tensors; `needs_raw_logits` returns false because the only
  sequence has a registered backend sampler. Thus both raw-logit and sampled
  logit readback paths are bypassed. The copy-count vectors are reset before
  decoding and expose actual copied element counts.
- The filter uses a process-lifetime vtable, null context and no retained
  tensor pointers. Its CPU apply operation is a no-op. Upstream's
  [clone/free implementation](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-sampler.cpp#L404-L440)
  supports null-context samplers without custom clone/free hooks. Chain
  ownership frees each sampler; the worker destroys its context before the
  borrowed chain. CPU selftests exercise clone/free and both filter branches.

## Reading the trace

`decode_submit` includes batch creation, graph construction/dispatch and any
waits that upstream already performs. It is not GPU execution duration.
`sample_wait_inclusive` includes waiting for prior GPU work and reading a
sample, plus CPU sampling when selected. `cpu_argmax_only`, available with
direct argmax, begins after logits become available. Snapshot-save/restore
spans include upstream synchronization and serialization.

`prefill_submit_inclusive` contains its decode spans;
`rollback_replay_submit_inclusive` contains its replay decode span. Do not add
these nested spans to their children. No span identifies pure GPU time.
Tracing allocates small host metadata and reads clocks; measure trace-off
latency for the actual speed comparison. Run a Metal System Trace only after
these spans identify the relevant phase.

## Cheapest decisive measurement sequence

1. Same binary, model file/hash, tokenizer, template and public inputs: run
   baseline scalar, copy3, and copy3 plus direct argmax. Include failures in
   latency and compare prompt IDs, output IDs, text and termination status.
2. Run copy3 plus device rollback, then combine with the winning sampler.
   Inspect acceptance, rejected suffixes, serialized bytes and forward tokens.
   Test both immediate partial mismatch and long accepted runs. Repeated
   input, cancellation, changed system and context-error recovery must match.
3. With rollback fixed, sweep N=2,3,4,6,8. A larger batch can save forwards
   while increasing rejected work, output-head work, temporary state and
   kernel latency. Plot elapsed time against accepted tokens per forward,
   not just tokens per second. Check near-output-limit requests and target EOS
   at every mismatch position. Every batch shape needs parity checks.
4. Retain only repeated same-model wins, then run the user's independently
   qualified recordings through recognition, production cleanup prompts,
   guards and postprocessing. Report audio recognition, cleanup and total
   separately. LFM3's short-prompt public fixtures cannot establish a win for
   the shipped Qwen3.5-4B 8-bit path or microphone-to-paste experience.
5. If substantial time remains between useful GPU kernels, inspect command
   buffer/encoder scheduling and pursue narrow fused normalization/gating or
   output-selection kernels. Attempt an entire persistent decode kernel only
   after the model and quantization are settled and a trace demonstrates
   dispatch overhead large enough to justify maintaining a model-specific
   implementation.

MLX's C++ API and shared-memory array model make a native implementation
possible, but do not by themselves remove per-layer GPU work. Existing MLX
weights preserve the current quantization and can make a same-artifact
experiment easier. A GGUF Q8_0 comparison changes quantization and must not be
presented as a backend-only result. See [MLX's primary documentation](https://github.com/ml-explore/mlx#readme).

## CPU-only validation

```sh
python3 native/cleanup/test_protocol.py /tmp/velora-native-research/build/velora-cleanup-native
python3 native/cleanup/experimental/test_runtime_flags.py /tmp/velora-native-research/build/velora-cleanup-native
```

The worker helper selftests cover argmax ties/negative values, experimental
bounds, trace enablement and the extended draft cap. The flag test uses a
nonexistent model so accepted arguments fail before backend initialization.

## Public64 ablation runner

`run_ablations.py compare` reads existing result files without inference. Its
comparison includes status, accepted text, diagnostic partial text, complete
prompt/output token IDs, model/template/binary/data identity, row order, and
the stored state-recovery outputs. Missing and duplicate rows are failures.
The known `public-holdout-052` length ceiling remains in all-attempt timings;
reproducing it exactly can pass **relative runtime parity**, while model
qualification and semantic-quality evaluation remain false.

```sh
python3 native/cleanup/experimental/test_run_ablations.py
python3 native/cleanup/experimental/run_ablations.py compare \
  --baseline /path/to/immutable-baseline.jsonl \
  --candidate /path/to/ablation.jsonl --out /path/to/new-comparison.json
```

For a reserved GPU window, `run` launches the existing benchmark serially,
with a fresh worker process for each variant. It requires the exact baseline
binary and public64 data hashes, checks the baseline files before/after each
run, refuses existing output directories, and acquires
`/tmp/velora-bench.lock` without waiting. It records process failures, partial
results, missing rows, counters and trace totals in an incrementally written
summary. A failed candidate does not erase other candidates' results.

```sh
python3 native/cleanup/experimental/run_ablations.py run \
  --baseline /path/to/immutable-baseline.jsonl \
  --binary /tmp/velora-native-research/build/velora-cleanup-native \
  --model /path/to/the-same-model.gguf --sha256 MODEL_SHA256 \
  --data training/cleanup/evaluation/public_holdout_v1.jsonl \
  --out-dir /path/to/new-matrix --trace-runtime
```

Defaults run direct argmax, rollback, draft sizes 2/4/6/8, backend sampling,
and `backend_token_only`
as separate ablations against copy3. `--variants` accepts a comma-separated
subset plus `copy3`, `rollback_direct`, and `rollback4/6/8` combinations.
`--repetitions 2` reverses the second repetition's order. An older fixed
baseline alone does not control host drift; include fresh copy3 controls and
repeat promising variants with tracing disabled. Different tracing settings
are explicitly ineligible for speed comparison. The benchmark's post-cancel
probe currently checks EOS, while stored system/context recovery probes also
support exact token/text comparison; the runner does not invent an exact
post-cancel check absent from the underlying artifact.

## First locating trace

The public64 copy3 trace on 2026-11-06 took 10,181.01 ms summed worker time.
Snapshot save took 45.27 ms across 395 calls and restore took 17.67 ms across
36 calls: 0.62% of summed worker time. Saves serialized 1,643,307,684 bytes in
total. This demotes host snapshot serialization as a major latency explanation
for this LFM3 workload; Qwen's larger recurrent state still needs its own
measurement. Device snapshots can themselves add GPU work.

The same trace reports 9,151.34 ms across 2,179 sample-wait calls, and 843.08 ms
in decode submission. Waiting includes model execution. These numbers do not
establish that CPU sampling dominates or that a custom persistent Metal kernel
would recover most latency. The direct-argmax comparison is the cheapest
next separation. Source artifacts are local under
`.context/compound-engineering/ce-optimize/cleanup-push-v3/native-baseline-trace.jsonl`
and `native-trace-attribution.json`; no personal input was used for this trace.

## Maintenance and licensing

The experiments use pinned public llama.cpp APIs, including explicitly
experimental backend-sampler and recurrent-snapshot interfaces. Revalidate
them on every core upgrade; a successful build does not establish unchanged
snapshot or graph behavior. No upstream source was patched or copied into a
new kernel. llama.cpp/MLX runtime licensing is separate from model licensing.
The LFM artifact retains its LFM license. Phonon's application/kernel source
is GPL-3.0 and is not used here. An independently implemented megakernel
would require its own numerical, architecture, context-length and hardware
qualification rather than inheriting upstream support guarantees.
