"""Real HTTP body/range fixtures at the owned transfer boundary."""
import errno
import hashlib
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from velora_engine.download_cache import _Cache, _File, _Manifest
from velora_engine.download_worker import _transfer_file, _classify

_PAYLOAD = b"abcdefghi"


@pytest.fixture
def transport():
    state = {"mode": "valid", "requests": []}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            state["requests"].append(dict(self.headers))
            mode = state["mode"]
            offset = int(self.headers.get("Range", "bytes=0-")[6:-1])
            if mode in ("auth", "416"):
                self.send_response(HTTPStatus.UNAUTHORIZED if mode == "auth" else HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.end_headers()
                return
            partial = offset and mode != "ignored"
            self.send_response(HTTPStatus.PARTIAL_CONTENT if partial else HTTPStatus.OK)
            self.send_header("ETag", '"changed"' if mode == "changed" else '"stable"')
            body = _PAYLOAD[offset:] if partial else _PAYLOAD
            if partial:
                start = offset + 1 if mode == "invalid" else offset
                self.send_header("Content-Range", f"bytes {start}-8/9")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if mode == "interrupted":
                self.wfile.write(body[:3])
                self.wfile.flush()
                self.close_connection = True
                return
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}/weights", state
    server.shutdown()
    thread.join()
    server.server_close()


def setup_file(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    file = _File("weights.bin", len(_PAYLOAD), hashlib.sha256(_PAYLOAD).hexdigest(), "sha256")
    spec = _Manifest("example/model", "a" * 40, (file,))
    cache._save_manifest(spec)
    return cache, spec, file


def test_body_resume_relaunch(tmp_path, transport):
    url, state = transport
    cache, spec, file = setup_file(tmp_path)
    events = []
    state["mode"] = "interrupted"
    with pytest.raises(Exception):
        _transfer_file(cache, spec, file, url, "stable", events.append)
    assert cache._partial(spec, file).read_bytes() == _PAYLOAD[:3]
    state["mode"] = "valid"
    # New cache instance represents an engine/worker relaunch.
    cache = _Cache(tmp_path, "example/model")
    _transfer_file(cache, spec, file, url, "stable", events.append)
    assert cache._complete(spec, file).read_bytes() == _PAYLOAD
    assert state["requests"][-1]["Range"] == "bytes=3-"
    assert state["requests"][-1]["If-Range"] == '"stable"'
    assert events[-1]["bytes_received"] == len(_PAYLOAD)
    assert any(event["resume"] == "partial" for event in events)


@pytest.mark.parametrize("mode", ["ignored", "invalid", "changed", "416"])
def test_unsafe_range_restart(tmp_path, transport, mode):
    url, state = transport
    cache, spec, file = setup_file(tmp_path)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(_PAYLOAD[:3])
    cache._save_identity(spec, file, "stable")
    state["mode"] = mode
    events = []
    if mode == "416":
        with pytest.raises(Exception):
            _transfer_file(cache, spec, file, url, "stable", events.append)
        assert not part.exists() or part.stat().st_size == 0
    else:
        _transfer_file(cache, spec, file, url, "stable", events.append)
        assert cache._complete(spec, file).read_bytes() == _PAYLOAD
    assert any(event["resume"] == "file_restarted" for event in events)
    assert max(event["bytes_received"] for event in events) <= len(_PAYLOAD)


def test_identity_restart(tmp_path, transport):
    url, state = transport
    cache, spec, file = setup_file(tmp_path)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(b"bad")
    cache._save_identity(spec, file, "old-identity")
    events = []
    _transfer_file(cache, spec, file, url, "stable", events.append)
    assert "Range" not in state["requests"][0]
    assert any(event["resume"] == "file_restarted" for event in events)


def test_auth_disk_no_retry(tmp_path, transport):
    url, state = transport
    cache, spec, file = setup_file(tmp_path)
    state["mode"] = "auth"
    with pytest.raises(Exception) as failure:
        _transfer_file(cache, spec, file, url, "stable", lambda _: None)
    assert _classify(failure.value)["category"] == "auth"
    assert _classify(failure.value)["retryable"] is False
    disk = _classify(OSError(errno.ENOSPC, "disk full"))
    assert disk["category"] == "disk"
    assert disk["retryable"] is False


def test_corrupt_not_promoted(tmp_path, transport):
    url, _ = transport
    cache, spec, file = setup_file(tmp_path)
    bad = _File(file.name, file.size, "0" * 64, "sha256")
    with pytest.raises(ValueError, match="verification"):
        _transfer_file(cache, spec, bad, url, "stable", lambda _: None)
    assert not cache._complete(spec, bad).exists()


def test_disk_write_preserves(tmp_path, transport, monkeypatch):
    from pathlib import Path

    url, _ = transport
    cache, spec, file = setup_file(tmp_path)
    original = Path.open

    def disk_full(path, mode="r", *args, **kwargs):
        if path.suffix == ".part" and mode in ("wb", "ab"):
            raise OSError(errno.ENOSPC, "full")
        return original(path, mode, *args, **kwargs)

    monkeypatch.setattr(Path, "open", disk_full)
    with pytest.raises(OSError) as failure:
        _transfer_file(cache, spec, file, url, "stable", lambda _: None)
    assert _classify(failure.value)["category"] == "disk"
    assert not cache._complete(spec, file).exists()
    assert cache._manifest() == spec


def test_socket_stall_reaped(tmp_path, monkeypatch):
    # A real socket stays open after valid headers; the child cannot make bytes.
    # Parent watchdog must kill it even though its HTTP read remains alive.
    import asyncio
    import os
    import sys
    import time
    from velora_engine import downloads
    from velora_engine.downloads import DownloadCoordinator, DownloadError

    class StallHandler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.flush()
            time.sleep(1)

    server = ThreadingHTTPServer(("127.0.0.1", 0), StallHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    pid_file = tmp_path / "pid"
    code = f'''import os,json
from pathlib import Path
from velora_engine.download_cache import _Cache,_File,_Manifest
from velora_engine.download_worker import _transfer_file
Path({str(pid_file)!r}).write_text(str(os.getpid()))
cache=_Cache(Path({str(tmp_path)!r}),"example/model")
f=_File("weights.bin",9,{hashlib.sha256(_PAYLOAD).hexdigest()!r},"sha256")
s=_Manifest("example/model",{"a" * 40!r},(f,))
with cache._lock():
 cache._save_manifest(s)
 _transfer_file(cache,s,f,"http://127.0.0.1:{server.server_port}/weights","stable",lambda event: print(json.dumps(event),flush=True))
'''
    monkeypatch.setattr(DownloadCoordinator, "_command", lambda self, *_: [sys.executable, "-u", "-c", code])
    monkeypatch.setattr(downloads, "_BYTE_STALL_S", .1)
    monkeypatch.setattr(downloads, "_BACKOFF_S", ())

    async def check():
        coordinator = DownloadCoordinator(cache_root=tmp_path)
        try:
            with pytest.raises(DownloadError) as failure:
                await coordinator.ensure("example/model", "stt")
            assert failure.value.code == "byte_stall"
            with pytest.raises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
        finally:
            await coordinator.close()

    try:
        asyncio.run(check())
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def test_offline_corrupt_error(tmp_path, monkeypatch):
    import huggingface_hub
    from velora_engine import download_worker

    legacy = tmp_path / "legacy"
    legacy.mkdir()
    (legacy / "config.json").write_text('{}')
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: str(legacy))

    def unavailable(*_):
        raise ConnectionError("offline")

    monkeypatch.setattr(download_worker, "_resolve_manifest", unavailable)
    with pytest.raises(Exception) as failure:
        download_worker._run("mlx-community/whisper-large-v3-turbo", tmp_path / "owned", False, lambda _: None)
    assert _classify(failure.value)["code"] == "cache_integrity"


def test_error_hides_url():
    from urllib.error import URLError

    error = URLError("https://cdn.example/file?token=secret")
    assert "secret" not in str(_classify(error))
    assert "https" not in str(_classify(error))


def test_full_partial_promoted(tmp_path, transport):
    url, state = transport
    cache, spec, file = setup_file(tmp_path)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(_PAYLOAD)
    cache._save_identity(spec, file, "stable")
    state["mode"] = "416"
    _transfer_file(cache, spec, file, url, "stable", lambda _: None)
    assert cache._complete(spec, file).read_bytes() == _PAYLOAD
    assert not state["requests"]


def test_partial_claim_deferred(tmp_path, transport, monkeypatch):
    import urllib.request

    url, _ = transport
    cache, spec, file = setup_file(tmp_path)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(_PAYLOAD[:3])
    cache._save_identity(spec, file, "stable")
    events = []
    original = urllib.request.urlopen

    def check_before_get(*args, **kwargs):
        assert all(event["resume"] != "partial" for event in events)
        return original(*args, **kwargs)

    monkeypatch.setattr(urllib.request, "urlopen", check_before_get)
    _transfer_file(cache, spec, file, url, "stable", events.append)
    assert any(event["resume"] == "partial" for event in events)


def test_partial_not_completed(tmp_path, monkeypatch):
    from velora_engine import models, download_worker

    cache, spec, file = setup_file(tmp_path)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(_PAYLOAD[:3])
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)

    def offline(*_):
        raise ConnectionError("offline")

    monkeypatch.setattr(download_worker, "_resolve_manifest", offline)
    events = []
    with pytest.raises(ConnectionError) as failure:
        download_worker._run(spec.model, tmp_path, False, events.append)
    assert _classify(failure.value)["retryable"] is True
    assert all(event.get("resume") != "completed_files" for event in events)


@pytest.mark.parametrize("document", ["current", "manifest"])
@pytest.mark.parametrize("restart", [False, True])
def test_manifest_repair_scoped(tmp_path, monkeypatch, document, restart):
    from velora_engine import models, download_worker

    cache, spec, file = setup_file(tmp_path)
    complete = cache._complete(spec, file)
    complete.parent.mkdir(parents=True)
    complete.write_bytes(_PAYLOAD)
    part = cache._partial(spec, file)
    part.parent.mkdir(parents=True)
    part.write_bytes(_PAYLOAD[:3])
    foreign = part.parent / "foreign.part"
    foreign.write_bytes(b"keep")
    path = cache._base / "current.json"
    if document == "manifest":
        path = cache._base / "manifests" / (spec.revision + ".json")
    path.write_text("broken json")
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)

    def offline(*_):
        raise ConnectionError("offline")

    monkeypatch.setattr(download_worker, "_resolve_manifest", offline)
    with pytest.raises(Exception) as failure:
        download_worker._run(spec.model, tmp_path, restart, lambda _: None)
    error = _classify(failure.value)
    assert error["code"] == "manifest_invalid"
    assert error["category"] == "verification"
    assert "retry" in error["message"].lower()
    assert complete.read_bytes() == _PAYLOAD
    assert part.read_bytes() == _PAYLOAD[:3]
    assert foreign.read_bytes() == b"keep"
    quarantined = list((cache._base / "quarantine").glob("*.json"))
    assert quarantined
    assert any(path.read_text() == "broken json" for path in quarantined)
    # A fresh worker/cache instance must retain the precise repair error offline.
    with pytest.raises(Exception) as again:
        download_worker._run(spec.model, tmp_path, restart, lambda _: None)
    assert _classify(again.value)["code"] == "manifest_invalid"
    assert len(list((cache._base / "quarantine").glob("*.json"))) == len(quarantined)
    monkeypatch.setattr(download_worker, "_resolve_manifest", lambda *_: spec)
    monkeypatch.setattr(download_worker, "_import_hub", lambda *_: None)
    result, revision = download_worker._run(spec.model, tmp_path, restart, lambda _: None)
    assert result == str(complete.parent) and revision == spec.revision
    assert cache._manifest() == spec
    assert not (cache._base / "repair.json").exists()
    assert complete.read_bytes() == _PAYLOAD
    assert foreign.read_bytes() == b"keep"
    assert part.exists() is not restart


def test_orphan_manifest_repair(tmp_path, monkeypatch):
    from velora_engine import models, download_worker

    cache, spec, file = setup_file(tmp_path)
    complete = cache._complete(spec, file)
    complete.parent.mkdir(parents=True)
    complete.write_bytes(_PAYLOAD)
    (cache._base / "current.json").unlink()
    path = cache._base / "manifests" / (spec.revision + ".json")
    path.write_text("broken json")
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)
    monkeypatch.setattr(download_worker, "_resolve_manifest", lambda *_: spec)
    monkeypatch.setattr(download_worker, "_import_hub", lambda *_: None)
    result, _ = download_worker._run(spec.model, tmp_path, False, lambda _: None)
    assert result == str(complete.parent)
    assert list((cache._base / "quarantine").glob("*.json"))
    assert complete.read_bytes() == _PAYLOAD


def test_owned_corrupt_offline(tmp_path, monkeypatch):
    from velora_engine import models, download_worker

    cache, spec, file = setup_file(tmp_path)
    complete = cache._complete(spec, file)
    complete.parent.mkdir(parents=True)
    complete.write_bytes(b"corrupt!")
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)

    def offline(*_):
        raise ConnectionError("offline")

    monkeypatch.setattr(download_worker, "_resolve_manifest", offline)
    with pytest.raises(ValueError) as failure:
        download_worker._run(spec.model, tmp_path, False, lambda _: None)
    error = _classify(failure.value)
    assert error["code"] == "cache_integrity"
    assert error["retryable"] is False


def test_legacy_revision_nullable(tmp_path, monkeypatch):
    from velora_engine import models, download_worker

    legacy = tmp_path / "legacy"
    legacy.mkdir()
    (legacy / "weights.bin").write_bytes(b"abc")
    monkeypatch.setattr(models, "_legacy_cached", lambda _: str(legacy))
    events = []
    result, revision = download_worker._run("custom/whisper-model", tmp_path / "owned", False, events.append)
    assert result == str(legacy)
    assert revision is None
    progress = next(event for event in events if event["event"] == "progress")
    assert progress["revision"] is None
    assert progress["bytes_received"] == 3
    assert progress["bytes_total"] is None
