# Cua Driver audit → background Action Mode (2026-08-23, superseded)

> Correction, 2026-08-28: this document records the original 0.21.0 audit and
> is not the current Velora design. A source audit of Cua 0.22.2 found that
> `type_text` constructs focus-restoration guards before it reads
> `_skip_window_change_detection`. A user switching to Telegram during the call
> can therefore be returned to the stale foreground app. The wire request also
> uses `args`, not `arguments`. Velora now uses Cua only for read-only window
> observation and verification. Automatic clicks, structured text writes, and
> media controls use public macOS Accessibility or app-native APIs. Window-only
> text uses a retained exact Accessibility element with compare-and-set and
> value readback. Incomplete or screenshot-only trees stay read-only. Cua no
> longer clicks, types, presses keys, launches apps, or changes
> focus during automatic execution. Cold targets without an open window are
> refused. The historical findings below remain for provenance.

Goal: judge whether the user-installed [Cua Driver](https://cua.ai/cua-driver)
(`com.trycua.driver`, v0.21.0) makes Action Mode more powerful — specifically
whether actions can drive other apps **without taking over the user's screen,
cursor, or keyboard** — and integrate it if so.

Verdict: **yes, integrated as an opt-out background execution path.** The
driver delivers clicks and text to a *chosen window* of a *chosen pid* with
no cursor movement and no focus steal — verified live on this machine before
a line of integration code was written. It is not a VM: the agent works on
the real apps in the real session, in windows the user is not using. Codex
Cloud-style duplication is a different (heavier) product; the driver's own
macOS-VM sibling (`lume`) is separate and not what the user installed.

## What was verified live (macOS 26, driver 0.21.0)

Every claim below was exercised against the daemon on this Mac, not read
from marketing.

- **Install**: signed Developer ID (`Cua AI, Inc.`, team YCK386LBJ7),
  notarized, MIT-licensed. Entitlements: apple-events, screen-capture.
  `LSUIElement` menubar-less daemon app + CLI symlink at
  `~/.local/bin/cua-driver`.
- **Transport**: unix socket `~/Library/Caches/cua-driver/cua-driver.sock`,
  newline-delimited JSON `{"method":"call","name":<tool>,"arguments":{…}}` →
  MCP-shaped `{"ok":true,"result":{structuredContent:…}}`. Sub-millisecond
  per call. (The `cua-driver call` CLI adds ~2.7 s of process startup per
  invocation — the socket is the only sane integration path.)
- **Background launch**: `launch_app` starts an app WITHOUT fronting it
  (`self_activation_suppressed: true`).
- **Background click**: two AX clicks on a **hidden** Calculator window
  produced "78" on its display, confirmed by pixel capture of the hidden
  window. No cursor movement, no focus change.
- **Background typing**: `type_text` into a background TextEdit document
  inserted text via `AXSelectedText` and the driver *verified it by value
  readback* (`effect: "confirmed"`). Independently confirmed by re-reading
  the window's AX tree.
- **Honest refusals everywhere**: off-Space/unresolved AX surfaces refuse
  background input with `ax_window_unresolved` ("events could reach a
  same-process sibling window") instead of misgrounding; `press_key` with an
  ambiguous window refuses with candidates; killing a pid the session didn't
  launch refuses (`foreign_process_termination_denied`); open/save panels
  are correctly identified as belonging to the XPC panel service.
- **The AX-materialization gotcha** (cost the first live QA run): an app
  that has *never been activated since launch* — cold-launched in the
  background OR opened earlier with `open -g` — has CGWindows but **zero
  AXWindows**. One brief activation materializes the tree permanently
  (Calculator: 0 elements → 67 after one `bring_to_front`). Velora handles
  this with at most one front-materialize-hide flash per action.
- **Wrong-window typing hazard** (caught in QA design): `type_text` without
  an element token targets the **pid's focused element**, which can live in
  a different window of the same app (TextEdit with three documents open).
  Velora therefore always addresses the target window's own text element by
  token.
- **Web content is honestly unverifiable**: the driver refuses to trust
  AXValue readback under an AXWebArea (Electron echo-confirms), returns
  `effect:"unverifiable"`, and recommends escalation. This matches Velora's
  own finding that browser/Electron AX is not an evidence chain.

## How the driver actually delivers input (documented mechanism)

From Cua's own engineering write-up (`cua.ai/blog/inside-macos-window-internals`),
corroborating what the live probes showed:

- **Keyboard**: public `CGEvent.postToPid` — "Keystrokes scoped to a specific
  pid land in that app's event queue and nowhere else." This is why the
  user's physical keyboard is untouched.
- **Mouse/click**: the PRIVATE SkyLight `SLEventPostToPid`, because
  `CGEvent.postToPid` drops clicks into the shared HID stream that Chrome's
  renderer filters. **Private API = the fragile part**; Velora's integration
  never depends on it (Velora uses only the AX element path plus `press_key`).
- **AX element path** (what Velora uses): drives AX actions directly — no
  pixels, no focus — and works on occluded, backgrounded, minimized, and
  off-Space windows.
- **Documented limits worth knowing**: canvas apps and games refuse
  background input entirely (they accept only `cghidEventTap` events);
  Chromium pixel right-click is filtered; minimized windows can't take
  Return/Space/Tab because AX focus is not renderer focus; Safari and Firefox
  get no browser-mutation tools at all. Velora's scope (native document apps,
  AX path, no games, browsers excluded) sits inside every one of these.

## Caveats that shaped the integration

- **Telemetry defaults ON**: content-free events to PostHog EU keyed by a
  pseudonymous install UUID (never text, prompts, screenshots, AX trees,
  window titles, or app names; client IP discarded after country lookup),
  plus a GitHub Releases update ping cached 20 h. Those are the only
  documented outbound calls. It still conflicts with Velora's
  nothing-leaves-the-Mac stance, so the release notes point at
  `cua-driver telemetry disable` (or `CUA_DRIVER_RS_TELEMETRY_ENABLED=false`).
- **The daemon's permission report follows the caller** (`"attribution":
  "caller"`): a daemon spawned as a child of Velora reads AX under Velora's
  Accessibility grant (TCC responsible-process inheritance) — so no new
  permission dialog. A daemon the user started elsewhere carries that
  parent's grants instead; Velora health-checks `check_permissions` before
  routing and falls back to the classic path if accessibility is missing.
- **Standard permission mode is promptless by design** — verified live
  (list/launch/click/type/clipboard-types all executed with
  `authorization host: unavailable`) and confirmed by the driver's docs. Its
  tighter modes (`bounded` + capability manifest, deny-by-default policy)
  are fixed at daemon launch.
- **A RUNNING daemon is a same-user privilege surface.** No per-connection
  credential is documented on the socket, and the vendor's own concurrency
  demo drives it from raw socket connections. The socket is `0600`, so this
  is same-user only, not network-reachable — but any process running as the
  user can drive every app on the desktop while a daemon is up. Velora
  therefore does not start a daemon unless an action actually routes, and
  **stops on quit any daemon it started itself** (a daemon the user started
  is left alone — another client may be attached). The "Work in the
  background" setting is the user's off switch; users who want the surface
  gone entirely should leave it off, or run the daemon in `bounded` mode
  themselves.
- **Velora's side of that surface is authenticated even though the socket
  is not.** Before spawning, the bundle at `/Applications/CuaDriver.app`
  must satisfy Cua's Developer ID requirement (`/Applications` is
  admin-writable without authentication, and a spawned child inherits
  Velora's TCC responsibility — an unverified binary there would have run
  under Velora's Accessibility grant with no prompt). Before sending a
  single byte, the socket's peer pid is checked against the same
  requirement, so a squatting process cannot collect typed text or feed
  Velora forged snapshots.
- **No isolation, and none claimed on the host.** The agent drives the real
  logged-in apps and profiles. "Without interrupting you" means input
  routing, not a sandbox. True isolation is a separate Cua product (Lume
  VMs, still active) and is not what "the driver is installed" buys.
- **Maturity**: MIT, ~22k stars, active weekly releases, 0.21.0 dated
  2026-08-19. macOS 26 is "E2E verified" but ScreenCaptureKit is its fragile
  spot (issue #870); the AX path Velora uses is the resilient one.

## What shipped

`BackgroundRoutingActionHost` wraps the classic `SystemActionHost`:

- Routing decision once per action, at `open_app`: target resolved via the
  driver's `list_apps`, then gated — **must be a different app** than the
  user's frontmost (compared by bundle id; an unreadable frontmost app fails
  closed), **must not be a communication app** (send authority stays on the
  battle-tested foreground evidence chain), **must not be a browser**.
  Everything else — driver missing, daemon sick, setting off — falls back to
  the classic foreground path, as does the remainder of an action after an
  `open_url` or a switch to a non-routable app.
- Web content is refused per ELEMENT, not per app: a text element under an
  `AXWebArea` is never a background target. Electron apps (VS Code,
  Obsidian, Notion) may route, but their web surfaces cannot be typed into —
  which is the actual hazard, since those echo-confirm AX writes the DOM
  never saw.
- In routed mode the executor's `wait_frontmost` polling drives target
  readiness: window picked (`CuaWindowPick` — on-screen, then largest,
  accessory panels last), AX tree snapshot must resolve, one
  materialization flash permitted after 1.2 s.
- `type_text` addresses the target window's primary text element by token
  (lone `AXTextArea` first, else the lone editable, else refuse). Evidence is
  the driver's `effect:"confirmed"` value readback, or — when the driver
  cannot prove it — the SAME element's value changing to include the
  insertion. "The text appears somewhere in the window" is deliberately not
  accepted: a document that already contained the words would certify a
  write that never happened.
- `elements_complete` is NOT trusted as the completeness signal: driver
  0.21.0 reports it false even on a walk that plainly finished (verified
  live, 67 of 67 elements). Velora compares `element_count` against
  `total_element_count` instead, and honours the flag only when it says
  true. Believing the flag would have refused every background target — the
  bug that live QA caught and unit tests could not.
- Committing keys (Return/Enter) require a draft this action itself
  delivered to the target, mirroring the foreground host's draft ownership —
  defense in depth behind the executor's communication-bundle gate.
- The observation reports the target window's primary text element as the
  focused element — the truthful answer to the planner's "is there
  somewhere for text to go?" (without it the planner waits forever for a
  focus that background windows never report).
- `press_element` runs the same `ActionRuntimePolicy.pressRoles` +
  committing-verb denylist + whole-word `AppMatcher` semantics over the
  snapshot (`CuaPressPick`), ancestor walk included.
- Keys are delivered by NAME through `press_key` (`CuaKeyMap`: enter→
  return, page_up→pageup; forward_delete and worded punctuation refuse).
  The `ActionHost.pressKey` protocol now carries the plan's key name+mods
  alongside the CGKeyCode for exactly this.
- Setting: **Settings → Voice actions → "Work in the background"** (shown
  only when the driver is installed; default on; portable settings key
  `shortcuts.backgroundActions`).

Unchanged on purpose: the engine planner, `ActionPlan` validation, the send
gate, the URL fence, turn/wall-clock budgets. The driver changes WHERE
verified steps are delivered, never what is allowed.

## Live end-to-end verification (2026-08-24)

With the transport fixed and the planner prompt corrected, on the installed
build:

- Command: "in TextEdit type: Background hello from Velora", TextEdit open in
  the background with one document, frontmost app `cmux`.
- Result: the document went from `QA SEED LINE` to
  `QA SEED LINE\nhellohellohellohellohellohello` — typed through the driver.
- **Focus never moved**: 25 samples of the frontmost app across the run, all
  `cmux`. TextEdit was never brought forward.
- Velora started the daemon itself (signature check passed) and logged
  "action driving TextEdit in the background".
- Control: with the setting off, the same command types through the classic
  foreground path, and NO daemon is started — confirming routing decides
  before the daemon does.

Two honest caveats from that session:

- **Multi-window apps**: TextEdit had restored three documents in an earlier
  attempt and the text went to the topmost one, not the one the QA had
  seeded. That is the documented rule working (topmost titled document), but
  it means "in TextEdit" is ambiguous when several documents are open. The
  mitigation is the existing one: name the document in the command and
  `verify_context` enforces it.
- **The planner still chunks.** It typed "hello" six times rather than the
  whole phrase, and burned the turn budget. That is the compact-model
  limitation already documented in the bakeoff, not a delivery failure —
  the same chunking happens on the foreground path.

## The multi-turn typing bug this round uncovered

Found while QA-ing the background path, and it affected BOTH paths: a new
`ActionExecutor` is built per batch, so focus state starts empty every turn
and the validator rejects any `type_text`/`key`/`press_element` that is not
preceded by a checkpoint IN THAT SAME BATCH. The system prompt said so once,
at the top; the between-turns note — the text nearest the model's reply, and
what a 4B planner actually acts on — did not. Live result: the model proposed
typing, was rejected, retried, and ran out of turns without ever writing
anything. Any action needing more than one turn to type was broken.

The note now states the rule AND carries a worked example of a checkpoint and
the work in one batch. Stating the rule alone was not enough — the model
then sent a lone `wait_frontmost` every turn instead. The example is what
fixed it, which is the general lesson for prompting this size of model.

## Rejected alternatives

- **Adopting the driver's MCP surface / browser CDP tools**: Velora's
  planner is a 4B local model with a closed step vocabulary; handing it 60
  raw tools is a different (bigger) product and a bigger attack surface.
- **Building pid-targeted AX delivery in-house**: Velora's AX stack could
  do ~70% of this, but the driver's delivery-ladder engineering
  (misgrounding refusals, readback evidence, coordinate spaces) is the hard
  30%, it is maintained, MIT, local-only, and already on the machine.
- **Routing communication apps in the background**: rejected until a
  background evidence chain exists for recipient verification — wrong-
  recipient risk beats convenience.
