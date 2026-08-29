# Action Mode findings and release gate (2026-08-29)

## Verdict

The installed, signed candidate passed background app-open readiness for
TextEdit, Notes, Calculator, Finder, and System Settings without changing the
foreground app. That is not proof that arbitrary mutation or navigation works
in those apps. Velora routes each requested effect through a verified
capability and refuses when it cannot prove the result. Cua is a read-only
observer. Public Accessibility performs exact native UI actions, and Music uses
its own Apple Events playback suite.

Music did not pass its playback acceptance test because the app had no current
or queued track. Velora returned an unavailable-state failure without falling
back to global input. A real play/pause acceptance check still needs a
user-chosen track.

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
7. Show progress and the result in Velora's nonactivating HUD. Automatic work
   stays in the background; clicking the completion card may bring the verified
   target forward.

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

Velora can press or set the value of an exact retained native element in a
background window. A stopped or windowless app gets one bounded native launch
attempt through `NSWorkspace.OpenConfiguration` with activation, recent-items,
and user-prompting disabled. Cua observes the exact PID and window only after
that native materialization; it does not launch or focus the app.

The launch begins with a provisional focus lease. Velora checks it immediately,
while waiting for a target window, on failure, and during teardown. If the app
activates itself, Velora restores the exact window the user was using. If the
user selects another window meanwhile, that newer selection wins. Ambiguous
input fails closed, and the native launcher cannot run on the main thread.

Before and after every mutation Velora rechecks the process, window, element,
and user-input lease. The native inactive launch contract avoids keyboard-focus
theft, but it cannot guarantee that every app creates a visually hidden or
off-Space window.

Controls with a readable state transition use that same-control readback.
Noncommitting navigation may use one fresh complete-tree delta, bound to one
mutation and consumed once. An unchanged or incomplete tree ends the action
without retry.

Generic presses reject committing, lifecycle, playback, toggle, recording,
and connectivity labels before review or AX mutation. Those state changes need
a separate semantic capability with their own readback.

This route still depends on the target app exposing a complete, stable AX tree.
Browser DOMs, custom canvases, hidden controls, and some SwiftUI surfaces can
remain unavailable. See
[NSWorkspace.OpenConfiguration](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)
and Apple's
[`openApplication` contract](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication%28at%3Aconfiguration%3Acompletionhandler%3A%29?changes=_2).

### The planner had three concrete failure modes

- An exact app-only request could enter a redundant planner turn after the
  runtime had already proved the requested app and pinned window. App-only
  intents now finish from that fresh local route proof. In-app requests still
  require a fresh follow-up and their own postcondition. One empty response may
  get one recovery call; invalid or non-progress work cannot extend that budget.
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
unavailable`. A read-only AppleScript query also failed to obtain the current
track with error `-1728`. The correct runtime result is refusal. A valid
acceptance test needs one user-chosen queued track, followed immediately by a
verified pause cleanup.

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

Pre-commit local candidate build 283 was signed and ran from
`/Applications/Velora.app`. Each scripted action recorded
`com.cmuxterm.app` as the foreground app before and after execution. These are
bounded before/after observations, not a continuous foreground trace. No test
used send permission. App-open readiness proves exact launch and target-window
ownership only; it does not prove arbitrary mutation or navigation inside the
app.

| Surface | Result | Evidence |
|---|---|---|
| HUD | Passed after normal background relaunch | Visible bottom-right failure card in `/tmp/velora-final-hud.png`; hidden `open -j` launch removed |
| Voice/history safety | Passed before final reinstall | 590 retained audio files; aggregate digest `e32abc5840b0501c1da4dff9392d6f5809d9c7ed6fb9ba6d272c714da27b0d49` |
| TextEdit | Passed app-open readiness | `open_app TextEdit`; exact target ready; foreground unchanged |
| Notes | Passed app-open readiness | `open_app Notes`; exact target ready; foreground unchanged |
| Calculator | Passed app-open readiness | `open_app Calculator`; exact target ready; foreground unchanged |
| Finder | Passed app-open readiness | `open_app Finder`; exact target ready; foreground unchanged |
| System Settings | Passed app-open readiness | `open_app System Settings`; exact target ready; foreground unchanged |
| Music | Failed safely; fixture missing | `open_app Music -> wait_frontmost Music -> media_control play: unavailable`; no AX, key, or text fallback ran |

The five app-open ledgers prove exact target readiness, not in-app effects or
continuous focus preservation. Manual checks observed no focus steal. The
runtime is designed to preserve Telegram, cmux, or another foreground app. If
the user deliberately selects the exact target window, Velora cancels its focus
restoration instead of fighting that choice.

## Release gate

Do not publish a GitHub release or Homebrew update from source tests alone. A
candidate is ready only after all of these pass on the installed signed app:

1. Full `make test`, plus the permission-gated checks required by the touched
   surfaces.
2. Exact installed binary/source parity. A public DMG must also pass Developer
   ID signature, notarization, stapling, and Gatekeeper verification.
3. HUD visible after a normal nonactivating relaunch.
4. TextEdit, System Settings, Calculator, Notes, and Finder complete the
   intended mutation or navigation with exact receipts while the foreground
   window stays unchanged. App-open readiness alone does not satisfy this gate.
5. Music play and pause complete against a queued track with exact playback
   readback.
6. No Cua mutation call, send receipt, foreground notification, stale target,
   or voice/history digest change.
7. Git branch SHA, installed binary SHA, and any public release/tap SHA are
   reported separately. A pushed branch is not a published release.

Until that matrix passes, the accurate product statement is: Action Mode passes
background app-open readiness across the five tested apps, can perform verified
actions on compatible native surfaces, preserves the user's foreground work in
the tested flows, and refuses unsupported or unverified requests.
