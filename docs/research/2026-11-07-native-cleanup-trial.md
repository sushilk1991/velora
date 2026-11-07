# Native cleanup personal trial — 7 November 2026

The signed personal build offers **Models → LFM3 Native — Experimental** when
its verified local kit is installed. The switch defaults off and changes only
after engine acknowledgement. Turn it off to return to the selected standard
cleanup model. This is a personal trial, with no public release or version bump.

The kit uses the earlier G 1.7B Q4 checkpoint and the existing C++/Metal worker:
copy length 8, ordinary system-prefix reuse, batch 128, context 4096, output 512, thinking
off. Rejected H/J checkpoints and compact prompts remain excluded. Identities,
installation contract and scope are in the [implementation plan](../plans/2026-11-07-native-cleanup-trial.md).

## What changed

Short supported English dictations in stock modes use the full tested student
request, including mode, strength, app context and vocabulary. Long/chunked
recordings, custom modes, screen entities, romanization, control-token literals,
other selected languages, edits, actions and meeting summaries use standard
cleanup. Explicit line breaks also use standard cleanup: its protected break
marker instructions are absent from the student contract. Auto language does
not distinguish languages written in Latin script;
use the trial for English and select another language or disable it otherwise.

The router reaps the active cleanup worker before loading the other backend.
Idle vocabulary mining and standard prefix warming do not wake the standard
model while native is preferred. Unsupported work still loads standard cleanup,
so alternating between workflows can incur cold model loads.

Expanded History shows the effective backend and checkpoint for matching trial
results. Original text remains available through As heard. Looks Right and
Correct Result save explicit feedback locally in `~/.velora/native-trial-feedback.jsonl`.
There is no automatic training or upload. Text-free provenance uses bounded
`native-trial-runs.jsonl`; hashes and timings bind it to the delivered result.
History edits and reprocessing invalidate previous provenance, including
identical-text replacements and delayed engine writes.

## Integration evidence

On this M5 Max / 36 GiB Mac, the real pinned runtime passed repeat-output equality,
context-overflow recovery, cancellation with no accepted text, and shutdown of
both owned processes. One runtime load took 5.98 s; three short synthetic worker
requests took 78.12, 38.51 and 38.50 ms. These are smoke measurements, not app latency.

A separate current-formatter replay used 24 existing owner Whisper transcripts
selected from 505 eligible cases in the frozen 614-recording corpus. All 24 used
native and completed with cleanup applied. Median formatting wall time was 172 ms,
after a 2.65 s model load. This checks integration, not semantic correctness or a
new population accuracy estimate. It does not retranscribe audio or measure
capture/insertion. Private per-case outputs remain outside the repository.

A real standard-model request then loaded Qwen3.5-4B MLX8-bit, followed by a
return to native. Both directions verified the previous worker PID had exited
before the next backend became active. Standard handoff plus one cleanup took
7.50 s, including a 5.97 s cold load. Model file size is not a RAM measurement.

## Remaining gaps and next experiments

- **Meaning preservation:** known correction and omission failures remain under
  full app instructions. Collect fresh confirmed/corrected trial results before
  another fine-tune; use an independently reviewed regression set. The
  [previous study](2026-11-07-simple-english-cleanup/README.md) records failed
  prompt and calibration attempts.
- **Cold switches:** measure real usage before changing residency. Retaining two
  cleanup models would undermine the resource goal. A smaller standard fallback
  or explicitly deferred background work needs its own quality test.
- **Long notes:** keep standard cleanup and hierarchical meeting summaries.
  Dictation cleanup weights are not qualified for summary generation.
- **Latency:** measure live stop-to-paste, p50/p95 and process footprint after user
  feedback. Warm worker throughput alone cannot establish an app-level win over
  Phonon. Keep prefix/copy optimizations already tested; no new inference rewrite
  is justified by this integration check.

## Verification

The full `make test` gate passed using
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`: 2,287 pytest
tests passed, three skipped, plus site, signing, publishing, bootstrap and
update-lifecycle checks. Final Swift selftest passed 3,978 checks after the
History fixes. The final focused router, eligibility, installer and socket suite
passed 65 tests after the explicit-layout and fallback-prefix guards. The
installed SDK27 still has its existing SwiftUI macro-plugin failure; SDK26.5
is the local build workaround.
