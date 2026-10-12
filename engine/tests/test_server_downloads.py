"""Recovery server contracts over framed sockets and controlled local loaders."""
import asyncio
import json
import shutil
import sys
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
    monkeypatch.setattr(server.models, "remove_from_cache", lambda model: 0)
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

    async def recv(self, timeout=1):
        kind, payload = await asyncio.wait_for(protocol.read_frame(self.reader), timeout)
        assert kind == protocol.FRAME_JSON
        return json.loads(payload)

    async def event(self, name, timeout=1):
        while True:
            event = await self.recv(timeout)
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


@pytest.mark.parametrize("command", ["retry_download", "restart_download"])
@pytest.mark.parametrize("failure", ["transfer", "load"])
async def test_cleanup_switch_recovery(recovery, monkeypatch, command, failure):
    engine = recovery.engine
    engine.config.data.update(cleanup_enabled=True, cleanup_model="example/cleanup-a")
    engine.config.save()
    old = SimpleNamespace(model_id="example/cleanup-a", loaded=True,
                          load_async=AsyncMock(), aclose=AsyncMock())
    attempts = []

    def candidate(model, **kwargs):
        if model == old.model_id:
            return old

        async def load(prompt):
            if failure == "load" and len(attempts) == 1:
                raise RuntimeError("first load failed")

        item = SimpleNamespace(model_id=model, loaded=True,
                               load_async=load, aclose=AsyncMock())
        attempts.append(item)
        return item

    monkeypatch.setattr(engine, "_new_cleanup_process", candidate)
    recovery.transfer.set()
    await engine._cmd_set_model({"model": old.model_id, "kind": "cleanup"})
    if failure == "transfer":
        recovery.failures.add("example/cleanup-b")
    error = DownloadError if failure == "transfer" else RuntimeError
    with pytest.raises(error):
        await engine._cmd_set_model({"model": "example/cleanup-b", "kind": "cleanup"})
    assert engine.cleanup is old
    assert engine.config.cleanup_model == "example/cleanup-a"
    item = recovery.coordinator.snapshot()["downloads"][-1]
    assert item["active_model"] == old.model_id
    recovery.failures.clear()
    await engine._cmd_download_retry({"cmd": command, "model": item["model"],
                                      "kind": "cleanup", "attempt": item["attempt"]})
    await engine._model_jobs[(item["model"], "cleanup")]
    assert engine.cleanup is attempts[-1]
    assert engine.config.cleanup_model == "example/cleanup-b"
    item = recovery.coordinator.snapshot()["downloads"][-1]
    assert item["state"] == "ready"
    assert item["active_model"] == "example/cleanup-b"
    old.aclose.assert_awaited_once()
    assert recovery.calls == [("example/cleanup-a", False), ("example/cleanup-b", False),
                              ("example/cleanup-b", command == "restart_download")]


@pytest.mark.parametrize("phase", ["transfer", "loading"])
async def test_same_model_latest_selection(recovery, monkeypatch, phase):
    engine = recovery.engine
    events = []
    engine._send = AsyncMock(side_effect=events.append)
    entered, finish = threading.Event(), threading.Event()
    factory = server.create_backend
    candidates = []

    def slow(model, language):
        backend = factory(model, language)
        if not candidates and model == "example/a":
            backend.load.side_effect = lambda: (entered.set(), finish.wait(2))
        candidates.append(backend)
        return backend

    if phase == "loading":
        monkeypatch.setattr(server, "create_backend", slow)
        recovery.transfer.set()
    try:
        for index, model in enumerate(("example/a", "example/b", "example/a")):
            await engine._cmd_set_model({"model": model, "kind": "stt"}, wait=False)
            if phase == "loading" and index == 0:
                while not entered.is_set():
                    await asyncio.sleep(.001)
            await asyncio.sleep(.001)
    finally:
        finish.set()
        recovery.transfer.set()
    await asyncio.gather(*engine._adoption_jobs)
    assert engine.stt.model_id == "example/a"
    assert engine.config.stt_model == "example/a"
    assert [event for event in events if event["event"] == "model_set"] == [
        {"event": "model_set", "model": "example/a", "kind": "stt"}]
    assert not [event for event in events if event["event"] == "error"]
    assert recovery.calls.count(("example/a", False)) == 1
    assert recovery.coordinator.snapshot()["downloads"][0]["state"] == "ready"


@pytest.mark.parametrize("command,event", [
    ("meeting_transcribe", "meeting_transcribe_failed"),
    ("meeting_notes", "meeting_notes_failed"),
    ("transcribe_file", "transcribe_failed"),
    ("reprocess", "reprocess_failed"),
    ("edit_text", "edit_failed"),
    ("action_start", "action_failed"),
    ("action_observe", "action_failed"),
    ("start", "error"),
])
async def test_adoption_terminal_events(recovery, socket_engine, monkeypatch, command, event):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    ready = await client.event("ready")
    if not ready["setup_complete"]:
        await client.event("setup_complete")
    entered, finish = threading.Event(), threading.Event()
    factory = server.create_backend

    def slow(model, language):
        backend = factory(model, language)
        backend.load.side_effect = lambda: (entered.set(), finish.wait(2))
        return backend

    monkeypatch.setattr(server, "create_backend", slow)
    await client.send(cmd="set_model", model="example/switch", kind="stt")
    try:
        while not entered.is_set():
            await asyncio.sleep(.001)
        await client.send(cmd=command, id="busy-job", meeting_id="meeting-1",
                          speaker="them", session="busy-session")
        rejected = await client.recv()
        while rejected["event"] == "download_status":
            rejected = await client.recv()
        assert rejected["event"] == event
        if command == "start":
            assert rejected["session"] == "busy-session"
        else:
            assert rejected["id"] == "busy-job"
            assert "busy" in rejected["error"]
        if command != "start" and command != "transcribe_file":
            assert rejected["code"] == "busy"
        if command.startswith("meeting_"):
            assert rejected["meeting_id"] == "meeting-1"
        if command == "meeting_transcribe":
            assert rejected["speaker"] == "them"
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        finish.set()
        client.writer.close()


@pytest.mark.parametrize("pending", [False, True])
async def test_pre_ready_cleanup_selection(recovery, socket_engine, monkeypatch, pending):
    engine = recovery.engine
    engine.config.data.update(cleanup_enabled=True, cleanup_model="example/cleanup-a")
    engine.config.save()
    selected = SimpleNamespace(model_id="example/cleanup-b", loaded=True,
                               load_async=AsyncMock(), aclose=AsyncMock())
    factory = Mock(return_value=selected)
    monkeypatch.setattr(engine, "_new_cleanup_process", factory)
    cleanup_transfer = asyncio.Event()
    if not pending:
        cleanup_transfer.set()
    once = recovery.coordinator._once

    async def gated(entry, restart):
        if entry.item["kind"] == "cleanup":
            await cleanup_transfer.wait()
            return DownloadResult(str(recovery.coordinator._root), None, entry.item["attempt"])
        return await once(entry, restart)

    monkeypatch.setattr(recovery.coordinator, "_once", gated)
    client = await _connect(socket_engine)
    await client.send(cmd="set_model", model="example/cleanup-b", kind="cleanup")
    if not pending:
        await client.event("model_set")
    else:
        while ("example/cleanup-b", "cleanup") not in recovery.coordinator._entries:
            await asyncio.sleep(.001)
    recovery.transfer.set()
    await client.event("ready")
    cleanup_transfer.set()
    if pending:
        await client.event("model_set")
    while not engine.setup_complete:
        await asyncio.sleep(.001)
    assert engine.cleanup is selected
    assert engine.config.cleanup_model == "example/cleanup-b"
    factory.assert_called_once_with("example/cleanup-b",
                                    local_model_path=str(recovery.coordinator._root))
    selected.load_async.assert_awaited_once()
    selected.aclose.assert_not_awaited()
    items = [item for item in recovery.coordinator.snapshot()["downloads"] if item["kind"] == "cleanup"]
    assert [(item["model"], item["state"]) for item in items] == [("example/cleanup-b", "ready")]
    client.writer.close()


@pytest.fixture
def cleanup_sources(recovery, monkeypatch):
    # Capture the production constructor seam, keeping loads small and local.
    workers = []

    def construct(model, **kwargs):
        item = SimpleNamespace(model_id=model, loaded=True, kwargs=kwargs,
                               load_async=AsyncMock(), aclose=AsyncMock())
        workers.append(item)
        return item

    monkeypatch.setattr(server, "CleanupProcess", construct)
    monkeypatch.setattr(server.models, "remove_from_cache", lambda model: 0)
    recovery.engine.config.data.update(cleanup_enabled=True, cleanup_model="example/cleanup-a")
    recovery.engine.config.save()
    return workers


async def test_cleanup_verified_startup(recovery, cleanup_sources, socket_engine, monkeypatch):
    # STT ready -> cleanup transfer pending -> verified source -> proxy -> ready.
    gate = asyncio.Event()
    once = recovery.coordinator._once

    async def gated(entry, restart):
        if entry.item["kind"] == "cleanup":
            await gate.wait()
        return await once(entry, restart)

    monkeypatch.setattr(recovery.coordinator, "_once", gated)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    try:
        await client.event("ready")
        assert cleanup_sources == []  # No unverified ID-only placeholder.
        gate.set()
        await client.event("setup_complete")
        assert len(cleanup_sources) == 1
        worker = cleanup_sources[0]
        assert worker.kwargs["local_model_path"] == str(recovery.coordinator._root)
        assert worker.model_id == recovery.engine.config.cleanup_model
        snapshot = recovery.coordinator.snapshot()
        assert snapshot["downloads"][-1]["active_model"] == worker.model_id
    finally:
        gate.set()
        client.writer.close()


async def test_cleanup_verified_switch_retry(recovery, cleanup_sources, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    try:
        await client.event("ready")
        await client.event("setup_complete")
        await client.send(cmd="set_model", model="example/cleanup-b", kind="cleanup")
        accepted = await client.event("model_set")
        assert accepted == {"event": "model_set", "model": "example/cleanup-b", "kind": "cleanup"}
        assert all(worker.kwargs["local_model_path"] == str(recovery.coordinator._root)
                   for worker in cleanup_sources)
        recovery.engine.cleanup = None
        await recovery.engine._retry_cleanup_attempt(1)
        assert cleanup_sources[-1].kwargs["local_model_path"] == str(recovery.coordinator._root)
        assert recovery.engine.cleanup is cleanup_sources[-1]
    finally:
        client.writer.close()


@pytest.mark.parametrize("failure", [None, "load", "construct"])
async def test_aux_adoption_snapshot(recovery, socket_engine, monkeypatch, failure):
    # Auxiliary adoption publishes ready/failed without replacing the primary.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    engine = recovery.engine
    primary = engine.stt
    factory = server.create_backend

    def auxiliary(model, language):
        if failure == "construct":
            raise RuntimeError("backend construction failed")
        backend = factory(model, language)
        if failure == "load":
            backend.load.side_effect = RuntimeError("backend load failed")
        return backend

    monkeypatch.setattr(server, "create_backend", auxiliary)
    try:
        if failure:
            with pytest.raises(RuntimeError):
                await engine._stt_for_reprocess("example/aux", "en")
        else:
            backend = await engine._stt_for_reprocess("example/aux", "en")
            assert engine._reprocess_backend is backend
            assert backend.model_id == "example/aux"
        snapshot = await client.event("download_status")
        while snapshot["downloads"][-1]["state"] not in ("ready", "failed"):
            snapshot = await client.event("download_status")
        assert snapshot["downloads"][-1]["state"] == ("failed" if failure else "ready")
        assert all(item["active_model"] == primary.model_id for item in snapshot["downloads"])
        assert engine.stt is primary
        assert engine.config.stt_model == primary.model_id
        if failure:
            assert engine._reprocess_backend is None
        client.writer.close()
        await client.writer.wait_closed()
        while engine.writer is not None:
            await asyncio.sleep(.001)
        client = await _connect(socket_engine)
        reconnect = await client.recv()
        assert reconnect["downloads"] == snapshot["downloads"]
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        client.writer.close()


async def test_cleanup_verified_retry(recovery, cleanup_sources):
    # Background retry must use the same verified source as explicit selection.
    recovery.transfer.set()
    assert await recovery.engine._retry_cleanup_attempt(1)
    assert cleanup_sources[-1].kwargs["local_model_path"] == str(recovery.coordinator._root)


@pytest.mark.parametrize("entrypoint", ["switch", "hibernate", "recovery"])
async def test_cleanup_source_removed(
    recovery, monkeypatch, tmp_path, socket_engine, capfd, entrypoint,
):
    # Server -> production proxy/CLI/worker -> local loader; acquisition trips fail.
    from velora_engine.cleanup_process import CleanupProcess
    import velora_engine.cleanup_process as process_module

    source = tmp_path / "verified-model"
    source.mkdir()
    (source / "config.json").write_text('{"eos_token_id": 7}')
    record = tmp_path / "loads.jsonl"
    workers = []
    cache_checks = []

    async def once(entry, restart):
        return DownloadResult(str(source), None, entry.item["attempt"])

    def construct(model, **kwargs):
        worker = CleanupProcess(model, worker_command=[
            sys.executable, str(Path(__file__).parent / "fixtures" / "offline_cleanup_worker.py"),
            str(record)], **kwargs)
        workers.append(worker)
        return worker

    def cached(model):
        cache_checks.append(model)
        return True

    monkeypatch.setattr(recovery.coordinator, "_once", once)
    monkeypatch.setattr(server, "CleanupProcess", construct)
    monkeypatch.setattr(server.models, "is_cached", cached)
    monkeypatch.setattr(server.models, "remove_from_cache", lambda model: 0)
    monkeypatch.setattr(process_module, "RECOVERY_BACKOFF_S", .01)
    monkeypatch.setattr(recovery.engine, "_queue_cleanup_unhealthy_restart", Mock())
    recovery.engine.config.data.update(cleanup_enabled=True, cleanup_model="example/cleanup-a")
    recovery.engine.config.save()
    recovery.transfer.set()
    client = await _connect(socket_engine)
    try:
        await client.event("ready")
        await client.event("setup_complete", timeout=15)
        primary = recovery.engine.cleanup
        assert primary is not None
        assert json.loads(record.read_text().splitlines()[0]) == {
            "model_id": "example/cleanup-a", "source": str(source)}
        if entrypoint == "hibernate":
            assert await primary.hibernate()
        (source / "config.json").unlink()
        source.rmdir()
        if entrypoint == "switch":
            await client.send(cmd="set_model", model="example/cleanup-b", kind="cleanup")
            await client.event("error", timeout=15)
            snapshot = recovery.coordinator.snapshot()
            assert snapshot["downloads"][-1]["state"] == "failed"
            assert snapshot["downloads"][-1]["error"]["code"] == "model_load_failed"
            assert snapshot["downloads"][-1]["active_model"] == primary.model_id
            assert "example/cleanup-b" in cache_checks  # Disappeared after a positive cache check.
            assert recovery.engine.cleanup is primary
        elif entrypoint == "hibernate":
            assert not await primary.ensure_loaded()
            assert not primary.loaded and primary.pid is None
        else:
            primary._process.kill()
            async with asyncio.timeout(15):
                while not primary.unhealthy:
                    await asyncio.sleep(.01)
            assert not primary.loaded and primary.pid is None
        # No missing-source load reached the model double or any acquisition helper.
        assert len(record.read_text().splitlines()) == 2
        stderr = capfd.readouterr().err
        assert "offline cleanup attempted acquisition" not in stderr
        assert "Offline cleanup load failed for" in stderr
        assert "Reacquire the model" in stderr
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        client.writer.close()
        for worker in workers:
            await worker.aclose()


@pytest.mark.parametrize("outcome", ["ready", "failed", "cancelled", "timeout"])
async def test_notes_before_verified_proxy(
    recovery, cleanup_sources, socket_engine, monkeypatch, outcome,
):
    # Submit after speech-ready, while verification has not produced a proxy.
    entered, release = asyncio.Event(), asyncio.Event()
    once = recovery.coordinator._once

    async def verifying(entry, restart):
        if entry.item["kind"] == "cleanup":
            recovery.coordinator._update(entry, state="verifying")
            entered.set()
            await release.wait()
        return await once(entry, restart)

    monkeypatch.setattr(recovery.coordinator, "_once", verifying)
    if outcome == "timeout":
        monkeypatch.setattr(server, "MEETING_NOTES_MODEL_READY_WAIT_S", .15)
    if outcome == "failed":
        recovery.failures.add("example/cleanup-a")
    original = server.CleanupProcess

    def notes_model(model, **kwargs):
        proxy = original(model, **kwargs)
        proxy.cleanup = AsyncMock(return_value=SimpleNamespace(
            applied=True, text=json.dumps({"summary": "Recovered notes.",
                                           "decisions": [], "action_items": []})))
        return proxy

    monkeypatch.setattr(server, "CleanupProcess", notes_model)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    try:
        await client.event("ready")
        await asyncio.wait_for(entered.wait(), 1)
        assert cleanup_sources == []
        await client.send(cmd="meeting_notes", id="pending-notes", meeting_id="m-pending",
                          transcript="[00:00] Me: Resume these saved notes.")
        await client.event("meeting_notes_accepted")
        # A ping fences the reader; a short bounded absence check lets the notes
        # task run and catches the original premature generation_failed event.
        await client.send(cmd="ping")
        await client.event("pong")
        with pytest.raises(TimeoutError):
            await client.event("meeting_notes_failed", timeout=.04)
        assert recovery.engine._meeting_notes_running
        if outcome in ("ready", "failed"):
            release.set()
        elif outcome == "cancelled":
            await client.send(cmd="meeting_notes_cancel", id="pending-notes")
        terminal = await client.event("meeting_notes_ready" if outcome == "ready"
                                      else "meeting_notes_failed")
        assert terminal["id"] == "pending-notes"
        assert terminal["meeting_id"] == "m-pending"
        if outcome == "ready":
            assert terminal["summary"] == "Recovered notes."
            cleanup_sources[0].cleanup.assert_awaited_once()
        else:
            assert terminal["code"] == ("cancelled" if outcome == "cancelled"
                                        else "generation_failed")
            assert cleanup_sources == []
        assert not recovery.engine._meeting_notes_running
        assert recovery.engine._meeting_notes_job_id is None
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        release.set()
        client.writer.close()


async def test_identified_busy_selection(recovery, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    recovery.engine._editing = True
    try:
        await client.send(cmd="set_model", model="example/selected", kind="cleanup",
                          request_id="busy-selection")
        error = await client.event("error")
        assert {key: error[key] for key in ("command", "model", "kind", "request_id")} == {
            "command": "set_model", "model": "example/selected", "kind": "cleanup",
            "request_id": "busy-selection"}
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        recovery.engine._editing = False
        client.writer.close()


@pytest.mark.parametrize("phase", ["transfer", "loading"])
async def test_identified_latest_selection(recovery, socket_engine, monkeypatch, phase):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    recovery.transfer.clear()
    entered, settle = threading.Event(), threading.Event()
    factory = server.create_backend

    def slow(model, language):
        backend = factory(model, language)
        if model == "example/a":
            backend.load.side_effect = lambda: (entered.set(), settle.wait(2))
        return backend

    if phase == "loading":
        monkeypatch.setattr(server, "create_backend", slow)
        recovery.transfer.set()
    try:
        for model, request in (("example/a", "old-a"), ("example/b", "old-b"),
                               ("example/a", "latest-a")):
            await client.send(cmd="set_model", model=model, kind="stt", request_id=request)
            await client.send(cmd="ping")
            await client.event("pong")
            if phase == "loading" and request == "old-a":
                async with asyncio.timeout(1):
                    while not entered.is_set():
                        await asyncio.sleep(.001)
        settle.set()
        recovery.transfer.set()
        replies = []
        while len(replies) < 3:
            event = await client.recv()
            if event["event"] in ("error", "model_set"):
                replies.append(event)
        assert [event["request_id"] for event in replies if event["event"] == "model_set"] == ["latest-a"]
        errors = {event["request_id"]: event for event in replies if event["event"] == "error"}
        assert set(errors) == {"old-a", "old-b"}
        assert all(event["error"]["code"] == "model_selection_superseded" for event in errors.values())
        assert errors["old-a"]["model"] == "example/a"
        assert errors["old-b"]["model"] == "example/b"
        assert recovery.calls.count(("example/a", False)) == 1
        assert recovery.engine.stt.model_id == "example/a"
    finally:
        settle.set()
        recovery.transfer.set()
        client.writer.close()


@pytest.mark.parametrize("kind", ["stt", "cleanup"])
@pytest.mark.parametrize("failure", ["transfer", "construct", "load", "config", "cache"])
async def test_identified_selection_failure(
    recovery, socket_engine, monkeypatch, kind, failure,
):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    engine = recovery.engine
    primary = engine.stt if kind == "stt" else engine.cleanup
    target = "example/rejected"
    if failure == "transfer":
        recovery.failures.add(target)
    elif failure == "config":
        monkeypatch.setattr(engine.config, "save", Mock(side_effect=OSError("disk full")))
    elif failure == "cache":
        monkeypatch.setattr(server.models, "is_cached", lambda model: False)
    if kind == "cleanup":
        def cleanup(model, **kwargs):
            if failure == "construct":
                raise RuntimeError("private constructor failure")
            load = AsyncMock(side_effect=RuntimeError("private load failure")
                             if failure == "load" else None)
            return SimpleNamespace(model_id=model, loaded=True, load_async=load,
                                   aclose=AsyncMock())
        monkeypatch.setattr(server, "CleanupProcess", cleanup)
    else:
        factory = server.create_backend

        def speech(model, language):
            if failure == "construct":
                raise RuntimeError("private constructor failure")
            backend = factory(model, language)
            if failure == "load":
                backend.load.side_effect = RuntimeError("private load failure")
            return backend
        monkeypatch.setattr(server, "create_backend", speech)
    try:
        await client.send(cmd="set_model", model=target, kind=kind, request_id="failed-selection")
        error = await client.event("error")
        assert {key: error[key] for key in ("command", "model", "kind", "request_id")} == {
            "command": "set_model", "model": target, "kind": kind,
            "request_id": "failed-selection"}
        assert "private" not in json.dumps(error)
        assert (engine.stt if kind == "stt" else engine.cleanup) is primary
        assert engine._model_notifications == {}
        await client.send(cmd="ping")
        await client.event("pong")
    finally:
        client.writer.close()


async def test_identified_duplicate_ids(recovery, socket_engine, monkeypatch):
    # Distinct IDs coalesce, identical IDs reply once, and retention is bounded.
    monkeypatch.setattr(server, "_MODEL_REQUESTS_MAX", 3)
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    recovery.transfer.clear()
    target = "example/coalesced"
    try:
        for request in ("first", "first", "second", None, "excess"):
            await client.send(cmd="set_model", model=target, kind="stt", request_id=request)
        error = await client.event("error")
        assert error["request_id"] == "excess"
        assert error["model"] == target and error["command"] == "set_model"
        assert "too many" in error["message"]
        recovery.transfer.set()
        replies = [await client.event("model_set") for _ in range(3)]
        assert {event.get("request_id") for event in replies} == {"first", "second", None}
        assert next(event for event in replies if "request_id" not in event) == {
            "event": "model_set", "model": target, "kind": "stt"}
        await client.send(cmd="ping")
        event = await client.recv()
        while event["event"] == "download_status":
            event = await client.recv()
        assert event["event"] == "pong"  # No extra duplicate acknowledgment queued.
        assert recovery.calls.count((target, False)) == 1
        assert recovery.engine._model_notifications == {}
    finally:
        recovery.transfer.set()
        client.writer.close()


@pytest.mark.parametrize("invalid", ["", 1, [], {"secret": "object"}, "x" * 129])
async def test_selection_invalid_id(recovery, socket_engine, invalid):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    try:
        await client.send(cmd="set_model", model="example/rejected", kind="stt", request_id=invalid)
        error = await client.event("error")
        assert error["command"] == "set_model" and error["request_id"] is None
        assert "invalid 'request_id'" in error["message"]
        assert "secret" not in json.dumps(error)
        assert ("example/rejected", "stt") not in recovery.engine._model_jobs
    finally:
        client.writer.close()


async def test_selection_disconnect_ids(recovery, socket_engine):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    recovery.transfer.clear()
    try:
        await client.send(cmd="set_model", model="example/pending", kind="stt", request_id="old-client")
        await client.send(cmd="ping")
        await client.event("pong")
        assert recovery.engine._model_notifications
        client.writer.close()
        await client.writer.wait_closed()
        while recovery.engine.writer is not None:
            await asyncio.sleep(.001)
        assert recovery.engine._model_notifications == {}
        client = await _connect(socket_engine)
        await client.event("ready")
        recovery.transfer.set()
        await recovery.engine._model_jobs[("example/pending", "stt")]
        await client.send(cmd="ping")
        event = await client.recv()
        while event["event"] == "download_status":
            event = await client.recv()
        assert event["event"] == "pong"  # Reconnect cannot inherit an old request ID.
    finally:
        recovery.transfer.set()
        client.writer.close()


async def test_selection_ids_during_reply(recovery, socket_engine, monkeypatch):
    # Admission during a reply drain must neither lose new IDs nor re-reply old IDs.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    send = recovery.engine._send
    replying, release = asyncio.Event(), asyncio.Event()

    async def delayed(event):
        await send(event)
        if event["event"] == "model_set" and event.get("request_id") == "first":
            replying.set()
            await release.wait()

    monkeypatch.setattr(recovery.engine, "_send", delayed)
    try:
        await client.send(cmd="set_model", model="example/coalesced", kind="stt", request_id="first")
        assert (await client.event("model_set"))["request_id"] == "first"
        await asyncio.wait_for(replying.wait(), 1)
        for request in ("first", "second"):
            await client.send(cmd="set_model", model="example/coalesced", kind="stt", request_id=request)
        await client.send(cmd="ping")
        await client.event("pong")
        release.set()
        assert (await client.event("model_set"))["request_id"] == "second"
        await client.send(cmd="ping")
        assert (await client.recv())["event"] == "pong"
        assert recovery.calls.count(("example/coalesced", False)) == 1
        assert recovery.engine._model_notifications == {}
    finally:
        release.set()
        client.writer.close()


@pytest.mark.parametrize("arguments", [{"model": []}, {"model": "example/a", "kind": ["invalid"]}])
async def test_selection_invalid_arguments(recovery, socket_engine, arguments):
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    try:
        await client.send(cmd="set_model", request_id="invalid-arguments", **arguments)
        error = await client.event("error")
        assert error["command"] == "set_model"
        assert error["request_id"] == "invalid-arguments"
        assert not recovery.engine._model_notifications
    finally:
        client.writer.close()


async def test_selection_cancel_before_acquire(recovery, socket_engine):
    # A replacement A waits on its first job; cancellation must settle its IDs
    # without cancelling the shared predecessor's acquisition.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    recovery.transfer.clear()
    try:
        for model, request in (("example/a", "old-a"), ("example/b", "old-b"),
                               ("example/a", "cancelled-a")):
            await client.send(cmd="set_model", model=model, kind="stt", request_id=request)
            await client.send(cmd="ping")
            await client.event("pong")
        task = recovery.engine._model_jobs[("example/a", "stt")]
        task.cancel()
        error = await client.event("error")
        assert error["request_id"] == "cancelled-a"
        assert error["error"]["code"] == "model_selection_cancelled"
        assert ("stt", recovery.engine._model_generation["stt"]) not in recovery.engine._model_notifications
        recovery.transfer.set()
        await asyncio.gather(*recovery.engine._adoption_jobs, return_exceptions=True)
        assert recovery.calls.count(("example/a", False)) == 1
    finally:
        recovery.transfer.set()
        client.writer.close()


@pytest.mark.parametrize("outcome", ["accepted", "failed"])
@pytest.mark.parametrize("stop", ["cancel", "repeated", "shutdown"])
async def test_selection_cancel_drain(
    recovery, socket_engine, monkeypatch, outcome, stop,
):
    # Pause after the first terminal frame, coalesce another ID, then cancel.
    # Cancellation must not replay first or change the already established result.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    target = "example/draining"
    primary = recovery.engine.stt
    if outcome == "failed":
        recovery.failures.add(target)
    send = recovery.engine._send
    replying, release = asyncio.Event(), asyncio.Event()

    async def delayed(event):
        await send(event)
        if event.get("request_id") == "first":
            replying.set()
            await release.wait()

    monkeypatch.setattr(recovery.engine, "_send", delayed)
    try:
        await client.send(cmd="set_model", model=target, kind="stt", request_id="first")
        first = await client.event("model_set" if outcome == "accepted" else "error")
        await asyncio.wait_for(replying.wait(), 1)
        await client.send(cmd="set_model", model=target, kind="stt", request_id="second")
        await client.send(cmd="ping")
        await client.event("pong")
        task = recovery.engine._model_jobs[(target, "stt")]
        if stop == "shutdown":
            recovery.engine.shutdown.set()
        else:
            task.cancel()
        if stop == "repeated":
            for _ in range(3):
                await asyncio.sleep(.01)
                task.cancel()
        release.set()
        second = await client.recv()
        while second["event"] == "download_status":
            second = await client.recv()
        assert second == {**first, "request_id": "second"}
        await asyncio.wait_for(asyncio.gather(task, return_exceptions=True), 1)
        assert recovery.engine._model_notifications == {}
        if stop != "shutdown":
            if outcome == "accepted":
                assert recovery.engine.stt.model_id == target
            else:
                assert recovery.engine.stt is primary
            await client.send(cmd="ping")
            assert (await client.recv())["event"] == "pong"  # No duplicate first reply.
    finally:
        release.set()
        client.writer.close()


@pytest.mark.parametrize("outcome", ["accepted", "failed"])
@pytest.mark.parametrize("stop", ["repeated", "shutdown"])
async def test_selection_blocked_transport(
    recovery, socket_engine, monkeypatch, outcome, stop,
):
    # Block the real captured writer after write(), including wait_closed.
    # Repeated cancellation/shutdown must end within the fixed transport bound.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    engine = recovery.engine
    target = "example/blocked"
    primary = engine.stt
    if outcome == "failed":
        recovery.failures.add(target)
    writer = engine.writer
    blocked = asyncio.Event()

    async def stall():
        blocked.set()
        await asyncio.Event().wait()

    send = engine._send

    async def terminal_send(event):
        if event.get("request_id") == "first":
            monkeypatch.setattr(writer, "drain", stall)
        await send(event)

    monkeypatch.setattr(engine, "_send", terminal_send)
    monkeypatch.setattr(writer, "wait_closed", stall)
    try:
        await client.send(cmd="set_model", model=target, kind="stt", request_id="first")
        first = await client.event("model_set" if outcome == "accepted" else "error")
        assert first["request_id"] == "first"
        await asyncio.wait_for(blocked.wait(), 1)
        await client.send(cmd="set_model", model=target, kind="stt", request_id="second")
        async with asyncio.timeout(1):
            while not any(len(item.requests) == 2 for item in engine._model_notifications.values()):
                await asyncio.sleep(.001)
        task = engine._model_jobs[(target, "stt")]
        if stop == "shutdown":
            engine.shutdown.set()
        else:
            for _ in range(3):
                task.cancel()
                await asyncio.sleep(.01)
        await asyncio.wait_for(asyncio.gather(task, return_exceptions=True),
                               server._MODEL_REPLY_DRAIN_S + 1)
        assert engine._model_notifications == {}
        assert writer.is_closing()
        if stop != "shutdown":
            if outcome == "accepted":
                assert engine.stt.model_id == target
            else:
                assert engine.stt is primary
        # The first possibly-written frame is never replayed; second cannot be
        # written after the connection is fenced. EOF is transport failure, not
        # a different model outcome attributed to either request.
        while True:
            try:
                event = await client.recv()
            except asyncio.IncompleteReadError:
                break
            assert event["event"] == "download_status"
    finally:
        client.writer.close()


@pytest.mark.parametrize("stop", ["cancel", "shutdown"])
async def test_selection_drain_reconnect(recovery, socket_engine, monkeypatch, stop):
    # A new client can arrive before the old writer's timeout. Its same-target
    # request gets a new generation, not the old drain's cursor or cancellation.
    recovery.transfer.set()
    client = await _connect(socket_engine)
    await client.event("ready")
    engine = recovery.engine
    send = engine._send
    replying = asyncio.Event()
    target = "example/reconnected"

    async def delayed(event):
        await send(event)
        if event.get("request_id") == "old-first":
            replying.set()
            await asyncio.Event().wait()

    monkeypatch.setattr(engine, "_send", delayed)
    try:
        await client.send(cmd="set_model", model=target, kind="stt", request_id="old-first")
        await client.event("model_set")
        await asyncio.wait_for(replying.wait(), 1)
        await client.send(cmd="set_model", model=target, kind="stt", request_id="old-second")
        await client.send(cmd="ping")
        await client.event("pong")
        old_task = engine._model_jobs[(target, "stt")]
        old_generation = engine._model_generation["stt"]
        client.writer.close()
        await client.writer.wait_closed()
        async with asyncio.timeout(1):
            while engine.writer is not None:
                await asyncio.sleep(.001)
        client = await _connect(socket_engine)
        await client.event("ready")
        new_writer = engine.writer
        await client.send(cmd="set_model", model=target, kind="stt", request_id="new-client")
        await client.send(cmd="ping")
        await client.event("pong")
        assert engine._model_generation["stt"] > old_generation
        if stop == "shutdown":
            engine.shutdown.set()
        else:
            for _ in range(3):
                old_task.cancel()
                await asyncio.sleep(.01)
        terminal = await client.recv(timeout=server._MODEL_REPLY_DRAIN_S + 1)
        while terminal["event"] == "download_status":
            terminal = await client.recv(timeout=server._MODEL_REPLY_DRAIN_S + 1)
        assert terminal["request_id"] == "new-client"
        assert terminal["event"] == ("error" if stop == "shutdown" else "model_set")
        await asyncio.wait_for(asyncio.gather(old_task, return_exceptions=True),
                               server._MODEL_REPLY_DRAIN_S + 1)
        assert not new_writer.is_closing()
        assert engine._model_notifications == {}
        if stop == "cancel":
            assert engine.stt.model_id == target
            await client.send(cmd="ping")
            assert (await client.recv())["event"] == "pong"
    finally:
        client.writer.close()
