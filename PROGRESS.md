# Cleanup model decision

Step 5 of 5: report and experiments complete; local review handoff on
`study/cleanup-model-decision`, based on `ded87d0` (Velora 0.29.7).
No push, merge, PR or main changes authorized.

## Done

- Frozen owner303 and EdAcc593 tables include raw, shipped 4B/2B,
  SimpleWords v2 and WhisperNow. Both specialists fail both cohorts.
- History final and all 30 earlier arms scored. Vedu fails EdAcc despite
  its owner win; Granite, MiniCPM1B, Kanso, Gemma and fused SimpleWords q4
  fail the owner screen. Conditional public skips are explicit.
- All 1,036 public audio replays and source joins pass, including AMI
  independent PCM validation. AMI/Vox supplemental controls are complete.
- List-bypass content guard reduces 4B harms 91→83/303 and 164→86/593
  with unchanged term-fix counts and no added product-benchmark failures.
  Minimal prompt and four-sentence chunking fail their declared criteria.
- Public-only LoRA completed 660 updates; AMI loss selected step440.
  Selected test completed 923 rows without runtime errors; it worsens both
  frozen cohorts and the same-size prompted control. All Action native and
  bare-label diagnostics are complete; 4B remains strongest on both revisions.

## Verified

- Fresh and archived 4B/2B outputs each match 303/303. Settings use the
  pinned scratch snapshot; SQLite opens read-only. App and Dictionary untouched.
- GPU/timing/training runs hold the regular-file flock. Audited retention
  is 34.363 GB, below the 60 GB cap. No login or terms acceptance occurred.
- Full isolated make test passed: 1,797 pytest tests plus required
  Swift/site/signing/publish markers. All 19 focused scorer/privacy
  regressions and 474 Action aggregate checks pass.
- Owner text/audio stay outside context and repository. Claude-labelled
  owner gold is evaluation-only; training uses human AMI targets only.

## Next

1. Review the opening decision table in
   `docs/research/2026-10-29-cleanup-model-decision.md`.
2. Before future dogfood, validate the proposed guard on the native path.
   Keep 4B cleanup/Action and shipped 2B Compact until that work qualifies.

Controlled shipping latency/RAM, native Action execution and broad accent
coverage remain unverified. Common Voice access is gated; a with-owner fit
needs independently human-written targets. Preserve unrelated `.orca/`.
