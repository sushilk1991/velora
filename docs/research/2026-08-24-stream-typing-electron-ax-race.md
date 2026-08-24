# Stream Typing died in every Electron app — an asynchronous Accessibility race

**Date:** 2026-08-24 · **Found in:** 0.18.0 (present well before it) · **Fixed in:** the
`ScreenContext.settle` round.

## The report

> "I don't think the streaming mode is working... Previously it used to work at
> least the streaming typing. But currently it didn't work. I think it posted
> one thing and then it was gone."

## What the logs showed

Two real Stream Typing sessions in Hermes (`com.nousresearch.hermes`, an
Electron app), 29 s and 28 s of audio. The engine was healthy for both:

```
13:22:04 session 974077F5 started (bundle_id=com.nousresearch.hermes mode=None)
13:22:16 cleanup inference output_tokens=15      <- partial 1
13:22:26 cleanup inference output_tokens=33      <- partial 2
13:22:36 session done: stt_ms=922 cleanup_applied=True total_ms=2141
```

STT ran, cleanup ran, the polished final was recorded in `history.sqlite3`
(184 chars). Nothing reached the document.

The app log said nothing at all between `stream hotkey up` and the next event,
because **`StreamTypingSession.swift` contained zero log statements**. The
entire path was silent, which is why the failure was invisible for so long.

The decisive evidence was the user's own composer, still holding `" another"` —
the first partial of the second dictation, and nothing else. One thing posted;
the rest gone.

## Reproduction

`--stream-e2e` (new, see docs/TESTING.md) feeds a scripted partial sequence
through the real `StreamTypingSession` against a real window. Against a
disposable Chrome textarea:

```
partial 1: rendered=true ownsDraft=true  selRange=(20,0) field="Just testing whether"
partial 2: rendered=true ownsDraft=false selRange=(0,20)  own=[caret at (0,20), expected (31,0)]
partial 3..final: unchanged, finish=ownershipLost
```

TextEdit passed the identical script. The split is native AppKit vs Chromium,
not Velora vs the world.

## Root cause

Chromium — and therefore every Electron app — applies an
`AXSelectedTextRange` write in the renderer process and acknowledges it
asynchronously. `ScreenContext.selectStreamDraft` did:

1. `streamOwnsDraft(draft)` — passes, caret at (20,0);
2. `AXUIElementSetAttributeValue(..., kAXSelectedTextRange, (0,20))` — returns
   `.success`;
3. re-read the range immediately — **still (20,0)**, the pre-write value.

Step 3 read "not yet" as "not true". The session concluded it had lost the
draft, abandoned itself, and every later partial returned early on
`plan.isAbandoned`. `finish()` then returned `.ownershipLost`, whose handler
shows "Cursor changed — final copied" and never inserts.

The selection landed a few milliseconds later, after Velora had given up — so
the draft sat **highlighted** in the user's field, one keystroke from deletion.
That is the "and then it was gone" half of the report.

Two aggravating factors made it invisible: the whole path was unlogged, and the
only live regression gate (`VELORA_STREAM_TYPING_E2E`) tested TextEdit, whose
AX is synchronous.

## The fix

`ScreenContext.settle(until:)` polls for the **exact** expected state, 0.4 s
budget, 10 ms interval, returning on the first match. Applied to
`selectStreamDraft`'s post-write verification and to the post-typing
`streamOwnsDraft` check.

This cannot loosen the safety property. Only the exact expected range and text
ever return true, and a timeout still fails closed; the wait only stops
counting latency as loss.

`collapseStreamDraftSelection` puts the caret back when a revision is abandoned
after Velora selected the draft — and only when the current selection is
exactly the range Velora set, so it can never disturb a selection the user
made.

## Verified

| Target | Engine | Before | After |
|---|---|---|---|
| TextEdit | AppKit | PASS | PASS |
| Google Chrome (textarea) | Chromium | FAIL after partial 1 | PASS |
| Hermes | Electron | FAIL after partial 1 | PASS (`--revert` restored the field) |

Plus `--selftest` 1836 checks and the live TextEdit gate.

## What to take from this

- **An AX write is not readable back on the next line.** Any read-after-write
  verification against a non-AppKit target needs a settle, not a single read.
  The same pattern already existed in `ActionExecutor.verifyContext` and its
  comment says exactly this — Stream Typing never got it.
- **A silent path is an unfixable path.** The first real diagnostic step was
  adding the logging that should have been there.
- **A gate that tests one app tests one app.** TextEdit's synchronous AX made
  the suite green while the feature was broken everywhere users actually type.
