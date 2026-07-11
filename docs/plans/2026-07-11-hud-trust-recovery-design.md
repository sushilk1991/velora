# HUD Trust and Performance Recovery Design

**Date:** 2026-07-11  
**Status:** Approved

## Problem

The 0.4.6 live-transcript HUD reduced trust instead of increasing it. It made
raw, revisable Whisper preview text the dominant visual, replaced the original
24-bar motion with a tiny seven-bar mark, mislabeled terminal sessions as
`Code`, and added preview inference that delayed authoritative transcription
and cleanup on the test Mac.

Live evidence from the installed build established four separate failures:

- Short natural Ghostty utterances were routed through Terminal's verbatim
  path solely because they contained fewer than 12 words. They received no
  grammar or punctuation cleanup.
- A longer Ghostty passage did receive Qwen cleanup, but the HUD did not make
  the raw-preview versus cleaned-final distinction visible.
- The HUD displayed `Code` while the engine resolved the same sessions to
  `Terminal`.
- During the first installed test, Qwen prefix preparation rose from roughly
  1.3 seconds to 15.7 seconds and Whisper stop-time transcription took 4.57
  seconds. The aggressive HUD-only preview lane was competing for the Apple
  GPU and could still be ahead of authoritative work at stop.

This is a retention and trust problem, not a cosmetic preference. A dictation
tool must first insert the words the user intended, quickly and consistently.

## Product tenets

1. **Authoritative text outranks preview theater.** The floating HUD must never
   present raw provisional words as if they were the polished result.
2. **Optional work never delays final work.** HUD feedback and cache warm-up
   may improve perceived speed, but neither may sit ahead of final Whisper or
   Qwen work after the user releases the hotkey.
3. **The interface tells the truth.** The displayed mode must match the policy
   the engine applies.
4. **Restore the known-good motion before inventing another design.** The user
   explicitly preferred the original waveform and state morphs.
5. **Quality remains fixed.** The production models remain
   `mlx-community/whisper-large-v3-turbo` and
   `mlx-community/Qwen3.5-4B-MLX-8bit`; no precision, model, or final decoding
   quality setting is reduced.

## Approved HUD

The recording HUD returns to the original waveform-first capsule and no longer
shows provisional transcript text.

### Listening

- A compact 56-point-high capsule.
- Frontmost app icon and the actual resolved mode at the leading edge.
- The original red listening dot, 120 x 32 point waveform, and elapsed timer.
- The original 24 mirrored bars, using all 12 spectrum bands at 30 fps.
- The original restrained rotating listening ring, material, border, shadow,
  and entrance spring.

The capsule remains a single row for the entire recording. Audio energy gives
immediate, honest feedback without claiming the words are final.

### Transcribing and success

- On release, the recording dot and timer disappear and the waveform settles
  with the original shimmer.
- No generic `Polishing` label is shown before the engine knows cleanup will
  run.
- Success restores the original brief green waveform flash and morph to the
  compact checkmark state, followed by dismissal.
- The existing clipboard guarantee remains unchanged: every non-command final
  result is staged on the clipboard before insertion.

### Errors and notices

The original actionable error capsule, learned-correction toast, and general
notice states remain. Hidden timelines stay paused so the HUD consumes no
continuous idle animation CPU.

## Engine behavior

### Remove HUD-only preview inference

Whisper's aggressive two-second display-preview lane is disabled in production.
The 10/25-second committed segmentation used for long-dictation cleanup and
final latency remains; only the extra non-authoritative HUD re-decodes are
removed. The app may continue to parse protocol partial events for compatibility,
but the recording HUD does not display them.

This removes stale preview text, avoids stop waiting behind a display-only
decode, and lets Qwen prefix preparation finish before the first long-dictation
segment normally becomes due.

### Prioritize final cleanup

When stop begins, session prefix preparation is cancelled before authoritative
finalization. Its cooperative cancellation signal is set early enough to free
the single cleanup executor while Whisper finalizes. A final cleanup must not
time out merely because optional prefill was queued first.

### Distinguish Terminal prose from commands

The fixed 12-word boundary is replaced by a conservative deterministic gate:

- Explicit shell syntax, flags, paths, assignments, operators, and ambiguous
  command-shaped fragments remain verbatim.
- Clearly prose-shaped short utterances—personal pronouns, natural questions,
  polite requests, or ordinary sentence structure without shell syntax—use the
  existing smart-Terminal Qwen prompt.
- Long Terminal prose continues to use smart cleanup.

The classifier only chooses between existing verbatim and smart-Terminal paths;
it does not rewrite text itself or add another model.

### Mode truth

The client distinguishes terminal apps from code editors. Ghostty, Terminal,
iTerm, Warp, and other supported terminals display `Terminal`; VS Code, Cursor,
Zed, and other editors continue to display `Code`.

## Verification contract

The recovery is not complete until all of the following pass:

1. Unit tests prove short Terminal prose enters cleanup while representative
   commands remain byte-for-byte verbatim.
2. A concurrency test proves stop signals prefix cancellation before final
   cleanup is submitted and does not poison the cleanup engine.
3. Swift self-tests prove terminal mode labels and the restored 56-point HUD /
   24-bar geometry.
4. The full Python suite, Swift release build, and Swift self-tests pass.
5. Exact-model benchmarks retain punctuation, grammar, names, numbers, and
   meaning.
6. An installed-app screen recording covers listening, transcribing, success,
   and error states with the real HUD—not only an offscreen snapshot.
7. Installed dogfood phrases include:
   - `please rerun the tests and show me the failures` -> cleaned prose.
   - `I just tested it is putting random text` -> capitalized and punctuated.
   - `git status` -> exactly `git status`.
   - `git rebase --interactive HEAD~3` -> command preserved.
8. A warm 8-10 second Ghostty dictation has no HUD-preview decode, no 15-second
   prefix preparation, and materially lower stop-to-insert latency than 0.4.6.

## Out of scope

True cursor-level provisional insertion and revision is a separate project. It
requires reliable cross-application replacement, selection, undo, and cleanup
semantics. It will not be approximated inside the HUD with stale batch previews.
