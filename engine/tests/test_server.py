"""Server integration test over a real unix socket with the fake STT backend
(VELORA_FAKE_STT=1): start → audio → stop → transcript/final, and cancel."""

import asyncio
import json
import shutil
import tempfile
import threading
from pathlib import Path

import numpy as np
import pytest

import velora_engine.server as server_mod
from velora_engine.cleanup import CleanupResult
from velora_engine import protocol
from velora_engine.config import Config
from velora_engine.server import Engine


class Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer

    async def send_json(self, obj: dict) -> None:
        self.writer.write(protocol.encode_json(obj))
        await self.writer.drain()

    async def send_audio(self, samples: np.ndarray) -> None:
        self.writer.write(protocol.encode_frame(protocol.FRAME_AUDIO, samples.astype("<f4").tobytes()))
        await self.writer.drain()

    async def recv(self, timeout: float = 5.0) -> dict:
        frame_type, payload = await asyncio.wait_for(protocol.read_frame(self.reader), timeout)
        assert frame_type == protocol.FRAME_JSON
        return json.loads(payload)

    async def recv_event(self, name: str, timeout: float = 5.0) -> dict:
        """Read events until `name` arrives (skipping partials etc.)."""
        while True:
            evt = await self.recv(timeout)
            if evt.get("event") == name:
                return evt
            if evt.get("event") == "error":
                raise AssertionError(f"unexpected error event: {evt}")

    def close(self) -> None:
        self.writer.close()


@pytest.fixture
async def engine(home, fake_stt):
    config = Config()
    eng = Engine(config, parent_pid=None)
    # AF_UNIX paths are length-limited (~104 bytes on macOS); pytest's tmp_path
    # is too deep, so use a short scratch dir for the socket.
    sock_dir = Path(tempfile.mkdtemp(prefix="velora-t-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    for _ in range(100):
        if sock.exists():
            break
        await asyncio.sleep(0.01)
    yield eng, sock
    eng.shutdown.set()
    await asyncio.wait_for(task, 5)
    shutil.rmtree(sock_dir, ignore_errors=True)


async def connect(sock) -> Client:
    reader, writer = await asyncio.open_unix_connection(str(sock))
    return Client(reader, writer)


AUDIO = (np.sin(np.linspace(0, 100, 1600)) * 0.1).astype(np.float32)  # one 100ms chunk


async def test_setup_complete_follows_ready(engine):
    """Onboarding gets an explicit signal after every first-run model is ready."""
    eng, sock = engine
    client = await connect(sock)
    ready = await client.recv_event("ready")
    if not ready["setup_complete"]:
        await client.recv_event("setup_complete")
    await client.send_json({"cmd": "ping"})
    assert (await client.recv())["event"] == "pong"  # no duplicate completion queued
    client.close()
    await client.writer.wait_closed()

    reconnected = await connect(sock)
    ready = await reconnected.recv_event("ready")
    if not ready["setup_complete"]:
        await reconnected.recv_event("setup_complete")
    await reconnected.send_json({"cmd": "ping"})
    assert (await reconnected.recv())["event"] == "pong"
    reconnected.close()


async def test_setup_complete_event_is_after_ready_and_sent_once(home, fake_stt):
    """Exercise the cold path deterministically: ready(false), progress, completion."""
    eng = Engine(Config(), parent_pid=None)
    finish_setup = asyncio.Event()

    async def delayed_model_setup():
        await eng._set_loading("Downloading the writing model (4.8 GB)", 0.42)
        eng.stt_ready.set()
        await finish_setup.wait()
        await eng._set_loading(None)
        eng.setup_complete = True
        await eng._send_setup_complete_if_ready()

    eng._load_models = delayed_model_setup
    sock_dir = Path(tempfile.mkdtemp(prefix="velora-t-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    try:
        for _ in range(100):
            if sock.exists():
                break
            await asyncio.sleep(0.01)

        client = await connect(sock)
        ready = await client.recv()
        assert ready["event"] == "ready"
        assert ready["setup_complete"] is False

        loading = await client.recv()
        assert loading == {
            "event": "loading",
            "phase": "Downloading the writing model (4.8 GB)",
            "fraction": 0.42,
        }

        finish_setup.set()
        assert (await client.recv())["event"] == "loading"  # explicit phase clear
        assert (await client.recv())["event"] == "setup_complete"
        await client.send_json({"cmd": "ping"})
        assert (await client.recv())["event"] == "pong"  # exactly one completion event
        client.close()
    finally:
        eng.shutdown.set()
        await asyncio.wait_for(task, 5)
        shutil.rmtree(sock_dir, ignore_errors=True)


async def test_superseded_pre_ready_client_cannot_clobber_setup_owner(home, fake_stt):
    """Only the newest client may publish ready/setup events after a reconnect."""
    eng = Engine(Config(), parent_pid=None)
    allow_ready = asyncio.Event()
    finish_setup = asyncio.Event()

    async def delayed_model_setup():
        await allow_ready.wait()
        eng.stt_ready.set()
        await finish_setup.wait()
        eng.setup_complete = True
        await eng._send_setup_complete_if_ready()

    eng._load_models = delayed_model_setup
    sock_dir = Path(tempfile.mkdtemp(prefix="velora-t-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    first = second = None
    try:
        for _ in range(100):
            if sock.exists():
                break
            await asyncio.sleep(0.01)

        first = await connect(sock)
        second = await connect(sock)
        for _ in range(100):
            if eng._client_gen == 2:
                break
            await asyncio.sleep(0.01)
        assert eng._client_gen == 2

        allow_ready.set()
        ready = await second.recv()
        assert ready["event"] == "ready"
        assert ready["setup_complete"] is False

        finish_setup.set()
        assert (await second.recv())["event"] == "setup_complete"
        await second.send_json({"cmd": "ping"})
        assert (await second.recv())["event"] == "pong"  # no stale ready frame queued
    finally:
        if first is not None:
            first.close()
        if second is not None:
            second.close()
        eng.shutdown.set()
        await asyncio.wait_for(task, 5)
        shutil.rmtree(sock_dir, ignore_errors=True)


async def test_full_dictation_flow(engine):
    eng, sock = engine
    client = await connect(sock)
    ready = await client.recv()
    assert ready["event"] == "ready"
    from velora_engine.config import DEFAULT_STT_MODEL

    assert ready["stt_model"] == DEFAULT_STT_MODEL

    await client.send_json({"cmd": "start", "session": "s1", "context": {"bundle_id": "com.apple.Notes", "app_name": "Notes", "mode": None}})
    for _ in range(10):  # ~1s of audio
        await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "s1"})

    transcript = await client.recv_event("transcript")
    assert transcript["session"] == "s1"
    assert transcript["raw"] == "hello world this is a fake transcript"
    assert isinstance(transcript["ms"], int)

    final = await client.recv_event("final")
    assert final["session"] == "s1"
    assert final["mode"] == "Note"
    assert final["raw"] == "hello world this is a fake transcript"
    # fake mode has no LLM: raw is inserted as-is (never lose the user's words)
    assert final["cleanup_applied"] is False
    assert final["text"] == "hello world this is a fake transcript"
    assert isinstance(final["cleanup_ms"], int)
    assert "auto_stopped" not in final  # only present on max-duration auto-stop
    # socket must be private to the user
    assert (sock.stat().st_mode & 0o777) == 0o600
    client.close()


async def test_hard_wedged_cleanup_sends_raw_final_then_restarts_engine(engine):
    eng, sock = engine

    class PoisoningCleanup:
        loaded = True
        model_id = "fake-poisoned"
        unhealthy = False

        async def cleanup(self, raw, _prompt, **_kwargs):
            self.unhealthy = True
            return CleanupResult(raw, False, 12, "timeout_hard")

    eng.cleanup = PoisoningCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start", "session": "poisoned", "context": {
            "bundle_id": "com.apple.Notes", "app_name": "Notes",
        },
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "poisoned"})

    final = await client.recv_event("final")
    assert final["text"] == final["raw"]
    assert final["cleanup_applied"] is False
    assert eng.shutdown.is_set()
    client.close()


async def test_partials_emitted(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s2", "context": {}})
    await client.send_audio(AUDIO)
    partial = await client.recv_event("partial")
    assert partial["session"] == "s2"
    assert "samples" in partial["text"]
    await client.send_json({"cmd": "cancel", "session": "s2"})
    await client.recv_event("cancelled")
    client.close()


async def test_start_prepares_cleanup_prefix_without_blocking_audio(engine):
    eng, sock = engine

    class BlockingPrefixCleanup:
        loaded = True
        model_id = "fake-prefix"

        def __init__(self):
            self.calls = []
            self.release = asyncio.Event()

        async def prepare_prefix(self, candidates, cancel_event=None):
            self.calls.append((candidates, cancel_event))
            await self.release.wait()

    cleanup = BlockingPrefixCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start",
        "session": "prefill-1",
        "context": {
            "bundle_id": "com.apple.Notes",
            "app_name": "Notes",
            "entities": [{"type": "nearby", "value": "cursor text"}],
        },
    })

    for _ in range(100):
        if cleanup.calls:
            break
        await asyncio.sleep(0.01)
    assert len(cleanup.calls) == 1
    candidates, cancel_event = cleanup.calls[0]
    assert len(candidates) == 2
    assert cancel_event is not None and not cancel_event.is_set()

    # Prefix inference remains blocked, but the recording feeder is live.
    await client.send_audio(AUDIO)
    partial = await client.recv_event("partial")
    assert partial["session"] == "prefill-1"

    await client.send_json({"cmd": "cancel", "session": "prefill-1"})
    await client.recv_event("cancelled")
    assert cancel_event.is_set()
    cleanup.release.set()
    client.close()


async def test_cancel_discards(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s3", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "cancel", "session": "s3"})
    cancelled = await client.recv_event("cancelled")
    assert cancelled["session"] == "s3"

    # no transcript/final should arrive; a ping must be answered next
    await client.send_json({"cmd": "ping"})
    evt = await client.recv()
    assert evt["event"] == "pong"

    # engine is idle again: a fresh session works end to end
    await client.send_json({"cmd": "start", "session": "s4", "context": {"bundle_id": "com.apple.Terminal"}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "s4"})
    final = await client.recv_event("final")
    assert final["session"] == "s4"
    assert final["mode"] == "Terminal"
    client.close()


async def test_cancel_sends_confirmation_then_restarts_unhealthy_cleanup(engine):
    eng, sock = engine

    class UnhealthyCleanup:
        loaded = True
        model_id = "fake-unhealthy"
        unhealthy = False

    cleanup = UnhealthyCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "cancel-poisoned", "context": {}})
    await client.send_audio(AUDIO)
    cleanup.unhealthy = True
    await client.send_json({"cmd": "cancel", "session": "cancel-poisoned"})

    cancelled = await client.recv_event("cancelled")
    assert cancelled["session"] == "cancel-poisoned"
    assert eng.shutdown.is_set()
    client.close()


async def test_malformed_frames_get_error_not_crash(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")

    # bad JSON payload
    client.writer.write(protocol.encode_frame(protocol.FRAME_JSON, b"{not json"))
    await client.writer.drain()
    evt = await client.recv()
    assert evt["event"] == "error"

    # unknown frame type
    client.writer.write(protocol.encode_frame(0x7F, b"\x00\x01"))
    await client.writer.drain()
    evt = await client.recv()
    assert evt["event"] == "error"

    # unknown command
    await client.send_json({"cmd": "warp_drive"})
    evt = await client.recv()
    assert evt["event"] == "error"

    # stop with no session
    await client.send_json({"cmd": "stop", "session": "nope"})
    evt = await client.recv()
    assert evt["event"] == "error"

    # engine still healthy
    await client.send_json({"cmd": "ping"})
    assert (await client.recv())["event"] == "pong"
    client.close()


async def test_status_and_reload(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "status"})
    status = await client.recv_event("status")
    assert status["state"] == "idle"
    assert any(m["id"] == "mlx-community/parakeet-tdt-0.6b-v2" for m in status["models"])
    await client.send_json({"cmd": "reload_config"})
    assert (await client.recv())["event"] == "config_reloaded"
    client.close()


# ---- session ownership across reconnect (codex#4 / claude M5) ----


class FakeWriter:
    """Stands in for an asyncio.StreamWriter in ownership unit tests."""

    def __init__(self) -> None:
        self.closed = False

    def write(self, data: bytes) -> None:
        pass

    async def drain(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


async def test_displaced_client_cleanup_keeps_new_session(home, fake_stt):
    """A displaced old handler's cleanup must not abort the new client's session."""
    eng = Engine(Config(), parent_pid=None)
    eng.stt_ready.set()
    w_old, w_new = FakeWriter(), FakeWriter()

    eng.writer = w_old
    await eng._cmd_start({"session": "s-old", "context": {}})
    assert eng.session is not None and eng.session.owner is w_old

    # new client connects and starts its own session
    eng.writer = w_new
    await eng._cmd_start({"session": "s-new", "context": {}})
    assert eng.session.id == "s-new" and eng.session.owner is w_new

    # old handler's finally runs late: must NOT discard the new session
    await eng._client_cleanup(w_old)
    assert eng.session is not None and eng.session.id == "s-new"
    assert w_old.closed

    # the owning connection's cleanup does abort it
    await eng._client_cleanup(w_new)
    assert eng.session is None


async def test_reconnect_new_client_flow_survives(engine):
    """End-to-end: reconnect mid-dictation; the new client's session completes."""
    eng, sock = engine
    a = await connect(sock)
    await a.recv_event("ready")
    await a.send_json({"cmd": "start", "session": "s1", "context": {}})
    await a.send_audio(AUDIO)
    for _ in range(200):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)

    b = await connect(sock)  # displaces a
    await b.recv_event("ready")
    await b.send_json({"cmd": "start", "session": "s2", "context": {}})
    await b.send_audio(AUDIO)
    await b.send_json({"cmd": "stop", "session": "s2"})
    final = await b.recv_event("final")
    assert final["session"] == "s2"
    a.close()
    b.close()


# ---- bounded audio queue (codex#7 / claude M4) ----


async def test_queue_overflow_aborts_session(engine, monkeypatch):
    eng, sock = engine
    monkeypatch.setattr(server_mod, "QUEUE_MAX_FRAMES", 3)
    monkeypatch.setattr(server_mod, "MAX_DROPPED_FRAMES", 5)
    release = threading.Event()

    def stuck_feed(chunk):  # simulate STT far below realtime
        release.wait(10)
        return None

    monkeypatch.setattr(eng.stt, "feed_chunk", stuck_feed)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s-of", "context": {}})
    for _ in range(12):  # capacity (3) + in-flight (1) + drops past threshold
        await client.send_audio(AUDIO)

    evt = await client.recv(timeout=5)
    assert evt["event"] == "error"
    assert "overflow" in evt["message"]
    assert evt["session"] == "s-of"
    release.set()

    # engine recovered: idle again and responsive
    await client.send_json({"cmd": "ping"})
    assert (await client.recv())["event"] == "pong"
    assert eng.session is None
    client.close()


# ---- max recording duration auto-stop ----


async def test_auto_stop_at_max_duration(engine):
    eng, sock = engine
    eng.config.data["max_recording_s"] = 0.05  # 800 samples at 16 kHz
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s-cap", "context": {}})
    await client.send_audio(AUDIO)  # 1600 samples > cap → auto-finalize, no stop sent

    transcript = await client.recv_event("transcript")
    assert transcript["session"] == "s-cap"
    final = await client.recv_event("final")
    assert final["session"] == "s-cap"
    assert final["auto_stopped"] is True
    assert final["text"] == "hello world this is a fake transcript"
    assert eng.session is None
    client.close()


# ---- config key consumption: language ----


def test_whisper_language_mapping(monkeypatch):
    monkeypatch.delenv("VELORA_FAKE_STT", raising=False)
    from velora_engine.stt import WhisperBackend, create_backend, whisper_language

    assert whisper_language("auto") is None
    assert whisper_language("AUTO") is None
    assert whisper_language("") is None
    assert whisper_language(None) is None
    assert whisper_language(" de ") == "de"

    backend = create_backend("mlx-community/whisper-large-v3-turbo", "de")
    assert isinstance(backend, WhisperBackend)
    assert backend.language == "de"
    # parakeet is English-only: language is ignored (no attribute consumed)
    parakeet = create_backend("mlx-community/parakeet-tdt-0.6b-v2", "de")
    assert not isinstance(parakeet, WhisperBackend)


async def test_reload_config_propagates_language(engine, home):
    eng, sock = engine
    assert eng.config.language == "auto"
    client = await connect(sock)
    await client.recv_event("ready")
    (home / "config.json").write_text(json.dumps({"language": "de"}))
    await client.send_json({"cmd": "reload_config"})
    await client.recv_event("config_reloaded")
    assert eng.config.language == "de"
    assert eng.stt.language == "de"  # FakeBackend mirrors the whisper attribute
    client.close()


# ---- transcript privacy (M7) ----


def test_velora_home_created_private(config):
    assert (config.home.stat().st_mode & 0o777) == 0o700


async def test_screen_context_entities_tag_end_to_end(engine, monkeypatch):
    """Full socket path: entities in the start context reach cleanup and a
    spoken 'tag' phrase becomes an @-mention (Cursor/code, Raw mode, no LLM)."""
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "please fix the bug in tag authCheck now")
    eng, sock = engine
    client = await connect(sock)
    await client.recv()  # ready

    await client.send_json({
        "cmd": "start", "session": "sc1",
        "context": {
            "bundle_id": "com.todesktop.230313mzl4w4u92",  # Cursor → code/Raw
            "app_name": "Cursor", "mode": None,
            "entities": [{"type": "file", "value": "authCheck.ts"}],
        },
    })
    for _ in range(6):
        await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "sc1"})

    final = await client.recv_event("final")
    assert final["session"] == "sc1"
    assert "@authCheck.ts" in final["text"], final["text"]
    assert "tag authCheck" not in final["text"]
    client.close()
