# LFM3 public cleanup experiment v4

Contains public or synthetic text only. Personal recordings and podcast text are evaluation-only and are not included.

The baseline removes one entire scenario group from pilot_v3 after a new frozen challenge overlap check: 1,242 train and 362 unchanged development examples. The augmented corpus adds 234 independently model-reviewed examples to training only: 1,476 train and the same 362 development examples. Every checkpoint and recipe is selected on that common development set before the new challenge or private regression set is evaluated.

Muse authored 128 public Sotto targets from raw-only inputs and 128 synthetic examples. Independent Terra review approved235 and rejected21; curation removed one duplicate. Review is model-assisted, not human certification. All rejected rows and reasons are retained for audit. Source revisions and permitted licenses are in sources.json; Sotto upstream targets were withheld from the author.

The 96-case challenge was independently authored by Terra and reviewed by Muse before training. It contains48English,24Hindi,24Hinglish, including12long examples across6 paired-language families. Related family variants are correlated. training_exclusions_v4.jsonl combines the old251 guards and new96 cases. See qualification_v4.manifest.json for immutable hashes.
