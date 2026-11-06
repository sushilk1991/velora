# Smaller cleanup models and complete personal-recording replay

Keep Whisper Large-v3 Turbo and Qwen3.5-4B MLX 8-bit as Velora's production models. Smaller specialists lowered memory or latency, but added material failures on current recordings. The native prototype retained a separately confirmed decoding improvement. Production model selection and engine dependencies remain unchanged. The running application initially used engine build `23436eb`, before the repository's 512 MiB allocator-cache policy. The main repository comparator includes that policy; a separately frozen copy of the installed source is also replayed as an uncapped baseline. The core recognition, server and formatting sources match byte-for-byte; the cleanup difference is the allocator policy.

## What Phonon does differently

The [source audit](2026-11-05-phonon-efficiency-audit.md) traced its recognition, refinement, native kernels, streaming, training, delivery, app integration and distribution paths at a pinned revision. Phonon disables thinking despite the base model supporting it. Velora already disables thinking too.

Phonon combines a small, task-specific LFM3-1.7B refiner, a short trained prompt, quantized weights, target-verified drafts, model-specific Metal execution, and refinement during speech. Work completed before key release reduces the work left after release; it does not establish lower total GPU work or energy. Its advertised release-to-paste time cannot be compared with a complete offline recognition-plus-cleanup replay.

The pinned [refiner metadata](https://huggingface.co/Infatoshi/phonon-refiner-1.7b/blob/2b0ab74bee7ab7cf364695bbe44f64ce4c47439e/phonon_refiner.json) reports 76,960 public/synthetic training rows. The publisher describes technical-audio ASR errors, synthetic dictations, unrelated vocabulary and four writing modes. This recipe is evidence for useful data categories, not an independently verified reproduction of that dataset. Its English cleanup contract also differs from Velora's multilingual and custom-mode requirements.

## References came before candidate comparisons

The frozen cohort contains 614 available owner recordings, about 4.59 hours. The manifest SHA256 is `90fd823f593d667d6eb7830ce71b2c3600649c89fe35c595f2f1993934f6e000`. Subsequent recordings are outside this cohort. History was opened read-only; saved final outputs were not reference labels.

Full Whisper Large-v3 and independent Qwen3-ASR-1.7B 8-bit each decoded the cohort. Muse prepared references from blinded ASR evidence, then Terra reviewed all six shards before main cleanup predictions. The frozen reference SHA256 is `15ab1893a15536bb3e78eda7694fd385a8a16283b4a5a526c84ebea78ee44a17`: 303 approved, 310 uncertain and one unscorable recording shorter than 0.2 seconds. Approved means no material ambiguity was found in the text evidence. These are model-assisted references, without human listening or audio adjudication. They do not establish human transcription accuracy. Ambiguous references are excluded from primary semantic scoring; all recordings remain in coverage and failure counts.

The initial Turbo replay omitted the production recognition glossary. That run and its partial cleanup replay were retained only as diagnostics. The corrected comparator reapplied the frozen production glossary before every audio chunk and decoded all 614 clips: 613 successful and one too short. Its glossary SHA256 is `1d872c8382986a291e72063209434a7a7651a502c9a4450f38a52e892d37a7ad`. All main cleanup arms consume this same corrected STT output. No historical screen entities are available.

[Replay tools](../../engine/scripts/benchmark_personal_recordings.py) use the production audio loader, chunking, formatting gates, splitting, divergence checks and postprocessing. Candidate controls use a copy of the frozen app settings and modes. These are sequential file-STT and cleanup passes, paired by recording, rather than live microphone, hotkey, streaming, insertion or concurrent-GPU measurements. Two historical Action-mode recordings are evaluated as text; no action is executed and this does not qualify the Action planner.

## Public-data fine-tuning

[Pilot v3](../../training/cleanup/data/pilot_v3/README.md) contains 1,605 examples, split into 1,243 training and 362 development rows. It adds 112 Terra-authored examples reviewed by Muse and 384 Muse-authored examples reviewed by Terra. New cases emphasize negation, genuine versus ambiguous corrections, unchanged text, names, numbers and unrelated glossary terms. Related scenarios are grouped before splitting. Public source licenses and review receipts are recorded in the source ledger. No owner recordings, private transcripts or Qwen4B teacher labels train these adapters.

A fresh 96-case qualification set was authored in a separate context and independently reviewed before training. All 251 old/new evaluation strings were excluded from curation. Muse's configured CLI default supplied independent judgments; its underlying weight-model identity was not exposed.

Both 2B variants used rank-16 LoRA, scale 8, learning rate 1e-5, 20 optimizer-update warmup steps, cosine decay, gradient clipping at 1, accumulation of four, maximum sequence length 1,024 and 2,488 training samples. Training ran locally in an isolated environment with MLX 0.32.4, MLX-LM 0.32.2 and Transformers 5.22.1. The production environment was not upgraded. [Sanitized training manifests](2026-11-06-cleanup-push-v3/training-manifests.json) pin both bases, adapter hashes, optimizer parameters and the audited training-only MLX-VLM gated-delta compatibility source. No inference kernel or installed package was patched by that hook. Tokenizer hashes match across the bases; their configuration differs in affine quantization precision, four versus eight bits with group size 64.

| Variant | Training time | Peak MLX allocation | Selected checkpoint | Full-dev loss | Fresh 96 acceptable |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.5-2B, 4-bit | 920.7 s | 3.122 GB | 624 samples | 0.15598 | 95/96 |
| Qwen3.5-2B, 8-bit | 975.5 s | 4.069 GB | 624 samples | 0.14593 | 95/96 |

Checkpoints were selected using the entire development split before qualification, rather than choosing the best test output. Later checkpoints overfit. These memory figures are training allocator peaks, not process RAM requirements. Both variants reached EOS on all 96 cases. Both retained a superseded recipient alongside the corrected recipient on the same explicit-correction case. That material error fails the declared zero-material-error gate regardless of average score; higher precision did not fix it. The four-bit mean was 4.7812/5 and the eight-bit mean 4.6458/5, mostly differing in minor style ratings. This new test cannot establish improvement over an older model evaluated on a different test.

## Inference experiments

The [native C++ worker](../../native/cleanup/README.md) owns the token loop and request lifecycle while using pinned MIT llama.cpp/ggml Metal math. It is separate from the app. Rust or Zig bindings would call similar kernels; a language change alone is not evidence of less model work. The earlier matched Qwen4B study favored the existing MLX path over its older llama.cpp comparator. That result does not rank every newer llama.cpp revision or smaller model.

The new worker adds bounded draft lengths, direct CPU argmax, backend greedy sampling with optional token-only readback, recurrent rollback and trace counters. On the same official LFM3 Q8_0 artifact, direct argmax, recurrent rollback and backend sampling did not demonstrate a clear latency benefit. Host snapshot save plus restore occupied 62.94 ms of a 10.18-second trace, about 0.62%. The sampling wait includes GPU execution and synchronization; it is not evidence of nine seconds of CPU sampling overhead. No new custom GPU kernel is justified by this trace alone.

Two counterbalanced fresh-process pairs confirmed a useful draft-size change:

| Same LFM3 Q8_0 artifact, 64 public cases | Pair 1 p50 | Pair 2 p50 |
| --- | ---: | ---: |
| Verify three transcript tokens | 106.94 ms | 107.94 ms |
| Verify eight transcript tokens | 81.81 ms | 82.49 ms |

This is a 23.54% reduction relative to the three-token worker. All 64 prompt/output token sequences, texts and termination statuses matched in all four runs, and recovery checks passed. One known token-ceiling case remained in every arm: relative runtime parity passed, but the base model remains unqualified. An earlier 151 ms baseline was anomalous and is not the comparison used for the claim. These timings exclude recognition and paste.

The selected 2B adapters were also checked with direct MLX-LM, Velora-style cached decoding and verified-copy decoding. Cache or batch shape can change near-tied token choices. A reproduced probe did not support the proposed normalized-argmax explanation: raw, normalized and float32-normalized selection chose the same token. Both selected adapters differed on one public fixture per variant. Four-bit cached decoding changed requested punctuation; eight-bit cached decoding changed email line breaks and capitalization without changing words. These differences are not proof of semantic corruption, but fail the declared exact-parity runtime gate. Fast variants were excluded from private replay in favor of the direct decoder. Cached eight-token public medians were 151 ms versus 195 ms direct for four-bit, and 195 ms versus 246 ms direct for eight-bit; those single-pass results remain unqualified diagnostics. These experiments do not change the production engine.

Rapid-MLX previously took 187 ms versus 169 ms with the same LFM3 MLX weights on this batch-one workload. Its batching claims do not establish a dictation latency win.

The full personal replay also shows why a short prompt alone is insufficient. The repository 4B arm with the existing cache cap had median 3,047.5 input tokens and reused a median 2,940 prefix tokens per model call. The direct four-bit student had median 825 input tokens and zero reused prefix tokens. Each produced a median 55 output tokens. These are per-call distributions over long-piece and retry calls, rather than recording-level timings. Smaller weights reduce memory, but removing the current cache benefit spends some of the expected latency savings again.

On a 96-recording pilot of the current Qwen4B model, eight-token drafts took 1.65 times the three-token cleanup median over 95 timed cases, and four outputs differed. One clip was too short. The larger draft was rejected; no full 614 speed claim is made for that arm. A further fresh-control pilot compared two, four and six tokens against three. Cleanup median ratios were 2.208, 0.900 and 1.572, with five, six and two changed text/status/guard cases, respectively. Four tokens looked faster but failed parity; none qualified for confirmation or a full-cohort change. Repeating three-token decoding reproduced all96 text/status results. Native LFM3's winning draft size does not transfer to Qwen4B.

## Personal replay results

[Aggregate results and provenance](2026-11-06-cleanup-push-v3/results.json) accompany the public-data evidence. All five full arms completed 614 cases; 613 have actual recognition/cleanup timers and one is too short. The installed and capped 4B arms produced identical text, modes, final guard outcomes and statuses on all 614 cases. Their identical outputs share the same quality judgments.

| Full-cohort arm | Cleanup p50 / p95 | Recognition + cleanup p50 / p95 | End / peak model-process footprint |
| --- | ---: | ---: | ---: |
| Installed Qwen3.5-4B 8-bit, uncapped | 735 / 3770 ms | 953 / 4646 ms | 5.4G / 8.7G |
| Same 4B, repository 512 MiB cache policy | 761 / 4299 ms | 991 / 5217 ms | 5.5G / 6.2G |
| Fine-tuned Qwen3.5-2B 4-bit | 633 / 3396 ms | 872 / 4451 ms | 1.5G / 3.2G |
| Fine-tuned Qwen3.5-2B 8-bit | 744 / 3958 ms | 982 / 4973 ms | 2.4G / 4.0G |
| Phonon refiner + our C++ copy-eight worker | 133 / 881 ms | 366 / 1945 ms | 1.4G / 1.5G |

The native row measures its worker separately from a 10.4M supervisor; the Python replay driver is not included in that worker number. Native and MLX rows are not complete live-app RAM requirements. Phonon had five unsupported non-Latin cases and one short STT failure. On the 608 supported cases, its paired median was 368 ms versus 1,002 ms for the capped 4B comparator on those same cases. Latin-script coverage alone does not establish English-language suitability.

Normal/fallback statuses do not establish semantic quality. The capped and installed 4B arms had six full cleanup fallbacks; four-bit SFT had four partial and two full fallbacks; eight-bit SFT had three partial and three full fallbacks. Failed attempts and long-piece retries stay in the timing distribution. Both student arms had 607 normal case results; the Phonon arm had 608, plus the explicit unsupported cases. These counts do not erase meaning errors in accepted text.

Uncapped here means no explicit Velora allocator budget; MLX and operating-system defaults still apply. The full replay did **not** reproduce an end-footprint reduction from the allocator policy: uncapped ended at 5.4G and capped at 5.5G. Process-lifetime peaks were 8.7G and 6.2G, respectively, but single passes do not isolate the cause of that peak difference. This corpus therefore provides no new retained-RAM saving or speed claim for the cap. The [earlier repeated controlled test](2026-11-05-phonon-efficiency-audit.md) remains its evidence: about 394 MB less retained footprint with matching outputs and inconclusive latency differences. The policy bounds unused allocator buffers; it does not shrink the model's live weights.

### Independent quality checks

Muse judged 967 unique anonymous outputs across the 303 previously approved reference cases, including raw STT. Identical outputs shared a label within each case; model names, timings and execution status were hidden. Three Terra reviewers then blindly audited **every one of the 156 unique content/control-flagged outputs** across 89 cases. They supported 46 material issues, rejected 97 flags as benign or unsupported, and left 13 uncertain. This review matters: removing filler is often useful cleanup and must not be counted automatically as lost meaning. Original references and Muse judgments were retained unchanged.

| Arm | Reviewed acceptable text | Supported material issues | Material cases without a supported flag in current 4B | Ambiguous text judgments |
| --- | ---: | ---: | ---: | ---: |
| Same 4B, repository 512 MiB cache policy | 256/303 | 8 | 0 | 36 |
| Fine-tuned Qwen3.5-2B 4-bit | 246/303 | 17 | 11 | 35 |
| Fine-tuned Qwen3.5-2B 8-bit | 254/303 | 12 | 9 | 35 |
| Phonon refiner + our C++ copy-eight worker | 254/303 | 8 | 3 | 35 |

Reviewed acceptance requires the original acceptable rating, score at least four, no ambiguity, and no supported or uncertain issue in the subsequent audit. Every table keeps all 303 cases in its denominator. Execution eligibility is separate: normal execution plus reviewed acceptable text was 253/303 for current 4B, 245 for four-bit SFT, 253 for eight-bit SFT and 251 for Phonon. Raw STT was acceptable on 258/303 and retained six supported correction/control issues. These are judgments from fallible text references, not human word-accuracy measurements or a statistically established ranking from small score differences.

No replacement passed the no-additional-material-error gate. Phonon had the same total supported issue count as current 4B but three occurred on cases without a supported material flag in current 4B. The students had 11 and nine such additional cases. Unresolved explicit reversals, changed identifiers and lost independent constraints remain concrete concerns. The current model also makes mistakes; fluent cleanup and a high average score do not guarantee preservation of the speaker's intent.

The fine-tuned 2B models save substantial model-process memory in this experiment. Eight-bit precision did not make the student materially faster or eliminate its correction failures. The native Phonon candidate offers much lower processing latency, but its English/mode limitations and additional supported issues prevent a global replacement. Velora also uses its selected writing model for voice edit, Action planning and notes; these replays do not qualify those features for a specialist.

The base Q8 pilot was also rejected: all 24 recordings fell back completely or partially, with 30 token ceilings. The QAD partial arm and Q8 pilot use the unadapted base with the student's structured JSON plus production controls. Their failures concern that artifact/prompt contract; they are not a universal claim about LFM3 or llama.cpp. Neither is reported as a completed 614 arm. Older base/v2 student full replays were not selected in this round; their earlier public results remain in the prior study.

## What is retained

The native eight-token draft remains an explicit experimental option with its repeated same-artifact speed and parity evidence. Four-bit and eight-bit adapters, reviewed public data, frozen qualification inputs and private replay tools are preserved for further work. Production model selection stays unchanged. Before another specialist ships, use broader licensed technical ASR error pairs, long explicit corrections, qualifier preservation and the complete mode/control contract, then qualify the fused/quantized artifact on a newly frozen test set. The personal evaluation corpus must not become training data or a repeatedly tuned test.

The existing allocator policy was activated in the local signed app after the full regression gate. The 0.31.0 build 434 uses the same Developer ID designated requirement, entitlements and Apple-issued provisioning profile as the old app. A graceful restart preserved the original app as a rollback copy; the new engine source matches the repository and reports ready. Launch checks report Microphone, Accessibility and Input Monitoring granted. No public release was created and model selection did not change. [Activation evidence](2026-11-06-cleanup-push-v3/local-activation.json) records the verified checks.


## Reproduction and limits

The measured helper source is preserved at commit `6bafa29`. Subsequent review fixes tighten source/config snapshots, cohort/resume checks, partial-result and failed-token accounting, and supervisor sampling failure handling. These change source fingerprints; archived qualification reports do not qualify a future run of the revised tools without fresh checks. Actual measured runs used private frozen settings and validated complete case sets.

All research GPU jobs run sequentially on an Apple M5 Max with 36 GiB unified memory. Other local apps remain open. A brief secondary app start during the installed-source pass was closed; its original serving instance remained running. Part of the first four-bit student replay overlapped CPU project tests. Whole-cohort model timings are exploratory single passes, without counterbalanced repetition; they do not establish a production speed guarantee. No energy measurements or results on other hardware are claimed. Model hashes, adapter hashes, source fingerprints and actual memory measurements accompany private runs. Timing includes fallback attempts and failed model calls where a timer exists; a clip that cannot reach recognition has no fabricated cleanup time.

The production comparator uses the full existing prompt. Student adapters use their short trained JSON controls while preserving production gates and guards. The Phonon arm uses its pinned fine-tuned GGUF and trained bare-transcript prompt through our copy-eight worker; it does not reproduce Phonon's native Metal/DFlash runtime. That bounded arm omits optional vocabulary and previous-piece hints, maps stock modes, and records unsupported romanization, non-Latin or customized modes as explicit fallbacks. Base LFM3 Q8_0 and QAD Q4_0 arms use different weight quantizations. The QAD arm was rejected after 234 of 614 recordings: 47 normal results, 173 complete fallbacks, 13 partial results and one too-short STT failure; 380 recordings were not completed. Calls included 221 token ceilings and nine deadlines. This is an incomplete rejected arm, not a full-cohort speed comparison. The actual fine-tuned Phonon arm completed all 614 without a token ceiling. Prompt, quantization and model training differ, so this contrast does not isolate fine-tuning causally. Cross-model tables therefore compare candidates, not programming languages or backends in isolation.

Accepted production CleanupResult objects do not expose EOS; explicit length rejections are counted, but accepted production outputs are not advertised as EOS-verified. Student and native paths record their observable termination separately.

Physical footprint, RSS, live MLX allocation, allocator cache and mapped model bytes measure different things. Per-process results are not total simultaneous STT-plus-cleanup memory requirements. Phonon's GPL application implementation was not copied; this independently authored code and upstream math core are permissively licensed. Weight licenses remain separate.

Private audio, labels, candidate text and token IDs remain outside the checkout under `~/.velora/benchmarks/personal-20261106/`, with private file permissions. Only aggregate personal results and public-data artifacts are committed.

The final full gate passed after review fixes: 3,932 Swift checks, 2,087 Python tests (three skipped), plus site, signing and publish-release checks. Two third-party deprecation warnings remain. The isolated training suite passed 29 CPU tests; regenerating the v3 corpus reproduced its exact dataset SHA256. Native protocol, runtime flags, nine ablation-accounting tests and seven supervisor tests passed. The distribution build and deep code-signature verification passed; its identity, entitlements and provisioning profile match the installed predecessor.
