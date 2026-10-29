# Cleanup latency and the MLX roofline

Not verified: the historical 963 ms TTFT cannot be reconstructed from its old
log fields. Native microphone-to-insertion tracing, idle watts, and several
days of real-use confirmation remain open. The traces below cover production
cleanup-worker replays, not a new microphone dictation in the native app.

**Keep MLX and the shipped 8-bit cleanup model. No lever passes.** Later decode
runs fall below the 60% comparison threshold, but identical baseline work also
reaches 82%. The outside engine is slower, the core upgrade changes outputs,
and the remaining candidates fail timing or decision-quality gates. This does
not prove that MLX has no remaining overhead. It rejects a replacement on the
measurements available here. The population target, p50 <1 s and p90 <2 s, is
not met.

## The 963 ms TTFT gap

Every `cleanup inference` line was parsed. The snapshot has 4,240 records;
2,423 include `input_tokens`. Of those, 1,961 have at least 20 output tokens,
four more than the starting snapshot.

| Complete calls with ≥20 output tokens | p50 | p90 |
| --- | ---: | ---: |
| Total | 1,744 ms | 5,520 ms |
| TTFT | 963 ms | 4,305 ms |
| Decode | 706 ms | 1,391 ms |
| Output tokens | 52 | 83 |

The uncached suffix has p50 150 tokens. Prefix hits are 88.0% in this cohort
and 77.5% across all complete records. The starting 78% and 963 ms describe
different populations. Effective decode is p50 66.3 tok/s using
`(output_tokens - 1) / decode_time`. Old records do not count copy drafts or
host load, so that rate cannot establish decoder efficiency.

New low-load replays attribute p50 294 ms TTFT: 259 ms exact prefill,
16 ms first forward/synchronization, 3 ms prompt tokenization, and a per-call
residual p50 of 6 ms. Cache-container restore takes 0.31 ms across the whole
request. It cannot explain hundreds of milliseconds.

A primed cold/warm trace puts **94 ms of additional idle-associated delay
inside exact prefill** after ten seconds without worker inference. First-token
synchronization and decode stay approximately unchanged. That is one measured
pair, not an explanation of the entire historical 963 ms. The difference
between the old median and the new replay median remains unattributed.

## Controls and evidence

M4 Max, 14 CPU cores, 36 GiB unified memory. Baseline: `mlx==0.31.2`,
`mlx-lm==0.31.3`, `transformers==5.3.0`, Python 3.12.14, from the repository
lock/environment. The installed app uses Python 3.14 with the same MLX versions;
interpreter parity was not tested.

Velora was quit. A single `fcntl.flock(LOCK_EX)` on
`/tmp/velora-bench.lock` covers each entire A-B-B-A matrix, including startup
and teardown. Each of the six levers had one `gpt-6.1-sol` agent, its own
scratch directory and environment, and the shared replay script. No worktree
was created. Host load varied sharply. Some early upgrade measurements also
overlapped a Swift build; those timing results are ineligible. Later tests and
measurements were serialized. Unrelated desktop GPU activity appears in the
system trace; Velora being quit does not make the entire GPU exclusive.

`benchmark_cleanup_latency.py` opens history with SQLite `mode=ro` and
`PRAGMA query_only=ON`. It selects recent historically cleaned takes with
100–1,800 raw characters. It uses production `CleanupProcess`, gates, current
mode/prompt construction, prefix preparation, greedy sampling, copy-draft
eligibility, divergence guards, and postprocessing. Settings are copied to a
temporary directory so `Config` cannot migrate the owner's files.

These replay current prompts; history does not preserve every historical
prompt or app observation. The explicit ten-second timeout separates model
output from timeout fallback; production's adaptive timeout is unchanged.
The bounded sample favors longer recent takes and is not a population estimate.

[Portable review](2026-10-29-cleanup-latency-roofline/review.html) uses the
existing Velora site colors and Instrument Serif, with no remote assets. It was
exported locally with Lavish; no page was opened or published.

[Evidence](2026-10-29-cleanup-latency-roofline/) contains per-request load1
before/after, durations, allocation counts, immutable model IDs and output
hashes. Generated-text hashes precede guards, so returning raw text cannot hide
a model-output change. Earlier exploratory rows have only final-output hashes.
No owner transcript, prompt, generated text, trace environment, or raw trace
is committed. Full traces and disposable prototypes remain under
`/tmp/velora-latency-20261029`.

## Hardware bounds

`benchmark_mlx_roofline.py` forces an MLX contiguous copy from a padded row
view: 1 GiB read plus 1 GiB written per iteration, beyond the system cache.
Three warmups precede 20 synchronized samples. Median read+write bandwidth is
**277.4 GB/s**, load1 6.92. This measures copy throughput on this Mac.

Safetensors headers supply stored bytes. Text decode excludes vision and MTP
tensors. Counts include quantized weights, scales, biases, norms, and the tied
output embedding. The embedding's full output projection is counted once.

| Shipped model | File payload | Text bytes/token¹ | Bandwidth bound | QMM, M=150 |
| --- | ---: | ---: | ---: | ---: |
| Qwen3.5-2B 4-bit | 1.722 GB | 1.059 GB | 261.9 passes/s | 7.25 TFLOP/s |
| Qwen3.5-4B 4-bit | 3.034 GB | 2.367 GB | 117.2 passes/s | 8.02 TFLOP/s |
| Qwen3.5-4B 8-bit | 5.137 GB | 4.470 GB | 62.1 passes/s | 8.05 TFLOP/s |

¹ One ordinary decode token requires one model pass. Copy-draft can produce
several tokens per pass; the column is bytes per model pass for that path.
It omits recurrent/KV state and activation traffic. Draft verification also
changes matrix shape and arithmetic intensity. The percentages below compare
weight traffic with the copy bound; they are not GPU-counter utilization.

QMM uses the actual first-layer gate projection, affine/group-64 quantization,
and bfloat16 inputs. FLOPs are dense-equivalent `2*M*N*K`. This single shape is
a reference, not a ceiling for every layer. M=1 results are 0.207, 0.346, and
0.317 TFLOP/s respectively; M=256 results are 8.58, 9.11, and 9.11 TFLOP/s.
All samples carry load1 in the evidence.

| Replay cohort, load1 <20 | Decode passes/s | % bandwidth bound | Accepted drafts/request | Prefill % QMM² |
| --- | ---: | ---: | ---: | ---: |
| 4B 8-bit, initial 2 s idle, n=32 | 50.8 | 81.9% | 47 | 38.6% |
| 4B 8-bit, later baseline arm, n=24 | 27.6 | 44.5% | 47 | 32.1% |
| 4B 4-bit, eligible individual rows, n=40 | 42.1 | 35.9% | 46 | 35.7% |
| 2B 4-bit, registry reference, n=8 | ≥195.7 | ≥74.7% | 0 | 47.3% |

² Projection elements come from the actual safetensors matrix shapes. Compute
`2 * (body_elements * prefilled_tokens + evaluated_head_elements) / seconds`,
then divide by measured M=150 QMM throughput. Cache-only batched prefill
does not evaluate the output head for every token. Exact prefill evaluates
the final one-token head once; stock prefill callbacks exclude that final step. Attention, DeltaNet, normalization and
scheduling add work absent from that numerator. Stock streaming and copy-draft
use their existing synchronized prefill boundaries. The 2B run measures the
shipped registry option; it is not a new default-model quality bakeoff. Its
decode rate uses delivered non-EOS tokens after the first as a lower bound;
stock streaming can also evaluate EOS/lookahead work not counted here.

Cohort load ranges are 5.55–9.43, 7.84–17.04, 13.01–19.26, and 7.86–8.55.
The 4-bit rows are diagnostic samples filtered individually by load, not two
qualifying complete ABBA repetitions.

The later baseline has the same input/output hashes, prefix lengths, draft
counts and model-pass counts as the initial baseline. Decode still nearly
doubles on several takes. Decode dominates p50 in both cohorts, so the later
44.5% observation admits an outside-engine comparison under the stated rule.
It does not isolate MLX software overhead from dispatch shape, GPU power state,
thermal behavior or other GPU work. Selecting only the initial 82% result would
hide this variability.

## TTFT and socket attribution

The initial baseline matrix repeats eight takes in four blocks: 32 requests,
load1 5.55–9.43, identical final-output hashes. Each prefix is prepared before
a two-second idle interval; no keep-warm tick runs.

| Existing work, no extra GPU synchronization | p50 |
| --- | ---: |
| Exact prefill, including its existing completion wait | 259.1 ms |
| First copy-draft forward and existing `argmax.tolist()` wait | 16.3 ms |
| Prompt tokenization | 3.3 ms |
| All cache restore calls | 0.31 ms |
| Parent socket RTT minus worker duration | 0.81 ms |

Raw tokenization is 0.31 ms; deterministic postprocessing is below 0.3 ms.
The p50 residual after prefill, first forward/sync and prompt tokenization is
6.3 ms. Nested spans are inclusive; do not add runtime-prefix or restore spans
to their containing prefill/request spans. Socket RTT includes worker execution.

Total p50 is 1,219.5 ms; decode p50 is 931 ms. Delivered decode reaches
102.1 tok/s while actual post-first model passes reach 50.8/s. Accepted drafts
and emitted tokens are counted separately. Rejected drafts can replay pending
tokens; `copy_draft_model_input_tokens` counts that work too.

### Cold and warm Metal traces

A targeted `Metal System Trace` recording attached to the production cleanup
worker and exported successfully. The same take followed ten seconds idle and
then no idle: TTFT 242 →103 ms, exact prefill 202.8 →79.5 ms, first forward
15.6 →15.9 ms, total 476 →333 ms; load1 4.45–4.57. This first pair conflates
first use of a suffix shape with idling.

A second recording primes the exact same take before the idle interval:

| Stage | Idle | TTFT | Exact prefill | Total |
| --- | ---: | ---: | ---: | ---: |
| Prime | 0 s | 102 ms | 79.5 ms | 335 ms |
| After idle | 10 s | 196 ms | 171.8 ms | 431 ms |
| Immediate repeat | 0 s | 102 ms | 77.6 ms | 337 ms |

Load1 is 4.38 for prime and 4.72 for both measured repeats. Prefix, input,
model-pass counts and both output hashes match. First-forward waits are
16.3/17.0 ms and decode is 234/235 ms for cold/warm. The extra 94 ms is inside
prefill's existing evaluation/wait boundary. The first worker GPU interval
after the idle period has 68.7 ms CPU-to-GPU latency; the maximum in the
cold/warm burst is 108.5 ms. Those intervals include encoding, dispatch and
queueing; they do not isolate hardware clock wake from host scheduling.
The trace evidence retains these numeric observations.

The earlier all-process recording failed to finalize/export and is excluded.
The successful recordings contain worker replays, without Swift signposts.
The new native `StopToFinal`/`StopWritten` signposts compile, but were not
observed in a new native dictation. Whisper co-residency, capture drain,
main-queue delivery and insertion remain outside these replay measurements.

## Lever results

Positive gain means lower duration. The table reports pooled A/B p50, with
per-take matched ratios stated separately where they differ. Load eligibility
applies to the entire repetition, not a favorable subset. Every accepted
candidate would still need a second qualifying repetition and multi-day use.

### Cleanup candidates

| Candidate | Measured result | Gate |
| --- | --- | --- |
| GPU tick every 0.5 s | At 10 s idle: total 760.5 →762 ms; TTFT 221.5 →213 ms, load1 4.64–6.21 | No 30% gain; idle watts unverified |
| MLX 0.32.4, old mlx-lm | 3/16 greedy outputs change in both repeats | Reject pure-speed change |
| MLX 0.32.4 + mlx-lm 0.32.2 | With cache adapter: total 648 →669 ms; TTFT 132.5 →141.5 ms, load1 5.50–5.76 | No gain on four takes; no extension |
| 4B 4-bit | Total 2046 →1532.5 ms, then 1995.5 →1528.5 ms: 25.1%/23.4% apparent gains | Both runs cross load20; decisions regress |

The two-second-idle tick matrices have 96 requests, identical final hashes,
and no added MLX allocations: active max 4.903 GB, peak 5.412 GB in both
arms. Pooled total changes are −13.3% and −6.5%; matched TTFT changes are
−3.4% and +3.4%. Load reached 90.3/29.4, invalidating both repetitions.
The low-load ten-second probe also matches raw greedy hashes; its per-take
median TTFT gain is 6.5%, total 2.0%. Privileged `powermetrics` was unavailable;
no idle-watt claim is made, and the tick is not approved.

The core-only upgrade's three output differences are stable within each arm.
Among the 13 unchanged cases, apparent matched total gains are 18.4%/11.9%,
TTFT −6.6%/−4.0%; loads reached 117.8. Max active allocation is unchanged;
peak grows about 16 MB. Output differences alone reject this lever.

The full upgrade initially fails because upstream `ArraysCache` no longer
has `meta_state`; those zero-duration fallbacks are failures. A scratch adapter
preserves arrays, padding, lengths and KV offsets using the new state API.
CPU isolation checks pass. The corrected low-load matrix has identical greedy
and final hashes on all four takes, but matched total/TTFT gains are
−1.2%/−3.1%. Active max is 4.886 versus 4.889 GB; peak adds 22 MB.
`transformers>=5.7` also conflicts with the current `<5.4` constraint.

For 4-bit, current unchanged quality checks reproduce **1/27 failures in both
models**, the same `mismatched_ordinal_counted_list` case. Decisions fall from
56/62 to 55/62: new `route-14` and `header_ok-9` misses, while `header_ok-4`
is fixed. Cleanup replay output changes on 11/12 takes, expected for this
quality-affecting candidate. Max active MLX allocation falls 4.903 →2.801 GB.
The quality runner's post-inference physical footprint falls 5.670 →3.555 GB.
It saves memory, but fails unchanged decisions and the timing threshold.
Quality/decision scripts were not edited; their timings are not used as ABBA
latency evidence.

### Cache and engine candidates

| Candidate | Measured result | Gate |
| --- | --- | --- |
| Cheaper cache restore | Selection 120.46 →95.67 µs; valid round total 1982.5 →2062.5 ms, TTFT 327.5 →300.5 ms | No 30% gain |
| Action prefix DeltaNet checkpoint | Existing implementation already snapshots convolution and recurrent state | No missing checkpoint to add |
| llama.cpp Metal Q8_0 | Initial two low-load repeats: total 1189.5 →4860 ms and 1212.5 →4752.5 ms | Slower; matched-prefix result below |

Restore's valid repetition has load1 7.84–13.12. Per-take median gains are
1.0% total and 1.4% TTFT. The second repetition reaches load71.8 and is
ineligible. All 64 requests apply; greedy and final hashes match. Peak MLX
allocation increases 35,848 bytes. Existing restore shares array handles;
the prototype only saves CPU container traversal.

Action Mode already passes prefix probes with `cache_scope="action"` from
`server.py`. `_extend_runtime_prefix_locked` snapshots the exact prefix.
Each Qwen `ArraysCache` holds both convolution and recurrent DeltaNet state;
attention uses `KVCache`. Restore creates fresh containers with shared
copy-on-write arrays. Decision prompts have a separate snapshot. A second
checkpoint would duplicate an existing feature. No new state or RAM is added.

llama.cpp v0.8.0, commit `8642541b255bfb5dc39cd351a178be09013a55d6`, uses Metal
and an immutable bartowski Q8_0 artifact. This is a different quantization from
MLX 8-bit; equal base-model identity does not guarantee numerical identity.
The adapter sends production chat-template token IDs through a local server
inside production `CleanupProcess`, retaining guards and postprocessing.
A server exists only in B blocks and is stopped before A. All four initial
replay outputs match before and after guards in both repetitions, load1
5.51–11.98. EOS token-count conventions differ by one.

The initial B adapter prepares no prefix outside the timer, unlike A. Its
numbers include that disadvantage and cannot isolate backend prefill speed.
A corrected variant prepares the exact 2,546-token production prefix outside
the request timer and verifies the server's `cache_n`. Pinned llama-server
produces one token even with `n_predict=0`; the strict zero-token preparation
attempt was rejected. The corrected variant discards that one preparation
token, then requests the exact prefix again. This is an integration difference,
not a claim of identical cache internals. The corrected ABBA result is **1163 →2678 ms total**, 195 →276.5 ms TTFT,
and 756 →2276.5 ms decode at load1 ≤9.23. Both arms reuse 2,546 tokens on
every request; all 16 pre-guard and final hashes match. It is 130.3% slower.
Server peak RSS is 5.299/5.373 GB, a proxy rather than physical footprint.
A second corrected repetition is unnecessary after this loss.

Separate locked `llama-bench` runs complete two ABBA rounds over prompt shapes
512 and 3,072 tokens, each with 128 decode tokens; these A/B labels are shapes,
not backend comparisons. At load1 ≤15.20, prefill is 817.7–968.0 tok/s at
512 and 572.9–594.8 tok/s at 3,072; decode is 30.35–33.53 tok/s. Full process
footprint parity is unverified; the initial server RSS proxy peaks at 5.194 GB.

## Upgrade sources and build cost

Checked primary sources: [MLX 0.32.4 release](https://github.com/ml-explore/mlx/releases/tag/v0.32.4),
[mlx-lm 0.32.2 release](https://github.com/ml-explore/mlx-lm/releases/tag/v0.32.2),
[quantized Metal dispatch](https://github.com/ml-explore/mlx/blob/v0.32.4/mlx/backend/metal/quantized.cpp),
and [Qwen gated-delta implementation](https://github.com/ml-explore/mlx-lm/blob/v0.32.2/mlx_lm/models/gated_delta.py).
The upgrade includes native gated-delta/packed-prefill paths, wider quantized
matvec dispatch, and split-K accumulation changes. Wider dispatch has
architecture/vector-count requirements; ordinary one-vector decode cannot be
assumed to use it. Qwen normalization epsilon also changes. Release notes do
not establish Velora output parity or speed.

The tick follows [oMLX PR #3974](https://github.com/jundot/omlx/pull/3974):
`mx.eval(mx.zeros((1,), dtype=mx.float32) + 1)` on the model executor while
loaded and idle. Its larger-model results on other hardware are not Velora
measurements. The September 28 notes report TensorFold refusing this tied-
embedding 4B, no MLX-beating engine on M4, prefill 65–130 ms, and unmeasured GPU
wake cost. Those historical bakeoffs were not repeated.

No handwritten Metal kernel or new C++ engine was started. Aggregate decode
below the weight bound does not identify one deficient kernel. A replacement
would require these recurring obligations before it could preserve behavior:

| Area | Build and maintenance obligation |
| --- | --- |
| DeltaNet and quantization | Match convolution/recurrent state, normalization and mixed attention; support MLX affine scales/biases or validate every conversion |
| Templates and tokenization | Preserve tokenizer versions, chat templates, thinking controls, EOS handling and control-token restoration |
| Cache lifecycle | Implement immutable snapshots, exact prefix extension, rollback and Action/decision scope isolation without duplicating gigabytes |
| Copy-draft | Preserve greedy verification, rejected-prefix replay, cancellation, token ceilings and accepted-token accounting |
| New model releases | Port each architecture/cache/quant format, then repeat output, quality, decision, memory and latency gates |

The measured outside engine loses even before charging this maintenance.
An extension needs a repeatable, isolated kernel/dispatch deficit and a
behavior-preserving improvement. Neither has been established here.

## Verification and next measurement

`make test` exits 0: Swift `selftest OK — 3751 checks`, pytest
`1774 passed`, `site checks OK`, `signing config tests OK`, and
`publish-release checks OK`. Swift compilation succeeds with existing warnings.
New tests cover request-local spans, exception cleanup, backward-compatible IPC,
copy-draft work counts, pre-guard hashes, stock-stream boundaries and the
disabled tracing path.

A direct pre-change versus instrumented ABBA confirms identical greedy/final
hashes on eight takes, 32 requests, load1 6.48–8.35. Its pooled totals are
1680 →2033.5 ms, but the original-control blocks themselves vary almost twofold.
Instrumentation overhead was not isolated. Detailed Python maps, hashes and
logs therefore default off; set `VELORA_TRACE_CLEANUP=1` for collection. The
replay script opts in automatically. Existing millisecond metrics are unchanged.

For a new replay matrix, quit the installed app and use the matrix entrypoint;
`--run` is an internal child and does not acquire the lock itself:

```sh
engine/.venv/bin/python engine/scripts/benchmark_cleanup_latency.py \
  --matrix /path/to/plan.json --output /path/to/new-results \
  --cases 16 --rounds 2 --prepare
```

A plan maps A/B to `python`, logical `model`, immutable `model_path`, optional
`adapter`, and `env`. Inspect `_latency_ns` and `_work_counts`. Native tracing
uses `StopToFinal` intervals and `StopWritten` events under `com.velora/Latency`.
Disconnect closes abandoned intervals. Instrumentation adds no MLX evaluation,
stream switch, sampler change or extra model call.

Shipped: no speed lever, dependency change, version bump or merge.

Verified: serialized replays, output/quality checks, roofline, worker Metal
captures and full local gate. Installed `/Applications/Velora.app` was
restarted. Its control socket reports
`app_running=true`, `engine_ready=true`, and `access_enabled=true`. The
headless check used `.build/debug/Velora --cli status --json`; the installed
`velora` symlink dispatched incorrectly, and its extra instance was stopped.

Pending: native stop-to-insertion trace, idle-watt measurement, and multi-day
engine.log evidence. Review the trace and lever tables in this PR before
choosing the next measurement.
