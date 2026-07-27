"""Exact, fail-closed Sublime Text selection bridge for Velora Voice Edit."""

import json
import os
import time
import uuid
from pathlib import Path

import sublime
import sublime_plugin


BRIDGE_DIR = Path.home() / ".velora" / "sublime-bridge"
_SESSIONS = {}
SESSION_LIFETIME_S = 360


def _valid_id(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (AttributeError, TypeError, ValueError):
        return False


def _response_path(request_id):
    return BRIDGE_DIR / f"{request_id}.response.json"


def _request_path(request_id):
    return BRIDGE_DIR / f"{request_id}.request.json"


def _write_response(request_id, payload):
    if not _valid_id(request_id):
        return
    BRIDGE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = BRIDGE_DIR / f".{request_id}.{uuid.uuid4()}.tmp"
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        response = _response_path(request_id)
        os.replace(temporary, response)
        sublime.set_timeout_async(
            lambda: _remove_if_present(response),
            30_000,
        )
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _remove_if_present(path):
    try:
        path.unlink()
    except OSError:
        pass


def _read_request(request_id):
    if not _valid_id(request_id):
        return None
    path = _request_path(request_id)
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    finally:
        try:
            path.unlink()
        except OSError:
            pass
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


class VeloraVoiceEditCaptureCommand(sublime_plugin.TextCommand):
    def run(self, edit, request_id):
        del edit
        if not _valid_id(request_id):
            return
        cutoff = time.time() - SESSION_LIFETIME_S
        for token, session in list(_SESSIONS.items()):
            if session["created_at"] < cutoff:
                _SESSIONS.pop(token, None)
        selections = list(self.view.sel())
        if len(selections) != 1:
            _write_response(
                request_id,
                {"ok": False, "error": "multiple_selections"},
            )
            return
        region = selections[0]
        if region.empty():
            _write_response(
                request_id,
                {"ok": False, "error": "empty_selection"},
            )
            return
        text = self.view.substr(region)
        if not text or not text.strip():
            _write_response(
                request_id,
                {"ok": False, "error": "empty_selection"},
            )
            return

        _SESSIONS[request_id] = {
            "view_id": self.view.id(),
            "a": region.a,
            "b": region.b,
            "text": text,
            "change_count": self.view.change_count(),
            "created_at": time.time(),
        }
        _write_response(
            request_id,
            {"ok": True, "token": request_id, "text": text},
        )


class VeloraVoiceEditApplyCommand(sublime_plugin.TextCommand):
    def run(self, edit, request_id):
        request = _read_request(request_id)
        if request is None:
            _write_response(
                request_id,
                {"ok": False, "error": "invalid_request"},
            )
            return

        token = request.get("token")
        replacement = request.get("replacement")
        expires_at = request.get("expires_at")
        session = _SESSIONS.pop(token, None) if _valid_id(token) else None
        if (
            session is None
            or not isinstance(replacement, str)
            or not isinstance(expires_at, (int, float))
        ):
            _write_response(
                request_id,
                {"ok": False, "error": "invalid_request"},
            )
            return
        if time.time() > expires_at:
            _write_response(
                request_id,
                {"ok": False, "error": "expired"},
            )
            return
        if time.time() - session["created_at"] > SESSION_LIFETIME_S:
            _write_response(
                request_id,
                {"ok": False, "error": "expired"},
            )
            return

        selections = list(self.view.sel())
        expected = sublime.Region(session["a"], session["b"])
        if (
            self.view.id() != session["view_id"]
            or self.view.change_count() != session["change_count"]
            or self.view.is_read_only()
            or len(selections) != 1
            or selections[0].a != expected.a
            or selections[0].b != expected.b
            or self.view.substr(expected) != session["text"]
        ):
            _write_response(
                request_id,
                {"ok": False, "error": "selection_changed"},
            )
            return

        old_size = self.view.size()
        self.view.replace(edit, expected, replacement)
        inserted_size = self.view.size() - old_size + expected.size()
        inserted = sublime.Region(expected.begin(), expected.begin() + inserted_size)
        if self.view.substr(inserted) != replacement:
            # A plugin or syntax-specific buffer can transform a replacement.
            # Restore the captured bytes within this same edit transaction so
            # Velora never leaves a mutation behind while reporting failure.
            self.view.replace(edit, inserted, session["text"])
            self.view.sel().clear()
            self.view.sel().add(sublime.Region(session["a"], session["b"]))
            _write_response(
                request_id,
                {"ok": False, "error": "postcondition_failed"},
            )
            return

        self.view.sel().clear()
        self.view.sel().add(sublime.Region(inserted.end(), inserted.end()))
        _write_response(request_id, {"ok": True})


class VeloraVoiceEditDiscardCommand(sublime_plugin.ApplicationCommand):
    def run(self, token):
        if _valid_id(token):
            _SESSIONS.pop(token, None)
