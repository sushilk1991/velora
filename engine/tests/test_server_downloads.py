"""Recovery server contracts over framed sockets and controlled local loaders."""
import asyncio
import json
import shutil
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest

from velora_engine import protocol
from velora_engine.config import Config
from velora_engine.downloads import DownloadCoordinator, DownloadError, DownloadResult
from velora_engine.server import Engine
from velora_engine.stt import FakeBackend
import velora_engine.server as server


@pytest.fixture
async def recovery(home, monkeypatch, tmp_path):
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    transfer = asyncio.Event()
    failures = set()
    calls = []

    async def once(entry, restart):
        model = entry.item["model"]
        calls.append((model, restart))
        await transfer.wait()
        if model in failures:
            raise DownloadError({"category": "disk", "code": "disk_full",
                                 "message": "Free disk space.", "retryable": False})
        return DownloadResult(str(tmp_path), "a" * 40, entry.item["attempt"])

    monkeypatch.setattr(coordinator, "_once", once)
    monkeypatch.setattr(server, "DownloadCoordinator", lambda: coordinator)
    monkeypatch.setattr(server, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(server.models, "is_cached", lambda model: True)
    backends = []

    def backend(model, language):
        item = FakeBackend(model, language)
        item.load = Mock()
        item.close = Mock()
        backends.append(item)
        return item

    monkeypatch.setattr(server, "create_backend", backend)
    config = Config()
    config.data.update(cleanup_enabled=False, save_audio=False)
    config.save()
    engine = Engine(config, hard_exit=Mock())
    yield SimpleNamespace(engine=engine, coordinator=coordinator, transfer=transfer,
                         failures=failures, calls=calls, backends=backends)
    engine.shutdown.set()
    await coordinator.close()
    for job in engine._model_jobs.values():
        job.cancel()
    await asyncio.gather(*engine._model_jobs.values(), return_exceptions=True)
    engine._stt_executor.shutdown(wait=True)


class _Client:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    async def send(self, **msg):
        self.writer.write(protocol.encode_json(msg))
        await self.writer.drain()

    async def recv(self):
        kind, payload = await asyncio.wait_for(protocol.read_frame(self.reader), 1)
        assert kind == protocol.FRAME_JSON
        return json.loads(payload)

    async def event(self, name):
        while True:
            event = await self.recv()
            if event["event"] == name:
                return event


@pytest.fixture
async def socket_engine(recovery):
    root = Path(tempfile.mkdtemp(prefix="velora-r-"))
    sock = root / "e.sock"
    task = asyncio.create_task(recovery.engine.serve(sock))
    while not sock.exists():
        await asyncio.sleep(.001)
    yield sock
    recovery.engine.shutdown.set()
    await asyncio.wait_for(task, 3)
    shutil.rmtree(root)


async def _connect(sock):
    return _Client(*await asyncio.open_unix_connection(str(sock)))


async def test_pre_ready_responsive(recovery, socket_engine):
    recovery.transfer.clear()
    client = await _connect(socket_engine)
    assert (await client.recv())["event"] == "download_status"
    await client.send(cmd="ping")
    await client.event("pong")
    await client.send(cmd="status")
    assert (await client.event("status"))["stt_ready"] is False
    await client.send(cmd="start", session="early")
    assert "speech" in (await client.event("error"))["message"]
    await client.send(cmd="cancel", session="early")
    await client.send(cmd="ping")
    await client.event("pong")
    recovery.transfer.set()
    await client.event("ready")
    client.writer.close()


async def test_startup_failure_retry(recovery, socket_engine):
    model = recovery.engine.stt.model_id
    recovery.failures.add(model)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    while True:
        snapshot = await client.event("download_status")
        if snapshot["downloads"] and snapshot["downloads"][0]["state"] == "failed":
            break
    assert not recovery.engine.shutdown.is_set()
    item = snapshot["downloads"][0]
    recovery.failures.clear()
    await client.send(cmd="retry_download", model=model, kind="stt", attempt=item["attempt"])
    await client.event("ready")
    assert recovery.engine.stt_ready.is_set()
    client.writer.close()


async def test_switch_responsive_retains_old(recovery, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    old = recovery.engine.stt
    recovery.transfer.clear()
    await client.send(cmd="set_model", model="example/new", kind="stt")
    await client.send(cmd="ping")
    await client.event("pong")
    assert recovery.engine.stt is old
    recovery.transfer.set()
    await client.event("model_set")
    assert recovery.engine.stt.model_id == "example/new"
    assert recovery.engine.config.stt_model == "example/new"
    # The backend sees a verified path only during load, not on the wire.
    assert recovery.backends[-1].model_id == "example/new"
    client.writer.close()


async def test_stale_retry_snapshot(recovery, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    await client.send(cmd="retry_download", model=recovery.engine.stt.model_id,
                      kind="stt", attempt="stale")
    error = await client.event("error")
    assert error["error"]["code"] == "stale_download_attempt"
    assert (await client.event("download_status"))["snapshot"] is True
    await client.send(cmd="ping")
    await client.event("pong")
    client.writer.close()


async def test_cold_edit_phases(recovery):
    events = []
    recovery.engine._send = AsyncMock(side_effect=events.append)
    cleanup = SimpleNamespace(loaded=False, ensure_loaded=AsyncMock(return_value=True),
                             cleanup=AsyncMock(return_value=SimpleNamespace(
                                 text="Changed", applied=True, reason="")))
    recovery.engine.cleanup = cleanup
    await recovery.engine._run_edit_text({"id": "edit-1"}, "Original", "Shorten")
    phases = [event for event in events if event["event"] == "edit_phase"]
    assert [event["phase"] for event in phases] == ["loading", "inference"]
    assert all(set(event) == {"event", "id", "phase", "stall_after_s"} for event in phases)
    assert phases[0]["stall_after_s"] >= server.LOAD_TIMEOUT_S
    assert phases[1]["stall_after_s"] < phases[0]["stall_after_s"]
    assert events[-1]["event"] == "edited"


async def test_recovery_forecast_capped(recovery, monkeypatch):
    engine = recovery.engine
    now = [100.0]
    engine._clock = lambda: now[0]
    cleanup = SimpleNamespace(loaded=False, unhealthy=False, recovery_deadline=205.0)
    engine.cleanup = cleanup
    sleeps = 0

    async def settle(delay):
        nonlocal sleeps
        sleeps += 1
        now[0] += delay
        cleanup.loaded = True

    monkeypatch.setattr(server.asyncio, "sleep", settle)
    assert await engine._wait_for_action_model_recovery()
    assert sleeps == 1


async def test_recovery_deadline_fixed(recovery, monkeypatch):
    engine = recovery.engine
    now = [100.0]
    engine._clock = lambda: now[0]
    engine.cleanup = SimpleNamespace(loaded=False, unhealthy=False, recovery_deadline=205.0)

    async def tick(delay):
        now[0] += 1
        engine.cleanup.recovery_deadline += 1  # Progress cannot extend total wait.

    monkeypatch.setattr(server.asyncio, "sleep", tick)
    assert not await engine._wait_for_action_model_recovery()
    assert now[0] == 100 + server.ACTION_MODEL_RECOVERY_WAIT_MAX_S


async def test_recovery_wait_cancelled(recovery, monkeypatch):
    engine = recovery.engine
    engine.cleanup = SimpleNamespace(loaded=False, unhealthy=False,
                                     recovery_deadline=engine._clock() + 105)

    async def cancel(delay):
        engine._action_cancel.set()

    monkeypatch.setattr(server.asyncio, "sleep", cancel)
    assert not await engine._wait_for_action_model_recovery()
    assert engine._action_cancel.is_set()


async def test_reconnect_snapshot_order(recovery, socket_engine):
    recovery.transfer.set()
    first = await _connect(socket_engine)
    snapshot = await first.recv()
    assert snapshot["event"] == "download_status"
    await first.event("ready")
    first.writer.close()
    await first.writer.wait_closed()
    while recovery.engine.writer is not None:
        await asyncio.sleep(.001)
    second = await _connect(socket_engine)
    snapshot = await second.recv()
    assert snapshot["engine_id"] == recovery.coordinator.snapshot()["engine_id"]
    assert snapshot["downloads"][0]["state"] == "ready"
    assert (await second.recv())["event"] == "ready"
    second.writer.close()


@pytest.mark.parametrize("failure", ["load", "save", "cache"])
async def test_switch_failure_retains(recovery, monkeypatch, failure):
    engine = recovery.engine
    recovery.transfer.set()
    await engine._queue_model_job(engine.stt.model_id, "stt")
    old, old_model = engine.stt, engine.config.stt_model
    if failure == "load":
        factory = server.create_backend

        def broken(model, language):
            item = factory(model, language)
            item.load.side_effect = RuntimeError("secret signed url")
            return item

        monkeypatch.setattr(server, "create_backend", broken)
    elif failure == "save":
        monkeypatch.setattr(engine.config, "save", Mock(side_effect=OSError("full disk")))
    else:
        monkeypatch.setattr(server.models, "is_cached", lambda model: False)
    await engine._queue_model_job("example/new", "stt")
    assert engine.stt is old
    assert engine.config.stt_model == old_model
    assert Config().stt_model == old_model
    item = recovery.coordinator.snapshot()["downloads"][-1]
    assert item["state"] == "failed"
    assert item["active_model"] == old_model
    assert "secret" not in json.dumps(item)
    if failure == "cache":
        assert len(recovery.backends) == 2  # No backend load can fetch behind coordinator.


async def test_duplicate_jobs(recovery):
    recovery.transfer.set()
    engine = recovery.engine
    task = engine._queue_model_job("example/new", "stt")
    assert engine._queue_model_job("example/new", "stt") is task
    await task
    item = recovery.coordinator.snapshot()["downloads"][0]
    await engine._cmd_download_retry({"cmd": "retry_download", "model": "example/new",
                                      "kind": "stt", "attempt": item["attempt"]})
    await asyncio.sleep(.01)
    assert recovery.calls == [("example/new", False)]
    assert len(recovery.backends) == 2


async def test_old_dictation_during_transfer(recovery, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    old = recovery.engine.stt
    recovery.transfer.clear()
    await client.send(cmd="set_model", model="example/new", kind="stt")
    await client.send(cmd="start", session="old-model", context={})
    while recovery.engine.session is None:
        await asyncio.sleep(.001)
    recovery.transfer.set()
    await asyncio.sleep(.03)
    assert recovery.engine.stt is old  # Ready bytes cannot interrupt the session.
    await client.send(cmd="cancel", session="old-model")
    await client.event("cancelled")
    await client.event("model_set")
    client.writer.close()


async def test_stt_timeout_quarantine(recovery, monkeypatch):
    engine = recovery.engine
    recovery.transfer.set()
    settle = threading.Event()
    entered = threading.Event()
    factory = server.create_backend

    def slow(model, language):
        backend = factory(model, language)
        backend.load.side_effect = lambda: (entered.set(), settle.wait(2))
        return backend

    monkeypatch.setattr(server, "create_backend", slow)
    monkeypatch.setattr(server, "_STT_LOAD_S", .02)
    task = engine._queue_model_job(engine.stt.model_id, "stt")
    try:
        while not entered.is_set():
            await asyncio.sleep(.001)
        while recovery.coordinator.snapshot()["downloads"][0]["state"] != "failed":
            await asyncio.sleep(.001)
        assert not engine.stt_ready.is_set()
        item = recovery.coordinator.snapshot()["downloads"][0]
        await engine._cmd_download_retry({"cmd": "retry_download", "model": item["model"],
                                          "kind": "stt", "attempt": item["attempt"]})
        assert recovery.coordinator.snapshot()["downloads"][0]["attempt"] == item["attempt"]
        assert len(recovery.calls) == 1
    finally:
        settle.set()
        await task
    assert not engine.stt_ready.is_set()  # A late successful load is never adopted.
    assert not engine._stt_pending


async def test_local_identity_load(recovery, monkeypatch):
    engine = recovery.engine
    recovery.transfer.set()
    observed = []
    logical = engine.stt.model_id
    factory = server.create_backend

    def checked(model, language):
        backend = factory(model, language)
        backend.load.side_effect = lambda: observed.append(backend.model_id)
        return backend

    monkeypatch.setattr(server, "create_backend", checked)
    await engine._queue_model_job(logical, "stt")
    assert observed == [str(recovery.coordinator._root)]  # Verified result path.
    assert engine.stt.model_id == logical
    assert engine.config.stt_model == logical


async def test_optional_writing_failure(recovery, socket_engine, monkeypatch):
    engine = recovery.engine
    engine.config.data["cleanup_enabled"] = True
    engine.config.save()
    recovery.failures.add(engine.config.cleanup_model)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    await client.event("setup_complete")
    snapshot = recovery.coordinator.snapshot()
    assert engine.stt_ready.is_set()
    assert snapshot["downloads"][-1]["state"] == "failed"
    assert engine.cleanup is None
    assert engine._cleanup_retry_task is None  # Disk failure needs an explicit action.
    client.writer.close()


async def test_duplicate_recovery_requests(recovery, socket_engine):
    model = recovery.engine.stt.model_id
    recovery.failures.add(model)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    while True:
        snapshot = await client.event("download_status")
        if snapshot["downloads"] and snapshot["downloads"][0]["state"] == "failed":
            break
    item = snapshot["downloads"][0]
    recovery.failures.clear()
    await client.send(cmd="restart_download", model=model, kind="stt", attempt=item["attempt"])
    await client.send(cmd="retry_download", model=model, kind="stt", attempt=item["attempt"])
    await client.event("ready")
    assert recovery.calls == [(model, False), (model, True)]
    client.writer.close()


async def test_failed_reconnect_actionable(recovery, socket_engine):
    model = recovery.engine.stt.model_id
    recovery.failures.add(model)
    recovery.transfer.set()
    first = await _connect(socket_engine)
    while True:
        snapshot = await first.event("download_status")
        if snapshot["downloads"] and snapshot["downloads"][0]["state"] == "failed":
            break
    first.writer.close()
    await first.writer.wait_closed()
    while recovery.engine.writer is not None:
        await asyncio.sleep(.001)
    second = await _connect(socket_engine)
    reconnect = await second.recv()
    assert reconnect["downloads"] == snapshot["downloads"]
    assert reconnect["downloads"][0]["retry_allowed"]
    await second.send(cmd="ping")
    await second.event("pong")
    second.writer.close()


async def test_generation_recheck(recovery, monkeypatch):
    engine = recovery.engine
    recovery.transfer.set()
    await engine._queue_model_job(engine.stt.model_id, "stt")
    entered, settle = threading.Event(), threading.Event()
    factory = server.create_backend

    def slow(model, language):
        item = factory(model, language)
        if model == "example/first":
            item.load.side_effect = lambda: (entered.set(), settle.wait(2))
        return item

    monkeypatch.setattr(server, "create_backend", slow)
    first = engine._queue_model_job("example/first", "stt")
    try:
        while not entered.is_set():
            await asyncio.sleep(.001)
        second = engine._queue_model_job("example/second", "stt")
    finally:
        settle.set()
    await asyncio.gather(first, second)
    assert engine.stt.model_id == "example/second"
    items = recovery.coordinator.snapshot()["downloads"]
    assert items[1]["state"] == "failed"
    assert items[2]["state"] == "ready"
    assert recovery.backends[2].close.call_count == 1


async def test_shutdown_reaps_transfer(recovery, monkeypatch, socket_engine):
    import sys
    from types import MethodType

    coordinator = recovery.coordinator
    monkeypatch.setattr(coordinator, "_once", MethodType(DownloadCoordinator._once, coordinator))
    monkeypatch.setattr(coordinator, "_command", lambda entry, restart: [
        sys.executable, "-u", "-c", "import time; time.sleep(600)"])
    recovery.transfer.set()
    recovery.engine._queue_model_job("example/worker", "stt")
    while ("example/worker", "stt") not in coordinator._entries:
        await asyncio.sleep(.001)
    entry = coordinator._entries[("example/worker", "stt")]
    while entry.process is None:
        await asyncio.sleep(.001)
    process = entry.process
    recovery.engine.shutdown.set()
    while not coordinator._closed:
        await asyncio.sleep(.001)
    while process.returncode is None:
        await asyncio.sleep(.001)
    assert process.returncode is not None


async def test_retry_reap_keeps_reader_live(recovery, monkeypatch, socket_engine):
    model = recovery.engine.stt.model_id
    recovery.failures.add(model)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    while True:
        snapshot = await client.event("download_status")
        if snapshot["downloads"] and snapshot["downloads"][0]["state"] == "failed":
            break
    began, finish = asyncio.Event(), asyncio.Event()
    retry = recovery.coordinator.retry

    async def slow(*args, **kwargs):
        began.set()
        await finish.wait()
        return await retry(*args, **kwargs)

    monkeypatch.setattr(recovery.coordinator, "retry", slow)
    item = snapshot["downloads"][0]
    await client.send(cmd="retry_download", model=model, kind="stt", attempt=item["attempt"])
    await began.wait()
    await client.send(cmd="ping")
    await client.event("pong")
    await client.send(cmd="download_status")
    await client.event("download_status")
    finish.set()
    client.writer.close()


async def test_cold_load_edit_budget(recovery, monkeypatch):
    # Forty-five seconds loading plus sixteen seconds inference must not share
    # the app's old forty-five-second whole-operation deadline.
    now, events = [0.0], []
    monkeypatch.setattr(server.time, "perf_counter", lambda: now[0])

    async def send(event):
        events.append((now[0], event))

    async def load(**kwargs):
        assert events[-1][1]["phase"] == "loading"
        now[0] += 44.9
        return True

    async def infer(*args, **kwargs):
        assert events[-1][1]["phase"] == "inference"
        assert kwargs["timeout_ms"] == 16_000
        now[0] += 16.0
        return SimpleNamespace(text="Changed", applied=True, reason="")

    recovery.engine._send = send
    recovery.engine.cleanup = SimpleNamespace(loaded=False, ensure_loaded=load, cleanup=infer)
    await recovery.engine._run_edit_text({"id": "cold-edit"}, "a" * 2000, "Shorten")
    phases = [(stamp, event) for stamp, event in events if event["event"] == "edit_phase"]
    assert phases[0][0] + phases[0][1]["stall_after_s"] > 44.9
    assert phases[1][0] + phases[1][1]["stall_after_s"] > now[0]
    assert now[0] > 45
    assert events[-1][1]["event"] == "edited"


async def test_edit_loading_cancel_phase(recovery):
    events = []
    engine = recovery.engine
    engine._send = AsyncMock(side_effect=events.append)

    async def cancel(**kwargs):
        kwargs["cancel_event"].set()
        return False

    engine.cleanup = SimpleNamespace(loaded=False, ensure_loaded=cancel)
    await engine._run_edit_text({"id": "cancel-edit"}, "Original", "Shorten")
    assert [event["event"] for event in events] == ["edit_phase", "edit_failed"]
    assert events[-1]["code"] == "cancelled"


async def test_pre_ready_identity(recovery, monkeypatch, socket_engine):
    entered, finish = threading.Event(), threading.Event()
    logical = recovery.engine.stt.model_id
    factory = server.create_backend

    def slow(model, language):
        backend = factory(model, language)
        backend.load.side_effect = lambda: (entered.set(), finish.wait(2))
        return backend

    monkeypatch.setattr(server, "create_backend", slow)
    # Current startup path also uses the already-constructed backend.
    recovery.engine.stt.load.side_effect = lambda: (entered.set(), finish.wait(2))
    recovery.transfer.set()
    client = await _connect(socket_engine)
    try:
        while not entered.is_set():
            await asyncio.sleep(.001)
        await client.send(cmd="status")
        assert (await client.event("status"))["stt_model"] == logical
    finally:
        finish.set()
        client.writer.close()


async def test_shutdown_stt_settle(recovery, monkeypatch, socket_engine):
    entered, finish = threading.Event(), threading.Event()
    factory = server.create_backend

    def slow(model, language):
        backend = factory(model, language)
        backend.load.side_effect = lambda: (entered.set(), finish.wait(2))
        return backend

    monkeypatch.setattr(server, "create_backend", slow)
    recovery.transfer.set()
    try:
        while not entered.is_set():
            await asyncio.sleep(.001)
        recovery.engine.shutdown.set()
        await asyncio.sleep(.03)
        assert recovery.engine._stt_pending  # Shutdown cannot claim thread cancellation.
    finally:
        finish.set()
    while recovery.engine._stt_pending:
        await asyncio.sleep(.001)
    assert not recovery.engine.stt_ready.is_set()


async def test_explicit_local_model(recovery, monkeypatch, tmp_path):
    # Explicit paths retain the existing trust rule; a Hub-only cache probe
    # cannot reject a coordinator-accepted local model.
    monkeypatch.setattr(server.models, "is_cached", lambda model: False)
    recovery.transfer.set()
    local = tmp_path / "local-model"
    local.mkdir()
    await recovery.engine._queue_model_job(str(local), "stt")
    assert recovery.engine.stt_ready.is_set()
    assert recovery.engine.stt.model_id == str(local)
