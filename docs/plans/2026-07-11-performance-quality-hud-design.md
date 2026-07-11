# Performance, Writing Quality, and Live HUD Design

**Date:** 2026-07-11
**Status:** Approved

## Goal

Make Velora materially faster on this M4 Max MacBook without changing either
model or reducing transcription/writing quality, while fixing missing sentence
punctuation, adding conservative grammatical cleanup, and making the HUD's live
transcript readable and earlier.

The exact production models remain:

- Speech: `mlx-community/whisper-large-v3-turbo`
- Writing: `mlx-community/Qwen3.5-4B-MLX-8bit`

Terminal behavior remains intentionally narrow: dictations under 12 words in
Terminal-mode apps are inserted verbatim; longer prose is cleaned as prose.

## Verifiable success criteria

1. No model ID, precision, decoding quality setting, or final-transcription
   segmentation threshold is reduced.
2. A long Terminal dictation that the writing model ends with `.` keeps that
   period; a short command such as `git status.` still inserts as `git status`.
3. The writing prompt explicitly permits conservative grammar corrections
   (agreement, tense, and obvious speech artifacts) without paraphrasing.
4. Session-start prompt prefill is reusable by Qwen's non-trimmable hybrid
   cache. Ordinary final cleanup does not throw away the stable prefix.
5. The cleanup quality deadline begins after prompt prefill / first-token
   arrival, while a separate hard watchdog still bounds genuinely wedged work.
6. Cancelled or superseded streaming cleanups cooperatively stop on the model
   thread and cannot delay the final cleanup behind obsolete work.
7. Whisper's startup warm-up populates the same `ModelHolder` used by
   transcription, eliminating the second cold load.
8. The HUD shows a word-boundary phrase/sentence in a dedicated row rather than
   a mid-word, head-truncated fragment squeezed beside the waveform.
9. Preview-only Whisper decoding can update the HUD before the existing
   10-second committed segment; it never advances committed segment state or
   changes the <=45-second whole-clip final and >45-second stitched-final rules.
10. Hidden Velora consumes under 1% CPU in an idle Release sample on this Mac.
11. Python tests, Swift build, Swift selftest, exact-model quality fixtures, and
    an installed-app smoke test all pass before shipping.

## Evidence and current bottlenecks

Observed warm dictations spend roughly 0.7-1.2 seconds in Whisper and
1.9-3.0 seconds in Qwen cleanup. Several cleanups hit a nominal 1.5-second
budget and returned raw text. This Mac is also in Low Power Mode and under
heavy memory compression, which amplifies latency, but neither condition
explains the deterministic code issues below.

### Qwen cache misses despite warm-up

The installed Qwen 3.5 model creates a hybrid prompt cache containing
`ArraysCache` entries. The combined cache is non-trimmable. Velora warms a
static prompt with a dummy user message, tracks a sampled token that has not
actually entered the cache, and resets the entire cache as soon as the real
request differs. The roughly 1,050-token stable prompt is therefore prefetched
again for every dictation.

The fix is a session-specific, exact-prefix prefill. At recording start Velora
builds the same formatting prompt that finalization will use from stable
session context. It prefills only the longest safe token prefix before volatile
text/entity material. Finalization appends the remaining prompt and transcript
without trimming. Any mismatch resets safely to the established full-prompt
path; quality never depends on a cache hit.

Prompt-token bookkeeping records only tokens actually consumed by the cache.
The last sampled token from `stream_generate` is not recorded until it is fed
on a later call.

### Deadline includes prefill

The current soft deadline starts before tokenization and prompt prefill. A slow
prefill can exhaust the entire budget before the first output token, causing an
immediate raw fallback. The quality deadline will instead begin on first output
token, with prompt/TTFT time logged separately. A larger outer hard watchdog
continues to protect against a wedged MLX call. Output divergence and
cooperative cancellation remain fail-safe fallbacks.

### Obsolete cleanup keeps running

Cancelling an asyncio task does not stop the single cleanup executor thread.
Each streaming chunk task will own a `threading.Event`; cancellation sets it,
and Qwen checks it between tokens. Retraction replacement, session cancel,
supersession, and whole-text fallback all cancel both layers. Final cleanup can
then acquire the model promptly.

### Whisper is loaded twice

Startup currently loads and evaluates a model directly, deletes it, then lets
`mlx_whisper.transcribe.ModelHolder` load it again on the first decode. Startup
will warm `ModelHolder.get_model(...)` directly so the exact evaluated model is
the object reused by transcription.

### Missing Terminal punctuation and grammar scope

Smart Terminal correctly routes long prose to Qwen, but the shared code-mode
postprocessor strips a final period afterward. Period stripping will apply only
to verbatim/code-command gates, never to `smart_terminal` results. The system
prompt will also explicitly fix conservative grammatical errors while
preserving wording, meaning, tone, names, numbers, and uncertainty.

### HUD unreadability and idle animation

The current 420-point row reserves space for the context chip, dot, 120-point
waveform, timer, and gaps, then gives the remainder to a 60-character suffix.
The suffix can start mid-word and is head-truncated again by SwiftUI. It is the
layout in the supplied screenshot, not an inference failure.

The listening capsule becomes a two-row presentation when text exists:

- top: the latest complete sentence when it fits, otherwise the newest whole
  words that fit; up to two lines and never a partial leading word;
- bottom: app/mode chip, recording dot, waveform, and timer.

The panel grows vertically enough for the second row and keeps the existing
single capsule, transition identity, and control layout. Preview text is still
partial and explicitly non-authoritative; final text continues through the
unchanged high-quality final path.

An early preview-only decode is allowed after a shorter speech span/pause. It
does not mutate `_decoded_samples`, `_segments`, `_new_segments`, or final-tail
state. The existing 10-second / 25-second committed segment boundaries remain
unchanged. Backoff prevents repeated decodes of nearly identical audio.

All waveform, timer, dot-pulse, ring, and shimmer timelines are paused or
absent while the HUD is hidden. This removes the measured continuous SwiftUI
display loop without changing visible animation.

## Telemetry and privacy

Release logs gain timings and counters only: prompt tokens, prefix tokens,
cache hit/reset, prefill time, time to first token, decode time, output tokens,
STT preview/commit type, and cancellation. Transcript content is never logged.

## Risks and safeguards

- **Prompt reorder changes output:** golden prompt/real-model fixtures compare
  representative dictations, and cache misses always use the same final prompt.
- **Preview compute competes with recording:** previews are throttled, use the
  existing STT executor, and never alter committed/final state.
- **Cancellation races:** task-local events are indexed with their chunk task;
  tests cover normal cancel, retraction replacement, and a subsequent final.
- **HUD layout clips on small screens:** the panel owns the maximum two-row
  bounds and positioning tests/selftests cover width and phrase extraction.
- **Quality timeout becomes unbounded:** only the soft generation clock moves;
  the independent hard watchdog remains.

## Shipping boundary

After all automated and real-model checks pass, run an adversarial `yoyo`
review, address material findings, merge the isolated branch to `main`, build a
new patch release, install `/Applications/Velora.app`, verify the running app
and engine use the new bundle, then commit and push the release to `origin/main`.
