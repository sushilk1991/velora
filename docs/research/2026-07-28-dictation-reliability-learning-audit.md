# Dictation reliability, latency, and learning audit — 2026-07-28

## Scope and evidence

This audit combines:

- 206 local dictations recorded from July 10 through July 28;
- finalization, STT, and cleanup timings stored in
  `~/.velora/history.sqlite3`;
- the current engine/app control flow, local configuration, runtime logs,
  learned corrections, and auto-mined vocabulary;
- the June 28 through July 28 `last30days` discovery corpus across Reddit,
  Hacker News, and GitHub, supplemented with direct recent product and user
  sources.

The research corpus contained substantial unrelated model/news noise. The
feature ranking below is therefore a qualitative synthesis of recurring,
dictation-specific evidence, not a claim that every fetched item was a feature
request.

## The three strongest current feature asks

1. **A trustworthy core loop:** reliable capture and insertion, low perceived
   stop-to-text latency, accurate text, and a recoverable transcript when
   anything fails. Recent dictation work repeatedly groups speed, accuracy, and
   reliability rather than treating them as independent features. A recent
   Superwhisper user request similarly prioritizes reliability, speed, and ease
   of use.
2. **Personal vocabulary and correction learning:** names, jargon, and repeated
   corrections should improve future dictations, and users need visibility and
   control over what was learned. The recent Mumble launch leads with vocabulary
   learning; a current Wispr Flow complaint specifically says that in-app text
   corrections were not learned.
3. **Long-form capture without a surprise cutoff:** users expect dictation and
   meetings to keep recording, retain audio/transcript state, and show an
   hour-aware timer. Long-form products now explicitly advertise unlimited
   continuous dictation or retained multi-hour capture.

Representative sources:

- [Recent Superwhisper reliability request](https://www.reddit.com/r/superwhisper/comments/1tlinzd/dont_miss_this_in_the_latest_release/)
- [Mumble Dictation launch: vocabulary learning](https://news.ycombinator.com/item?id=49028737)
- [Wispr Flow correction-learning complaint](https://www.reddit.com/r/WisprFlow/comments/1v7ve9m/wispr_flow_doesnt_learn_from_inapp_text/)
- [TalkType feature set](https://talk-type.com/features/)
- [Dictate Keyboard long-form dictation](https://dictatekeyboard.com/)

These priorities primarily improve retention and learning speed. Adding more
modes before the core loop is trustworthy would increase surface area without
addressing the observed failure modes.

## Recording cutoff

The reported five-minute stop was real and deterministic:

- the engine default was `max_recording_s = 300`;
- the installed settings and projected engine configuration both contained
  `300`;
- runtime logs show two sessions automatically finalized at 4,801,600 samples,
  just beyond 300 seconds at 16 kHz.

The normal dictation default is now one hour. Version-1 settings containing the
old five-minute default migrate to version 2 and persist 3,600 seconds. A
non-default custom duration is preserved. The final engine event identifies an
automatic duration stop so the app can tell the user what happened, and the HUD
uses `h:mm:ss` at one hour and beyond.

The engine also emits an immediate `recording_auto_stopped` event before model
finalization. The app stops the microphone, freezes speaking duration, switches
to the transcribing state, and arms a duration-scaled watchdog. This avoids
discarding microphone frames behind a still-running timer and prevents a
legitimate long recovery decode from being mislabeled by the former fixed
20-second timeout. Short dictations retain the 20-second budget; a one-hour
recording receives six minutes, capped at ten minutes.

This is intentionally not a multi-hour normal-dictation cap. With audio archive
enabled, normal dictation holds one float32 PCM copy for the archive and another
inside Whisper: approximately 460 MB at one hour. A whole-clip recovery decode
temporarily materializes a third copy, bringing audio alone to roughly 690 MB;
at three hours those figures are approximately 1.38 GB retained and 2.07 GB
during recovery, before model and working memory. Cancellation or a process
failure can also discard the unfinalized session. Private Meeting Memory is the
correct 2–3 hour path: it spools separate microphone and system-audio CAF tracks
to disk while recording, then transcribes in resumable chunks. The engine
rejects a single meeting track only beyond four hours.

The one-hour change guarantees capture, not equally polished output from every
optional STT backend. The production Whisper path formats streamed segments;
the optional Parakeet path can hand a full hour of raw text to the existing
six-second whole-text cleanup ceiling. On that backend, cleanup may safely fall
back to the raw transcript. Raising that ceiling without a separate latency and
memory benchmark would make the stop-to-text tail worse, so it remains a
follow-up rather than part of this reliability fix.

## Latency findings

The product is not uniformly slow; it has a tail-latency problem.

| Measurement | Samples | Median | p90 | p95 | Maximum |
|---|---:|---:|---:|---:|---:|
| Finalization | 54 | 2,288 ms | 7,199 ms | 11,647 ms | 14,974 ms |
| STT | 171 | 724 ms | 5,267 ms | 6,076 ms | 11,133 ms |
| Cleanup wall time | 54 | 1,435 ms | 3,430 ms | 5,087 ms | 7,159 ms |

The 15–45 second recordings are the stable cohort: 2,299 ms median and 4,860 ms
maximum finalization. Both very short and over-45-second cohorts contain
10–15-second outliers. Logs tie those tails to two existing safety paths:

- authoritative whole-clip STT/glossary retries after a suspect result;
- cleanup worker hard-wall timeout and worker recovery.

No model, precision, timeout, multilingual, or fallback behavior was weakened
in this change. The current production models remain
`whisper-large-v3-turbo` and `Qwen3.5-4B-MLX-8bit`. The next latency work should
instrument retry reason and worker generation directly into history, then
optimize the dominant measured tail without removing the recovery behavior that
protects correctness.

## Learning and correctness findings

The learning architecture is present but its evidence quality is uneven:

- edit learning reads the accessible text field after insertion and promotes a
  correction only after repeated evidence;
- manual vocabulary, learned corrections, auto-mined vocabulary, and current
  screen entities are fed into transcription/cleanup context;
- the current stores contain one explicit vocabulary term, two soft
  replacements, 36 active auto-mined terms, 107 candidates, and no user bans.

Two concrete bugs undermined that loop:

1. Auto-mining reads previous STT output. A recurring mis-transcription could
   therefore become a candidate and eventually be fed back as preferred
   vocabulary, even after the user had corrected it.
2. Whisper occasionally appended the end of its `Glossary:` prompt to otherwise
   valid text. `Glossary` itself had already become an active auto-mined term,
   proving that prompt leakage could enter the learning store.

The engine now excludes the wrong side of both hard and soft user corrections
from mining and from loaded auto-vocabulary, rejects prompt-header artifacts,
and conservatively removes an exact ordered prompt-tail suffix after a completed
sentence. The suffix guard runs once on the authoritative assembled final,
rather than independently on every segment, and logs when it removes text.
Loaded prompt-header variants such as `Glossary:` share the same normalization
rule as newly mined candidates. The migration does not rewrite the user's
vocabulary files.

The model-quality audit also demonstrated why fixture review matters. Its first
Romanization pass changed source `मुझे` (`Mujhe`) to `Maine` but still satisfied
the older loose assertions. The prompt and quality case now prohibit that
inflection, and the exact production model passed both tightened Hindi
Romanization cases.

Correctness still cannot be claimed from the current history. Only 6 of 206
dictations have an observable post-insertion quality outcome: five unchanged
and one edited. Accessibility-readable fields provide useful correction
evidence, but Terminal, secure, clipboard-only, sent-message, and unsupported
surfaces remain unobservable. The smallest next step is an explicit one-tap
`Correct` / `Looks right` action in History for saved-audio rows, plus coverage
metrics broken down by app surface. That would create an honest evaluation set
without treating lack of an observed edit as proof of correctness.

## Verification

- Focused engine tests: 118 passed.
- Full engine suite: 431 passed.
- Swift self-test: 772 checks passed.
- Sublime plugin tests: 26 passed.
- Site and signing-configuration checks passed.
