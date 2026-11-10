import asyncio
import json
import os
import hashlib
import threading
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from test_cleanup_process import fixture_command
from test_server import AUDIO, connect, engine  # noqa: F401
from velora_engine import native_cleanup, server as server_mod
from velora_engine.cleanup_process import CleanupProcess
from velora_engine.config import Config
from velora_engine.downloads import DownloadResult
from velora_engine.native_cleanup import NativeCleanupRouter


class TrialRuntime:
    fail = False

    def __init__(self, package):
        self.loaded = False
        self.unhealthy = False
        self.pid = None
        self.calls = []

    async def load(self, cancel_event=None):
        if self.fail:
            raise RuntimeError("native load refused")
        self.loaded = True
        return {}

    async def generate(self, system, user, **kwargs):
        try:
            payload = json.loads(user)
        except ValueError:
            payload = {"transcript": user}
        if not isinstance(payload, dict) or "transcript" not in payload:
            payload = {"transcript": user}
        self.calls.append((system, payload, kwargs))
        text = payload["transcript"]
        return {"event": "result", "status": "eos", "text": text,
                "elapsed_ms": 1, "prompt_tokens": [1], "output_tokens": [2]}

    async def aclose(self):
        self.loaded = False
        self.pid = None


@pytest.fixture
def trial(monkeypatch):
    monkeypatch.setattr(server_mod, "discover_package", lambda home: SimpleNamespace())
    monkeypatch.setattr(native_cleanup, "NativeRuntime", TrialRuntime)
    monkeypatch.setattr(TrialRuntime, "fail", False)


async def settled(client, request_id):
    while True:
        message = await client.recv_event("status")
        if message.get("native_cleanup_request_id") == request_id and not message["native_cleanup_switching"]:
            return message


async def install_standard(eng):
    standard = CleanupProcess("fake-quality", worker_command=fixture_command())
    await standard.load_async()
    eng.cleanup = standard
    return standard


def test_native_trial_defaults_off(home):
    assert Config(home).experimental_native_cleanup is False


async def test_trial_selection_real_socket_persists_only_acknowledged_choice(engine, trial):
    eng, sock = engine
    standard = await install_standard(eng)
    old_pid = standard.pid
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "enable"})
    reply = await settled(client, "enable")
    assert reply["native_cleanup_enabled"] and not reply.get("native_cleanup_error")
    assert Config(eng.config.home).experimental_native_cleanup
    assert isinstance(eng.cleanup, NativeCleanupRouter) and eng.cleanup.native_active
    with pytest.raises(ProcessLookupError):
        os.kill(old_pid, 0)
    raw = "Please send the revised report tomorrow morning."
    text, _mode, _ms, applied, _reason = await eng._apply_formatting(raw, None, "TextEdit", "Default")
    assert text == raw and applied
    assert eng.cleanup.runtime.calls[-1][1]["mode"] == "default"
    await client.send_json({"cmd": "set_native_cleanup", "enabled": False, "request_id": "disable"})
    reply = await settled(client, "disable")
    assert not reply["native_cleanup_enabled"]
    assert not Config(eng.config.home).experimental_native_cleanup
    assert standard.loaded and not eng.cleanup.runtime.loaded
    client.close()


async def test_failed_native_activation_rolls_back_standard(engine, trial, monkeypatch):
    eng, sock = engine
    standard = await install_standard(eng)
    monkeypatch.setattr(TrialRuntime, "fail", True)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "fail"})
    reply = await settled(client, "fail")
    assert not reply["native_cleanup_enabled"] and reply["native_cleanup_error"]
    assert eng.cleanup is standard and standard.loaded
    assert not Config(eng.config.home).experimental_native_cleanup
    client.close()


@pytest.mark.parametrize("failure", [None, "load", "save", "save-and-close"])
async def test_native_selection_without_previous_owner(engine, trial, monkeypatch, failure):
    eng, sock = engine
    assert eng.cleanup is None
    created = []
    factory = eng._new_cleanup_process

    def candidate(*args, **kwargs):
        owner = factory(*args, **kwargs)
        created.append(owner)
        return owner

    monkeypatch.setattr(eng, "_new_cleanup_process", candidate)
    acquire = AsyncMock(side_effect=AssertionError("native selection must not acquire Qwen"))
    monkeypatch.setattr(eng._downloads, "ensure", acquire)
    monkeypatch.setattr(TrialRuntime, "fail", failure == "load")
    save = eng.config.save

    def checked_save(*, keys=None):
        if failure in {"save", "save-and-close"} and "experimental_native_cleanup" in (keys or ()):
            raise OSError("disk full")
        save(keys=keys)

    monkeypatch.setattr(eng.config, "save", checked_save)
    close = TrialRuntime.aclose
    close_failed = failure == "save-and-close"

    async def checked_close(runtime):
        if close_failed:
            raise RuntimeError("native reap refused")
        await close(runtime)

    monkeypatch.setattr(TrialRuntime, "aclose", checked_close)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "first"})
        reply = await settled(client, "first")
        owner = created[0]
        assert owner.standard.pid is None and not owner.standard.loaded
        acquire.assert_not_awaited()
        assert reply["native_cleanup_enabled"] is (failure is None)
        assert Config(eng.config.home).experimental_native_cleanup is (failure is None)
        if failure == "save-and-close":
            assert eng.cleanup is owner and owner.native_active
            assert not await owner.park_for_backend_switch()
            assert owner.standard.pid is None and not owner.standard.loaded
            replacement = CleanupProcess("fake-standard", worker_command=fixture_command())
            load = AsyncMock(wraps=replacement.load_async)
            monkeypatch.setattr(replacement, "load_async", load)
            monkeypatch.setattr(eng, "_new_cleanup_process", lambda *args, **kwargs: replacement)
            monkeypatch.setattr(eng._downloads, "ensure", AsyncMock(return_value=None))
            monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
            with pytest.raises(RuntimeError, match="previous cleanup model is still busy"):
                await eng._cmd_set_model({"model": "fake-standard", "kind": "cleanup"})
            load.assert_not_awaited()
            assert eng.cleanup is owner and owner.native_active
            assert replacement.pid is None and not replacement.loaded
        elif failure:
            assert eng.cleanup is None and not owner.native_active
        else:
            assert eng.cleanup is owner and owner.loaded
    finally:
        close_failed = False
        for owner in created:
            await owner.aclose()
        client.close()


async def test_trial_busy_and_missing_package_do_not_change_selection(engine, trial, monkeypatch):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    eng._editing = True
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "busy"})
    reply = await settled(client, "busy")
    eng._editing = False
    assert not reply["native_cleanup_enabled"] and "busy" in reply["native_cleanup_error"].lower()
    monkeypatch.setattr(server_mod, "discover_package", lambda home: None)
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "missing"})
    reply = await settled(client, "missing")
    assert not reply["native_cleanup_available"] and not reply["native_cleanup_enabled"]
    assert not Config(eng.config.home).experimental_native_cleanup
    client.close()


async def test_custom_dictation_keeps_selected_native_model_and_no_idle_mining_wake(engine, trial):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "route"})
    await settled(client, "route")
    router = eng.cleanup
    assert await eng._mine_generate("Extract names", "Example source") == "Example source"
    assert router.native_active and not router.standard.loaded
    eng.config.modes["default"].prompt += " Keep each sentence on its own line."
    text, _, _, applied, _ = await eng._apply_formatting("Please preserve this complete sentence exactly.", None, "TextEdit", "Default")
    assert applied and router.native_active and not router.standard.loaded
    assert text == "Please preserve this complete sentence exactly."
    assert "Keep each sentence on its own line." in router.runtime.calls[-1][0]
    client.close()


async def test_native_startup_does_not_acquire_saved_standard_weights(engine, trial, monkeypatch):
    eng, _ = engine
    eng.config.data["experimental_native_cleanup"] = True
    eng.config.save(keys={"experimental_native_cleanup"})
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    eng._downloads = SimpleNamespace(
        ensure=AsyncMock(side_effect=AssertionError("native startup requested Qwen weights")),
        mark_loading=AsyncMock(), mark_ready=AsyncMock(), mark_failed=AsyncMock(), close=AsyncMock(),
        snapshot=lambda: {"downloads": []})
    monkeypatch.setattr(eng, "_publish_downloads", AsyncMock())
    await eng._queue_model_job(eng.config.cleanup_model, "cleanup", origin=server_mod._ModelJobOrigin.startup)
    assert isinstance(eng.cleanup, NativeCleanupRouter) and eng.cleanup.native_loaded
    assert not eng.cleanup.standard.loaded and eng.cleanup.standard.pid is None
    eng._downloads.ensure.assert_not_awaited()


def test_missing_selected_native_package_never_constructs_standard_fallback(home, monkeypatch):
    config = Config(home)
    config.data["experimental_native_cleanup"] = True
    monkeypatch.setattr(server_mod, "discover_package", lambda _: None)
    eng = server_mod.Engine(config)
    try:
        with pytest.raises(RuntimeError, match="native.*unavailable"):
            eng._new_cleanup_process(config.cleanup_model)
    finally:
        eng._stt_executor.shutdown(wait=False)


async def test_chunked_native_results_keep_native_provenance(engine, trial, monkeypatch):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "chunks"})
    await settled(client, "chunks")
    monkeypatch.setattr(server_mod, "CLEANUP_SINGLE_CALL_UNITS", 4)
    session = server_mod.Session("native-chunk-provenance", {})
    raw = "Please preserve this first sentence. Please preserve this second sentence."
    text, _, ms, applied, reason = await eng._apply_formatting(
        raw, None, "TextEdit", "Default", session=session)
    assert applied and reason == "chunked" and not eng.cleanup.standard.loaded
    eng._record_trial_bg(session, raw, text, applied, reason, ms, ms, 1.)
    await asyncio.gather(*eng._archive_tasks)
    recorded = json.loads((eng.config.home / "native-trial-runs.jsonl").read_text())
    assert recorded["backend"] == recorded["attempted_backend"] == "native_lfm3_g"
    client.close()


async def test_native_final_provenance_matches_delivered_text_without_blocking_delivery(engine, trial, monkeypatch):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "metadata"})
    await settled(client, "metadata")
    started, release = threading.Event(), threading.Event()
    record = server_mod.record_trial_run

    def delayed_record(*args, **kwargs):
        started.set()
        assert release.wait(3), "test must release metadata writer"
        record(*args, **kwargs)

    monkeypatch.setattr(server_mod, "record_trial_run", delayed_record)
    try:
        await client.send_json({"cmd": "start", "session": "trial-final", "context": {"mode": "Default"}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "trial-final"})
        final = await client.recv_event("final", timeout=2)
        assert final["cleanup_applied"]
        assert await asyncio.to_thread(started.wait, 1)
        assert not (eng.config.home / "native-trial-runs.jsonl").exists()
        release.set()
        await asyncio.gather(*eng._archive_tasks)
        metadata = json.loads((eng.config.home / "native-trial-runs.jsonl").read_text())
        assert metadata["session_id"] == final["session"]
        assert metadata["backend"] == metadata["attempted_backend"] == "native_lfm3_g"
        assert metadata["raw_sha256"] == hashlib.sha256(final["raw"].encode()).hexdigest()
        assert metadata["final_sha256"] == hashlib.sha256(final["text"].encode()).hexdigest()
        assert metadata["cleanup_ms"] == final["cleanup_ms"]
        assert metadata["cleanup_wall_ms"] == final["cleanup_wall_ms"]
        assert "raw" not in metadata and "final" not in metadata
    finally:
        release.set()
        client.close()


@pytest.mark.parametrize("fail", [False, True])
async def test_standard_model_selection_with_trial_retires_previous_owner_before_loading(engine, trial, monkeypatch, fail):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "before-model"})
    await settled(client, "before-model")
    old = eng.cleanup
    previous_choice = eng.config.cleanup_model
    created = []

    def candidate(model, **kwargs):
        standard = CleanupProcess(model, worker_command=fixture_command())
        router = (NativeCleanupRouter(standard, SimpleNamespace())
                  if kwargs.get("native", True) else standard)
        load = router.load_async

        async def checked_load(*args):
            assert not old.native_active and not old.standard.loaded and old.standard.pid is None
            if fail:
                raise RuntimeError("replacement load refused")
            await load(*args)

        router.load_async = checked_load
        created.append(router)
        return router

    # Exercise the production adoption branch without network or model weights.
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(server_mod.models, "is_cached", lambda model: True)
    eng._downloads = SimpleNamespace(
        ensure=AsyncMock(return_value=DownloadResult(str(eng.config.home), None, "test")),
        mark_loading=AsyncMock(), mark_ready=AsyncMock(), mark_failed=AsyncMock(), close=AsyncMock(),
        snapshot=lambda: {"downloads": []})
    monkeypatch.setattr(eng, "_publish_downloads", AsyncMock())
    monkeypatch.setattr(eng, "_new_cleanup_process", candidate)
    command = {"model": "fake-new-standard", "kind": "cleanup", "request_id": "new-model"}
    if fail:
        with pytest.raises(RuntimeError, match="replacement load refused"):
            await eng._cmd_set_model(command)
        assert eng.cleanup is old and eng.config.cleanup_model == previous_choice
        assert not created[0].loaded and created[0].pid is None
        assert await old.ensure_native_loaded()
    else:
        await eng._cmd_set_model(command)
        assert eng.cleanup is created[0] and created[0].loaded
        assert not isinstance(eng.cleanup, NativeCleanupRouter)
        assert eng.config.cleanup_model == "fake-new-standard"
        assert not old.loaded and old.pid is None
    assert Config(eng.config.home).experimental_native_cleanup is fail
    client.close()
