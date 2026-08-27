# Generic background computer use on macOS (2026-08-27)

## Verdict

There is no single generic Accessibility path that can reliably control every
Mac app without taking the foreground. “Generic” has to mean a
**capability-driven router**: retain an exact process/window target, discover
which semantic transports and verifiers are available for that target, choose
one route, and refuse when no route can prove the requested postcondition.

Do not add five app-name scripts or ask the planner to improvise around a
transport failure. The planner should receive
capabilities such as `media.play`, `ax.perform`, `ax.set_value`, `browser.dom`,
and `window.pointer`, each coupled to a verifier. App-specific protocols remain
behind those generic intent capabilities.

The current failure pattern, launching Calendar or Mail twice, exhausting turns
on Finder, and waiting after Music changed, fits a contract error:
**delivery or process launch is being treated as task completion without a
target-owned postcondition.** More retries, UI-review turns, or planner prose
cannot repair that.

## Evidence boundary

Facts below come from public vendor documentation, upstream source at the pinned
commits, or read-only inspection on this Mac. The proposed Velora architecture
is explicitly marked as inference. OpenAI documents product behavior and a
computer-use loop, but does not publicly document the private macOS actuator
used by Codex/ChatGPT; claims that it uses Cua, SkyLight, or a particular event
route are therefore unsupported.

| Source inspected | Evidence status |
|---|---|
| OpenAI computer-use API and ChatGPT/Codex computer-use documentation | Current primary documentation, checked 2026-08-27 |
| Cua | Source at [`9029514`](https://github.com/trycua/cua/tree/90295148d34dac8e5a1307bac917e08171af5839) |
| Orca | Source at [`026389a`](https://github.com/stablyai/orca/tree/026389a3bc03da03ca2d65295e805493712b0774); installed app 1.4.190 inspected read-only |
| Phonon | Source at [`2d864b9`](https://github.com/Infatoshi/phonon/tree/2d864b918c2a929324f9c92cfb42a37cbd533496) |
| osaurus-macos-use | Source at [`34add4c`](https://github.com/osaurus-ai/osaurus-macos-use/tree/34add4c83f5459e41588e206f155db94c570c0ac) |
| Super Computer Use | Source at [`3fc53ec`](https://github.com/paperfoot/super-computer-use/tree/3fc53ecbe2f6e635d0603de2bc1508bded2c6f6c) |
| Apple framework behavior | Current Apple documentation plus read-only `sdef` discovery on macOS 26.5.2 |

## Verified facts

### OpenAI documents a harness contract

OpenAI's API guide says a computer-use model can work with screenshots,
model-returned UI actions, or a custom harness mixing visual and programmatic
interaction. Its loop is action → execute → capture updated UI → return the new
state, and it recommends isolation plus human confirmation for consequential
actions. [OpenAI computer-use API guide](https://developers.openai.com/api/docs/guides/tools-computer-use)

The ChatGPT/Codex product documentation says macOS computer use needs Screen
Recording and Accessibility, can run a scoped task in the background while the
user keeps working, and should be given an exact app/window/flow. It also says to
prefer a dedicated plugin or MCP integration when one exists, using visual
computer use for the remaining UI surface. [OpenAI computer-use product documentation](https://learn.chatgpt.com/docs/computer-use)

Those documents support three design facts:

1. observation after action is part of the loop;
2. structured and visual routes can coexist;
3. background coexistence is a product requirement.

They do **not** disclose how the native macOS build addresses a hidden window,
posts input, resolves Spaces, or proves a postcondition. Reverse-engineered
third-party claims are not evidence of OpenAI's implementation.

### Public macOS APIs expose several different capability families

| Capability | What the public API gives | What it does not give |
|---|---|---|
| Application identity | `NSRunningApplication` exposes PID, bundle identity, bundle URL, launch date, termination state, and activation. [Apple](https://developer.apple.com/documentation/appkit/nsrunningapplication) | A stable document/window identity across relaunches. Its properties are time-varying, so PID must be paired with launch identity and revalidated. |
| Background launch | `NSWorkspace.OpenConfiguration.activates` can be set false; activation is a separate operation. [Apple](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/activates) | A guarantee that the application creates a window or publishes an Accessibility tree. |
| Foregrounding | `NSRunningApplication.activate(options:)` explicitly activates the app. [Apple](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)) | Background delivery. Calling it is the focus-steal, not a harmless setup step. |
| Accessibility target | `AXUIElementCreateApplication(pid)` scopes an AX root to one process. [Apple](https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication) | Exact window ownership from PID alone, complete trees for every toolkit, or a guarantee that an accepted action changed app state. |
| AX capability discovery | `AXUIElementCopyActionNames`, attribute queries, settable checks, and `AXUIElementPerformAction` expose what a particular element advertises. Calls can return stale/invalid, cannot-complete, or not-implemented errors. [Apple](https://developer.apple.com/documentation/applicationservices/1462053-axuielementcopyactionnames) | One action vocabulary or equivalent behavior across AppKit, SwiftUI, Catalyst, Electron, browsers, canvases, and games. |
| Per-process synthetic input | `CGEvent.postToPid(_:)` accepts a PID. [Apple](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) | A window ID or public promise that the event reaches a particular same-process window/first responder. |
| Window inventory | `CGWindowListOption.optionAll` can include onscreen and offscreen WindowServer windows; `optionOnScreenOnly` is narrower. [Apple](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optionall) | An actionable AX node or proof that an off-Space/minimized window can receive input. |
| Screen capture identity | `SCWindow` carries a window ID, owning application, frame, and onscreen state. [Apple](https://developer.apple.com/documentation/screencapturekit/scwindow) | Semantic state or a delivery channel. A captured change is not automatically the requested task postcondition. |
| Spaces policy | `NSWindow.CollectionBehavior` controls the caller's own windows. [Apple](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) | Public control of another app's arbitrary window across Spaces. |
| Apple Events | Scriptable apps publish app-specific terminology; ScriptingBridge sends Apple Events against that dictionary. Terminology varies by application and may change. [Apple scripting terminology](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AboutScriptingTerminology.html), [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) | A common schema implemented by every app. Automation also requires consent/usage description and, when sandboxed, the appropriate entitlement. [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) |

An Accessibility observer is created for a PID and reports notifications from
that application; it is useful for invalidating a target-local snapshot, not as
a desktop-wide completion oracle. [AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), [AX notification constants](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h)

Passive activity monitoring is possible: a listen-only event tap or global
event monitor can observe user events without modifying them. [CGEventTapOptions](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions), [NSEvent global monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))

### Music controls are a separate semantic domain

`MPRemoteCommandCenter` lets a media app register handlers for remote commands;
it is not a controller for an arbitrary other media app. System media events go
to the current or most recently active Now Playing application, which is not an
exact Music target. [Apple remote-command center](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter), [external player events](https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications)

MusicKit's `ApplicationMusicPlayer` deliberately does not affect the Music
app. Although Apple documents `SystemMusicPlayer` on other platforms, the
current macOS 26.5 SDK marks it unavailable on macOS. MusicKit therefore cannot
be Velora's controller for an existing Music.app session.
[ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer)

A live read-only probe on this Mac found Music itself playing while macOS
MediaRemote named a paused Chrome process as the current Now Playing owner.
That falsifies the assumption that a global play/pause key targets the app the
user named. When the requested player's current window exposes an exact
Play/Pause capability, Cua's PID/window/element background action is the safer
generic route; otherwise Velora must refuse rather than redirect the key.

On this Mac, read-only `sdef` discovery showed that Music exports `play`,
`pause`, `playpause`, `stop`, `current track`, and `player state`. Finder exports
`open`, `make`, and `reveal`; Calendar exposes calendars/events and view/reload
operations; Mail exposes messages, mail checks, and send. This is direct proof
that useful semantic capabilities exist, but in different dictionaries. It is
not permission to invoke arbitrary Apple Events. A generic registry should map
a small audited intent vocabulary onto a discovered, consented capability.

### Cua separates route accounting from task verification

Cua's current contract reports the actuator's effect and route separately from
a caller-defined `verify_state` postcondition. `satisfied` is the only terminal
success; `unknown` cannot become success. A PID-only window action is permitted
only when the process has one eligible top-level window; otherwise the driver
returns `ambiguous_window_target` before input is sent. [Cua action-result contract](https://github.com/trycua/cua/blob/90295148d34dac8e5a1307bac917e08171af5839/libs/cua-driver/docs/action-result-contract.md#L3-L11), [exact window rule](https://github.com/trycua/cua/blob/90295148d34dac8e5a1307bac917e08171af5839/libs/cua-driver/docs/action-result-contract.md#L58-L86)

Its accepted support ledger proves different outcomes by toolkit. On macOS,
AppKit has proven AX background click/value/type paths but several other
combinations remain gaps; SwiftUI's tested popover is absent from targeted AX
enumeration; WKWebView has a different matrix. The ledger counts only fixture
state changes or exact refusals, never API acceptance alone. [Cua support ledger](https://github.com/trycua/cua/blob/90295148d34dac8e5a1307bac917e08171af5839/libs/cua-driver/docs/action-support.md#L1-L15), [macOS toolkit matrix](https://github.com/trycua/cua/blob/90295148d34dac8e5a1307bac917e08171af5839/libs/cua-driver/docs/action-support.md#L62-L68)

Cua also has a detailed background-input design document, but it is labelled a
proposal. It correctly identifies the target as `(pid, windowID)`, refuses
implicit Space switching/foreground activation, treats off-Space state as
observation-limited, and proposes a route ladder with postconditions. Those are
design evidence, not proof that every route is released. [Cua macOS proposal](https://github.com/trycua/cua/blob/90295148d34dac8e5a1307bac917e08171af5839/libs/cua-driver/docs/macos-background-input-v1-plan.md)

### Orca is capability- and snapshot-driven, with honest background limits

Orca's computer-use guide requires a fresh state after UI changes, treats
element indexes as short-lived, prefers bundle ID plus stable window ID, and
separates provider success from verification. It prefers semantic `set-value`
and advertised actions over synthetic typing, whose delivery is explicitly
unverified. [Orca computer-use guide](https://github.com/stablyai/orca/blob/026389a3bc03da03ca2d65295e805493712b0774/skill-guides/computer-use.md#L37-L60), [action rules](https://github.com/stablyai/orca/blob/026389a3bc03da03ca2d65295e805493712b0774/skill-guides/computer-use.md#L95-L109)

Its guide states that background behavior is app-dependent. It exposes
`unsupported_capability`, `action_not_supported`, `window_stale`, and
`element_not_found` instead of retrying the same path indefinitely. Restoring a
window is explicit, not a background default. Spotify gets a specific warning
to refresh after asynchronous playback clicks. [Orca limits and errors](https://github.com/stablyai/orca/blob/026389a3bc03da03ca2d65295e805493712b0774/skill-guides/computer-use.md#L118-L160)

Read-only inspection of installed Orca 1.4.190 on this Mac corroborated the
documented contract: the macOS provider reported explicit window selectors,
`focus: false`, semantic actions, screenshots, and element frames. Music state
was bound to its PID, bundle ID, window ID, and snapshot, but the AX tree exposed
several “Play” controls and unlabeled player buttons. A rich tree still did not
uniquely encode the intent “resume current music.” No action was issued.

### Phonon captures a target early but still uses foreground-global paste

Phonon records the current frontmost `NSRunningApplication` when dictation
starts. At insertion it copies text to the global pasteboard, reactivates the
captured app only if Phonon itself is currently frontmost, then posts Command-V
to the global HID event tap. [Target capture](https://github.com/Infatoshi/phonon/blob/2d864b918c2a929324f9c92cfb42a37cbd533496/bar/Sources/PhononBar.swift#L1957-L1979), [paste route](https://github.com/Infatoshi/phonon/blob/2d864b918c2a929324f9c92cfb42a37cbd533496/bar/Sources/PhononBar.swift#L1144-L1189)

The transferable idea is early target capture. The source does **not** provide
a background Action Mode implementation: the eventual paste is global, has no
window identity, and has no insertion postcondition. Source-level inference:
if the user changes apps while processing and Phonon is not frontmost, the paste
can follow the current foreground receiver rather than the recorded target. Its
local one-shot OCR context is useful for dictation, but not a delivery proof.
[Phonon OCR/privacy description](https://github.com/Infatoshi/phonon/blob/2d864b918c2a929324f9c92cfb42a37cbd533496/README.md#L127-L149)

### Other open-source agents independently converge on routing and readback

osaurus-macos-use reports which route it used and classifies Chromium separately
from Cocoa. Its ladder is private SkyLight → public per-PID events → global HID,
and it says the last route warps the user's cursor. It also documents that
Chromium drops the public per-PID path. [route telemetry and app classes](https://github.com/osaurus-ai/osaurus-macos-use/blob/34add4c83f5459e41588e206f155db94c570c0ac/Sources/osaurus_macos_use/BackgroundDriver.swift#L6-L100), [route ladder](https://github.com/osaurus-ai/osaurus-macos-use/blob/34add4c83f5459e41588e206f155db94c570c0ac/Sources/osaurus_macos_use/BackgroundDriver.swift#L102-L210)

Super Computer Use compares before/after state because an AX call can report
success without an effect. It uses a closed allowlist of activation-like AX
actions, refuses click-then-type as a background `setValue` fallback, and notes
that responder-level shortcuts can disappear in a background app. It also
distinguishes a running app with no window from an Accessibility permission
failure. [semantic actions and input limits](https://github.com/paperfoot/super-computer-use/blob/3fc53ecbe2f6e635d0603de2bc1508bded2c6f6c/src/actions.swift#L1-L129), [post-action observation](https://github.com/paperfoot/super-computer-use/blob/3fc53ecbe2f6e635d0603de2bc1508bded2c6f6c/src/commands.swift#L103-L143), [empty-tree diagnosis](https://github.com/paperfoot/super-computer-use/blob/3fc53ecbe2f6e635d0603de2bc1508bded2c6f6c/src/commands.swift#L185-L224)

Both projects contain undocumented/private event mechanisms. They are useful
evidence that route telemetry and toolkit classification matter, not a basis for
calling those transports stable or App Store-safe. Global HID is incompatible
with Velora's background coexistence requirement.

### A narrow off-Space AX prime works on this Mac

A live probe on macOS 26.5.2 found one bounded exception to the public-API
limits above. Fresh Calculator, Calendar, and Dictionary windows on another
Space sometimes remained present in WindowServer while Cua returned
`degraded_reason=ax_window_unresolved`. Posting one SkyLight focus record to the
exact PID/window made the AX tree readable; posting the paired defocus record
removed the private focus state. The public foreground app and cursor stayed
unchanged across 50 samples, and a Cua semantic click then changed Calculator's
exact AX state without global input.

This is an undocumented compatibility route, not general background input. It
is safe enough to attempt only when the target PID generation, window ID,
title, bounds, off-Space state, foreground lease, cursor lease, Accessibility,
screen lock, and physical-input ledger are all current. It runs once, accepts
only an unrelated foreground change such as Telegram, always posts defocus,
and refuses on target or unattributed input. A stale app that still exposes no
AX tree after the prime needs a restart; Velora must not quit it automatically.

## The universal-AX hypothesis is falsified

Hypothesis: “Given an app PID and AX permission, the same semantic AX path can
complete any basic action in any Mac app without taking foreground.”

| Falsifying observation | Consequence |
|---|---|
| Apple's AX API discovers per-element actions and explicitly permits `notImplemented`/`cannotComplete`; it defines no cross-app semantic equivalence. | Capability discovery must occur on the current element/window. |
| Cua's accepted macOS ledger has different AppKit, SwiftUI, WKWebView, and Electron results; a SwiftUI popover can be missing from target AX enumeration. | Toolkit and surface type change the available route. |
| Orca documents app-dependent background actions, stale element refs, unverified synthetic input, and browser-specific focus behavior. | One successful provider call is neither portable nor proof of effect. |
| `CGEvent.postToPid` has no window parameter; responder actions depend on app focus state. | PID-scoped keyboard input cannot prove delivery to an exact same-process window. |
| Music's AX tree can expose several indistinguishable play controls, while MusicKit/Apple Events expose playback state. | A domain semantic adapter is safer and more precise than choosing a label. |
| Finder is normally already running and may have no requested window; Notes/Calendar can be running with zero AX windows after background launch. | “Process exists” cannot verify “open the app/window.” |
| Canvas/game/custom-rendered surfaces may expose no meaningful AX nodes. | Some background requests have no safe host-session route and must refuse or use an isolated environment. |

The hypothesis is false. A single AX path can remain a useful rung, not the
architecture.

## Proposed Velora contract — engineering inference

This section is a recommendation derived from the facts above, not an upstream
claim.

```text
intent
  -> discover capabilities
  -> acquire exact target lease
  -> select one actuator
  -> execute once
  -> verify target-owned postcondition
  -> receipt or typed refusal
```

### 1. Bind an immutable target lease

Use a target value equivalent to:

```text
TargetLease {
  bundleID, pid, processLaunchIdentity,
  cgWindowID, axWindowIdentity,
  snapshotGeneration
}
```

Before each mutation, revalidate process launch identity, WindowServer owner,
AX window ancestry, and snapshot generation. PID-only execution is allowed only
when exactly one eligible window exists. A stale lease causes one re-observation,
not a blind retry.

### 2. Discover capabilities; do not hardcode five UI recipes

Expose a current capability report to the planner:

```text
structured.media       available | unavailable | unknown
structured.appleEvent  available | permission_required | unavailable
ax.semantic            actions + settable attributes
browser.dom             exact page target | unavailable
window.pointer          exact target + verifier | unavailable
pid.keyboard            singleton target + readback | unavailable
observation             ax | pixels | structured state
visibility              visible | hidden | minimized | off_space | unknown
```

`available` means executable **and verifiable now**, not “the API accepted this
once.” Discovery can cache static bundle/toolkit traits, but permission, window,
element, and verifier state must be fresh.

Map a small intent vocabulary onto the best current capability:

1. dedicated OS/app semantics for the actual intent when a public API controls
   and verifies the exact requested session;
2. exact AX action or value write on an element descended from the leased AX
   window;
3. exact browser page/DOM target;
4. exact window-local pointer route only with route evidence and an exact effect
   verifier;
5. per-PID keyboard only for a singleton window, a known receiver, and readable
   post-state;
6. typed refusal.

Do not internally “try every route.” One selected route, one bounded verifier,
then the planner receives the new capability/state facts. Repeating the same
`capability + target + action + unchanged post-state` fingerprint should stop
and return `background_unavailable` or `effect_unknown`, not consume eight
review turns.

### 3. Keep action accounting separate from task completion

Use two closed results:

```text
ActionEffect = confirmed | partial | unverifiable | suspected_noop | refused
Postcondition = satisfied | unsatisfied | unknown
```

Only `Postcondition.satisfied` completes the task. Examples:

| User intent | Required postcondition |
|---|---|
| Open Calendar/Mail/Notes | A newly resolved exact target window exists and matches the requested app/context; process launch alone fails. |
| Open/reveal in Finder | The requested item/window is represented by a new exact Finder state; Finder's persistent process is irrelevant. |
| Play music | Exact media provider reports `playing`; when a track was requested, current item also matches. An AX button press or changing screenshot is insufficient. |
| Type a draft | The exact leased field's value/readback contains the intended draft. |
| Click a control | A named target-state predicate changes; `AXUIElementPerformAction == success` alone is unverifiable. |

### 4. Hidden, minimized, and off-Space policy

- Launch with `activates = false`. Never call `activate` as hidden setup.
- Inventory offscreen windows for identity, but do not infer they are actionable.
- Hidden/off-Space work is permitted only through a structured semantic route or
  an exact AX route when the leased window still exists in AX and the effect is
  readable.
- An `ax_window_unresolved` target may receive one bounded exact-window AX prime
  under the lease above. This does not switch Spaces, activate or raise the app,
  move the cursor, or grant raw input. Every other degraded reason refuses.
- Raw pointer and keyboard routes remain unavailable for an off-Space or
  unresolved target.
- If background launch yields no window, use a discovered semantic “new/open
  window” capability or return `requires_foreground`. “App is running” is not
  completion.
- The completion notification can offer an explicit user click to activate the
  exact app/window. Revalidate the lease before activation. The action itself
  does not bring Velora or the target forward.

### 5. Coexist with current user activity

Telegram use should not block an unrelated Music, Calendar, or Finder action.
The conflict unit is the **target lease**, not the whole desktop:

- passively observe physical input and frontmost/focused-window changes;
- serialize mutations per target PID/window, not globally;
- continue when the user is active in another PID/window and the chosen route is
  non-global;
- if user activity or an AX notification changes the same leased target, discard
  the snapshot and re-observe or pause;
- never restore the foreground app captured at action start; the user may have
  moved on deliberately;
- forbid global HID, cursor warp, and implicit clipboard paste in background
  mode;
- distinguish Velora-generated events from physical activity where the API
  permits tagging, so the agent does not invalidate its own lease.

This makes “user is typing in Telegram” benign while “user is editing the same
Mail compose window” becomes a real conflict.

### 6. Planner vocabulary should express intent and proof

The planner should ask for generic semantic operations, not select transports:

```text
ensure_app_window(app, context, postcondition)
media_play(provider?, item?, postcondition)
media_pause(provider?, postcondition)
invoke_semantic(capability, target, postcondition)
ax_perform(targetLease, element, advertisedAction, postcondition)
ax_set_value(targetLease, element, value, postcondition)
```

The host returns the capabilities and exact refusal. A missing capability is not
`planner_unavailable`, and an actuator's unverifiable result is not
`plan_invalid`. This is a transport/evidence fact.

## Smallest useful implementation sequence

1. Repair the completion contract first: exact target lease, separate action
   effect/postcondition, `unknown` never done, identical no-effect fingerprint
   stops.
2. Feed the planner a runtime capability report instead of expanding prompt
   heuristics or retries.
3. Bind `media.play/pause` to one exact current UI capability and verify the
   acquired target PID's Core Audio output. A future public semantic adapter is
   eligible only when it controls and verifies that same named target.
4. Add generic SDEF discovery for diagnostics/capability registration, but map
   only an audited closed intent vocabulary. Do not let the planner emit raw
   AppleScript or arbitrary dictionary commands.
5. Keep Cua as an actuator/verifier provider where its current capability report
   proves the target route. Do not assume AX merely because Cua is installed.
6. Show a completion/failure HUD without activation. A user click may open the
   exact result app/window after lease revalidation.

The capability/evidence contract is the necessary deterministic boundary. It
does not require an accumulating layer of app-specific behavior.

## Five-app acceptance gate

Run this against the signed installed build while another app remains in active
use. Each case records initial foreground PID/window, target lease, chosen route,
action effect, postcondition, final foreground PID/window, cursor position, and
any physical-input generation changes.

| App/intent | Pass condition | Expected route class |
|---|---|---|
| Music: play/resume, then pause | Exact target PID output reaches playing/paused; user's foreground and cursor never move. | Exact Cua UI capability plus target-owned Core Audio readback |
| Calendar: open/show requested calendar | Exact Calendar window/context exists; process-only launch does not pass. | Apple Event or exact AX semantic route |
| Mail: open inbox without sending | Exact Mail window/context exists; no draft/send mutation; no activation. | Apple Event or exact AX semantic route |
| Finder: reveal a temporary non-sensitive test file | Exact revealed item/window state is observable; persistent Finder process does not pass. | Finder Apple Event, with AX observation where useful |
| TextEdit: write to a uniquely named test document | Exact window and text receiver are leased; exact value readback matches; a second same-process window causes refusal unless explicitly selected. | Exact AX set-value/type route |

Add negative cases: hidden target, minimized target, off-Space target,
same-target user activity, unrelated Telegram activity, two same-app windows,
screen lock, stale PID after relaunch, missing Apple Events consent, and an AX
call that returns success with unchanged state. Any focus/cursor change,
wrong-window mutation, `unknown` promoted to success, or duplicate launch is a
failure.

## Decision

Do not add more planner retries or treat “reviewer could not plan” as the root
cause. Implement one exact-target, capability, and postcondition contract; use
semantic OS/app routes where they exist; keep AX as one discovered rung; and
refuse when the current target has no verifiable background route. That is the
generic solution supported by OpenAI's harness model, Apple's public API
boundaries, Cua's evidence contract, and the independent behavior documented by
Orca and other open-source agents.
