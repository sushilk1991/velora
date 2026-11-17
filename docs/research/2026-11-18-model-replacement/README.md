# Smaller-model study — 18 November 2026

**Decision: retain Qwen3.5-4B-MLX-8bit. None of five candidates passed the zero-regression quality gate. No production model, runtime, settings or app binary was changed. Velora remains stopped at the user’s request.**

Apple M4 Max, 36 GiB unified RAM; MLX 0.31.2, MLX-LM 0.31.3, Transformers 5.3.0. Scope is the shared cleanup LLM; Whisper STT is unchanged. Base `fb700ce`. Public synthetic inputs only; no owner history, audio or dictionary was read.

## Baseline versus candidates

Raw **screening** measurements: 27 identical edge cases × 2 repeats per fresh worker. Percentiles use all 54 cleanup request wall times, including IPC, tokenization and inference; formatting gates/postprocessing stay outside the timed request for every model. Failures are never filtered out. All five candidates failed quality and were rejected before paired A-B-B-A qualification. These single-arm numbers do not establish the comparative latency or sustained-memory exit gates. MB means 1,000,000 bytes; RSS, physical footprint and MLX allocations overlap and are not added.

| Model | Text params (B) | Disk (MB) | P50 / P95 / P99 (ms) | Peak RSS / physical (MB) | Quality | Result |
|---|---:|---:|---:|---:|---:|---|
| Baseline Qwen 4B8 | 4.206 | 5,164 | 612 / 1005 / 1053 | 3,982 / 6,781 | 26/27 | Retain |
| Qwen 2B4 | 1.882 | 1,749 | 345 / 669 / 969 | 1,979 / 2,729 | 17/27 | Reject: quality |
| Muesli 2B8 | 1.882 | 2,020 | 394 / 562 / 589 | 3,018 / 3,208 | 9/27 | Reject: quality |
| Vedu 0.8B | 0.752 | 561 | 240 / 305 / 390 | 1,552 / 1,665 | 17/27 | Reject: quality |
| Muesli 0.8B8 | 0.752 | 820 | 284 / 387 / 411 | 1,817 / 1,960 | 10/27 | Reject: quality |
| Qwen 2B8 | 1.882 | 2,690 | 445 / 770 / 841 | 2,877 / 3,587 | 19/27 | Reject: quality |

The table uses the final clean baseline. The earlier clean baseline scored the same 26/27 with P95 1,081 ms versus 1,005 ms here, illustrating why a single-arm speed ratio cannot qualify a replacement. Cycles 1, 3 and 5 retain valid earlier screens; the resumed study recollected its baseline and reran the failed adapter. [Exact metrics, sample counts, immutable revisions, commands and host deltas](raw/metrics.json).

## Five-cycle critique

1. **General 2B4:** smaller and faster in screening, but loses numbers, correction intent, multilingual lists and prose/list distinctions (17/27).
2. **Muesli 2B8:** task fine-tuning plus higher precision does not retain Velora’s grammar, mode and multilingual contracts (9/27).
3. **Vedu 0.8B:** trained formatting controls improve speed/size, but corrections, romanization and list behavior regress (17/27).
4. **Muesli 0.8B8:** holding specialist prompt/precision fixed while reducing capacity still fails quality (10/27).
5. **General 2B8:** raising precision recovers two passing cases over 2B4, but quality remains 19/27; capacity/task behavior remains insufficient.

[Ranked research and primary sources](research.md). [All 27 side-by-side cases](side-by-side.md), [machine-readable output diff](output-diff.json), [per-cycle predicate regressions and decisions](raw/final-study/cycles.json).

## Exit gates

| Gate | Status | Evidence |
|---|---|---|
| Fewer parameters and smaller disk payload | Pass for all five screened candidates | Full tensor-header counts and artifact SHA-256 manifests; both text and all unique model parameters are smaller |
| P95 ≥25% faster; P50/P99 strictly lower | Not qualified | Early quality rejection; no candidate received a complete A-B-B-A round |
| Peak RSS and physical footprint ≥20% lower; no sustained OOM/swap spikes | Not qualified | No errors, OOM, swapout increase, swap-used growth or warning pressure in valid measured windows; longer sustained-load paired proof was not run after quality failed |
| Equal/better quality plus all tests and 10+ output diffs | Fail | Baseline 26/27; best candidate 19/27. Tests pass and all 27 cases are diffed, but cannot erase the measured quality regression |

No winning replacement diff exists. Production inference/config files are unchanged. Changes are isolated benchmark instrumentation, fail-closed comparison/runner tools, regression checks, research/evidence, and a benchmark-only S1 helper correction that preserves gated input.

## Reproduction and raw evidence

[Exact reproducible benchmark and test commands](commands.md). Every run directory contains `model.json`, `result.json`, `requests.jsonl`, `quality.jsonl`, `worker.jsonl` and `host.jsonl`. The model manifest records packed tensor accounting, total artifact bytes and actual content hashes. Worker RSS and macOS physical-footprint high-water marks include startup. MLX peaks are retained separately.

- [Baseline Qwen 4B8 raw run](raw/final-study/baseline-a1/result.json)
- [Qwen 2B4 raw run](raw/controlled-study/cycle-1-b1/result.json)
- [Muesli 2B8 raw run](raw/final-study/cycle-2-b1/result.json)
- [Vedu 0.8B raw run](raw/controlled-study/cycle-3-b1/result.json)
- [Muesli 0.8B8 raw run](raw/final-study/cycle-4-b1/result.json)
- [Qwen 2B8 raw run](raw/repaired-study/cycle-5-b1/result.json)

Discarded diagnostics remain explicit: the initial baseline ran under load above 200 with memory/swap contamination; the first Muesli attempt returned tokenizer errors for all requests, and the next adapter omitted the required end-of-turn stop. Those adapter and host diagnostics are excluded from the comparison. The pinned Muesli card explicitly requires manual encoding; the repaired adapter and final focused checks verify its whitespace and stop-token contract. [Independent audit](raw/independent-audit.txt), [harness review](raw/harness-review.txt), [review dispositions](review-responses.md), [card provenance](muesli-card-evidence.json).

## Verification and diff

- Native engine suite: **2,438 passed, 3 skipped** ([raw log](raw/mac-engine-tests.log)). Final adapter/helper changes subsequently pass **71 focused checks** on retained Instabox ([raw log](raw/focused-tests-final.log)).
- macOS Swift/script targets covering the rest of `make test`: **4,293 Swift checks**, site, Sublime plugin, signing, publishing, engine bootstrap and update lifecycle checks passed ([raw log](raw/mac-tests.log)).
- Broad Linux attempt is incomplete and not counted as a gate pass; Apple dependencies/tools were unavailable there. Completed task-owned detached remote jobs were cleaned; the reusable build machine and dependency cache remain.
- The newly downloaded temporary 2B8 model cache was removed after recording its hashes; the runner can reacquire the same revision. Existing caches were preserved. [Cleanup proof](raw/local-cleanup.json).
- [Git diff summary](git-diff-summary.txt). No model promotion, merge of a replacement, release or app restart is claimed.

Limit: these public cleanup fixtures are a rejection screen. A survivor would additionally require semantic review, current edits/actions/notes evaluation, a paired performance round and sustained memory proof. The five-cycle budget ended with a measured quality failure for every candidate.
