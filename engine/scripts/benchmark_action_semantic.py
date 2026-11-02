#!/usr/bin/env python3
"""Real-model check for Action Mode's semantic verbs: set_ui, menu_item, find_ui.

Run from ``engine/``::

    .venv/bin/python scripts/benchmark_action_semantic.py [--model PATH] [--json]

Drives the production planner (Qwen3.5-4B-MLX-8bit, greedy, in its own
cleanup worker) through the REAL ``ActionSession`` turn logic with synthetic
snapshots shaped like the 2026-11-02 AX probe found them: System Settings
rows that offer only ``set=selected``, a Focus switch, Finder's menu bar, and
a busy window too big for the 500-element snapshot. Each turn follows the
server's order: direct completion check, controller (+ one repair carrying
the rejection), UI-action reviewer, goal verifier, ``accept_reply``. Plans are
generated and validated only; nothing is sent to the macOS executor.

Modelled on docs/research/2026-10-27-lfm3-bakeoff/action_probes.py.
Contract: docs/plans/2026-11-02-action-mode-semantic-actions.md.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import statistics
import time
from typing import Any, Callable
import uuid

from velora_engine import action_fastpath, actions
from velora_engine.cleanup_process import CleanupProcess

MODEL_ID = "mlx-community/Qwen3.5-4B-MLX-8bit"


# ---------------------------------------------------------------- snapshots

def _frame(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def settings_sidebar(selected: str, snapshot_id: str) -> dict:
    rows = ("Wi-Fi", "Bluetooth", "Network", "Battery", "General",
            "Accessibility", "Appearance", "Control Center", "Displays",
            "Notifications", "Sound", "Focus", "Screen Time")
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow", "label": selected,
         "frame": _frame(0, 0, 900, 640)},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXSearchField",
         "label": "Search", "actions": ["AXFocus"],
         "frame": _frame(10, 40, 200, 24)},
        {"index": 2, "parent_index": 0, "depth": 1, "role": "AXOutline",
         "label": "Sidebar", "frame": _frame(0, 70, 220, 570)},
    ]
    for offset, name in enumerate(rows):
        row = {"index": 3 + offset, "parent_index": 2, "depth": 2,
               "role": "AXRow", "label": name,
               "frame": _frame(0, 80 + offset * 28, 220, 28)}
        if name == selected:
            row["selected"] = True
        else:
            row["set"] = ["selected"]
        elements.append(row)
    base = 40
    elements += [
        {"index": base, "parent_index": 0, "depth": 1, "role": "AXGroup",
         "label": selected, "frame": _frame(230, 40, 670, 600)},
        {"index": base + 1, "parent_index": base, "depth": 2,
         "role": "AXHeading", "label": selected,
         "frame": _frame(250, 50, 300, 30)},
        {"index": base + 2, "parent_index": base, "depth": 2,
         "role": "AXCheckBox", "label": selected, "actions": ["AXPress"],
         "toggle": "on", "set": ["off"], "frame": _frame(800, 100, 40, 20)},
    ]
    return {"id": snapshot_id, "source": "native", "complete": True,
            "app_name": "System Settings",
            "bundle_id": "com.apple.systempreferences",
            "window_title": selected, "window_id": 501,
            "elements": elements}


def settings_live(pane: str, snapshot_id: str, *, wifi: str | None = None,
                  complete: bool = True, scope: dict | None = None) -> dict:
    """System Settings as the live probe saw it (2026-11-02): foreground (no
    window id), each sidebar row holds a cell holding a pressable button,
    and the Wi-Fi page is partial (~40 nearby networks overflow the cap).
    Its switch has no name of its own; Swift names it from its row text."""
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow", "label": pane,
         "frame": _frame(0, 0, 900, 640)},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXOutline",
         "label": "Sidebar", "frame": _frame(0, 70, 220, 570)},
    ]
    index = 2
    for offset, name in enumerate(("Wi-Fi", "Bluetooth", "Network", "VPN",
                                   "Battery", "General", "Accessibility",
                                   "Appearance")):
        frame = _frame(0, 80 + offset * 28, 220, 28)
        row = {"index": index, "parent_index": 1, "depth": 2,
               "role": "AXRow", "label": name, "frame": frame}
        if name == pane:
            row["selected"] = True
        else:
            row["set"] = ["selected"]
        elements += [
            row,
            {"index": index + 1, "parent_index": index, "depth": 3,
             "role": "AXCell", "frame": frame},
            {"index": index + 2, "parent_index": index + 1, "depth": 4,
             "role": "AXButton", "label": name, "actions": ["AXPress"],
             "frame": _frame(8, 80 + offset * 28, 200, 28)},
        ]
        index += 3
    if pane == "General":
        for offset, name in enumerate(("About", "Software Update", "Storage",
                                       "Date & Time", "Sharing")):
            elements.append(
                {"index": 60 + offset, "parent_index": 0, "depth": 1,
                 "role": "AXButton", "label": name, "actions": ["AXPress"],
                 "frame": _frame(250, 100 + offset * 40, 600, 36)})
    if wifi is not None:
        elements += [
            {"index": 70, "parent_index": 0, "depth": 1, "role": "AXGroup",
             "frame": _frame(250, 60, 600, 120)},
            {"index": 71, "parent_index": 70, "depth": 2,
             "role": "AXStaticText", "label": "Wi\u2011Fi",
             "frame": _frame(260, 70, 200, 20)},
            {"index": 72, "parent_index": 70, "depth": 2,
             "role": "AXCheckBox", "label": "Wi\u2011Fi",
             "actions": ["AXPress"], "toggle": wifi,
             "set": ["off" if wifi == "on" else "on"],
             "frame": _frame(800, 70, 40, 20)},
            {"index": 73, "parent_index": 70, "depth": 2,
             "role": "AXStaticText", "label": "Police",
             "frame": _frame(260, 110, 200, 20)},
            {"index": 74, "parent_index": 70, "depth": 2, "role": "AXButton",
             "label": "Details…", "actions": ["AXPress"],
             "frame": _frame(760, 110, 80, 24)},
        ]
    snap = {"id": snapshot_id, "source": "native", "complete": complete,
            "app_name": "System Settings",
            "bundle_id": "com.apple.systempreferences",
            "window_title": pane, "elements": elements}
    if scope is not None:
        snap["scope"] = scope
    return snap


def focus_pane(toggle: str, snapshot_id: str) -> dict:
    opposite = {"on": ["off"], "off": ["on"]}
    switches = (
        ("Do Not Disturb", toggle),
        ("Share across devices", "on"),
        ("Allow notifications from people", "off"),
        ("Allow calls from Favorites", "on"),
    )
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow", "label": "Focus"},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXHeading",
         "label": "Focus"},
        {"index": 2, "parent_index": 0, "depth": 1, "role": "AXGroup",
         "label": "Focus modes"},
    ]
    for offset, (label, state) in enumerate(switches):
        elements.append({
            "index": 3 + offset, "parent_index": 2, "depth": 2,
            "role": "AXCheckBox", "label": label, "actions": ["AXPress"],
            "toggle": state, "set": opposite[state]})
    elements += [
        {"index": 9, "parent_index": 0, "depth": 1,
         "role": "AXDisclosureTriangle", "label": "Schedules",
         "actions": ["AXPress"], "expanded": False, "set": ["expanded"]},
        {"index": 10, "parent_index": 0, "depth": 1, "role": "AXButton",
         "label": "Add Focus…", "actions": ["AXPress"]},
    ]
    return {"id": snapshot_id, "source": "native", "complete": True,
            "app_name": "System Settings",
            "bundle_id": "com.apple.systempreferences",
            "window_title": "Focus", "window_id": 501,
            "elements": elements}


FINDER_MENU = {
    "complete": True,
    "top": ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
    "items": [{"path": path} for path in (
        ["Finder", "Settings…"],
        ["File", "New Finder Window"], ["File", "New Folder"],
        ["File", "New Smart Folder"], ["File", "New Tab"],
        ["File", "Open"], ["File", "Get Info"], ["File", "Duplicate"],
        ["File", "Make Alias"], ["File", "Quick Look"], ["File", "Find"],
        ["Edit", "Copy"], ["Edit", "Select All"],
        ["Edit", "Show Clipboard"],
        ["View", "as Icons"], ["View", "as List"], ["View", "as Columns"],
        ["View", "as Gallery"], ["View", "Use Groups"],
        ["View", "Sort By", "Name"], ["View", "Sort By", "Date Modified"],
        ["View", "Show Tab Bar"], ["View", "Show All Tabs"],
        ["View", "Show Sidebar"], ["View", "Show Preview"],
        ["View", "Hide Toolbar"], ["View", "Show Path Bar"],
        ["View", "Show Status Bar"], ["View", "Show View Options"],
        ["View", "Enter Full Screen"],
        ["Go", "Back"], ["Go", "Enclosing Folder"], ["Go", "Recents"],
        ["Go", "Documents"], ["Go", "Desktop"], ["Go", "Downloads"],
        ["Go", "Home"], ["Go", "Computer"], ["Go", "AirDrop"],
        ["Go", "Network"], ["Go", "iCloud Drive"], ["Go", "Applications"],
        ["Go", "Utilities"], ["Go", "Go to Folder…"],
        ["Go", "Connect to Server…"],
        ["Window", "Minimize"], ["Window", "Zoom"],
        ["Window", "Move Window to Left Side of Screen"],
        ["Window", "Bring All to Front"],
        ["Help", "macOS Help"],
    )],
}


def finder(snapshot_id: str, *, sidebar: bool) -> dict:
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow", "label": "Recents"},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXToolbar",
         "label": "toolbar"},
        {"index": 2, "parent_index": 1, "depth": 2, "role": "AXButton",
         "label": "Back", "actions": ["AXPress"]},
        {"index": 3, "parent_index": 1, "depth": 2, "role": "AXButton",
         "label": "Forward", "actions": ["AXPress"], "enabled": False},
        {"index": 4, "parent_index": 1, "depth": 2, "role": "AXSearchField",
         "label": "Search", "actions": ["AXFocus"]},
        {"index": 5, "parent_index": 0, "depth": 1, "role": "AXList",
         "label": "Recents"},
    ]
    for offset, name in enumerate(("Q3 report.pdf", "invoice.pdf",
                                   "IMG_2041.jpg", "notes.md")):
        elements.append({
            "index": 6 + offset, "parent_index": 5, "depth": 2,
            "role": "AXRow", "label": name, "set": ["selected"],
            "frame": _frame(240, 80 + offset * 24, 600, 24)})
    if sidebar:
        elements.append({"index": 20, "parent_index": 0, "depth": 1,
                         "role": "AXOutline", "label": "Sidebar"})
        for offset, name in enumerate(("AirDrop", "Recents", "Applications",
                                       "Desktop", "Documents", "Downloads")):
            row = {"index": 21 + offset, "parent_index": 20, "depth": 2,
                   "role": "AXRow", "label": name,
                   "frame": _frame(0, 80 + offset * 26, 200, 26)}
            if name == "Recents":
                row["selected"] = True
            else:
                row["set"] = ["selected"]
            elements.append(row)
    return {"id": snapshot_id, "source": "native", "complete": True,
            "app_name": "Finder", "bundle_id": "com.apple.finder",
            "window_title": "Recents", "window_id": 77,
            "elements": elements, "menu_bar": FINDER_MENU}


SLACK_MENU = {
    "complete": True,
    "top": ["Slack", "File", "Edit", "View", "Go", "Window", "Help"],
    "items": [{"path": path} for path in (
        ["Slack", "Settings…"], ["File", "New Message"],
        ["Edit", "Copy"], ["Edit", "Select All"],
        ["View", "Actual Size"], ["View", "Zoom In"], ["View", "Zoom Out"],
        ["View", "Toggle Full Screen"], ["Go", "Back"], ["Go", "Forward"],
        ["Go", "Home"], ["Go", "DMs"], ["Go", "Activity"],
        ["Go", "Quick Switcher"],
    )],
}


def busy_slack(snapshot_id: str) -> dict:
    """Message history fills the 500-node budget before the sidebar does."""
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow",
         "label": "random (Channel) - Acme - Slack"},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXGroup",
         "label": "random"},
    ]
    authors = ("Priya Sharma", "Himesh Singh", "Dana Lee", "Omar Haddad")
    for offset in range(60):
        elements.append({
            "index": 2 + offset, "parent_index": 1, "depth": 2,
            "role": "AXGroup",
            "label": f"{authors[offset % 4]}: update {offset} on the launch"})
    elements.append({"index": 70, "parent_index": 0, "depth": 1,
                     "role": "AXTextArea", "label": "Message to random",
                     "focused": True, "actions": ["AXFocus"]})
    return {"id": snapshot_id, "source": "native", "complete": False,
            "app_name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap",
            "window_title": "random (Channel) - Acme - Slack",
            "window_id": 88, "elements": elements, "menu_bar": SLACK_MENU}


def found_general(snapshot_id: str, *, selected: bool) -> dict:
    row = {"index": 3, "parent_index": 2, "depth": 2, "role": "AXRow",
           "label": "general"}
    if selected:
        row["selected"] = True
    else:
        row["set"] = ["selected"]
    return {"id": snapshot_id, "source": "native", "complete": True,
            "app_name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap",
            "window_title": ("general (Channel) - Acme - Slack" if selected
                             else "random (Channel) - Acme - Slack"),
            "window_id": 88,
            "scope": {"kind": "find", "query": "general", "matches": 2},
            "elements": [
                {"index": 0, "depth": 0, "role": "AXWindow",
                 "label": "Slack"},
                {"index": 1, "parent_index": 0, "depth": 1,
                 "role": "AXGroup", "label": "Sidebar"},
                {"index": 2, "parent_index": 1, "depth": 2,
                 "role": "AXOutline", "label": "Channels"},
                row,
                {"index": 9, "parent_index": 0, "depth": 1,
                 "role": "AXGroup",
                 "label": "Dana Lee: moved the notes to general"},
            ],
            "menu_bar": SLACK_MENU}


# ------------------------------------------------------------------ cases

Check = Callable[[dict], str | None]


def _expect_step(verb: str, **fields: Any) -> Check:
    def check(turn: dict) -> str | None:
        steps = turn.get("steps") or []
        last = steps[-1] if steps else {}
        if last.get("do") != verb:
            return f"expected {verb}, got {last.get('do') or 'no step'}"
        for key, value in fields.items():
            if last.get(key) != value:
                return f"expected {key}={value!r}, got {last.get(key)!r}"
        return None
    return check


def _expect_any(*checks: Check) -> Check:
    def check(turn: dict) -> str | None:
        errors = [c(turn) for c in checks]
        return None if any(e is None for e in errors) else " / ".join(errors)
    return check


def _expect_done(turn: dict) -> str | None:
    return None if turn.get("done") else "expected done"


def _obs(app: str, snapshot: dict, executed: list[str]) -> dict:
    return {"frontmost_app": app, "window_title": snapshot["window_title"],
            "ui_snapshot": snapshot, "executed": executed,
            "failed_step": None}


_WIFI_FIND = {"kind": "find", "query": "wi-fi", "matches": 3}

CASES: tuple[dict, ...] = (
    {
        # Live failure 2026-11-02: System Settings opened on General; the
        # press check and reviewer refused the Wi-Fi sidebar press.
        "name": "settings_turn_on_wifi_already_on",
        "command": "turn on wifi",
        "app": "System Settings",
        "snapshot": settings_live("General", "gen-1"),
        "turns": [
            (None, _expect_any(
                _expect_step("press_ui", label="Wi-Fi"),
                _expect_step("set_ui", label="Wi-Fi", state="selected"))),
            (_obs("System Settings",
                  settings_live("Wi-Fi", "wifi-1", wifi="on",
                                complete=False),
                  ["wait_frontmost System Settings", "press_ui Wi-Fi"]),
             _expect_done),
        ],
    },
    {
        "name": "settings_turn_on_wifi_when_off",
        "command": "turn on wifi",
        "app": "System Settings",
        "snapshot": settings_live("Wi-Fi", "wifi-1", wifi="off",
                                  complete=False),
        "turns": [
            (None, _expect_step("find_ui")),
            (_obs("System Settings",
                  settings_live("Wi-Fi", "find-1", wifi="off",
                                scope=_WIFI_FIND),
                  ["find_ui wi-fi"]),
             _expect_step("set_ui", index=72, state="on")),
            (_obs("System Settings",
                  settings_live("Wi-Fi", "find-2", wifi="on",
                                scope=_WIFI_FIND),
                  ["wait_frontmost System Settings", "set_ui Wi-Fi on"]),
             _expect_done),
        ],
    },
    {
        "name": "settings_sidebar_select",
        "command": "open Bluetooth settings",
        "app": "System Settings",
        "snapshot": settings_sidebar("Wi-Fi", "set-1"),
        "turns": [
            (None, _expect_step("set_ui", index=4, state="selected")),
            (_obs("System Settings", settings_sidebar("Bluetooth", "set-2"),
                  ["wait_frontmost System Settings",
                   "set_ui Bluetooth selected"]),
             _expect_done),
        ],
    },
    {
        "name": "switch_toggle_on",
        "command": "turn on Do Not Disturb",
        "app": "System Settings",
        "snapshot": focus_pane("off", "dnd-1"),
        "turns": [
            (None, _expect_step("set_ui", index=3, state="on")),
            (_obs("System Settings", focus_pane("on", "dnd-2"),
                  ["wait_frontmost System Settings",
                   "set_ui Do Not Disturb on"]),
             _expect_step("verify_state", index=3, **{"assert": "on"})),
        ],
    },
    {
        "name": "finder_menu_show_sidebar",
        "command": "show the sidebar in Finder",
        "app": "Finder",
        "snapshot": finder("fin-1", sidebar=False),
        "turns": [
            (None, _expect_step("menu_item", path=["View", "Show Sidebar"])),
        ],
    },
    {
        "name": "finder_open_downloads",
        "command": "open the downloads folder",
        "app": "Finder",
        "snapshot": finder("fin-2", sidebar=True),
        "turns": [
            (None, _expect_any(
                _expect_step("menu_item", path=["Go", "Downloads"]),
                _expect_step("set_ui", index=26, state="selected"))),
        ],
    },
    {
        "name": "switch_toggle_off_in_content",
        "command": "turn off Wi-Fi",
        "app": "System Settings",
        "snapshot": settings_sidebar("Wi-Fi", "wifi-1"),
        "turns": [
            (None, _expect_step("set_ui", index=42, state="off")),
        ],
    },
    {
        "name": "finder_menu_path_bar",
        "command": "show the path bar",
        "app": "Finder",
        "snapshot": finder("fin-3", sidebar=True),
        "turns": [
            (None, _expect_step("menu_item", path=["View", "Show Path Bar"])),
        ],
    },
    {
        "name": "busy_window_find_then_select",
        "command": "open the general channel in Slack",
        "app": "Slack",
        "snapshot": busy_slack("busy-1"),
        "turns": [
            (None, _expect_step("find_ui")),
            (_obs("Slack", found_general("find-1", selected=False),
                  ["find_ui general"]),
             _expect_step("set_ui", index=3, state="selected")),
            (_obs("Slack", found_general("find-2", selected=True),
                  ["find_ui general", "wait_frontmost Slack",
                   "set_ui general selected"]),
             _expect_step("verify_state", index=3,
                          **{"assert": "selected"})),
        ],
    },
)


# ------------------------------------------------------------- the driver

async def _call(engine: CleanupProcess, message: str, prompt: str, *,
                controller: bool, cold: bool) -> Any:
    if controller:
        return await engine.cleanup(
            message, prompt,
            timeout_ms=(actions.FIRST_TURN_TIMEOUT_MS if cold
                        else actions.PLAN_TIMEOUT_MS),
            check_ratio=False, max_tokens=actions.PLAN_MAX_TOKENS,
            prefix_candidates=[(prompt, "a"), (prompt, "b")],
            cache_scope="action",
            max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS)
    return await engine.cleanup(
        message, prompt, timeout_ms=actions.VERIFIER_TIMEOUT_MS,
        check_ratio=False, max_tokens=180, cache_scope=None,
        max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS)


def _timing(result: Any) -> dict:
    return {"wall_ms": result.wall_ms, "ttft_ms": result.ttft_ms,
            "decode_ms": result.decode_ms, "cache_hit": result.cache_hit,
            "applied": result.applied, "reason": result.reason}


async def _goal_check(engine, session, record) -> dict | None:
    snapshot = session.current_ui_snapshot
    result = await _call(
        engine, actions.goal_verifier_message(session.transcript, session.goal),
        actions.build_goal_verifier_prompt(snapshot, session.prior_ui_snapshot),
        controller=False, cold=False)
    record["calls"].append({"kind": "goal_verifier", "reply": result.text,
                            **_timing(result)})
    if not result.applied:
        return None
    verdict = actions.parse_goal_verdict(
        result.text, snapshot, session.transcript, session.prior_ui_snapshot)
    return verdict if verdict.get("safe") is True else None


async def run_turn(engine: CleanupProcess, session: actions.ActionSession,
                   message: str) -> dict:
    """One server turn: direct goal check, controller + repair, reviewer,
    goal verifier, accept. Mirrors `server._run_action_turn` minus the
    calibrated decision fast path."""
    record: dict[str, Any] = {"calls": [], "rejections": []}
    started = time.perf_counter()
    direct = session.direct_goal_check_pending
    session.direct_goal_check_pending = False
    snapshot = session.current_ui_snapshot
    # Server: the named switch already in the asked-for state ends the
    # action with no model call.
    if actions.turn_is_observed_toggle_done({"done": True}, session):
        record["turn"] = session.accept_reply(
            '{"sends":false,"steps":[],"done":true}')
        record["path"] = "observed switch state"
        direct = False
    if (direct and actions.goal_snapshot_can_verify(snapshot)
            and actions.goal_snapshot_has_evidence(
                snapshot, session.prior_ui_snapshot)):
        try:
            verdict = await _goal_check(engine, session, record)
            if verdict is not None:
                token = uuid.uuid4().hex
                session.state.allowed_ui_attestation = token
                parsed = actions.attach_verified_goal(
                    {"done": True}, verdict, snapshot, token,
                    sends=bool(session.sends))
                record["turn"] = session.accept_reply(json.dumps(parsed))
                record["path"] = "direct_goal_check"
        except actions.PlanError as exc:
            session.state.allowed_ui_attestation = None
            record["rejections"].append(f"direct goal check: {exc}")

    last_error = ""
    for attempt in ((0, 1) if "turn" not in record else ()):
        prompt = session.system_prompt()
        if attempt and last_error:
            prompt += "\n" + actions.turn_repair_note(last_error)
        cold = session.controller_calls == 0
        result = await _call(engine, message, prompt, controller=True,
                             cold=cold)
        session.controller_calls += 1
        record["calls"].append({"kind": "controller", "attempt": attempt,
                                "reply": result.text, **_timing(result)})
        if not result.applied:
            last_error = f"model unavailable ({result.reason})"
            record["rejections"].append(last_error)
            continue
        try:
            reply = result.text
            parsed = actions.parse_turn(reply)
            settled = actions.settle_named_toggle(parsed, session)
            if settled is not parsed:
                parsed = settled
                reply = json.dumps(parsed, ensure_ascii=False)
            bounded = actions.bound_observation_turn(parsed)
            if bounded is not parsed:
                parsed = bounded
                reply = json.dumps(parsed, ensure_ascii=False)
            needs_review = actions.turn_requires_ui_action_review(
                parsed, session)
            if (not needs_review
                    and actions.turn_is_self_evident_collection_navigation(
                        parsed, session)):
                # Server `_press_needs_review`: the calibrated model keeps
                # the exemption only for a confident "goes somewhere".
                if action_fastpath.presses_may_call(session):
                    needs_review = True
                elif actions.turn_opens_named_setting(parsed, session):
                    record["calls"].append({
                        "kind": "named_setting_page", "wall_ms": 0,
                        "ttft_ms": None, "decode_ms": None,
                        "cache_hit": None, "applied": True,
                        "reason": "rule", "reply": "navigate"})
                else:
                    check = action_fastpath.press_check(parsed, session)
                    if check is not None:
                        decided = await engine.decide(
                            check.state, list(check.questions),
                            max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                            timeout_ms=action_fastpath.PRESS_CHECK_TIMEOUT_MS)
                        goes = (decided.ok
                                and action_fastpath.press_goes_somewhere(
                                    decided.answers))
                        record["calls"].append({
                            "kind": "press_check", "wall_ms": decided.ms,
                            "ttft_ms": None, "decode_ms": None,
                            "cache_hit": None, "applied": decided.ok,
                            "reason": decided.status,
                            "reply": "navigate" if goes else "needs review"})
                        needs_review = not goes
            if needs_review:
                review = await _call(
                    engine,
                    actions.ui_action_review_message(
                        session.transcript,
                        str(parsed.get("goal") or session.goal),
                        parsed.get("steps") or []),
                    actions.build_ui_action_review_prompt(snapshot),
                    controller=False, cold=False)
                record["calls"].append({"kind": "ui_reviewer",
                                        "reply": review.text,
                                        **_timing(review)})
                verdict = actions.parse_ui_action_review(
                    review.text, snapshot, session.transcript,
                    session.prior_ui_snapshot)
                if verdict.get("goal_met") is True:
                    token = uuid.uuid4().hex
                    session.state.allowed_ui_attestation = token
                    parsed = actions.attach_verified_goal(
                        parsed, verdict, snapshot, token,
                        sends=bool(session.sends
                                   if session.sends is not None
                                   else parsed.get("sends")))
                    reply = json.dumps(parsed, ensure_ascii=False)
                elif verdict.get("safe") is not True:
                    reason = str(verdict.get("reason"))
                    if not (session.sends is False
                            and session.turns_used > 0
                            and not actions.snapshot_is_find_scoped(
                                snapshot)):
                        raise actions.PlanError(
                            "UI action reviewer refused: " + reason)
                    # Server: a refused later-turn action never runs; only
                    # exact completion proof may replace it, and a tree that
                    # cannot carry proof ends the action evidence-free.
                    record["review_refused"] = reason
                    if not (snapshot.get("complete") is True
                            and actions.goal_snapshot_can_verify(snapshot)):
                        record["turn"] = session.accept_reply('{"done":true}')
                        record["path"] = ("refused review → evidence-free "
                                          "terminal turn")
                        break
                    goal = await _goal_check(engine, session, record)
                    if goal is None:
                        raise actions.PlanError(
                            "UI action reviewer refused: " + reason)
                    token = uuid.uuid4().hex
                    session.state.allowed_ui_attestation = token
                    parsed = actions.attach_verified_goal(
                        {"done": True}, goal, snapshot, token,
                        sends=False)
                    record["turn"] = session.accept_reply(
                        json.dumps(parsed, ensure_ascii=False))
                    record["path"] = "refused review → completion proof"
                    break
            if actions.turn_requires_goal_verifier(parsed, session):
                if not actions.goal_snapshot_can_verify(snapshot):
                    raise actions.PlanError(
                        "goal verifier: runtime-verifiable UI is required")
                verdict = await _goal_check(engine, session, record)
                if verdict is None:
                    raise actions.PlanError("goal verifier refused")
                token = uuid.uuid4().hex
                session.state.allowed_ui_attestation = token
                parsed = actions.attach_verified_goal(
                    parsed, verdict, snapshot, token,
                    sends=bool(session.sends))
                reply = json.dumps(parsed, ensure_ascii=False)
            if actions.turn_requires_target_verifier(parsed, session):
                raise actions.PlanError(
                    "benchmark: target verifier path is out of scope")
            record["turn"] = session.accept_reply(reply)
            record["path"] = f"controller attempt {attempt}"
            break
        except actions.PlanError as exc:
            session.state.allowed_ui_attestation = None
            last_error = str(exc)
            record["rejections"].append(last_error)
    record["turn_ms"] = int((time.perf_counter() - started) * 1000)
    return record


async def run_case(engine: CleanupProcess, case: dict) -> dict:
    context = actions.ActionContext(
        transcript=case["command"], frontmost_app=case["app"],
        frontmost_bundle=case["snapshot"]["bundle_id"],
        frontmost_window=case["snapshot"]["window_title"],
        running_apps=[case["app"], "Safari", "Slack", "Notes"],
        ui_snapshot=actions.normalize_ui_snapshot(case["snapshot"]),
    )
    session = actions.ActionSession(case["command"], context,
                                    require_target_verifier=True)
    turns = []
    for number, (obs, check) in enumerate(case["turns"], start=1):
        message = (session.first_message() if obs is None
                   else session.observation_message(obs))
        record = await run_turn(engine, session, message)
        accepted = record.get("turn")
        record["number"] = number
        record["failure"] = ("not accepted: " + "; ".join(record["rejections"])
                             if accepted is None else check(accepted))
        turns.append(record)
        if accepted is None or record["failure"]:
            break
    return {"case": case["name"], "command": case["command"], "turns": turns,
            "passed": len(turns) == len(case["turns"])
            and all(not t["failure"] for t in turns)}


def _resolve(model: str | None) -> str:
    if model:
        return str(Path(model).expanduser().resolve())
    from huggingface_hub import snapshot_download
    return snapshot_download(repo_id=MODEL_ID, local_files_only=True)


def _emitted(turn: dict | None) -> str:
    if turn is None:
        return "—"
    steps = [step for step in turn.get("steps") or []
             if step.get("do") != "wait_frontmost"]
    shown = []
    for step in steps:
        body = {k: v for k, v in step.items()
                if k in ("index", "label", "state", "path", "text", "assert")}
        shown.append(step["do"] + json.dumps(body, ensure_ascii=False))
    return (" ; ".join(shown) or "(no steps)") + (
        " done" if turn.get("done") else "")


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model", help="local snapshot path "
                        f"(default: cached {MODEL_ID})")
    parser.add_argument("--json", action="store_true",
                        help="print one JSON record per case")
    parser.add_argument("--case", action="append", default=[],
                        help="run only cases whose name contains this "
                        "(repeatable)")
    args = parser.parse_args()
    cases = [case for case in CASES
             if not args.case or any(part in case["name"]
                                     for part in args.case)]
    path = _resolve(args.model)
    engine = CleanupProcess(MODEL_ID, local_model_path=path)
    started = time.perf_counter()
    await engine.load_async()
    load_ms = int((time.perf_counter() - started) * 1000)
    records = []
    try:
        for case in cases:
            record = await run_case(engine, case)
            records.append(record)
            if args.json:
                print(json.dumps(record, ensure_ascii=False), flush=True)
    finally:
        await engine.aclose()

    print(f"\nmodel {MODEL_ID} ({path}) load {load_ms} ms\n")
    print("| case | turn | emitted (validated) | path / rejections | "
          "calls | turn ms |")
    print("|---|---|---|---|---|---|")
    controller_walls = []
    for record in records:
        for turn in record["turns"]:
            calls = ", ".join(
                f"{call['kind']}:{call['wall_ms']}"
                for call in turn["calls"])
            controller_walls += [call["wall_ms"] for call in turn["calls"]
                                 if call["kind"] == "controller"]
            note = turn.get("path", "rejected")
            if turn["rejections"]:
                note += " — " + " | ".join(
                    r[:160] for r in turn["rejections"])
            status = "PASS" if not turn["failure"] else f"FAIL ({turn['failure']})"
            print(f"| {record['case']} | {turn['number']} | "
                  f"{_emitted(turn.get('turn'))} | {note} | {calls} | "
                  f"{turn['turn_ms']} {status} |")
    passed = sum(record["passed"] for record in records)
    print(f"\n{passed}/{len(records)} cases passed; controller call p50 "
          f"{statistics.median(controller_walls) if controller_walls else 0:.0f}"
          " ms")
    return 0 if passed == len(records) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
