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
        self.calls.append((system, json.loads(user), kwargs))
        text = json.loads(user)["transcript"]
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


async def test_standard_routing_for_custom_dictation_and_no_idle_mining_wake(engine, trial):
    eng, sock = engine
    await install_standard(eng)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "set_native_cleanup", "enabled": True, "request_id": "route"})
    await settled(client, "route")
    router = eng.cleanup
    assert await eng._mine_generate("Extract names", "Example source") == ""
    assert router.native_active and not router.standard.loaded
    eng.config.modes["default"].prompt += " Keep each sentence on its own line."
    text, _, _, applied, _ = await eng._apply_formatting("Please preserve this complete sentence exactly.", None, "TextEdit", "Default")
    assert applied and not router.native_active and router.standard.loaded
    assert text == "PLEASE PRESERVE THIS COMPLETE SENTENCE EXACTLY."
    assert not router.runtime.calls
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
        router = NativeCleanupRouter(CleanupProcess(model, worker_command=fixture_command()), SimpleNamespace())
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
        assert eng.cleanup is created[0] and created[0].native_loaded
        assert eng.config.cleanup_model == "fake-new-standard"
        assert not old.loaded and old.pid is None
    assert Config(eng.config.home).experimental_native_cleanup
    client.close()
