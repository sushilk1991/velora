# Inference results and remaining work after the English continuation

The initial six-hour exploration window ended with the copy-anchor prototype deferred. The user authorized continuation at 09:39 UTC, with no additional training. That continuation produced runtime and quantization results: **the copy-anchor variant missed its registered speed threshold, calibrated Q4 tied the development gates, and naive Q4 was retained.** Neither experiment changed the installed app model or promoted new native code. [Copy-anchor result](copy-anchor.json), [quantization decision](quantization.json).

The remaining priority is faithful owner dictation and retention of mode instructions, followed by attribution of the actual remaining inference cost. Faster completion alone does not resolve either requirement. Long-note generation also remains unqualified.

## The qualified comparison used student-header caching OFF

Selected G's naive-Q4 headerON development arm reached EOS on 191/192 cases: one case hit its deadline. Its two output-reference errors were the incomplete-output and mismatch reports for that same case. The composite recovery flag included the all-EOS requirement; individual cancellation and after-cancellation checks passed. This did **not** establish a numerical or recurrent-state bug. Scalar and copy8/headerOFF completed 192/192 EOS with exact output parity, so the final comparison and the safety-derived continuation used headerOFF.

Ordinary system-prefix caching remained ON. The native owner arm used copy8, prefill batch 128, context 4096, a 512-token output ceiling and full-SWA allocation. The selected MLX stream arm used a 1024-token output ceiling and different decoding/deadline behavior. Their timing and quality differences are system-level observations, not isolated backend or quantization effects. [Actual runtime controls](final-performance.json).

Prior C header-cache results remain valid for that artifact and workload: at batch 128, the paired owner subset measured 206.03 ms OFF versus 133.27 ms ON, followed by full 614-case output/per-call-token parity. They do not automatically qualify new weights or request deadlines. The cache's exact token-prefix validation, sentinel-only construction and preserved batch boundaries are useful safeguards, but a future re-enable still needs the failed deadline case and full completion/recovery gates. [Prior header-cache evidence](../2026-11-07-lfm3-native-meetings/header-cache.json).

## Copy-anchor: parity passed, performance gate failed

The original first-token proposal remains a negative result. Only2/44 existing public traces had a unique exact raw-token anchor immediately after the first emitted token, below the registered 12-case locating threshold. It was not implemented or rescued with casing normalization.

The separately registered later-position rule was more applicable: only after at least two emitted tokens, and only when normal two/three-token matching produced no proposal, it allowed a globally unique exact last-token anchor. CPU replay found eligible opportunities in 34/44 cases, including 24/44 at the first missing ordinary-suffix point. Full prompt/draft-token identities and reconstructed baseline proposal/acceptance/rollback counts matched all 44. Those were locating observations, not a latency prediction.

The actual selected-G continuation then passed the 192-case old6b/new-OFF/new-ON development gate and exact prompt/output/text/status parity on the reversed 44-case comparison. It used the same artifact and headerOFF policy. The speed result was:

| Paired per-case two-repeat metric | OFF | ON |
| --- | ---: | ---: |
| p50 | 63.75 ms | 61.03 ms |
| p95 | 220.16 ms | 219.34 ms |

The p50 improvement was **4.2618%**, below the preregistered 5% minimum. P95 improved 0.3753%, and both order pairs favored ON, but neither substitutes for the failed primary threshold. The variant was not selected; no conditional 614-case candidate run was emitted and no native source was promoted. The actual continuation's conditional baseline was headerOFF, superseding the original plan's headerON wording. [Complete numeric result and report hash](copy-anchor.json).

The isolated implementation still preserves ordinary matching precedence, exact token identity, output/eight-token bounds, target verification and the 32 MiB snapshot cap. The independent Muse source audit found no verified blocking algorithm error, while retaining three caveats: counters may increment before a later decode/restore failure, OFF adds metadata and is therefore not byte-identical JSON, and CPU helper tests do not execute model rollback/cancellation. Successful EOS and recovery evidence—not failed-request counter totals—supports exercise claims. Target verification also does not itself guarantee identical finite-precision behavior after batch-shape changes; the executed parity gates provide the evidence for this workload. [Leviathan et al., ICML 2023](https://proceedings.mlr.press/v202/leviathan23a.html).

## Calibrated Q4: valid coverage, no development improvement

Activation collection used 163 approved public TRAIN examples, rendered to 32,899 tokens, with 64 complete 512-token chunks covering 32,768 tokens. No development, fresh-challenge, owner or audio examples supplied calibration activations. All 153 intended block projections passed coverage; temporal-convolution kernels and output/embedding collection remained outside that scope. [Calibration and coverage](quantization.json).

Ten warnings concerned nonfinite derived cross-layer statistics. The raw importance energies/counts passed their numeric checks. In this pinned implementation, the loader reads `.in_sum2` and `.counts` for the quantizer, with optional `.in_sum`; it does not consume the diagnostic `.stats` tensors. The quantizer normalizes the collected sums by their counts. The warnings therefore were not silently treated as valid importance values or filled with invented positive energies. [Pinned loader](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/common/imatrix-loader.cpp#L120-L183), [quantizer normalization](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/tools/quantize/quantize.cpp#L195-L215).

The naive and calibrated artifacts had matching names, shapes and storage types for all 287 tensors: 133 F32, 136 Q4_K and 18 Q6_K. The only missing-importance log entry was the intentionally excluded token embedding; there were no unexpected missing entries or dimension warnings. Matching storage policy establishes a controlled format comparison, not identical weights or quality.

The frozen development rule retained naive Q4:

| Supported development metric | Naive Q4 | Calibrated Q4 |
| --- | ---: | ---: |
| Complete supported cases | 185/185 | 185/185 |
| Strict required repairs | 32/43 | 32/43 |
| Exact no-edit cases | 83/86 | 83/86 |
| Protected literals intact | 79/81 | 79/81 |

Five supported outputs changed. Relative blind review covered those five plus 16 hash-selected controls: both arms had four material flags and one uncertain judgment, with no newly fixed or newly introduced material case. Other supported outputs were identical. This selected comparison is not an independent accuracy estimate. Because both strict metrics and relative material flags tied, the rule requiring improvement selected neither a new quantization artifact nor an owner/fresh evaluation of it. **Naive Q4 was retained.** [Selection evidence](quantization.json).

## Speed evidence does not establish a Phonon win

The final paired 96-case replay had 95 STT-successful cases, all with four available timings. Current4B/native/native/current4B ordering and per-case medians of two repeats produced:

| Cohort | Current4B p50 / p95 | Selected native p50 / p95 |
| --- | ---: | ---: |
| All 95 matched STT-successful cases | 524.34 / 3,790.75 ms | 256.86 / 1,146.83 ms |
| English 90 subset | 558.12 / 3,795.24 ms | 263.87 / 1,172.67 ms |

Finite failure/fallback/partial timings were retained; five cases in the95-case cohort had a non-OK status in at least one round. These are offline cleanup measurements, excluding capture, paste and model load. The full 614-case selected-native replay recorded 611 OK, one fallback, one partial and one STT failure; all 605 English cases had timing. Neither these latencies nor EOS prove semantic correctness. Physical footprint, RSS and MLX allocator observations remain separate and must not be summed or converted into a whole-app RAM claim. [Performance, denominators and resources](final-performance.json).

On the current public 44-case Phonon comparison, native p50 was 63.33 ms versus Phonon's 32.96 ms; linear p95 was 221.44 ms versus 205.16 ms. Each engine had two repeats in Phonon/native/native/Phonon order. A single blind model judge flagged four material errors in each arm; its fallible text references are not human/audio truth. The systems use different weights, quantization, prompts and warmups. Terminal examples force generation rather than the application's bypass. **Phonon remains faster on this diagnostic workload; this is not a backend-only comparison or a universal quality ranking.** [Matched44 evidence](phonon-matched44.json).

Older traces still do not explain that remaining gap. An earlier Q8/copy3 workload attributed only 0.618% of worker time to host snapshot save/restore. Its sampling-wait span included queued GPU completion, so it cannot be read as CPU argmax time. Existing sampler/readback ablations did not establish a repeatable gain. The pinned context already synchronizes logits access and attempts graph reuse. These facts justify profiling the actual remaining workload; they do not justify a custom kernel, removal of host snapshots, or a Rust rewrite without attribution. [Pinned logits access](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-context.cpp#L4495-L4502), [graph reuse](https://github.com/ggml-org/llama.cpp/blob/4b77dee0524c64b8471869232e2958bd9589607d/src/llama-context.cpp#L1691-L1711), [prior trace interpretation](../2026-11-06-cleanup-push-v3.md).

## Long notes: faster requests, unsuccessful summarization

The same frozen 56-minute transcript and hierarchical comprehensive policy produced 16 failed map chunks: 12 reached EOS and four hit their length cap, but **all 16 failed JSON validation**. Successfully mapped coverage was zero and no final notes were available.

Three corrected first-chunk prompt probes—plain JSON, student `note` JSON and student `note` bullets—all hit the 768-token limit. The bullets probe produced zero bullet lines and output character length equal to 91.3% of the source length. That ratio is a length observation, not a measured copying rate or semantic assessment. Earlier probes using invalid plural `notes` were excluded; the reported probes used the corrected singular mode. No successful full-hour follow-up was established. [Notes failures and probe scope](long-notes.json).

The separate fixed-prompt batch test completed 12 requests including warmups, with eight measured EOS outputs and exact response parity. Batch 128's full-request median was 4,865.00 ms versus 4,013.45 ms at batch 512, a 17.5037% reduction. This is full-request time, not isolated prefill or visible TTFT, and it does not qualify meeting summaries. Instruction retention and actual summarization behavior must improve before such a timing result can support a notes feature.

The next work should therefore address owner meaning regressions and mode/summary instruction retention, while preserving a fixed development selection boundary. Then profile the residual cost on the accepted artifact and workload before proposing another implementation change. Previous bounded-SWA and MLX rotating-cache full-output mismatches remain failures; first-token agreement does not reverse them. [Prior cache results](../2026-11-07-lfm3-native-meetings/prefill.json), [MLX full-output gate](../2026-11-07-lfm3-native-meetings/mlx-swa.json).

## Traceability

The retained isolated copy-anchor worker SHA256 is `4fc519ba242305a693663c244612b5597b65db8cd1d351836d899dc6e12183fd`; its patch is `dca4c283ccbdec5186fd88982e8a19f74c118dfe548d6bc20b2791658413e2ae`. The earlier first-token negative report remains `17275d0e1084cb4b4a777d8da7b4caaf0b73837a54ed709101d4f1e53af28c46`. Muse audit `20261107T055641-490fb699` is source review, not a substitute for the later runtime evidence.

The runtime pin remains llama.cpp `4b77dee0524c64b8471869232e2958bd9589607d`, source tree `9ed56cfe2f6554d6ff40e137b609e1f9e152bc58c9db0c9d51b87891bdf1bd0d`. Linked public aggregates preserve actual artifact/report hashes. No Phonon GPL application code was copied; runtime MIT and LFM model licensing remain separate. This note contains no owner examples or private corpus identifiers and makes no app-default, installation or release claim.
