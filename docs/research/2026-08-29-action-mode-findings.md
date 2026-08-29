# Action Mode findings and release gate (2026-08-29)

## Verdict

Action Mode can operate an already-open Mac app without taking the user's
foreground window, but it cannot safely automate every app through one generic
input path. Velora now routes by verified capability and refuses when it cannot
prove the requested result. Cua is a read-only observer. Public Accessibility
performs exact native UI actions, and Music uses its own Apple Events playback
suite.

The pending source closes the planner and target-ownership defects found in
this round. It does not yet justify a claim that the five-app live matrix has
passed. Build 281 produced honest failures in System Settings, Calculator,
Finder, and Music. Those results are recorded below and must not be described as
successful automation.

## Product contract

1. Keep the user's app, window, cursor, and keyboard focus unchanged during
   automatic execution.
2. Bind every action to one process generation and one window ID. Never retarget
   to another window because the original target disappeared.
3. Use a fresh, complete native Accessibility snapshot before an AX mutation.
   Partial, visual, degraded, stale, or replayed observations are read-only.
4. Treat an accepted API call as delivery evidence, not task completion.
   Completion needs target-owned state readback.
5. Stop on target activity, user activity, stale lineage, ambiguity, or missing
   proof. Do not hide a transport failure with more planner turns.
6. Never send a message without the separate send permission. A draft and a
   send remain different operations.
7. Show progress and the result in Velora's nonactivating HUD. Open the target
   app only after the user clicks the completion card.

## What the investigation established

### One universal macOS actuator does not exist

macOS exposes several different capability families: process identity,
WindowServer inventory, Accessibility actions, per-PID events, Apple Events,
and app-specific APIs. None supplies a stable, verified action vocabulary for
AppKit, SwiftUI, Electron, browsers, custom canvases, and media players.

The generic design uses a capability router:

```text
spoken intent
    |
exact app process + window
    |
fresh capabilities -----------------------+
    |                                     |
native AX action + readback        app-native semantic action
    |                                     |
fresh exact observation             app-owned state readback
    +------------------+------------------+
                       |
               verified / refused
```

Global HID input is excluded from background Action Mode. It targets the
foreground responder and would interfere with whatever the user is doing.
Undocumented SkyLight input is also excluded from automatic execution. The
bounded off-Space probe was useful research, but it is not a stable product
contract.

The source and API evidence is in
[`2026-08-27-action-mode-generic-computer-use.md`](2026-08-27-action-mode-generic-computer-use.md).

### Cua is observation-only

Cua supplies window inventory, screenshots, and bounded UI observations. It no
longer clicks, types, presses keys, launches apps, or brings a target forward
during automatic execution. This avoids the stale-focus restoration failure
found in its input path and keeps mutation authority inside Velora.

A routed action now retains the target PID generation, bundle ID, window ID,
snapshot lineage, native AX element, and user-input generation. Replayed,
missing, oversized, or exhausted snapshot IDs poison the session. Later
readiness or media capabilities cannot revive it.

### Native Accessibility is exact but capability-limited

Velora can press or set the value of an exact retained native element in an
already-open background window. Before and after every mutation it rechecks the
process, window, element, and user-input lease. If the target app activates
itself, Velora restores the exact window the user was using. A concurrent user
switch wins.

Controls with a readable state transition use that same-control readback.
Noncommitting navigation may use one fresh complete-tree delta, bound to one
mutation and consumed once. An unchanged or incomplete tree ends the action
without retry.

Generic presses reject committing, lifecycle, playback, toggle, recording,
and connectivity labels before review or AX mutation. Those state changes need
a separate semantic capability with their own readback.

This route still depends on the target app exposing a complete, stable AX tree.
Browser DOMs, custom canvases, hidden controls, and some SwiftUI surfaces can
remain unavailable.

### The planner had three concrete failure modes

- An app-only `open_app` could be accepted as completion for an in-app request.
  The loop now asks for a fresh follow-up. One empty response may get one
  recovery call; invalid or non-progress work cannot extend that budget.
- An invalid nonempty batch could reset the empty-follow-up budget. It no
  longer does.
- Polite requests such as “I'd like to open…” could miss presentation-intent
  classification. The direct forms now classify with the existing bounded
  prefix grammar.

Media commands also fail closed outside `media_control`. A planner cannot turn
“pause Spotify” into a key, text, or generic press against Music, even if its
checkpoint names the wrong app.

### Music is a separate semantic capability

Music play and pause use Music's published Apple Events playback suite, target
the exact running PID, and require Automation consent. Completion is checked
against playback state. A global media key is not used because macOS can route
it to another Now Playing owner.

The 2026-08-29 live Music probe failed with `the target app's media state is
unavailable`. A manual read-only query then showed Music was `stopped` and had
no current track; that second observation was not retained in the ledger. The
correct runtime result is refusal. A valid acceptance test needs one
user-chosen queued track, followed immediately by a verified pause cleanup.

### The missing HUD was a hidden-launch incident

The HUD panel and SwiftUI content were both alive. WindowServer listed a
480-by-160 Velora window at the configured bottom-right position, and a direct
window capture showed the expected capsule. The same window was absent from the
active Space and from a full-display screenshot.

The installed app had been started with `open -j`, which asks Launch Services
to launch it hidden. Quitting and reopening it with a normal background launch
made the existing HUD window onscreen:

- `kCGWindowIsOnscreen = 1`;
- the bottom-right capsule was visible in a full-display capture;
- Orca remained frontmost before and after;
- Velora stayed an `LSUIElement` app with no Dock activation.

No HUD source change was needed. Velora's update helper already relaunches with
plain `open`; the fault came from the manual install command. Local installs and
tests must not use the hidden-launch flag.

Apple documents `orderFrontRegardless()` as ordering a window without making it
key or main, while Space membership is controlled separately by
`NSWindow.CollectionBehavior`. See
[Apple's window ordering contract](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless%28%29)
and [Space collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct).

### Phonon does not solve Action Mode

Phonon captures the frontmost app early, but its final insertion uses the
global pasteboard and Command-V. It has no cross-app planner, exact window
ownership, background verifier, or Action Mode equivalent. Its GPL-3.0 source
must not be copied into MIT-licensed Velora.

Its useful ideas are narrower:

- benchmark instance-scoped MLX detokenizer reuse;
- pin exact model revisions;
- retain an opt-in intended-transcript field and phase timings;
- benchmark its exact Gemma 4 E2B model before considering a model change.

Velora should keep Whisper Large v3 Turbo and Qwen3.5-4B-MLX-8bit until a
candidate passes the existing multilingual, Romanization, latency, memory,
saved-audio, and Action-safety gates. The full competitor audit is in
[`phonon-2026-08-26.md`](phonon-2026-08-26.md).

## Live acceptance evidence

Build 281 was signed and ran from `/Applications/Velora.app`, but it predates
the pending source changes and is baseline evidence only. Manual before/after
checks found the user's app still frontmost during the safe probes; no
continuous foreground-monitor artifact was retained. No test used send
permission.

| Surface | Result | Evidence |
|---|---|---|
| HUD | Passed after normal background relaunch | Onscreen WindowServer entry, visible full-display capture, unchanged Orca foreground |
| Voice/history safety | Passed | 590 retained audio files; aggregate digest unchanged at `e32abc5840b0501c1da4dff9392d6f5809d9c7ed6fb9ba6d272c714da27b0d49` |
| TextEdit | Failed | The last run could not resolve the already-open target and made no text mutation |
| Notes | Failed | The ledger recorded a target-resolution failure; no note mutation was accepted |
| System Settings | Failed | The planner could not prove the active About destination |
| Calculator | Unverified | Opening Calculator was recorded; pressing `7` was not proven |
| Finder | Failed | Downloads was not found and the proposed fallback chord was rejected |
| Music | Failed safely | Exact app-native media control returned unavailable; no AX, key, or text fallback ran |

The ledger proves missing capability or postcondition failures, not continuous
focus preservation. Manual checks observed no focus steal. The runtime is
designed to ignore Telegram, Orca, or another foreground app unless the user
interacts with the exact target window.

## Release gate

Do not publish a GitHub release or Homebrew update from source tests alone. A
candidate is ready only after all of these pass on the installed signed app:

1. Full `make test`, plus the permission-gated checks required by the touched
   surfaces.
2. Exact installed binary/source parity. A public DMG must also pass Developer
   ID signature, notarization, stapling, and Gatekeeper verification.
3. HUD visible after a normal nonactivating relaunch.
4. TextEdit, System Settings, Calculator, Notes, and Finder complete with exact
   mutation or navigation receipts while the foreground window stays unchanged.
5. Music play and pause complete against a queued track with exact playback
   readback.
6. No Cua mutation call, send receipt, foreground notification, stale target,
   or voice/history digest change.
7. Git branch SHA, installed binary SHA, and any public release/tap SHA are
   reported separately. A pushed branch is not a published release.

Until that matrix passes, the accurate product statement is: Action Mode can
perform verified background actions on compatible already-open native
surfaces, is designed to preserve the user's foreground work, and refuses
unsupported or unverified requests.
