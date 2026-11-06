# Reviewed public pilot v3

1,605 examples: 1,243 train and 362 dev. This extends [pilot v2](../pilot_v2/README.md) with 112 Terra-authored examples reviewed by Muse and 384 Muse-authored examples reviewed by Terra. The new examples emphasize negation, contrasts, explicit versus ambiguous repairs, unchanged text, names, numbers and irrelevant glossary entries. All 496 were approved by the opposite model family; these are model reviews, not human certification.

Muse did not expose its underlying weight-model identity. The recorded identity is the configured Muse CLI default; the YoYo receipt is `20261106T090219-01abb01c`. Terra joined 129 related Muse rows into 58 scenario families before curation. Generic curation then joins scenario and shared eight-word components before the stable split. The newly authored set contains no custom instruction examples; custom-control coverage comes from v2.

The fresh 96-case qualification v3 was authored in an independent fresh context without reading training data or prior predictions, then independently reviewed by Muse (`20261106T090755-f2a12535`). It was frozen before v3 training. All 251 old/new evaluation strings are exclusion guards. No personal recordings, personal transcripts or Qwen4B labels are training inputs.

Reproduce from the repository root using the isolated training environment:

```sh
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python -m cleanup curate \
  --input training/cleanup/data/pilot_v2/reviewed.jsonl \
  --input training/cleanup/data/pilot_v3/terra_generated_muse_reviewed.jsonl \
  --input training/cleanup/data/pilot_v3/muse_generated_terra_reviewed.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v3.jsonl \
  --ledger training/cleanup/data/pilot_v3/sources.json \
  --sotto-raw /path/to/verified/sotto-acquired-raw.jsonl \
  --out /tmp/pilot-v3.jsonl --report /tmp/pilot-v3-curation.json \
  --seed velora-public-20261106-v3
```

Dataset SHA-256: `af8e8411bce5939f7f9dae6fa895393c2adcb75f0979b256f843c3afd5f4021f`. Expected exclusions: 0. The acquisition procedure for the pinned public Sotto raw export is in [the training README](../../README.md). `curation.json` records input, guard and ledger hashes. The split was recomputed over the complete v3 corpus; it is not directly comparable to v2 development loss.
