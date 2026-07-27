"""Exact, fail-closed Sublime Text selection bridge for Velora Voice Edit."""

import json
import os
import socket
import stat
import threading
import time
import uuid

import sublime
import sublime_plugin


BRIDGE_DIR = os.path.join(os.path.expanduser("~"), ".velora", "sublime-bridge")
PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 1_048_576
SESSION_LIFETIME_S = 360
COMMAND_TIMEOUT_S = 3.0
RESULT_LIFETIME_S = 30

_SESSIONS = {}
_COMMAND_RESULTS = {}
_DELIVERY_RESULTS = {}
_GENERATION = str(uuid.uuid4())
_SERVER = None


def _valid_id(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (AttributeError, TypeError, ValueError):
        return False


def _error(code):
    return {"ok": False, "error": code}


def _expire_sessions():
    cutoff = time.time() - SESSION_LIFETIME_S
    for token, session in list(_SESSIONS.items()):
        if session["created_at"] < cutoff:
            _SESSIONS.pop(token, None)
    result_cutoff = time.time() - RESULT_LIFETIME_S
    for request_id, delivery in list(_DELIVERY_RESULTS.items()):
        if delivery["created_at"] < result_cutoff:
            _DELIVERY_RESULTS.pop(request_id, None)


def _is_document_view(view):
    return (
        view.is_valid()
        and view.element() is None
        and not view.is_scratch()
        and not view.is_read_only()
    )


def _capture(view, request_id):
    _expire_sessions()
    if not _is_document_view(view):
        return _error("unsupported_view")
    selections = list(view.sel())
    if len(selections) != 1:
        return _error("multiple_selections")
    region = selections[0]
    if region.empty():
        return _error("empty_selection")
    text = view.substr(region)
    if not text or not text.strip():
        return _error("empty_selection")

    _SESSIONS[request_id] = {
        "view_id": view.id(),
        "a": region.a,
        "b": region.b,
        "text": text,
        "change_count": view.change_count(),
        "created_at": time.time(),
        "generation": _GENERATION,
    }
    return {
        "ok": True,
        "token": request_id,
        "text": text,
    }


def _apply(view, edit, request):
    token = request.get("token")
    replacement = request.get("replacement")
    expires_at = request.get("expires_at")
    generation = request.get("generation")
    session = _SESSIONS.pop(token, None) if _valid_id(token) else None
    if (
        session is None
        or not isinstance(replacement, str)
        or generation != _GENERATION
        or isinstance(expires_at, bool)
        or not isinstance(expires_at, (int, float))
    ):
        return _error("invalid_request")
    if time.time() > expires_at:
        return _error("expired")
    if time.time() - session["created_at"] > SESSION_LIFETIME_S:
        return _error("expired")

    selections = list(view.sel())
    expected = sublime.Region(session["a"], session["b"])
    if (
        view.id() != session["view_id"]
        or session["generation"] != _GENERATION
        or view.change_count() != session["change_count"]
        or not _is_document_view(view)
        or len(selections) != 1
        or selections[0].a != expected.a
        or selections[0].b != expected.b
        or view.substr(expected) != session["text"]
    ):
        return _error("selection_changed")

    old_size = view.size()
    view.replace(edit, expected, replacement)
    inserted_size = view.size() - old_size + expected.size()
    inserted = sublime.Region(expected.begin(), expected.begin() + inserted_size)
    if view.substr(inserted) != replacement:
        # A syntax-specific buffer can transform a replacement. Restore the
        # captured bytes within this same edit transaction before failing.
        view.replace(edit, inserted, session["text"])
        view.sel().clear()
        view.sel().add(sublime.Region(session["a"], session["b"]))
        return _error("postcondition_failed")

    view.sel().clear()
    view.sel().add(sublime.Region(inserted.end(), inserted.end()))
    return {"ok": True}


def _store_command_result(request_id, result):
    if _valid_id(request_id):
        _COMMAND_RESULTS[request_id] = result


class VeloraVoiceEditCaptureCommand(sublime_plugin.TextCommand):
    def run(self, edit, request_id):
        del edit
        try:
            result = (
                _capture(self.view, request_id)
                if _valid_id(request_id)
                else _error("invalid_request")
            )
        except Exception:
            result = _error("internal_error")
        _store_command_result(request_id, result)


class VeloraVoiceEditApplyCommand(sublime_plugin.TextCommand):
    def run(
        self,
        edit,
        request_id,
        token,
        generation,
        replacement,
        expires_at,
    ):
        try:
            result = _apply(
                self.view,
                edit,
                {
                    "token": token,
                    "generation": generation,
                    "replacement": replacement,
                    "expires_at": expires_at,
                },
            )
        except Exception:
            result = _error("internal_error")
        _store_command_result(request_id, result)


def _run_on_main(callback):
    finished = threading.Event()
    result = {}

    def invoke():
        try:
            result["value"] = callback()
        except Exception:
            result["value"] = _error("internal_error")
        finally:
            finished.set()

    sublime.set_timeout(invoke, 0)
    if not finished.wait(COMMAND_TIMEOUT_S):
        return _error("command_timeout")
    return result.get("value", _error("internal_error"))


def _run_view_command(command, request):
    request_id = request["request_id"]

    def invoke():
        window = sublime.active_window()
        view = window.active_view() if window is not None else None
        if view is None:
            return _error("no_active_view")
        args = dict(request)
        args.pop("version", None)
        args.pop("command", None)
        view.run_command(command, args)
        return _COMMAND_RESULTS.pop(request_id, _error("internal_error"))

    return _run_on_main(invoke)


def _discard(request):
    token = request.get("token")
    if (
        not _valid_id(token)
        or request.get("generation") != _GENERATION
    ):
        return _error("invalid_request")

    def invoke():
        _SESSIONS.pop(token, None)
        return {"ok": True}

    return _run_on_main(invoke)


def _status(request):
    apply_request_id = request.get("apply_request_id")
    if not _valid_id(apply_request_id):
        return _error("invalid_request")
    _expire_sessions()
    delivery = _DELIVERY_RESULTS.get(apply_request_id)
    if delivery is None:
        return {
            "ok": True,
            "known": False,
        }
    return {
        "ok": True,
        "known": True,
        "result_ok": delivery["result"].get("ok") is True,
        "result_error": delivery["result"].get("error"),
    }


def _dispatch(request):
    if not isinstance(request, dict):
        return _error("invalid_request")
    if request.get("version") != PROTOCOL_VERSION:
        return _error("invalid_request")
    request_id = request.get("request_id")
    if not _valid_id(request_id):
        return _error("invalid_request")

    command = request.get("command")
    if command == "capture":
        return _run_view_command("velora_voice_edit_capture", request)
    if command == "apply":
        result = _run_view_command("velora_voice_edit_apply", request)
        _DELIVERY_RESULTS[request_id] = {
            "result": result,
            "created_at": time.time(),
        }
        return result
    if command == "discard":
        return _discard(request)
    if command == "status":
        return _status(request)
    return _error("invalid_request")


def _socket_path():
    # plugin_host is a direct child of the Sublime Text process on macOS.
    # A PID-specific endpoint prevents one Sublime instance from answering for
    # another instance's active view.
    return os.path.join(BRIDGE_DIR, "bridge-{}.sock".format(os.getppid()))


class _BridgeServer:
    def __init__(self):
        self.path = _socket_path()
        self.stopping = threading.Event()
        self.thread = threading.Thread(
            target=self._serve,
            name="VeloraVoiceEditBridge",
            daemon=True,
        )
        self.listener = None
        self.socket_inode = None

    def start(self):
        self.thread.start()

    def stop(self):
        self.stopping.set()
        wake = None
        try:
            wake = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            wake.settimeout(0.1)
            wake.connect(self.path)
        except OSError:
            pass
        finally:
            if wake is not None:
                wake.close()
        self.thread.join(0.5)

    def _prepare_path(self):
        if os.path.lexists(BRIDGE_DIR) and os.path.islink(BRIDGE_DIR):
            raise OSError("bridge directory is a symbolic link")
        os.makedirs(BRIDGE_DIR, mode=0o700, exist_ok=True)
        os.chmod(BRIDGE_DIR, 0o700)
        if os.path.lexists(self.path):
            info = os.lstat(self.path)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
                raise OSError("unsafe bridge socket path")
            os.unlink(self.path)

    def _serve(self):
        try:
            self._prepare_path()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener = listener
            listener.bind(self.path)
            self.socket_inode = os.lstat(self.path).st_ino
            os.chmod(self.path, 0o600)
            listener.listen(4)
            listener.settimeout(0.2)
            while not self.stopping.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                self._serve_connection(connection)
        except OSError:
            pass
        finally:
            listener = self.listener
            self.listener = None
            if listener is not None:
                try:
                    listener.close()
                except OSError:
                    pass
            try:
                info = os.lstat(self.path)
                if (
                    stat.S_ISSOCK(info.st_mode)
                    and info.st_uid == os.geteuid()
                    and info.st_ino == self.socket_inode
                ):
                    os.unlink(self.path)
            except OSError:
                pass

    def _serve_connection(self, connection):
        with connection:
            connection.settimeout(COMMAND_TIMEOUT_S)
            try:
                getpeereid = getattr(connection, "getpeereid", None)
                if (
                    getpeereid is not None
                    and getpeereid()[0] != os.geteuid()
                ):
                    raise OSError("bridge peer is not the current user")
                with connection.makefile("rb") as stream:
                    line = stream.readline(MAX_REQUEST_BYTES + 1)
                if (
                    not line.endswith(b"\n")
                    or len(line) > MAX_REQUEST_BYTES
                ):
                    response = _error("invalid_request")
                else:
                    response = _dispatch(json.loads(line.decode("utf-8")))
            except (OSError, UnicodeError, ValueError):
                response = _error("invalid_request")
            response["editor_pid"] = os.getppid()
            response["generation"] = _GENERATION
            response["sublime_build"] = sublime.version()
            encoded = (
                json.dumps(response, ensure_ascii=False, separators=(",", ":"))
                .encode("utf-8")
                + b"\n"
            )
            try:
                connection.sendall(encoded)
            except OSError:
                pass


def plugin_loaded():
    global _SERVER
    if _SERVER is not None:
        _SERVER.stop()
    _SERVER = _BridgeServer()
    _SERVER.start()


def plugin_unloaded():
    global _SERVER
    if _SERVER is not None:
        _SERVER.stop()
        _SERVER = None
