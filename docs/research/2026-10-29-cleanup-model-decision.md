# Cleanup and Action Mode model decision

Keep the 4B for cleanup and Action Mode. No evaluated replacement passes
the frozen bar. Keep the shipped 2B q4 Compact tier; SimpleWords v2 does
not justify replacing it.

| Job | Decision | Evidence |
|---|---|---|
| Cleanup, Quality tier | Keep Qwen3.5-4B-MLX-8bit | Existing candidates and the public-only LoRA fail mandatory quality conditions. No two-model router qualifies. |
| Cleanup, Compact tier | Keep Qwen3.5-2B-MLX-4bit | SimpleWords v2 has more harms and fewer owner term fixes, with worse observed p90; its fused q4 follow-up also fails. |
| Action Mode | Keep the 4B | 56/62 and 58/62 on the two revisions; no tested alternative beats it. No Action fine-tune or router qualifies. |

The best offline pipeline change is a list-bypass content-deletion fallback:
4B harms fall 91→83/303 and 164→86/593 with unchanged measured term-fix counts.
Dogfood it behind a setting after native latency/RAM validation. Current
4B wWER still exceeds raw on both sets; retaining it is not a quality win
over raw passthrough. Nothing is installed or enabled by this study.

Executed 29–30 October 2026. Base: `ded87d0`, Velora 0.29.7. Local branch:
`study/cleanup-model-decision`. The study made no app restart, Dictionary
change, or write to `~/.velora`. This base already includes
the Whisper prompt, padding-segment, and miner guards from #33–#35.

## Frozen replacement bar

Recorded in scratch `codex-model/NOTES.md` before inference. A cleanup model
replaces 4B only if it meets every condition on **both** frozen owner303
and the accent-stratified public test:

1. Mean wWER is below raw and 4B, with fewer worse-than-raw takes than 4B
   and paired McNemar p < .05.
2. No accent bucket is worse than raw beyond its 95% CI.
3. Term-fix rate reaches 4B's, or the trade is stated numerically.
4. p90 latency and peak RAM do not exceed 4B's.

An owner-only win fails. If no model passes, keep 4B and choose the best
pipeline change that passes its declared test. The added guard/chunking
test is fewer harms without lower term recovery. This study does not
change these thresholds after results.

## Evidence and limits

| Cohort | Use | Coverage and limitations |
|---|---|---|
| Frozen owner303 | Paired owner evaluation | 104 teacher-pinned dev takes plus exactly 199 archived Superwhisper takes. The supplied labels were Claude-written; they are an evaluation proxy and never training targets. The 199 Superwhisper inputs are not Velora Whisper output. |
| EdAcc593 | Accent-stratified test | Human dev/test references, CC BY-SA 4.0; 12 regional buckets, 43–50 clips each, 6,749 seconds. No training or checkpoint selection uses this set. |
| AMI300/100 | Public training/internal validation | Human IHM transcripts, CC BY 4.0; 13/11 speakers and 7/3 meetings, with zero speaker or meeting overlap. Fixed rules supply sentence case and punctuation. |
| VoxPopuli43 | Supplemental diagnostic | 43 speakers, 15 first-language groups, 515 seconds; CC0 data, no noncommercial code/model used. Edited formal speech; not spontaneous-dictation gold. |
| Common Voice EN | Unavailable requested component | Current official access requires Mozilla Data Collective login/terms. No acceptance or bypass. Published CV13 Whisper hypotheses lack human references and accent tags. |

EdAcc references are uppercase and largely unpunctuated. Fixed rules remove
documented nonlinguistic tags and UM/UH/ERM/ER, preserving restarts and
affirmations. fWER/exact on this set cannot measure natural punctuation
quality. Sparse accent buckets have only two speakers; their bootstrap
intervals do not establish population safety. Australia, New Zealand,
Canada, multilingual/code-switched dictation, and microphone/noise strata
remain outside this test.

Public audio uses Velora's current `large-v3-turbo` STT backend, streaming
16 kHz mono audio in 100 ms chunks with windowed finalization and no owner
Whisper prompt. All 1,036 selected public clips completed. Human-source
references and sampling rules were frozen before cleanup inference.

[EdAcc source and licence](https://datashare.ed.ac.uk/handle/10283/8983),
[AMI human source](https://huggingface.co/datasets/edinburghcstr/ami),
[VoxPopuli data licence](https://github.com/facebookresearch/voxpopuli#license),
[Mozilla access policy](https://community.mozilladatacollective.com/faq-can-i-get-the-common-voice-or-other-mdc-datasets-from-other-platforms-like-github-or-hugging-face/).

## Where error enters

| Comparison | n | Raw wWER % | Final wWER % | Raw/reference edits | Final/reference edits | Net cleanup edits |
|---|---:|---:|---:|---:|---:|---:|
| Frozen owner → 4B | 303 | 4.0868 | 6.0727 | 1,170 | 1,918 | +748 |
| EdAcc current Whisper → 4B | 593 | 19.5653 | 22.2474 | 2,636 | 3,138 | +502 |
| Frozen history inputs → stored history final | 1,045 | 5.1029 | 5.9346 | 4,798 | 6,800 | +2,002 |

These are reference-relative budgets. They quantify error before cleanup
and its net change; they do not assign every final error causally to an
ASR or cleanup model. Owner303 mixes Velora and Superwhisper inputs.
Stored history is observational: three of the 104 pinned dev inputs differ
from the current history raw field, and history can be reprocessed. The
frozen replay uses exported inputs throughout.

Across the 1,045 history comparisons, content deletions are 110 raw versus
765 final. Final/raw alignment adds 647 words and drops 1,148 content tokens.
Matched-word case/punctuation errors change 2,528/6,184→2,238/5,059; list
mismatches stay 245. Final lexical/aligned-term recovery is 146/872 and
26/197. Formatting gains coexist with more reference-relative word errors.

EdAcc raw alignment has 1,440 deletions, 931 substitutions and 265 additions;
4B has 1,894/1,004/240. Reference-relative content deletions rise 785→1,053;
raw→output alignment records 275 content deletions and 35 additions. The
unstructured guard reduces these to 100 and 31, with 885 reference-relative
content deletions. The measured 4B did not reduce reference-relative deletions.

Owner raw has 19 reference-relative content deletions, 569 matched-word case
errors, 1,309 punctuation errors and 23 list-layout mismatches. The table
shows the same diagnostics after cleanup. R/C counts reference-relative /
raw→output content deletions; unrecovered L/D uses the fixed recovery proxies.

| Owner arm | Content R/C | Added vs raw | Unrecovered L/D | Case errors | Punctuation errors | List mismatches |
|---|---:|---:|---:|---:|---:|---:|
| 4B | 299/346 | 132 | 110/23 | 358 | 922 | 23 |
| 2B | 353/363 | 310 | 144/29 | 568 | 1,251 | 90 |
| SimpleWords | 296/422 | 46 | 150/30 | 565 | 1,177 | 23 |
| WhisperNow | 501/711 | 212 | 115/29 | 539 | 610 | 26 |
| 4B + unstructured guard | 290/332 | 125 | 110/23 | 360 | 933 | 23 |

Case/punctuation counts align matching lexical tokens; changed or deleted
words are counted by word alignment instead. Punctuation compares marks
following matched words; leading marks are not counted separately. Whole-text
fWER and exact matching still include them. List checks include marker,
ordinal, indentation and position. Owner labels remain a Claude-written
proxy, so these counts do not establish human formatting preferences.

The public STT audit confirms 1,036 source/replay joins and 636 pinned
EdAcc/Vox waveform hashes. Independently re-downloaded AMI source shards
match all 400 human rows and every selected PCM sample exactly. There is
no detected channel, sample-rate, or source-row mismatch.

EdAcc has two empty STT outputs; the 25 cleanup bypasses include 23 nonempty
short utterances. CPU guards explain one empty; one downstream cause is
unknown. All 18 AMI empties are predecode energy rejections, with train-empty
median RMS −55.93 dBFS versus −39.98 dBFS for nonempty train clips. None is
digitally silent. One EdAcc rejection depends on the 300 ms integrity crop;
that crop affects guard evidence, while Whisper receives full PCM if the
guards pass. This supports testing quiet-speech handling with nonspeech
controls, not disabling the guard.

A declared apostrophe-only sensitivity check changes none of the ten
priority cohort/arm wWER values or harm counts. Typographic apostrophes do
not explain these results; the primary metric remains unchanged.

## Metrics and measurement

`engine/scripts/evaluate_cleanup.py` reports mean per-take word-normalized
WER (wWER), whitespace-token formatted WER (fWER), exact matches, harms,
word additions, and recovery proxies. A harm means wWER exceeds the same
take's raw wWER. Word normalization lowercases Unicode word/apostrophe
tokens and removes recognized list prefixes. Layout checks score those
prefixes separately. Micro-WER and word edit totals are separate diagnostics.

Lexical recovery matches `score_gold.py`: reference word types absent from
raw and present in output. It is not name/Dictionary accuracy. The separate
aligned-term proxy counts frozen-vocabulary reference phrases repaired
contiguously in output. Both depend on reference quality; aligned terms
also inherit repeated-word alignment ambiguity. No owner vocabulary is
shown here or used for public replay.

Paired two-sided exact sign tests compare wWER; exact McNemar tests compare
the harm indicator against raw and 4B. A tiny p-value can mean **more** harm;
direction and discordant counts matter. Comparisons require complete
cohorts. Raw has zero harms by definition, so McNemar versus raw does not
prove useful cleanup. Speaker-cluster bootstrap uses 2,000 draws and seed
1029 for each accent; a wholly positive paired delta-raw interval fails
the accent bar. Owner take-bootstrap intervals describe this frozen owner.
These are pointwise intervals without multiple-comparison correction. Some
accent buckets have only two speakers, so they give limited population evidence.

Word alignment reports reference deletions, content deletions, additions,
substitutions, matched-word case/punctuation errors, and list layout.
“Content” excludes a fixed function-word/filler list; it is a deletion proxy,
not a part-of-speech or semantic-preservation score.
Independent raw/reference and output/reference alignments can reassign
duplicate words. Their lost/recovered reference matches are diagnostics,
not causal counts of speech lost or ASR repaired. The primary error budget
is raw/reference edits and the net change after cleanup. Intended filler
removal, self-corrections, and imperfect labels also enter that budget.

Every GPU/timing run holds regular-file `/tmp/velora-bench.lock` with
`fcntl.flock`. Owner settings come from the pinned snapshot copied into
disposable homes; SQLite opens `mode=ro`. The M4 Max (`Mac16,6`) has 36 GB
RAM and 14 logical CPUs, running macOS 27.0.1 and Python 3.12.14.
No study process controls the running app. Concurrent dictation and
thermal state remain uncontrolled. During the production runtime comparison,
load1 spans 351.27–710.13 on 14 CPU cores. Long-case timeouts and output
variation make this a contention diagnostic, not evidence of shipping latency
noninferiority. Earlier screening runs did not record load1. Their observed
p50/p90 values cannot establish a controlled speed advantage.

Screening timing includes token budgeting, synchronized first token,
greedy decoding, acceptance, and postprocessing with prefix snapshots.
It excludes STT, model load, production copy-draft/IPC, and native insertion.
MLX peak allocation and process peak RSS are reported separately in
decimal GB; neither is Apple's physical footprint. All quantizations are
the actual loaded builds, not inferred from model names.

Historical `engine.log` has 4,285 cleanup-inference records: total p50/p90
1,573/4,592.6 ms, logged TTFT 944/3,484 ms and decode 602/1,327.6 ms. These
are mixed historical versions, input lengths and workloads, not a controlled
current-model comparison. The production probe extends the #32 replay approach
through the real cleanup worker/IPC and copy-draft path, with disposable homes.
It still excludes microphone-to-insertion timing and power measurement.

## Priority owner303 and EdAcc results

Both specialists fail both cohorts. SimpleWords has slightly lower owner
mean wWER than shipped 2B, but more harms, fewer owner term fixes and slower
p90. Its public mean wWER is much higher. Keep the shipped small tier.
These compare complete model/prompt pipelines. Different bases, task data,
prompts and quantizations prevent attributing the difference to fine-tuning alone.

L = lexical recovery; D = aligned-term proxy. I/N = raw→output insertions /
output word types absent from both raw and reference, summed across takes.
N includes substitutions as well as inserted words. McNemar compares harms.

### Frozen owner303

| Arm | fWER % | wWER % | Exact | Harms | L fixes; D fixes | I/N | McNemar vs 4B / 2B |
|---|---:|---:|---:|---:|---|---:|---:|
| Raw | 10.8678 | 4.0868 | 82/303 | 0/303 | 0/156 (0.00%); 0/30 | 0/0 | — / — |
| 4B q8 | 10.5847 | 6.0727 | 80/303 | 91/303 | 46/156 (29.49%); 7/30 | 132/148 | — / 0.0192 |
| 2B q4 | 15.4804 | 7.2328 | 51/303 | 68/303 | 12/156 (7.69%); 1/30 | 310/86 | 0.0192 / — |
| SimpleWords q8 | 13.4581 | 7.0554 | 71/303 | 95/303 | 6/156 (3.85%); 0/30 | 46/38 | 0.767 / 0.0132 |
| WhisperNow q8 | 11.9629 | 7.3581 | 61/303 | 174/303 | 41/156 (26.28%); 1/30 | 212/245 | 1.73e-15 / 2.55e-20 |

| Arm | Total p50/p90 ms | TTFT p50/p90 ms | Peak MLX/RSS GB |
|---|---:|---:|---:|
| Raw | — | — | — |
| 4B q8 | 2125/8611 | 186/768 | 8.88/5.28 |
| 2B q4 | 538/3317 | 72/206 | 3.47/2.00 |
| SimpleWords q8 | 1118/4271 | 77/142 | 3.03/2.94 |
| WhisperNow q8 | 1486/5437 | 140/353 | 5.62/2.62 |

<details>
<summary>Frozen owner303: paired tests</summary>

W/L = wWER wins/losses; p = sign-test p. McNemar gives new/removed harms; p.

| Arm | vs raw W/L; p | vs 4B W/L; p | McNemar vs raw | McNemar vs 4B |
|---|---|---|---|---|
| 4B q8 | 32/91; 9.74e-08 | 0/0; 1 | 91/0; 8.08e-28 | 0/0; 1 |
| 2B q4 | 20/68; 2.77e-07 | 69/63; 0.664 | 68/0; 6.78e-21 | 33/56; 0.0192 |
| SimpleWords q8 | 27/95; 4.56e-10 | 76/84; 0.58 | 95/0; 5.05e-29 | 53/49; 0.767 |
| WhisperNow q8 | 26/174; 4.44e-28 | 50/147; 2.85e-12 | 174/0; 8.35e-53 | 100/17; 1.73e-15 |

</details>

### EdAcc593

| Arm | fWER % | wWER % | Exact | Harms | L fixes; D fixes | I/N | McNemar vs 4B / 2B |
|---|---:|---:|---:|---:|---|---:|---:|
| Raw | 97.7489 | 19.5653 | 0/593 | 0/593 | 0/1301 (0.00%) | 0/0 | — / — |
| 4B q8 | 97.4527 | 22.2474 | 0/593 | 164/593 | 7/1301 (0.54%) | 35/86 | — / 0.000225 |
| 2B q4 | 97.8085 | 21.4790 | 0/593 | 120/593 | 1/1301 (0.08%) | 161/60 | 0.000225 / — |
| SimpleWords q8 | 97.2570 | 28.1523 | 0/593 | 306/593 | 2/1301 (0.15%) | 34/39 | 1.56e-23 / 3.35e-35 |
| WhisperNow q8 | 97.2099 | 27.7198 | 0/593 | 379/593 | 13/1301 (1.00%) | 33/150 | 2.08e-49 / 5.7e-59 |

| Arm | Total p50/p90 ms | TTFT p50/p90 ms | Peak MLX/RSS GB |
|---|---:|---:|---:|
| Raw | — | — | — |
| 4B q8 | 844/2210 | 114/198 | 5.62/3.38 |
| 2B q4 | 299/896 | 52/82 | 2.19/1.98 |
| SimpleWords q8 | 350/1023 | 50/81 | 2.55/2.30 |
| WhisperNow q8 | 700/1946 | 91/177 | 5.02/2.72 |

<details>
<summary>EdAcc593: paired tests</summary>

W/L = wWER wins/losses; p = sign-test p. McNemar gives new/removed harms; p.

| Arm | vs raw W/L; p | vs 4B W/L; p | McNemar vs raw | McNemar vs 4B |
|---|---|---|---|---|
| 4B q8 | 17/164; 2.26e-31 | 0/0; 1 | 164/0; 8.55e-50 | 0/0; 1 |
| 2B q4 | 16/120; 6.91e-21 | 118/73; 0.00139 | 120/0; 1.5e-36 | 47/91; 0.000225 |
| SimpleWords q8 | 14/306; 9.96e-73 | 69/252; 1.25e-25 | 306/0; 1.53e-92 | 179/37; 1.56e-23 |
| WhisperNow q8 | 8/379; 7.52e-101 | 40/324; 2.23e-56 | 379/0; 1.62e-114 | 232/17; 2.08e-49 |

</details>

Owner 4B uses archived quality and fresh resource measurements; all 303
outputs are byte-identical. Fresh 2B also matches all 303 archived outputs.
These screening times are not production stop-to-insertion latency. Priority runs froze
inputs and settings within each run, but cross-run app/mode metadata hashes
were added only for v4 controls. Completed priority runs did not mix resumed
rows. Archive parity is verified for 4B/2B; the earlier metadata audit limit
remains disclosed rather than inferred away.

SimpleWords versus 2B harm McNemar: owner p=.0132; public p=3.35e-35,
both indicating more harm. Owner lexical fixes: 6/156 versus 12/156; aligned
terms: 0/30 versus 1/30. Public lexical fixes: 2/1,301 versus 1/1,301,
at the cost of 186 more harmed takes.

### Priority models by accent

<details>
<summary>All 12 accent buckets and paired confidence intervals</summary>

Cells give mean wWER %. Parentheses give the speaker-bootstrap 95% CI for
paired delta from raw in percentage points; raw parentheses give its wWER
CI. A wholly positive paired interval fails the frozen accent bar.

| Accent | Clips/speakers | Raw | 4B | 2B | SimpleWords | WhisperNow |
|---|---:|---|---|---|---|---|
| Caribbean | 50/6 | 28.29 (+18.61, +36.82) | 29.40 (+0.25, +2.34) | 28.84 (-0.05, +1.38) | 36.18 (+4.87, +11.72) | 36.89 (+5.82, +11.60) |
| East_African | 50/2 | 18.43 (+17.33, +19.53) | 20.89 (+1.91, +3.01) | 19.50 (+0.72, +1.40) | 25.87 (+6.37, +8.50) | 24.52 (+4.43, +7.74) |
| East_Asian | 50/5 | 21.02 (+13.95, +28.38) | 23.47 (+0.92, +3.98) | 22.06 (+0.29, +1.92) | 28.56 (+5.16, +9.42) | 30.27 (+7.49, +10.69) |
| European_L2 | 50/28 | 19.85 (+15.96, +23.89) | 21.08 (+0.01, +2.74) | 20.87 (-0.14, +2.23) | 28.66 (+4.75, +12.96) | 27.06 (+4.38, +10.11) |
| Indian_S_Asian | 43/5 | 14.30 (+10.78, +17.57) | 20.48 (+3.14, +8.94) | 16.81 (+0.47, +4.42) | 26.60 (+8.98, +17.16) | 26.18 (+8.59, +16.96) |
| Latin_American | 50/5 | 15.84 (+11.08, +20.61) | 17.90 (+1.21, +2.95) | 19.45 (+1.87, +5.09) | 23.65 (+4.83, +12.32) | 22.71 (+5.38, +9.02) |
| MENA | 50/3 | 13.88 (+11.49, +15.77) | 18.33 (+3.08, +5.59) | 16.65 (+1.12, +4.40) | 24.15 (+8.78, +11.51) | 23.95 (+7.99, +14.20) |
| SE_Asian | 50/13 | 30.14 (+24.22, +36.54) | 33.69 (+1.37, +6.54) | 30.66 (+0.14, +0.96) | 38.79 (+5.42, +12.44) | 36.65 (+4.05, +9.23) |
| Southern_African | 50/2 | 14.32 (+10.34, +18.30) | 15.61 (+0.88, +1.70) | 16.71 (+1.90, +2.87) | 17.73 (+3.14, +3.68) | 22.20 (+7.86, +7.89) |
| UK_IE | 50/22 | 16.61 (+12.26, +21.78) | 18.32 (+0.70, +2.85) | 18.74 (+1.18, +3.34) | 25.19 (+5.75, +11.70) | 21.83 (+3.40, +7.09) |
| US | 50/17 | 18.15 (+13.16, +23.95) | 20.20 (+0.36, +4.41) | 19.72 (+0.24, +2.98) | 28.07 (+6.51, +13.49) | 26.60 (+3.89, +13.03) |
| West_African | 50/6 | 23.20 (+16.86, +28.38) | 27.34 (+1.74, +6.96) | 27.09 (+1.92, +6.16) | 34.17 (+6.18, +15.40) | 33.56 (+7.17, +13.04) |

Aggregate priority-public-summary.json also retains per-accent mean-WER
intervals, word additions/recovery, and paired tests. Reproduction below
regenerates these totals without examples.

</details>

### Additional EdAcc controls

Vedu fails EdAcc: mean wWER is 22.9031% versus raw 19.5653% and
4B 22.2474%. It harms 197/593 clips versus 164/593 for 4B.
All five controls below have higher mean wWER than raw. Every accent has a
wholly positive delta-raw CI for Vedu and untrained Mini1 minimal. The guard
reduces 4B harms but still fails the raw floor and eight accent buckets.

| Control | wWER % | Delta raw pp [95% CI] | Harms | Positive accent CIs |
|---|---:|---:|---:|---:|
| Vedu Scribe 0.8B | 22.9031 | +3.34 [+2.75, +3.96] | 197/593 | 12/12 |
| 4B minimal prompt | 21.8301 | +2.26 [+1.87, +2.66] | 162/593 | 11/12 |
| 4B chunk4 | 22.2449 | +2.68 [+2.09, +3.33] | 172/593 | 11/12 |
| MiniCPM5-1B q4 minimal | 23.6274 | +4.06 [+3.16, +4.95] | 170/593 | 12/12 |
| 4B repair-unstructured guard | 20.6321 | +1.07 [+0.73, +1.38] | 86/593 | 8/12 |

Vedu fWER is 97.3738%; exact matches 0/593; raw→output insertions
1, novel word types 8, lexical recovery 0/1301. Public aligned-term
opportunities are zero. Its 33 additional harms versus 4B are significant; the
paired wWER sign test does not show lower wWER than 4B.

| Vedu comparator | wWER wins/losses | Sign p | New/removed harms | McNemar p |
|---|---:|---:|---:|---:|
| Raw | 15/197 | 1.19e-41 | 197/0 | 9.96e-60 |
| 4B q8 | 97/113 | 0.301 | 86/53 | 0.00643 |

| Vedu resources | Total p50/p90 ms | TTFT p50/p90 ms | Peak MLX/RSS GB |
|---|---:|---:|---:|
| EdAcc593 | 290.00/945.22 | 37.90/62.98 | 0.878/1.152 |

Vedu load is 2,280 ms, with zero worker errors; runtime MLX 0.31.2
and mlx-lm 0.31.3. These are observed screening resources under the
contention limits above.

<details>
<summary>Additional controls: paired delta-raw by accent</summary>

Cells give mean wWER change from raw and its speaker-bootstrap 95% CI in
percentage points. Positive values mean more error. Intervals are pointwise;
the low speaker counts documented above still apply.

| Accent | Clips | Vedu | 4B minimal | 4B chunk4 | Mini1 minimal | 4B guard |
|---|---:|---|---|---|---|---|
| Caribbean | 50 | +3.16 [+1.29, +5.69] | +1.49 [+0.66, +2.63] | +1.20 [+0.42, +2.34] | +1.68 [+0.81, +2.60] | +0.82 [+0.21, +1.79] |
| East_African | 50 | +2.77 [+0.90, +4.63] | +2.23 [+2.06, +2.40] | +2.84 [+1.95, +3.73] | +4.46 [+3.67, +5.24] | +1.74 [+1.64, +1.84] |
| East_Asian | 50 | +2.58 [+1.09, +4.27] | +2.19 [+1.14, +3.59] | +2.45 [+0.92, +3.98] | +3.34 [+1.67, +5.08] | +1.16 [+0.63, +1.76] |
| European_L2 | 50 | +3.12 [+1.06, +5.75] | +0.80 [-0.16, +1.84] | +0.96 [-0.12, +2.20] | +4.30 [+1.10, +8.72] | +0.29 [-0.58, +1.28] |
| Indian_S_Asian | 43 | +5.63 [+4.53, +6.51] | +3.30 [+1.48, +5.35] | +6.25 [+3.14, +9.09] | +5.79 [+4.77, +7.60] | +1.60 [-0.45, +3.88] |
| Latin_American | 50 | +2.61 [+0.97, +4.67] | +1.83 [+1.37, +2.31] | +1.98 [+1.21, +2.75] | +1.39 [+0.19, +2.79] | +1.63 [+1.07, +2.34] |
| MENA | 50 | +5.16 [+3.64, +7.58] | +3.67 [+3.46, +3.84] | +4.08 [+3.08, +4.71] | +9.20 [+8.46, +10.06] | +2.16 [+1.25, +3.67] |
| SE_Asian | 50 | +3.19 [+1.08, +5.97] | +2.91 [+1.10, +4.97] | +3.46 [+1.35, +6.49] | +5.60 [+2.54, +9.16] | +1.27 [+0.59, +2.04] |
| Southern_African | 50 | +2.47 [+1.76, +3.19] | +2.77 [+2.25, +3.30] | +1.36 [+1.02, +1.70] | +3.49 [+1.65, +5.32] | +0.43 [+0.29, +0.56] |
| UK_IE | 50 | +3.10 [+1.91, +4.45] | +1.95 [+0.93, +3.04] | +1.69 [+0.72, +2.78] | +3.09 [+1.36, +5.51] | +0.15 [-0.12, +0.54] |
| US | 50 | +3.17 [+2.02, +4.47] | +2.12 [+0.58, +4.15] | +1.99 [+0.36, +3.99] | +3.67 [+0.87, +7.07] | +0.50 [-0.38, +1.61] |
| West_African | 50 | +3.42 [+1.26, +5.96] | +2.07 [+1.04, +3.02] | +4.38 [+2.04, +6.93] | +3.00 [+1.92, +4.13] | +1.11 [+0.18, +1.94] |

</details>

Aggregate sources under `$STUDY`: `vedu-public-final-summary.json`,
`controls-public-final-summary.json`, `completed-public-final-summary.json`,
`guard-public-final-summary.json`, and `runs/vedu-public-v4-summary.json`.
Exact arm labels, in table order: `vedu-public-v4`, `minimal-4b-v4`,
`chunk4-4b-v4`, `minicpm1b-minimal-v4`, and
`priority-qwen4b-public-v1-pipeline-guard-repair-unstructured`.

## Supplemental public controls

Both models increase mean wWER against raw on both corpora. The 2B does not
establish an advantage over the 4B. Completed v5 controls use the same Default
prompt and verified public work hashes for shipped 4B 8-bit and 2B q4. AMI dev
has 100 clips from 11 speakers; VoxPopuli has 43 clips from 43 speakers.

AMI dev is internal validation for the public-only LoRA trial and cannot
independently qualify that adapter. VoxPopuli is edited formal speech, with
only 2–3 clips per L1 label. AMI references use fixed cleanup/case rules;
they are not handwritten dictation-cleanup labels. No L1 labels are available
for AMI.

Values are percentages. Brackets give speaker-bootstrap 95% CIs; delta is
paired wWER change from raw in percentage points. Exact and harm columns
are clip counts. All cohorts are complete, with zero worker errors.

AMI dev100:

| Corpus | Arm | wWER [95% CI] | Delta raw [95% CI] | fWER | Exact | Harms |
|---|---|---:|---:|---:|---:|---:|
| AMI100 | Raw | 15.26 [12.34, 18.61] | 0 | 25.09 | 3 | 0 |
| AMI100 | 4B 8-bit | 16.80 [13.65, 20.24] | +1.54 [+0.74, +2.43] | 27.07 | 2 | 16 |
| AMI100 | 2B q4 | 16.84 [13.84, 20.22] | +1.58 [+0.82, +2.42] | 26.69 | 3 | 19 |

VoxPopuli43:

| Corpus | Arm | wWER [95% CI] | Delta raw [95% CI] | fWER | Exact | Harms |
|---|---|---:|---:|---:|---:|---:|
| Vox43 | Raw | 19.20 [13.53, 26.20] | 0 | 36.71 | 0 | 0 |
| Vox43 | 4B 8-bit | 20.10 [14.23, 27.18] | +0.90 [+0.19, +1.81] | 40.19 | 0 | 8 |
| Vox43 | 2B q4 | 20.29 [14.60, 27.10] | +1.09 [+0.44, +1.91] | 38.86 | 0 | 11 |

Additions align output against raw and include legitimate recovery. Novel
types occur in neither raw nor reference; substitutions can introduce them
without an aligned insertion. Lexical recovery uses the word-type proxy
defined above. No public glossary is supplied, so aligned-term opportunities
are zero.

| Corpus | Arm | Aligned additions | Novel types | Lexical recovery |
|---|---|---:|---:|---:|
| AMI100 | 4B 8-bit | 0 | 5 | 1/191 |
| AMI100 | 2B q4 | 4 | 4 | 0/191 |
| Vox43 | 4B 8-bit | 3 | 5 | 1/132 |
| Vox43 | 2B q4 | 2 | 6 | 1/132 |

Tests below are exact, paired and two-sided. New/removed harms give direction;
the small p-values versus raw indicate more harm. The 2B/4B comparisons are
inconclusive on these samples.

AMI paired tests:

| Corpus | Arm vs comparator | wWER wins/losses | Sign p | New/removed harms | McNemar p |
|---|---|---:|---:|---:|---:|
| AMI100 | 4B vs raw | 0/16 | .0000305 | 16/0 | .0000305 |
| AMI100 | 2B vs raw | 0/19 | .00000381 | 19/0 | .00000381 |
| AMI100 | 2B vs 4B | 12/14 | .8450 | 13/10 | .6776 |

VoxPopuli paired tests:

| Corpus | Arm vs comparator | wWER wins/losses | Sign p | New/removed harms | McNemar p |
|---|---|---:|---:|---:|---:|
| Vox43 | 4B vs raw | 1/8 | .03906 | 8/0 | .007813 |
| Vox43 | 2B vs raw | 1/11 | .006348 | 11/0 | .0009766 |
| Vox43 | 2B vs 4B | 2/4 | .6875 | 4/1 | .3750 |

Vox L1 counts remain sparse diagnostics. Each clip has a distinct speaker;
no per-L1 significance or replacement claim is made.

<details>
<summary>All 15 sparse VoxPopuli L1 groups</summary>

| Vox L1 label | Clips | 4B harms | 2B harms |
|---|---:|---:|---:|
| en_cs | 3 | 0 | 1 |
| en_de | 3 | 0 | 1 |
| en_es | 3 | 0 | 0 |
| en_et | 3 | 2 | 1 |
| en_fi | 3 | 1 | 2 |
| en_fr | 3 | 0 | 0 |
| en_hr | 2 | 1 | 1 |
| en_hu | 3 | 2 | 2 |
| en_it | 3 | 1 | 1 |
| en_lt | 2 | 0 | 0 |
| en_nl | 3 | 0 | 0 |
| en_pl | 3 | 0 | 0 |
| en_ro | 3 | 0 | 1 |
| en_sk | 3 | 0 | 0 |
| en_sl | 3 | 1 | 1 |

</details>

`score_supplements.py` imports the shared scorer's pure metric functions.
It verifies frozen public source hashes, human references, replay sidecars,
exact output membership, pinned model revisions, and regenerated public
gate/input-work hashes before scoring. It opens no owner data or Dictionary,
creates no transcript copies, and never turns model outputs into targets.
The aggregate source hashes, CIs, additions/recovery diagnostics and all
paired comparisons are retained in `supplemental-final-analysis.md`.

```sh
python3 "$STUDY/score_supplements.py"
```

## Archived baselines and earlier arms

All earlier files were rescored against the frozen membership. The original
`score_gold.py` also ran on stored history final and all seven `oc-*` arms;
rounded fWER/wWER and per-set harm counts agree. Its added-word column counts
takes with novel additions; this report separately counts aligned inserted
words. History has 24 null `cleanup_applied` values, so its original rejection
column is not a valid rejection count.

The complete 303-take baselines follow. W/L;p compares wWER; N/R;p compares
new/removed harms. L/D are lexical/aligned-term fixes. Archived runs have no
comparable peak RAM; current priority reruns supply only the 4B/2B resources.

<details>
<summary>All seven complete archived owner arms</summary>

| Archive | n | fWER % | wWER % | Exact | Harms | Added words | L/D | vs raw W/L;p | vs 4B W/L;p | Harm N/R;p vs 4B |
|---|---:|---:|---:|---:|---:|---:|---|---|---|---|
| oc-minicpm5 | 303 | 11.3618 | 4.6587 | 79 | 30 | 11 | 5/156; 0/30 | 14/30; 0.0226 | 85/39; 4.41e-05 | 13/74; 1.59e-11 |
| oc-muesli08 | 303 | 10.8341 | 5.2207 | 72 | 105 | 21 | 16/156; 0/30 | 38/105; 1.89e-08 | 80/78; 0.937 | 56/42; 0.189 |
| oc-muesli2b | 303 | 11.1373 | 5.7391 | 74 | 109 | 34 | 23/156; 0/30 | 39/109; 7.46e-09 | 77/84; 0.636 | 60/42; 0.0918 |
| oc-qwen2b | 303 | 15.4804 | 7.2328 | 51 | 68 | 310 | 12/156; 1/30 | 20/68; 2.77e-07 | 69/63; 0.664 | 33/56; 0.0192 |
| oc-qwen4b | 303 | 10.5847 | 6.0727 | 80 | 91 | 132 | 46/156; 7/30 | 32/91; 9.74e-08 | 0/0; 1 | 0/0; 1 |
| oc-s1mini | 303 | 9.0376 | 4.3265 | 79 | 52 | 48 | 24/156; 1/30 | 49/52; 0.842 | 97/41; 2.09e-06 | 21/60; 1.69e-05 |
| oc-vedu08 | 303 | 8.3162 | 3.7896 | 96 | 29 | 4 | 7/156; 1/30 | 58/29; 0.00248 | 110/30; 6.25e-12 | 12/74; 4.69e-12 |

</details>

Vedu alone beats pooled owner raw (3.7896% versus 4.0868%); its term trade
is 7/156 lexical and 1/30 aligned fixes versus 4B 46/156 and 7/30. The
frozen bar permits a quantified term trade, so Vedu received the required
EdAcc replay. It fails there, as shown in Additional EdAcc controls.
MiniCPM2B and S1-mini beat 4B but remain above raw; Muesli also fails.

<details>
<summary>Earlier 104-take and empty arms</summary>

These rows use only the 104 pinned dev takes, whose raw mean wWER is
3.5779%. They are not full303 results. Complete dev-set pairing is separate
from incomplete full303 pairing. No earlier distilled weights or teacher
outputs become training data in this study.

| Archive | n | fWER % | wWER % | Exact | Harms | Added words | L/D | vs raw W/L;p | vs 4B W/L;p | Harm N/R;p vs 4B |
|---|---:|---:|---:|---:|---:|---:|---|---|---|---|
| ft-muesli08-own | 104 | 11.6143 | 5.3505 | 15 | 46 | 11 | 8/81; 0/13 | 16/46; 0.000176 | 31/36; 0.625 | 25/15; 0.154 |
| ft-muesli2b-own | 104 | 11.5414 | 5.2237 | 16 | 47 | 12 | 8/81; 0/13 | 17/47; 0.000227 | 30/37; 0.464 | 26/15; 0.117 |
| ft-vedu08-own | 104 | 9.0084 | 3.6491 | 21 | 16 | 0 | 2/81; 0/13 | 26/16; 0.164 | 44/14; 0.0001 | 7/27; 0.000821 |
| lfm3-8bit | 104 | 17.3918 | 10.1089 | 18 | 15 | 526 | 0/81; 0/13 | 0/15; 6.1e-05 | 32/22; 0.22 | 10/31; 0.00145 |
| lfm3-8bit-ft344 | 104 | 14.1575 | 7.6175 | 13 | 50 | 59 | 8/81; 0/13 | 4/50; 3.8e-11 | 26/42; 0.0681 | 31/17; 0.0595 |
| lfm3-8bit-ft344-rp | 104 | 16.8383 | 9.9228 | 10 | 57 | 48 | 5/81; 0/13 | 5/57; 3.07e-12 | 21/53; 0.000256 | 35/14; 0.0038 |
| lfm3-8bit-ft688 | 104 | 10.3667 | 4.5576 | 13 | 40 | 33 | 9/81; 0/13 | 8/40; 3.31e-06 | 29/29; 1 | 20/16; 0.618 |
| lfm3-8bit-ft688-rp | 104 | 12.1517 | 5.5408 | 16 | 51 | 36 | 8/81; 0/13 | 7/51; 2.4e-09 | 25/40; 0.0817 | 26/11; 0.0201 |
| lfm3-8bit-r2 | 104 | 11.0075 | 4.9929 | 19 | 37 | 39 | 8/81; 0/13 | 10/37; 9.85e-05 | 32/25; 0.427 | 15/14; 1 |
| lfm3-fused-r1 | 104 | 10.4351 | 4.5226 | 13 | 39 | 33 | 9/81; 0/13 | 8/39; 5.54e-06 | 30/30; 1 | 21/18; 0.749 |
| minicpm5-2b-4bit | 104 | 11.2796 | 4.2161 | 18 | 14 | 7 | 2/81; 0/13 | 3/14; 0.0127 | 31/17; 0.0595 | 5/27; 0.000113 |
| qwen2b-4bit | 104 | 16.2080 | 7.2975 | 9 | 27 | 107 | 3/81; 0/13 | 6/27; 0.000324 | 29/28; 1 | 14/23; 0.188 |
| qwen2b-4bit-rp | 104 | 16.9677 | 8.4985 | 10 | 28 | 189 | 3/81; 0/13 | 8/28; 0.00119 | 30/28; 0.896 | 12/20; 0.215 |
| teacher | 104 | 12.7304 | 6.5991 | 11 | 41 | 122 | 14/81; 1/13 | 9/41; 5.61e-06 | 7/19; 0.029 | 7/2; 0.18 |
| teacher-run2 | 104 | 12.7304 | 6.5991 | 11 | 41 | 122 | 14/81; 1/13 | 9/41; 5.61e-06 | 7/19; 0.029 | 7/2; 0.18 |
| teacher-snap1 | 104 | 12.7304 | 6.5991 | 11 | 41 | 122 | 14/81; 1/13 | 9/41; 5.61e-06 | 7/19; 0.029 | 7/2; 0.18 |

Zero matching frozen rows: `ft-muesli2b-velora`, `lfm3-8bit-ft172`, `qwen4b-8bit`, `teacher-partial`, `teacher-synth`, `vl6-card`, `vl6-greedy`.
These are unavailable comparisons, not zero-error successes. The invalid
initial live-input 4B replay is excluded because its inputs were not frozen.

</details>

## Pipeline, runtime, and remaining candidates

### Remaining candidate screens

All four candidates fail the mandatory owner303 quality screen. Their
conditional EdAcc replays were skipped; none has an accent pass.
Granite/MiniCPM/Gemma use Velora's messages through native templates;
Kanso uses its trained system/user roles and 200/400-token caps.
All use greedy decoding and their verified thinking-off contracts.

L/D are lexical/aligned-term recovery. I/N counts aligned raw-to-output
insertions / novel output word types absent from raw and reference.

| Arm | fWER % | wWER % | Exact | Harms | L/D fixes | I/N | Product failures /27 |
|---|---:|---:|---:|---:|---|---:|---:|
| Granite4.2 q8 | 13.0079 | 6.3645 | 73/303 | 50/303 | 6/156; 0/30 | 157/204 | 9 |
| MiniCPM5-1B q4 | 14.8813 | 8.3541 | 74/303 | 45/303 | 9/156; 0/30 | 64/113 | 22 |
| Kanso Satori q4 | 11.6932 | 5.2445 | 71/303 | 85/303 | 15/156; 0/30 | 40/32 | 16 |
| Gemma4 E2B mixed q4/q8 | 12.1702 | 6.4579 | 71/303 | 104/303 | 26/156; 3/30 | 89/89 | 9 |

W/L;p is the paired sign test; N/R;p is McNemar new/removed harms.

| Arm | vs raw W/L;p | vs 4B W/L;p | vs raw N/R;p | vs 4B N/R;p |
|---|---|---|---|---|
| Granite4.2 q8 | 11/50; 4.589e-07 | 80/62; 0.1534 | 50/0; 1.776e-15 | 27/68; 3.114e-05 |
| MiniCPM5-1B q4 | 12/45; 1.313e-05 | 83/60; 0.06543 | 45/0; 5.684e-14 | 28/74; 5.908e-06 |
| Kanso Satori q4 | 44/85; 0.0003872 | 93/69; 0.07043 | 85/0; 5.17e-26 | 47/53; 0.6173 |
| Gemma4 E2B mixed q4/q8 | 26/104; 3.026e-12 | 73/79; 0.6852 | 104/0; 9.861e-32 | 52/39; 0.2082 |

Owner303 quantiles below use all 303 retained timing rows. The folded
dev104/SW199 breakdown is separate; averaging its quantiles would be invalid.
Screening excludes STT/native insertion and shares the contention limits.
Peaks include earlier cohorts in the same process. GB is decimal; core and
Metal versions match within each run. These are observed screening resources,
not controlled shipping noninferiority measurements.

| Arm / owner303 | Total p50/p90 ms | TTFT p50/p90 ms | Peak MLX/RSS GB | Runtime: core / LM / Transformers |
|---|---:|---:|---:|---|
| Granite4.2 q8 | 2621.0/10533.9 | 183.5/587.2 | 10.144/1.678 | 0.32.4 / 0.32.2 / 5.7.0 |
| MiniCPM5-1B q4 | 620.1/2182.0 | 56.9/156.5 | 2.970/1.301 | 0.31.2 / 0.31.3 / 5.3.0 |
| Kanso Satori q4 | 1074.4/3884.5 | 123.4/280.5 | 3.201/3.030 | 0.31.2 / 0.31.3 / 5.3.0 |
| Gemma4 E2B mixed q4/q8 | 1613.0/7719.5 | 119.0/451.2 | 4.956/1.931 | 0.32.4 / 0.32.2 / 5.7.0 |

<details>
<summary>Separate dev104 and SW199 resource totals</summary>

| Arm / set | n | Total p50/p90 ms | TTFT p50/p90 ms | Peak MLX/RSS GB | Runtime: core / LM / transformers |
|---|---:|---:|---:|---:|---|
| Granite4.2 q8 / dev104 | 104 | 3613.4/12254.8 | 224.9/729.6 | 6.785/1.678 | 0.32.4 / 0.32.2 / 5.7.0 |
| Granite4.2 q8 / SW199 | 199 | 2061.4/8873.4 | 162.4/491.1 | 10.144/1.678 | 0.32.4 / 0.32.2 / 5.7.0 |
| MiniCPM5-1B q4 / dev104 | 104 | 683.5/2527.9 | 63.5/198.8 | 1.975/1.301 | 0.31.2 / 0.31.3 / 5.3.0 |
| MiniCPM5-1B q4 / SW199 | 199 | 578.0/1993.2 | 54.8/132.7 | 2.970/1.301 | 0.31.2 / 0.31.3 / 5.3.0 |
| Kanso Satori q4 / dev104 | 104 | 1515.7/3793.6 | 148.4/334.1 | 3.201/3.030 | 0.31.2 / 0.31.3 / 5.3.0 |
| Kanso Satori q4 / SW199 | 199 | 925.9/4008.2 | 111.3/253.2 | 3.201/3.030 | 0.31.2 / 0.31.3 / 5.3.0 |
| Gemma4 E2B mixed q4/q8 / dev104 | 104 | 3063.2/8122.4 | 143.9/570.1 | 4.573/1.931 | 0.32.4 / 0.32.2 / 5.7.0 |
| Gemma4 E2B mixed q4/q8 / SW199 | 199 | 1252.8/6606.2 | 110.0/427.7 | 4.956/1.931 | 0.32.4 / 0.32.2 / 5.7.0 |

</details>

| Arm | Owner-screen disposition | Conditional EdAcc status |
|---|---|---|
| Granite4.2 q8 | Fails: mean wWER exceeds raw and 4B | Skipped after mandatory owner failure; no accent pass claimed |
| MiniCPM5-1B q4 | Fails: mean wWER exceeds raw and 4B | Skipped after mandatory owner failure; no accent pass claimed |
| Kanso Satori q4 | Fails: mean wWER exceeds raw; harm McNemar p≥.05 | Skipped after mandatory owner failure; no accent pass claimed |
| Gemma4 E2B mixed q4/q8 | Fails: mean wWER exceeds raw and 4B; harms exceed 4B; harm McNemar p≥.05 | Skipped after mandatory owner failure; no accent pass claimed |

Source totals: each `<label>-owner-score.json`, `runs/<label>-summary.json`,
and `remaining-status.json` in scratch. No private row is reproduced.

### Content fallback

Compare prepared, unencoded gate text with accepted cleanup output. Bypass
passthrough, model-free gates, romanization, and existing rejected output.
Fallback returns gate text. No reference label enters a trigger.

| 4B pipeline | Owner wWER % / harms | Owner L / D fixes | EdAcc wWER % / harms | EdAcc L fixes | Product failures /27 |
|---|---:|---:|---:|---:|---:|
| Current | 6.0727 / 91 | 46 / 7 | 22.2474 / 164 | 7 | 1 |
| Missing content types | 4.7113 / 47 | 5 / 0 | 20.0707 / 65 | 1 | 13 |
| Aligned content deletion | 4.7104 / 51 | 33 / 5 | 19.8591 / 53 | 4 | 11 |
| Repair-preserving | 5.8588 / 82 | 46 / 7 | 20.6201 / 85 | 7 | 8 |
| Repair-preserving, lists bypassed | 5.8619 / 83 | 46 / 7 | 20.6321 / 86 | 7 | 1 |

Owner denominators are 156 lexical and 30 aligned-term opportunities;
EdAcc has 1,301 lexical opportunities. Strict guards sacrifice recovery.
The repair-preserving trigger requires an aligned content deletion, zero
substitutions, and no declared retraction cue. Its seven new product failures
blocked valid list transformations. The follow-up bypasses recognized list
markers in either input or output. This follows benchmark feedback; the
reused 27 cases are a regression check, not new held-out evidence. The frozen
corpora have earlier-arm results; this is exploratory pipeline selection,
not fresh-user confirmation. The trigger itself never reads gold.

The list-bypass version passes the declared offline pipeline test: 4B harms
fall 91→83 and 164→86, with recovery counts unchanged. It creates zero new harms in
either cohort; paired McNemar p=.0078125 and 6.62e-24. It adds no product
failures. Against 4B, the guard has 8/3 owner wWER wins/losses and 79/1
public wins/losses. The three owner and one public regressions create no new
raw-relative harms; the owner sign test is inconclusive (p=.2266).
It still exceeds raw wWER and does not satisfy the model replacement bar.
It misses deletions accompanied by substitutions, retraction cues or lists;
it cannot guarantee content preservation.

The same guard on shipped 2B reduces harms 68→61 and 120→77. Lexical-fix
counts remain 12/156 and 1/1,301; owner aligned-term fixes remain 1/30.
McNemar versus 2B is .015625 and 2.27e-13. Its existing 11/27 product
failures remain. List bypass is more frequent on 2B; this does not establish
equivalent protection across tiers.

Guard-only CPU p50/p90 is 0.172/2.137 ms on owner-plus-benchmark rows and
0.057/0.351 ms on EdAcc; maximums are 53.58/1.68 ms. This includes the
decision and row copy, excluding preparation, I/O and model inference. Offline
transformation does not establish integrated latency or combined peak RAM.
Those checks and fresh-user dogfood precede enabling it by default.

### Minimal editing and sentence chunks

The declared minimal prompt raises owner wWER to 6.6584%, with 103 harms,
43/156 lexical fixes and 7/30 aligned terms. EdAcc improves relative to 4B
to 21.8301%, but remains above raw: 162 harms and 4/1,301 lexical fixes.
Harm McNemar versus 4B is .1114 owner and .9063 public. Product failures rise
1→11. Reject this prompt.

The sentence arm groups four punctuation-delimited spans, cleans each, then
applies the original global acceptance/postprocessing. It can split
abbreviations and list ordinals; punctuation-free input stays whole.
[DRES §3.5](https://arxiv.org/html/2509.20321v2) tests four-sentence segmentation
on human Switchboard deletion-only edits;
it does not prove four sentences optimal for ASR, accents, or Velora latency.
Chunking raises harms to 106 owner and 172 public, versus 91/164. Owner
lexical fixes rise 46→48, with 7 aligned terms unchanged; public fixes stay
7. Mean wWER is 6.0666%/22.2449%, essentially unchanged. Owner harm McNemar
p=.00408 indicates more harm (20 new, 5 removed); public p=.0768 (12/4).
Product failures rise 1→4. Reject this four-sentence rule. The runtime
controls below also fail to justify changing the shipped stack.

### Matched small-model prompt control

Untrained MiniCPM5-1B on the fixed minimal prompt has owner wWER 8.4041%,
63/303 harms, 4/156 lexical fixes and 0/30 aligned fixes. EdAcc wWER is
23.6274%, with 170/593 harms and 2/1,301 lexical fixes. Its 18/27 product
failures establish the matching starting point for the public-only pilot.
Fewer harmed owner takes than 4B does not offset much larger mean error;
the frozen bar requires both. These results do not qualify it as a replacement.

### MLX runtime and production replay

Keep the shipped runtime. The 0.32 upgrades do not meet the declared runtime
gate: unchanged quality/recovery, no added synthetic failures, and controlled
p90/RAM no worse. A faster repeated-case median alone cannot establish cold
stop-to-insertion latency.

<details>
<summary>Runtime versions and measurement boundary</summary>

The completed production probe uses the same 4B q8 checkpoint, real
`CleanupProcess` worker/IPC, copy drafts and copied frozen settings. Two
ABBA rounds per comparison, five requests per bucket/block, produce 16 blocks
and 320 measured requests. Buckets contain 14, 18, 43 and 182 words. OLD is
MLX/Metal 0.31.2, LM 0.31.3, Transformers 5.3.0. CORE changes only MLX/Metal
to 0.32.4. NEW uses MLX/Metal 0.32.4, LM 0.32.2, Transformers 5.7.0 and a
disposable cache-state API shim; this is a combined runtime change.

Wall runs from cleanup IPC invocation through external postprocess. Explicit
prefix preparation, policy/prompt assembly, model load, STT and native
insertion are outside that boundary. Worker TTFT includes tokenization,
cache restoration and prefill through the first generation response; it
excludes parent IPC and the worker executor queue.

</details>

| Runtime | Requests | Wall p50/p90 ms | TTFT p50/p90 ms | Peak MLX/worker RSS GB |
|---|---:|---:|---:|---:|
| OLD, pooled | 160 | 1843/6947 | 398/906 | 5.344/3.411 |
| CORE | 80 | 2211/6939 | 513/1195 | 5.359/3.351 |
| NEW + shim | 80 | 1547/6798 | 335/677 | 5.359/4.476 |

These are whole-runtime request quantiles. OLD pools two sequential
comparisons; each candidate uses its own comparison. The pooled OLD row is
therefore not a matched comparator. The saved report retains block quantiles
and whole-runtime totals but discards individual requests. Exact pooled OLD
quantiles within each comparison cannot be reconstructed; averaging block
quantiles would not recover them.

<details>
<summary>ABBA ranges, failures, hash parity and timing limits</summary>

The table below preserves each comparison separately. Cells give the range
of four block wall p90 values, OLD → candidate, in ms. Each block/bucket has
five requests; each runtime/comparison/bucket has 20. These ranges are neither
pooled p90 estimates nor confidence intervals.

| Bucket/words | OLD → CORE block p90 range | OLD → NEW block p90 range |
|---|---:|---:|
| Short/14 | 1248–1947 → 979–2056 | 682–1354 → 816–1495 |
| Grammar/18 | 1422–3377 → 2052–3210 | 1021–1539 → 1146–2299 |
| List/43 | 2338–4880 → 2193–3103 | 1829–2493 → 1269–2516 |
| Long/182 | 6872–7890 → 7079–7960 | 6926–7245 → 6664–8343 |

All blocks completed, but functional checks and exact-output parity both
fail. Within CORE's comparison, OLD/CORE have 38/32 timeouts, 6/10 anchor
failures and 11/4 list failures. Within NEW's comparison, OLD/NEW have 20/21
timeouts, 0/2 anchor failures and 0/0 list failures. NEW worker peak RSS is
4.476 GB versus its matched OLD blocks' 3.016 GB. MLX peaks retain load and
warm-up; RSS and MLX allocation remain separate memory measures.

All 111 measured fallbacks are timeouts. The long case falls back in 40/40
pooled OLD, 18/20 CORE and 19/20 NEW requests; these timings mostly describe
deadline/fallback behavior. OLD itself varies in output during the CORE
comparison. Relative to each comparison's first OLD output, CORE matches
20/10/16/18 of 20 short/grammar/list/long requests; NEW matches 20/18/20/19.
Matching raw fallback hashes does not establish successful cleanup parity.

Host load1 spans 351.27–710.13; concurrent app use and thermal state remain
uncontrolled. This is a contention diagnostic, not a causal runtime speed
or quality comparison. Separate 27-case screening wall p90 is 6747 ms OLD,
7158 CORE and 7956 NEW, with exactly 1/27 product failures in each run.
Equal failure totals do not establish identical wording or failures. Full frozen
owner/public upgrade quality and controlled p90/RAM noninferiority remain
unverified. The missing within-comparison pooled percentiles do not change
the keep decision. A shipping speed claim still needs a controlled low-load run.

</details>

### Idle keep-warm probe

Keep the idle tick off. The probe uses one synthetic ftlib greedy case,
two OFF/ON/ON/OFF rounds per gap and four requests per arm/gap. ON evaluates
a scalar MLX addition every 200 ms. All 24 outputs are byte-identical and
all runs finish `ok`.

| Idle gap | OFF TTFT p50/p90 ms | ON TTFT p50/p90 ms | OFF wall p50/p90 ms | ON wall p50/p90 ms |
|---|---:|---:|---:|---:|
| 0.5 s | 73/181 | 93/110 | 562/1204 | 811/1281 |
| 2 s | 159/930 | 189/1091 | 530/1284 | 507/1445 |
| 6 s | 1104/1264 | 1229/1677 | 1420/1634 | 1570/2034 |

ON TTFT p90 is 17% higher after 2 seconds and 33% higher after 6 seconds;
the 0.5-second TTFT improvement does not extend to wall latency. This tiny
probe does not establish a cold dictation benefit. It excludes production
copy drafts/IPC, STT and insertion. Load1, RSS, temperature and power were
not collected; lifetime MLX peak is 5.625 GB without per-arm resets. Battery
cost remains unmeasured, so this is no basis for a default-on keep-warm task.
MTP was not tested: contention leaves the required TTFT attribution unresolved.

## Action Mode

Keep the 4B as the Action default. Fresh native scores are 56/62 on
revision 1 and 58/62 on revision 2. None of the seven other compatible
checkpoints beats it. Switching is unsupported; no Action fine-tune or
per-take router was evaluated. The cleanup LoRA has zero Action targets.
All 62 decisions remain evaluation-only.

| Checkpoint | Native revision 1 | Native revision 2 | Finding |
|---|---:|---:|---|
| Qwen3.5 4B q8 | 56/62 | 58/62 | Retain default |
| Granite4.2 3B q8 | 51/62 | 53/62 | Fewer correct decisions |
| Gemma4 E2B mixed q4/q8 | 52/62 | 52/62 | Fewer correct decisions |
| Qwen3.5 2B q4 | 52/62 | 52/62 | Six losses, zero wins against 4B on revision 2; p=.03125 |
| MiniCPM5 1B / 2B q4 | Label refusal | Label refusal | Bare-label diagnostics also score lower |

All 22 native model/revision outcomes are recorded: 16 complete 62-item
runs and six compatibility failures. Both MiniCPM5 tokenizers add special
tokens to standalone option letters and fail the native single-token
contract before scoring. Production `cleanup.py:1454` and the benchmark
both use `tokenizer.encode(label)` with the same default. Production
returns a decision error for caller fallback. WhisperNow fails in both
revisions; CPU template preflight independently finds unsupported system
messages. These failures have no accuracy denominator.

The six synthetic categories cover routing, chat selection, navigation,
conversation identity, sent-state checks and YouTube result selection.
Revision 2 repairs selected-chat-row states: 17 UI-state strings and two
embedded option descriptions change; IDs, gold answers and question
instructions remain fixed. Compare models within a revision. No live
Action, tool execution, recovery, permission flow or unseen app was tested.

Accuracy counts forced choices without the production confidence gates
in `action_fastpath.py:250`. Saved minimum label mass cannot recover
thresholded coverage or execution success. Per-category winners on these
62 cases do not validate a router. An Action fine-tune would require new
human-written training targets and a separate held-out execution set.

<details>
<summary>All native scores, categories, paired tests and resources</summary>

Category columns list correct counts in this order: route / chat / nav /
header / sent / YouTube, with denominators 26/8/8/9/6/5. W/L counts candidate
wins/losses against the fresh 4B on the same revision; p is exact two-sided
McNemar. Tests are unadjusted screens. Accuracy intervals are 95% Wilson
intervals on these fixed cases.

| Checkpoint | Revision | Correct/62; 95% CI | W/L | p | Category correct | Minimum label mass |
|---|---:|---|---:|---:|---|---:|
| Qwen3.5 4B q8 | 1 | 56/62; 80.5–95.5% | 0/0 | 1 | 26/6/8/8/4/4 | 0.9989 |
| MiniCPM5 1B q4 | 1 | Label refusal; 0 scored | — | — | — | — |
| MiniCPM5 2B q4 | 1 | Label refusal; 0 scored | — | — | — | — |
| Granite4.2 3B q8 | 1 | 51/62; 71.0–89.8% | 3/8 | 0.226563 | 26/7/7/5/2/4 | 0.9923 |
| Gemma4 E2B mixed q4/q8 | 1 | 52/62; 72.8–91.0% | 2/6 | 0.289063 | 26/6/6/6/4/4 | 0.9894 |
| SimpleWords v2 q8 | 1 | 35/62; 44.1–68.1% | 3/24 | 4.92334e-05 | 18/6/4/4/2/1 | 0.6412 |
| WhisperNow q8 | 1 | Child error; unscored | — | — | — | — |
| Kanso Satori DWQ q4 | 1 | 18/62; 19.2–41.3% | 2/40 | 4.11092e-10 | 5/2/4/4/2/1 | 0.0028 |
| Vedu Scribe 0.8B mixed q4/q8 | 1 | 25/62; 29.0–52.7% | 3/34 | 1.23313e-07 | 7/4/4/5/2/3 | 0.8830 |
| s1-mini BF16 | 1 | 17/62; 17.9–39.6% | 2/41 | 2.15323e-10 | 6/1/4/4/2/0 | 0.0061 |
| Qwen3.5 2B q4 | 1 | 52/62; 72.8–91.0% | 1/5 | 0.21875 | 24/7/8/6/3/4 | 0.9562 |
| Qwen3.5 4B q8 | 2 | 58/62; 84.6–97.5% | 0/0 | 1 | 26/7/8/9/4/4 | 0.9984 |
| MiniCPM5 1B q4 | 2 | Label refusal; 0 scored | — | — | — | — |
| MiniCPM5 2B q4 | 2 | Label refusal; 0 scored | — | — | — | — |
| Granite4.2 3B q8 | 2 | 53/62; 74.7–92.2% | 0/5 | 0.0625 | 26/7/7/7/2/4 | 0.9923 |
| Gemma4 E2B mixed q4/q8 | 2 | 52/62; 72.8–91.0% | 1/7 | 0.0703125 | 26/6/6/6/4/4 | 0.9894 |
| SimpleWords v2 q8 | 2 | 34/62; 42.5–66.6% | 2/26 | 3.03239e-06 | 18/5/4/4/2/1 | 0.7004 |
| WhisperNow q8 | 2 | Child error; unscored | — | — | — | — |
| Kanso Satori DWQ q4 | 2 | 18/62; 19.2–41.3% | 2/42 | 1.12664e-10 | 5/2/4/4/2/1 | 0.0028 |
| Vedu Scribe 0.8B mixed q4/q8 | 2 | 25/62; 29.0–52.7% | 2/35 | 1.02445e-08 | 7/4/4/5/2/3 | 0.8830 |
| s1-mini BF16 | 2 | 17/62; 17.9–39.6% | 2/43 | 5.88898e-11 | 6/1/4/4/2/0 | 0.0073 |
| Qwen3.5 2B q4 | 2 | 52/62; 72.8–91.0% | 0/6 | 0.03125 | 24/7/8/6/3/4 | 0.9584 |

Each time measures independent full-prompt tokenization, one forward pass,
option probabilities and choice decoding, after one excluded warm-up.
Production `cleanup.py:1541` shares state/prefix caches across questions;
this screen does not measure that batching, IPC, or complete Action
latency. Peak MLX allocation and process RSS include model-load/warm-up
high-water marks. They are separate measures, not physical footprint.
The running app, host load and thermal state were uncontrolled.

OLD = MLX 0.31.2 / mlx-lm 0.31.3 / Transformers 5.3.0.
NEW = MLX 0.32.4 / mlx-lm 0.32.2 / Transformers 5.7.0.

| Checkpoint | Revision | Runtime | Decision p50/p90 ms | Peak MLX GB | Peak RSS GB |
|---|---:|---|---:|---:|---:|
| Qwen3.5 4B q8 | 1 | OLD | 1034.10/1450.98 | 5.592 | 1.773 |
| MiniCPM5 1B q4 | 1 | OLD | — | — | 1.056 |
| MiniCPM5 2B q4 | 1 | OLD | — | — | 2.052 |
| Granite4.2 3B q8 | 1 | OLD | 766.85/1021.20 | 4.657 | 3.718 |
| Gemma4 E2B mixed q4/q8 | 1 | NEW | 550.85/863.61 | 4.478 | 4.349 |
| SimpleWords v2 q8 | 1 | OLD | 445.55/691.33 | 3.241 | 2.911 |
| WhisperNow q8 | 1 | NEW (configured; child failed) | — | — | — |
| Kanso Satori DWQ q4 | 1 | OLD | 956.80/1178.28 | 3.277 | 2.980 |
| Vedu Scribe 0.8B mixed q4/q8 | 1 | OLD | 208.80/304.50 | 1.939 | 1.576 |
| s1-mini BF16 | 1 | OLD | 139.40/245.22 | 1.977 | 1.920 |
| Qwen3.5 2B q4 | 1 | OLD | 455.45/596.74 | 2.369 | 2.001 |
| Qwen3.5 4B q8 | 2 | OLD | 972.40/1254.53 | 5.592 | 3.321 |
| MiniCPM5 1B q4 | 2 | OLD | — | — | 1.268 |
| MiniCPM5 2B q4 | 2 | OLD | — | — | 2.078 |
| Granite4.2 3B q8 | 2 | OLD | 753.00/1292.46 | 4.657 | 3.631 |
| Gemma4 E2B mixed q4/q8 | 2 | NEW | 631.50/958.09 | 4.455 | 3.608 |
| SimpleWords v2 q8 | 2 | OLD | 463.90/791.24 | 3.241 | 2.946 |
| WhisperNow q8 | 2 | NEW (configured; child failed) | — | — | — |
| Kanso Satori DWQ q4 | 2 | OLD | 1009.60/1318.68 | 3.277 | 2.997 |
| Vedu Scribe 0.8B mixed q4/q8 | 2 | OLD | 234.55/410.33 | 1.939 | 1.573 |
| s1-mini BF16 | 2 | OLD | 159.10/247.28 | 2.044 | 1.921 |
| Qwen3.5 2B q4 | 2 | OLD | 485.50/691.77 | 2.346 | 2.002 |

Source: `codex-model/action-results-20261029T190024467744Z.json`. Source and wrapper digests match the
executed files. Independent aggregate audit passes 330 checks covering
completeness, category totals, paired direction, exact McNemar values,
Wilson intervals and resource fields. Per-item predictions were discarded;
these checks cannot independently reconstruct model answers.

</details>

The separate bare-label adapter restores MiniCPM scoring by disabling
special tokens only for standalone option letters. MiniCPM5 1B scores
31/62 and 2B scores 47/62 on each revision, below their fresh 4B controls.
The adapter leaves all 26 4B letter IDs unchanged; 4B score/category totals
also match the native run. Per-item prediction parity was not retained.
No production adapter was installed.

<details>
<summary>All six bare-label diagnostic outcomes</summary>

These scores use separate fresh 4B controls and the same synthetic cases.
They do not replace native refusals. Category denominators and paired-test
direction match the native table above. All runs use OLD.

| Checkpoint | Revision | Correct/62; 95% CI | W/L vs diagnostic 4B | p | Category correct | Minimum label mass |
|---|---:|---|---:|---:|---|---:|
| Qwen3.5 4B q8 | 1 | 56/62; 80.5–95.5% | 0/0 | 1 | 26/6/8/8/4/4 | 0.9989 |
| MiniCPM5 1B q4 | 1 | 31/62; 37.9–62.1% | 2/27 | 1.62423e-06 | 16/4/4/4/2/1 | 0.7718 |
| MiniCPM5 2B q4 | 1 | 47/62; 63.8–84.8% | 2/11 | 0.0224609 | 25/6/5/5/2/4 | 0.9788 |
| Qwen3.5 4B q8 | 2 | 58/62; 84.6–97.5% | 0/0 | 1 | 26/7/8/9/4/4 | 0.9984 |
| MiniCPM5 1B q4 | 2 | 31/62; 37.9–62.1% | 2/29 | 4.62867e-07 | 16/4/4/4/2/1 | 0.7742 |
| MiniCPM5 2B q4 | 2 | 47/62; 63.8–84.8% | 2/13 | 0.00738525 | 25/6/5/5/2/4 | 0.9813 |

| Checkpoint | Revision | Decision p50/p90 ms | Peak MLX GB | Peak RSS GB | Native/bare single-token letters; changed IDs |
|---|---:|---:|---:|---:|---|
| Qwen3.5 4B q8 | 1 | 1108.55/1788.03 | 5.592 | 1.489 | 26/26 → 26/26; 0 |
| MiniCPM5 1B q4 | 1 | 254.40/342.45 | 1.609 | 1.269 | 0/26 → 26/26; 26 |
| MiniCPM5 2B q4 | 1 | 628.15/830.82 | 2.427 | 2.078 | 0/26 → 26/26; 26 |
| Qwen3.5 4B q8 | 2 | 1132.70/1838.35 | 5.576 | 2.875 | 26/26 → 26/26; 0 |
| MiniCPM5 1B q4 | 2 | 290.85/419.69 | 1.637 | 1.096 | 0/26 → 26/26; 26 |
| MiniCPM5 2B q4 | 2 | 640.40/892.66 | 2.427 | 2.047 | 0/26 → 26/26; 26 |

Source: `codex-model/action-bare-label-v1.json`. All six outcomes are
complete. Another 144 independent aggregate checks pass, including the
26-letter adapter contract, same-revision controls and source/wrapper
hashes. Native and diagnostic audits total 474 checks. The timing and
execution limits above apply to these runs too.

</details>

## Candidate research and provenance

The initial live primary-source census covers 114 fetched HF API records:
113 model/build/adapter records and one provenance dataset, across 29 maker
organizations. Later v2-adapter/v3 checks are separate supplements. Cards,
configs, templates, licence files and revisions are retained in scratch
`public-metadata/`. This is a bounded census; arbitrary 2026 derivatives
remain a search gap. X searches yielded no verified primary maker page;
the cited HF records, maker sites and paper provide the source evidence.
Unrun candidates are not measured failures.

| Candidate | Actual artifact and contract | Provenance or limit |
|---|---|---|
| WhisperNow Qwen3.5 4B | Local affine q8/group64 conversion of pinned BF16 source; transcript-only user turn; native template; repetition penalty 1.05 | Apache-2.0. Every cleanup target was GPT-6.1-sol-written. Existing weights evaluated; no new training on its targets/outputs. |
| SimpleWords v2 | Published Qwen3.5-2B-derived q8/group64; exact trained one-user-turn prompt; thinking off | Apache-2.0 card. The maker discloses 29,425 templated rows, 14,448 generated by local Qwen3.5-27B q4, and 9,627 from unnamed local MLX generators. The corpus is private. Publisher's q4-collapse percentage is not a Velora measurement. |
| Gemma4 E2B | Mixed q4/q8 MLX build; 5.123B stored parameters, about 2.3B effective; thinking off | Current official licence is Apache-2.0, ungated. All 105 MLP projections remain q8 in the measured build. Stored weight/RAM matters despite the E2B name. |
| Kanso Satori | Qwen3-derived q4 DWQ/group64; exact trained system/user contract | Apache-2.0 card; punctuation/ITN/fillers scope. Human-only target provenance is unproven; no repeat DWQ calibration on Qwen4B logits. |
| Granite4.2 / MiniCPM5 1B | Official q8 / official q4, respectively; Velora prompt, thinking off | Apache-2.0. General instruct controls, distinct from specialist prompts. |

[WhisperNow model](https://huggingface.co/category271/whispernow-qwen3.5-4b),
[WhisperNow target provenance](https://huggingface.co/datasets/category271/whispernow-cleanup),
[SimpleWords model](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v2),
[SimpleWords maker's provenance](https://www.abhiramsalammagari.com/writing/dictation-cleanup-corpus-design),
[Gemma Apache licence](https://ai.google.dev/gemma/apache_2),
[Kanso model](https://huggingface.co/BuilderHelm/Kanso-Satori-1.0).

Archived controls retain Vedu, MiniCPM5 2B, S1-mini, Qwen2B, 4B and Muesli.
The tested official S1-mini is **BF16 Qwen3**, 596 million unique parameters;
its duplicated tied embeddings increase stored tensor elements. Community
S1 q4 is a separate build. Vedu's tested build is mixed q4/q8, not uniform
q4. Muesli remains a losing own-prompt baseline; its model-generated corpus
is not a training source.

### Research exclusions and unrun gaps

| Group | Disposition |
|---|---|
| Noncommercial or gated | Apple SimpleSD, Audex, Efficient-DLM and GooseReason lack the required commercial licence. TinyAya and several Google/NVIDIA specialists are gated. SimpleWords v3 is auto-gated; no terms accepted and its adapter was not substituted for v2. |
| Conditional commercial scope | LFM3's revenue condition needs company eligibility; Youtu excludes EU use. Historical LFM outputs are scored, but these sources are not a worldwide default choice or new training target. |
| Outside active-size cap or large resident weights | Gemma E4/Bolt advertise 4.5B effective parameters, beyond the cap. Low-active GLM/Qwen35–36/Nemotron30B/Gemma26B still have large resident weights; no measured RAM-failure claim is made. |
| Runtime/task integration missing | Dory/diffusion/NOSA/Bolmo/LLaDA need an unsupported or unaudited generation path. Bonsai/LFM need exact custom-version handling. UI/browser/code specialists need Velora Action-schema tests; external task scores do not qualify them. |
| Compatible but unmeasured, or date/base controls | Spark, Nanbeige, Nano4B and smaller Falcon variants remain unrun. Official Phi4-mini, SmolLM3 and older listed sources have no qualifying 2026 maker update in this census. SWASH/Cotypist are base/autocomplete controls, not drop-in cleanup instruct models. |

These are separate from measured quality failures. The conclusion applies
to the evaluated shortlist; it does not prove every unrun 2026 derivative
fails. A later candidate must satisfy the same frozen bar rather than inherit
an exclusion from this table.

[LFM licence](https://huggingface.co/LiquidAI/LFM3-1.7B/blob/ac2586a34f1a1c03329dbdcdefabd8b6478ddaa7/LICENSE),
[SimpleSD licence](https://huggingface.co/apple/SimpleSD-4B-instruct/blob/bf2df4dc85327389b0b671c932da91b92b7116ea/LICENSE),
[SimpleWords v3 gate metadata](https://huggingface.co/api/models/ReFyneLabs/simplewords-dictation-cleanup-v3),
[Gemma E4 source](https://huggingface.co/google/gemma-4-E4B-it/blob/ee0ef6023621cff504d758262d4e04895a5af4a2/README.md),
[Dory source](https://huggingface.co/nvidia/NVIDIA-Nemotron-Labs-Dory1.0-4B-BF16/blob/48e0c3faac0aaa8b93fc4e68256d7e58b183645e/README.md).

### SimpleWords q4 diagnostic

The publisher's private 44+1,546-case collapse claim cannot be reproduced
from public material. On the public Pomvox 28-predicate suite, all three
trained variants pass the four explicit self-correction checks. This tiny
suite does not show a q4 collapse and does not replace owner/accent testing.

| Build / exact prompt | Publisher-guard pass /28 | Self-correction /4 | Total p50/p90 ms | Peak MLX/RSS GB |
|---|---:|---:|---:|---:|
| Shipped 2B q4 / Velora | 18 | 0 | 113/219 | 1.37/1.98 |
| q4 base + runtime v2 adapter / trained | 25 | 4 | 154/287 | 1.38/2.01 |
| Plain fused q4 / trained | 24 | 4 | 77/140 | 1.33/2.01 |
| Published q8 / trained | 24 | 4 | 106/182 | 2.27/2.92 |

All use core/Metal .32.4, LM .32.2, transformers 5.7 in fresh subprocesses.
Fusion merges the existing adapter and requantizes to affine q4/group64;
there is no training. Public prompts/caps differ by their native contract.
Publisher-guard results include its stripping step; raw preguard strict
already-clean scoring has a whitespace caveat. No decoded output is retained.
The follow-up frozen q4 owner screen fails: 5.8449% wWER, 73/303 harms,
70 exact matches, 14/156 lexical fixes and 0/30 aligned-term fixes, with
57 inserted words and 53 novel added types. It beats 4B mean wWER but remains
above raw. Harm McNemar versus 4B is .05354 (30 new/48 removed), failing
p<.05; versus shipped 2B it is .653 (42/37). The sign test versus 2B has
59 wins/58 losses, p=1. Total p50/p90 is 958/4777 ms,
TTFT 72/154 ms, peak MLX/RSS 2.18/1.96 GB. This frozen screen uses
MLX/Metal 0.31.2, mlx-lm 0.31.3 and Transformers 5.3.0; the public28
diagnostic uses 0.32.4/0.32.2 and Transformers 5.7.0.
Product failures are 17/27. EdAcc is skipped under the predeclared mandatory
owner-screen policy; public-suite success cannot qualify a replacement.

[Public predicate source](https://github.com/pomvox/pomvox/blob/da8afc66e69a259ca2e155e3d9af59e09fb00b83/scripts/eval_cleanup_v2.py),
[public v2 adapter](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v2-adapter/tree/7a6a41173775022d2adaeceabe61062ea1c9186c).

<details>
<summary>Full inspected candidate census and pinned sources</summary>

### Inspected candidate families: bounded census

Initial screening queried 29 maker namespaces and 4,478 listed repositories; 113 selected model/build/adapter records plus one provenance dataset received primary metadata inspection. The table retains all 113 initial pinned model/build links, grouped into 70 rows. Three follow-up records add the cached Qwen2B q4 base and SimpleWords v3 model/adapter. This is complete for the inspected records, not every 2026 derivative worldwide. A repository update is not a new checkpoint release; dated controls are identified explicitly.

Open means the public API reported no gate. Card-only licence declarations are labelled; official licence files/pages override stale tags. Parameter totals include embeddings, vision or MTP where present and are not measured active parameters or RAM. Low-active models with large resident weights remain unrun concerns, not measured memory failures. Source active-size ambiguity is retained.

Measured describes cleanup evidence available at this audit; it does not confer an Action Mode pass. The separate Action section gives decision-path results. No listed model-written corpus is an approved source of new Velora targets.

| Inspected family / pinned primary sources | Commercial licence; gate | Apple path / stored-size concern | Evidence / disposition |
|---|---|---|---|
| [Qwen3.5 4B](https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/README.md); [Qwen3.5-4B-MLX-8bit](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-8bit/blob/5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d/README.md) | Apache-2.0 file; open | 4.660B source / 4.539B MLX pack; q8; stock qwen3_5 | Measured baseline: owner303 + EdAcc593; fails raw quality. Keep comparator. |
| [Qwen3.5 2B](https://huggingface.co/Qwen/Qwen3.5-2B/blob/15852e8c16360a2fea060d615a32b45270f8a8fc/README.md); [Qwen3.5-2B-MLX-8bit](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-8bit/blob/e6ffd0033d03c9efa880984e611028e0da63905f/README.md); [shipped q4 base](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit/blob/93760be4f1f69842a46bc13dbdc0f19e291392a3/config.json) | Apache-2.0 file; open | 2.274B source / 1.882B stripped text; shipped affine q4/group64; listed q8 build separate; qwen3_5 | Measured shipped q4: owner303 + EdAcc593; fails raw quality. Listed q8 build unrun. |
| [MiniCPM5 2B](https://huggingface.co/openbmb/MiniCPM5-2B/blob/f97400052a43d642bbc6e9975e2397e3ae6a6b52/README.md); [MiniCPM5-2B-MLX](https://huggingface.co/openbmb/MiniCPM5-2B-MLX/blob/8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3/README.md) | Apache-2.0 card; open | 2.517B; official q4; llama | Measured archive owner303: above raw; no complete accent result. |
| [Vedu Scribe 0.8B](https://huggingface.co/heyvedu/vedu-scribe-0.8b/blob/7dced5841c58d7d6e0118c4c123f222b35057871/README.md) | Apache-2.0 card; open | 0.752B; mixed attention-q8/rest-q4; qwen3_5 | Measured owner303 below pooled raw, but EdAcc593 fails: wWER 22.9031%, 197 harms, all 12 accent delta-raw CIs positive. No replacement pass. |
| [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini/blob/88f6b15896c73bbb13a3b596e0afe8ea0d5150b4/README.md); [S1-mini-MLX-4bit](https://huggingface.co/mlx-community/S1-mini-MLX-4bit/blob/5cbd7aec3401144f88a331d385c40b65fd2548eb/README.md) | Apache-2.0 + naming clause file/NOTICE; open | 596.050M unique; official BF16 qwen3; 751.632M stored tensor elements; separate community q4/group64 | Measured official BF16 owner303: above raw. Community q4 unrun. |
| [Granite 4.2 3B](https://huggingface.co/ibm-granite/granite-4.2-3b/blob/4e9c275e232f10211ec88644d106a1f6a1b60e06/README.md); [granite-4.2-3b-q8-mlx](https://huggingface.co/ibm-granite/granite-4.2-3b-q8-mlx/blob/8e19ac6574124635eb8fbd06a15d05ebbfff82dd/README.md); [granite-4.2-3b-q4-mlx](https://huggingface.co/ibm-granite/granite-4.2-3b-q4-mlx/blob/0c6f39b1827afd5eb2c1c3b13751929857434953/README.md) | Apache-2.0 card; open | 3.660B; official q8/q4; granite | Measured q8 owner303 fails: mean wWER 6.3645%, above raw/4B despite fewer harms (50). EdAcc skipped. q4 unrun. |
| [MiniCPM5 1B](https://huggingface.co/openbmb/MiniCPM5-1B/blob/87179e5c1f455ef22e6223592d2d61351b525bfc/README.md); [MiniCPM5-1B-MLX](https://huggingface.co/openbmb/MiniCPM5-1B-MLX/blob/9879b18bf2928355fcdf4287635388a3665a40cb/README.md) | Apache-2.0 card; open | 1.081B; official q4; llama | Measured minimal-prompt owner303 + EdAcc593 fails. Velora-prompt owner303 also fails (wWER 8.3541%, 45 harms); its EdAcc skipped. |
| [WhisperNow Qwen3.5 4B](https://huggingface.co/category271/whispernow-qwen3.5-4b/blob/3b271af4ac6f4eb181c3e77dcbfa2252c7605bfd/README.md) | Apache-2.0 file; open | 4.206B text; converted affine q8/group64, 4.490GB local artifact; qwen3_5; BF16 source 8.412GB | Measured local MLX q8 owner303 + EdAcc593: fails both; existing weights only. |
| [Simplewords v2](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v2/blob/1b0388753b6aa3baa471c45195d29122a52aef9b/README.md); [simplewords-dictation-cleanup-v2-adapter](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v2-adapter/blob/7a6a41173775022d2adaeceabe61062ea1c9186c/README.md) | Apache-2.0 card; open; no local LICENSE | 1.882B text; published q8 2.000GB; adapter 67.3MB; generated q4 artifact 1.079GB; stock qwen3_5 | Measured q8 owner303 + EdAcc593: fails both. Fused q4 owner303 fails; EdAcc skipped. Public28 self-correction 4/4 does not qualify it. |
| [Kanso Satori / Koi](https://huggingface.co/BuilderHelm/Kanso-Satori-1.0/blob/07a3ad5452b6393264310af5a99f7238a9a8d734/README.md); [Kanso-Koi-1.0](https://huggingface.co/BuilderHelm/Kanso-Koi-1.0/blob/e62fa0fe7c20bcf32d04e64b16d0d447e5e0dae6/README.md) | Apache-2.0 card/upstream link; open | Satori 4.022B, q4 DWQ/group64, 2.263GB; Koi 1.721B q4 base + adapter; qwen3 | Measured Satori owner303 fails: wWER 5.2445% exceeds raw; 85 harms, harm McNemar versus 4B .6173. EdAcc skipped. Koi unrun; new-training targets unproven. |
| [Qwen3.5 0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B/blob/2fc06364715b967f1860aea9cf38778875588b17/README.md) | Apache-2.0 file; open | 0.873B source incl vision/MTP; q4/q8 conversion; qwen3_5 | Unrun: Eligible generic comparator, separate from task fine-tunes. |
| [Granite 4.1 3B](https://huggingface.co/ibm-granite/granite-4.1-3b/blob/c0650403e44e78ec0262dab1c90914c65b196c4e/README.md); [granite-4.1-3b-8bit](https://huggingface.co/mlx-community/granite-4.1-3b-8bit/blob/38735bfdf1eb49543dd7316ec5574c269dafb8fd/README.md) | Apache-2.0 card; open | 3.403B; community q8; granite | Unrun: Eligible fallback to 4.2. |
| [Spark X2.5 / X2.6 1.7B](https://huggingface.co/XHToken/Spark-X2.5-1.7B/blob/14d6e83c13c7add2b62a7c39b2131f4ed1cddcf8/README.md); [Spark-X2.6-1.7B](https://huggingface.co/XHToken/Spark-X2.6-1.7B/blob/f18c032c7675f807c0fdffe281dbe124edba2605/README.md) | Apache-2.0 file; open | 1.708B; maker Spark-MLX-LLM or supported spark2_5; uniform q4/q8 ship build not established | Unrun: Eligible runtime work; do not borrow maker speed. |
| [Spark X2.6 4B](https://huggingface.co/XHToken/Spark-X2.6-4B/blob/d1b5f26071101c27fcd07728e7a7770e428281f4/README.md); [Spark-X2.6-4B-OptiQ-4bit](https://huggingface.co/mlx-community/Spark-X2.6-4B-OptiQ-4bit/blob/6d83e911abefcbbb9c7c595e6517264f36db03dd/README.md) | Apache-2.0 card/file; open | 4.112B source; OptiQ mixed q4; spark2_5 | Unrun: Active/embedding definition needs recording; source total alone is not exclusion. |
| [Nanbeige 4.1 / 4.2 3B](https://huggingface.co/Nanbeige/Nanbeige4.1-3B/blob/9c4555c37921c0982af8fffeee1e0a6e6b953c4f/README.md); [Nanbeige4.1-3B-8bit](https://huggingface.co/mlx-community/Nanbeige4.1-3B-8bit/blob/699b0e755a2841c4c2762f846d4eaf93542ac97c/README.md); [Nanbeige4.2-3B](https://huggingface.co/Nanbeige/Nanbeige4.2-3B/blob/b82e54bd609793562a75cbf9337970a93369eab5/README.md); [Nanbeige4.2-3B-OptiQ-4bit](https://huggingface.co/mlx-community/Nanbeige4.2-3B-OptiQ-4bit/blob/e88d49fdd9cd67629c712fc2b4d845ad403ae9b4/README.md) | Apache-2.0 card; open | 4.1: 3.934B q8/llama; 4.2: 4.170B mixed-q4; source total differs from label | Unrun: Eligible only after full-output/latency check; 4.2 active definition unresolved. |
| [Gemma 4 E2B](https://huggingface.co/google/gemma-4-E2B-it/blob/3e22461f65e89153144f8adb70e3b8c2cc9845a7/README.md); [gemma-4-E2B-it-MLX-4bit](https://huggingface.co/lmstudio-community/gemma-4-E2B-it-MLX-4bit/blob/31512dab743c73974a99795270031a6f85072d94/README.md); [gemma-4-E2B-it-MLX-8bit](https://huggingface.co/lmstudio-community/gemma-4-E2B-it-MLX-8bit/blob/381c070ec0e9d92b27abd8038a0a0f369ee64ef6/README.md); [gemma-4-e2b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/blob/238767527555cb75a05732a84dff5d6ba0dd6809/README.md) | Official Apache-2.0; open; community gemma tag stale | 2.3B effective / 5.123B stored; chosen mixed-q4/q8 4.340GB, all 105 MLP projections q8; gemma4 | Measured mixed-q4/q8 owner303 fails: wWER 6.4579%, 104 harms; McNemar versus 4B .2082. EdAcc skipped. Uniform q4/q8 alternatives unrun. |
| [Nemotron 3 Nano 4B](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/blob/dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f/README.md); [NVIDIA-Nemotron-3-Nano-4B-4bit](https://huggingface.co/mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit/blob/c4d79ba1901d99806ef757642a552acebb851a35/README.md) | NVIDIA Nemotron Open Model License, commercial; open | 3.974B; q4; nemotron_h | Unrun: Eligible custom-licence candidate. |
| [North Micro Vision Instruct](https://huggingface.co/CohereLabs/North-Micro-Vision-Instruct/blob/fa548d9aa62c1220bfd21fc6cfc465f1bd2a1a40/README.md); [North-Micro-Vision-Instruct-8bit](https://huggingface.co/mlx-community/North-Micro-Vision-Instruct-8bit/blob/26e6b3aef507899fbf86057593d99fc12418e26f/README.md) | Apache-2.0 card; open | 2.485B multimodal; q8; mlx-vlm | Unrun: Text/Action-context candidate; integration and 62-case schema check needed. |
| [Falcon H1 Tiny variants](https://huggingface.co/tiiuae/Falcon-H1-Tiny-90M-Instruct/blob/e6389502a0b12cd8da894b395ba5bf7436873b16/README.md); [Falcon-H1-Tiny-Multilingual-100M-Instruct](https://huggingface.co/tiiuae/Falcon-H1-Tiny-Multilingual-100M-Instruct/blob/295b1eb969d4d1683ea7d988ac70fb03990f881c/README.md); [Falcon-H1-Tiny-Tool-Calling-90M](https://huggingface.co/tiiuae/Falcon-H1-Tiny-Tool-Calling-90M/blob/fc099d791a229464b995fdd2fd24e8ffd2d699e8/README.md); [Falcon-H1-Tiny-R-0.6B](https://huggingface.co/tiiuae/Falcon-H1-Tiny-R-0.6B/blob/ccf3d61714e029d86dbd48883f1d40cfc995d433/README.md) | Falcon custom commercial licence; open | 0.091/0.108/0.091/0.622B; maker documents MLX; chosen quant not established | Unrun: Eligible family, no measured proof tiny variants satisfy either job. |
| [Aitana 2B SI Instruct](https://huggingface.co/gplsi/Aitana-2B-SI-Instruct/blob/44f9e54aa164a99fe1afbe4ce11f9e4b69976f80/README.md) | Apache-2.0 card; open | 2.253B; llama clean conversion; no chosen shipquant | Unrun: Eligible language-specific trial, not accent evidence. |
| [VibeThinker 1.5B / 3B](https://huggingface.co/WeiboAI/VibeThinker-1.5B/blob/9614bcb0264f03f18f2fa2406c4a9754635f51de/README.md); [VibeThinker-3B](https://huggingface.co/WeiboAI/VibeThinker-3B/blob/77bd2cced09193c8b9a59a32bd8577bbd1f3e01c/README.md) | MIT card; open | 1.777/3.086B; qwen2 clean conversion; quant not chosen | Unrun: Lower priority cleanup; Action orchestration unsupported by its own intended use. |
| [Bonsai 1.7B 1-bit](https://huggingface.co/prism-ml/Bonsai-1.7B-mlx-1bit/blob/fac480d016cf265838ad087f9f3f2abac4a2c1a5/README.md) | Apache-2.0 card; open | 1.7B marketed; HF packed tensor count is not parameter count; native q1/group128 | Unrun: Runtime fork requirement; do not assume stock q1 compatibility. |
| [Bonsai 2 ternary 2B / 4B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-mlx-2bit/blob/1c6cbae21f8c38830ce337972b46fdae7b18eaaa/README.md); [Ternary-Bonsai-2-4B-mlx-2bit](https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-mlx-2bit/blob/dff2caaa23fa8706164c44c10f1b58feb405f76a/README.md) | Apache-2.0 card; open | 2.214/4.540B incl vision; q2/group128; prism_hadamard_qwen35; mlx-vlm>=0.7.8 or bundled loader | Unrun: 2B eligible; 4B text model ~4.21B incl embeddings. Released mlx-lm0.32.0 unsupported per card. |
| [Ministral 3 3B Instruct 2512](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-BF16/blob/b6d637bef2393152b3da2b2fde72eecdee30557e/README.md) | Apache-2.0 card; open | 4.252B multimodal; community q4; mistral3 | Unrun: 2025 release, source updated 2026; eligible if active language count is used. |
| [Muesli cleanup v12 variants](https://huggingface.co/Muesli-HQ/qwen35-0.8b-muesli-cleanup-v12-mlx-8bit/blob/d557e9528ba42a47026372d372e071e6f2db33e2/README.md); [qwen35-2b-muesli-cleanup-v12-mlx-8bit](https://huggingface.co/Muesli-HQ/qwen35-2b-muesli-cleanup-v12-mlx-8bit/blob/0fbfa48e98f1f8f28a0e3ca692066c823812db4e/README.md); [gemma4-e2b-muesli-cleanup-v12-mlx-4bit](https://huggingface.co/Muesli-HQ/gemma4-e2b-muesli-cleanup-v12-mlx-4bit/blob/29d40bae87983afbc330f39bf6d2b47f38c2215c/README.md); [lfm25-1.2b-muesli-cleanup-v12-gguf](https://huggingface.co/Muesli-HQ/lfm25-1.2b-muesli-cleanup-v12-gguf/blob/9f8b4e257d0f091da9396e06aa893538a823509e/README.md) | Qwen/Gemma Apache-2.0; LFM conditional revenue licence; open | Qwen text0.752/1.882B q8; Gemma pack4.629B q4; LFM1.2B GGUF requires separate Apple backend | Measured Qwen0.8/2B owner303 archives: above raw. Gemma/LFM variants unrun; model-written targets excluded from new training. |
| [Tholos 2B](https://huggingface.co/mertkayacs/Tholos-2B/blob/67a55e438302ebf5bda116543b660c05ed78efca/README.md) | Apache-2.0 card; open | 2.517B MiniCPM5/llama; clean conversion; quant not chosen | Unrun: Map to Velora Action schema and score 62; no cleanup claim. |
| [ToolMind Web 3B](https://huggingface.co/Nanbeige/ToolMind-Web-3B/blob/9f5aa81ce9d6ddf6cac9754a885f089184d74db8/README.md) | Apache-2.0 card; open | 3B class; API exact count absent; llama conversion | Unrun: 62-case Action benchmark needed; web-agent results do not establish fit. |
| [Fara 1.5 4B](https://huggingface.co/microsoft/Fara1.5-4B/blob/776a33ae5b2ad503796a97ae20fdc66f61d2feea/README.md) | MIT card; open | 4.539B incl vision; qwen3_5 conversion | Unrun: Action candidate; text-only schema and quantization unverified. |
| [UI-Venus 1.5 2B](https://huggingface.co/inclusionAI/UI-Venus-1.5-2B/blob/bc4c6e62a1c545e043761439be95646d801853a4/README.md) | Apache-2.0 card; open | 2.439B incl vision; qwen3_vl conversion | Unrun: Action candidate; screenshot grounding differs from dictation intent. |
| [LocoOperator 4B](https://huggingface.co/LocoreMind/LocoOperator-4B/blob/7224ae265a69ec46e5142d29130412073a8b6173/README.md) | MIT card; open | 4.022B; qwen3; clean conversion, no chosen quant | Unrun: Existing-model eval only; no human-target training corpus; domain mismatch. |
| [MolmoWeb 4B](https://huggingface.co/allenai/MolmoWeb-4B/blob/c96d1cc05ae7dcb850f4156f5656849961fece14/README.md) | Apache-2.0 card; open | 4.851B incl vision; molmo2; tested Apple path not established | Unrun: Action-specific integration gap; not a generic cleanup trial. |
| [MiniCPM-V 4.7 1B](https://huggingface.co/openbmb/MiniCPM-V-4.7-1B/blob/bb99eab4113676f30830ffa73bac1f0b2a5f1dea/README.md) | Apache-2.0 card; open | 1.554B incl vision; minicpmv4_7; clean supported MLX path not established here | Unrun: Multimodal lead; runtime integration remains. |
| [Ling 3.0 tiny](https://huggingface.co/inclusionAI/Ling-3.0-tiny/blob/9a98e35fe1c9ee255f78dd64771c7ae15a799481/README.md) | MIT card/file; open | 1.3B active / 7.893B total; rapid-mlx q4; bailing_hybrid | Unrun: Most plausible small-active MoE for a RAM screen; no measured RAM failure. |
| [Ling / Ring mini2.0](https://huggingface.co/inclusionAI/Ling-mini-2.0/blob/a810f6416bc4e1e29c9d7f271dd2fa7e56e71eab/README.md); [Ring-mini-2.0](https://huggingface.co/inclusionAI/Ring-mini-2.0/blob/e807a1d16dc358dd7fcc46f0ad243a743adc2439/README.md) | MIT card/file; open | 1.4B active / 16.256B total; bailing_moe conversion; no chosen quant | Unrun: Large resident weights; no evidence of passing 4B RAM bar. |
| [Trinity Mini](https://huggingface.co/arcee-ai/Trinity-Mini/blob/cdb81e8130815fec299cccc8f8700004b8366e1e/README.md) | OpenMDW1.1 commercial; open | 3B active / 26.124B total; MLX q4; afmoe | Unrun: 2025 release/2026 update; large resident payload; not measured RAM failure. |
| [GLM 4.7 Flash](https://huggingface.co/zai-org/GLM-4.7-Flash/blob/7dd20894a642a0aa287e9827cb1a1f7f91386b67/README.md) | MIT card; open | 3B active / 31.221B total; MLX q4 | Unrun: ~15.6GB raw4bit payload before overhead; RAM shortlist concern, not measured result. |
| [Qwen3.5 / 3.6 35B-A3B](https://huggingface.co/Qwen/Qwen3.5-35B-A3B/blob/59d61f3ce65a6d9863b86d2e96597125219dc754/README.md); [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/blob/995ad96eacd98c81ed38be0c5b274b04031597b0/README.md) | Apache-2.0 file; open | 3B active / 35.952B total; MLX q4 | Unrun: Large resident payload; no verified peak-RAM pass. |
| [Nemotron Nano / Lightning30B-A3B](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16/blob/bf77c3174f68ad409e1c2aa60daeb46e32d1c606/README.md); [NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16/blob/a9904d24bcc1d289a1950fa9d2b978c47cf903b9/README.md) | Nano NVIDIA commercial; Lightning OpenMDW1.1; open | 3B-class active / 31.578B total each; MLX q4; nemotron_h | Unrun: Large resident payload; no verified peak-RAM pass. |
| [Gemma4 26B-A4B](https://huggingface.co/google/gemma-4-26B-A4B-it/blob/4d7ae4984b7db7de8f8457170b3f1a419ee76d52/README.md) | Official Apache-2.0; open | Maker 3.8B active /25.806B total; MLX conversion/q4 | Unrun: Active cap fits; resident weights remain large. |
| [LFM2.5 dense variants](https://huggingface.co/LiquidAI/LFM2.5-230M/blob/40cb2ad3b3044d5a41eee083a6103c8b523afa45/README.md); [LFM2.5-350M](https://huggingface.co/LiquidAI/LFM2.5-350M/blob/9e6c6ccf47cd318696e137d381a7ded8fe4df09f/README.md); [LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/0f604ada3f766f9f257460c4c9f0b5d6f69d431b/README.md); [LFM2.5-2.6B](https://huggingface.co/LiquidAI/LFM2.5-2.6B/blob/b212e75975bbda9676a94d3cb7b2ca25b65fed48/README.md) | LFM Open1.0 file: commercial below $10M annual revenue; open | 0.230/0.354/1.170/2.697B; official MLX q8; lfm2 | Unrun: commercial eligibility below $10M revenue not established; native thinking controls differ. |
| [LFM2.5 low-active variants](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B/blob/5dd22602c2e9f6a097b1de4c4efe0658b605015c/README.md); [LFM2.5-24B-A2B](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/blob/3fcfdbfa1a1b6d8166846a6323e69f1e1254440d/README.md) | Same LFM revenue condition; open | Maker 1.5B/2.45B active, API 8.468B/23.972B total; official MLX variants | Unrun: same revenue condition; 8.5/24B resident payload and forced reasoning need measurement. |
| [LFM3 text / VL](https://huggingface.co/LiquidAI/LFM3-1.7B/blob/ac2586a34f1a1c03329dbdcdefabd8b6478ddaa7/README.md); [LFM3-1.7B-MLX-8bit](https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-8bit/blob/ee7667f3cfccb2a41725f91820531823fcabc6b7/README.md); [LFM3-VL-2B](https://huggingface.co/LiquidAI/LFM3-VL-2B/blob/ba44bd51db20a2753f28c273a1571ccaa210d954/README.md) | Same LFM revenue condition; open | 1.729B text /1.918B VL; official text q8 / VL q4; lfm3/lfm3_vl | Measured historical text104 only, above raw; current exact-runtime/full303/accent evidence absent. VL unrun; conditional licence. |
| [Liquid d1 decision heads](https://huggingface.co/LiquidAI/d1-2B/blob/bee23105009f0fafea44ea95c501743c36bd4693/README.md); [d1-3B](https://huggingface.co/LiquidAI/d1-3B/blob/051bcc464b01b9f92942b364d9586b0ef5912432/README.md) | Same LFM revenue condition; open | 1.918/3.123B; custom single-pass decision heads; no verified MLX decoder | Unrun: conditional licence, custom decision API and Apple implementation/schema gap. |
| [Youtu LLM2B](https://huggingface.co/tencent/Youtu-LLM-2B/blob/d69af0fc88814aafe7528eda55b63283c7790931/README.md) | Custom file excludes EU; open | 1.962B; MLX builds exist | Excluded from worldwide default: custom licence excludes EU use; no quality failure asserted. |
| [Nemotron Labs Dory1.0 4B](https://huggingface.co/nvidia/NVIDIA-Nemotron-Labs-Dory1.0-4B-BF16/blob/48e0c3faac0aaa8b93fc4e68256d7e58b183645e/README.md) | Custom commercial licence; open | 3.975B; latent recurrent custom runtime | Unrun: verified stock-MLX conversion/recurrent decoding path absent. |
| [Nemotron Labs Diffusion3B](https://huggingface.co/nvidia/Nemotron-Labs-Diffusion-3B/blob/0d51902da1f8869f83413ce642fab402fa5641e0/README.md) | Custom commercial licence; open | 3.832B; diffusion generation | Unrun: verified Apple diffusion decoder absent. |
| [Nemotron Flash3B Instruct](https://huggingface.co/nvidia/Nemotron-Flash-3B-Instruct/blob/f9f7cb16613a8318a402452fec2f8b7127dbfd99/README.md) | Custom commercial licence; open | 2.750B; nemotron_flash custom runtime | Unrun: clean Apple custom-runtime implementation not established. |
| [NOSA1B /3B](https://huggingface.co/openbmb/NOSA-1B/blob/7bdc33fbc1bc80b76b29689ba35ff6a7991b7dee/README.md); [NOSA-3B](https://huggingface.co/openbmb/NOSA-3B/blob/c5a4d505d5811f7555d786a031a4623787da7fb0/README.md) | Apache-2.0 card; open | 3B API 3.606B; 1B exact API count absent; SparseLlama/NOSI | Unrun: sparse-attention/offload implementation needed; llama tag is insufficient. |
| [Bolmo1B](https://huggingface.co/allenai/Bolmo-1B/blob/452690a8cfab1dd1ec27b74f2667632f17a21b46/README.md) | Apache-2.0 card; open | 1.469B; byte-level custom model | Unrun: verified MLX byte-level implementation absent. |
| [LLaDA2.2 mini](https://huggingface.co/inclusionAI/LLaDA2.2-mini/blob/e4f77d25ab5ca86f2223c6cdc6a72b887e20c8a5/README.md) | Apache-2.0 card; open | 1.4B active / 16.256B total; llada2_moe diffusion | Unrun: custom diffusion decoder and 16B resident payload; no measured RAM failure. |
| [Granite Switch4.1 preview](https://huggingface.co/ibm-granite/granite-switch-4.1-3b-preview/blob/daf8e650d23e5f3574ec2cb1cc6e346a2f90d116/README.md) | Apache-2.0 card; open | 4.150B incl embedded adapters; granite_switch | Unrun: custom adapter-switching runtime absent from checked stock tree. |
| [Granite SWASH3B-a600M](https://huggingface.co/ibm-granite/granite-swash-3b-a600m/blob/568a94fcfeff42a8cab9ee2ffea89fde12071282/README.md) | Apache-2.0 card; open | 0.6B active / 3.020B total | Excluded from existing-instruct comparison: base research checkpoint. |
| [Muesli Cotypist2B Base](https://huggingface.co/Muesli-HQ/qwen35-2b-base-cotypist-mlx-4bit/blob/2434da7449586e5e676ce03f5f34008e5df85ba8/README.md) | Apache-2.0 card; open | 1.882B text; q4; qwen3_5 | Excluded from cleanup-instruct comparison: unmodified autocomplete base. |
| [Tiny Aya global](https://huggingface.co/CohereLabs/tiny-aya-global/blob/af89d219b53ed9b13b8a4645f9c8028973510324/README.md) | CC-BY-NC4.0; auto gate | 3.349B; no gated weights fetched | Excluded: noncommercial and gated; no acceptance or gated weights. |
| [Apple SimpleSD4B Instruct](https://huggingface.co/apple/SimpleSD-4B-instruct/blob/bf2df4dc85327389b0b671c932da91b92b7116ea/README.md) | Apple research licence file excludes commercial/product development; open | 4.022B; generation implementation irrelevant to licence failure | Excluded: research licence bars commercial/product development. |
| [Nemotron Audex2B](https://huggingface.co/nvidia/Nemotron-Labs-Audex-2B/blob/77b7e1a4de899769f22c1bc074db666601c28907/README.md) | NVIDIA Oneway Noncommercial; open | 2B class; exact API count absent; custom audio model | Excluded: noncommercial licence. |
| [Efficient-DLM4B](https://huggingface.co/nvidia/Efficient-DLM-4B/blob/d28c3167e0972d9c08eb92e03cb40a42d14690d5/README.md) | CC-BY-NC4.0 card; open | 4.411B; base diffusion model | Excluded: noncommercial licence and base diffusion scope. |
| [GooseReason4B Instruct](https://huggingface.co/nvidia/Nemotron-Research-GooseReason-4B-Instruct/blob/82197937b873740604d04f3df7bab0decefe5ab5/README.md) | CC-BY-NC4.0; open | 4.411B; reasoning model | Excluded: noncommercial licence. |
| [FunctionGemma270M](https://huggingface.co/google/functiongemma-270m-it/blob/39eccb091651513a5dfb56892d3714c1b5b8276c/README.md) | Gemma card tag; manual gate | 0.268B; chosen MLX quant unverified | Excluded from runs: manual gate; no acceptance or gated files. |
| [TranslateGemma4B](https://huggingface.co/google/translategemma-4b-it/blob/10042cb0e6e7fdce748996a71dc3dc432a4e0c89/README.md) | Gemma card tag; manual gate | 4.300B multimodal source; active-language size not independently resolved | Excluded from runs: manual gate; no acceptance; translation specialist. |
| [MedGemma1.5 4B](https://huggingface.co/google/medgemma-1.5-4b-it/blob/91850547d9f0b2fdd21aa7c5f4f3d1a8a52c243b/README.md) | Custom HealthAI card; auto gate | 4.300B multimodal source | Excluded from runs: auto gate; no acceptance; medical specialist. |
| [GELab Zero4B Sico](https://huggingface.co/microsoft/GELab-Zero-4B-preview-Sico-Evolution/blob/c92fa0701ee08104d528068ee45cc0a516be972e/README.md) | Apache-2.0 card; auto gate | 4.438B source | Excluded from runs: auto gate; no acceptance; UI-action specialist. |
| [Cosmos Reason2 2B](https://huggingface.co/nvidia/Cosmos-Reason2-2B/blob/9ce19a195e423419c349abfc86fd07178b230561/README.md) | Custom NVIDIA card; auto gate | 2.439B source | Excluded from runs: auto gate; no acceptance; vision-reasoning specialist. |
| [Gemma4 E4B / Nemotron BoltE4B](https://huggingface.co/google/gemma-4-E4B-it/blob/ee0ef6023621cff504d758262d4e04895a5af4a2/README.md); [NVIDIA-Nemotron-3.5-Bolt-E4B-BF16](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-BF16/blob/49843eed8db1f1c616c47af75cfd36e07aec0667/README.md) | Gemma Apache-2.0 / Bolt OpenMDW; open | Maker4.5B effective /7.996B source each | Excluded: maker advertises 4.5B effective, above literal active-size cap. |
| [Meraj Mini](https://huggingface.co/arcee-ai/Meraj-Mini/blob/ca09341a4cae803c296f4453e33fc4293d254102/README.md) | Apache-2.0 card; open | 7.616B dense; qwen2 | Excluded: 7.616B dense, despite 2026 repository update. |
| [Phi4 mini / SmolLM3](https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/cfbefacb99257ffa30c83adab238a50856ac3083/README.md); [SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B/blob/a07cc9a04f16550a088caea529712d1d335b0ac1/README.md) | MIT / Apache-2.0; open | 3.836/3.075B; MLX builds exist | Date control: official source last updates 2025-12-10 / 2025-09-10; no qualifying 2026 maker update found. |
| [Granite4.0 micro / h-tiny](https://huggingface.co/ibm-granite/granite-4.0-micro/blob/56111ae135df9c53a78c99028e7bc24035a9e979/README.md); [granite-4.0-h-tiny](https://huggingface.co/ibm-granite/granite-4.0-h-tiny/blob/791e0d3d28c86e106c9b6e0b4cecdee0375b6124/README.md) | Apache-2.0 card; open | 3.403/6.939B source; h-tiny low-active family | Date control: both official sources last updated 2025-11-03. |
| [Qwen3 30B-A3B Instruct2507](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507/blob/0d7cf23991f47feeb3a57ecb4c9cee8ea4a17bfe/README.md) | Apache-2.0; open | 3B active /30.532B source | Date control: official source last updated 2025-09-17; resident 30B concern separate. |
| [ERNIE4.5 PT0.3B /21B-A3B](https://huggingface.co/baidu/ERNIE-4.5-0.3B-PT/blob/b565cf6caebdb7a1eadf00100857b1ed5e044f12/README.md); [ERNIE-4.5-21B-A3B-PT](https://huggingface.co/baidu/ERNIE-4.5-21B-A3B-PT/blob/87db95487941cb39592ee0abca3b9155a6d19c5c/README.md) | Apache-2.0 card; open | 0.361/21.949B source | Date/base controls: official updates 2025-08-29 / 2025-11-26; not cleanup instruct. |
| [Hunyuan4B Instruct](https://huggingface.co/tencent/Hunyuan-4B-Instruct/blob/167d1128f3f49ab2b644afe494428526309f12cb/README.md) | Custom licence not fully cleared; open | 4.222B source | Date control: official update 2025-10-31; custom licence not fully cleared. |
| [SimpleWords v3 metadata](https://huggingface.co/api/models/ReFyneLabs/simplewords-dictation-cleanup-v3/revision/7947b1eceef757de8784ea1d664648cdd22bd8e8); [v3 adapter metadata](https://huggingface.co/api/models/ReFyneLabs/simplewords-dictation-cleanup-v3-adapter/revision/b603b485ffb54f5458a94f1542cf1cad97cc872c) | Apache-2.0 card; model auto-gated, adapter open | Newer model/adapter; no weights fetched, no substituted v2 fusion | Model excluded from runs by gate; adapter unrun. Neither reproduces the private v2 q4 claim. |

Downloaded snapshots use `$STUDY/model-cache/models--ORG--REPO/snapshots/REV`; retained research metadata uses `$STUDY/public-metadata/`. Generated WhisperNow is `$STUDY/whispernow-mlx8`; generated SimpleWords q4 is `$STUDY/q4-simplewords/fused-q4`. Cached baseline locations resolve through the runner; source/build revisions above distinguish them. File bytes and loaded peak RAM are separate measurements.

Specialist contracts: WhisperNow uses one trimmed transcript-only user turn, greedy decoding, repetition penalty 1.05 over prompt+reply, `max(64,int(2.5*word_count))`; its [dataset card](https://huggingface.co/datasets/category271/whispernow-cleanup/blob/8a54b7665decf3362593f72d28eb7691b4508c59/README.md) attributes every reference to GPT-6.1-sol. SimpleWords uses its frozen prompt plus two newlines and raw in one user turn, greedy, thinking off, cap 512; its [maker](https://www.abhiramsalammagari.com/writing/dictation-cleanup-corpus-design) identifies 14,448 Qwen3.5-27B-q4-generated rows alongside 29,425 templated rows and 9,627 other unnamed local-MLX-generated rows. Kanso uses its actual trained system/user roles and published 200/400-token protocol. These are existing-weight evaluations only.

The fused SimpleWords q4 owner screen is complete: 303 takes, 5.8449% wWER versus raw 4.0868%,73 harms; McNemar versus 4B .0535444 (30 new/48 removed), so it fails. EdAcc was skipped under the mandatory owner-screen policy. Its public 28 diagnostic passed4/4 explicit self-corrections; the publisher's private 44+1,546 suite remains unreproduced.

[Official Gemma Apache licence](https://ai.google.dev/gemma/apache_2) resolves stale community tags. [LFM licence](https://huggingface.co/LiquidAI/LFM3-1.7B/blob/ac2586a34f1a1c03329dbdcdefabd8b6478ddaa7/LICENSE) sets the revenue condition. [Nemotron commercial licence](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/) does not apply by assumption to separately noncommercial Audex/DLM/GooseReason.

</details>

## Fine-tuning

The selected public-only MiniCPM5-1B LoRA fails the replacement bar on both
test cohorts. It also raises mean wWER and raw-relative harms versus its
matched untrained 1B control. Keep this adapter out of shipped weights.

All 14 evaluated existing pipelines failed mandatory quality conditions before
fitting. The eligibility audit passed, with its evidence snapshotted read-only.
Targets use human AMI text under fixed rules. Real Velora Whisper inputs and
injected fillers/restarts produce 881 training and 298 validation pairs, with
13/11 speakers and 7/3 meetings disjoint across the splits. There is no exact
input/target overlap across splits. EdAcc, owner takes, Qwen outputs, Wispr
output, and model-written labels contribute zero targets.

The fixed trial uses official MiniCPM5-1B q4, the same minimal prompt as its
untrained control, last eight layers, rank 8, scale 16, Adam 5e-5, seed 1029,
1,320 batch-2 minibatches and accumulation 2: 660 optimizer updates. The stock
iterator permanently excludes its one longest row, leaving 880 batchable rows;
three complete passes give 2,640 row presentations. All 1,179 prepared pairs
fit the 768-token cap without truncation; the long Default prompt does not.
The custom loss covers only human target tokens and native EOT/newline framing,
with the one-token prediction shift and padding mask checked before fitting.

Before any fit, this superseded the 100-minibatch plumbing pilot, which would
have presented only 200 rows. The replacement bar, data splits and all other
training parameters stayed fixed.

Selection used loss on 98 real AMI dev pairs, excluding the 200 synthetic dev
pairs, at steps 0/440/880/1,320; ties chose the earlier step. Owner and EdAcc
were one-time tests after selection. AMI loss selected step 440; later epochs
worsened it. No checkpoint was reselected after these test results.

The trial completed all 1,320 minibatches and 660 optimizer updates, with
1,867,776 trainable parameters. Total run time was 990.7 seconds, with training
peak MLX/RSS 1.886/1.411 GB.

| Checkpoint | Batchable epochs | AMI dev token loss | Selected |
|---|---:|---:|---|
| 0 | 0 | 1.934345 | No |
| 440 | 1 | 0.965096 | Yes |
| 880 | 2 | 1.090774 | No |
| 1,320 | 3 | 1.315420 | No |

The selected replay completed 923/923 rows with zero inference errors.
Product predicates fail on 20/27 cases, versus 18/27 for the matched control
and 1/27 for the current 4B. Owner quality uses the same frozen evaluation
proxies described above. The table
separates lexical recovery (L) from aligned-term recovery (D); added/novel words
use the scoring definitions above.

Frozen owner303:

| Cohort | Arm | wWER % | fWER % | Exact | Worse/raw | L | D | Added/novel |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Owner 303 | Raw | 4.087 | 10.868 | 82 | 0 (0.0%) | 0/156 | 0/30 | 0/0 |
| Owner 303 | 4B | 6.073 | 10.585 | 80 | 91 (30.0%) | 46/156 | 7/30 | 132/148 |
| Owner 303 | 1B minimal control | 8.404 | 14.995 | 70 | 63 (20.8%) | 4/156 | 0/30 | 79/155 |
| Owner 303 | Selected LoRA | 10.783 | 23.110 | 29 | 126 (41.6%) | 6/156 | 1/30 | 151/125 |

EdAcc593:

| Cohort | Arm | wWER % | fWER % | Exact | Worse/raw | L | D | Added/novel |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| EdAcc 593 | Raw | 19.565 | 97.749 | 0 | 0 (0.0%) | 0/1301 | N/A | 0/0 |
| EdAcc 593 | 4B | 22.247 | 97.453 | 0 | 164 (27.7%) | 7/1301 | N/A | 35/86 |
| EdAcc 593 | 1B minimal control | 23.627 | 97.637 | 0 | 170 (28.7%) | 2/1301 | N/A | 57/130 |
| EdAcc 593 | Selected LoRA | 24.061 | 98.249 | 0 | 203 (34.2%) | 25/1301 | N/A | 224/100 |

LoRA recovers more EdAcc lexical fixes than the 4B (25 versus 7 of 1,301),
but raises mean wWER and harms. Owner recovery falls to 6/156 lexical and
1/30 aligned-term fixes, versus the 4B's 46/156 and 7/30.

All paired tests below are exact and two-sided. W/L counts lower/higher
per-take wWER; the sign test does not test the mean. New/removed counts compare
raw-relative harm membership. The auxiliary matched-control files call their
comparison field `vs_4b`; that field means the untrained 1B control there.
The primary files retain the true 4B comparator.

Owner paired tests:

| Cohort | LoRA versus | W/L | Sign p | New/removed harms | McNemar p |
|---|---|---:|---:|---:|---:|
| Owner | Raw | 6/126 | 2.52329e-30 | 126/0 | 2.35099e-38 |
| Owner | 4B | 69/121 | 0.000198376 | 87/52 | 0.0037703 |
| Owner | 1B minimal control | 50/106 | 8.6327e-06 | 95/32 | 1.93561e-08 |

EdAcc paired tests:

| Cohort | LoRA versus | W/L | Sign p | New/removed harms | McNemar p |
|---|---|---:|---:|---:|---:|
| EdAcc | Raw | 29/203 | 2.44127e-33 | 203/0 | 1.55575e-61 |
| EdAcc | 4B | 134/162 | 0.116418 | 130/91 | 0.0104208 |
| EdAcc | 1B minimal control | 137/158 | 0.244197 | 134/101 | 0.0366224 |

Eleven of 12 accent buckets have wholly positive LoRA-minus-raw 95% CIs;
UK/IE crosses zero. These pointwise speaker-bootstrap intervals retain the
speaker-count limits described above.

<details>
<summary>Selected LoRA: all 12 accent buckets</summary>

| Accent | Takes/speakers | Raw % | 4B % | 1B control % | LoRA % | LoRA minus raw 95% CI, pp | LoRA harms |
|---|---:|---:|---:|---:|---:|---:|---:|
| Caribbean | 50/6 | 28.290 | 29.404 | 29.968 | 31.854 | [+0.079, +8.719] | 17 |
| East_African | 50/2 | 18.432 | 20.894 | 22.889 | 24.858 | [+5.897, +6.954] | 19 |
| East_Asian | 50/5 | 21.021 | 23.475 | 24.358 | 27.203 | [+2.488, +9.876] | 19 |
| European_L2 | 50/28 | 19.854 | 21.084 | 24.156 | 25.929 | [+2.591, +9.960] | 18 |
| Indian_S_Asian | 43/5 | 14.299 | 20.476 | 20.086 | 19.449 | [+2.102, +9.573] | 14 |
| Latin_American | 50/5 | 15.844 | 17.901 | 17.236 | 23.852 | [+2.223, +16.584] | 23 |
| MENA | 50/3 | 13.880 | 18.335 | 23.077 | 16.934 | [+1.153, +5.010] | 19 |
| SE_Asian | 50/13 | 30.138 | 33.686 | 35.738 | 33.249 | [+1.710, +4.534] | 15 |
| Southern_African | 50/2 | 14.321 | 15.610 | 17.807 | 18.253 | [+2.851, +5.011] | 14 |
| UK_IE | 50/22 | 16.612 | 18.318 | 19.699 | 17.768 | [-0.267, +2.489] | 11 |
| US | 50/17 | 18.154 | 20.199 | 21.822 | 21.831 | [+1.591, +7.039] | 18 |
| West_African | 50/6 | 23.200 | 27.338 | 26.198 | 26.909 | [+0.338, +7.716] | 16 |

</details>

Inference measurements use the q4 shipping candidate and selected adapter.
They are separate from training resources; owner quantiles pool all 303 takes.

| Cohort | Arm | Total p50/p90, ms | TTFT p50/p90, ms | Peak MLX/RSS, GB |
|---|---|---:|---:|---:|
| Owner | 1B minimal control | 403.0/1157.6 | 36.5/190.7 | 1.739/1.324 |
| Owner | Selected LoRA | 842.7/3325.5 | 59.1/198.9 | 1.984/1.311 |
| EdAcc | 1B minimal control | 184.7/549.1 | 32.0/54.0 | 1.389/1.324 |
| EdAcc | Selected LoRA | 279.3/920.6 | 37.8/57.4 | 1.459/1.311 |

Both 1B runs process owner, bench and public cohorts in one process; public
memory measurements follow the earlier cohorts. The priority 4B public run
uses a fresh public-only process. These observed screening times and mixed
process peaks do not establish controlled shipping p90/RAM noninferiority.
Quality fails independently. This trial rejects this recipe and adapter;
it leaves other fine-tuning recipes untested.

The requested with-owner training ablation lacks independently human-written
owner targets. Claude-labelled evaluation files cannot supply them. No owner
takes may enter shipped weights without separate consent.


## Reproduction, downloads, and verification

The local artifact is a decision report and aggregate scorer, not a deployed
model or setting. The running app, live settings and Dictionary are untouched.
The isolated-home `make test` gate passed: 1,797 pytest tests, Swift selftest,
site, signing-config and publish-release checks. The 19 focused scorer/privacy
regressions also pass after test-name cleanup. Independent synthetic review
covered label collisions, incomplete pairing, conflicting/identical duplicates,
private Config warnings, repeated-word attribution and bootstrap key collisions.
The final 16-token overlap check found zero matches against 11,997 private
text fields across the four repository artifacts; no transcript examples
are included. Independent final review passed 71 additional aggregate checks
on the LoRA tables, paired directions, accent intervals and guard harm tests.

### Downloads and storage

<details>
<summary>All downloaded model revisions and source inventories</summary>

| Downloaded source | Revision | Repository inventory GB |
|---|---|---:|
| `ibm-granite/granite-4.2-3b-q8-mlx` | `8e19ac6574124635eb8fbd06a15d05ebbfff82dd` | 3.896 |
| `openbmb/MiniCPM5-1B-MLX` | `9879b18bf2928355fcdf4287635388a3665a40cb` | 0.618 |
| `ReFyneLabs/simplewords-dictation-cleanup-v2` | `1b0388753b6aa3baa471c45195d29122a52aef9b` | 2.020 |
| `BuilderHelm/Kanso-Satori-1.0` | `07a3ad5452b6393264310af5a99f7238a9a8d734` | 2.275 |
| `lmstudio-community/gemma-4-E2B-it-MLX-4bit` | `31512dab743c73974a99795270031a6f85072d94` | 4.372 |
| `category271/whispernow-qwen3.5-4b` | `3b271af4ac6f4eb181c3e77dcbfa2252c7605bfd` | 12.915 |
| SimpleWords v2 adapter/config/prompt | `7a6a41173775022d2adaeceabe61062ea1c9186c` | 0.0673 |

</details>

Repository inventories are advertised complete-file sizes, not network-byte
counters. Actual new model-cache retention is 24.683 GB, including an unused
GGUF and partial downloads. Existing shipped 4B/2B, Vedu, MiniCPM2B and S1
caches were reused. Generated WhisperNow q8 is 4.490 GB; generated SimpleWords
q4 plus adapter/metadata is 1.147 GB. Neither conversion is training.

Public downloads comprise EdAcc human metadata and selected audio, AMI IHM
human metadata/selected audio plus published Whisper diagnostics, VoxPopuli
`en_accented`, and public model cards/configs/templates/licences/source code.
Common Voice human audio/accent data was not downloaded. Public-data completed
transfer is 8.832 GB; the conservative transfer bound including failed/retried
requests and AMI revalidation is 9.354 GB. Metadata/source retention is 0.029 GB.
The two isolated runtime venvs retain 2.328 GB. Public LoRA pairs,
checkpoints/selected adapter and immutable eligibility evidence retain
0.0157/0.0449/0.00057 GB. Combined audited retention is
34.363 GB, below the 60 GB cap, with 89.138 GB free at that audit.
No login, gate or terms acceptance occurred. Manifests retain URLs,
revisions and hashes; owner files are excluded.

### Commands

Run from this checkout. All outputs containing per-take text remain private in
scratch. Named aggregate outputs can be inspected; never print row files.
GPU wrappers acquire `fcntl.flock` themselves. Do not wrap them in another lock
or run an unwrapped MLX command. Completed-run replay labels are resumable;
new code/prompt/settings require a new label. Rebuilding public preparation
rewrites manifests: use a separate scratch copy when preserving these results.

```sh
cd /Users/sushil/Code/Github/velora
SCRATCH='/private/tmp/claude-501/-Users-sushil-Code-Github-velora/692ba9ca-9639-4754-86c4-46838c7b1b81/scratchpad'
STUDY="$SCRATCH/codex-model"
OLD="$SCRATCH/lfm3ft/venvA/bin/python"
CORE="$STUDY/venv032/bin/python"
NEW="$STUDY/venv-lm032/bin/python"
PUBLIC_PY="$STUDY/public-data/venv/bin/python"
export VELORA_REPLAY_HOME="$SCRATCH/ftbench/owner-snapshot-1612"

# Frozen priority cohorts, including shipped small tier and both comparators.
"$OLD" "$STUDY/priority_scores.py" --cohort owner
"$OLD" "$STUDY/priority_scores.py" --cohort public
"$OLD" "$STUDY/score_controls.py"
"$OLD" "$STUDY/score_guards.py"
"$OLD" "$STUDY/score_completed.py"
"$OLD" "$STUDY/score_supplements.py"

# Original scorer: first arm is the comparator; prints aggregate tables only.
"$OLD" "$SCRATCH/ftbench/score_gold.py" \
  "$SCRATCH/ftbench/gold/gold-first.jsonl" "$SCRATCH/ftbench/gold/in" \
  "$SCRATCH/lfm3ft/runs/oc-qwen4b.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-minicpm5.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-muesli08.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-muesli2b.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-qwen2b.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-s1mini.jsonl" \
  "$SCRATCH/lfm3ft/runs/oc-vedu08.jsonl"
"$OLD" "$SCRATCH/ftbench/score_gold.py" \
  "$SCRATCH/ftbench/gold/gold-first.jsonl" "$SCRATCH/ftbench/gold/in" \
  "$STUDY/history-final-observed-v1.jsonl" "$SCRATCH"/lfm3ft/runs/oc-*.jsonl

# Anonymous pinned model fetches; existing snapshots are reused.
"$OLD" "$STUDY/download_models.py"
"$OLD" "$STUDY/download_extra.py"
# Fresh scratch only: conversion refuses an existing output directory.
"$NEW" "$STUDY/convert_whispernow.py"

# Source preparation and current Velora Whisper replay.
"$PUBLIC_PY" "$STUDY/public-data/prepare_edacc.py"
"$PUBLIC_PY" "$STUDY/public-data/prepare_ami_audio.py"
"$PUBLIC_PY" "$STUDY/public-data/prepare_vox_audio.py"
"$PUBLIC_PY" "$STUDY/public-data/audit_public_data.py"
"$PUBLIC_PY" "$STUDY/revalidate_ami_source.py"
"$OLD" "$STUDY/replay_public.py" --sets edacc,ami-train,ami-dev,vox

# CPU provenance and human-target/native-token checks.
"$OLD" "$STUDY/prepare_public_lora.py" --mode selftest
"$OLD" "$STUDY/prepare_public_lora.py" --mode build \
  --profile both --run-name public-v1
"$OLD" "$STUDY/train_public_lora.py" --selftest
"$OLD" "$STUDY/audit_public_lora.py"

# Eligibility audit, immutable evidence, fixed public-only fit and selected test.
# --write refuses a conflicting existing gate; preserve completed artifacts.
python3 "$STUDY/permit_public_lora.py"
python3 "$STUDY/permit_public_lora.py" --write
"$OLD" "$STUDY/train_public_lora.py" --run \
  --run-name minicpm5-1b-minimal-full-v2
python3 "$STUDY/lora_evaluate_selected.py"
python3 "$STUDY/score_lora_matched.py"

# Synthetic decision revisions stay separate; fresh workers, aggregate output.
"$OLD" "$STUDY/action_study.py" --run
"$OLD" "$STUDY/action_study.py" --run --models minicpm5-1b,minicpm5-2b \
  --label-encoding bare-label --revisions 1,2
"$OLD" "$STUDY/production_latency.py" --run --rounds 2 --samples 5 --include-new
"$NEW" "$STUDY/benchmark_idle.py"
"$NEW" "$STUDY/q4_simplewords.py" --run --published-q8 \
  "$STUDY/model-cache/models--ReFyneLabs--simplewords-dictation-cleanup-v2/snapshots/1b0388753b6aa3baa471c45195d29122a52aef9b"
"$OLD" "$STUDY/simplewords_q4_screen.py"

# Isolated-home full repository gate; fixed status/counts only.
"$OLD" "$STUDY/run_repo_gate.py"
python3 "$STUDY/storage_audit.py"
python3 "$STUDY/privacy_audit.py"
```

The bare-label Action command is a separate diagnostic; native results remain
the primary integration check. Action commands create fresh timestamped reports
and refuse an existing explicit output path.

For new priority inference, use fresh labels and the immutable v4 runner below.
It retains trained prompt/decoding contracts and freezes cross-run metadata.
The original priority manifests predate that metadata-hash extension; score
their retained outputs with the commands above to reproduce the printed totals.

```sh
BASE='/Users/sushil/.cache/huggingface/hub/.velora-downloads/15402d3d1555d0f44d9d7d265c6d779320e0c307f89dc65cb0cb9d91314c4b6b/snapshots/5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d'
Q2='/Users/sushil/.cache/huggingface/hub/models--mlx-community--Qwen3.5-2B-MLX-4bit/snapshots/93760be4f1f69842a46bc13dbdc0f19e291392a3'
SIMPLE="$STUDY/model-cache/models--ReFyneLabs--simplewords-dictation-cleanup-v2/snapshots/1b0388753b6aa3baa471c45195d29122a52aef9b"
"$OLD" "$STUDY/run_study-locked-v4.py" --model "$BASE" \
  --label reproduce-4b --prompt velora --sets owner,bench,public
"$OLD" "$STUDY/run_study-locked-v4.py" --model "$Q2" \
  --label reproduce-2b --prompt velora --sets owner,bench,public
"$OLD" "$STUDY/run_study-locked-v4.py" --model "$SIMPLE" \
  --label reproduce-simplewords --prompt simplewords --sets owner,bench,public
"$NEW" "$STUDY/run_study-locked-v4.py" --model "$STUDY/whispernow-mlx8" \
  --label reproduce-whispernow --prompt whispernow --sets owner,bench,public
```

Combined-cohort runs retain process peaks across earlier cohorts. For directly
comparable public resource measurements, use separate `--sets public` labels,
as in the priority study; do not compare a late-cohort cache peak to a fresh
public-only process.

The remaining inference supervisors preserve the executed model, runtime,
prompt and cohort arguments. They skip completed cleanup labels; the Action
step creates a fresh report. Run them serially:

```sh
"$OLD" "$STUDY/continue_study.py"
"$OLD" "$STUDY/additional_controls.py"
"$OLD" "$STUDY/supplement_controls.py"
```

`continue_study.py` records incomplete native Action integration before exiting
nonzero. Inspect its aggregate status rather than treating that exit as a
completed study. The scripts copy owner settings before Config migration;
history extraction uses SQLite `mode=ro`. No private row, vocabulary item or
model weight enters the repository.


## What improves dictation across users

1. Make preservation measurable. Dogfood the passing content guard behind
   a setting, retain immediate Raw access, and separate word preservation
   from punctuation/list preferences. The current 4B exceeds raw wWER;
   keeping it under the frozen rule is not evidence that cleanup helps
   every take. #33–#35 are already in the base, not new study improvements.
2. Improve correction observation before optimizing an edit-rate headline.
   At the study-start snapshot, 1,170 takes have 3 edited, 11 unchanged and
   1,156 unknown outcomes: 1.20% observation coverage. Three of fourteen is
   not a population edit rate. Record eligible/observed counts and missing
   reasons by setting, app and input length, on-device. Existing capture
   learns word changes; it does not supply complete human rewrites or all
   punctuation/layout edits.
3. Test quiet-speech handling with nonspeech controls. AMI's predecode
   rejections and the crop-dependent EdAcc example justify an acoustic
   regression set spanning quiet voices, microphones and background noise.
   Positives-only replay cannot establish the false-trigger cost of lowering
   thresholds. Evaluate STT and cleanup separately on the same audio.
4. Extend population coverage before changing defaults. Add human-reviewed
   accented spontaneous dictation, multilingual/code-switched speech,
   numbers, names, negation, lists and app-specific formatting. Keep speakers
   out of training and choose checkpoints without owner/EdAcc test access.
   Common Voice remains blocked on access; no borrowed accent claim fills it.
5. Validate each shipped RAM tier. This 36 GB M4 Max does not establish
   behavior on an 8 GB Mac. Compact uses 2B q4; Balanced uses 4B q4 and was
   not measured here; Quality uses 4B q8. Any two-model route needs combined
   residency or cold-switch measurements while Action Mode remains usable.

## Two-week dogfood plan

This is a future opt-in setting, not installed or enabled by this study.
Keep Current as the default and expose Experimental plus a one-click
rollback. Experimental keeps the same weights and adds the list-bypass
content-deletion fallback. Quality stays on 4B q8; Compact stays on 2B q4.
Balanced 4B q4 needs its own offline validation. Store variant IDs, counts,
timing and reason codes on-device; no owner-trained weights ship.

1. **Days 1–2: prove observability and integration.** Verify the setting,
   rollback, full cleanup/IPC latency and peak memory on the native path.
   Track correction capture as edited/(edited+unchanged), with unknowns
   excluded from the denominator and coverage always alongside it. Require
   at least 30% eligible observation coverage and comparable arm coverage
   before interpreting edit-rate differences. Current 1.20% is insufficient.
2. **Days 3–5: owner pilot.** Alternate Current/Experimental in AB/BA daily
   blocks. Collect at least 30 observed eligible takes per arm, recording
   input length, app, mode, tier, fallback reason and p50/p90. Review any
   number, negation, script or list loss before continuing. New human review
   stays separate from the frozen Claude-labelled evaluation proxy.
3. **Days 6–10: consenting-user pilot.** Recruit 8–12 users across at least
   four accent/language groups, multiple microphones/apps and base/Max Macs.
   Randomize daily blocks; target 200 observed takes per arm in the cohort.
   Give every user immediate rollback. Report sparse groups rather than
   treating pooled owner improvement as general success.
4. **Days 11–12: evaluate.** Use user-cluster 95% intervals for live edit-rate
   differences and coverage; unrelated live takes are not McNemar pairs.
   Report word versus punctuation/layout corrections separately where capture
   supports them. Require no confirmed critical content loss, no p90/RAM
   regression, and no group with a supported edit-rate increase. A proposed
   5-point noninferiority margin is meaningful only with adequate coverage
   and precision; otherwise continue Current and mark the result inconclusive.
5. **Days 13–14: decide.** Enable the guard only after its offline harm/term
   criterion and integrated/user evidence both hold. Any model change still
   needs the frozen replacement bar. Keep Current if evidence is owner-only,
   coverage is inadequate, or a critical regression remains. If a keep-warm
   tick is proposed, measure idle power/battery separately before adoption.
   Record the decision and outstanding groups; do not infer battery benefit
   from faster TTFT.
