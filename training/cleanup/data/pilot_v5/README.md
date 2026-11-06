# LFM3 public cleanup experiment v5

This dataset contains public or synthetic text only. Personal recordings, meeting transcripts, and model predictions are not training inputs. Review is independent and model-assisted, not human certification.

The final corpus has **2,216 examples: 1,799 train and 417 development**. The original pilot_v4 corpus remains an exact byte prefix: all 1,838 original rows, their order, scenario groups, and splits are unchanged. Its 1,476 training and 362 development examples are supplemented with 323 new training and 55 new development examples. The 20% development setting assigns connected scenario components by seeded hash; it does not promise exactly 20% of rows.

Muse authored 384 additions: 128 targets for raw-only public Sotto inputs and 256 synthetic examples. Fresh independent Terra review approved 382 and rejected two, with 23 target edits. The reviewed additions contain 258 English, 63 Hindi, and 63 Hinglish examples. Curation excludes the two rejected rows, two normalized duplicates, and two rows in a component containing an exact baseline duplicate. The remaining 378 additions form 272 connected components. No surviving component needed assignment to an original split, and no train/development bridge was retained.

Sotto raw membership is checked against the pinned public export at revision `183cc8fd58532f13fa192980185214de1bcd5acc` (MIT). Its upstream targets were not used as teacher labels. New synthetic examples use source `velora-muse-contrast-v5`, revision `20261107`, under CC0-1.0. The full source ledger, including inherited sources and licenses, is [sources.json](sources.json).

[prepare_lfm3_v5.py](../../scripts/prepare_lfm3_v5.py) validates the original corpus against all 443 frozen guards before adding anything. Original overlap is fatal; it is never repaired by removing data already seen by the starting checkpoint. The guard union comprises 347 earlier exclusions and the fresh 96-case V5 challenge. Additions must be approved, public, ledger-backed, and isolated from guard raw/target/template text by normalized exact comparison and shared eight-word sequences. Existing curation deduplicates rows and connects surviving scenario families and shared eight-word sequences. A new component duplicating baseline content or bridging original train and dev is discarded whole; otherwise an overlap forces its original split, and independent components receive the seeded assignment. Combined train/dev validation runs again before output.

The independent V5 challenge was authored by Terra and reviewed by Muse, with its manifest recording a freeze before final training. It has 48 English, 24 Hindi, and 24 Hinglish cases, with 16 cases in each of six modes. Its text is evaluation-only. The final C recipe continues the selected B adapter, and checkpoint selection is preregistered on all 417 development examples, including evaluation of the initial B checkpoint. Final challenge or private benchmark performance must not select the checkpoint. Related scenario variants remain correlated; neither the development nor challenge count implies independent observations.

[reviewed_additions.jsonl](reviewed_additions.jsonl) retains all 384 reviewed candidates, including rejections. [review_summary.json](review_summary.json) records review changes. [curation.json](curation.json) records every exclusion, component assignment, original/new development membership, source hashes, and input/output hashes. The checked artifacts are:

| Artifact | SHA-256 |
| --- | --- |
| Original pilot_v4 rows | `85d6401b8d713ff729c30dd596ceef830d5698ccb9692c580745f5074013e340` |
| Reviewed additions | `aa16a60372292fcf3d4a24127cf8279b32dd4d9fd8031569071607a971380264` |
| Final reviewed rows | `fac685509b3d1b5b44e4af6707ce8e1f8e2a525e215b4083507a2ecd89f48a51` |
| Source ledger | `f14b7f51f1143ab96f1644e1f3a786fec45e3e03fc791f23d958fe73cb80bb8c` |
| Fresh V5 challenge (manifest value) | `792e9a8549af9afa68655451c73ab8b1cff01dd9280bcada9956af9334e153a4` |

The recorded split seed is `velora-public-lfm3-v5-20261107`. Reproduction requires a fresh output directory and the pinned raw-only Sotto export identified in `curation.json`; no model loading is involved.
