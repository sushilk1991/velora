# Public cleanup students and native inference

## Outcome

Velora can run an independently authored native C++ decoding loop on Apple
Silicon. The prototype uses pinned MIT llama.cpp/Metal math kernels, owns its
request lifecycle and greedy token loop, and supports bounded static-prefix
reuse and target-verified transcript copy drafts. It is separate from the app.

Two fresh-process copy-draft comparisons reduced median text-generation latency
from 170.75 to 107.61 ms and from 169.39 to 107.32 ms on 64 public fixtures, a
36.6–37.0% reduction. Text, prompt/output token IDs and termination statuses
matched on every case in both comparisons. The underlying base model reached
EOS on 63 cases and its token ceiling on one; failed output was kept in the
denominator and never treated as acceptable cleanup. This is a runtime result,
not a qualified replacement model or microphone-to-paste measurement.

Six substantive student-training variants were attempted. Public-data
fine-tuning worked locally, and the expanded 2B student improved meaning and
control handling. Every candidate still failed material fidelity or formatting
checks. No student replaced the production model, and engine dependencies were
not upgraded. The existing measured allocator-cap improvement remains in place.

## Reproducible artifacts

- [Training pipeline and setup](../../training/cleanup/README.md)
- [Reviewed pilot v1](../../training/cleanup/data/pilot_v1/README.md)
- [Reviewed pilot v2](../../training/cleanup/data/pilot_v2/README.md)
- [Native worker, build and protocol](../../native/cleanup/README.md)
- [Results and provenance](2026-11-06-public-cleanup-student/results.json)
- [Earlier Phonon audit](2026-11-05-phonon-efficiency-audit.md)

The adjacent results directory contains public predictions and anonymous
judgments with their model keys. Local adapters and complete manifests remain
under the ignored `.context/compound-engineering/ce-optimize/public-cleanup-student/`
directory. No model weights or personal dictations were added to Git.

## Data and teachers

The pinned [Sotto source](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup)
contains 135,503 training and 6,921 validation raw inputs and declares MIT.
We sampled 512 raw inputs for new labels; original Sotto answers were withheld.
Terra authored labels and Muse independently reviewed them. Muse also authored
256 original multilingual examples that Terra reviewed. The first curated
corpus had 756 rows, split into 592 train and 164 dev.

The second round added 128 English examples authored by Terra and 256
Hindi/Hinglish examples authored by Muse. Review went to the other model;
28 multilingual drafts were rejected. After deduplication and exclusions,
pilot v2 contains 1,109 rows: 900 train, 209 dev; 787 English, 162 Hindi and
160 Hinglish. These are model reviews, not human certification. Muse's CLI
did not expose its underlying model identity; no weight-model name is guessed.

Both corpora require public visibility, an approved review, a source ledger,
revision and license. Related scenarios and shared eight-word sequences are
joined before splitting. Translated Muse families are joined explicitly because
literal overlap cannot find translations. The 64-case original test and a fresh
64-case qualification test were hidden from data teachers. Another 27 legacy
benchmark inputs are contamination exclusions. One old example overlapped the
new qualification guard and was removed before the second training run.

The owner authorized Muse to clean copies of 40 personal dictations. Nine were
marked uncertain; 31 were retained as private text-only evaluation references.
The history database was not written. Personal raw text, targets and predictions
remain in a private directory with restricted permissions and were not training
inputs. Qwen4B supplied no training labels; it was used only as a comparator.

## Training and quality

Training used an isolated Python 3.12 environment with MLX 0.32.4,
MLX-LM 0.32.2 and Transformers 5.22.1. Immutable model revisions and actual
weight/config/tokenizer hashes are in the manifests. The exact short system
prompt and JSON controls are shared by training and generation. Thinking is
disabled; evaluation is greedy. Loss covers answer tokens and EOS, excluding
padding, with no silent truncation.

| Run | Data | Training time | Peak MLX allocation | Outcome |
| --- | --- | ---: | ---: | --- |
| Qwen3 0.6B, 8-bit | v1 | 95 s | 1.65 GB | Incorrect corrections and Hindi; rejected |
| Qwen3.5 2B, initial aggressive run | v1 | Stopped | — | Dev loss rose sharply; rejected |
| Qwen3.5 2B, safer recipe | v1 | 390 s | 3.12 GB | Better corrections; omissions/custom-mode errors |
| Qwen3.5 2B, expanded data | v2 | 603 s | 2.99 GB | Best overall candidate, still meaning errors |
| LFM3 1.7B, 8-bit | v2 | 339 s | 4.05 GB | Invented a glossary term and missed corrections |
| Qwen3 1.7B, 8-bit | v2 | 350 s | 4.57 GB | Script, romanization and negation errors |

These are MLX allocation peaks during training, not process RAM requirements.
The 0.6B pilot predates the padding-mask fix and is retained as a diagnostic,
not a shipping candidate. The safer recipe uses rank 16, direct LoRA scale 8,
learning rate 1e-5, 20 optimizer-update warmup steps, cosine decay, global
gradient clipping at 1 and accumulation of four samples. Development selection
uses the full dev split, before examining qualification outputs. Qwen3 1.7B
needed a 1,536-token limit to retain eight long Hindi examples; none were dropped.

On the new 64-case qualification set, Terra judged the base 2B model acceptable
on 47 cases and the expanded student on 58. Muse's independent passes accepted
56–57 for that same student, 57 for LFM3 and 53 for Qwen3 1.7B. Small score and
reference disagreements include whether an explicit Hindi contrast must be
removed as a retraction. The rejection remains supported by unambiguous
meaning changes, script errors and an unsupported glossary insertion.

On the 31 private owner references, both final Qwen students were acceptable on
30 cases and lost meaning on one. Neither invented additional facts in that
review. These are text judgments without audio/prosody, not human accuracy
measurements. Passing losses and fluent outputs did not establish readiness.

## Runtime investigation

Hardware was an Apple M5 Max with 36 GiB unified memory. GPU jobs ran serially;
other local applications remained open and idle. These are development-machine
measurements with one-token warmup, no energy measurements or cross-device
extrapolation.

| Runtime, batch one | Median on 64 cases |
| --- | ---: |
| Direct MLX-LM, official LFM3 MLX 8-bit | 169.17 ms |
| Rapid-MLX, same MLX weights and prompt tokens | 187.31 ms |
| Native C++, official GGUF Q8_0, uncached | 177.41 ms |
| Same C++ binary and GGUF, static prefix cache | 169.63 ms |
| Same C++ worker, prefix cache plus verified copy drafts | 107.61 / 107.32 ms, two matched runs |

GGUF Q8_0 and MLX 8-bit are different quantizations. Prompt token IDs matched
on all 64 cases, but only 59 raw outputs matched across those formats. The
cross-format table does not isolate a programming-language speedup. The
copy-draft comparison uses the same binary, weights, tokenizer and fixtures;
all 64 outputs/statuses match in both runs. Target forward calls fell from
2,167 to 1,441 in the first pair, with no separate drafter model. IPC added
about 0.28 ms median, so the useful
optimization was fewer target-model forwards rather than rewriting framing.

Rapid-MLX offered no latency advantage on this batch-one workload. Its headline
optimizations for other architectures/concurrency are not evidence for this
dictation workload. Its cleaned output also failed to remove reasoning leakage
in the tested base model. Raw outputs and EOS/length status were preserved.

The native worker independently implements JSONL framing, offline SHA
verification, thinking-off Jinja rendering, a greedy token loop, request bounds,
deadlines, cancellation and state reset. Its parent uses nonblocking bounded
pipes and process-group kill/reap. Static snapshots are model/template/context
and token keyed, capped at 32 MiB and separate from request-local draft states.
Restored prefixes replay their final token because llama.cpp does not serialize
logits. Copy proposals are limited to three transcript tokens and accepted only
after target verification; mismatches restore full hybrid state and replay the
verified prefix plus the corrected target token before committing output.

The stock GGUF model reached the same token ceiling on one fixture with both
decoders. Benchmarks return a failing qualification result for that ceiling
while still reporting the full timing denominator. Repeatability, cancellation,
changed-system invalidation and exact recovery after context errors passed.
Cache and copy drafts remain explicit experimental flags. Full acceptance on
these fixtures is not a guarantee across model artifacts or GPU generations.

## Useful conclusions for Velora

The strongest measured native idea is target-verified copying: cleanup usually
retains much of its input, so several target tokens can be checked in one
forward without another drafter model. The native API makes that policy,
memory bounds and lifecycle ownership explicit. Matrix math still comes from
the pinned permissive upstream core; no Phonon GPL implementation was copied.

The model remains the release gate. A final student needs broader multilingual
and hard-negative data, an independently qualified fused/quantized artifact,
and tests through Velora's existing guards and postprocessing. Native loading
does not repair missing clauses or wrong negation. The shared current model
also serves voice edit, actions and notes; a dictation specialist needs explicit
routing and serialized role changes so adopting it does not retain two loaded
models or silently change those features.

Validation completed: `make test` passed with 3,932 Swift checks and 2,039 pytest
tests (3 skips), plus site, signing and release checks. The training suite has
29 passing CPU tests. Native protocol/cache/copy selftests, supervisor regressions
and benchmark-accounting tests pass; independent reviews found and fixed
blocking-pipe, signal cleanup, status-accounting and provenance defects.
