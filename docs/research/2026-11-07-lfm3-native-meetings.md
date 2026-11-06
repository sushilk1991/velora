# LFM3 fine-tuning, native inference, and long-meeting experiments

This study follows the [Phonon source audit](2026-11-05-phonon-efficiency-audit.md) and [complete personal-recording replay](2026-11-06-cleanup-push-v3.md). Three LFM3-1.7B fine-tunes produced a promising cleanup specialist. Native execution, copy decoding, and reusable prompt headers reduced its inference cost. The strongest new controlled result is a **35% median cleanup reduction from prompt-header caching on the paired 95-case latency cohort**, plus a separate exact-output-parity check on all 614 owner recordings. The model still adds meaning errors, and Phonon remains faster at the median on the matched English test. Keep the trained candidate experimental and retain the runtime improvement for further integration.

**Whisper Large-v3 Turbo and Qwen3.5-4B MLX 8-bit remain the installed production models.** This round makes no release or app activation. GPU experiments run sequentially on an Apple M5 Max with 36 GiB unified memory, using isolated model environments. Other apps remained open, and some exploratory runs overlapped CPU work; repeated controlled studies are identified separately below. Cleanup, recognition, and meeting-summary measurements have different endpoints; none is presented as microphone-to-paste latency.

**Three training recipes, with development-only checkpoint selection.** All recipes use `LiquidAI/LFM3-1.7B-MLX-8bit` at revision `4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099`. The experimental architecture port is SHA-pinned. [Training records](2026-11-07-lfm3-native-meetings/training.json) preserve dataset, adapter, base, and port identities, parameters, finite-gradient preflight results, and measured training resources.

| Recipe | Train / dev rows | Training time | Selected full-dev loss |
| --- | ---: | ---: | ---: |
| A | 1,242 / 362 | 511.8 s | 0.17364 |
| B | 1,476 / 362 | 664.2 s | 0.15229 |
| C, continued from selected B | 1,799 / 417 | 789.3 s | 0.14449 |

A and B share the same 362 development examples, so their development losses are comparable. C preserves those examples and adds 55 new development rows. Its loss must be compared with the initial B checkpoint evaluated on that same expanded set: **0.15829 for B versus 0.14449 for selected C**. Comparing C's 0.14449 directly with B's earlier 0.15229 would mix evaluation sets. Including initial B in C's checkpoint competition also avoids forcing adoption of a continuation that failed to improve.

All three use rank-16 LoRA, scale 8, accumulation of four, cosine learning-rate decay, 20 warmup updates, and gradient clipping at 1. A/B use learning rate `1e-5` and maximum sequence length 1,536; C uses `3e-6` and 2,048. Three recipes are the limit for this round. Checkpoint selection uses development loss, not final challenge or personal-recording results.

[Public pilot V5](../../training/cleanup/data/pilot_v5/README.md) contains 2,216 rows. Its 1,838 original rows retain their exact bytes, order, groups, and splits. Muse authored 384 additions: 128 targets for raw-only public Sotto inputs and 256 synthetic examples. Independent Terra review approved 382; curation retained 378 after duplicate exclusions. These add 323 train and 55 dev rows. Family/component hashing targets a 20% development allocation; it does not guarantee that fraction of individual rows. Sotto membership, source licenses, approval status, normalized duplicates, shared eight-word sequences, and train/dev bridges are checked. Original overlap with the frozen holdout is fatal rather than silently removed.

There are **zero personal-recording rows, podcast rows, or Qwen-teacher rows** in training. Review is model-assisted, not human certification. The fresh 96-case V5 challenge was independently authored and reviewed before C training; the exclusion union has 443 cases. Previously examined public tests and personal recordings remain regression evidence, not unseen generalization evidence.

**The fresh public challenge favors the specialist, with important limits.** [Blinded quality aggregates](2026-11-07-lfm3-native-meetings/public-v5-quality.json) cover 96 outputs per model. Muse reviewed all 384 outputs; Terra independently adjudicated 59 selected cases, covering 236 ratings. Second judgments replace first judgments only on that selected subset. There were 42 rating disagreements. These are fallible text judgments, not human listening or word-accuracy measurements.

| Model | Rated / supported judgments | Material errors | Introduced facts | Control errors |
| --- | ---: | ---: | ---: | ---: |
| C | 96 / 93 | 1 | 1 | 0 |
| B | 96 / 93 | 1 | 1 | 1 |
| Unadapted base | 96 / 93 | 16 | 11 | 33 |
| 4B under the common student prompt | 96 / 92 | 11 | 2 | 17 |

This public 4B arm uses the same student JSON prompt and the training MLX-LM 0.32.2 environment; it does not measure the installed 4B production prompt. Paired comparisons use jointly supported cases, not mismatched denominators. Against that common-prompt 4B arm, C has one versus 11 material errors on 92 jointly supported cases, with ten improvements and no additional material-error cases. However, the separate introduced-fact category includes one additional C failure and two improvements. Against B, all 93 jointly supported cases retain the same material-error and introduced-fact outcomes; C improves one control outcome. Lower development loss therefore does not establish broad quality superiority over B, and the remaining error must stay visible.

**The production-contract recording comparison is more demanding.** The [repeated 96-recording study](2026-11-07-lfm3-native-meetings/paired96.json) runs incumbent 4B, native C Q4, C MLX, then the reverse order. Each model has 192 attempts, with the same case IDs and input hashes. One failed STT case remains in the denominator; 95 have cleanup latency and 86 actually invoke the model, with nine controller bypasses. Per-case medians from two attempts give:

| Pipeline | Cleanup p50 | Cleanup p95 |
| --- | ---: | ---: |
| Production-contract 4B | 601.30 ms | 4,039.41 ms |
| C MLX 8-bit | 548.29 ms | 4,041.72 ms |
| Native C Q4 | 281.00 ms | 1,641.65 ms |

The 86 model-invoking cases give p50 values of 649.67, 620.54, and 289.08 ms respectively. Every available final text and every status repeats exactly within each model. Native prompt and output token IDs also repeat exactly; MLX token counts alone do not establish token-ID parity. Failures remain in the status aggregates. The first 96 recordings are a fixed regression sample, not a random population estimate.

**Native copy-eight improves the same trained artifact.** The [native-copy experiment](2026-11-07-lfm3-native-meetings/native-copy.json) uses one C Q4 GGUF, one binary, greedy decoding, and the fresh 96 cases. Order is scalar, copy-three with prefix caching, copy-eight with prefix caching, then the reverse. Each variant has two runs, 192 measured EOS results, exact output-token/status parity to scalar, and passing runtime qualification in both runs. The table summarizes the distribution of per-case medians.

| Native variant | Cleanup p50 | Cleanup p95 |
| --- | ---: | ---: |
| Scalar | 84.17 ms | 1,993.50 ms |
| Copy-three + prefix cache | 62.04 ms | 1,015.04 ms |
| Copy-eight + prefix cache | 48.17 ms | 476.68 ms |

Copy-three versus copy-eight changes draft size only: median cleanup time falls about **22%**. Scalar versus either copy arm changes both draft decoding and prefix caching, so its improvement cannot be attributed to draft size alone. These are warm text-cleanup measurements, excluding STT and GUI delivery. Comparing them with another model or MLX quantization would also change weights, prompts, or numerical execution; it would not prove that C++ universally beats MLX.

**Full personal coverage does not qualify a default switch.** All 614 recordings, approximately 4.59 hours, were replayed against frozen local STT; 613 have successful recognition and one fails recognition. The [complete native runs](2026-11-07-lfm3-native-meetings/native-private-performance.json) retain every attempt: Q8 has 602 successful, seven fallback, four partial and one STT-failed result; Q4 has 603 successful, five fallback, five partial and one STT-failed result. Exploratory cleanup p50/p95 is 307.92/1,750.40 ms for Q8 and 281.28/1,524.54 ms for Q4. These exclude recognition time and are separate from the counterbalanced study.

Only 303 recordings have approved model-assisted text references; 310 uncertain references and the failed recording are not silently treated as quality successes. The [final private quality review](2026-11-07-lfm3-native-meetings/native-private-quality.json) rechecks changed native outputs and controls, inheriting 225 ratings only when output, input, mode, status and context match. On the 255 cases supported across all four models, material errors are incumbent 7, C MLX 7, Q8 8, and Q4 6. Despite Q4's lower total, it introduces **five additional material-error cases** while fixing six. The larger jointly supported incumbent/Q4 pair has 256 cases, seven errors each, six additional and six improved cases. This is insufficient replacement quality.

These are fallible model judgments on a previously examined regression corpus, not human listening or unseen accuracy. Native variants can change earlier output and therefore later previous-piece context: system-prompt hashes match in 294/303 Q4 and 302/303 Q8 cases. This is an end-to-end decoder comparison, not a pure quantization experiment. The older `private-c-quality.json` records an earlier review wave and must not be mixed with these denominators.

**Reusable headers are the strongest new runtime change.** The opt-in `--student-prefix-cache` extends the existing system cache across stable student JSON metadata, stopping before transcript tokens. It preserves the old batch boundaries, verifies the actual token prefix, invalidates changed metadata, and falls back for previous-piece context or an unsafe header. Snapshots retain the 32 MiB cap. It does not cache arbitrary transcript text as trusted metadata.

The [header-cache experiment](2026-11-07-lfm3-native-meetings/header-cache.json) uses two reversed OFF/ON pairs per batch size on the same 96 recordings and binary. At batch 128, the 95-case cleanup p50 falls **206.03 → 133.27 ms, 35.31%**. At 512 it falls 154.90 → 135.64 ms, 12.43%; 128 is the selected short-cleanup setting. All native prompt/output IDs, final texts, statuses and inputs match across these runs. A subsequent full 614-case ON run matches the original native baseline across **all 760 native calls**, including fallbacks and partial results, with 375 header hits. Its single-pass p50 is 200.70 ms; do not turn that into a separate causal speedup claim. Maximum observed snapshot size is 13,559,240 bytes.

The promoted benchmark requires real header capture/reuse, recovery, bounded snapshots and exact full outputs against a matching OFF control. A 12-case public stress fixture passes; the short V5 challenge correctly fails feature qualification because it never exercises the header, despite exact output parity. The clean private CLI also completes its 96-case replay. The flag remains off by default and is restricted to the student contract. Gains from separate copy, header, batching and model studies must not be multiplied together.

**Memory savings are measured for the cleanup process.** [Memory aggregates](2026-11-07-lfm3-native-meetings/memory.json) record end-of-replay `vmmap` measurements while the model remains resident, plus process-lifetime peaks and MLX allocation counters.

| Cleanup process | End physical footprint | Peak physical footprint |
| --- | ---: | ---: |
| Current 4B, full replay | 5.5G | 6.2G |
| C MLX 8-bit, full replay | 2.1G | 3.5G |
| Native C Q4, full replay | 1.6G | 1.9G |

The native full-replay entry is in the native performance artifact. In the separate repeated 96-case study, end footprints are 5.4G/2.2G/1.9G for incumbent/C MLX/native. The `G` values retain `vmmap`'s reported units. These processes did not also hold STT. They are neither whole-app memory requirements nor minimum hardware recommendations, and model/runtime environments differ. RSS, physical footprint, active MLX allocations, and unused allocator cache are distinct measurements. Download size is not used as a RAM proxy.

**Larger prefill batches help the fixed long prompt.** The [full-SWA sweep](2026-11-07-lfm3-native-meetings/prefill.json) tests six native batch sizes with two counterbalanced rounds, a fresh worker per arm, one warmup, and three measured requests per arm. All 48 requests match prompt tokens and the single generated token; the measured requests stop at the deliberate one-token ceiling.

| Prefill batch | Median first decision, full SWA |
| --- | ---: |
| 16 | 12.033 s |
| 32 | 12.000 s |
| 64 | 6.624 s |
| 128 | 3.727 s |
| 256 | 3.054 s |
| 512 | 2.751 s |

Moving from 128 to 512 reduces this diagnostic interval about **26%**. Every arm processes the same prompt: this changes runtime batching, not semantic chunking or source coverage. First decision includes request preparation and waiting for the first sampled token; it is neither isolated prefill nor token-delivery TTFT. No completed-summary or full-output speed claim follows from a one-token run.

Full-output confirmation compares batches 128 and 512 in two reversed rounds, each with one warmup and two measured requests. All 12 requests reach EOS with exact complete output-token parity. Measured wall medians fall **5.240 → 4.366 seconds**, about 17%, on this fixed long prompt. This qualifies a batching improvement on that workload, not summary quality or all prompts. Short cleanup prefers a different batch, as the header experiment shows.

The bounded-SWA one-token sweep also passes, but its EOS confirmation changes complete output tokens across batches. Its lower memory is therefore not qualified as a lossless replacement. The first 16k synthetic recovery probe lacked copy/rollback coverage because the existing snapshot cap prevented that path. A rerun using the existing recurrent-rollback option exercises those paths through 16k and passes all synthetic checks without increasing the cap. This does not override the real long-prompt mismatch.

The [isolated MLX rotating-cache probe](2026-11-07-lfm3-native-meetings/mlx-swa.json) replaces only five sliding caches, preserving six global-attention and 13 convolution layers, with prefix/copy disabled. One-token boundary tests pass. Complete generation fails exact token parity in two comparisons despite reaching EOS, so this option is also rejected as a lossless default. No architecture-port or installed MLX dependency change is required by the retained native header improvement.

**Long-meeting coverage is a separate qualification.** The source is [Beyond Coding #191, Maurício Aniche on testing](https://www.youtube.com/watch?v=oFO85YFuXjg), approximately 56 minutes. It was downloaded for local evaluation, not added to training or redistributed. Actual on-device Whisper Turbo takes 49.33 seconds including process overhead, 47.57 seconds decoding, and succeeds on all 64 chunks covering the decoded audio. A provenance-bound rerun produces the exact same transcript bytes. This establishes processing coverage, not transcription accuracy, diarization or word error rate. The transcript has 11,033 words, 59,194 characters and approximately 13.6k model tokens. Source text and notes remain outside Git.

The [20 notes experiments](2026-11-07-lfm3-native-meetings/notes.json) cover the production graph, a hierarchical map/reduce graph and direct full-context generation, followed by a shared comprehensive prompt profile. The 29 reference claims, including 13 late claims, were frozen independently before predictions. Reference topics are not inserted in the prompts. Judgments use the transcript, not verified audio. The podcast contains advice rather than newly assigned meeting actions, so turning advice into commitments is an error.

The first nine MLX trials have four complete, two partial outputs available for review, and three unavailable outputs. The production graph maps all source chunks but clips merged content before reducing: the 4B run trims 4,557 summary characters to 4,000 and 13 actions to eight. It takes 41.21 seconds, retains only six partially covered reference claims and invents eight actions. Fast C direct output completes in 5.57 seconds but only partially covers 14/29 claims, four late claims, and has two unsupported summary entries. The native version completes in 4.42 seconds with 14 partially covered claims, six late claims and one unsupported entry. None is a satisfactory comprehensive meeting summary.

The second wave has eleven trials: eight shared comprehensive variants plus three native baseline variants. Completion and quality are separate; a partial output available to a judge is not counted as complete. Selected comprehensive results are:

| Model / graph | Status; wall time | Full + partial claims / 29 | Late full + partial | Unsupported summary / decisions / actions |
| --- | --- | ---: | ---: | ---: |
| 4B direct | Complete; 14.78 s | 4 + 12 | 1 + 3 | 2 / 0 / 0 |
| 4B hierarchical | Complete; 52.58 s | 7 + 14 | 2 + 6 | 3 / 6 / 5 |
| Base direct | Complete; 6.41 s | 3 + 16 | 0 + 8 | 2 / 8 / 0 |
| C direct | Complete; 11.15 s | 4 + 17 | 0 + 8 | 3 / 6 / 6 |
| C hierarchical | Complete; 31.99 s | 8 + 6 | 4 + 3 | 5 / 6 / 6 |
| Native C direct | Failed; 6.85 s | Unavailable | Unavailable | Decisions exceed schema cap |
| Native C hierarchical | Failed; 28.46 s | Unavailable | Unavailable | Reducer hits token limit |

Base hierarchical also fails at the reducer limit. The comprehensive profile allows 768 map tokens and 1,536 reduce/direct tokens versus 384/512 in the baseline. It is exploratory, authored after V1 and before V2 predictions. Counts of unsupported entries are not counts of unique fabricated propositions. 4B direct has the best commitment discipline among complete comprehensive variants, but still loses late coverage and adds two unsupported entries. C's greater detail also brings invented commitments. Keep meeting summarization separate from cleanup training; the production graph needs coverage-preserving reduction and a better summary-specific evaluation before a model or prompt switch. These experimental prompts do not change installed notes behavior.

**Phonon still wins the matched median.** The [44-case comparison](2026-11-07-lfm3-native-meetings/phonon-matched44.json) uses the actual Phonon native engine and supported English cases, with three repetitions per engine. Unsupported Hindi, custom instructions and vocabulary settings are excluded explicitly. Native C Q4 has p50 **77.60 ms**, versus **46.19 ms** for Phonon; p95 is 222.82 versus 206.15 ms using linear interpolation of per-case medians. Native reaches EOS on all 44; Phonon rejects one case through its edit guard. Blind text review finds three native versus four Phonon material errors, each also an introduced fact. These are already examined V4 diagnostic cases, different trained models and product prompts, and warm one-shot cleanup. They do not establish statistical quality superiority or streaming/audio/GUI performance. The later header optimization has not been compared against Phonon on this same test.

The [Phonon source](https://github.com/Infatoshi/phonon/tree/342b641c093f103e9aec9bed98865844e9c041fa) explicitly disables thinking even though the base template enables it by default; Velora already disables it. The audited publisher metadata describes 76,960 rows versus this experiment's 2,216: 38,480 writing-mode targets, including public technical audio and synthetic inputs, mixed with 38,480 older examples. Specialized Metal execution, verified drafts and work performed during speech also matter. Dataset composition is publisher metadata, not a reproduced training corpus, and more rows alone do not explain a measured speed difference. No GPL Phonon application code was copied; model licensing remains separate from runtime-source licensing.

**Recommendation.** Retain C as the experimental 1.7B cleanup candidate and the C++/Metal worker as the measured inference path. For short cleanup, the tested configuration is Q4, copy-eight, full SWA and opt-in header caching at batch 128; for the fixed long prompt, batch 512 wins. Keep the current production model until additional public examples and independent evaluations eliminate the new material errors. A wholesale Zig/Rust engine rewrite has less evidence behind it than these measured changes. Meeting notes need their own training/evaluation target and coverage-preserving reduction; the cleanup adapter is not qualified for that role.

**Reproduction and validation.** The [training recipes](../../training/cleanup/README.md#reproduce-the-lfm3-abc-research-recipes), [native runner](../../native/cleanup/README.md), [export guide](../../native/cleanup/experimental/LFM3_EXPORT_AND_PREFILL.md) and [prefill sweep](../../native/cleanup/experimental/PREFILL_SWEEP.md) are checked in. The portable LFM3 runner is newly provided; historical manifests preserve the original operator-wrapper hash rather than pretending the new script produced these checkpoints. All personal data, podcast text and model weights stay outside Git.

Selected C adapter SHA-256 is `2389b2d67d719e7b7f56b8f348cd6b38c7c7f2f7b59c6c8276cba2501c498f17`; Q4 is `15def8830eb1ee5a7a5ddc002aae31a8a38a913b53f0d7f1c8583b80044f16c9`. GGUF export dequantizes the actual 8-bit source before fusing; it does not recover original BF16 weights. Original versus fused generation matches on all 96 public cases; Q4 differs on five, independently reviewed without an additional material error on that small precision check. Private quality remains the stricter gate. Native upstream is pinned at `4b77dee0524c64b8471869232e2958bd9589607d`. Canonical source-tree SHA `9ed56cfe2f6554d6ff40e137b609e1f9e152bc58c9db0c9d51b87891bdf1bd0d` corrects an earlier generated-bytecode inclusion: all 4,074 source files match the upstream archive, and verification remains strict. The promoted header worker SHA is `6b5ab148f586b881d27577f5a61a5dafa551d1a24edb140213c29321ec044a3c`.

An owner-local package at `~/.velora/benchmarks/lfm3-native-meetings-20261106/artifacts/lfm3-c-20261107/` contains the selected adapter, Q4/Q8 artifacts, source export, licenses and verified lineage. It is explicitly marked `quality_qualified:false`. Its 6.04 GiB logical size includes multiple formats and the source export; it is not a shipping download or RAM estimate. Package manifest SHA is `7be16ed4c1fca4998a4be9f88a7538d168c5d58be2debe2c2fcc373671b4dcd4`.

`make test` passes with SDK 26.5: **3,935 Swift checks, 2,138 Python tests, three skips**, plus site, signing, publish, bootstrap and lifecycle checks. Separate training tests pass **60/60**; native CPU tests pass **66 plus eight subtests**, including protocol/runtime startup checks and source-pin mutation rejection/restoration. Muse source reviews prompted stricter provenance, EOS and header-path qualification checks. A separately reproduced dictionary-scroll regression was fixed and covered by the Swift selftest. The runtime checks establish the tested paths and outputs, not universal numerical equivalence. Implementation commit: `cda8600` (runtime, training, datasets and tools); dictionary fix: `91e2a80`. The report and aggregate results accompany them on `main`. Installed model defaults and release version remain unchanged.
