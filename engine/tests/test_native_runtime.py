from __future__ import annotations

import asyncio
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

import pytest

from velora_engine import native_runtime as native


FIXTURE = Path(__file__).parent / "fixtures" / "fake_native_supervisor.py"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def alive(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                            capture_output=True, text=True, check=False)
    return result.returncode == 0 and not result.stdout.strip().startswith("Z")


@pytest.fixture
def package(tmp_path, monkeypatch):
    home = tmp_path / "home"
    root = home / "experimental" / "lfm3-native-v1"
    root.mkdir(parents=True)
    model = root / "model.gguf"
    model.write_bytes(b"fake model")
    binary = root / "velora-cleanup-native"
    binary.write_bytes(b"#!/bin/sh\nexit 0\n")
    binary.chmod(0o700)
    supervisor = root / "supervise.py"
    supervisor.write_bytes(FIXTURE.read_bytes())
    monkeypatch.setattr(native, "MODEL_SHA256", digest(model))
    monkeypatch.setattr(native, "BINARY_SHA256", digest(binary))
    monkeypatch.setattr(native, "SUPERVISOR_SHA256", digest(supervisor))
    manifest = {
        "schema": 1, "checkpoint": "G", "model_sha256": native.MODEL_SHA256,
        "binary_sha256": native.BINARY_SHA256, "supervisor_sha256": native.SUPERVISOR_SHA256,
        "model_bytes": model.stat().st_size,
    }
    (root / "manifest.json").write_text(json.dumps(manifest))
    monkeypatch.setenv("VELORA_HOME", str(home))
    trace = tmp_path / "trace.jsonl"
    monkeypatch.setenv("VELORA_FAKE_NATIVE_TRACE", str(trace))
    monkeypatch.setattr(native, "LOAD_TIMEOUT_S", 1.0)
    monkeypatch.setattr(native, "HARD_GRACE_S", .1)
    monkeypatch.setattr(native, "RESPONSE_GRACE_S", .1)
    monkeypatch.setattr(native, "CANCEL_GRACE_S", .15)
    monkeypatch.setattr(native, "SHUTDOWN_GRACE_S", .15)
    monkeypatch.setattr(native, "TERMINATE_GRACE_S", .5)
    monkeypatch.setattr(native, "KILL_GRACE_S", .5)
    yield home, native.NativePackage(root), trace
    # A failed test must not leave its real fixture descendants running.
    for row in rows(trace):
        for key in ("worker", "supervisor"):
            if key in row and alive(row[key]):
                try:
                    os.kill(row[key], signal.SIGKILL)
                except ProcessLookupError:
                    pass


def test_pins_match_approved_contract():
    assert native.MODEL_SHA256 == "ec3710cf3bc12c0fbdfcf24587e5f87a2bf197f4c3129d390052af67e3d1a666"
    assert native.BINARY_SHA256 == "6b5ab148f586b881d27577f5a61a5dafa551d1a24edb140213c29321ec044a3c"
    assert native.SUPERVISOR_SHA256 == "fd06b212cff24db00b855265dfae20b403623a15a379ef1e72eec39e106e0b02"
    assert native.LLAMA_COMMIT == "4b77dee0524c64b8471869232e2958bd9589607d"


def test_discovery_and_small_artifact_verification(package, monkeypatch):
    home, expected, _ = package
    found = native.discover_package()
    assert found == expected == native.discover_package(home)
    assert found.model_path == found.root / "model.gguf"
    assert found.binary_path == found.root / "velora-cleanup-native"
    assert found.supervisor_path == found.root / "supervise.py"
    original = native._sha256
    hashed = []

    def record(path):
        hashed.append(path)
        return original(path)

    monkeypatch.setattr(native, "_sha256", record)
    found.verify()
    assert set(hashed) == {found.binary_path, found.supervisor_path}
    native.discover_package(home)
    assert len(hashed) == 2  # status discovery never hashes any artifacts


@pytest.mark.parametrize("change", [
    {"schema": True}, {"checkpoint": "F"}, {"model_sha256": "0" * 64},
    {"binary_sha256": "0" * 64}, {"supervisor_sha256": "0" * 64},
    {"model_bytes": 1}, {"model_bytes": True},
])
def test_discovery_rejects_identity_and_size_mismatch(package, change):
    home, item, _ = package
    path = item.root / "manifest.json"
    value = json.loads(path.read_text())
    value.update(change)
    path.write_text(json.dumps(value))
    assert native.discover_package(home) is None
    with pytest.raises(ValueError):
        item.verify()


@pytest.mark.parametrize("filename", ["manifest.json", "model.gguf", "velora-cleanup-native", "supervise.py"])
def test_discovery_rejects_missing_symlink_and_nonregular_files(package, filename):
    home, item, _ = package
    path = item.root / filename
    content = path.read_bytes()
    path.unlink()
    assert native.discover_package(home) is None
    target = home / "outside"
    target.write_bytes(content)
    path.symlink_to(target)
    assert native.discover_package(home) is None
    path.unlink()
    path.mkdir()
    assert native.discover_package(home) is None


@pytest.mark.parametrize("filename", ["velora-cleanup-native", "supervise.py"])
def test_verify_rejects_modified_worker_or_supervisor(package, filename):
    _, item, _ = package
    path = item.root / filename
    path.write_bytes(path.read_bytes() + b"\n# tampered\n")
    with pytest.raises(ValueError, match="SHA256"):
        item.verify()


async def test_load_generate_close_and_reload_own_both_processes(package):
    _, item, trace = package
    runtime = native.NativeRuntime(item)
    try:
        ready = await runtime.load()
        assert runtime.loaded and runtime.ready == ready and not runtime.unhealthy
        first = rows(trace)[0]
        assert runtime.pid == first["worker"]
        assert "--copy-draft" in first["args"] and "--prefix-cache" in first["args"]
        assert first["args"][first["args"].index("--draft-max") + 1] == "8"
        for _ in range(2):
            result = await runtime.generate("Edit faithfully.", "hello", max_tokens=64, deadline_ms=500)
            assert result["status"] == "eos" and result["text"] == "Ready."
            assert result["prompt_tokens"] == [1, 2] and result["output_tokens"] == [3]
            assert result["partial_text"] == ""
        await runtime.aclose()
        assert not runtime.loaded and runtime.pid is None and not runtime.ready
        assert not alive(first["worker"]) and not alive(first["supervisor"])
        await runtime.aclose()
        await runtime.load()
        assert runtime.pid != first["worker"]
    finally:
        await runtime.aclose()
    for row in rows(trace):
        for key in ("worker", "supervisor"):
            if key in row:
                assert not alive(row[key])


@pytest.mark.parametrize("field,value", [
    ("event", "other"), ("protocol", True), ("model_sha256", "wrong"),
    ("llama_commit", "wrong"), ("architecture", "qwen3"), ("context_tokens", 8192),
    ("copy_draft", False), ("copy_draft_max", 3), ("prefix_reuse", False),
    ("prefill_batch_tokens", 256), ("max_output_tokens", 2048),
    ("batch_tokens", 256), ("ubatch_tokens", 256), ("swa_full", False),
    ("max_rss_mb", 32768),
    ("student_prefix_cache", True), ("recurrent_rollback", True),
    ("research_long_context", True), ("bounded_swa", True),
    ("sampling", "backend_greedy"), ("backend_token_only", True),
    ("trace_runtime", True), ("pid", True), ("pid", os.getpid()),
])
async def test_ready_mismatch_retires_both_processes(package, monkeypatch, field, value):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_READY", json.dumps({field: value}))
    runtime = native.NativeRuntime(item)
    try:
        with pytest.raises(RuntimeError):
            await runtime.load()
    finally:
        await runtime.aclose()
    assert runtime.unhealthy and not runtime.loaded
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


@pytest.mark.parametrize("status", ["length", "deadline", "context_limit"])
async def test_failed_text_is_never_accepted_and_context_recovers(package, status):
    _, item, _ = package
    runtime = native.NativeRuntime(item)
    try:
        failed = await runtime.generate("Edit.", status, max_tokens=64, deadline_ms=500)
        assert failed["status"] == status and failed["text"] == failed["partial_text"] == ""
        assert failed["output_tokens"] == [3]
        assert (await runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=500))["status"] == "eos"
    finally:
        await runtime.aclose()


@pytest.mark.parametrize("mode", ["eof", "malformed", "oversize", "truncated", "wrong_id", "invalid_id", "invalid_event", "hang"])
async def test_transport_failures_are_bounded_and_retire_every_child(package, monkeypatch, mode):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", mode)
    runtime = native.NativeRuntime(item)
    await runtime.load()
    started = time.monotonic()
    try:
        result = await asyncio.wait_for(runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=50), 3)
    finally:
        await runtime.aclose()
    assert result["status"] == "native_transport_failure" and result["text"] == ""
    assert runtime.unhealthy and not runtime.loaded and time.monotonic() - started < 2
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


@pytest.mark.parametrize("mode", ["", "cancel_race", "ignore_cancel"])
async def test_cooperative_cancel_never_returns_racing_eos(package, monkeypatch, mode):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", mode or "hang")
    runtime = native.NativeRuntime(item)
    cancel = asyncio.Event()
    try:
        await runtime.load()
        task = asyncio.create_task(runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=5000, cancel_event=cancel))
        await asyncio.sleep(.03)
        cancel.set()
        result = await asyncio.wait_for(task, 2)
        assert result["text"] == result.get("partial_text", "") == ""
        assert result["status"] in {"cancelled", "native_transport_failure"}
        assert any(row.get("op") == "cancel" for row in rows(trace))
        assert runtime.loaded is (mode != "ignore_cancel")
    finally:
        await runtime.aclose()


async def test_task_cancel_reaps_processes_and_leaves_engine_loop_responsive(package, monkeypatch):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", "hang")
    runtime = native.NativeRuntime(item)
    await runtime.load()
    task = asyncio.create_task(runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=5000))
    await asyncio.sleep(.03)
    task.cancel()
    ticks = 0
    while not task.done():
        ticks += 1
        await asyncio.sleep(.005)
    with pytest.raises(asyncio.CancelledError):
        await task
    assert ticks > 0 and not runtime.loaded
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


@pytest.mark.parametrize("cancel_load", [False, True])
@pytest.mark.parametrize("mode", ["startup_hang", "startup_stubborn"])
async def test_startup_timeout_or_cancel_reaps_worker_before_ready(package, monkeypatch, cancel_load, mode):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", mode)
    monkeypatch.setattr(native, "LOAD_TIMEOUT_S", .12)
    runtime = native.NativeRuntime(item)
    cancel = asyncio.Event()
    task = asyncio.create_task(runtime.load(cancel_event=cancel))
    if cancel_load:
        await asyncio.sleep(.05)
        cancel.set()
    with pytest.raises(asyncio.CancelledError if cancel_load else TimeoutError):
        await asyncio.wait_for(task, 3)
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


async def test_close_interrupts_stuck_request_and_reaps_before_reload(package, monkeypatch):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", "stubborn")
    runtime = native.NativeRuntime(item)
    await runtime.load()
    task = asyncio.create_task(runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=5000))
    await asyncio.sleep(.03)
    await asyncio.wait_for(runtime.aclose(), 2)
    await asyncio.wait_for(task, 2)
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])
    monkeypatch.delenv("VELORA_FAKE_NATIVE_MODE")
    await runtime.load()
    await runtime.aclose()


async def test_close_waits_for_spawn_handle_before_proving_exit(package, monkeypatch):
    _, item, trace = package
    runtime = native.NativeRuntime(item)
    spawned = asyncio.Event()
    release = asyncio.Event()
    original = asyncio.create_subprocess_exec

    async def delayed_spawn(*args, **kwargs):
        process = await original(*args, **kwargs)
        spawned.set()
        await release.wait()
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", delayed_spawn)
    loading = asyncio.create_task(runtime.load())
    await asyncio.wait_for(spawned.wait(), 1)
    closing = asyncio.create_task(runtime.aclose())
    try:
        await asyncio.sleep(.03)
        assert not closing.done(), "close must acquire and reap an in-progress spawn"
    finally:
        release.set()
        await asyncio.gather(loading, closing, return_exceptions=True)
        await runtime.aclose()
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


async def test_cancel_result_before_ack_does_not_poison_next_request(package, monkeypatch):
    _, item, _ = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", "cancel_result_first")
    runtime = native.NativeRuntime(item)
    cancel = asyncio.Event()
    try:
        await runtime.load()
        task = asyncio.create_task(runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=5000, cancel_event=cancel))
        await asyncio.sleep(.03)
        cancel.set()
        result = await task
        assert result["status"] == "cancelled" and result["text"] == ""
        next_result = await runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=500)
        assert next_result["status"] == "eos"
    finally:
        await runtime.aclose()


async def test_cancelling_close_waits_for_exit_before_propagating(package, monkeypatch):
    _, item, trace = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", "stubborn")
    runtime = native.NativeRuntime(item)
    await runtime.load()
    closing = asyncio.create_task(runtime.aclose())
    await asyncio.sleep(.03)
    closing.cancel()
    with pytest.raises(asyncio.CancelledError):
        await closing
    assert not runtime.loaded and runtime.pid is None
    for key in ("worker", "supervisor"):
        assert not alive(rows(trace)[0][key])


async def test_native_request_error_drops_text_and_preserves_warm_worker(package, monkeypatch):
    _, item, _ = package
    monkeypatch.setenv("VELORA_FAKE_NATIVE_MODE", "error")
    runtime = native.NativeRuntime(item)
    try:
        result = await runtime.generate("Edit.", "hello", max_tokens=64, deadline_ms=500)
        assert result["event"] == "error" and result["error"] == "context_limit"
        assert result["text"] == result["partial_text"] == ""
        assert runtime.loaded and not runtime.unhealthy
    finally:
        await runtime.aclose()


@pytest.mark.parametrize("kwargs", [
    {"max_tokens": 513, "deadline_ms": 500},
    {"max_tokens": True, "deadline_ms": 500},
    {"max_tokens": 64, "deadline_ms": 120001},
    {"max_tokens": 64, "deadline_ms": True},
    {"max_tokens": 64, "deadline_ms": 500, "draft_text": "x" * 65537},
])
async def test_invalid_request_is_rejected_before_starting_process(package, kwargs):
    _, item, trace = package
    runtime = native.NativeRuntime(item)
    with pytest.raises(ValueError):
        await runtime.generate("Edit.", "hello", **kwargs)
    assert not trace.exists()
