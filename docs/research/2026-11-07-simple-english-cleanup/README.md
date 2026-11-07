# Simple English cleanup follow-up — 7 November 2026

The smaller native cleanup model remains experimental. Prompt simplification improved selected examples but introduced omissions elsewhere. A targeted adapter improved the public correction proxy but still failed a known owner correction under the app's full request context. Both final serving-alignment checkpoints also fail the development preservation gate. No candidate is promoted. Installed defaults remain Whisper Turbo and Qwen3.5-4B MLX 8-bit until the complete fidelity gate passes.

The useful finding is a training/serving mismatch. With identical original G weights, tokenizer and worker, removing mode instructions resolves a known explicit name repair; removing vocabulary alone does not. Stock Default instructions alone and FULL-strength instructions alone can each suppress the repair. Original MLX H512 also fails it, so quantization is not a complete explanation. Mapping pure-prose Smart Terminal requests to the familiar training contract resolves a different known duration repair, but does not fix every formatting request. These are controlled locating results on exposed regressions, not an unseen accuracy estimate or proof that instructions explain every error.

## Fixed runtime and prompt search

Experiments retain the existing C++/Metal worker, G's naive Q4 artifact, batch128, context4096, ordinary system-prefix reuse, copy length8 and thinking disabled. Student-header caching stays off because its previous deadline qualification failed. No decoder/kernel rewrite or new dependency was added. The [previous English-scale study](../2026-11-07-lfm3-english-scale.md) owns the contemporary paired 264ms versus558ms owner cleanup comparison and the Phonon33ms versus native63ms public comparison. Those are different-weight/prompt/quantization comparisons, not isolated backend measurements, and not capture-to-paste latency.

All public development runs contain192 cases,185 with supported references. Repair, identity and protected-literal counts overlap and are lexical diagnostics, not semantic accuracy.

| Contract / artifact | Required repairs /43 | Exact no-edit /86 | Literals intact /81 |
| --- | ---: | ---: | ---: |
| Original canonical prompt, G native Q4 |32|83|79|
| Concise prompt, same G Q4 |31|82|79|
| Minimal prompt, same G Q4 |32|84|80|
| Original canonical prompt, G MLX8 + adapter |33|83|79|
| H256 targeted adapter, canonical MLX contract |35|84|78|
| H512 targeted adapter, canonical MLX contract |35|84|79|
| H512, actual serving fields V2 |36|83|79|
| J256, same serving fields V2 |36|81|78|
| J512, same serving fields V2 |36|81|78|

The minimal prompt reduced total full prompt tokens36196→32548 but did not improve measured request median58.57→58.99ms; cached system tokens are not fresh prefill work. A third correction-boundary prompt also failed to qualify. Prompt search outcomes are retained rather than selecting another variation from owner results.

The separate minimal-prompt scalar/copy8 check matched all192 prompt IDs, output IDs, answers and completion statuses, with all EOS and runtime recovery gates passing. Worker medians were81.33ms scalar versus58.80ms copy8 in one pair; this is descriptive workload timing, not a repeated latency guarantee. It validates an existing decoding optimization under the changed prompt, not a new app speedup. See [runtime-parity.json](runtime-parity.json).

## Owner fidelity gates

The frozen614-case replay uses the existing real Whisper Turbo transcripts and actual app formatting, guards and postprocessing. This round does not retranscribe audio or measure capture, insertion, model loading or live stop-to-paste. There are300 English cases with supported model-assisted references and305 English cases with uncertain references; other-language, empty and failed-STT cases remain in coverage.

The minimal system-prompt candidate had609OK, two fallback, two partial and one STT failure. All27 changed supported outputs were independently reviewed with prior regressions and controls,42 selected cases in total. It fixed two material cases versus original G with no new material case in that selected comparison, but still had three clear regressions versus production. It was rejected for a default change. The fresh256-case check was a reused regression suite, not untouched evaluation.

The more aggressive compact profile blanks stock Default/FULL instructions while retaining vocabulary and custom/explicit controls. It completed605OK, six fallback, two partial and one STT failure. Full300 candidate flags combine264 exact prior text/status judgment matches and36 newly blinded outputs. The selected51-case comparison favored compact over original G by three fixes/no regressions, but versus production it had two fixes/three clear regressions. Reviewer disagreements mean these counts differ from comparing prior primary labels.

The source-only audit of the305 uncertain-reference cases was decisive:215 exact prior output/status judgments reused;90 new outputs and eight unchanged controls independently reviewed. In those98 selected cases, compact introduced five new-only addition flags and seven new-only deletion flags, versus zero and one in the other direction. Several omissions were clear source-relative harms. These are fallible text-based judgments, not audio ground truth, but they fail the preservation gate. The [compact helper](../../../native/cleanup/experimental/english_context.py) and seven tests are retained strictly for the rejected experiment; the app does not import it. Public aggregates are in [compact-owner-quality.json](compact-owner-quality.json) and [compact-source-quality.json](compact-source-quality.json).

A vertical-list regression was also checked before considering a guard change. Its candidate returned comma-separated values despite the spoken vertical-list instruction. The low output-ratio fallback did not reject an otherwise correct vertical list. Weakening that guard would not fix the actual formatting error.

## Targeted data and calibration

Muse through YoYo generated48 original public repair/preservation/code examples; Terra reviewed them, including a second pass after scenario-specific instruction hints were removed. The first rehearsal contains96 existing public repairs,96 exact identities and those48 new rows:240TRAIN plus1427 unchangedDEV. All frozen content/component isolation checks pass. [Data and provenance](data-targeted/README.md) are exported. Owner text never becomes a training example; exposed owner failure types did inform the investigation, so later owner results are regression evidence.

H trains from the original selected G adapter for512 microsteps /128 optimizer updates, rank16/scale8, LR2e-6, accumulation4, warmup8, cosine schedule, seed42 and max sequence2048. Training took342.25s, peak MLX allocation3914220410bytes. H256 loses one protected-literal success and is rejected. H512 improves repairs33→35 and identity83→84 with unchanged literals79; independent review of all ten changed outputs plus eight controls found no new clear material error. Yet its cheap first44-owner locating replay still misses the known explicit name correction. Native conversion was stopped at that gate.

The final calibration J uses actual app-generated request fields rather than shorter training presets: FULL strength, app category, mode, language, vocabulary and caution-word context. Eight additional Muse layout examples were independently approved by Terra, and eligible existing public Note lists were represented under Default/Smart Terminal contracts. All300 candidate training pairs were then reviewed against all nine complete templates. Nine incompatible and one uncertain target were excluded rather than rewritten, leaving290TRAIN plus the unchanged1427DEV. This uncovered deleted qualifiers and mode conflicts that earlier label approval missed. [The serving data](data-served/README.md) preserves candidates, exclusions, approved rows and source hashes.

An initial J attempt was interrupted after213.25s because nuisance vocabulary incorrectly pooled original DEV as well as TRAIN:50 of196 entries were DEV-exclusive. It produced no saved checkpoint and is excluded from qualification. The corrected pool uses original TRAIN only, four exact-string sets of37 terms, with two normalized case overlaps explicitly recorded. The complete source/target/template review packet is byte-identical after this change. J restarts from untouched H512, never the interrupted attempt; its parent is rerun on the exact corrected serving probe before comparison. The original standalone tokenizer diagnostic also incorrectly counted a Transformers dictionary; it was invalidated, corrected to MLX-compatible integer token lists, and never used by training or selection. Actual trainer preflight independently rejects truncation or overflow.

J uses the same registered512-microstep recipe. Selection requires all192EOS, no decrease in repair/identity/literal counts versus H512 on the serving probe, at least one increase, and no new clear material error in independent changed-output review. Original-dev compatibility and known-owner locating gates precede native conversion and a full replay. Validation loss is diagnostic rather than the checkpoint selector. J completed in565.21s with peak MLX allocation5374008340bytes; this is training allocation, not inference or whole-app memory. Both checkpoints complete192/192 EOS but keep repairs at36/43, reduce exact identities83→81 and reduce intact literals79→78. Both therefore fail required objectives. No checkpoint is selected, and later semantic/original-dev/owner/native/fresh gates are not run for J. Their saved artifacts and failures are retained; the gates are not weakened. Results and artifact hashes are recorded in [results.json](results.json).


Before finalizing rejection, a source-only independent review audited all192 serving-probe references and flags without reading model outputs. It minimally amended eight targets and found183 supported, eight uncertain and one invalid under the current instructions. One no-edit flag penalized required Message punctuation removal, so that original penalty is not evidence of harm. The original files and failed gate remain preserved. All model input fields are byte-for-byte unchanged; only evaluation annotations are rebound with explicit receipts, without running inference again. No revised annotation is used in training.

| Contract-audited probe | Repairs /41 | Exact no-edit /85 | Literals intact /80 |
| --- | ---: | ---: | ---: |
| H512 |34|82|78|
| J256 |34|81|77|
| J512 |34|81|77|

The preservation failure remains after that correction. In particular, J inserts a new line into source code whose current instructions require the original shape verbatim; the source-only reviewer retained that no-edit check. The literal check also remains, though interpreting historical-versus-retracted statements is inherently fallible without more context. Thus the failed strict scores are not proof of a broad semantic regression, and the corrected audit does not create a qualified candidate. See [contract-audit.json](contract-audit.json), [scores](contract-audit-proxies.json) and the exported evaluation-only review in [data-served](data-served/README.md).

## Verification and scope

This round starts from main `d4b4c02924488d8fe6a2f9052abb64d0d8046148`. No production Swift/engine inference code, app default, installed model or version is changed by the failed profiles. Owner transcripts, audio, references and private per-case review keys remain local. Public exports contain public/synthetic data and aggregate outcomes only. Current Mac: M5 Max,36GiB; artifact sizes are not RAM measurements.

The ordinary SDK27 `make test` invocation fails because the installed Command Line Tools cannot load `SwiftUIMacros.StateMacro`. With `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, `make test` passes:3935 Swift checks,2151 pytest passed/3skipped, site/signing/publish-release/bootstrap and14 update-lifecycle checks. The isolated training suite passes123 tests; compact-helper tests pass7. This is an SDK workaround for running the gate, not a source workaround or a claim that default SDK27 passes.

The initial two-hour search window elapsed during the serving bug-fix follow-up; that overrun and the213.25s invalidated attempt remain in accounting. No further prompt or training recipe is selected after the final registered calibration. Existing subscribed agents were used; no new dependency, cloud GPU, paid API integration or model download was added. The existing native path remains the right lightweight inference candidate, but this round produces no qualified app/model switch. Before further training, resolve the actual instruction contract and build a small independently adjudicated regression set: more synthetic rows and a shorter prompt have both failed to establish a safe replacement. A custom inference rewrite would not repair the observed meaning losses. These cleanup weights remain separately unqualified for meeting summaries; the previous study records the failed long-podcast summary experiment.
