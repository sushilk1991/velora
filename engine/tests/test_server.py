"""Server integration test over a real unix socket with the fake STT backend
(VELORA_FAKE_STT=1): start → audio → stop → transcript/final, and cancel."""

import asyncio
import contextlib
import json
import logging
import os
import shutil
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import numpy as np
import pytest

from fixtures.fake_cleanup_worker import kill_workers
from test_cleanup_process import (
    deliver_sigkill_late,
    fixture_command,
    process_gone,
    record_spawns,
)

import velora_engine.cleanup_process as cleanup_process_mod
import velora_engine.server as server_mod
from velora_engine.cleanup import CleanupResult
from velora_engine.cleanup_process import CleanupProcess
from velora_engine import formatting, protocol
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


def test_config_patch_save_preserves_newer_unrelated_writer_values(home):
    config = Config(home)
    config.data["stt_model"] = "example/new-stt"

    # Mirror the app committing a preference after this Config instance loaded.
    on_disk = json.loads(config.config_path.read_text())
    on_disk["language"] = "hi"
    on_disk["future_app_key"] = {"keep": True}
    config.config_path.write_text(json.dumps(on_disk))

    config.save(keys={"stt_model"})

    projected = json.loads(config.config_path.read_text())
    assert projected["stt_model"] == "example/new-stt"
    assert projected["language"] == "hi"
    assert projected["future_app_key"] == {"keep": True}


@pytest.fixture
async def engine(home, fake_stt):
    config = Config()
    eng = Engine(config, parent_pid=None, hard_exit=Mock())
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


async def restart_exit(eng: Engine) -> None:
    """Wait for the engine's scheduled restart to reach its hard exit.

    The restart gives pending audio archive writes up to
    CLEANUP_RESTART_ARCHIVE_GRACE_S before its CLEANUP_RESTART_GRACE_S, so a
    fixed sleep of that grace raced a dictation's archive write under load.
    """
    await asyncio.wait_for(
        eng._cleanup_restart_task,
        server_mod.CLEANUP_RESTART_ARCHIVE_GRACE_S
        + server_mod.CLEANUP_RESTART_GRACE_S + 1.0,
    )


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


async def test_startup_falls_back_to_mlx_when_transcribe_cpp_cannot_load(
    home, monkeypatch
):
    from velora_engine import models
    from velora_engine.config import DEFAULT_STT_MODEL
    from velora_engine.stt import TranscribeCppWhisperBackend, WhisperBackend

    monkeypatch.delenv("VELORA_FAKE_STT", raising=False)
    config = Config()
    config.data.update({
        "stt_model": models.TRANSCRIBE_CPP_Q8_MODEL,
        "cleanup_enabled": False,
    })
    config.save()
    monkeypatch.setattr(models, "is_cached", lambda _model_id: True)
    monkeypatch.setattr(
        TranscribeCppWhisperBackend,
        "load",
        lambda self: (_ for _ in ()).throw(RuntimeError("native load failed")),
    )

    def load_fallback_after_app_config_write(_backend):
        # Model setup can take minutes. Mirror the app updating an unrelated
        # setting directly on disk while the fallback is loading.
        latest = Config(home)
        latest.data["language"] = "hi"
        latest.save()

    monkeypatch.setattr(WhisperBackend, "load", load_fallback_after_app_config_write)
    eng = Engine(config, parent_pid=None)

    await eng._load_models()

    assert eng.stt_ready.is_set()
    assert eng.shutdown.is_set() is False
    assert eng.stt.model_id == DEFAULT_STT_MODEL
    assert Config(home).stt_model == DEFAULT_STT_MODEL
    assert Config(home).language == "hi"
    assert eng.config.language == "hi"
    assert eng.stt.language == "hi"


async def test_second_pre_ready_client_cannot_displace_setup_owner(home, fake_stt):
    """A diagnostic connection cannot steal startup events from the app."""
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
        rejected = await second.recv()
        assert rejected == {
            "event": "error",
            "message": "Engine already has an active client",
            "fatal": True,
        }
        for _ in range(100):
            if eng._client_gen == 1:
                break
            await asyncio.sleep(0.01)
        assert eng._client_gen == 1

        allow_ready.set()
        ready = await first.recv()
        assert ready["event"] == "ready"
        assert ready["setup_complete"] is False

        finish_setup.set()
        assert (await first.recv())["event"] == "setup_complete"
        await first.send_json({"cmd": "ping"})
        assert (await first.recv())["event"] == "pong"
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
    # Fake mode has no LLM: keep every word and apply the deterministic final
    # punctuation contract.
    assert final["cleanup_applied"] is False
    assert final["text"] == "hello world this is a fake transcript."
    assert isinstance(final["cleanup_ms"], int)
    assert isinstance(final["cleanup_wall_ms"], int)
    assert isinstance(final["total_ms"], int)
    assert final["total_ms"] >= transcript["ms"]
    assert "auto_stopped" not in final  # only present on max-duration auto-stop
    # socket must be private to the user
    assert (sock.stat().st_mode & 0o777) == 0o600
    client.close()


async def test_stream_typing_enables_preview_only_for_its_session(engine):
    eng, sock = engine
    # The fake backend has no preview lane by default; add the same public flag
    # Whisper exposes so this protocol gate stays deterministic and model-free.
    eng.stt.preview_enabled = False
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({
        "cmd": "start", "session": "stream-preview",
        "context": {"stream_typing": True},
    })
    for _ in range(100):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)
    assert eng.session is not None
    assert eng.stt.preview_enabled is True
    await client.send_json({"cmd": "cancel", "session": "stream-preview"})
    await client.recv_event("cancelled")
    assert eng.stt.preview_enabled is False

    await client.send_json({
        "cmd": "start", "session": "ordinary-no-preview", "context": {},
    })
    for _ in range(100):
        if eng.session is not None and eng.session.id == "ordinary-no-preview":
            break
        await asyncio.sleep(0.01)
    assert eng.stt.preview_enabled is False
    await client.send_json({"cmd": "cancel", "session": "ordinary-no-preview"})
    await client.recv_event("cancelled")
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
    assert final["text"] == final["raw"] + "."
    assert final["cleanup_applied"] is False
    assert eng.shutdown.is_set()
    await restart_exit(eng)
    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)
    client.close()


async def test_killed_cleanup_child_returns_raw_and_engine_serves_next_dictation(
    engine, monkeypatch
):
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    await cleanup.load_async("warm prompt")
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    stalled_raw = (
        "this __hang__ cleanup request has enough words to use the writing model"
    )
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", stalled_raw)
    await client.send_json({
        "cmd": "start",
        "session": "child-stall",
        "context": {"bundle_id": "com.apple.Notes", "app_name": "Notes"},
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "child-stall"})
    final = await client.recv_event("final")

    assert final["raw"] == stalled_raw
    assert final["cleanup_applied"] is False
    assert final["cleanup_ms"] == 1_500
    assert final["cleanup_wall_ms"] >= 1_500
    assert final["cleanup_recovery_pending"] is True
    assert final["cleanup_recovery_wait_ms"] == 0
    assert not eng.shutdown.is_set()

    await client.send_json({"cmd": "ping"})
    assert (await client.recv_event("pong"))["event"] == "pong"
    for _ in range(500):
        if cleanup.loaded:
            break
        await asyncio.sleep(0.01)
    assert cleanup.loaded

    monkeypatch.setenv(
        "VELORA_FAKE_STT_TEXT",
        "the replacement writing worker completes this second dictation correctly",
    )
    await client.send_json({
        "cmd": "start",
        "session": "after-child-stall",
        "context": {"bundle_id": "com.apple.Notes", "app_name": "Notes"},
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "after-child-stall"})
    recovered = await client.recv_event("final")
    assert recovered["session"] == "after-child-stall"
    assert recovered["cleanup_applied"] is True
    assert not eng.shutdown.is_set()
    client.close()


async def test_cleanup_model_swap_reaps_old_worker_before_ack(engine, monkeypatch):
    eng, sock = engine
    def new_cleanup(model_id: str, **kwargs) -> CleanupProcess:
        return CleanupProcess(
            model_id,
            worker_command=fixture_command(),
            **kwargs,
        )

    old = new_cleanup("fake-old")
    await old.load_async("warm prompt")
    old_pid = old.pid
    assert old_pid is not None
    eng.cleanup = old
    monkeypatch.setattr(server_mod, "CleanupProcess", new_cleanup)
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)

    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "set_model",
        "kind": "cleanup",
        "model": "fake-new",
    })
    changed = await client.recv_event("model_set")

    assert changed["model"] == "fake-new"
    assert eng.cleanup is not old
    assert eng.cleanup is not None and eng.cleanup.loaded
    try:
        os.kill(old_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("retired cleanup model survived model_set acknowledgement")
    client.close()


# How long serve() may take to return after shutdown before a test fails.
SERVE_SHUTDOWN_MAX_S = 5.0


@contextlib.asynccontextmanager
async def serve_with_startup_worker(
    monkeypatch, *worker_flags: str, is_cached=lambda _model_id: True,
    retry_idle_s: float = 0.0, load_then_swap: bool = False,
):
    """Serve an engine whose startup cleanup load runs the fixture worker.

    Yields (engine, socket, workers, spawned): every CleanupProcess the engine
    built, with the monotonic time it was built, in order; and the pid of
    every worker spawned, in order. A retry attempt waits `retry_idle_s` of
    idle. `load_then_swap` allows set_model's designed overlap: its model
    loads beside the adopted one, which it then replaces.
    """
    workers: list[tuple[float, CleanupProcess]] = []
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    monkeypatch.setattr(server_mod, "CLEANUP_RETRY_IDLE_S", retry_idle_s)

    def new_cleanup(model_id: str, **kwargs) -> CleanupProcess:
        cleanup = CleanupProcess(
            model_id,
            worker_command=[*fixture_command(), *worker_flags],
            **kwargs,
        )
        workers.append((time.monotonic(), cleanup))
        return cleanup

    monkeypatch.setattr(server_mod, "CleanupProcess", new_cleanup)
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(server_mod.models, "is_cached", is_cached)
    # Adoption prunes superseded models from the real Hugging Face cache.
    monkeypatch.setattr(server_mod.models, "remove_from_cache", lambda _model_id: 0)
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    sock_dir = Path(tempfile.mkdtemp(prefix="velora-t-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    for _ in range(100):
        if sock.exists():
            break
        await asyncio.sleep(0.01)
    try:
        yield eng, sock, workers, spawned
    finally:
        eng.shutdown.set()
        try:
            # asyncio.wait, not wait_for: serve() can swallow wait_for's
            # cancel and return, so a retry that hung shutdown passed at the
            # timeout.
            done, _ = await asyncio.wait({task}, timeout=SERVE_SHUTDOWN_MAX_S)
            hung = task not in done
            if hung:
                task.cancel()
                done, _ = await asyncio.wait({task}, timeout=SERVE_SHUTDOWN_MAX_S)
            assert not hung, (
                f"serve() still running {SERVE_SHUTDOWN_MAX_S:.0f} s after shutdown"
                + ("" if task in done else ", and after a cancel"))
            task.result()
            # The startup retry, hung or not, ended with serve().
            retry = eng._cleanup_retry_task
            assert retry is None or retry.done()
            # Shutdown stops the retry and reaps every worker, including one
            # a retry was loading; none is built after it.
            built = len(workers)
            await asyncio.sleep(0.3)
            assert len(workers) == built
            assert all(process_gone(pid) for pid in spawned)
            # No worker, and so no model load, ever ran beside another.
            if not load_then_swap:
                assert alive_at_spawn == []
        finally:
            shutil.rmtree(sock_dir, ignore_errors=True)
            # A failed check above leaves no worker that ignores SIGTERM
            # running into later tests.
            kill_workers(pid for pid in spawned if not process_gone(pid))


async def dictate(client: Client, session: str) -> dict:
    await client.send_json({"cmd": "start", "session": session, "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": session})
    return await client.recv_event("final", timeout=2.0)


async def test_timed_out_startup_cleanup_load_is_retried(
    home, fake_stt, monkeypatch, tmp_path
):
    """The one-shot startup load left dictation raw until the app restarted."""
    # The retried worker must spawn and load within this, even on a busy machine.
    monkeypatch.setattr(cleanup_process_mod, "LOAD_TIMEOUT_S", 1.0)
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    monkeypatch.setenv(
        "VELORA_FAKE_STT_TEXT",
        "the retried writing worker cleans up this dictation once it loads",
    )
    async with serve_with_startup_worker(
        monkeypatch, "--hang-first-load", str(tmp_path / "hung")
    ) as (eng, sock, workers, spawned):
        client = await connect(sock)
        ready = await client.recv_event("ready")
        if not ready["setup_complete"]:
            await client.recv_event("setup_complete")
        for _ in range(1000):
            if eng.cleanup is not None:
                break
            await asyncio.sleep(0.01)

        assert eng.cleanup is not None and eng.cleanup.loaded
        assert len(workers) == 2
        assert process_gone(spawned[0])  # the timed-out worker was reaped
        final = await dictate(client, "after-retry")
        assert final["cleanup_applied"] is True
        client.close()


async def test_failing_startup_cleanup_load_backs_off(home, fake_stt, monkeypatch):
    """A model that never loads is retried on the capped backoff, not in a loop."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_MAX_S", 0.2)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load"
    ) as (eng, _sock, workers, spawned):
        for _ in range(1000):
            if len(workers) >= 4:
                break
            await asyncio.sleep(0.01)

        assert eng.cleanup is None
        assert not eng.shutdown.is_set()
        assert eng.setup_complete
        built = [at for at, _ in workers]
        gaps = [later - earlier for earlier, later in zip(built, built[1:])]
        assert len(gaps) >= 3
        for retry, gap in enumerate(gaps):
            assert gap >= min(0.05 * 2 ** retry, 0.2)
        assert all(process_gone(pid) for pid in spawned[:3])


async def test_cleanup_load_retry_waits_for_dictation(home, fake_stt, monkeypatch):
    """A retry never loads during a dictation, whose final stays raw and prompt."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.2)
    monkeypatch.setenv(
        "VELORA_FAKE_STT_TEXT",
        "this dictation finishes raw while the writing model retries its load",
    )
    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load"
    ) as (eng, sock, workers, _spawned):
        client = await connect(sock)
        ready = await client.recv_event("ready")
        if not ready["setup_complete"]:
            await client.recv_event("setup_complete")
        await client.send_json({"cmd": "start", "session": "held", "context": {}})
        await client.send_audio(AUDIO)
        await client.recv_event("partial")
        built = len(workers)
        await asyncio.sleep(0.6)

        assert len(workers) == built
        await client.send_json({"cmd": "stop", "session": "held"})
        final = await client.recv_event("final", timeout=2.0)
        assert final["cleanup_applied"] is False
        assert final["text"] == final["raw"] + "."
        for _ in range(200):
            if len(workers) > built:
                break
            await asyncio.sleep(0.01)
        assert len(workers) > built  # the held retry ran once dictation ended
        client.close()


async def wait_for(condition, timeout_s: float = 5.0) -> None:
    for _ in range(int(timeout_s * 100)):
        if condition():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("condition not reached")


async def ready_client(sock: Path) -> Client:
    client = await connect(sock)
    ready = await client.recv_event("ready")
    if not ready["setup_complete"]:
        await client.recv_event("setup_complete")
    return client


async def test_set_model_during_a_cleanup_retry_load_loads_one_model_at_a_time(
    home, fake_stt, monkeypatch, tmp_path
):
    """set_model stops a retry mid-load before loading its own model.

    Before: both loaded at once, two copies of the weights in memory.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--load-delay", "0.8",
    ) as (eng, sock, workers, spawned):
        client = await ready_client(sock)
        await wait_for(lambda: len(spawned) == 2)  # the retry is loading
        retry_pid = spawned[1]

        await client.send_json({
            "cmd": "set_model", "kind": "cleanup", "model": "fake-new"})
        changed = await client.recv_event("model_set", timeout=5.0)

        assert changed["model"] == "fake-new"
        assert eng.cleanup is not None and eng.cleanup.model_id == "fake-new"
        assert eng.cleanup.loaded
        assert len(spawned) == 3
        assert process_gone(retry_pid)
        assert eng._cleanup_retry_task is not None and eng._cleanup_retry_task.done()
        client.close()


async def test_failed_set_model_restarts_the_stopped_cleanup_retry(
    home, fake_stt, monkeypatch
):
    """The retry that set_model stopped runs again when set_model's own load
    fails, so dictation does not stay raw until the next launch."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load"
    ) as (eng, sock, workers, spawned):
        client = await ready_client(sock)
        await wait_for(lambda: eng._cleanup_retry_task is not None)
        first_retry = eng._cleanup_retry_task

        await client.send_json({
            "cmd": "set_model", "kind": "cleanup", "model": "fake-new"})
        error = await client.recv_event("error", timeout=5.0)

        assert "set_model" in error["message"]
        assert first_retry.done()
        assert eng.cleanup is None
        restarted = eng._cleanup_retry_task
        assert restarted is not None and restarted is not first_retry
        assert not restarted.done()
        built = len(spawned)
        await wait_for(lambda: len(spawned) > built)  # the restarted retry loads
        client.close()


async def test_dictation_start_abandons_a_cleanup_retry_load(
    home, fake_stt, monkeypatch, tmp_path
):
    """A retry load in flight when a dictation starts is abandoned at once and
    runs again after it; the dictation itself stays raw.

    Before: the load finished during the dictation, competing for the GPU.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    monkeypatch.setenv(
        "VELORA_FAKE_STT_TEXT",
        "a dictation that starts while the writing model is loading stays raw",
    )
    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--load-delay", "0.8",
    ) as (eng, sock, workers, spawned):
        client = await ready_client(sock)
        await wait_for(lambda: len(spawned) == 2)  # the retry is loading
        retry_pid = spawned[1]

        await client.send_json({"cmd": "start", "session": "mid-load", "context": {}})
        await client.send_audio(AUDIO)
        await client.recv_event("partial")
        await wait_for(lambda: process_gone(retry_pid), timeout_s=1.0)
        assert eng.cleanup is None
        assert len(spawned) == 2

        await client.send_json({"cmd": "stop", "session": "mid-load"})
        final = await client.recv_event("final", timeout=2.0)
        assert final["cleanup_applied"] is False
        await wait_for(lambda: eng.cleanup is not None and eng.cleanup.loaded)
        final = await dictate(client, "after-load")
        assert final["cleanup_applied"] is True
        client.close()


async def test_cleanup_retry_rechecks_for_a_dictation_after_the_cache_check(
    home, fake_stt, monkeypatch
):
    """A dictation that starts while the retry checks the model cache holds
    the load until it ends."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    cleanup_model = Config().cleanup_model
    cache_checks = 0
    retry_checking = threading.Event()

    def slow_is_cached(model_id: str) -> bool:
        nonlocal cache_checks
        if model_id != cleanup_model:
            return True
        cache_checks += 1
        if cache_checks == 2:  # the retry's check; the first is startup's
            retry_checking.set()
            time.sleep(0.3)
        return True

    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load", is_cached=slow_is_cached,
    ) as (eng, sock, workers, spawned):
        client = await ready_client(sock)
        await wait_for(retry_checking.is_set)
        built = len(spawned)
        await client.send_json({"cmd": "start", "session": "held", "context": {}})
        await client.send_audio(AUDIO)
        await client.recv_event("partial")
        await asyncio.sleep(0.5)
        assert len(spawned) == built

        await client.send_json({"cmd": "stop", "session": "held"})
        await client.recv_event("final", timeout=2.0)
        await wait_for(lambda: len(spawned) > built)
        client.close()


async def test_cleanup_retry_waits_for_batch_jobs(home, fake_stt, monkeypatch):
    """Background batch work (the vocabulary miner) holds a retry load too."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load"
    ) as (eng, _sock, workers, spawned):
        await wait_for(lambda: eng._cleanup_retry_task is not None)
        eng._begin_batch_job(lower_priority=True)
        await asyncio.sleep(0.8)
        assert len(spawned) == 1

        eng._end_batch_job(lower_priority=True)
        await wait_for(lambda: len(spawned) > 1)


async def test_cleanup_retry_loads_the_model_config_names_after_a_switch(
    home, fake_stt, monkeypatch, tmp_path
):
    """A retry whose load finishes for a model config no longer names tries
    again with the new one.

    Before: it closed the loaded engine and stopped retrying for good.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--load-delay", "0.5",
    ) as (eng, _sock, workers, spawned):
        await wait_for(lambda: len(spawned) == 2)  # the retry is loading
        eng.config.data["cleanup_model"] = "fake-other"

        await wait_for(lambda: eng.cleanup is not None)
        assert eng.cleanup.model_id == "fake-other"
        assert eng.cleanup.loaded


def hung_retry_flags(marker_dir: Path) -> tuple[str, ...]:
    """Worker flags for a startup retry whose load hangs.

    The startup load fails at once. Every later load never returns, touches
    marker_dir/<pid>, and leaves a worker only SIGKILL ends (see
    wait_for_hung_retry_load).
    """
    return (
        "--fail-first-load", str(marker_dir / "startup-load-failed"),
        "--hang-every-load", "--hang-marker-dir", str(marker_dir),
    )


async def wait_for_hung_retry_load(spawned: list[int], marker_dir: Path) -> None:
    """Return once the retry's worker holds its load and only SIGKILL ends it.

    A stop from then on ends the load through `_reap`. Waiting for the spawn
    alone raced: a stop before the worker's socket connected killed it
    inside `_spawn`, which never calls `_reap`.

        spawn recorded ─▶ socket connects ─▶ load sent ─▶ SIGTERM ignored
           (old wait)                                     (this wait)
    """
    # This spans two cold worker starts, the backoff and the load read, all
    # slower on a loaded machine.
    await wait_for(
        lambda: len(spawned) == 2 and (marker_dir / str(spawned[1])).exists(),
        timeout_s=15.0,
    )


async def test_shutdown_while_a_retry_abandons_its_load_stops_the_retry(
    home, fake_stt, monkeypatch, tmp_path
):
    """Shutdown stops a retry that is still abandoning its load for
    foreground work.

    Before: the abandon awaited the load under suppress(CancelledError),
    which also swallowed serve()'s cancel; the retry then waited for idle
    forever and serve() never returned.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    async with serve_with_startup_worker(
        monkeypatch, *hung_retry_flags(tmp_path)
    ) as (eng, _sock, workers, spawned):
        await wait_for_hung_retry_load(spawned, tmp_path)

        # Hold the retry's abandon open after its worker is reaped, as a
        # worker slow to exit does, so shutdown lands inside it.
        reaped = asyncio.Event()
        reap = CleanupProcess._reap

        async def slow_reap(self, process):
            await reap(self, process)
            reaped.set()
            await asyncio.sleep(0.5)

        monkeypatch.setattr(CleanupProcess, "_reap", slow_reap)
        eng._starting = True
        await asyncio.wait_for(reaped.wait(), 2.0)
        eng.shutdown.set()
        await wait_for(lambda: eng._cleanup_retry_task.done(), timeout_s=3.0)


async def test_shutdown_during_a_hung_cleanup_retry_load_reaps_the_worker(
    home, fake_stt, monkeypatch, tmp_path
):
    """Shutdown stops a retry whose load never returns, and its worker, which
    ignores SIGTERM, is gone once serve() returns."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    async with serve_with_startup_worker(
        monkeypatch, *hung_retry_flags(tmp_path)
    ) as (eng, _sock, workers, spawned):
        # Shut down only once the retry's worker ignores SIGTERM. A fixed
        # 0.2 s sleep usually ended before it read its load, so SIGTERM
        # alone reaped it and the SIGKILL path went untested.
        await wait_for_hung_retry_load(spawned, tmp_path)
        assert eng._cleanup_loading is not None
        started = time.monotonic()
        eng.shutdown.set()
    # The teardown waited 0.3 s for stray respawns and found every pid gone.
    assert time.monotonic() - started < 3.0


async def test_stopping_a_retry_that_abandons_its_load_ends_it(
    home, fake_stt, monkeypatch, tmp_path
):
    """set_model's stop of the startup retry ends a retry that is still
    abandoning its load for foreground work.

    Before: the abandon swallowed the stop's cancel too, so the retry
    waited out the foreground work and set_model waited on it.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    async with serve_with_startup_worker(
        monkeypatch, *hung_retry_flags(tmp_path)
    ) as (eng, _sock, workers, spawned):
        await wait_for_hung_retry_load(spawned, tmp_path)

        # Hold the abandon open after its worker is reaped, as a worker
        # slow to exit does, so the stop lands inside it.
        reaped = asyncio.Event()
        reap = CleanupProcess._reap

        async def slow_reap(self, process):
            await reap(self, process)
            reaped.set()
            await asyncio.sleep(0.5)

        monkeypatch.setattr(CleanupProcess, "_reap", slow_reap)
        eng._starting = True
        await asyncio.wait_for(reaped.wait(), 2.0)

        # asyncio.wait, not wait_for: the stop absorbs wait_for's cancel and
        # keeps waiting, so a retry that never ends hung the suite.
        stopping = asyncio.create_task(eng._stop_cleanup_retry())
        done, _ = await asyncio.wait({stopping}, timeout=3.0)
        assert stopping in done, "the stop still waits on the retry after 3 s"
        stopping.result()


async def test_a_load_failing_as_it_is_abandoned_is_a_failed_retry(
    home, fake_stt, monkeypatch, caplog
):
    """A retry load that fails while foreground work abandons it counts as a
    failed attempt, which backs off, not as a pause, which does not."""
    caplog.set_level(logging.INFO, logger="velora.server")
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.3)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-every-load"
    ) as (eng, _sock, workers, spawned):
        await wait_for(lambda: eng._cleanup_retry_task is not None)
        loading = asyncio.Event()

        async def load_failing_on_cancel(self, warm_system_prompt=None):
            # A load whose own teardown fails, as a reap that errors would.
            loading.set()
            try:
                await asyncio.sleep(3600)
            except asyncio.CancelledError:
                raise RuntimeError("load failed while abandoned") from None

        monkeypatch.setattr(CleanupProcess, "load_async", load_failing_on_cancel)
        await asyncio.wait_for(loading.wait(), 2.0)
        eng._starting = True

        # Attempt 1 failed through the abandon, not through a real load that
        # ran before the patch: the error it logged is the abandon's.
        await wait_for(lambda: any(
            record.getMessage().startswith("writing model retry 1 failed")
            and record.exc_info is not None
            and str(record.exc_info[1]) == "load failed while abandoned"
            for record in caplog.records
        ))
        assert "paused for foreground work" not in caplog.text


async def test_set_model_during_the_startup_load_keeps_a_working_cleanup(
    home, fake_stt, monkeypatch
):
    """set_model waits for the startup load, which is adopted; when set_model's
    own model then fails to load, the startup model keeps serving.

    Before: set_model loaded beside the startup load and failed; the startup
    engine then found config naming the new model and closed itself, so
    dictation stayed raw until the next launch.
    """
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)
    async with serve_with_startup_worker(
        monkeypatch, "--load-delay", "0.8", "--fail-load-for", "fake-new",
        load_then_swap=True,
    ) as (eng, sock, _workers, spawned):
        client = await connect(sock)
        await client.recv_event("ready")
        await wait_for(lambda: len(spawned) == 1)  # the startup load runs
        # Whether the startup engine was adopted when each later worker spawned.
        adopted_at_spawn: list[bool] = []
        spawn = CleanupProcess._spawn

        async def recording_spawn(self) -> None:
            adopted_at_spawn.append(eng.cleanup is not None)
            await spawn(self)

        monkeypatch.setattr(CleanupProcess, "_spawn", recording_spawn)
        # The app writes its pick to config.json, then sends set_model.
        eng.config.data["cleanup_model"] = "fake-new"
        eng.config.save(keys={"cleanup_model"})

        await client.send_json({
            "cmd": "set_model", "kind": "cleanup", "model": "fake-new"})
        error = await client.recv_event("error", timeout=5.0)

        assert "set_model" in error["message"]
        await wait_for(lambda: eng.cleanup is not None and eng.cleanup.loaded)
        # set_model loaded only after the startup load ended, never beside it.
        assert adopted_at_spawn == [True]
        client.close()


async def test_startup_load_skips_a_model_set_model_already_installed(
    home, fake_stt, monkeypatch
):
    """A set_model that takes the load lock before the startup load installs
    its model; the startup load then loads nothing beside it."""
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)
    startup_model = Config().cleanup_model
    startup_checking = threading.Event()

    def slow_startup_cache_check(model_id: str) -> bool:
        if model_id == startup_model and not startup_checking.is_set():
            startup_checking.set()
            time.sleep(0.8)  # set_model takes the lock meanwhile
        return True

    async with serve_with_startup_worker(
        monkeypatch, is_cached=slow_startup_cache_check,
    ) as (eng, sock, _workers, spawned):
        client = await connect(sock)
        await client.recv_event("ready")
        await wait_for(startup_checking.is_set)
        await client.send_json({
            "cmd": "set_model", "kind": "cleanup", "model": "fake-new"})
        await client.recv_event("model_set", timeout=5.0)
        await wait_for(lambda: eng.setup_complete)

        assert eng.cleanup is not None and eng.cleanup.model_id == "fake-new"
        assert len(spawned) == 1
        client.close()


async def test_failed_set_model_starts_a_retry_when_none_runs(
    home, fake_stt, monkeypatch, tmp_path
):
    """A set_model whose load fails with no engine left starts the retry, even
    when no retry was running for it to stop.

    Before: only a retry that set_model had stopped ran again, so cleanup
    stayed absent until the next launch.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    monkeypatch.setattr(server_mod.models, "ensure_downloaded", lambda _model_id: None)
    startup_model = Config().cleanup_model
    checks = 0

    def missing_at_the_first_retry(model_id: str) -> bool:
        nonlocal checks
        if model_id != startup_model:
            return True
        checks += 1
        return checks != 2  # startup's check passes; the retry's stops it

    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--fail-load-for", "fake-new", is_cached=missing_at_the_first_retry,
    ) as (eng, sock, _workers, _spawned):
        client = await ready_client(sock)
        await wait_for(
            lambda: eng._cleanup_retry_task is not None and eng._cleanup_retry_task.done())
        assert eng.cleanup is None

        await client.send_json({
            "cmd": "set_model", "kind": "cleanup", "model": "fake-new"})
        await client.recv_event("error", timeout=5.0)

        await wait_for(lambda: eng.cleanup is not None and eng.cleanup.loaded)
        assert eng.cleanup.model_id == startup_model
        client.close()


async def test_cleanup_retry_runs_once_at_a_time(home, monkeypatch):
    """A second start while a retry runs keeps the running one, which
    set_model can then stop."""
    monkeypatch.setattr(server_mod, "respawn_backoff_s", lambda _step: 3600.0)
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    eng._start_cleanup_retry()
    running = eng._cleanup_retry_task

    eng._start_cleanup_retry()

    assert eng._cleanup_retry_task is running
    await eng._stop_cleanup_retry()
    assert running.done()


async def test_meeting_notes_do_not_cancel_a_cleanup_retry_load(
    home, fake_stt, monkeypatch, tmp_path
):
    """Notes that start during a retry load wait for it, as they do for the
    startup load.

    Before: the retry counted notes as foreground work and abandoned its
    load, and the notes then failed with no model to wait for.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--load-delay", "0.8",
    ) as (eng, _sock, _workers, spawned):
        await wait_for(lambda: len(spawned) == 2)  # the retry is loading
        retry_pid = spawned[1]
        eng._meeting_notes_running = True

        await wait_for(lambda: eng.cleanup is not None and eng.cleanup.loaded)
        assert eng.cleanup.pid == retry_pid
        eng._meeting_notes_running = False


async def test_cleanup_retry_waits_for_continuous_idle(
    home, fake_stt, monkeypatch, tmp_path
):
    """Gaps between dictations shorter than a load start no retry load.

    Before: each gap spawned a worker that the next dictation abandoned, so a
    burst of dictations churned workers and never restored cleanup.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 0.05)
    async with serve_with_startup_worker(
        monkeypatch, "--fail-first-load", str(tmp_path / "failed"),
        "--load-delay", "0.8", retry_idle_s=1.0,
    ) as (eng, _sock, _workers, spawned):
        # Dictations 0.3 s long, 0.5 s apart: every gap is shorter than
        # both the load and the idle requirement.
        for _ in range(5):
            eng._editing = True
            await asyncio.sleep(0.3)
            eng._editing = False
            await asyncio.sleep(0.5)
        assert len(spawned) == 1  # the failed startup load only

        await wait_for(lambda: eng.cleanup is not None and eng.cleanup.loaded)
        assert len(spawned) == 2


async def test_stop_cleanup_retry_keeps_the_callers_cancellation(home):
    """Cancelling set_model while it stops the retry cancels set_model, once
    the retry has reaped its worker.

    Before: stopping the retry swallowed every CancelledError, including one
    aimed at its caller. Then it awaited the retry directly, which carried
    that cancel into the retry's reap and cut it short.
    """
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    reaped: list[str] = []

    async def retry_slow_to_stop() -> None:
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            await asyncio.sleep(0.5)  # reaping its worker
            reaped.append("worker")
            raise

    eng._cleanup_retry_task = asyncio.create_task(retry_slow_to_stop())
    await asyncio.sleep(0)
    stopping = asyncio.create_task(eng._stop_cleanup_retry())
    await asyncio.sleep(0.05)
    stopping.cancel()

    with pytest.raises(asyncio.CancelledError):
        await stopping
    assert reaped == ["worker"]


async def test_stop_cleanup_retry_logs_a_failure_its_callers_cancel_hides(
    home, caplog
):
    """A retry that fails while a cancelled caller stops it is logged: the
    caller gets its cancel, not the failure, so the log is its only trace."""
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())

    async def retry_failing_to_stop() -> None:
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            await asyncio.sleep(0.2)  # reaping its worker
            raise RuntimeError("reap failed") from None

    eng._cleanup_retry_task = asyncio.create_task(retry_failing_to_stop())
    await asyncio.sleep(0)
    stopping = asyncio.create_task(eng._stop_cleanup_retry())
    await asyncio.sleep(0.05)
    stopping.cancel()

    with pytest.raises(asyncio.CancelledError):
        await stopping
    assert any(
        record.levelname == "WARNING"
        and record.exc_info is not None
        and str(record.exc_info[1]) == "reap failed"
        for record in caplog.records
    )


async def test_stop_cleanup_retry_after_its_caller_was_cancelled_returns(home):
    """Stopping the retry in a `finally` that a cancel entered returns once
    the retry ends, so the rest of that `finally` runs.

    Before: it re-raised the retry's own cancel whenever its task had a
    cancel pending, which counted the cancel that entered the `finally`.
    """
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    eng._cleanup_retry_task = asyncio.create_task(asyncio.sleep(3600))
    caller_started = asyncio.Event()
    finished: list[str] = []

    async def caller() -> None:
        try:
            caller_started.set()
            await asyncio.Event().wait()
        finally:
            await eng._stop_cleanup_retry()
            finished.append("rest of finally")

    calling = asyncio.create_task(caller())
    await caller_started.wait()
    calling.cancel()
    await asyncio.wait({calling}, timeout=SERVE_SHUTDOWN_MAX_S)

    assert finished == ["rest of finally"]
    assert calling.cancelled()
    assert eng._cleanup_retry_task.cancelled()


def frozen_clock(eng: Engine, now: float = 100.0) -> list[float]:
    """Drive `eng`'s monotonic clock by hand: set `clock[0]` to move it."""
    clock = [now]
    eng._clock = lambda: clock[0]
    return clock


async def test_action_model_wait_covers_a_delayed_recovery(home, monkeypatch):
    """A recovery due after ACTION_MODEL_RECOVERY_WAIT_S (a crash-loop
    backoff, a retired worker's exit) is still a recovery: Action Mode waits
    for the replacement instead of failing."""
    monkeypatch.setattr(server_mod, "ACTION_MODEL_RECOVERY_WAIT_S", 1.0)
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    clock = frozen_clock(eng)
    cleanup = SimpleNamespace(
        loaded=False, unhealthy=False, recovering=True,
        recovery_deadline=clock[0] + 10.0)
    eng.cleanup = cleanup
    waiting = asyncio.create_task(eng._wait_for_action_model_recovery())
    await asyncio.sleep(0.1)

    clock[0] += 5.0  # past the ordinary wait, inside the recovery
    await asyncio.sleep(0.1)
    assert not waiting.done()
    cleanup.loaded = True
    assert await asyncio.wait_for(waiting, 1.0) is True


async def test_action_fails_now_when_a_recovery_outlasts_the_turn(
    home, monkeypatch
):
    monkeypatch.setattr(server_mod, "ACTION_MODEL_RECOVERY_WAIT_S", 0.05)
    monkeypatch.setattr(server_mod, "ACTION_MODEL_RECOVERY_WAIT_MAX_S", 0.3)
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    clock = frozen_clock(eng)
    eng.cleanup = SimpleNamespace(
        loaded=False, unhealthy=False, recovering=True,
        recovery_deadline=clock[0] + 1.0)

    # The clock never moves, so only the up-front check can end this wait.
    assert await asyncio.wait_for(eng._wait_for_action_model_recovery(), 1.0) is False


async def test_action_waits_out_a_retired_worker_exit(home, monkeypatch):
    """Action Mode waits for a replacement held back by a retired worker's
    exit instead of failing at its ordinary model wait.

    Before: only a crash-loop backoff extended the wait, so the turn failed
    at ACTION_MODEL_RECOVERY_WAIT_S while the replacement was still due.
    """
    deliver_sigkill_late(monkeypatch, 2.0)
    monkeypatch.setattr(server_mod, "ACTION_MODEL_RECOVERY_WAIT_S", 0.2)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    eng = Engine(Config(), parent_pid=None, hard_exit=Mock())
    eng.cleanup = cleanup
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"
        await wait_for(lambda: bool(cleanup_process_mod._retired_workers))

        assert await eng._wait_for_action_model_recovery() is True
        assert cleanup.loaded
    finally:
        await cleanup.aclose()


class RecoveringNotesCleanup:
    """Notes model whose replacement is due at `recovery_deadline`."""

    unhealthy = False
    recovering = True

    def __init__(self, *, loaded: bool, recovery_deadline: float | None):
        self.loaded = loaded
        self.recovery_deadline = recovery_deadline
        self.calls = 0

    async def cleanup(self, raw, system_prompt, **kwargs):
        self.calls += 1
        return SimpleNamespace(
            applied=True,
            text=json.dumps({
                "summary": "Notes after the recovery.",
                "decisions": [],
                "action_items": [],
            }),
        )


async def run_notes(
    eng: Engine,
    meeting_id: str,
    transcript: str = "[00:00] Me: Summarize this after the recovery.",
) -> list[dict]:
    eng._send = AsyncMock()
    eng._meeting_notes_running = True
    await eng._run_meeting_notes({
        "id": f"{meeting_id}-notes", "meeting_id": meeting_id,
        "transcript": transcript,
    })
    return [call.args[0] for call in eng._send.await_args_list]


async def test_meeting_notes_wait_out_a_delayed_recovery(engine, monkeypatch):
    """Notes wait for a replacement due after their own model wait (a
    crash-loop backoff, a retired worker's exit) instead of restarting the
    engine when that wait runs out."""
    eng, _sock = engine
    monkeypatch.setattr(server_mod, "MEETING_NOTES_MODEL_READY_WAIT_S", 0.2)
    cleanup = RecoveringNotesCleanup(
        loaded=False, recovery_deadline=time.monotonic() + 1.0)
    eng.cleanup = cleanup
    asyncio.get_running_loop().call_later(0.6, setattr, cleanup, "loaded", True)

    sent = await run_notes(eng, "m-delayed")

    assert cleanup.calls == 1
    assert not eng.shutdown.is_set()
    assert any(item.get("event") == "meeting_notes_ready" for item in sent)


async def test_meeting_notes_wait_out_a_recovery_that_starts_mid_call(
    engine, monkeypatch
):
    """A notes call that finds its worker just replaced (a dictation's hard
    timeout, while the call waited its turn) waits for the replacement.

    Before: the notes treated the replacement as a lost model and restarted
    the engine, though the proxy was recovering on schedule.
    """
    eng, _sock = engine
    monkeypatch.setattr(server_mod, "MEETING_NOTES_MODEL_READY_WAIT_S", 0.2)
    cleanup = RecoveringNotesCleanup(loaded=True, recovery_deadline=None)
    succeed = cleanup.cleanup

    async def replaced_on_first_call(raw, system_prompt, **kwargs):
        if cleanup.calls:
            return await succeed(raw, system_prompt, **kwargs)
        cleanup.calls += 1
        cleanup.loaded = False
        cleanup.recovery_deadline = time.monotonic() + 1.0
        asyncio.get_running_loop().call_later(0.4, setattr, cleanup, "loaded", True)
        return SimpleNamespace(applied=False, reason="llm_recovering", text=raw)

    cleanup.cleanup = replaced_on_first_call
    eng.cleanup = cleanup

    sent = await run_notes(eng, "m-mid-call")

    assert cleanup.calls == 2
    assert not eng.shutdown.is_set()
    assert any(item.get("event") == "meeting_notes_ready" for item in sent)


async def test_meeting_notes_wait_for_a_replacement_loading_after_a_loss(
    engine, monkeypatch
):
    """Notes that meet a replacement still loading after a first worker loss
    (no backoff, no retired worker) wait for it instead of restarting the
    engine. The real proxy reports its own recovery_deadline here.

    Before: the proxy reported no deadline during that load, so the notes
    gave up after their own model wait and restarted the engine.
    """
    eng, _sock = engine
    monkeypatch.setattr(server_mod, "MEETING_NOTES_MODEL_READY_WAIT_S", 0.2)
    cleanup = CleanupProcess(
        "fake", worker_command=[*fixture_command(), "--load-delay", "1.0"])
    try:
        await cleanup.load_async("warm prompt")
        eng.cleanup = cleanup
        await cleanup.cleanup("__crash__", "system")

        sent = await asyncio.wait_for(
            run_notes(eng, "m-reload", transcript="[00:00] Me: __notes__"),
            timeout=15.0,
        )

        assert not eng.shutdown.is_set()
        assert any(item.get("event") == "meeting_notes_ready" for item in sent)
    finally:
        await cleanup.aclose()


async def test_meeting_notes_stop_retrying_an_overdue_recovery(engine):
    """A model that still answers llm_recovering once its replacement is
    overdue is lost: the notes restart the engine instead of retrying.

    Before: every llm_recovering answer went straight back to the model with
    no pause and no deadline, so a model stuck recovering pinned a core.
    """
    eng, _sock = engine
    clock = frozen_clock(eng)
    cleanup = RecoveringNotesCleanup(loaded=True, recovery_deadline=clock[0] + 5.0)

    async def still_recovering(raw, system_prompt, **kwargs):
        cleanup.calls += 1
        clock[0] += 1.0
        await asyncio.sleep(0)
        return SimpleNamespace(applied=False, reason="llm_recovering", text=raw)

    cleanup.cleanup = still_recovering
    eng.cleanup = cleanup

    sent = await asyncio.wait_for(run_notes(eng, "m-overdue"), timeout=10.0)

    assert cleanup.calls == 5  # one per clock second until the deadline
    assert eng.shutdown.is_set()
    assert not any(item.get("event") == "meeting_notes_ready" for item in sent)


async def test_meeting_notes_pace_retries_while_a_recovery_is_due(engine):
    """Retries while a replacement is due pause between calls instead of
    spinning on a proxy that still reports loaded."""
    eng, _sock = engine
    cleanup = RecoveringNotesCleanup(
        loaded=True, recovery_deadline=time.monotonic() + 0.5)

    async def still_recovering(raw, system_prompt, **kwargs):
        cleanup.calls += 1
        await asyncio.sleep(0)
        return SimpleNamespace(applied=False, reason="llm_recovering", text=raw)

    cleanup.cleanup = still_recovering
    eng.cleanup = cleanup

    await asyncio.wait_for(run_notes(eng, "m-paced"), timeout=10.0)

    assert cleanup.calls <= 6  # 0.5 s at no more than one call per 0.1 s


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


async def test_recording_never_runs_cleanup_prefill_against_live_stt(engine):
    eng, sock = engine

    class RecordingCleanup:
        loaded = True
        model_id = "fake-prefix"
        unhealthy = False

        def __init__(self):
            self.calls = []

        async def prepare_prefix(self, candidates, cancel_event=None):
            self.calls.append((candidates, cancel_event))

        async def cleanup(self, raw, _prompt, **_kwargs):
            return CleanupResult("Hello world, this is a fake transcript.", True, 3)

    cleanup = RecordingCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start",
        "session": "no-prefill-race",
        "context": {
            "bundle_id": "com.apple.Notes",
            "app_name": "Notes",
            "entities": [{"type": "nearby", "value": "cursor text"}],
        },
    })
    await client.send_audio(AUDIO)
    partial = await client.recv_event("partial")
    assert partial["session"] == "no-prefill-race"
    assert cleanup.calls == []

    await client.send_json({"cmd": "stop", "session": "no-prefill-race"})
    final = await client.recv_event("final")

    assert final["text"] == "Hello world, this is a fake transcript."
    assert final["cleanup_applied"] is True
    # The only preparation is the stop-time warm-up, which starts after the
    # live stream has ended.
    assert len(cleanup.calls) == 1
    assert cleanup.unhealthy is False
    assert not eng.shutdown.is_set()
    client.close()


NOTES_CONTEXT = {
    "bundle_id": "com.apple.Notes",
    "app_name": "Notes",
    "entities": [{"type": "nearby", "value": "cursor text"}],
}


class WarmupCleanup:
    """Fake cleanup worker whose prefix warm-up blocks until released.

    ``release`` ends the warm-up; its ``cancel_event`` ends it too. Calls land
    in ``calls`` in order, so tests can check what waited for what.
    """

    loaded = True
    model_id = "fake-warmup"
    unhealthy = False

    def __init__(self):
        self.calls = []
        self.started = threading.Event()
        self.release = threading.Event()
        self.cancel_event = None

    async def prepare_prefix(self, candidates, cancel_event=None):
        self.calls.append(("prepare", candidates))
        self.cancel_event = cancel_event
        self.started.set()

        def wait_for_release_or_cancel():
            while not (self.release.is_set() or cancel_event.is_set()):
                self.release.wait(0.01)

        await asyncio.to_thread(wait_for_release_or_cancel)
        self.calls.append(("prepared", cancel_event.is_set()))

    async def cleanup(self, raw, _prompt, **kwargs):
        self.calls.append(("cleanup", kwargs.get("prefix_candidates")))
        if kwargs["cancel_event"].is_set():
            return CleanupResult(raw, False, 0, "cancelled")
        return CleanupResult("Hello world, this is a fake transcript.", True, 3)


class StubbornWarmupCleanup(WarmupCleanup):
    """Warm-up that ignores its cancel event and runs until released.

    ``task`` is the warm-up task, so tests can see when it has finished.
    """

    task = None

    async def prepare_prefix(self, candidates, cancel_event=None):
        self.calls.append(("prepare", candidates))
        self.cancel_event = cancel_event
        self.task = asyncio.current_task()
        self.started.set()
        await asyncio.to_thread(self.release.wait, 5.0)
        self.calls.append(("prepared", cancel_event.is_set()))

    async def aclose(self):
        self.calls.append(("aclose", self.task is not None and self.task.done()))


def notes_prefix_candidates(config):
    return formatting.build_prefill_prompt_candidates(
        config,
        bundle_id=NOTES_CONTEXT["bundle_id"],
        app_name=NOTES_CONTEXT["app_name"],
        explicit_mode=None,
        entities=NOTES_CONTEXT["entities"],
    )


async def test_stop_warms_cleanup_beside_stt_finalize(engine, monkeypatch):
    """The cleanup warm-up overlaps STT finalize, and cleanup waits for it.

    stop ─► STT finalize ───────────────► cleanup ─► final
       └──► prepare_prefix (warm-up) ───┘
    """
    eng, sock = engine
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    # STT finalize holds until the warm-up has started, then lets the warm-up
    # run past it: cleanup must still wait for the warm-up to finish.
    finalize = eng.stt.finalize
    overlapped = []

    def finalize_beside_warmup():
        overlapped.append(cleanup.started.wait(timeout=1.0))
        threading.Timer(0.2, cleanup.release.set).start()
        return finalize()

    monkeypatch.setattr(eng.stt, "finalize", finalize_beside_warmup)
    await client.send_json({"cmd": "start", "session": "warm", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "warm"})
    final = await client.recv_event("final")

    expected = notes_prefix_candidates(eng.config)
    assert expected
    assert overlapped == [True]
    assert cleanup.calls == [
        ("prepare", expected),
        ("prepared", False),
        ("cleanup", expected),
    ]
    assert final["cleanup_applied"] is True
    client.close()


async def test_stalled_cleanup_warmup_is_cancelled_before_cleanup(engine, monkeypatch):
    """A warm-up past its wait budget is cancelled; the final is not held."""
    eng, sock = engine
    monkeypatch.setattr(server_mod, "CLEANUP_WARMUP_WAIT_S", 0.05)
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "stall", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "stall"})
    final = await client.recv_event("final", timeout=2.0)

    assert final["cleanup_applied"] is True
    assert cleanup.cancel_event is not None and cleanup.cancel_event.is_set()
    assert [call[0] for call in cleanup.calls] == ["prepare", "prepared", "cleanup"]
    client.close()


async def test_short_final_does_not_wait_for_cleanup_warmup(engine, monkeypatch):
    """A final that skips the model is not held, and its warm-up is cancelled."""
    eng, sock = engine
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "sounds good")
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "short", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "short"})
    final = await client.recv_event("final", timeout=1.0)

    assert final["cleanup_applied"] is False
    assert cleanup.started.is_set()
    for _ in range(100):
        if ("prepared", True) in cleanup.calls:
            break
        await asyncio.sleep(0.01)
    assert cleanup.calls == [("prepare", notes_prefix_candidates(eng.config)), ("prepared", True)]
    client.close()


async def load_fixture_cleanup(
    eng: Engine, *worker_flags: str, queue_timeout_s: float = 0.1
) -> CleanupProcess:
    """Make the fixture worker the engine's cleanup."""
    cleanup = CleanupProcess(
        "fake",
        worker_command=[*fixture_command(), *worker_flags],
        queue_timeout_s=queue_timeout_s,
    )
    await cleanup.load_async("warm prompt")
    eng.cleanup = cleanup
    return cleanup


async def test_slow_cleanup_warmup_delays_cleanup_without_a_replacement(
    engine, monkeypatch
):
    """A warm-up that ignores cancel but finishes only delays cleanup.

    The old waits (0.1 s, cancel, 0.1 s, then the 0.1 s queue timeout here)
    gave up on a 0.6 s warm-up: raw text, and a healthy worker replaced.
    """
    eng, sock = engine
    monkeypatch.setattr(server_mod, "CLEANUP_WARMUP_WAIT_S", 0.1)
    cleanup = await load_fixture_cleanup(eng, "--prefix-delay", "0.6")
    pid = cleanup.pid
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "slow", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "slow"})
    final = await client.recv_event("final", timeout=5.0)

    assert final["cleanup_applied"] is True
    assert cleanup.loaded and cleanup.pid == pid
    client.close()


async def test_wedged_cleanup_warmup_gives_raw_after_the_budget_and_one_replacement(
    engine, monkeypatch, caplog
):
    """Only a warm-up that outlives the cleanup's whole budget costs the final.

    The cleanup waits its own budget (1.5 s timeout + 0.1 s grace here), then
    returns raw at once, not after the worker's 2 s queue timeout, and retires
    the worker once. The retirement fails the wedged warm-up's request, so its
    own watchdog never retires a second worker.
    """
    eng, sock = engine
    monkeypatch.setattr(server_mod, "CLEANUP_WARMUP_WAIT_S", 0.1)
    monkeypatch.setattr(server_mod, "HARD_TIMEOUT_GRACE_S", 0.1)
    cleanup = await load_fixture_cleanup(eng, "--hang-prefix", queue_timeout_s=2.0)
    pid = cleanup.pid
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "wedged", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "wedged"})
    final = await client.recv_event("final", timeout=5.0)

    budget_ms = server_mod.adaptive_timeout_ms(final["raw"]) + 100
    assert final["cleanup_applied"] is False
    assert budget_ms - 20 <= final["cleanup_wall_ms"] < budget_ms + 1000
    for _ in range(500):
        if cleanup.loaded and cleanup.pid != pid:
            break
        await asyncio.sleep(0.01)
    assert cleanup.loaded and cleanup.pid not in (None, pid)
    replacements = [
        record.getMessage()
        for record in caplog.records
        if record.getMessage().startswith("replacing cleanup worker")
    ]
    assert replacements == ["replacing cleanup worker asynchronously reason=timeout_queue"]
    client.close()


async def test_cancel_during_the_warmup_wait_lets_the_next_start_through(
    engine, monkeypatch
):
    """Cancelling a final that waits on the warm-up frees the engine at once.

    The wait held the finalize for up to 4 s, so the next start got "busy
    finalizing the previous dictation".
    """
    eng, sock = engine
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "first", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "first"})
    # The transcript goes out just before formatting waits on the warm-up.
    await client.recv_event("transcript")
    await client.send_json({"cmd": "cancel", "session": "first"})
    await client.recv_event("cancelled", timeout=1.0)

    # The next final skips the model, so it does not wait on its own warm-up.
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "sounds good")
    await client.send_json({"cmd": "start", "session": "next", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "next"})
    final = await client.recv_event("final", timeout=1.0)

    assert final["session"] == "next"
    for _ in range(100):
        if cleanup.calls.count(("prepared", True)) == 2:
            break
        await asyncio.sleep(0.01)
    assert cleanup.calls.count(("prepared", True)) == 2
    client.close()


async def test_next_start_waits_for_a_warmup_that_outlived_its_final(
    engine, monkeypatch
):
    """A new dictation starts with the cleanup worker free.

    The short final skips the model and cancels its warm-up, which ignores
    the cancel. The next start waits for it rather than record beside it.
    """
    eng, sock = engine
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "sounds good")
    cleanup = StubbornWarmupCleanup()
    eng.cleanup = cleanup
    start_session = eng.stt.start_session
    warmup_running_at_start = []

    def record_start():
        warmup_running_at_start.append(
            cleanup.task is not None and not cleanup.task.done())
        start_session()

    monkeypatch.setattr(eng.stt, "start_session", record_start)
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "short", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "short"})
    await client.recv_event("final", timeout=1.0)
    threading.Timer(0.2, cleanup.release.set).start()
    await client.send_json({"cmd": "start", "session": "next", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "next"})
    await client.recv_event("final", timeout=2.0)

    assert warmup_running_at_start == [False, False]
    client.close()


async def test_finalize_ends_after_its_warmup_stops(engine, monkeypatch):
    """A finalize leaves no warm-up running behind it, within its bound."""
    eng, sock = engine
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "sounds good")
    cleanup = StubbornWarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "short", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "short"})
    await client.recv_event("final", timeout=1.0)
    finalize = eng._finalize_task  # noqa: SLF001
    threading.Timer(0.2, cleanup.release.set).start()
    if finalize is not None:
        await asyncio.wait_for(asyncio.shield(finalize), 2.0)

    assert cleanup.task is not None and cleanup.task.done()
    client.close()


async def test_shutdown_waits_for_a_running_cleanup_warmup(engine, monkeypatch):
    """Shutdown cancels a running warm-up and waits for it before closing."""
    eng, sock = engine
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "sounds good")
    cleanup = StubbornWarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "short", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "short"})
    await client.recv_event("final", timeout=1.0)
    client.close()
    threading.Timer(0.2, cleanup.release.set).start()
    eng.shutdown.set()
    for _ in range(300):
        if cleanup.calls[-1][0] == "aclose":
            break
        await asyncio.sleep(0.01)

    assert cleanup.calls[-2:] == [("prepared", True), ("aclose", True)]


async def test_failed_cleanup_warmup_start_still_delivers_the_final(
    engine, monkeypatch
):
    """The warm-up is an optimization: its failure never costs the final."""
    eng, sock = engine
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    build = formatting.build_prefill_prompt_candidates
    builds = []

    def fail_first_build(*args, **kwargs):
        builds.append(args)
        if len(builds) == 1:
            raise RuntimeError("injected warm-up failure")
        return build(*args, **kwargs)

    monkeypatch.setattr(formatting, "build_prefill_prompt_candidates", fail_first_build)
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "s", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "s"})
    final = await client.recv_event("final", timeout=2.0)

    assert final["cleanup_applied"] is True
    assert [call[0] for call in cleanup.calls] == ["cleanup"]
    client.close()


HINDI_TRANSCRIPT = "नमस्ते दुनिया यह एक छोटा परीक्षण है"


async def test_romanize_final_does_not_wait_for_the_cleanup_warmup(
    engine, monkeypatch
):
    """Romanization uses its own prompt, so the warm-up is cancelled at once.

    The Latin preview could not predict the romanize final; the final used to
    wait CLEANUP_WARMUP_WAIT_S for a warm-up it cannot use.
    """
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", HINDI_TRANSCRIPT)
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "hi", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "hi"})
    final = await client.recv_event("final", timeout=1.0)

    assert final["cleanup_applied"] is True
    for _ in range(100):
        if ("prepared", True) in cleanup.calls:
            break
        await asyncio.sleep(0.01)
    assert sorted(call[0] for call in cleanup.calls) == ["cleanup", "prepare", "prepared"]
    assert ("prepared", True) in cleanup.calls
    client.close()


async def test_romanize_preview_starts_no_cleanup_warmup(engine, monkeypatch):
    """A non-Latin preview under romanize predicts a final the warm-up can't serve."""
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", HINDI_TRANSCRIPT)
    monkeypatch.setattr(eng.stt, "feed_chunk", lambda _chunk: HINDI_TRANSCRIPT)
    cleanup = WarmupCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "hi", "context": NOTES_CONTEXT})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "hi"})
    final = await client.recv_event("final", timeout=1.0)

    assert final["cleanup_applied"] is True
    assert [call[0] for call in cleanup.calls] == ["cleanup"]
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


async def test_cancel_during_finalization_discards_audio(engine, monkeypatch):
    eng, sock = engine
    formatting_started = asyncio.Event()
    release_formatting = asyncio.Event()

    async def delayed_formatting(*_args, **_kwargs):
        formatting_started.set()
        await release_formatting.wait()
        return "cancel me", "Default", 0, False, "test"

    monkeypatch.setattr(eng, "_apply_formatting", delayed_formatting)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({
            "cmd": "start", "session": "cancel-finalizing", "context": {},
        })
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "cancel-finalizing"})
        await asyncio.wait_for(formatting_started.wait(), 2)

        await client.send_json({"cmd": "cancel", "session": "cancel-finalizing"})
        cancelled = await client.recv_event("cancelled", timeout=0.5)
        assert cancelled["session"] == "cancel-finalizing"

        release_formatting.set()
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong"))["event"] == "pong"
        assert not (eng.audio.active_dir / "cancel-finalizing.pcm16.part").exists()
        assert not (eng.config.audio_dir / eng.audio.name_for("cancel-finalizing")).exists()
    finally:
        release_formatting.set()
        client.close()


async def test_final_audio_spool_waits_for_history_ack(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start", "session": "durable-final", "context": {},
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "durable-final"})
    final = await client.recv_event("final")
    assert final["session"] == "durable-final"

    archive = eng._final_archives["durable-final"]
    assert await asyncio.wait_for(archive, 2) is True
    spool = eng.audio.active_dir / "durable-final.pcm16.part"
    assert spool.is_file()

    await client.send_json({"cmd": "ack_final", "session": "durable-final"})
    await client.send_json({"cmd": "ping"})
    assert (await client.recv_event("pong"))["event"] == "pong"
    assert not spool.exists()
    client.close()


async def test_live_start_waits_for_automatic_recovery(engine, monkeypatch):
    eng, sock = engine
    recovery_started = threading.Event()
    release_recovery = threading.Event()

    def delayed_reprocess(*_args):
        recovery_started.set()
        assert release_recovery.wait(2)
        return "recovered text"

    monkeypatch.setattr(server_mod, "transcribe_clip", delayed_reprocess)
    audio = eng.audio.save("automatic-recovery", AUDIO)
    assert audio is not None
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({
            "cmd": "reprocess", "audio": audio, "id": 41,
            "recovery": True,
        })
        for _ in range(100):
            if recovery_started.is_set():
                break
            await asyncio.sleep(0.01)
        assert recovery_started.is_set()

        await client.send_json({
            "cmd": "start", "session": "live-after-recovery", "context": {},
        })
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "live-after-recovery"})
        release_recovery.set()

        recovered = await client.recv_event("reprocessed")
        assert recovered["id"] == 41
        final = await client.recv_event("final")
        assert final["session"] == "live-after-recovery"
        assert eng._reprocessing is False
    finally:
        release_recovery.set()
        client.close()


async def test_automatic_recoveries_run_serially(engine, monkeypatch):
    eng, sock = engine
    first_started = threading.Event()
    release_first = threading.Event()
    calls = 0

    def delayed_first(*_args):
        nonlocal calls
        calls += 1
        if calls == 1:
            first_started.set()
            assert release_first.wait(2)
        return f"recovered {calls}"

    monkeypatch.setattr(server_mod, "transcribe_clip", delayed_first)
    first_audio = eng.audio.save("recovery-one", AUDIO)
    second_audio = eng.audio.save("recovery-two", AUDIO)
    assert first_audio is not None and second_audio is not None
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({
            "cmd": "reprocess", "audio": first_audio, "id": 51,
            "recovery": True,
        })
        for _ in range(100):
            if first_started.is_set():
                break
            await asyncio.sleep(0.01)
        assert first_started.is_set()
        await client.send_json({
            "cmd": "reprocess", "audio": second_audio, "id": 52,
            "recovery": True,
        })
        release_first.set()

        recovered = {
            (await client.recv_event("reprocessed"))["id"],
            (await client.recv_event("reprocessed"))["id"],
        }
        assert recovered == {51, 52}
        assert calls == 2
    finally:
        release_first.set()
        client.close()


async def test_cancel_after_final_before_history_ack_discards_audio(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start", "session": "cancel-after-final", "context": {},
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "cancel-after-final"})
    await client.recv_event("final")
    assert await eng._final_archives["cancel-after-final"] is True

    await client.send_json({"cmd": "cancel", "session": "cancel-after-final"})
    cancelled = await client.recv_event("cancelled")
    assert cancelled["session"] == "cancel-after-final"
    assert not (eng.audio.active_dir / "cancel-after-final.pcm16.part").exists()
    assert not (eng.config.audio_dir / eng.audio.name_for("cancel-after-final")).exists()
    client.close()


async def test_failed_final_archive_keeps_recovery_spool(engine, monkeypatch):
    eng, sock = engine
    monkeypatch.setattr(eng.audio, "recover_interrupted", lambda _sessions: [])
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "start", "session": "archive-failed", "context": {},
    })
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "archive-failed"})
    await client.recv_event("final")
    assert await eng._final_archives["archive-failed"] is False

    await client.send_json({"cmd": "ack_final", "session": "archive-failed"})
    await client.send_json({"cmd": "ping"})
    assert (await client.recv_event("pong"))["event"] == "pong"
    assert (eng.audio.active_dir / "archive-failed.pcm16.part").is_file()
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
    await restart_exit(eng)
    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)
    client.close()


async def test_detached_reap_failure_restarts_engine_without_another_request(
    engine,
    monkeypatch,
):
    eng, _sock = engine
    cleanup = CleanupProcess(
        "fake",
        on_unhealthy=eng._queue_cleanup_unhealthy_restart,
    )
    eng.cleanup = cleanup

    async def delayed_failed_reap():
        await asyncio.sleep(0.02)
        cleanup.loaded = False
        cleanup._mark_unhealthy()

    monkeypatch.setattr(cleanup, "_stop_worker", delayed_failed_reap)
    cleanup._schedule_replacement("test_failed_reap")

    for _ in range(100):
        if eng.shutdown.is_set():
            break
        await asyncio.sleep(0.01)

    assert cleanup.unhealthy is True
    assert eng.shutdown.is_set()
    await restart_exit(eng)
    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)
    await cleanup.aclose()


async def test_unhealthy_notification_waits_for_active_dictation_fallback(engine):
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        on_unhealthy=eng._queue_cleanup_unhealthy_restart,
    )
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "defer-unhealthy", "context": {}})
    await client.send_audio(AUDIO)
    for _ in range(100):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)
    assert eng.session is not None
    cleanup._mark_unhealthy()
    await asyncio.sleep(server_mod.CLEANUP_RESTART_GRACE_S + 0.02)
    assert not eng.shutdown.is_set()
    eng._hard_exit.assert_not_called()

    await client.send_json({"cmd": "cancel", "session": "defer-unhealthy"})
    cancelled = await client.recv_event("cancelled")
    assert cancelled["session"] == "defer-unhealthy"
    assert eng.shutdown.is_set()
    await restart_exit(eng)
    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)

    client.close()
    await cleanup.aclose()


async def test_cleanup_restart_waits_for_pending_audio_archive(engine):
    eng, _sock = engine
    release = asyncio.Event()

    class UnhealthyCleanup:
        unhealthy = True

    eng.cleanup = UnhealthyCleanup()

    async def archive_write():
        await release.wait()

    archive = asyncio.create_task(archive_write())
    eng._archive_tasks.add(archive)
    archive.add_done_callback(eng._archive_tasks.discard)

    assert eng._restart_if_cleanup_unhealthy() is True
    await asyncio.sleep(server_mod.CLEANUP_RESTART_GRACE_S + 0.01)
    eng._hard_exit.assert_not_called()

    release.set()
    await archive
    await restart_exit(eng)
    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)


async def test_cleanup_restart_keeps_loop_independent_exit_backstop(engine, monkeypatch):
    eng, _sock = engine

    class UnhealthyCleanup:
        unhealthy = True

    eng.cleanup = UnhealthyCleanup()
    monkeypatch.setattr(server_mod, "CLEANUP_RESTART_GRACE_S", 0.01)
    monkeypatch.setattr(server_mod, "CLEANUP_RESTART_ARCHIVE_GRACE_S", 0.01)

    assert eng._restart_if_cleanup_unhealthy() is True
    assert eng._cleanup_restart_task is not None
    eng._cleanup_restart_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await eng._cleanup_restart_task
    # The backstop is a daemon thread, so wait for it to finish rather than
    # sleeping a fixed interval that thread scheduling can overrun.
    timer = eng._cleanup_restart_timer
    assert timer is not None
    await asyncio.to_thread(timer.join, 5)
    assert not timer.is_alive()

    eng._hard_exit.assert_called_once_with(server_mod.CLEANUP_RESTART_EXIT_CODE)


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


async def test_shutdown_rejects_new_sessions_on_an_existing_connection(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")

    eng.shutdown.set()
    await client.send_json({"cmd": "start", "session": "doomed", "context": {}})

    evt = await client.recv()
    assert evt["event"] == "error"
    assert evt["session"] == "doomed"
    assert "shutting down" in evt["message"]
    assert eng.session is None
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


async def test_second_client_cannot_displace_active_session(engine):
    """An extra local client is rejected while the app's dictation completes."""
    eng, sock = engine
    a = await connect(sock)
    await a.recv_event("ready")
    await a.send_json({"cmd": "start", "session": "s1", "context": {}})
    await a.send_audio(AUDIO)
    for _ in range(200):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)

    b = await connect(sock)
    rejected = await b.recv()
    assert rejected == {
        "event": "error",
        "message": "Engine already has an active client",
        "fatal": True,
    }
    assert eng.session is not None and eng.session.id == "s1"

    await a.send_json({"cmd": "stop", "session": "s1"})
    final = await a.recv_event("final")
    assert final["session"] == "s1"
    a.close()
    b.close()


# ---- bounded audio queue (codex#7 / claude M4) ----


def install_blocking_preview(eng, monkeypatch):
    """Give FakeBackend Whisper's request/decode surface with a held decode."""
    pending = []
    decode_started = threading.Event()
    release_decode = threading.Event()
    stats = {"active": 0, "max_active": 0, "calls": 0}
    lock = threading.Lock()

    def feed_chunk(chunk):
        eng.stt.samples += len(chunk)
        pending[:] = [f"preview-{eng.stt.samples}"]  # coalesce to latest
        return None

    def take_preview_request():
        return pending.pop() if pending else None

    def decode_preview(_request):
        with lock:
            stats["active"] += 1
            stats["calls"] += 1
            stats["max_active"] = max(stats["max_active"], stats["active"])
        decode_started.set()
        release_decode.wait(5)
        with lock:
            stats["active"] -= 1
        return "early words"

    def discard_preview_request():
        pending.clear()

    monkeypatch.setattr(eng.stt, "feed_chunk", feed_chunk)
    monkeypatch.setattr(eng.stt, "take_preview_request", take_preview_request, raising=False)
    monkeypatch.setattr(eng.stt, "decode_preview", decode_preview, raising=False)
    monkeypatch.setattr(eng.stt, "discard_preview_request", discard_preview_request, raising=False)
    return decode_started, release_decode, stats


async def test_preview_decode_does_not_block_socket_ingest(engine, monkeypatch):
    eng, sock = engine
    decode_started, release_decode, stats = install_blocking_preview(eng, monkeypatch)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "preview-live", "context": {}})
        await client.send_audio(AUDIO)
        assert await asyncio.to_thread(decode_started.wait, 2)

        # Preview owns the single model thread, but socket dispatch must still
        # accept the next frame and answer control traffic immediately.
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong"))["event"] == "pong"
        assert eng.session is not None
        assert eng.session.samples == len(AUDIO) * 2
        assert eng.stt.samples == len(AUDIO)  # second feed waits, ingest does not

        release_decode.set()
        partial = await client.recv_event("partial")
        assert partial["text"] == "early words"
        await client.send_json({"cmd": "stop", "session": "preview-live"})
        final = await client.recv_event("final")
        assert final["text"] == "hello world this is a fake transcript."
        assert stats["max_active"] == 1
    finally:
        release_decode.set()
        client.close()


async def test_stop_discards_inflight_preview_result_before_final(engine, monkeypatch):
    eng, sock = engine
    decode_started, release_decode, _stats = install_blocking_preview(eng, monkeypatch)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "preview-stop", "context": {}})
        await client.send_audio(AUDIO)
        assert await asyncio.to_thread(decode_started.wait, 2)
        await client.send_json({"cmd": "stop", "session": "preview-stop"})
        for _ in range(100):
            if eng.session is None:
                break
            await asyncio.sleep(0.01)
        assert eng.session is None

        release_decode.set()
        events = []
        while not events or events[-1].get("event") != "final":
            events.append(await client.recv())

        names = [event.get("event") for event in events]
        assert "partial" not in names
        assert names.index("transcript") < names.index("final")
        assert events[-1]["text"] == "hello world this is a fake transcript."
    finally:
        release_decode.set()
        client.close()


async def test_queue_overflow_aborts_session(engine, monkeypatch):
    eng, sock = engine
    monkeypatch.setattr(server_mod, "QUEUE_MAX_FRAMES", 3)
    monkeypatch.setattr(server_mod, "MAX_DROPPED_FRAMES", 5)
    feed_started = threading.Event()
    release = threading.Event()

    def stuck_feed(chunk):  # simulate STT far below realtime
        feed_started.set()
        release.wait(10)
        return None

    monkeypatch.setattr(eng.stt, "feed_chunk", stuck_feed)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s-of", "context": {}})
    # Pin one frame in flight before the burst. The socket reader consumes
    # every buffered frame without yielding, so without this wait the worker
    # may not have dequeued anything yet and the accepted count is one lower.
    await client.send_audio(AUDIO)
    assert await asyncio.to_thread(feed_started.wait, 2)
    for _ in range(11):  # capacity (3) + drops past threshold
        await client.send_audio(AUDIO)

    evt = await client.recv(timeout=5)
    assert evt["event"] == "error"
    assert "overflow" in evt["message"]
    assert evt["session"] == "s-of"
    spool = eng.config.audio_dir / ".active" / "s-of.pcm16.part"
    assert spool.is_file()
    accepted_frames = 3 + 1 + 5 + 1  # queued + in-flight + allowed drops + aborting frame
    assert spool.stat().st_size == AUDIO.size * 2 * accepted_frames
    release.set()

    # engine recovered: idle again and responsive
    await client.send_json({"cmd": "ping"})
    assert (await client.recv())["event"] == "pong"
    assert eng.session is None
    client.close()


# ---- max recording duration auto-stop ----


def test_default_max_recording_duration_is_one_hour(home):
    config = Config()
    assert config.max_recording_s == 3600


async def test_auto_stop_at_max_duration(engine):
    eng, sock = engine
    eng.config.data["max_recording_s"] = 0.05  # 800 samples at 16 kHz
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s-cap", "context": {}})
    await client.send_audio(AUDIO)  # 1600 samples > cap → auto-finalize, no stop sent

    auto_stop = await client.recv_event("recording_auto_stopped")
    assert auto_stop["session"] == "s-cap"
    assert auto_stop["limit_s"] == 0.05
    assert auto_stop["duration_s"] == 0.1
    transcript = await client.recv_event("transcript")
    assert transcript["session"] == "s-cap"
    final = await client.recv_event("final")
    assert final["session"] == "s-cap"
    assert final["auto_stopped"] is True
    assert final["text"] == "hello world this is a fake transcript."
    assert eng.session is None
    client.close()


# ---- config key consumption: language ----


def test_whisper_language_mapping(monkeypatch):
    monkeypatch.delenv("VELORA_FAKE_STT", raising=False)
    from velora_engine.models import TRANSCRIBE_CPP_Q8_MODEL
    from velora_engine.stt import (
        TranscribeCppWhisperBackend,
        WhisperBackend,
        create_backend,
        whisper_language,
    )

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

    accelerated = create_backend(TRANSCRIBE_CPP_Q8_MODEL, "hi")
    assert isinstance(accelerated, TranscribeCppWhisperBackend)
    assert accelerated.language == "hi"


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


async def test_apply_formatting_passes_converted_text_to_llm(engine):
    # The original regression: _apply_formatting sent RAW text to the model,
    # so spoken break commands survived as literal words. The model must get
    # gate.text with breaks encoded as the ⏎ transport marker.
    eng, _sock = engine

    class CapturingCleanup:
        loaded = True
        model_id = "fake-capture"
        seen = None

        async def cleanup(self, raw, _prompt, **_kwargs):
            self.seen = raw
            return CleanupResult(raw, True, 5)

    fake = CapturingCleanup()
    eng.cleanup = fake
    text, _mode, _ms, applied, _reason = await eng._apply_formatting(
        "point one is speed. now a new line. point two is privacy and it matters",
        bundle_id="com.apple.Notes",
        app_name="Notes",
        explicit_mode=None,
    )
    assert fake.seen is not None
    assert "new line" not in fake.seen.lower()
    assert "⏎" in fake.seen
    assert applied and "\n" in text
