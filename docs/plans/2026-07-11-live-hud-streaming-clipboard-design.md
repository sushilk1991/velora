# Live HUD, Streaming Preview, and Clipboard Safety Design

**Date:** 2026-07-11  
**Status:** Approved

## Goal

Replace the visually noisy two-row recording capsule with a compact, stable
live card; make the exact Whisper model produce genuinely incremental HUD
previews without blocking microphone ingestion; and guarantee that every final
dictation remains available on the clipboard when synthesized paste fails.

The exact production models and authoritative final-transcription path remain
unchanged:

- Speech: `mlx-community/whisper-large-v3-turbo`
- Writing: `mlx-community/Qwen3.5-4B-MLX-8bit`

## Approved visual direction

The recording HUD is a quiet native live card rather than a stretched capsule.
Its recording footprint is fixed at approximately 348 x 72 points so incoming
words never resize or re-center the shell.

The hierarchy is:

1. Live transcript: primary, two lines, leading aligned, stable footprint.
2. Audio state: a small live waveform at the leading edge.
3. Context: the frontmost app icon and detected mode remain visible in a
   restrained secondary footer, as explicitly requested.
4. Elapsed time: tertiary, trailing aligned, monospaced digits.

The current rotating gradient ring, large 120-point waveform, pulsing recording
dot, and full-text shimmer are removed. The card uses native glass/material, a
neutral one-point border, a soft shadow, and Velora violet only as a restrained
waveform accent.

Before the first preview, the transcript area says `Listening...`. Once text
arrives, the same reserved area displays the newest useful whole-word phrase.
No width or height changes occur during recording. Text updates do not animate
the entire sentence; unchanged words remain visually stable while only the
provisional suffix changes.

On release, the same card enters `Polishing` state: the waveform settles, the
timer stops, and the last preview remains readable without shimmer. On success,
the card collapses once into a compact `checkmark + Copied` pill and dismisses.
`Copied` is deliberately used instead of `Inserted` because clipboard placement
is observable and guaranteed while another application consuming synthetic
Command-V is not.

Errors retain an actionable compact card. Permission, secure-input, and
focus-change fallbacks continue to state that text was copied.

## Streaming preview design

The current Whisper preview is delayed until either a pause after four seconds
or eight seconds of continuous speech, and then requires three seconds of new
audio. More importantly, `feed_chunk` awaits preview inference on the single
STT executor, so merely reducing those constants would queue microphone frames
behind model work.

The new preview lane separates cheap audio ingestion from display-only decode:

- PCM frames are appended immediately; model inference is never awaited by the
  socket's audio-ingest path.
- At most one preview decode is in flight. New requests coalesce to the latest
  audio snapshot instead of building a queue.
- The first preview is targeted after roughly two seconds of voiced audio;
  subsequent previews are adaptive, normally every 1.5-2 seconds or sooner
  after a useful pause.
- Cadence backs off from the measured preview duration so a slower Mac cannot
  saturate inference.
- Preview decoding uses a bounded recent window for predictable latency and is
  explicitly non-authoritative. It may revise its suffix.
- Stop cancels any pending preview request and waits only for an already-running
  bounded decode before the authoritative final path uses the model.
- Existing committed-segment thresholds and all <=45-second whole-clip versus
  >45-second stitched-final behavior stay unchanged.

This preserves final quality: only ephemeral HUD text uses the new lane. The
final transcript still covers every audio sample with the same model, decode
settings, cleanup model, and quality gates.

## Clipboard invariant

After voice-command detection and before any insertion attempt, every non-empty
final dictation is written to the general pasteboard. This applies to:

- normal synthesized Command-V insertion;
- configured Unicode-typing fallback;
- Velora's own onboarding text editor;
- secure-input, focus-change, and missing-permission fallbacks.

The existing pasteboard snapshot/restore mechanism then snapshots the final
dictation rather than the user's previous clipboard. If Command-V succeeds,
the text remains available; if it fails, manual Command-V still works. A user
copy made during the insertion window continues to win through the existing
change-count guard. Whole-utterance voice commands are not copied.

## Verification

Completion requires all of the following:

1. Swift self-tests cover stable HUD geometry, whole-word transcript selection,
   context visibility, and the `Copied` success state.
2. Python tests cover non-blocking ingest, single-flight/coalesced previews,
   adaptive cadence, stop/final ordering, and unchanged final output.
3. Clipboard tests or a deterministic insertion seam prove the final text is
   staged before own-window, paste, and typing insertion paths.
4. Release build and exact-model engine tests pass.
5. A live installed-app run visually proves the recording, preview, polishing,
   and copied states; a real target-app run proves both automatic insertion and
   manual paste from the retained clipboard.
6. Runtime logs show an early partial before stop while audio continues to be
   accepted, with no model or final-quality-path change.

## Risks and safeguards

- **Preview competes with final inference:** one bounded in-flight preview,
  coalescing, adaptive backoff, and stop priority prevent an unbounded queue.
- **Concurrent model access:** preview and authoritative final decode are
  serialized around the shared Whisper model even though ingestion continues.
- **Text revisions look unstable:** fixed geometry, whole-word selection, and
  stable-prefix rendering keep provisional changes local.
- **Clipboard overwrites prior user content:** this is the approved reliability
  tradeoff; a subsequent user copy always wins and is never restored over.
- **Context makes the footer noisy:** app icon and mode use secondary styling
  and never compete with the transcript.

