# Action Mode: semantic actions, menu bar, busy windows (2026-11-02)

Owner request: adopt the useful parts of vercel-labs/agent-desktop in Velora's
own Swift/Python Action Mode — more semantic actions, menu-bar menus, and
windows too big for the 500-element snapshot — without adding a dependency or
slowing the hot path.

## Evidence (read-only probe, this Mac, `--action-probe`)

`Sources/Velora/Selftest/ActionAXProbe.swift` surveyed 20 running apps under
the signed bundle's Accessibility grant (attribute reads only).

- **Native list rows have no AXPress.** Finder 0/28 rows, System Settings 0/38,
  Tailscale 0/9 expose AXPress, but every row has a settable `AXSelected` and
  every list a settable selection. `press_ui` therefore cannot navigate the
  Finder or System Settings sidebars today.
- **Row names live in a descendant `AXStaticText`'s AXValue** (Finder,
  Tailscale) or deeper in a SwiftUI hosting group (System Settings); the row
  itself has no title/description. Action Mode excludes AXValue, so these rows
  reach the model unnamed.
- **Every app's menu bar is readable, including background apps and apps with
  zero AX windows** (Notes, Messages): 79–795 items, 56–495 ms to walk.
  Background apps report many items disabled (no key window) — disabled items
  genuinely cannot run there, so they stay excluded.
- **Busy windows are web content.** Chrome 2113 nodes (1628 AXGroup, depth 62),
  Telegram Web 1331. Few are empty wrappers (9 and 5 single-child unlabeled
  groups), so wrapper elision would not fit them into 500; searching does.
- Outline disclosure is settable on some rows (Finder 3/28).

## Scope

1. `set_ui` — declarative target state on one exact native element:
   `on`/`off` (checkbox/switch), `selected` (row), `expanded`/`collapsed`
   (outline row / disclosure triangle). Idempotent, verified by readback.
2. `menu_item` — run one enabled menu-bar command by path, resolved live
   against the target app's AX menu bar. No visible menu, no keystroke.
3. `find_ui` — when the window snapshot is incomplete, search the whole window
   for a visible name and observe only the matches (plus ancestors). This is
   agent-desktop's `find`, chosen over skeleton/drill because a 4B planner
   knows the NAME it needs, not the region.

Not in scope (documented, not built): pop-up button option selection and
context menus (they open visible menus over the user's work), sliders
(AXIncrement/AXDecrement), wrapper elision.

## Wire contract

### Snapshot payload (Swift → engine)

Per element (`ActionUIElement.payload`), all optional, native source only:

| field | type | meaning |
|---|---|---|
| `toggle` | `"on"\|"off"\|"mixed"` | current state of an AXCheckBox (incl. subrole AXSwitch) whose AXValue is numeric 0/1/2 and which exposes AXPress |
| `expanded` | bool | AXDisclosing of a row, or AXDisclosureTriangle numeric AXValue (1 = expanded) |
| `set` | array of `"on" "off" "selected" "expanded" "collapsed"` | target states this element can be put into NOW (never its current state) |

`set` rules (Swift decides; engine trusts only the listed enum values):

- `on`/`off`: element has `toggle` and AXPress; offer the opposite of the
  current state; `mixed` offers both.
- `selected`: element is not selected AND either its own AXSelected is
  settable, or (role AXRow) its nearest AXTable/AXOutline/AXList ancestor
  (≤3 levels) has a settable AXSelectedRows. AXRow only this round (tabs and
  radio buttons already select through AXPress).
- `expanded`/`collapsed`: AXDisclosing settable on a row → the opposite of the
  current value; AXDisclosureTriangle with AXPress and numeric value → the
  opposite.

Derived labels (Swift, one function used at capture AND execution recheck):

- AXRow with no authored label: label = first short name found in its subtree
  (BFS, ≤4 levels, ≤16 nodes): an authored title/description, or the AXValue of
  a non-editable AXStaticText. "Short" = the existing passive-label rule
  (≤80 chars, ≤8 words).
- AXCheckBox / AXSlider / AXPopUpButton with no authored label: the
  AXTitleUIElement's title or (static text) value.
- AXValue of editable roles is NEVER used (self-confirmation rule unchanged).
  General AXStaticText values are NOT added to the full-window observation
  (prompt size); they are used only for row labels and find matching.

Snapshot-level:

```json
"scope": {"kind": "find", "query": "Downloads", "matches": 3},
"menu_bar": {
  "complete": true,
  "top": ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
  "items": [{"path": ["View", "Show Sidebar"]}, {"path": ["Go", "Downloads"]}]
}
```

- `scope` present only on find-scoped snapshots. `complete` there means the
  whole window was searched and every match (≤30) is included.
- `menu_bar.items`: enabled leaf items that pass the menu policy below, ≤600,
  depth ≤4 below the bar, components ≤80 chars, walk deadline 0.5 s
  (`complete:false` when cut). `top` excludes the Apple menu; it includes the
  app menu title only if the app menu contributes an item.

### Plan steps (engine → Swift), as the planner writes them

```json
{"do":"set_ui","index":12,"role":"AXCheckBox","label":"Wi-Fi","state":"on"}
{"do":"menu_item","path":["View","Show Sidebar"]}
{"do":"find_ui","text":"Downloads"}
```

The engine adds `"snapshot": <id>` to `set_ui` exactly as it does for
`press_ui`. `menu_item.path` is normalized to the exact strings from the
current `menu_bar.items` entry it matched.

## Validation (engine `actions.py` AND Swift `ActionPlan.swift` must agree)

### set_ui
- Current native snapshot, `complete == true` (a complete find-scoped snapshot
  counts), source native, element exists, role and label equal (normalized),
  enabled, normalized label ≥3 chars, `state` ∈ element `set`.
- Label policy (as shipped): `selected`/`expanded`/`collapsed` carry no label
  denylist. Selection and disclosure navigate; the live probe showed sidebar
  rows named Trash, Lock Screen, Wallet & Apple Pay and Archive that the press
  denylist would have made unreachable. `on`/`off` use the press denylist MINUS the
  toggle-exempt words, because a switch label names a setting, not a commit:
  `toggle_exempt: toggle turn enable disable play pause stop start resume
  connect disconnect record mute lock sleep save close quit block subscribe`
  (mirrored list + mirror test, like `// press_denylist:`).
- Needs a focus checkpoint earlier in the batch (FOCUS_REQUIRED_VERBS), must be
  the final step of its batch (observation barrier, like press_ui), is an
  EFFECTIVE verb, triggers `turn_needs_goal_check`.
- State after it = state after press_ui (focus not established, target not
  verified, pending text becomes unverified and loses its element binding).
- UI-action review: required like press_ui. The self-evident-navigation skip
  extends to `set_ui state=selected` on a repeated collection member whose
  label the command names. Reviewer rules learn set_ui: approve `on`/`off` only
  when the command explicitly asks to turn that exact setting on/off
  (enable/disable/check/uncheck/switch); approve `selected`/`expanded`/
  `collapsed` when it navigates toward the command.
- `verify_state` gains `assert: "on" | "off"`: element `toggle` currently
  equals the assertion and its label is named by the command.
- A plain `press_ui` on an element with a `toggle` state is refused in both
  validators and points to `set_ui` (a press flips blindly; set_ui is
  idempotent and read back). A press on a set-only row (no AXPress) points to
  `set_ui` too, without spending a reviewer call.
- "Named by the command" (`command_mentions_ui_label` /
  `commandMentionsUILabel`) also accepts a whole label of 4+ normalized
  characters equal to one to three consecutive command words joined, so
  "wifi", "wi-fi" and "wi fi" all name "Wi-Fi", whose own words are too short
  to share.

### menu_item
- `path` is a list of 1–5 non-empty strings ≤80 chars; it must equal
  (component-wise normalized: `normalized_term` / `AppMatcher.normalize`) one
  entry in the current snapshot's `menu_bar.items`.
- No component may be committing (`press_label_is_committing`) or contain a
  menu-deny word: `menu_deny: paste cut undo redo` (mirrored + mirror test).
- Needs a focus checkpoint earlier in the batch; final step of its batch;
  EFFECTIVE verb; triggers `turn_needs_goal_check`; state after = press_ui.
- Review (as shipped, after cross-vendor review): skipped only when the
  command names the leaf AND every content word of the command (minus menu
  stopwords, the app name and generic command words) is a word of the path
  (`command_is_menu_path`). Naming the leaf alone let "copy the bold text"
  skip review for Format > Font > Bold. Otherwise the UI-action reviewer
  judges the proposed menu path against the command.
- An AXPress the app rejects after the path resolved (`.failed`) is terminal
  in both hosts: a menu item that opens a modal can time the press out after
  the command ran, so a retry could run it twice.
- Not found → PlanError naming the deepest matched prefix and listing its
  children from `menu_bar.items` (bounded, defanged) so the one repair retry can
  pick a real item. Raise the repair-note reason cap from 200 to 400 chars.

### find_ui
- `text` 3–60 chars after sanitize/defang. Requires a current native snapshot
  (any completeness). Final step of its batch. NOT effective, needs no focus
  checkpoint, changes no text/focus state, never combines with `done`.

### Finishing on a find result
`verify_state` binds to an exact window id, which only routed background
snapshots carry; the goal verifier never accepts a find result. In the
foreground (`window_id` null) the FIND RESULT hint says to reply done=true,
`verify_state` is refused with that steer, and the goal verifier is skipped,
so the done ends the action and Swift reports the effect as performed but
unverified (no effect at all is still a failure).

### Find-scoped snapshots grant navigation only
On a snapshot with `scope.kind == "find"`: `press_ui` and `set_ui` are allowed
(when complete); `type_text`/`paste_text`/`replace_text`/`search_text` with an
index, `verify_ui` (target or goal attestation), and native-input contract
lines are NOT. `verify_state` IS allowed (it re-checks one exact positive
state). The target verifier and goal verifier never treat a find-scoped
snapshot as admissible evidence.

## Prompt (engine)

- Step list gains the three shapes with one line each.
- Element lines: `can_set=on` / `can_set=selected,expanded` (the wire field
  stays `set`; the 4B reviewer read `set=selected` as the current state in
  the bench); the state list gains
  `on|off|mixed` and `expanded|collapsed` (`state=off`, `state=selected,expanded`).
- Header line for find-scoped trees: `scope=find query="Downloads" matches=3`.
- When `complete=false` (not find-scoped), add: indexed actions are refused on a
  partial tree; use `find_ui` with the visible name of the control you need.
- Menu bar lines (in the user turn with the UI tree, never the cached system
  prefix): `MENU BAR (screen data): File | Edit | View | Go | Window | Help`,
  then up to 16 `menu_item` paths whose words match the spoken command
  (case/accent-folded words ≥3 chars minus stopwords; equal or shared prefix
  ≥4 chars; ranked by matched words, then shorter path). If none match, only
  the top line.
- Rules: prefer `set_ui` over `press_ui` for rows/checkboxes/disclosure;
  prefer `menu_item` for app commands that live in the menu bar ("show the
  sidebar", "new folder", "export as PDF") over hunting for toolbar buttons;
  use `verify_state` `on`/`off`/`selected` to finish after a verified set_ui.

## Execution (Swift)

All three run through both hosts (`SystemActionHost` foreground,
`BackgroundRoutingActionHost` routed) with the existing lease/focus/lineage
checks of press_ui.

- **set_ui**: re-resolve the retained element (snapshot id, role, derived label,
  enabled, same pid/window as press). on/off: read numeric value; already equal
  → success no-op; else AXPress, poll readback ≤5×50 ms. selected: prefer the
  container's settable AXSelectedRows = [row] (exclusive), else AXSelected=true;
  poll readback AXSelected==true. expanded/collapsed: set AXDisclosing; or
  AXPress the triangle; poll readback. Failure to verify → non-recoverable
  failure "could not be verified; it was not retried" (same wording family as
  background press). Any success invalidates the snapshot (like press).
- **menu_item**: resolve live from the action's target app (`AXMenuBar` →
  `AXMenuBarItem` → `AXMenu` → `AXMenuItem`…), exactly one normalized title
  match per level, leaf with no submenu, AXEnabled != false, menu policy
  re-checked, then AXPress on the item (no menu is opened). Background host:
  additionally refuse unless the app's `AXMainWindow` is the routed target
  window (menu commands act on the main window; never retarget). Invalidate the
  menu-bar cache for that pid afterwards; settle like press.
- **find_ui**: store the query on the host; return success if a native target
  exists. The scope is sticky for the session: every later observation whose
  full-window walk is incomplete is replaced by a find-scoped walk for the
  current query; a complete full-window walk is returned as-is; a new
  `find_ui` replaces the query; an app/window change clears it.
  Find walk: whole window, visit ≤6000 nodes, deadline 2 s; match = normalized
  derived/authored label or short static-text value CONTAINS the normalized
  query; ≤30 matches; records = matches + every ancestor (nearest included
  ancestor becomes parent) + a match's enclosing AXRow; indices renumbered in
  tree order; `complete` = walk exhausted and ≤30 matches.

### Menu policy (Swift, at capture and at execution)
- Apple menu (menu bar item 0) excluded entirely.
- App menu (item 1): only the leaf whose shortcut is exactly ⌘, (Settings).
- Exclude items whose shortcut uses ⌘ with Q, W, S, X, V, Z, H, Delete,
  Forward Delete, Return, Enter, or Escape (any extra modifiers): read
  AXMenuItemCmdChar / AXMenuItemCmdVirtualKey / AXMenuItemCmdGlyph /
  AXMenuItemCmdModifiers (bit 8 = no ⌘). Pure function + selftests.
- Exclude disabled items, separators (empty titles), and any committing or
  menu-deny word in any component.

### Menu-bar cache and speed
- Cache keyed by pid (+ bundle id), TTL 120 s, invalidated after a
  `menu_item` on that pid. Prewarm the frontmost app's menu bar off-main when
  the Action hotkey goes down, so the walk overlaps speech and turn 1 pays
  nothing. A cold background target pays one walk (≤0.5 s) at its first
  observation.

## Tests

- Engine (pytest): normalization of the new fields (enum filtering, native
  only), prompt rendering (set=/state= tokens, find header, partial-tree hint,
  menu top + relevance filter + ranking + cap), validation accept/refuse for
  each verb (barrier, checkpoint, deny lists incl. toggle exemptions, path
  existence + repair listing, find-scope restrictions), review gating and the
  self-evident skip, verify_state on/off, mirror tests for the two new lists.
- Swift (`--selftest`): decode/validate/state for the three steps matching the
  engine cases; menu shortcut policy; menu path normalization/matching; the
  find-scope authority restrictions; host fakes for executor paths.
- Real model (Qwen3.5-4B via a bench script modelled on
  `docs/research/2026-10-27-lfm3-bakeoff/action_probes.py`): synthetic
  snapshots for System Settings sidebar select, a switch toggle, a Finder menu
  command, and a busy window → find_ui → act. Report pass/fail and turn
  latency.
- Live (signed app, `--action-probe` extended if needed): menu cache timing,
  row label derivation coverage on Finder/System Settings, find walk timing on
  Chrome.
