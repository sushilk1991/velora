# Reviewed public pilot v2

1,109 examples: 900 train and 209 dev. This extends pilot v1 with 128 original English examples authored by Terra and 256 Hindi/Hinglish examples authored by Muse. Muse independently reviewed the English batch; Terra independently reviewed the Hindi/Hinglish batch, approving 228 and rejecting 28. These are model reviews, not human certification.

The final corpus has 787 English, 162 Hindi and 160 Hinglish examples. It contains custom formatting controls, unchanged text, explicit retractions, distinct facts that must remain separate, longer paragraphs and romanization. It includes no personal dictations or Qwen4B answers. Sotto source attribution and immutable revision remain in [pilot_v1](../pilot_v1/README.md).

The author used separate `hi` and `hg` scenario namespaces for related translated examples. `prepare_sources.py` joins those family namespaces before curation; literal word overlap cannot find translations. Original family names remain in `original_scenario_group`. Generic curation then joins scenarios and shared eight-word sequences before the split. This is a conservative grouping rule, not a claim that paraphrased contamination is impossible.

Qualification v2 was authored independently without reading training data or previous tests. Its 64 cases were frozen before this training run; the exclusion file includes those cases, the original 64 public cases and 27 legacy benchmark inputs. Curation removed one old training example that overlapped the new exclusion set. Neither test set was supplied to the data teachers.

From the repository root, with the isolated training environment installed:

```
python3 training/cleanup/data/pilot_v2/prepare_sources.py --out /tmp/muse-families.jsonl
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python -m cleanup acquire-sotto --out /tmp/sotto-raw.jsonl
PYTHONPATH=training/cleanup training/cleanup/.venv/bin/python -m cleanup curate \
  --input training/cleanup/data/pilot_v1/muse_generated_terra_reviewed.jsonl \
  --input training/cleanup/data/pilot_v1/sotto_terra_relabelled_muse_reviewed.jsonl \
  --input training/cleanup/data/pilot_v2/terra_generated_muse_reviewed.jsonl \
  --input /tmp/muse-families.jsonl \
  --holdout training/cleanup/evaluation/training_exclusions_v2.jsonl \
  --ledger training/cleanup/data/pilot_v2/sources.json \
  --sotto-raw /tmp/sotto-raw.jsonl --out /tmp/pilot-v2.jsonl \
  --report /tmp/pilot-v2-report.json
```

Expected SHA-256: `b45c3e6eb987de01b3ee53462880cbf3b0f047762db59af0db764c7cfc6ef806`. Output paths must be new files. `curation.json` records all 43 exclusions and the hashes of every input.
