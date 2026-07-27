#!/usr/bin/env python3
"""Headless contract tests for the bundled Sublime Text Voice Edit plugin."""

import importlib.util
import json
import sys
import tempfile
import time
import types
import unittest
import uuid
from pathlib import Path

sys.dont_write_bytecode = True


class Region:
    def __init__(self, a, b):
        self.a = a
        self.b = b

    def begin(self):
        return min(self.a, self.b)

    def end(self):
        return max(self.a, self.b)

    def empty(self):
        return self.a == self.b

    def size(self):
        return self.end() - self.begin()


class Selection(list):
    def add(self, region):
        self.append(region)


class View:
    def __init__(self, text, selections, view_id=7):
        self.text = text
        self.selections = Selection(selections)
        self.view_id = view_id
        self.changes = 0

    def sel(self):
        return self.selections

    def id(self):
        return self.view_id

    def size(self):
        return len(self.text)

    def change_count(self):
        return self.changes

    def is_read_only(self):
        return False

    def substr(self, region):
        return self.text[region.begin() : region.end()]

    def replace(self, edit, region, replacement):
        del edit
        self.text = (
            self.text[: region.begin()]
            + replacement
            + self.text[region.end() :]
        )
        self.changes += 1


class ReadOnlyView(View):
    def is_read_only(self):
        return True

    def replace(self, edit, region, replacement):
        del edit, region, replacement


class TransformingView(View):
    def __init__(self, text, selections, view_id=7):
        super().__init__(text, selections, view_id)
        self.replace_count = 0

    def replace(self, edit, region, replacement):
        self.replace_count += 1
        if self.replace_count == 1:
            replacement = replacement.upper()
        super().replace(edit, region, replacement)


class TextCommand:
    def __init__(self, view):
        self.view = view


class ApplicationCommand:
    pass


def load_plugin():
    sublime = types.ModuleType("sublime")
    sublime.Region = Region
    sublime.set_timeout_async = lambda callback, delay: None
    sublime_plugin = types.ModuleType("sublime_plugin")
    sublime_plugin.TextCommand = TextCommand
    sublime_plugin.ApplicationCommand = ApplicationCommand
    sys.modules["sublime"] = sublime
    sys.modules["sublime_plugin"] = sublime_plugin
    path = (
        Path(__file__).resolve().parents[1]
        / "Resources"
        / "SublimeText"
        / "VeloraVoiceEdit.py"
    )
    spec = importlib.util.spec_from_file_location("velora_sublime_plugin", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PLUGIN = load_plugin()


class SublimePluginTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        PLUGIN.BRIDGE_DIR = Path(self.temporary.name)
        PLUGIN._SESSIONS.clear()

    def tearDown(self):
        self.temporary.cleanup()

    def response(self, request_id):
        path = PLUGIN.BRIDGE_DIR / f"{request_id}.response.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def request(self, request_id, value):
        path = PLUGIN.BRIDGE_DIR / f"{request_id}.request.json"
        path.write_text(json.dumps(value), encoding="utf-8")

    def capture(self, view):
        request_id = str(uuid.uuid4())
        PLUGIN.VeloraVoiceEditCaptureCommand(view).run(None, request_id)
        return request_id, self.response(request_id)

    def test_exact_selection_is_replaced_and_verified(self):
        view = View("before TARGET after", [Region(7, 13)])
        token, captured = self.capture(view)
        self.assertEqual(
            captured,
            {"ok": True, "token": token, "text": "TARGET"},
        )

        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "सही ✅",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(self.response(request_id), {"ok": True})
        self.assertEqual(view.text, "before सही ✅ after")
        self.assertEqual(
            [(region.a, region.b) for region in view.sel()],
            [(7 + len("सही ✅"), 7 + len("सही ✅"))],
        )

    def test_empty_selection_is_rejected_without_reading_current_line(self):
        view = View("current line", [Region(4, 4)])
        _, response = self.capture(view)
        self.assertEqual(response["error"], "empty_selection")
        self.assertFalse(PLUGIN._SESSIONS)

    def test_multiple_selections_are_rejected(self):
        view = View("same same", [Region(0, 4), Region(5, 9)])
        _, response = self.capture(view)
        self.assertEqual(response["error"], "multiple_selections")
        self.assertFalse(PLUGIN._SESSIONS)

    def test_same_text_at_another_region_fails_closed(self):
        view = View("same same", [Region(0, 4)])
        token, _ = self.capture(view)
        view.selections = Selection([Region(5, 9)])
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"],
            "selection_changed",
        )
        self.assertEqual(view.text, "same same")

    def test_any_buffer_change_invalidates_the_token(self):
        view = View("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        view.changes += 1
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"],
            "selection_changed",
        )
        self.assertEqual(view.text, "TARGET")

    def test_expired_request_never_edits_later(self):
        view = View("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "late",
                "expires_at": time.time() - 1,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(self.response(request_id)["error"], "expired")
        self.assertEqual(view.text, "TARGET")

    def test_expired_capture_token_never_edits_later(self):
        view = View("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        PLUGIN._SESSIONS[token]["created_at"] = (
            time.time() - PLUGIN.SESSION_LIFETIME_S - 1
        )
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "late",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(self.response(request_id)["error"], "expired")
        self.assertEqual(view.text, "TARGET")

    def test_read_only_buffer_is_rejected_without_mutation(self):
        view = ReadOnlyView("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"], "selection_changed"
        )
        self.assertEqual(view.text, "TARGET")

    def test_transformed_replacement_is_rolled_back_before_failure(self):
        view = TransformingView("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"],
            "postcondition_failed",
        )
        self.assertEqual(view.text, "TARGET")
        self.assertEqual(view.replace_count, 2)
        self.assertEqual(
            [(region.a, region.b) for region in view.sel()],
            [(0, 6)],
        )

    def test_capture_token_is_one_shot_after_success(self):
        view = View("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        first_request = str(uuid.uuid4())
        self.request(
            first_request,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, first_request)
        self.assertEqual(self.response(first_request), {"ok": True})

        replay_request = str(uuid.uuid4())
        self.request(
            replay_request,
            {
                "token": token,
                "replacement": "replayed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, replay_request)
        self.assertEqual(
            self.response(replay_request)["error"],
            "invalid_request",
        )
        self.assertEqual(view.text, "changed")

    def test_same_selection_in_another_view_fails_closed(self):
        original = View("TARGET", [Region(0, 6)], view_id=7)
        token, _ = self.capture(original)
        other = View("TARGET", [Region(0, 6)], view_id=8)
        request_id = str(uuid.uuid4())
        self.request(
            request_id,
            {
                "token": token,
                "replacement": "changed",
                "expires_at": time.time() + 5,
            },
        )
        PLUGIN.VeloraVoiceEditApplyCommand(other).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"],
            "selection_changed",
        )
        self.assertEqual(original.text, "TARGET")
        self.assertEqual(other.text, "TARGET")

    def test_missing_apply_request_is_rejected_without_editing(self):
        view = View("TARGET", [Region(0, 6)])
        request_id = str(uuid.uuid4())
        PLUGIN.VeloraVoiceEditApplyCommand(view).run(None, request_id)
        self.assertEqual(
            self.response(request_id)["error"],
            "invalid_request",
        )
        self.assertEqual(view.text, "TARGET")

    def test_invalid_capture_id_creates_no_session_or_response(self):
        view = View("TARGET", [Region(0, 6)])
        PLUGIN.VeloraVoiceEditCaptureCommand(view).run(None, "../invalid")
        self.assertFalse(PLUGIN._SESSIONS)
        self.assertFalse(list(PLUGIN.BRIDGE_DIR.iterdir()))

    def test_discard_is_one_shot_and_non_mutating(self):
        view = View("TARGET", [Region(0, 6)])
        token, _ = self.capture(view)
        PLUGIN.VeloraVoiceEditDiscardCommand().run(token)
        self.assertNotIn(token, PLUGIN._SESSIONS)
        self.assertEqual(view.text, "TARGET")

    def test_package_selects_sublime_modern_python_host(self):
        version_file = (
            Path(__file__).resolve().parents[1]
            / "Resources"
            / "SublimeText"
            / ".python-version"
        )
        self.assertEqual(version_file.read_text(encoding="utf-8").strip(), "3.8")


if __name__ == "__main__":
    unittest.main()
