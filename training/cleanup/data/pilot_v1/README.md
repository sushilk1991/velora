# Reviewed public pilot v1

756 examples: 592 train, 164 dev. The corpus contains 254 original synthetic examples authored by Muse and independently reviewed by Terra, plus 502 raw Sotto inputs relabelled by Terra and independently reviewed by Muse after exclusions. These are model reviews, not human certification. No personal dictations or Qwen4B answers are included.

Sotto attribution: [juanquivilla/sotto-transcript-cleanup](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup), revision `183cc8fd58532f13fa192980185214de1bcd5acc`, declared MIT in its dataset card. Only its raw inputs were supplied to the relabelling teacher; original Sotto answers were withheld. See `provenance.json` for source file hashes and teacher receipts. Keep this attribution with redistributed data.

`reviewed.jsonl` is the exact split used by the pilot. The two longer review files retain rejected examples for audit. Curation rejects unapproved rows and exact/eight-word holdout overlaps, removes normalized duplicates, and joins scenario groups and shared eight-word sequences into connected components before splitting. This guards obvious leakage; it cannot prove absence of paraphrased contamination.

From the repository root, using the isolated training environment:

```
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python -m cleanup acquire-sotto --out /tmp/sotto-raw.jsonl
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python -m cleanup curate \
  --input training/cleanup/data/pilot_v1/muse_generated_terra_reviewed.jsonl \
  --input training/cleanup/data/pilot_v1/sotto_terra_relabelled_muse_reviewed.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v1.jsonl \
  --ledger training/cleanup/data/pilot_v1/sources.json \
  --sotto-raw /tmp/sotto-raw.jsonl --out /tmp/reproduced-pilot.jsonl \
  --report /tmp/reproduced-pilot-report.json
```

Expected output SHA-256: `3c51a38930ccc1fc4bb39b791807a1fa5ade1bccc13b438eec12cd6b30af8547`. The frozen 64-case public test was authored separately before training; another 27 legacy benchmark inputs are contamination exclusions. Neither belongs in training or teacher prompts.
