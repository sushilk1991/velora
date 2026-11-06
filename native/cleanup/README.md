# Experimental native cleanup worker

This is an independently authored C++ token loop over the MIT llama.cpp/ggml math core and Metal kernels. It is not an HTTP proxy, does not invoke Python for inference, and does not copy Phonon's GPL implementation. It is isolated from Velora's shipped engine and defaults. The optional Python supervisor is process ownership/watchdog code; model evaluation and greedy token selection are C++.

Current status: **GPU comparisons passed output, token and status parity on all 64 public fixtures, including two fresh-process copy-draft comparisons.** Cancellation, system-cache invalidation and context-error recovery also passed. The base model reached EOS on 63 cases and its token ceiling on one, so model qualification still failed. The worker remains experimental and separate from the shipped app; measured results and limits are below.

## Why this backend

Primary source inspection on 2026-11-06:

- [llama.cpp at 4b77dee](https://github.com/ggml-org/llama.cpp/tree/4b77dee0524c64b8471869232e2958bd9589607d) includes `src/models/qwen35.cpp` and `src/models/lfm3.cpp` and supports Metal. Both target architectures are now upstream; older claims that LFM3 needs an unmerged patch are stale. This avoids a new tensor/kernel/model port.
- [MLX Swift LM 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) supports Qwen3.5 including compiled decode. Its LFM3 [PR 750](https://github.com/ml-explore/mlx-swift-lm/pull/750) and [PR 756](https://github.com/ml-explore/mlx-swift-lm/pull/756) remain open. Swift is a reasonable route for reusing existing MLX weight formats, but not the shortest maintained path for both candidates today.
- [mlx-rs at adf439b](https://github.com/oxideai/mlx-rs/tree/adf439bf5361d8a02955de7aaf651b0c45900945) has MLX tensor bindings and a Qwen3 implementation in `mlx-lm/src/arch/qwen3`; no Qwen3.5/LFM3 implementation was found in the recursive source tree. [Candle at cfcbd718](https://github.com/huggingface/candle/tree/cfcbd7186d13271843ce7eb41d25659bd0835850) has Qwen3/LFM2, including quantized variants, but no Qwen3.5/LFM3. A Rust native implementation is possible, but requires model work or C bindings to the same llama core. Zig can likewise call its C API. C++ gives direct supported access now.
- C++ MLX is a permissive math core, not an automatically available C++ implementation of all Python mlx-lm architectures. Porting Qwen/LFM and quantized loaders independently would add numerical-validation work before any performance evidence.

`UPSTREAM.json` pins source and model identities. The initial model is official LiquidAI/LFM3-1.7B-GGUF Q8_0, revision `cd0c74c575b5c416f3011b5b4c298077f26ca8c2`, 1,846,238,496 bytes, SHA256 `8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6`. Its weights use LFM Open License v1.0, distinct from runtime MIT. GGUF Q8_0 is **not** the existing MLX 8-bit artifact; runtime comparisons must disclose quantization/conversion and compare quality/output separately. A successful public student will need adapter fusion, a supported GGUF conversion and fresh quantization/quality qualification; this prototype does not load MLX adapters.

## Build without loading a model

The source tar from GitHub's pinned commit has SHA256 `f78d578b9a9246793e65917f7b3d0a567cb4f3aa349afe43f54576d623925d2a`. Prepared source is `/tmp/velora-native-research/llama.cpp`; build tools are in `/tmp/velora-native-research/build-tools/bin` (CMake 4.4.4/Ninja 1.13.2). Dependencies/build output remain outside the checkout.

For a new checkout, acquire the exact source first. CMake 3.22 or later, Ninja,
Apple's Command Line Tools and a usable Metal compiler are required. Existing
local CMake/Ninja executables can replace the prepared tool paths below.

```
git clone https://github.com/ggml-org/llama.cpp /tmp/velora-native-research/llama.cpp
git -C /tmp/velora-native-research/llama.cpp checkout 4b77dee0524c64b8471869232e2958bd9589607d
```

Download the model separately from the pinned repository/revision in
`UPSTREAM.json`, or use an already verified local file. Runtime has no model
downloader. A different model artifact needs its own SHA and qualification.

```
/tmp/velora-native-research/build-tools/bin/cmake -S native/cleanup \
  -B /tmp/velora-native-research/build -G Ninja \
  -DCMAKE_MAKE_PROGRAM=/tmp/velora-native-research/build-tools/bin/ninja \
  -DLLAMA_SOURCE=/tmp/velora-native-research/llama.cpp \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
/tmp/velora-native-research/build-tools/bin/cmake --build /tmp/velora-native-research/build --target velora-cleanup-native -j6
python3 native/cleanup/test_protocol.py /tmp/velora-native-research/build/velora-cleanup-native
python3 native/cleanup/test_supervisor.py
```

The compiled binary embeds Metal shaders and statically links llama/ggml. The backend's dependency implementation stays upstream; our source controls lifecycle, framing and inference. OpenSSL is disabled; our worker has no download or HTTP call path. Upstream common utilities are linked for the tested Jinja renderer, but no model acquisition APIs are invoked. Include upstream/transitive license notices if distributing binaries. `LICENSE.llama.cpp` is the pinned upstream license; SHA256 helper is public domain and nlohmann JSON is MIT.

## Protocol and ownership

Launch via `supervise.py BINARY LOCAL_GGUF SHA256`, optionally `--gpu-layers 99 --context 4096 --max-rss-mb 8192` (flags take separate values). Worker startup arguments set those bounds and cannot change per request. The model is SHA256-verified from a local regular file, maximum 4 GiB, before backend/model initialization, and loaded from the same open descriptor with mmap disabled. This prevents path substitution between hash and load, but assumes no other process writes to the open artifact while loading; use immutable verified snapshots. Hash/source/template/model metadata are reported, not inferred from filenames.

Stdout is JSONL only; diagnostics go to stderr. On success startup emits `event=ready` with model SHA, architecture, template SHA, tokenizer size, context budget and PID. The supported architecture allowlist is qwen3/qwen35/lfm3. Template must support the thinking toggle. Requests:

```json
{"op":"generate","id":"take-1","system":"Rewrite dictation faithfully...","user":"{\"mode\":\"default\",\"transcript\":\"hello world\"}","max_tokens":256,"deadline_ms":10000}
{"op":"cancel","id":"take-1"}
{"op":"ping"}
{"op":"shutdown"}
```

Use the exact frozen training renderer to produce `system` and `user`; the abbreviated example above is not the training contract. This keeps model policy outside the C++ worker. It renders the verified GGUF Jinja template with `enable_thinking=false`, then tokenizes and runs bounded prefill chunks of 128 tokens and a greedy single-token loop. It does not strip reasoning or reinterpret generated text. Full prompt token IDs and output token IDs are returned for tokenizer/termination comparisons. EOS is determined with the backend's vocabulary EOG set; max-token ceiling is distinct.

Result status is `eos`, `length`, `deadline`, `cancelled`, `memory_limit`, `context_limit`, or an explicit failure. Only EOS returns nonempty `text`; rejected/truncated output is diagnostic `partial_text`. The app must retain its original gated transcript and apply its own divergence/postprocessing/fallback. **Never use the JSON user payload as fallback text.** Parsed valid IDs are retained in input-error replies, allowing the supervisor to clear the right request and accept the next one.

Only one generation is accepted at a time; concurrent requests get `busy`, pre-readiness requests `not_ready`. Model stays loaded, but full KV/recurrent state is cleared before and after every request, including failures. Cross-request prefix reuse is off by default; the optional experiment is described below. Cooperatively checked deadlines/cancellation occur at prefill/decode boundaries and through the backend abort callback. Metal kernels may not be interruptible mid-dispatch; a cooperative check is not a hard deadline.

The supervisor supplies process-level deadlines: readiness 120 seconds, request deadline + 2 seconds, cancellation 2 seconds and shutdown 3 seconds. It uses nonblocking bounded input/output queues (2 MiB each), so a stalled worker stdin or unread client stdout cannot block the watchdog. It enforces one in-flight generation, treats unexpected live-worker stdout EOF as failure and terminates/kills/reaps its own process group. Tests deliberately use workers that ignore SIGTERM and never read stdin. Keep client stdin open until results arrive; EOF means cancel/shutdown.

Limits: 1 MiB per JSONL frame, system 16 KiB, user 64 KiB, output 512 tokens, context 4,096 tokens, model 4 GiB. RSS is checked in-worker and by the supervisor; it is a **process RSS ceiling**, not a guarantee about total unified-memory physical footprint or all Metal allocations. Limits may terminate a request after allocation pressure starts; measured physical-footprint qualification is still required. No model-size-to-RAM claim is made. Supervisor deadline test flags shorten startup/grace only for deterministic CPU regressions.

For this prototype, control-token-like `<|...`, `<think>` and `</think>` input is rejected until the production neutralize/restore contract is ported and tested. Other multilingual UTF-8 input remains intact. Prompt-token equality must be checked before any backend-only claim; the GGUF and MLX tokenizers can diverge despite the same model family. GGUF metadata inspected locally: architecture lfm3, GPT2 tokenizer, BOS 124894/EOS 124900, add_bos=false/add_eos=false. Metadata inspection did not initialize a model.

## Reproduce inference qualification

Run serially with other GPU experiments stopped:

```
PYTHONPATH=training/cleanup python3 native/cleanup/benchmark.py \
 --binary /tmp/velora-native-research/build/velora-cleanup-native \
 --model /tmp/velora-native-research/verified-model/LFM3-1.7B-Q8_0.gguf \
 --sha256 8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6 \
 --data training/cleanup/evaluation/public_holdout_v1.jsonl \
 --reference-tokens /tmp/velora-rapid-student/native-tokens.json \
 --out /tmp/velora-native-lfm3-public64.jsonl
```

Use `--limit 3` for an initial smoke test. The client performs one 1-token warmup, serial greedy requests, repeated-input state-reset checks, cancellation/recovery and teardown. Its latency includes JSONL/supervision; worker elapsed time is separate. It reports exact prompt mismatches, not silent equivalence. Physical footprint is sampled via vmmap after requests outside the timing region. A passing run will establish an operational prototype, not permission to replace production cleanup or general voice-edit/action/notes models.

CMake verifies every upstream source-file/symlink byte against the pinned source-tree SHA256 in `UPSTREAM.json`, excluding `.git` metadata. This works for both a checkout and the verified tarball used for this build. A different commit, dirty source or unexpected extra source file fails configuration; the existence of llama.h alone is insufficient. `verify_source.py` has no network operations. Dependency source should remain pristine; place all build products outside it.

### Review fixes and qualification accounting

The benchmark never substitutes `partial_text` for `answer`. Failed main requests remain in the full denominator with blank accepted text, diagnostic partial output and explicit status. Metadata reports expected/attempted/EOS/failed counts, status counts, all-attempt latency separately from EOS-only latency, and failed IDs. A one-token warmup may intentionally reach `length`; main requests must all reach EOS for runtime qualification. Repeated-input checks require two EOS results plus identical text/prompt/output tokens. Cancellation must actually return `cancelled`; recovery uses 256 tokens and must reach EOS. The client exits nonzero when runtime qualification fails. Runtime qualification is not semantic quality acceptance; guards and independent quality evaluation remain required.

The supervisor validates cancel IDs before lookup, locally rejects malformed IDs and remains usable. SIGTERM/SIGHUP/SIGINT request controlled owner shutdown; the owner kills/reaps its separate worker process group even when the child ignores SIGTERM. CPU regressions cover these paths without loading a model. Build-time source verification runs on every build, not only configuration; the reported commit is generated from UPSTREAM.json into build_pin.h, not duplicated as a hardcoded C++ string. `test_source_pin.py` verifies that modifying dependency source after configuration fails the next build and restores the source in finally.

Additional CPU checks:

```
python3 native/cleanup/test_benchmark_checks.py
python3 native/cleanup/test_source_pin.py \
 --cmake /tmp/velora-native-research/build-tools/bin/cmake \
 --build /tmp/velora-native-research/build \
 --source /tmp/velora-native-research/llama.cpp
```


### Optional static-prefix experiment

Add `--prefix-cache` to the supervisor or benchmark only for an explicitly reserved serial comparison. `--context 4096` is independently configurable within 128..4096. Default requests and baseline behavior are unchanged. Backend diagnostics default to warning/error; `--verbose` enables research debug logs. Benchmark metadata records binary SHA256, every prototype source hash, upstream pin and selected flags. Each result records cache hit/miss/fallback and snapshot bytes.

The cache has one immutable in-memory entry, capped at 32 MiB, and never caches completed text or a transcript-conditioned state. The candidate is the common token prefix of two independently rendered sentinel users (`A` and `中`), minus its final token. Exact token-prefix matching against every real prompt is required. Model SHA, template SHA, system SHA, context identity/settings and exact prefix tokens must all match. Different system instructions invalidate the entry. No state is persisted to disk.

The pinned upstream [hybrid-iswa sequence serializer](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-memory-hybrid-iswa.cpp#L196-L204) includes both attention KV and recurrent convolution state. Its host-buffer get/set functions synchronize the context. Logits are not serialized, so every request clears live state, restores the snapshot, then replays at least the final static-prefix token plus user suffix before sampling. A failed size/write/restore/position check discards the snapshot, clears live state and performs full prefill. An oversized snapshot also falls back. Live user state is cleared after every request, including cancellation and failure.

CPU selftests cover exact token boundaries, immutable entry identity, system/model/template/context invalidation, suffix-independent reuse and the byte cap. They do not prove model-state restoration or output parity. Splitting prefill changes kernel shapes and can change numerical results; compare full raw outputs, token IDs, termination, cancellation/recovery and limits against the uncached binary before retaining this experiment. No custom kernels are included.


Matched cache-off/cache-on runs used the same binary, GGUF and fixtures. The 69-token static snapshot occupied 2,195,716 bytes; every output/status/token sequence matched on all 64 cases. Median latency was 177.41 ms uncached and 169.63 ms cached. The same base-model fixture reached its token ceiling in both. System invalidation, cancellation and context-error recovery passed. Cache remains an explicit experimental option.

The additional copy-draft comparison was confirmed in two fresh-process pairs. With the same static-prefix setting, scalar medians were 170.75 and 169.39 ms; verified-copy medians were 107.61 and 107.32 ms, a 36.6–37.0% reduction. All 64 raw outputs, prompt/output token IDs and statuses matched in both pairs. Target forward calls fell from 2,167 to 1,441 in the first comparison. Recovery checks passed. The base model still had 63 EOS results and one length ceiling, so model qualification failed despite successful runtime parity.

These are text-generation measurements on an M5 Max with 36 GiB memory, not microphone-to-paste latency. Post-probe vmmap footprint was about 2.3–2.6G with a 2.6G peak; this is not a universal RAM requirement. GGUF Q8_0 differs from MLX 8-bit, so the controlled copy/scalar comparison is stronger evidence than cross-format backend rankings. See [the complete study](../../docs/research/2026-11-06-public-cleanup-student.md).

After the timed rows, the benchmark now changes the actual system suffix, requires a cache miss/rebuild when enabled, restores the original system and requires exact EOS/text/prompt/output-token recovery. It then deliberately exceeds the context budget and requires `context_limit` without accepted/partial output, followed by exact original-request recovery. These fixtures remain outside the timed 64 denominator and are recorded separately in `state_recovery`; any failure prevents runtime qualification.

### Optional target-verified transcript drafts

`--copy-draft` opts the worker/supervisor/benchmark into a three-token draft experiment; it defaults off independently of `--prefix-cache`. The optional JSONL request field `draft_text` accepts a string up to 64 KiB. The benchmark supplies the public row's raw transcript; the worker does not parse the policy JSON or treat it as fallback text. Draft text uses ordinary tokenization with special-token parsing disabled. Empty/no-alignment drafts use scalar greedy decoding.

The independently authored alignment helper looks for a 3- or 2-token output suffix in the draft source, prefers the next occurrence at/after a cursor, and proposes at most 3 following tokens. Proposals never bypass target verification: the first must match the greedy choice already available before the batch; each later token must match the target logits after its preceding proposal. All batch positions request logits. EOS remains target-controlled; draft EOS tokens are not accepted as proposals. No output is committed from a batch before verification and any required state repair.

Before each batch, the worker saves complete hybrid sequence state in request-owned host scratch capped at 32 MiB. A partial match restores the snapshot and replays the verified prefix plus the target's corrected token before sampling again. EOS or output-ceiling paths need no further logits and clear live state at request end. Snapshot unavailability/oversize disables drafts for that request; failed restoration produces an explicit failure followed by full live-state clear. Transcript-conditioned scratch is freed with the request and never stored in the static-prefix cache. Cancellation/deadline/context/output bounds apply to both paths.

Per-result `copy_draft` records proposed/accepted tokens, rollbacks, snapshot peak bytes, fallback reason, forward calls and processed tokens. Forward counters include prefill and rollback replay; accepted means target-verified, even if subsequent cancellation prevents committing that batch. Benchmark metadata sums counters without dropping failed rows. CPU selftests cover alignment/cursor selection, proposal bounds, exact-prefix verification and draft-field bounds. They do not validate GPU batch numerics. Compare all 64 raw outputs, statuses and prompt/output tokens, plus all recovery fixtures, against the same binary with drafts off before making any speed claim. Changed batch shapes can affect near-tied logits; this experiment is not an unconditional exactness claim across all inputs. No custom model kernels or GPL implementation are included.
