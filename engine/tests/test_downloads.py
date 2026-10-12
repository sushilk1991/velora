"""Coordinator attempts, authoritative progress and subprocess lifetime."""
import asyncio
import os
import sys

import pytest

from velora_engine import downloads
from velora_engine.downloads import DownloadCoordinator, DownloadError


def set_worker(monkeypatch, code):
    monkeypatch.setattr(DownloadCoordinator, "_command", lambda self, *_: [sys.executable, "-u", "-c", code])


async def wait_state(coordinator, state):
    for _ in range(200):
        snapshot = coordinator.snapshot()
        if snapshot["downloads"] and snapshot["downloads"][0]["state"] == state:
            return snapshot["downloads"][0]
        await asyncio.sleep(.01)
    raise AssertionError(coordinator.snapshot())


def success_code():
    return ('import json; print(json.dumps({"event":"progress","state":"verifying",'
            '"bytes_received":9,"bytes_total":9,"revision":"abc","resume":"none"})); '
            'print(json.dumps({"event":"result","path":"/cache/model","revision":"abc"}))')


async def test_ensure_and_adoption(monkeypatch, tmp_path):
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    first, second = await asyncio.gather(coordinator.ensure("example/model", "stt"), coordinator.ensure("example/model", "stt"))
    assert first == second
    assert first.path == "/cache/model"
    snapshot = coordinator.snapshot()
    assert snapshot["schema"] == 1 and snapshot["snapshot"] is True
    assert snapshot["downloads"][0]["state"] == "verifying"
    await coordinator.mark_loading("example/model", "stt", first.attempt)
    await coordinator.mark_ready("example/model", "stt", first.attempt)
    assert coordinator.snapshot()["downloads"][0]["active_model"] == "example/model"
    await coordinator.close()


async def test_stale_attempt_rejected(monkeypatch, tmp_path):
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    result = await coordinator.ensure("example/model", "stt")
    with pytest.raises(DownloadError) as failure:
        await coordinator.retry("example/model", "stt", "obsolete")
    assert failure.value.code == "stale_download_attempt"
    assert failure.value.snapshot["downloads"][0]["attempt"] == result.attempt
    await coordinator.close()


async def test_heartbeat_byte_stall(monkeypatch, tmp_path):
    pid_file = tmp_path / "pid"
    set_worker(monkeypatch, f'import os,time,json; open({str(pid_file)!r},"w").write(str(os.getpid())); print(json.dumps({{"event":"progress","state":"downloading","bytes_received":0,"bytes_total":9,"revision":"abc","resume":"none"}}),flush=True);\nwhile True:\n print(json.dumps({{"event":"heartbeat"}}), flush=True); time.sleep(.01)')
    monkeypatch.setattr(downloads, "_BYTE_STALL_S", .08)
    monkeypatch.setattr(downloads, "_METADATA_S", .08)
    monkeypatch.setattr(downloads, "_BACKOFF_S", ())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(DownloadError) as failure:
        await coordinator.ensure("example/model", "stt")
    assert failure.value.code == "byte_stall"
    pid = int(pid_file.read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    assert coordinator.snapshot()["downloads"][0]["state"] == "failed"
    await coordinator.close()


async def test_backoff_is_bounded(monkeypatch, tmp_path):
    assert downloads._BACKOFF_S == (2, 5, 15)
    counter = tmp_path / "counter"
    set_worker(monkeypatch, f'import json; open({str(counter)!r},"a").write("x"); print(json.dumps({{"event":"error","error":{{"category":"network","code":"network_error","message":"Connection interrupted.","retryable":True}}}}))')
    monkeypatch.setattr(downloads, "_BACKOFF_S", (.01, .01, .01))
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(DownloadError):
        await coordinator.ensure("example/model", "stt")
    assert counter.read_text() == "xxxx"
    item = coordinator.snapshot()["downloads"][0]
    assert item["retry_index"] == 3
    assert item["retry_allowed"] is True
    await coordinator.close()


async def test_retry_now_coalesces(monkeypatch, tmp_path):
    set_worker(monkeypatch, 'import json; print(json.dumps({"event":"error","error":{"category":"network","code":"network_error","message":"Offline.","retryable":True}}))')
    monkeypatch.setattr(downloads, "_BACKOFF_S", (20,))
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    pending = asyncio.create_task(coordinator.ensure("example/model", "stt"))
    old = await wait_state(coordinator, "retry_wait")
    set_worker(monkeypatch, success_code())
    await coordinator.retry("example/model", "stt", old["attempt"])
    new = coordinator.snapshot()["downloads"][0]
    assert new["attempt"] != old["attempt"]
    # Duplicate acceptance for the new attempt must not replace its job.
    await coordinator.retry("example/model", "stt", new["attempt"])
    assert coordinator.snapshot()["downloads"][0]["attempt"] == new["attempt"]
    result = await coordinator.ensure("example/model", "stt")
    assert result.attempt == new["attempt"]
    await asyncio.gather(pending, return_exceptions=True)
    await coordinator.close()


async def test_close_kills_and_reaps(monkeypatch, tmp_path):
    pid_file = tmp_path / "pid"
    set_worker(monkeypatch, f'import os,time,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); open({str(pid_file)!r},"w").write(str(os.getpid())); time.sleep(60)')
    monkeypatch.setattr(downloads, "_REAP_S", .05)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    pending = asyncio.create_task(coordinator.ensure("example/model", "stt"))
    for _ in range(100):
        if pid_file.exists():
            break
        await asyncio.sleep(.01)
    pid = int(pid_file.read_text())
    await coordinator.close()
    await asyncio.gather(pending, return_exceptions=True)
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


async def test_verification_deadline(monkeypatch, tmp_path):
    set_worker(monkeypatch, 'import json,time; print(json.dumps({"event":"progress","state":"verifying","bytes_received":9,"bytes_total":9,"revision":"abc","resume":"none"}),flush=True); time.sleep(60)')
    monkeypatch.setattr(downloads, "_VERIFY_S", .06)
    monkeypatch.setattr(downloads, "_BACKOFF_S", ())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(DownloadError) as failure:
        await coordinator.ensure("example/model", "stt")
    assert failure.value.code == "verification_timeout"
    await coordinator.close()


async def test_worker_cache_offline(tmp_path, monkeypatch):
    import hashlib
    from velora_engine.download_cache import _Cache, _File, _Manifest

    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    file = _File("weights.bin", 3, hashlib.sha256(b"abc").hexdigest(), "sha256")
    spec = _Manifest("example/model", "a" * 40, (file,))
    cache = _Cache(tmp_path, spec.model)
    with cache._lock():
        cache._save_manifest(spec)
        path = cache._complete(spec, file)
        path.parent.mkdir(parents=True)
        path.write_bytes(b"abc")
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    result = await coordinator.ensure(spec.model, "stt")
    assert result.path == str(path.parent)
    item = coordinator.snapshot()["downloads"][0]
    assert item["bytes_received"] == item["bytes_total"] == 3
    assert item["resume"] == "completed_files"
    assert coordinator._entries[(spec.model, "stt")].process is None
    await coordinator.close()


async def test_metadata_timeout_reaps(monkeypatch, tmp_path):
    set_worker(monkeypatch, 'import time; time.sleep(60)')
    monkeypatch.setattr(downloads, "_METADATA_S", .05)
    monkeypatch.setattr(downloads, "_BACKOFF_S", ())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(DownloadError) as failure:
        await coordinator.ensure("example/model", "stt")
    assert failure.value.code == "metadata_timeout"
    assert coordinator._entries[("example/model", "stt")].process is None
    await coordinator.close()


@pytest.mark.parametrize("category", ["auth", "disk"])
async def test_auth_disk_no_backoff(monkeypatch, tmp_path, category):
    counter = tmp_path / "counter"
    set_worker(monkeypatch, f'import json; open({str(counter)!r},"a").write("x"); print(json.dumps({{"event":"error","error":{{"category":{category!r},"code":"access_or_disk","message":"Fix access or disk.","retryable":False}}}}))')
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(DownloadError):
        await coordinator.ensure("example/model", "stt")
    assert counter.read_text() == "x"
    assert coordinator.snapshot()["downloads"][0]["retry_index"] == 0
    await coordinator.close()


async def test_adoption_keeps_active(monkeypatch, tmp_path):
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    old = await coordinator.ensure("example/old", "stt")
    await coordinator.mark_loading("example/old", "stt", old.attempt)
    await coordinator.mark_ready("example/old", "stt", old.attempt)
    new = await coordinator.ensure("example/new", "stt")
    await coordinator.mark_loading("example/new", "stt", new.attempt)
    await coordinator.mark_failed("example/new", "stt", new.attempt, {
        "category": "loading", "code": "load_failed", "message": "Load failed.", "retryable": False})
    items = coordinator.snapshot()["downloads"]
    assert all(item["active_model"] == "example/old" for item in items)
    assert items[1]["state"] == "failed"
    await coordinator.close()


@pytest.mark.parametrize("kind", ["stt", "cleanup"])
async def test_aux_ready_keeps_primary(monkeypatch, tmp_path, kind):
    # Auxiliary adoption completes B without replacing the serving primary A.
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        primary = await coordinator.ensure("example/primary", kind)
        await coordinator.mark_loading("example/primary", kind, primary.attempt)
        await coordinator.mark_ready("example/primary", kind, primary.attempt)
        auxiliary = await coordinator.ensure("example/auxiliary", kind)
        await coordinator.mark_loading("example/auxiliary", kind, auxiliary.attempt)
        await coordinator.mark_aux_ready("example/auxiliary", kind, auxiliary.attempt)
        snapshot = coordinator.snapshot()
        items = snapshot["downloads"]
        assert [item["state"] for item in items] == ["ready", "ready"]
        assert all(item["active_model"] == "example/primary" for item in items)
        assert items[1]["error"] is None and items[1]["retry_at"] is None
        assert items[1]["retry_allowed"] is False and items[1]["restart_allowed"] is False
        assert coordinator.snapshot() == snapshot
        items[1]["active_model"] = "example/auxiliary"
        assert coordinator.snapshot()["downloads"][1]["active_model"] == "example/primary"

        # Later primary switches update every entry, including a reused primary.
        latest = await coordinator.ensure("example/latest", kind)
        await coordinator.mark_loading("example/latest", kind, latest.attempt)
        await coordinator.mark_ready("example/latest", kind, latest.attempt)
        assert all(item["active_model"] == "example/latest"
                   for item in coordinator.snapshot()["downloads"])
        await coordinator.mark_loading("example/primary", kind, primary.attempt)
        await coordinator.mark_ready("example/primary", kind, primary.attempt)
        await coordinator.ensure("example/next", kind)
        assert all(item["active_model"] == "example/primary"
                   for item in coordinator.snapshot()["downloads"])
    finally:
        await coordinator.close()


@pytest.mark.parametrize("kind", ["stt", "cleanup"])
async def test_aux_fail_keeps_primary(monkeypatch, tmp_path, kind):
    # Failed live adoption leaves A serving and B recoverable, not loading.
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        primary = await coordinator.ensure("example/primary", kind)
        await coordinator.mark_loading("example/primary", kind, primary.attempt)
        await coordinator.mark_ready("example/primary", kind, primary.attempt)
        auxiliary = await coordinator.ensure("example/auxiliary", kind)
        await coordinator.mark_loading("example/auxiliary", kind, auxiliary.attempt)
        error = {"category": "loading", "code": "load_failed",
                 "message": "Load failed.", "retryable": False}
        await coordinator.mark_failed("example/auxiliary", kind, auxiliary.attempt, error)
        items = coordinator.snapshot()["downloads"]
        assert all(item["active_model"] == "example/primary" for item in items)
        assert items[1]["state"] == "failed" and items[1]["error"] == error
        assert items[1]["retry_allowed"] is True
    finally:
        await coordinator.close()


@pytest.mark.parametrize("kind", ["stt", "cleanup"])
async def test_aux_ready_no_primary(monkeypatch, tmp_path, kind):
    # Auxiliary readiness cannot invent a primary that has not been adopted.
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        primary = await coordinator.ensure("example/primary", kind)
        await coordinator.mark_loading("example/primary", kind, primary.attempt)
        auxiliary = await coordinator.ensure("example/auxiliary", kind)
        await coordinator.mark_loading("example/auxiliary", kind, auxiliary.attempt)
        await coordinator.mark_aux_ready("example/auxiliary", kind, auxiliary.attempt)
        snapshot = coordinator.snapshot()
        assert [item["state"] for item in snapshot["downloads"]] == ["loading", "ready"]
        assert all(item["active_model"] is None for item in snapshot["downloads"])
        assert coordinator.snapshot() == snapshot
        await coordinator.mark_ready("example/primary", kind, primary.attempt)
        assert all(item["active_model"] == "example/primary"
                   for item in coordinator.snapshot()["downloads"])
    finally:
        await coordinator.close()


@pytest.mark.parametrize("state", ["queued", "verifying", "failed"])
async def test_aux_requires_loading(monkeypatch, tmp_path, state):
    # Cache acquisition alone, or a failed adoption, cannot report live readiness.
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        if state == "queued":
            attempt = coordinator._new_entry("example/auxiliary", "stt").item["attempt"]
        else:
            result = await coordinator.ensure("example/auxiliary", "stt")
            attempt = result.attempt
            if state == "failed":
                await coordinator.mark_loading("example/auxiliary", "stt", attempt)
                await coordinator.mark_failed("example/auxiliary", "stt", attempt, {
                    "category": "loading", "code": "load_failed",
                    "message": "Load failed.", "retryable": False})
        snapshot = coordinator.snapshot()
        with pytest.raises(DownloadError) as failure:
            await coordinator.mark_aux_ready("example/auxiliary", "stt", attempt)
        assert failure.value.code == "model_not_loading"
        assert coordinator.snapshot() == snapshot
    finally:
        await coordinator.close()


@pytest.mark.parametrize("action", ["loading", "ready", "failed"])
async def test_aux_stale_rejected(monkeypatch, tmp_path, action):
    # Replaced attempts cannot finish or fail the current live auxiliary load.
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        old = await coordinator.ensure("example/auxiliary", "stt")
        error = {"category": "loading", "code": "load_failed",
                 "message": "Load failed.", "retryable": False}
        await coordinator.mark_failed("example/auxiliary", "stt", old.attempt, error)
        await coordinator.retry("example/auxiliary", "stt", old.attempt)
        current = await coordinator.ensure("example/auxiliary", "stt")
        await coordinator.mark_loading("example/auxiliary", "stt", current.attempt)
        snapshot = coordinator.snapshot()
        with pytest.raises(DownloadError) as failure:
            if action == "loading":
                await coordinator.mark_loading("example/auxiliary", "stt", old.attempt)
            elif action == "ready":
                await coordinator.mark_aux_ready("example/auxiliary", "stt", old.attempt)
            else:
                await coordinator.mark_failed("example/auxiliary", "stt", old.attempt, error)
        assert failure.value.code == "stale_download_attempt"
        assert failure.value.snapshot == snapshot
        assert coordinator.snapshot() == snapshot
        await coordinator.mark_aux_ready("example/auxiliary", "stt", current.attempt)
        assert coordinator.snapshot()["downloads"][0]["state"] == "ready"
    finally:
        await coordinator.close()


async def test_kind_conflict_rejected(monkeypatch, tmp_path):
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    await coordinator.ensure("example/model", "stt")
    with pytest.raises(DownloadError) as failure:
        await coordinator.ensure("example/model", "cleanup")
    assert failure.value.code == "invalid_download_kind"
    await coordinator.close()


async def test_cancel_during_spawn(monkeypatch, tmp_path):
    set_worker(monkeypatch, 'import time; time.sleep(60)')
    original = asyncio.create_subprocess_exec
    spawned = asyncio.Event()
    children = []

    async def delayed_spawn(*args, **kwargs):
        process = await original(*args, **kwargs)
        children.append(process)
        spawned.set()
        await asyncio.sleep(.05)
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", delayed_spawn)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    pending = asyncio.create_task(coordinator.ensure("example/model", "stt"))
    await spawned.wait()
    try:
        await coordinator.close()
        await asyncio.gather(pending, return_exceptions=True)
        with pytest.raises(ProcessLookupError):
            os.kill(children[0].pid, 0)
    finally:
        # Keep the red run itself from leaking the child it proves was unowned.
        if children[0].returncode is None:
            children[0].kill()
        await children[0].wait()


async def test_real_worker_lock(tmp_path, monkeypatch):
    import hashlib
    from velora_engine.download_cache import _Cache, _File, _Manifest

    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    file = _File("weights.bin", 3, hashlib.sha256(b"abc").hexdigest(), "sha256")
    spec = _Manifest("example/model", "a" * 40, (file,))
    cache = _Cache(tmp_path, spec.model)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with cache._lock():
        cache._save_manifest(spec)
        path = cache._complete(spec, file)
        path.parent.mkdir(parents=True)
        path.write_bytes(b"abc")
        with pytest.raises(DownloadError) as failure:
            await coordinator.ensure(spec.model, "stt")
        assert failure.value.code == "download_locked"
        assert coordinator._entries[(spec.model, "stt")].process is None
        old = coordinator.snapshot()["downloads"][0]
    await coordinator.retry(spec.model, "stt", old["attempt"])
    assert (await coordinator.ensure(spec.model, "stt")).path == str(path.parent)
    await coordinator.close()


async def test_real_worker_restart(tmp_path, monkeypatch):
    import hashlib
    from velora_engine.download_cache import _Cache, _File, _Manifest

    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    file = _File("weights.bin", 3, hashlib.sha256(b"abc").hexdigest(), "sha256")
    spec = _Manifest("example/model", "a" * 40, (file,))
    cache = _Cache(tmp_path, spec.model)
    with cache._lock():
        cache._save_manifest(spec)
        path = cache._complete(spec, file)
        path.parent.mkdir(parents=True)
        path.write_bytes(b"abc")
        partial = cache._partial(spec, file)
        partial.parent.mkdir(parents=True)
        partial.write_bytes(b"a")
        unknown = partial.parent / "foreign.part"
        unknown.write_bytes(b"keep")
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    result = await coordinator.ensure(spec.model, "stt")
    await coordinator.mark_failed(spec.model, "stt", result.attempt, {
        "category": "loading", "code": "load_failed", "message": "Load failed.", "retryable": False})
    await coordinator.retry(spec.model, "stt", result.attempt, restart=True)
    next_result = await coordinator.ensure(spec.model, "stt")
    assert next_result.attempt != result.attempt
    assert path.read_bytes() == b"abc"
    assert not partial.exists()
    assert unknown.read_bytes() == b"keep"
    assert coordinator._entries[(spec.model, "stt")].process is None
    await coordinator.close()


async def test_url_not_published(tmp_path):
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    with pytest.raises(ValueError):
        await coordinator.ensure("https://cdn.example/model?token=secret", "stt")
    assert coordinator.snapshot()["downloads"] == []
    await coordinator.close()


@pytest.mark.parametrize("resume", ["partial", "file_restarted", "completed_files"])
async def test_resume_survives_verify(monkeypatch, tmp_path, resume):
    code = f'import json; print(json.dumps({{"event":"progress","state":"downloading","bytes_received":9,"bytes_total":9,"revision":"abc","resume":{resume!r}}})); ' + success_code()
    set_worker(monkeypatch, code)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    await coordinator.ensure("example/model", "stt")
    assert coordinator.snapshot()["downloads"][0]["resume"] == resume
    await coordinator.close()


@pytest.mark.parametrize("action", ["close", "fail"])
async def test_stop_during_reap(monkeypatch, tmp_path, action):
    import signal
    from velora_engine.download_cache import _Cache

    # Synchronize with the actual SIGTERM grace interval, not an estimated delay.
    grace = asyncio.Event()
    original_killpg = os.killpg

    def capture_term(pid, sig):
        original_killpg(pid, sig)
        if sig == signal.SIGTERM:
            grace.set()

    monkeypatch.setattr(os, "killpg", capture_term)
    monkeypatch.setattr(downloads, "_BYTE_STALL_S", .05)
    monkeypatch.setattr(downloads, "_REAP_S", .15)
    monkeypatch.setattr(downloads, "_BACKOFF_S", ())
    code = f'''import signal,time,json
from pathlib import Path
from velora_engine.download_cache import _Cache
signal.signal(signal.SIGTERM,signal.SIG_IGN)
with _Cache(Path({str(tmp_path)!r}),"example/model")._lock():
 print(json.dumps({{"event":"progress","state":"downloading","bytes_received":0,"bytes_total":9,"revision":None,"resume":"none"}}),flush=True)
 time.sleep(60)
'''
    set_worker(monkeypatch, code)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    pending = asyncio.create_task(coordinator.ensure("example/model", "stt"))
    await asyncio.wait_for(grace.wait(), 5)
    entry = coordinator._entries[("example/model", "stt")]
    process = entry.process
    try:
        if action == "close":
            await coordinator.close()
        else:
            await coordinator.mark_failed("example/model", "stt", entry.item["attempt"], {
                "category": "loading", "code": "load_failed", "message": "Load failed.", "retryable": False})
        await asyncio.gather(pending, return_exceptions=True)
        with pytest.raises(ProcessLookupError):
            os.kill(process.pid, 0)
        assert entry.process is None
        with _Cache(tmp_path, "example/model")._lock():
            pass
    finally:
        # The expected red run must not leave its proven orphan behind.
        if process.returncode is None:
            process.kill()
        await process.wait()
        await coordinator.close()


async def test_partial_offline_budget(monkeypatch, tmp_path):
    import hashlib
    from velora_engine.download_cache import _Cache, _File, _Manifest

    cache = _Cache(tmp_path, "example/model")
    file = _File("weights.bin", 9, hashlib.sha256(b"abcdefghi").hexdigest(), "sha256")
    spec = _Manifest("example/model", "a" * 40, (file,))
    with cache._lock():
        cache._save_manifest(spec)
        partial = cache._partial(spec, file)
        partial.parent.mkdir(parents=True)
        partial.write_bytes(b"abc")
        cache._save_identity(spec, file, "stable")
    counter = tmp_path / "counter"
    code = f'''import json
from pathlib import Path
from velora_engine import models,download_worker
Path({str(counter)!r}).open("a").write("x")
models._legacy_cached=lambda _: None
def offline(*_):
 raise ConnectionError("offline")
download_worker._resolve_manifest=offline
try:
 download_worker._run("example/model",Path({str(tmp_path)!r}),False,lambda event: print(json.dumps(event),flush=True))
except Exception as error:
 print(json.dumps({{"event":"error","error":download_worker._classify(error)}}),flush=True)
'''
    set_worker(monkeypatch, code)
    monkeypatch.setattr(downloads, "_BACKOFF_S", (.01, .01, .01))
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        with pytest.raises(DownloadError) as failure:
            await coordinator.ensure(spec.model, "stt")
        assert failure.value.error["category"] == "network"
        assert failure.value.error["retryable"] is True
        assert counter.read_text() == "xxxx"
        assert coordinator.snapshot()["downloads"][0]["retry_index"] == 3
        assert partial.read_bytes() == b"abc"
    finally:
        await coordinator.close()


@pytest.mark.parametrize("adoption", ["transfer", "primary", "auxiliary"])
async def test_snapshot_schema_exact(monkeypatch, tmp_path, adoption):
    set_worker(monkeypatch, success_code())
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    result = await coordinator.ensure("example/model", "stt")
    if adoption != "transfer":
        await coordinator.mark_loading("example/model", "stt", result.attempt)
        if adoption == "primary":
            await coordinator.mark_ready("example/model", "stt", result.attempt)
        else:
            await coordinator.mark_aux_ready("example/model", "stt", result.attempt)
    snapshot = coordinator.snapshot()
    assert set(snapshot) == {"schema", "engine_id", "sequence", "snapshot", "downloads"}
    assert snapshot["schema"] == 1 and snapshot["snapshot"] is True
    assert isinstance(snapshot["sequence"], int)
    item = snapshot["downloads"][0]
    assert set(item) == {
        "model", "kind", "revision", "attempt", "state", "bytes_received", "bytes_total",
        "retry_index", "retry_at", "error", "resume", "retry_allowed", "restart_allowed", "active_model"}
    expected_state = "verifying" if adoption == "transfer" else "ready"
    assert item["state"] == expected_state
    assert item["active_model"] == ("example/model" if adoption == "primary" else None)
    assert item["retry_at"] is None and item["error"] is None
    assert item["bytes_received"] == item["bytes_total"] == 9
    item["state"] = "failed"
    assert coordinator.snapshot()["downloads"][0]["state"] == expected_state
    await coordinator.close()
