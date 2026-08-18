"""Exact, fail-closed Sublime Text selection bridge for Velora Voice Edit."""

import ctypes
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
MAX_STREAM_SELECTION = 8_000
MAX_STREAM_SESSIONS = 8
COMMAND_TIMEOUT_S = 3.0
RESULT_LIFETIME_S = 30
VELORA_TEAM_ID = "JZFVKGDPU4"
VELORA_IDENTITY = "com.sushil.velora"
CS_OPS_STATUS = 0
CS_OPS_IDENTITY = 11
CS_OPS_TEAMID = 14
CS_VALID = 0x00000001
CS_SIGNED = 0x20000000
_LIBSYSTEM = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

_SESSIONS = {}
_STREAM_SESSIONS = {}
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
    for token, session in list(_STREAM_SESSIONS.items()):
        # Once Velora has rendered a draft, only an exact guarded commit or
        # restore may release it. Time alone must never strand provisional text.
        if session["rendered"] is None and session["created_at"] < cutoff:
            _STREAM_SESSIONS.pop(token, None)
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


def _stream_capture(view, request_id):
    _expire_sessions()
    if not _is_document_view(view):
        return _error("unsupported_view")
    selections = list(view.sel())
    if len(selections) != 1:
        return _error("multiple_selections")
    region = selections[0]
    if region.size() > MAX_STREAM_SELECTION:
        return _error("selection_too_long")
    if len(_STREAM_SESSIONS) >= MAX_STREAM_SESSIONS:
        return _error("too_many_sessions")
    start = region.begin()
    end = region.end()
    text = view.substr(region)
    context_limit = 32
    before = view.substr(sublime.Region(max(0, start - context_limit), start))
    after = view.substr(
        sublime.Region(end, min(view.size(), end + context_limit))
    )
    _STREAM_SESSIONS[request_id] = {
        "view_id": view.id(),
        "original_a": region.a,
        "original_b": region.b,
        "original_text": text,
        "start": start,
        "end": end,
        "rendered": None,
        "change_count": view.change_count(),
        "created_at": time.time(),
        "generation": _GENERATION,
    }
    return {
        "ok": True,
        "token": request_id,
        "text": text,
        "before": before,
        "after": after,
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


def _stream_selection_is_owned(view, session):
    selections = list(view.sel())
    if (
        view.id() != session["view_id"]
        or session["generation"] != _GENERATION
        or view.change_count() != session["change_count"]
        or not _is_document_view(view)
        or len(selections) != 1
    ):
        return False
    rendered = session["rendered"]
    if rendered is None:
        expected = sublime.Region(
            session["original_a"], session["original_b"]
        )
        return (
            selections[0].a == expected.a
            and selections[0].b == expected.b
            and view.substr(expected) == session["original_text"]
        )
    expected = sublime.Region(session["start"], session["end"])
    return (
        selections[0].a == expected.end()
        and selections[0].b == expected.end()
        and view.substr(expected) == rendered
    )


def _stream_update(view, edit, request):
    token = request.get("token")
    replacement = request.get("replacement")
    expires_at = request.get("expires_at")
    generation = request.get("generation")
    final = request.get("final")
    session = _STREAM_SESSIONS.get(token) if _valid_id(token) else None
    if (
        session is None
        or not isinstance(replacement, str)
        or generation != _GENERATION
        or not isinstance(final, bool)
        or isinstance(expires_at, bool)
        or not isinstance(expires_at, (int, float))
    ):
        return _error("invalid_request")
    if time.time() > expires_at:
        # A request deadline only bounds this mutation. Once a draft has been
        # rendered, retain its exact restoration record for a later cancel.
        if session["rendered"] is None:
            _STREAM_SESSIONS.pop(token, None)
        return _error("expired")
    if (
        session["rendered"] is None
        and time.time() - session["created_at"] > SESSION_LIFETIME_S
    ):
        _STREAM_SESSIONS.pop(token, None)
        return _error("expired")
    if not _stream_selection_is_owned(view, session):
        _STREAM_SESSIONS.pop(token, None)
        return _error("selection_changed")

    previous = (
        session["original_text"]
        if session["rendered"] is None
        else session["rendered"]
    )
    expected = sublime.Region(session["start"], session["end"])
    if session["rendered"] is not None and previous == replacement:
        if final:
            _STREAM_SESSIONS.pop(token, None)
        return {"ok": True}

    old_size = view.size()
    view.replace(edit, expected, replacement)
    inserted_size = view.size() - old_size + expected.size()
    inserted = sublime.Region(expected.begin(), expected.begin() + inserted_size)
    if view.substr(inserted) != replacement:
        view.replace(edit, inserted, previous)
        view.sel().clear()
        if session["rendered"] is None:
            view.sel().add(
                sublime.Region(session["original_a"], session["original_b"])
            )
        else:
            view.sel().add(sublime.Region(session["end"], session["end"]))
        _STREAM_SESSIONS.pop(token, None)
        return _error("postcondition_failed")

    view.sel().clear()
    view.sel().add(sublime.Region(inserted.end(), inserted.end()))
    session["end"] = inserted.end()
    session["rendered"] = replacement
    session["change_count"] = view.change_count()
    session["created_at"] = time.time()
    if final:
        _STREAM_SESSIONS.pop(token, None)
    return {"ok": True}


def _stream_cancel(view, edit, request):
    _expire_sessions()
    token = request.get("token")
    generation = request.get("generation")
    session = (
        _STREAM_SESSIONS.pop(token, None) if _valid_id(token) else None
    )
    if session is None or generation != _GENERATION:
        return _error("invalid_request")
    if not _stream_selection_is_owned(view, session):
        return _error("selection_changed")
    if session["rendered"] is None:
        return {"ok": True, "restored": False}

    expected = sublime.Region(session["start"], session["end"])
    old_size = view.size()
    view.replace(edit, expected, session["original_text"])
    restored_size = view.size() - old_size + expected.size()
    restored = sublime.Region(
        expected.begin(), expected.begin() + restored_size
    )
    if view.substr(restored) != session["original_text"]:
        return _error("postcondition_failed")
    view.sel().clear()
    view.sel().add(
        sublime.Region(session["original_a"], session["original_b"])
    )
    return {"ok": True, "restored": True}


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


class VeloraStreamCaptureCommand(sublime_plugin.TextCommand):
    def run(self, edit, request_id):
        del edit
        try:
            result = (
                _stream_capture(self.view, request_id)
                if _valid_id(request_id)
                else _error("invalid_request")
            )
        except Exception:
            result = _error("internal_error")
        _store_command_result(request_id, result)


class VeloraStreamUpdateCommand(sublime_plugin.TextCommand):
    def run(
        self,
        edit,
        request_id,
        token,
        generation,
        replacement,
        final,
        expires_at,
    ):
        try:
            result = _stream_update(
                self.view,
                edit,
                {
                    "token": token,
                    "generation": generation,
                    "replacement": replacement,
                    "final": final,
                    "expires_at": expires_at,
                },
            )
        except Exception:
            result = _error("internal_error")
        _store_command_result(request_id, result)


class VeloraStreamCancelCommand(sublime_plugin.TextCommand):
    def run(self, edit, request_id, token, generation):
        try:
            result = _stream_cancel(
                self.view,
                edit,
                {"token": token, "generation": generation},
            )
        except Exception:
            result = _error("internal_error")
        _store_command_result(request_id, result)


def _run_on_main(callback):
    finished = threading.Event()
    gate = threading.Lock()
    result = {}
    state = {"started": False, "cancelled": False}

    def invoke():
        with gate:
            if state["cancelled"]:
                finished.set()
                return
            state["started"] = True
        try:
            result["value"] = callback()
        except Exception:
            result["value"] = _error("internal_error")
        finally:
            finished.set()

    sublime.set_timeout(invoke, 0)
    if not finished.wait(COMMAND_TIMEOUT_S):
        with gate:
            if not state["started"]:
                state["cancelled"] = True
                return _error("command_timeout")
        # The main-thread transaction already began. Wait for its authoritative
        # result so a journaled timeout can never disagree with a later edit.
        finished.wait()
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
        _STREAM_SESSIONS.pop(token, None)
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
    if command == "stream_capture":
        return _run_view_command("velora_stream_capture", request)
    if command == "stream_update":
        result = _run_view_command("velora_stream_update", request)
        _DELIVERY_RESULTS[request_id] = {
            "result": result,
            "created_at": time.time(),
        }
        return result
    if command == "stream_cancel":
        result = _run_view_command("velora_stream_cancel", request)
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


def _csops_string(pid, operation):
    # CS_OPS_IDENTITY and CS_OPS_TEAMID return an eight-byte fake blob header
    # followed by the NUL-terminated process identity.
    value = ctypes.create_string_buffer(512)
    if _LIBSYSTEM.csops(pid, operation, value, len(value)) != 0:
        return None
    return os.fsdecode(value.raw[8:].split(b"\0", 1)[0])


def _process_is_velora(pid):
    status = ctypes.c_uint32()
    if (
        _LIBSYSTEM.csops(
            pid, CS_OPS_STATUS, ctypes.byref(status), ctypes.sizeof(status)
        )
        != 0
        or status.value & (CS_VALID | CS_SIGNED) != (CS_VALID | CS_SIGNED)
    ):
        return False
    return (
        _csops_string(pid, CS_OPS_IDENTITY) == VELORA_IDENTITY
        and _csops_string(pid, CS_OPS_TEAMID) == VELORA_TEAM_ID
    )


def _peer_is_velora(connection):
    """Require the peer itself to be the signed Velora executable.

    File permissions isolate other users; LOCAL_PEERPID plus the designated
    kernel code identity prevents an unrelated process in this account from
    using the editor mutation capability. Querying the live process avoids a
    pathname replacement race between PID lookup and signature validation.
    """
    try:
        peer_pid = connection.getsockopt(0, 0x002)  # SOL_LOCAL/LOCAL_PEERPID
        return _process_is_velora(peer_pid)
    except (OSError, ValueError):
        return False


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
                    raise PermissionError("bridge peer is not the current user")
                if not _peer_is_velora(connection):
                    raise PermissionError("bridge peer is not signed Velora")
                with connection.makefile("rb") as stream:
                    line = stream.readline(MAX_REQUEST_BYTES + 1)
                if (
                    not line.endswith(b"\n")
                    or len(line) > MAX_REQUEST_BYTES
                ):
                    response = _error("invalid_request")
                else:
                    response = _dispatch(json.loads(line.decode("utf-8")))
            except PermissionError:
                response = _error("unauthorized")
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
