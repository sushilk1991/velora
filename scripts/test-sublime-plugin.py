#!/usr/bin/env python3
"""Headless contract tests for the bundled Sublime Text Voice Edit plugin."""

import importlib.util
import json
import os
import socket
import stat
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
    def __init__(
        self,
        text,
        selections,
        view_id=7,
        *,
        element=None,
        scratch=False,
        valid=True,
    ):
        self.text = text
        self.selections = Selection(selections)
        self.view_id = view_id
        self.changes = 0
        self._element = element
        self._scratch = scratch
        self._valid = valid

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

    def is_valid(self):
        return self._valid

    def element(self):
        return self._element

    def is_scratch(self):
        return self._scratch

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

    def run_command(self, command, args):
        commands = {
            "velora_voice_edit_capture": PLUGIN.VeloraVoiceEditCaptureCommand,
            "velora_voice_edit_apply": PLUGIN.VeloraVoiceEditApplyCommand,
        }
        commands[command](self).run(None, **args)


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


class Window:
    def __init__(self, view):
        self.view = view

    def active_view(self):
        return self.view


class TextCommand:
    def __init__(self, view):
        self.view = view


def load_plugin():
    sublime = types.ModuleType("sublime")
    sublime.Region = Region
    sublime.version = lambda: "4200"
    sublime.set_timeout = lambda callback, delay=0: callback()
    sublime.active_window = lambda: ACTIVE_WINDOW[0]
    sublime_plugin = types.ModuleType("sublime_plugin")
    sublime_plugin.TextCommand = TextCommand
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


ACTIVE_WINDOW = [None]
PLUGIN = load_plugin()


class SublimePluginTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        PLUGIN.BRIDGE_DIR = self.temporary.name
        PLUGIN._SESSIONS.clear()
        PLUGIN._COMMAND_RESULTS.clear()
        PLUGIN._DELIVERY_RESULTS.clear()
        self.view = View("TARGET", [Region(0, 6)])
        ACTIVE_WINDOW[0] = Window(self.view)
        PLUGIN.plugin_loaded()
        deadline = time.time() + 1
        while time.time() < deadline:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.connect(PLUGIN._socket_path())
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.005)
        else:
            self.fail("Sublime bridge did not begin accepting connections")

    def tearDown(self):
        PLUGIN.plugin_unloaded()
        ACTIVE_WINDOW[0] = None
        self.temporary.cleanup()

    def request(self, command, **values):
        request = {
            "version": PLUGIN.PROTOCOL_VERSION,
            "command": command,
            "request_id": str(uuid.uuid4()),
        }
        request.update(values)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1)
            client.connect(PLUGIN._socket_path())
            client.sendall(
                json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"
            )
            response = b""
            while not response.endswith(b"\n"):
                chunk = client.recv(4096)
                if not chunk:
                    break
                response += chunk
        return request, json.loads(response.decode("utf-8"))

    def capture(self, view=None):
        if view is not None:
            ACTIVE_WINDOW[0].view = view
        return self.request("capture")

    def apply(self, token, replacement, expires_at=None):
        return self.request(
            "apply",
            token=token,
            generation=PLUGIN._GENERATION,
            replacement=replacement,
            expires_at=expires_at or time.time() + 5,
        )

    def test_socket_capture_and_exact_replacement(self):
        self.view = View("before TARGET after", [Region(7, 13)])
        ACTIVE_WINDOW[0].view = self.view
        request, captured = self.capture()
        self.assertEqual(
            {key: captured[key] for key in ("ok", "token", "text")},
            {"ok": True, "token": request["request_id"], "text": "TARGET"},
        )
        _, applied = self.apply(request["request_id"], "सही ✅")
        self.assertTrue(applied["ok"])
        self.assertEqual(self.view.text, "before सही ✅ after")
        self.assertEqual(
            [(region.a, region.b) for region in self.view.sel()],
            [(7 + len("सही ✅"), 7 + len("सही ✅"))],
        )

    def test_reversed_multiline_selection_preserves_exact_text(self):
        view = View("first\nsecond", [Region(12, 0)])
        capture, captured = self.capture(view)
        self.assertEqual(captured["text"], "first\nsecond")
        _, applied = self.apply(capture["request_id"], "नया\n✅")
        self.assertTrue(applied["ok"])
        self.assertEqual(view.text, "नया\n✅")

    def test_bridge_is_owner_only_and_pid_scoped(self):
        info = os.stat(PLUGIN._socket_path())
        self.assertTrue(stat.S_ISSOCK(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_uid, os.geteuid())
        self.assertTrue(
            PLUGIN._socket_path().endswith(
                "bridge-{}.sock".format(os.getppid())
            )
        )
        _, response = self.capture()
        self.assertEqual(response["editor_pid"], os.getppid())
        self.assertEqual(response["generation"], PLUGIN._GENERATION)

    def test_empty_selection_is_rejected(self):
        _, response = self.capture(View("current line", [Region(4, 4)]))
        self.assertEqual(response["error"], "empty_selection")
        self.assertFalse(PLUGIN._SESSIONS)

    def test_multiple_selections_are_rejected(self):
        _, response = self.capture(
            View("same same", [Region(0, 4), Region(5, 9)])
        )
        self.assertEqual(response["error"], "multiple_selections")
        self.assertFalse(PLUGIN._SESSIONS)

    def test_ui_widget_is_rejected_without_session(self):
        _, response = self.capture(
            View("Find query", [Region(0, 10)], element="find_input")
        )
        self.assertEqual(response["error"], "unsupported_view")
        self.assertFalse(PLUGIN._SESSIONS)

    def test_scratch_and_invalid_views_are_rejected(self):
        for view in (
            View("scratch", [Region(0, 7)], scratch=True),
            View("invalid", [Region(0, 7)], valid=False),
        ):
            _, response = self.capture(view)
            self.assertEqual(response["error"], "unsupported_view")
            self.assertFalse(PLUGIN._SESSIONS)

    def test_same_text_at_another_region_fails_closed(self):
        view = View("same same", [Region(0, 4)])
        capture, _ = self.capture(view)
        view.selections = Selection([Region(5, 9)])
        _, response = self.apply(capture["request_id"], "changed")
        self.assertEqual(response["error"], "selection_changed")
        self.assertEqual(view.text, "same same")

    def test_any_buffer_change_invalidates_the_token(self):
        capture, _ = self.capture()
        self.view.changes += 1
        _, response = self.apply(capture["request_id"], "changed")
        self.assertEqual(response["error"], "selection_changed")
        self.assertEqual(self.view.text, "TARGET")

    def test_expired_request_never_edits_later(self):
        capture, _ = self.capture()
        _, response = self.apply(
            capture["request_id"],
            "late",
            expires_at=time.time() - 1,
        )
        self.assertEqual(response["error"], "expired")
        self.assertEqual(self.view.text, "TARGET")

    def test_expired_capture_token_never_edits_later(self):
        capture, _ = self.capture()
        PLUGIN._SESSIONS[capture["request_id"]]["created_at"] = (
            time.time() - PLUGIN.SESSION_LIFETIME_S - 1
        )
        _, response = self.apply(capture["request_id"], "late")
        self.assertEqual(response["error"], "expired")
        self.assertEqual(self.view.text, "TARGET")

    def test_read_only_buffer_is_rejected_without_mutation(self):
        view = ReadOnlyView("TARGET", [Region(0, 6)])
        _, response = self.capture(view)
        self.assertEqual(response["error"], "unsupported_view")
        self.assertEqual(view.text, "TARGET")

    def test_view_becoming_read_only_after_capture_fails_closed(self):
        capture, _ = self.capture()
        self.view.is_read_only = lambda: True
        _, response = self.apply(capture["request_id"], "changed")
        self.assertEqual(response["error"], "selection_changed")
        self.assertEqual(self.view.text, "TARGET")

    def test_transformed_replacement_is_rolled_back_before_failure(self):
        view = TransformingView("TARGET", [Region(0, 6)])
        capture, _ = self.capture(view)
        _, response = self.apply(capture["request_id"], "changed")
        self.assertEqual(response["error"], "postcondition_failed")
        self.assertEqual(view.text, "TARGET")
        self.assertEqual(view.replace_count, 2)
        self.assertEqual(
            [(region.a, region.b) for region in view.sel()],
            [(0, 6)],
        )

    def test_capture_token_is_one_shot_after_success(self):
        capture, _ = self.capture()
        _, first = self.apply(capture["request_id"], "changed")
        self.assertTrue(first["ok"])
        _, replay = self.apply(capture["request_id"], "replayed")
        self.assertEqual(replay["error"], "invalid_request")
        self.assertEqual(self.view.text, "changed")

    def test_same_selection_in_another_view_fails_closed(self):
        original = View("TARGET", [Region(0, 6)], view_id=7)
        capture, _ = self.capture(original)
        other = View("TARGET", [Region(0, 6)], view_id=8)
        ACTIVE_WINDOW[0].view = other
        _, response = self.apply(capture["request_id"], "changed")
        self.assertEqual(response["error"], "selection_changed")
        self.assertEqual(original.text, "TARGET")
        self.assertEqual(other.text, "TARGET")

    def test_discard_is_one_shot_and_non_mutating(self):
        capture, _ = self.capture()
        _, response = self.request(
            "discard",
            token=capture["request_id"],
            generation=PLUGIN._GENERATION,
        )
        self.assertTrue(response["ok"])
        self.assertNotIn(capture["request_id"], PLUGIN._SESSIONS)
        self.assertEqual(self.view.text, "TARGET")

    def test_invalid_protocol_is_rejected_without_editing(self):
        _, response = self.request("unknown")
        self.assertEqual(response["error"], "invalid_request")
        self.assertEqual(self.view.text, "TARGET")

    def test_malformed_and_truncated_frames_are_rejected(self):
        for payload in (
            b"{not-json}\n",
            b'{"version":1,"command":"capture"',
        ):
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(1)
            client.connect(PLUGIN._socket_path())
            client.sendall(payload)
            if not payload.endswith(b"\n"):
                client.shutdown(socket.SHUT_WR)
            response = b""
            while not response.endswith(b"\n"):
                chunk = client.recv(4096)
                if not chunk:
                    break
                response += chunk
            client.close()
            self.assertEqual(
                json.loads(response.decode("utf-8"))["error"],
                "invalid_request",
            )
        self.assertFalse(PLUGIN._SESSIONS)

    def test_stale_generation_never_applies_or_discards(self):
        capture, _ = self.capture()
        _, apply_response = self.request(
            "apply",
            token=capture["request_id"],
            generation=str(uuid.uuid4()),
            replacement="changed",
            expires_at=time.time() + 5,
        )
        self.assertEqual(apply_response["error"], "invalid_request")
        self.assertEqual(self.view.text, "TARGET")

        capture, _ = self.capture()
        _, discard_response = self.request(
            "discard",
            token=capture["request_id"],
            generation=str(uuid.uuid4()),
        )
        self.assertEqual(discard_response["error"], "invalid_request")
        self.assertIn(capture["request_id"], PLUGIN._SESSIONS)

    def test_apply_result_can_be_confirmed_after_response_loss(self):
        capture, _ = self.capture()
        apply_request, applied = self.apply(
            capture["request_id"], "changed"
        )
        self.assertTrue(applied["ok"])
        _, status = self.request(
            "status", apply_request_id=apply_request["request_id"]
        )
        self.assertTrue(status["ok"])
        self.assertTrue(status["known"])
        self.assertTrue(status["result_ok"])
        self.assertEqual(self.view.text, "changed")

    def test_unknown_apply_status_never_retries_or_mutates(self):
        _, status = self.request(
            "status", apply_request_id=str(uuid.uuid4())
        )
        self.assertTrue(status["ok"])
        self.assertFalse(status["known"])
        self.assertEqual(self.view.text, "TARGET")

    def test_oversized_request_is_rejected_without_session(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(1)
        client.connect(PLUGIN._socket_path())
        client.sendall(b"x" * (PLUGIN.MAX_REQUEST_BYTES + 1) + b"\n")
        response = b""
        while not response.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        client.close()
        self.assertEqual(
            json.loads(response.decode("utf-8"))["error"],
            "invalid_request",
        )
        self.assertFalse(PLUGIN._SESSIONS)

    def test_plugin_unload_removes_only_its_socket(self):
        socket_path = PLUGIN._socket_path()
        PLUGIN.plugin_unloaded()
        self.assertFalse(os.path.exists(socket_path))
        PLUGIN.plugin_loaded()
        deadline = time.time() + 1
        while not os.path.exists(socket_path) and time.time() < deadline:
            time.sleep(0.005)
        self.assertTrue(os.path.exists(socket_path))

    def test_reloaded_server_cannot_unlink_its_replacement(self):
        first_server = PLUGIN._SERVER
        first_inode = os.lstat(PLUGIN._socket_path()).st_ino
        replacement = PLUGIN._BridgeServer()
        replacement.start()
        deadline = time.time() + 1
        while time.time() < deadline:
            try:
                if os.lstat(PLUGIN._socket_path()).st_ino != first_inode:
                    break
            except FileNotFoundError:
                pass
            time.sleep(0.005)
        replacement_inode = os.lstat(PLUGIN._socket_path()).st_ino
        self.assertNotEqual(first_inode, replacement_inode)
        first_server.stop()
        self.assertEqual(
            os.lstat(PLUGIN._socket_path()).st_ino,
            replacement_inode,
        )
        replacement.stop()
        PLUGIN._SERVER = None

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
