# Action Background Final Handoff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Action Mode navigate exact controls in the background, bring a web composer forward only for the final content step, and close the automation daemon after each action with telemetry and update checks disabled.

**Architecture:** Preserve `complete` as the proof for absence, uniqueness, and whole-screen completion. Partial snapshots may authorize only affirmative exact capabilities whose snapshot, window, element, role, authored label, and action are rechecked at execution. Cua supplies background capabilities but never claims a complete tree; web content transitions through an explicit final `present_app` step before recipient-verified typing.

**Tech Stack:** Swift/AppKit Accessibility, Cua Driver 0.21, Python action engine, Swift selftest, pytest.

---

### Task 1: Exact partial UI capabilities

**Files:**
- Modify: `Sources/Velora/Actions/ActionUIObservation.swift`
- Modify: `Sources/Velora/Context/ScreenContext.swift`
- Modify: `Sources/Velora/Actions/SystemActionHost.swift`
- Modify: `Sources/Velora/Actions/CuaActionHost.swift`
- Modify: `Sources/Velora/Actions/ActionPlan.swift`
- Modify: `engine/src/velora_engine/actions.py`
- Modify: `engine/src/velora_engine/server.py`
- Test: `Sources/Velora/Selftest/ActionSelftest.swift`
- Test: `engine/tests/test_actions.py`

1. Add failing tests proving a partial snapshot cannot prove absence or completion, but an exact command-bound `AXPress`/`AXFocus` capability can pass UI review and must still be re-read at execution.
2. Add the current focused window to `ScreenActionUISnapshot`; reject native press/verify when that window changes inside the same app.
3. Parse Cua index, token, role, label/value, parent, depth, frame, enabled, selected, and web-content fields. Expose routed snapshots as partial `ActionUISnapshot` values and retain their exact tokens locally.
4. Implement routed indexed press/verify against the cached snapshot id, pinned window id, bundle, token, role, label, action, and current driver snapshot. Do not infer whole-tree completeness from Cua counts.
5. Replace blanket server `complete` refusals with purpose-specific checks: ordinary goal/absence claims remain complete-only; partial UI review may only approve exact command-bound non-committing actions and may never return `goal_met`; partial target evidence is limited to the exact focused editable whose authored label names the command target.
6. Run the focused engine tests and Swift selftest.

### Task 2: Draft recipient proof and final foreground handoff

**Files:**
- Modify: `Sources/Velora/Actions/ActionPlan.swift`
- Modify: `Sources/Velora/Actions/ActionExecutor.swift`
- Modify: `Sources/Velora/Actions/CuaActionHost.swift`
- Modify: `Sources/Velora/Actions/ActionLoop.swift`
- Modify: `engine/src/velora_engine/actions.py`
- Modify: `engine/src/velora_engine/server.py`
- Test: `Sources/Velora/Selftest/ActionSelftest.swift`
- Test: `engine/tests/test_actions.py`

1. Add failing tests proving drafts cannot type content before exact recipient/destination verification.
2. Add a bounded `present_app` step. It may only present the host's already-pinned target and does not type or commit anything.
3. When a proposed content step targets background web content, deterministically replace that turn with `present_app`, force `done=false`, and observe again.
4. In the routed host, pin the unique target editor, activate the exact app/window, focus that exact element, verify the app and focused editable, then leave the target foreground and return to the native host.
5. Require independent exact target verification for draft content as well as sending content. Keep Return/Enter forbidden for drafts.
6. Run the focused engine tests and Swift selftest.

### Task 3: Focus restoration and private daemon lifetime

**Files:**
- Modify: `Sources/Velora/Actions/ActionExecutor.swift`
- Modify: `Sources/Velora/Actions/ActionLoop.swift`
- Modify: `Sources/Velora/Actions/CuaActionHost.swift`
- Modify: `Sources/Velora/Actions/CuaDriverClient.swift`
- Test: `Sources/Velora/Selftest/ActionSelftest.swift`

1. Add failing tests where temporary materialization succeeds but `hide()` fails; assert the exact prior PID is explicitly reactivated and verified.
2. Replace activate/sleep/hide with capture-prior-PID, materialize, restore-prior-PID, verify. If restoration fails, stop background execution and report that foreground access is required.
3. Add `endActionInputSession()` to `ActionHost` and call it with `defer` for success, failure, and cancellation.
4. Spawn Velora-owned Cua with `CUA_DRIVER_RS_TELEMETRY_ENABLED=false` and `CUA_DRIVER_RS_UPDATE_CHECK=false`; stop only Velora-owned daemon processes at action end.
5. Run the Swift selftest and verify no Velora-owned daemon remains after the action seam completes.

### Task 4: Audit and installed acceptance

**Files:**
- Review all changed files against this plan and `/Users/sushil/.claude/CLAUDE.md`.

1. Run a spec-compliance subagent review, fix every missing/extra requirement, and re-review.
2. Run an independent code-quality/security subagent review, fix every critical or important finding, and re-review.
3. Run focused engine Action tests, Swift build/selftest, Ruff, Python compilation, and `git diff --check`.
4. Build and install a signed local app, relaunch it, and prove installed bundle version plus running executable path.
5. From a different frontmost app, run one Slack command that drafts for Hemesh without sending. Verify background navigation, no early persistent focus takeover, exact final Slack/composer focus, draft text present, no Return/send receipt, daemon shutdown, and fresh app/engine logs.
