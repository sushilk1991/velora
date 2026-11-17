# Independent review disposition

Muse read-only review: `raw/harness-review.txt`. Findings were assessed before
starting the fresh controlled study. The earlier `baseline-initial` is discarded:
it ran during extreme host load, used the pre-review copy-draft policy on
romanization, and its end-of-run source hash cannot identify the script image
already loaded into the parent. It is retained only as a diagnostic record.

- Production error/timeout/recovery reason prefixes reject a paired round.
- Both arm policies, per-request input/prompt hashes and copy-draft flags must
  remain identical within an arm. Runtime and source hashes must match across
  all four runs. Baseline ID, prompt, allocator and draft policy are enforced.
- Applying a chat template to Muesli failed: the pinned snapshot has none.
  Primary-source recheck showed its card explicitly requires manual encoding.
  The repaired adapter matches its single-user training string, paragraph
  breaks and two trailing newlines, with `add_special_tokens=False`. Its config EOS is end-of-text; the worker
  additionally installs the required end-of-turn EOS in memory. Both Muesli
  sizes were rerun with the correct stop contract. That
  failed adapter attempt is excluded from model-quality and latency results.
  Card revision, URL and hash are in `muesli-card-evidence.json`. Vedu controls
  remain an explicit experimental adapter;
  passing it would still require a real production integration and broader
  qualification. No model-card throughput is treated as a Velora result.
- Specialists retain the deterministic gated source. The existing S1 helper
  now accepts that source rather than restoring the raw fixture text.
- Copy drafts are requested for ordinary cleanup, disabled for romanization,
  and still controlled by the production model allowlist.
- Parameter accounting merges all shard headers, respects per-module group
  overrides, restricts text namespaces and excludes duplicated tied LM heads.
- Predicate regressions from either candidate repeat are checked; already
  failing cases cannot hide a newly failing predicate.
- Worker PIDs are recorded and a changed PID set rejects a paired round.
  Worker failure reasons independently reject it. Peak physical footprint is
  the kernel high-water mark; MLX active bytes are not used as process memory.
- Frozen case/repeat coverage and ordered nonoverlapping run timestamps reject
  copied or incomplete rounds.
- Host commands have three-second timeouts. Monitoring starts before artifact
  hashing, and errors, a live monitor at shutdown or gaps over five seconds
  reject the run. Quiet admission requires 30 seconds of stable host telemetry.
- Each close is attempted even after a previous close fails. Environment and
  monkey patches are restored. A remaining retired worker is an error.
- Contaminated or incomplete runs now return nonzero, preserving their logs.

Focused CPU checks pass on Instabox: 71 tests, including production failure
spellings, worker CLI forwarding, late predicate regressions, chronology,
policy drift and gated specialist input. The full macOS engine gate passed: 2,438 tests and 3 skips; the subsequent
adapter correction is covered by the final focused checks.
Screening explicitly never authorizes a production replacement: semantic
review, all existing tests and shared edits/actions/notes evaluation remain
required for any survivor.
