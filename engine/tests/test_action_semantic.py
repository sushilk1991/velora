"""Action Mode semantic actions: set_ui, menu_item, find_ui.

Contract: docs/plans/2026-11-02-action-mode-semantic-actions.md. The Swift
validator (`Sources/Velora/Actions/ActionPlan.swift`) refuses the same plans;
the word lists are mirrored and contract-tested below.

Every refusal added for these verbs has a matching test that the legitimate
plan still passes: a deterministic layer that refuses too much is its own bug.
"""

# ruff: noqa: F811

import json
from pathlib import Path

import pytest
from test_actions import (  # noqa: F401 — fixture + helper reuse
    FakePlanner, connect, engine, local_transfers, observation, send_observe,
    send_start, turn,
)

from velora_engine import action_fastpath, actions


# ---------------------------------------------------------------- fixtures

SIDEBAR_ROWS = ("Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound",
                "Focus", "Lock Screen")


def settings_sidebar(selected="Wi-Fi", snapshot_id="set-1"):
    """System Settings: sidebar rows expose no AXPress, only set=selected."""
    elements = [
        {"index": 0, "depth": 0, "role": "AXWindow", "label": selected,
         "frame": {"x": 0, "y": 0, "w": 900, "h": 600}},
        {"index": 1, "parent_index": 0, "depth": 1, "role": "AXOutline",
         "label": "Sidebar", "frame": {"x": 0, "y": 40, "w": 220, "h": 560}},
    ]
    for offset, name in enumerate(SIDEBAR_ROWS):
        row = {"index": 2 + offset, "parent_index": 1, "depth": 2,
               "role": "AXRow", "label": name,
               "frame": {"x": 0, "y": 50 + offset * 30, "w": 220, "h": 30}}
        if name == selected:
            row["selected"] = True
        else:
            row["set"] = ["selected"]
        elements.append(row)
    elements += [
        {"index": 20, "parent_index": 0, "depth": 1, "role": "AXGroup",
         "label": "Content", "frame": {"x": 230, "y": 40, "w": 670, "h": 560}},
        {"index": 21, "parent_index": 20, "depth": 2, "role": "AXHeading",
         "label": selected, "frame": {"x": 240, "y": 50, "w": 300, "h": 30}},
    ]
    return {
        "id": snapshot_id, "source": "native", "complete": True,
        "app_name": "System Settings", "bundle_id": "com.apple.systempreferences",
        "window_title": selected, "window_id": 501, "elements": elements,
    }


def focus_pane(toggle="off", snapshot_id="dnd-1"):
    """A Focus pane: switches, a disclosure triangle, a destructive switch."""
    opposite = {"on": ["off"], "off": ["on"], "mixed": ["on", "off"]}
    return {
        "id": snapshot_id, "source": "native", "complete": True,
        "app_name": "System Settings", "bundle_id": "com.apple.systempreferences",
        "window_title": "Focus", "window_id": 501,
        "elements": [
            {"index": 0, "depth": 0, "role": "AXWindow", "label": "Focus"},
            {"index": 1, "parent_index": 0, "depth": 1, "role": "AXGroup",
             "label": "Focus"},
            {"index": 2, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
             "label": "Do Not Disturb", "actions": ["AXPress"],
             "toggle": toggle, "set": opposite[toggle]},
            {"index": 3, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
             "label": "Enable notifications", "actions": ["AXPress"],
             "toggle": "off", "set": ["on"]},
            {"index": 4, "parent_index": 1, "depth": 2,
             "role": "AXDisclosureTriangle", "label": "Schedules",
             "actions": ["AXPress"], "expanded": False, "set": ["expanded"]},
            {"index": 5, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
             "label": "Delete history automatically", "actions": ["AXPress"],
             "toggle": "off", "set": ["on"]},
            {"index": 6, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
             "label": "Play sound for notifications", "actions": ["AXPress"],
             "toggle": "on", "set": ["off"]},
            {"index": 7, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
             "label": "Pause", "actions": ["AXPress"],
             "toggle": "off", "set": ["on"]},
        ],
    }


FINDER_MENU = {
    "complete": True,
    "top": ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
    "items": [{"path": path} for path in (
        ["Finder", "Settings…"],
        ["File", "New Finder Window"],
        ["File", "New Folder"],
        ["File", "Close Window"],
        ["File", "Save As…"],
        ["Edit", "Copy"],
        ["Edit", "Paste Item"],
        ["Edit", "Undo Move"],
        ["View", "as Icons"],
        ["View", "Show Sidebar"],
        ["View", "Show Toolbar"],
        ["View", "Show Path Bar"],
        ["View", "Show Status Bar"],
        ["View", "Sort By", "Name"],
        ["Go", "Back"],
        ["Go", "Recents"],
        ["Go", "Documents"],
        ["Go", "Desktop"],
        ["Go", "Downloads"],
        ["Window", "Minimize"],
    )],
}


def finder(menu=None, *, complete=True, source="native", snapshot_id="fin-1"):
    return {
        "id": snapshot_id, "source": source, "complete": complete,
        "app_name": "Finder", "bundle_id": "com.apple.finder",
        "window_title": "Recents", "window_id": 77,
        "elements": [
            {"index": 0, "depth": 0, "role": "AXWindow", "label": "Recents"},
            {"index": 1, "parent_index": 0, "depth": 1, "role": "AXButton",
             "label": "Back", "actions": ["AXPress"]},
        ],
        "menu_bar": FINDER_MENU if menu is None else menu,
    }


def busy_slack(snapshot_id="busy-1"):
    """A window too big for the 500-element snapshot: complete=false."""
    return {
        "id": snapshot_id, "source": "native", "complete": False,
        "app_name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap",
        "window_title": "Slack", "window_id": 88,
        "elements": [
            {"index": 0, "depth": 0, "role": "AXWindow", "label": "Slack"},
            *[{"index": i, "parent_index": 0, "depth": 1, "role": "AXGroup",
               "label": f"message {i}"} for i in range(1, 6)],
            {"index": 9, "parent_index": 0, "depth": 1, "role": "AXRow",
             "label": "random", "set": ["selected"]},
        ],
    }


def found_general(snapshot_id="find-1", *, complete=True, selected=False):
    """The find_ui result for "general": matches plus their ancestors."""
    row = {"index": 3, "parent_index": 2, "depth": 2, "role": "AXRow",
           "label": "general"}
    if selected:
        row["selected"] = True
    else:
        row["set"] = ["selected"]
    return {
        "id": snapshot_id, "source": "native", "complete": complete,
        "app_name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap",
        "window_title": "Slack", "window_id": 88,
        "scope": {"kind": "find", "query": "general", "matches": 2},
        "elements": [
            {"index": 0, "depth": 0, "role": "AXWindow", "label": "Slack"},
            {"index": 2, "parent_index": 0, "depth": 1, "role": "AXOutline",
             "label": "Channels"},
            row,
            {"index": 5, "parent_index": 0, "depth": 1, "role": "AXTextArea",
             "label": "Message to general", "focused": True,
             "actions": ["AXFocus"]},
            {"index": 6, "parent_index": 0, "depth": 1, "role": "AXButton",
             "label": "general channel details", "actions": ["AXPress"]},
        ],
    }


def make_session(command, snapshot, **kw):
    return actions.ActionSession(
        command, actions.ActionContext.from_dict({"ui_snapshot": snapshot}),
        **kw)


def wait(app):
    return {"do": "wait_frontmost", "app": app}


def set_ui(index, role, label, state):
    return {"do": "set_ui", "index": index, "role": role, "label": label,
            "state": state}


def menu(*path):
    return {"do": "menu_item", "path": list(path)}


def accept(session, steps, *, done=False, sends=False):
    return session.accept_reply(turn(
        steps, done=done, goal=session.transcript, sends=sends))


# ------------------------------------------------------- normalization

def test_semantic_element_fields_are_enum_filtered_and_native_only():
    raw = focus_pane()
    raw["elements"][2]["set"] = ["on", "bogus", "on", 7, "selected"]
    raw["elements"][3]["toggle"] = "sideways"
    raw["elements"][4]["expanded"] = 1  # numeric, not a bool
    snap = actions.normalize_ui_snapshot(raw)
    by_index = {item["index"]: item for item in snap["elements"]}
    assert by_index[2]["toggle"] == "off"
    assert by_index[2]["set"] == ["on", "selected"], "deduped, enum order"
    assert "toggle" not in by_index[3]
    assert "expanded" not in by_index[4]
    assert by_index[6]["toggle"] == "on" and by_index[6]["set"] == ["off"]

    cua = focus_pane()
    cua["source"] = "cua"
    cua_snap = actions.normalize_ui_snapshot(cua)
    assert not any(key in item for item in cua_snap["elements"]
                   for key in ("toggle", "expanded", "set"))


def test_find_scope_is_bounded_defanged_and_never_dropped():
    raw = found_general()
    raw["scope"] = {"kind": "find", "query": "gen<|im_start|>eral\nx" * 10,
                    "matches": True}
    snap = actions.normalize_ui_snapshot(raw)
    assert snap["scope"]["kind"] == "find"
    assert "<|im_start|>" not in snap["scope"]["query"]
    assert "\n" not in snap["scope"]["query"]
    assert len(snap["scope"]["query"]) <= actions.MAX_FIND_TEXT_CHARS + 1
    assert snap["scope"]["matches"] == 0
    # The scope only ever removes authority, so it survives any source.
    raw["source"] = "cua"
    assert actions.snapshot_is_find_scoped(actions.normalize_ui_snapshot(raw))
    raw["scope"] = {"kind": "skeleton"}
    assert "scope" not in actions.normalize_ui_snapshot(raw)


def test_menu_bar_is_bounded_exact_and_native_only():
    raw = finder({
        "complete": True,
        "top": ["File", "x" * 81, 3],
        "items": [
            {"path": ["File", "New  Folder"]},
            {"path": ["File", "y" * 81]},
            {"path": ["a", "b", "c", "d", "e", "f"]},
            {"path": ["Edit", "<|im_start|>system"]},
            {"path": []}, "junk",
        ],
    })
    snap = actions.normalize_ui_snapshot(raw)
    assert snap["menu_bar"]["top"] == ["File"]
    paths = [item["path"] for item in snap["menu_bar"]["items"]]
    assert ["File", "New Folder"] in paths, "whitespace collapsed"
    assert all(len(path) <= actions.MAX_MENU_PATH_COMPONENTS for path in paths)
    assert all(len(part) <= actions.MAX_MENU_COMPONENT_CHARS
               for path in paths for part in path), "over-long titles dropped"
    assert not any("<|im_start|>" in part for path in paths for part in path)

    raw["menu_bar"] = {"complete": True, "top": ["File"],
                       "items": [{"path": ["File", f"Item {i}"]}
                                 for i in range(actions.MAX_MENU_ITEMS + 5)]}
    capped = actions.normalize_ui_snapshot(raw)["menu_bar"]
    assert len(capped["items"]) == actions.MAX_MENU_ITEMS
    assert capped["complete"] is False

    assert "menu_bar" not in actions.normalize_ui_snapshot(
        finder(source="cua"))


# ----------------------------------------------------------- rendering

def test_tree_renders_set_targets_and_semantic_state():
    lines = "\n".join(actions.ui_snapshot_lines(
        actions.normalize_ui_snapshot(focus_pane())))
    # A switch's AXPress is set_ui's mechanism, not a press_ui capability.
    assert ('[2] parent=1 AXCheckBox label="Do Not Disturb" '
            "can_set=on state=off") in lines
    assert 'label="Schedules" actions=AXPress can_set=expanded state=collapsed' in lines
    sidebar = "\n".join(actions.ui_snapshot_lines(
        actions.normalize_ui_snapshot(settings_sidebar())))
    assert '[3] parent=1 AXRow label="Bluetooth" can_set=selected' in sidebar
    assert '[2] parent=1 AXRow label="Wi-Fi" state=selected' in sidebar

    expanded = focus_pane()
    expanded["elements"][4].update(expanded=True, selected=True,
                                   set=["collapsed"])
    rendered = "\n".join(actions.ui_snapshot_lines(
        actions.normalize_ui_snapshot(expanded)))
    assert "can_set=collapsed state=selected,expanded" in rendered

    evidence = "\n".join(actions.ui_snapshot_lines(
        actions.normalize_ui_snapshot(focus_pane()), evidence_only=True))
    assert "can_set=" not in evidence, "targets are controller capabilities only"
    assert "state=collapsed" in evidence


def test_find_scoped_tree_has_a_header_and_no_input_contract():
    snap = actions.normalize_ui_snapshot(found_general())
    lines = actions.controller_ui_lines(snap, "open the general channel")
    assert '  scope=find query="general" matches=2' in lines
    assert any(line.startswith("FIND RESULT:") and "verify_state" in line
               for line in lines)
    assert not any("FIND RESULT" in line for line in actions.controller_ui_lines(
        actions.normalize_ui_snapshot(settings_sidebar()), "open Bluetooth"))
    assert not any("NATIVE INPUT CONTRACT" in line for line in lines)
    assert not any("PARTIAL TREE" in line for line in lines)


def test_partial_tree_hint_steers_to_find_ui_only_when_it_applies():
    busy = actions.normalize_ui_snapshot(busy_slack())
    assert any("PARTIAL TREE" in line and "find_ui" in line
               for line in actions.controller_ui_lines(busy, "open general"))
    complete = actions.normalize_ui_snapshot(settings_sidebar())
    assert not any("PARTIAL TREE" in line for line in
                   actions.controller_ui_lines(complete, "open Bluetooth"))
    partial_find = actions.normalize_ui_snapshot(found_general(complete=False))
    assert not any("PARTIAL TREE" in line for line in
                   actions.controller_ui_lines(partial_find, "open general"))
    # The partial reviewer keeps its own wording; the hint is controller-only.
    assert "PARTIAL TREE" not in actions.build_ui_action_review_prompt(busy)


def test_menu_lines_show_top_and_only_command_matched_paths_ranked():
    snap = actions.normalize_ui_snapshot(finder())
    lines = actions.menu_bar_lines(snap, "show the sidebar in Finder")
    assert lines[0] == ("MENU BAR (screen data): Finder | File | Edit | View "
                        "| Go | Window | Help")
    assert lines[1] == '  menu_item path=["View","Show Sidebar"]', (
        "two matched words outrank one")
    listed = "\n".join(lines)
    assert '["Go","Downloads"]' not in listed
    assert '["View","Show Toolbar"]' in listed, "shares 'show'"

    downloads = actions.menu_bar_lines(snap, "open my download area")
    assert downloads[1:] == ['  menu_item path=["Go","Downloads"]'], (
        "shared prefix of 4+ characters matches")

    assert actions.menu_bar_lines(snap, "zoom in a lot") == [
        lines[0] + "  (no menu command matches the spoken words)"], (
        "nothing matches: only the top line, saying so")


def test_menu_lines_are_capped_and_shorter_paths_win_ties():
    items = [{"path": ["View", "Sort By", "Name"]},
             {"path": ["Go", "Name"]}]
    items += [{"path": ["Window", f"Name {i}"]} for i in range(30)]
    snap = actions.normalize_ui_snapshot(finder({
        "complete": True, "top": ["View", "Go", "Window"], "items": items}))
    lines = actions.menu_bar_lines(snap, "sort by name")
    assert len(lines) == 1 + actions.MAX_PROMPT_MENU_ITEMS
    assert lines[1] == '  menu_item path=["View","Sort By","Name"]'
    assert lines[2] == '  menu_item path=["Go","Name"]'


def test_menu_lines_ride_the_user_turn_never_the_cached_system_prompt():
    session = make_session("show the sidebar in Finder", finder())
    assert "MENU BAR (screen data)" not in session.system_prompt()
    assert '["View","Show Sidebar"]' in session.first_message()
    accept(session, [wait("Finder"), menu("View", "Show Sidebar")])
    message = session.observation_message(observation(
        frontmost_app="Finder", ui_snapshot=finder(snapshot_id="fin-2")))
    assert '["View","Show Sidebar"]' in message
    assert "MENU BAR (screen data)" not in session.system_prompt()


def test_planner_prompt_teaches_the_three_step_shapes():
    rules = actions.PLANNER_RULES
    assert '{"do":"set_ui","index":12' in rules
    assert '{"do":"menu_item","path":["<menu>","<item>"]}' in rules
    # A concrete example path got copied verbatim into an unrelated app's
    # turn on the real model (2026-11-02 bench): placeholders only.
    assert '"path":["View","Show Sidebar"]' not in rules
    assert '{"do":"find_ui","text":' in rules
    assert "written_text|selected|on|off" in rules


# ---------------------------------------------------------------- set_ui

def test_set_ui_selects_a_sidebar_row_named_by_the_command():
    session = make_session("open Bluetooth settings", settings_sidebar())
    out = accept(session, [wait("System Settings"),
                           set_ui(3, "AXRow", "Bluetooth", "selected")])
    assert out["steps"][1] == {
        "do": "set_ui", "snapshot": "set-1", "index": 3, "role": "AXRow",
        "label": "Bluetooth", "state": "selected"}
    assert out["done"] is False
    assert session.direct_goal_check_pending is True


def test_set_ui_switch_labels_name_settings_not_commits():
    for index, label, state in (
            (2, "Do Not Disturb", "on"),
            (3, "Enable notifications", "on"),
            (6, "Play sound for notifications", "off")):
        session = make_session(f"turn {state} {label}", focus_pane())
        out = accept(session, [wait("System Settings"),
                               set_ui(index, "AXCheckBox", label, state)])
        assert out["steps"][-1]["state"] == state
    # The exemption is only for on/off: the full denylist still guards
    # every other target and every non-exempt commit word.
    session = make_session("turn on delete history automatically", focus_pane())
    with pytest.raises(actions.PlanError, match="committing control"):
        accept(session, [wait("System Settings"),
                         set_ui(5, "AXCheckBox",
                                "Delete history automatically", "on")])
    # Selection is navigation: a row whose NAME holds a commit word
    # ("Lock Screen") is still a destination, not a commit.
    session = make_session("open Lock Screen settings", settings_sidebar())
    out = accept(session, [wait("System Settings"),
                           set_ui(8, "AXRow", "Lock Screen", "selected")])
    assert out["steps"][-1]["state"] == "selected"


def test_set_ui_expands_a_disclosure_triangle():
    session = make_session("show the Focus schedules", focus_pane())
    out = accept(session, [wait("System Settings"),
                           set_ui(4, "AXDisclosureTriangle", "Schedules",
                                  "expanded")])
    assert out["steps"][-1]["state"] == "expanded"


def test_set_ui_binds_exact_offered_state_role_and_label():
    session = make_session("turn on Do Not Disturb", focus_pane())
    for bad, error in (
            (set_ui(2, "AXCheckBox", "Do Not Disturb", "selected"),
             "does not offer state selected"),
            (set_ui(2, "AXCheckBox", "Do Not Disturb", "maybe"),
             "'state' must be one of"),
            (set_ui(2, "AXButton", "Do Not Disturb", "on"), "role changed"),
            (set_ui(2, "AXCheckBox", "Wi-Fi", "on"), "label changed"),
            (set_ui(99, "AXCheckBox", "Do Not Disturb", "on"),
             "not in that snapshot"),
            (set_ui(2, "AXCheckBox", "DN", "on"), "too short")):
        with pytest.raises(actions.PlanError, match=error):
            accept(session, [wait("System Settings"), bad])
    already = make_session("turn on Do Not Disturb", focus_pane(toggle="on"))
    with pytest.raises(actions.PlanError, match="already on.*verify_state"):
        accept(already, [wait("System Settings"),
                         set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])
    mixed = make_session("turn off Do Not Disturb", focus_pane(toggle="mixed"))
    assert accept(mixed, [wait("System Settings"),
                          set_ui(2, "AXCheckBox", "Do Not Disturb", "off")])

    disabled = focus_pane()
    disabled["elements"][2]["enabled"] = False
    with pytest.raises(actions.PlanError, match="disabled"):
        accept(make_session("turn on Do Not Disturb", disabled),
               [wait("System Settings"),
                set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])


def test_set_ui_needs_a_complete_native_tree_and_a_checkpoint():
    partial = focus_pane()
    partial["complete"] = False
    with pytest.raises(actions.PlanError, match="incomplete.*find_ui"):
        accept(make_session("turn on Do Not Disturb", partial),
               [wait("System Settings"),
                set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])
    cua = focus_pane()
    cua["source"] = "cua"
    with pytest.raises(actions.PlanError, match="source=native"):
        accept(make_session("turn on Do Not Disturb", cua),
               [wait("System Settings"),
                set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])

    session = make_session("turn on Do Not Disturb", focus_pane())
    with pytest.raises(actions.PlanError, match="focus checkpoint"):
        actions.validate_plan(
            {"sends": False,
             "steps": [set_ui(2, "AXCheckBox", "Do Not Disturb", "on")]},
            state=session.state)
    # The session inserts the checkpoint itself on a complete native tree.
    out = accept(session, [set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])
    assert [step["do"] for step in out["steps"]] == ["wait_frontmost", "set_ui"]


def test_set_ui_and_menu_item_end_their_batch_like_press_ui():
    session = make_session("turn on Do Not Disturb", focus_pane())
    with pytest.raises(actions.PlanError, match="fresh observation"):
        accept(session, [wait("System Settings"),
                         set_ui(2, "AXCheckBox", "Do Not Disturb", "on"),
                         {"do": "pause", "ms": 100}])
    finder_session = make_session("show the sidebar", finder())
    with pytest.raises(actions.PlanError, match="fresh observation"):
        accept(finder_session, [wait("Finder"), menu("View", "Show Sidebar"),
                                {"do": "pause", "ms": 100}])
    for barrier in (set_ui(2, "AXCheckBox", "Do Not Disturb", "on"),
                    menu("View", "Show Sidebar"),
                    {"do": "find_ui", "text": "general"}):
        bounded = actions.bound_observation_turn({
            "steps": [wait("System Settings"), barrier,
                      {"do": "pause", "ms": 100}], "done": True})
        assert bounded["steps"][-1] == barrier and bounded["done"] is False


def test_set_ui_leaves_pending_text_unverified_like_press_ui():
    session = make_session("turn on Do Not Disturb", focus_pane())
    session.state.pending_text = True
    session.state.pending_value = "hello"
    session.state.unverified_text = False
    accept(session, [wait("System Settings"),
                     set_ui(2, "AXCheckBox", "Do Not Disturb", "on")])
    assert session.state.unverified_text is True
    assert session.state.pending_value == ""
    assert session.state.pending_ui_index is None


def test_press_ui_cannot_flip_a_switch_blindly():
    session = make_session("turn on Do Not Disturb", focus_pane())
    with pytest.raises(actions.PlanError, match="is a switch.*set_ui"):
        accept(session, [wait("System Settings"),
                         {"do": "press_ui", "index": 2, "role": "AXCheckBox",
                          "label": "Do Not Disturb"}])
    # Controls without a reported toggle state press as before.
    plain = focus_pane()
    plain["elements"].append({
        "index": 8, "parent_index": 1, "depth": 2, "role": "AXCheckBox",
        "label": "Show Focus status", "actions": ["AXPress"]})
    assert accept(make_session("show Focus status", plain),
                  [wait("System Settings"),
                   {"do": "press_ui", "index": 8, "role": "AXCheckBox",
                    "label": "Show Focus status"}])
    disclosure = make_session("show the Focus schedules", focus_pane())
    assert accept(disclosure, [wait("System Settings"),
                               {"do": "press_ui", "index": 4,
                                "role": "AXDisclosureTriangle",
                                "label": "Schedules"}])


def test_press_on_a_set_only_row_points_to_set_ui_without_a_review():
    session = make_session("open the general channel", found_general())
    press = {"do": "press_ui", "index": 3, "role": "AXRow", "label": "general"}
    assert not actions.turn_requires_ui_action_review(
        {"sends": False, "steps": [wait("Slack"), press]}, session)
    with pytest.raises(actions.PlanError, match="cannot be pressed.*set_ui"):
        accept(session, [wait("Slack"), press])
    # Ordinary presses keep the established reviewer-first order.
    details = {"do": "press_ui", "index": 6, "role": "AXButton",
               "label": "general channel details"}
    assert actions.turn_requires_ui_action_review(
        {"sends": False, "steps": [wait("Slack"), details]},
        make_session("show general channel details", found_general()))


def test_checkpoints_in_front_of_a_state_proof_are_dropped():
    session = make_session("turn on Do Not Disturb", focus_pane(toggle="on"))
    session.turns_used = 1
    out = accept(session, [wait("System Settings"),
                           {"do": "verify_context",
                            "expect": ["Do Not Disturb"]},
                           {"do": "verify_state", "index": 2,
                            "assert": "on"}], done=True)
    assert [step["do"] for step in out["steps"]] == ["verify_state"]
    assert out["done"] is True
    # Anything that acts is still refused next to a state proof.
    with pytest.raises(actions.PlanError, match="sole terminal step"):
        accept(session, [{"do": "key", "key": "tab"},
                         {"do": "verify_state", "index": 2,
                          "assert": "on"}], done=True)


def test_media_commands_still_require_the_media_capability():
    session = make_session("pause music", focus_pane())
    with pytest.raises(actions.PlanError, match="media_control"):
        accept(session, [wait("Music"),
                         set_ui(7, "AXCheckBox", "Pause", "on")])


# ------------------------------------------------------------- menu_item

def test_menu_item_binds_to_the_exact_listed_path():
    session = make_session("show the sidebar in Finder", finder())
    out = accept(session, [wait("Finder"), menu("view", "show  sidebar")])
    assert out["steps"][-1] == {"do": "menu_item",
                                "path": ["View", "Show Sidebar"]}
    assert session.direct_goal_check_pending is True

    written = make_session("open the downloads folder", finder())
    out = accept(written, [wait("Finder"),
                           {"do": "menu_item", "path": "Go > Downloads"}])
    assert out["steps"][-1]["path"] == ["Go", "Downloads"]

    nested = make_session("sort by name", finder())
    out = accept(nested, [wait("Finder"), menu("View", "Sort By", "Name")])
    assert out["steps"][-1]["path"] == ["View", "Sort By", "Name"]


def test_menu_item_not_found_lists_the_real_children_for_the_repair():
    session = make_session("show the sidebar", finder())
    with pytest.raises(actions.PlanError) as caught:
        accept(session, [wait("Finder"), menu("View", "Sidebar")])
    message = str(caught.value)
    assert 'under "View" the menu has:' in message
    assert '"Show Sidebar"' in message and '"Go"' not in message
    with pytest.raises(actions.PlanError, match="the menu bar has: "
                       '"Finder", "File"'):
        accept(session, [wait("Finder"), menu("Format", "Show Fonts")])
    with pytest.raises(actions.PlanError, match='under "View" the menu has'):
        accept(session, [wait("Finder"), menu("View")])
    note = actions.turn_repair_note(message)
    assert '"Show Sidebar"' in note
    assert len(actions.turn_repair_note("x" * 1_000)) > 400


def test_menu_item_refuses_commits_and_content_edits():
    session = make_session("tidy up this folder", finder())
    for path in (("File", "Close Window"), ("Edit", "Paste Item"),
                 ("Edit", "Undo Move"), ("Edit", "Cut"), ("Edit", "Redo"),
                 ("File", "Move to Trash")):
        with pytest.raises(actions.PlanError, match="committing or editing"):
            accept(session, [wait("Finder"), menu(*path)])
    # A spelling that hides the commit word still matches a listed item
    # whose words carry it; the listed form is checked too.
    with pytest.raises(actions.PlanError, match="committing or editing"):
        accept(session, [wait("Finder"), menu("File", "SaveAs")])
    assert accept(session, [wait("Finder"), menu("Edit", "Copy")])


def test_menu_item_shape_checkpoint_source_and_app_rules():
    session = make_session("show the sidebar", finder())
    for bad in (menu(), menu("View", ""), menu(*["View"] * 6),
                {"do": "menu_item", "path": 3}):
        with pytest.raises(actions.PlanError, match="'path' must be"):
            accept(session, [wait("Finder"), bad])
    with pytest.raises(actions.PlanError, match="focus checkpoint"):
        actions.validate_plan(
            {"sends": False, "steps": [menu("View", "Show Sidebar")]},
            state=session.state)
    with pytest.raises(actions.PlanError, match="belongs to Finder"):
        accept(session, [wait("Safari"), menu("View", "Show Sidebar")])
    with pytest.raises(actions.PlanError, match="source=native"):
        accept(make_session("show the sidebar", finder(source="cua")),
               [wait("Finder"), menu("View", "Show Sidebar")])

    # The window tree may be partial: the command comes from the menu bar.
    partial = make_session("show the sidebar", finder(complete=False))
    out = accept(partial, [menu("View", "Show Sidebar")])
    assert [step["do"] for step in out["steps"]] == [
        "wait_frontmost", "menu_item"]


# --------------------------------------------------------------- find_ui

def test_find_ui_searches_a_partial_window_without_a_checkpoint():
    session = make_session("open the general channel in Slack", busy_slack())
    out = accept(session, [{"do": "find_ui", "text": " general "}])
    assert out == {"steps": [{"do": "find_ui", "text": "general"}],
                   "done": False}
    assert session.direct_goal_check_pending is False
    assert actions.turn_requires_ui_action_review(
        {"steps": out["steps"]}, session) is False


def test_find_ui_bounds_and_refusals():
    session = make_session("open the general channel", busy_slack())
    for text, error in (("ge", "3\\+ letters"), ("...", "3\\+ letters"),
                        ("x" * 61, "over 60")):
        with pytest.raises(actions.PlanError, match=error):
            accept(session, [{"do": "find_ui", "text": text}])
    with pytest.raises(actions.PlanError, match="before reporting done"):
        accept(session, [{"do": "find_ui", "text": "general"}], done=True)
    with pytest.raises(actions.PlanError, match="fresh observation"):
        accept(session, [{"do": "find_ui", "text": "general"},
                         wait("Slack")])
    cua = busy_slack()
    cua["source"] = "cua"
    with pytest.raises(actions.PlanError, match="source=native"):
        accept(make_session("open general", cua),
               [{"do": "find_ui", "text": "general"}])
    # Read-only: carried text state is untouched.
    session.state.pending_text = True
    session.state.unverified_text = False
    accept(session, [{"do": "find_ui", "text": "general"}])
    assert session.state.pending_text is True
    assert session.state.unverified_text is False


def test_find_scoped_tree_grants_navigation_only():
    session = make_session("open the general channel in Slack", found_general())
    out = accept(session, [wait("Slack"),
                           set_ui(3, "AXRow", "general", "selected")])
    assert out["steps"][-1]["do"] == "set_ui"

    pressing = make_session("open general channel details", found_general())
    assert accept(pressing, [wait("Slack"),
                             {"do": "press_ui", "index": 6,
                              "role": "AXButton",
                              "label": "general channel details"}])

    typing = make_session("type hello in general", found_general())
    assert actions.turn_requires_target_verifier(
        {"steps": [{"do": "type_text", "text": "hello", "index": 5}]},
        typing) is False
    for verb in ("type_text", "paste_text", "search_text"):
        with pytest.raises(actions.PlanError, match="navigation only"):
            accept(typing, [wait("Slack"),
                            {"do": verb, "text": "hello", "index": 5}])

    partial = make_session("open the general channel",
                           found_general(complete=False))
    with pytest.raises(actions.PlanError, match="incomplete"):
        accept(partial, [wait("Slack"),
                         set_ui(3, "AXRow", "general", "selected")])


def test_find_scoped_tree_is_never_completion_or_recipient_evidence():
    snap = actions.normalize_ui_snapshot(found_general(selected=True))
    assert actions.goal_snapshot_can_verify(snap) is False
    evidence = {"index": 3, "role": "AXRow", "label": "general"}
    with pytest.raises(actions.PlanError, match="runtime-verifiable"):
        actions.parse_goal_verdict(json.dumps(
            {"safe": True, "target": "general", "evidence": evidence}), snap)
    review = actions.parse_ui_action_review(json.dumps(
        {"safe": False, "goal_met": True, "target": "general",
         "evidence": evidence}), snap)
    assert review["goal_met"] is False
    with pytest.raises(actions.PlanError, match="navigation only"):
        actions.parse_target_verdict(json.dumps({
            "safe": True, "target": "general",
            "evidence": {"index": 5, "role": "AXTextArea",
                         "label": "Message to general"}}), snap)
    session = make_session("open general", found_general(selected=True))
    session.state.allowed_ui_attestation = "tok"
    with pytest.raises(actions.PlanError, match="cannot attest"):
        actions.validate_plan({"sends": False, "steps": [
            wait("Slack"),
            {"do": "verify_ui", "snapshot": "find-1", "index": 3,
             "role": "AXRow", "label": "general", "target": "general",
             "attestation": "tok", "purpose": "goal"}]},
            state=session.state)
    # A full-window tree compared against a prior find result proves only
    # active state, never "changed".
    full = actions.normalize_ui_snapshot(settings_sidebar())
    assert actions._goal_snapshots_comparable(full, snap) is False


def test_verify_state_finishes_on_a_find_scoped_tree():
    session = make_session("open the general channel in Slack",
                           found_general(selected=True))
    session.turns_used = 1  # a later turn, after the selection ran
    out = accept(session, [{"do": "verify_state", "index": 3,
                            "assert": "selected"}], done=True)
    assert out["done"] is True
    assert out["steps"][0]["assert"] == "selected"


# --------------------------------------------------------- verify_state

def test_verify_state_on_off_checks_a_switch_named_by_the_command():
    session = make_session("turn on Do Not Disturb", focus_pane(toggle="on"))
    session.turns_used = 1
    out = accept(session, [{"do": "verify_state", "index": 2,
                            "assert": "on"}], done=True)
    assert out["done"] is True and out["steps"][0]["assert"] == "on"
    off = make_session("turn off Do Not Disturb", focus_pane(toggle="on"))
    off.turns_used = 1
    with pytest.raises(actions.PlanError, match="off state is not"):
        accept(off, [{"do": "verify_state", "index": 2, "assert": "off"}],
               done=True)
    unnamed = make_session("turn on Wi-Fi", focus_pane(toggle="on"))
    unnamed.turns_used = 1
    with pytest.raises(actions.PlanError, match="not named"):
        accept(unnamed, [{"do": "verify_state", "index": 2, "assert": "on"}],
               done=True)


# --------------------------------------------------------- review gating

def test_selecting_a_named_collection_row_is_self_evident_navigation():
    session = make_session("open Bluetooth settings", settings_sidebar())
    parsed = {"sends": False, "steps": [
        wait("System Settings"), set_ui(3, "AXRow", "Bluetooth", "selected")]}
    assert actions.turn_is_self_evident_collection_navigation(parsed, session)
    assert not actions.turn_requires_ui_action_review(parsed, session)
    # The decided-model press check reads the same row through set_ui.
    check = action_fastpath.press_check(parsed, session)
    assert check is not None and "Bluetooth" in check.state

    unnamed = make_session("open my network settings", settings_sidebar())
    other = {"sends": False, "steps": [
        wait("System Settings"), set_ui(3, "AXRow", "Bluetooth", "selected")]}
    assert actions.turn_requires_ui_action_review(other, unnamed)


def test_explicit_on_off_command_for_the_named_switch_skips_review():
    toggle = {"sends": False, "steps": [
        wait("System Settings"), set_ui(2, "AXCheckBox", "Do Not Disturb", "on")]}
    for command in ("turn on Do Not Disturb", "switch Do Not Disturb on",
                    "please enable do not disturb"):
        assert not actions.turn_requires_ui_action_review(
            toggle, make_session(command, focus_pane())), command
    off = {"sends": False, "steps": [
        wait("System Settings"),
        set_ui(6, "AXCheckBox", "Play sound for notifications", "off")]}
    assert not actions.turn_requires_ui_action_review(
        off, make_session("turn off play sound for notifications",
                          focus_pane()))
    # Sharing one word with the label is not naming it.
    assert actions.turn_requires_ui_action_review(
        off, make_session("disable the notification sound", focus_pane()))

    for command in (
            "I want fewer interruptions",         # state not asked for
            "turn off Do Not Disturb",            # the opposite state
            "turn Do Not Disturb on then off",    # both: not explicit
            "check Do Not Disturb",               # "check" may mean look
            "turn on Wi-Fi"):                     # another switch
        assert actions.turn_requires_ui_action_review(
            toggle, make_session(command, focus_pane())), command
    assert actions.turn_requires_ui_action_review(
        {**toggle, "sends": True},
        make_session("turn on Do Not Disturb", focus_pane()))


def test_selecting_a_named_row_in_a_find_result_is_self_evident():
    session = make_session("open the general channel in Slack", found_general())
    parsed = {"sends": False, "steps": [
        wait("Slack"), set_ui(3, "AXRow", "general", "selected")]}
    assert actions.turn_is_self_evident_collection_navigation(parsed, session)
    assert not actions.turn_requires_ui_action_review(parsed, session)
    assert action_fastpath.press_check(parsed, session) is not None
    unnamed = make_session("open the random channel", found_general())
    assert actions.turn_requires_ui_action_review(parsed, unnamed)
    # Off a find result, a lone row still needs to be a collection member.
    lone = found_general()
    del lone["scope"]
    assert actions.turn_requires_ui_action_review(
        parsed, make_session("open the general channel in Slack", lone))


def test_switches_disclosure_and_unnamed_menu_paths_go_to_the_reviewer():
    session = make_session("I want fewer interruptions", focus_pane())
    toggle = {"sends": False, "steps": [
        wait("System Settings"), set_ui(2, "AXCheckBox", "Do Not Disturb", "on")]}
    assert actions.turn_requires_ui_action_review(toggle, session)
    message = actions.ui_action_review_message(
        session.transcript, session.goal, toggle["steps"])
    assert '"state":"on"' in message
    prompt = actions.build_ui_action_review_prompt(session.current_ui_snapshot)
    assert "set_ui puts the exact element" in prompt
    disclosure = make_session("show the Focus schedules", focus_pane())
    assert actions.turn_requires_ui_action_review(
        {"sends": False, "steps": [
            wait("System Settings"),
            set_ui(4, "AXDisclosureTriangle", "Schedules", "expanded")]},
        disclosure)

    named = make_session("show the sidebar in Finder", finder())
    assert not actions.turn_requires_ui_action_review(
        {"steps": [wait("Finder"), menu("View", "Show Sidebar")]}, named)
    # Naming the leaf is not asking for it: every spoken word must be the
    # menu command's own (filler and the app name aside).
    for command, path in (
            ("show the sidebar in Finder", ["View", "Show Sidebar"]),
            ("please show the path bar", ["View", "Show Path Bar"]),
            ("new folder", ["File", "New Folder"]),
            ("open the downloads folder", ["Go", "Downloads"]),
            ("make it bold", ["Format", "Font", "Bold"])):
        assert actions.command_is_menu_path(path, command, "Finder"), command
    for command, path in (
            ("copy the bold text", ["Format", "Font", "Bold"]),
            ("make the selected text upper case",
             ["Edit", "Transformations", "Make Upper Case"]),
            ("open the downloads folder", ["File", "New Folder"]),
            ("show it", ["View", "Show Sidebar"]),
            ("no new folder", ["File", "New Folder"]),
            ("don't show the sidebar", ["View", "Show Sidebar"])):
        assert not actions.command_is_menu_path(path, command, "Finder"), command
    unnamed = make_session("I want to see my folders on the left", finder())
    proposal = {"steps": [wait("Finder"), menu("View", "Show Sidebar")]}
    assert actions.turn_requires_ui_action_review(proposal, unnamed)
    assert '"path":["View","Show Sidebar"]' in actions.ui_action_review_message(
        unnamed.transcript, unnamed.goal, proposal["steps"])
    # An unlisted path is refused by validation, so no reviewer call.
    assert not actions.turn_requires_ui_action_review(
        {"steps": [wait("Finder"), menu("View", "Show Folders")]}, unnamed)
    partial_prompt = actions.build_ui_action_review_prompt(
        actions.normalize_ui_snapshot(finder(complete=False)))
    assert "menu_item runs the app's menu-bar command" in partial_prompt.replace(
        "A menu_item", "menu_item")


def test_goal_checks_follow_every_semantic_mutation():
    session = make_session("open Bluetooth", settings_sidebar())
    for steps, expected in (
            ([set_ui(3, "AXRow", "Bluetooth", "selected")], True),
            ([menu("View", "Show Sidebar")], True),
            ([{"do": "find_ui", "text": "Bluetooth"}], False)):
        assert actions.turn_needs_goal_check({"steps": steps}, session) is expected


def test_only_navigation_set_ui_can_be_replaced_by_completion_proof():
    snap = actions.normalize_ui_snapshot(settings_sidebar(selected="Bluetooth"))
    verdict = {"target": "Bluetooth", "evidence": {
        "snapshot": "set-1", "index": 21, "role": "AXHeading",
        "label": "Bluetooth"}}
    replaced = actions.attach_verified_goal(
        {"steps": [wait("System Settings"),
                   set_ui(3, "AXRow", "Bluetooth", "selected")]},
        verdict, snap, "tok", sends=False)
    assert [step["do"] for step in replaced["steps"]] == [
        "wait_frontmost", "verify_ui"]
    for mutation in (set_ui(2, "AXCheckBox", "Do Not Disturb", "on"),
                     menu("View", "Show Sidebar")):
        with pytest.raises(actions.PlanError, match="content-changing"):
            actions.attach_verified_goal(
                {"steps": [wait("System Settings"), mutation]},
                verdict, snap, "tok", sends=False)


# ------------------------------------------------------------- mirrors

def _swift_marker(marker):
    swift = (Path(__file__).resolve().parents[2]
             / "Sources/Velora/Actions/ActionPlan.swift")
    if not swift.exists():
        pytest.skip("swift sources not available (installed engine)")
    line = next((ln for ln in swift.read_text().splitlines() if marker in ln),
                None)
    assert line is not None, f"ActionPlan.swift has no `{marker.strip()}` line"
    return set(line.split(marker, 1)[1].split())


def test_toggle_exemptions_are_press_deny_words():
    assert actions.TOGGLE_EXEMPT_WORDS <= actions.PRESS_DENY_WORDS


def test_toggle_exempt_matches_the_swift_mirror():
    mirrored = _swift_marker("// toggle_exempt: ")
    assert mirrored == set(actions.TOGGLE_EXEMPT_WORDS), (
        f"engine-only: {set(actions.TOGGLE_EXEMPT_WORDS) - mirrored}, "
        f"swift-only: {mirrored - set(actions.TOGGLE_EXEMPT_WORDS)}")


def test_menu_deny_matches_the_swift_mirror():
    mirrored = _swift_marker("// menu_deny: ")
    assert mirrored == set(actions.MENU_DENY_WORDS), (
        f"engine-only: {set(actions.MENU_DENY_WORDS) - mirrored}, "
        f"swift-only: {mirrored - set(actions.MENU_DENY_WORDS)}")


# ------------------------------------------------- socket loop end to end

async def test_switch_toggle_is_set_then_finished_by_verify_state(engine):
    eng, sock = engine
    eng.cleanup = FakePlanner(
        turn([{"do": "open_app", "app": "System Settings"}],
             goal="turn on Do Not Disturb", sends=False),
        turn([wait("System Settings"),
              set_ui(2, "AXCheckBox", "Do Not Disturb", "on")]),
        turn([{"do": "verify_state", "index": 2, "assert": "on"}], done=True),
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="turn on Do Not Disturb",
                     context={"frontmost_app": "Finder",
                              "frontmost_bundle": "com.apple.finder",
                              "running_apps": ["Finder", "System Settings"]})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="System Settings", ui_snapshot=focus_pane(),
        executed=["open_app System Settings"]))
    evt = await client.recv_event("action_turn")
    assert evt["steps"][-1] == {
        "do": "set_ui", "snapshot": "dnd-1", "index": 2,
        "role": "AXCheckBox", "label": "Do Not Disturb", "state": "on"}
    assert len(eng.cleanup.calls) == 2, (
        "an explicit on/off command for the named switch needs no reviewer")
    await send_observe(client, observation=observation(
        frontmost_app="System Settings",
        ui_snapshot=focus_pane(toggle="on", snapshot_id="dnd-2"),
        executed=["open_app System Settings", "set_ui Do Not Disturb on"]))
    done = await client.recv_event("action_turn")
    assert done["done"] is True
    assert done["steps"] == [{
        "do": "verify_state", "snapshot": "dnd-2", "index": 2,
        "role": "AXCheckBox", "label": "Do Not Disturb", "assert": "on"}]


async def test_named_menu_command_skips_the_reviewer(engine):
    eng, sock = engine
    eng.cleanup = FakePlanner(
        turn([wait("Finder"), menu("View", "Show Sidebar")],
             goal="show the sidebar in Finder", sends=False),
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="show the sidebar in Finder",
                     context={"frontmost_app": "Finder",
                              "frontmost_bundle": "com.apple.finder",
                              "running_apps": ["Finder"],
                              "ui_snapshot": finder()})
    evt = await client.recv_event("action_turn")
    assert evt["steps"][-1] == {"do": "menu_item",
                                "path": ["View", "Show Sidebar"]}
    assert evt["done"] is False
    assert len(eng.cleanup.calls) == 1
    assert '["View","Show Sidebar"]' in eng.cleanup.calls[0][0]


async def test_busy_window_find_then_select(engine):
    eng, sock = engine
    eng.cleanup = FakePlanner(
        turn([{"do": "find_ui", "text": "general"}],
             goal="open the general channel in Slack", sends=False),
        turn([wait("Slack"), set_ui(3, "AXRow", "general", "selected")]),
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="open the general channel in Slack",
                     context={"frontmost_app": "Slack",
                              "frontmost_bundle": "com.tinyspeck.slackmacgap",
                              "running_apps": ["Slack"],
                              "ui_snapshot": busy_slack()})
    first = await client.recv_event("action_turn")
    assert first["steps"] == [{"do": "find_ui", "text": "general"}]
    assert "PARTIAL TREE" in eng.cleanup.calls[0][0]
    await send_observe(client, observation=observation(
        frontmost_app="Slack", ui_snapshot=found_general(),
        executed=["find_ui general"]))
    second = await client.recv_event("action_turn")
    assert second["steps"][-1] == {
        "do": "set_ui", "snapshot": "find-1", "index": 3, "role": "AXRow",
        "label": "general", "state": "selected"}
    assert 'scope=find query="general" matches=2' in eng.cleanup.calls[1][0]
    # A find result holds matches, never the row's peers; selecting the
    # command-named row there is self-evident navigation like a collection
    # row (the calibrated press check still runs on the production model).
    assert len(eng.cleanup.calls) == 2


async def test_refused_review_on_a_find_result_repairs_instead_of_ending(engine):
    """A complete find result can act but never proves completion, so the
    later-turn "refused review → completion check" path would end the action
    with nothing run. The controller gets the refusal as its repair."""
    eng, sock = engine
    details = {"do": "press_ui", "index": 6, "role": "AXButton",
               "label": "general channel details"}
    eng.cleanup = FakePlanner(
        turn([{"do": "find_ui", "text": "general"}],
             goal="open the general channel details", sends=False),
        turn([wait("Slack"), details]),
        json.dumps({"safe": False, "reason": "looks selected already"}),
        turn([wait("Slack"), details]),
        json.dumps({"safe": True}),
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="open the general channel details",
                     context={"frontmost_app": "Slack",
                              "frontmost_bundle": "com.tinyspeck.slackmacgap",
                              "running_apps": ["Slack"],
                              "ui_snapshot": busy_slack()})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="Slack", ui_snapshot=found_general(),
        executed=["find_ui general"]))
    evt = await client.recv_event("action_turn")
    assert evt["done"] is False
    assert evt["steps"][-1]["do"] == "press_ui"
    assert "looks selected already" in eng.cleanup.calls[3][1], (
        "the refusal reached the controller's repair note")
    assert len(eng.cleanup.calls) == 5


def test_a_joined_label_is_named_by_its_spoken_spellings():
    # "Wi-Fi" splits into words too short to share with the command; the
    # whole label equal to one to three joined command words still names
    # it. Mirrored by Swift `commandMentionsUILabel`.
    for command in ("turn on wi-fi", "turn on wifi", "turn wi fi on",
                    "turn on WiFi calling"):
        assert actions.command_mentions_ui_label("Wi-Fi", command), command
    assert not actions.command_mentions_ui_label("Wi-Fi", "turn on bluetooth")
    # Too short to bind by joining, and generic command words never bind.
    assert not actions.command_mentions_ui_label("A-B", "press a b")
    assert not actions.command_mentions_ui_label("Op-en", "open settings")
    # The shared-word rule is unchanged.
    assert actions.command_mentions_ui_label(
        "Enable notifications", "turn notifications on")


async def test_foreground_find_result_finishes_without_a_window_id(engine):
    """Foreground snapshots carry no CGWindowID, so verify_state cannot bind
    there, and the goal verifier never accepts a find result. A done after
    the row was selected must end the action (Swift reports the effect as
    performed, unverified), not loop on refusals until the turn cap."""
    eng, sock = engine
    busy = busy_slack()
    busy["window_id"] = None
    found = found_general(selected=True)
    found["window_id"] = None
    eng.cleanup = FakePlanner(
        turn([{"do": "find_ui", "text": "general"}],
             goal="open the general channel in Slack", sends=False),
        json.dumps({"done": True}),
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="open the general channel in Slack",
                     context={"frontmost_app": "Slack",
                              "frontmost_bundle": "com.tinyspeck.slackmacgap",
                              "running_apps": ["Slack"],
                              "ui_snapshot": busy})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="Slack", ui_snapshot=found,
        executed=["find_ui general", "set_ui [3] AXRow general = selected"]))
    evt = await client.recv_event("action_turn")
    assert evt["done"] is True
    assert evt["steps"] == []
    assert len(eng.cleanup.calls) == 2, "no goal-verifier call on a find result"
    assert "reply done=true" in eng.cleanup.calls[1][0]
    assert "finish with verify_state" not in eng.cleanup.calls[1][0]


def test_verify_state_without_a_window_id_steers_to_done():
    session = make_session("open the general channel", dict(
        found_general(selected=True), window_id=None))
    with pytest.raises(actions.PlanError, match="reply done=true"):
        actions._validate_verify_state(
            {"do": "verify_state", "index": 3, "assert": "selected"},
            session.state)
