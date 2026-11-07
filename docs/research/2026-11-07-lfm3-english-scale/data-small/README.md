# English cleanup data: small (D)

This is the frozen public English-only D dataset: **3,101 rows**, with **2,525 train** and **576 dev**. `reviewed.jsonl`, `sources.json` and `curation.json` are byte-for-byte copies of the frozen artifacts. The first 1,466 rows are the original English baseline; their original splits and bytes are preserved.

D includes identity examples generated from approved parent targets. They share the parent family and are not independent source cases. `identity-manifest.json` records the first batch derivation. The source ledger lists public Sotto material (MIT) and project-generated and CC0 synthetic material; consult the ledger for per-source terms. No private dictation or evaluation predictions are part of this dataset.

The frozen `sources.json` is the ledger used for training; it has not been rewritten. `sources-prompt-isolation.json` is a separate, later audited guard ledger. It opts in to prompt-field isolation and exempts 137 exact nonempty generic instruction templates. With the full 779-case heldout union, both D and E pass validation under their respective audited ledgers; see `prompt-isolation-audit.json`. A template exemption applies only to that exact string, not to arbitrary instructions. Validation is not evidence of model quality.

The frozen curation report's `review_status` is a historical assertion, not a validator guarantee: validation checks declared provenance and, for approved additions, distinct teacher and reviewer strings; it cannot prove the reviewer type or actual independence. Local run records identify Muse as teacher and Terra as reviewer for the new batches, without human or audio certification. Summaries and teacher manifests are included with the [large dataset](../data-large/provenance/).

Keep the heldout [challenge](../challenge/) out of training and checkpoint selection.
