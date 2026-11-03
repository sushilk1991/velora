"""Deletion is engine-coordinated, owner-scoped and excludes acquisition."""
import asyncio
import hashlib
import json
import threading

import pytest

from velora_engine import model_storage, models
from velora_engine.download_cache import _Cache, _File, _Manifest
from velora_engine.downloads import DownloadCoordinator, DownloadError

MODEL = "mlx-community/parakeet-tdt-0.6b-v2"


def fixture_cache(root):
    cache = _Cache(root, MODEL)
    payload = b"owned weights"
    file = _File("model.safetensors", len(payload), hashlib.sha256(payload).hexdigest(), "sha256")
    spec = _Manifest(MODEL, "a" * 40, (file,))
    with cache._lock():
        cache._save_manifest(spec)
        path = cache._complete(spec, file)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
    return cache, path


def test_remove_never_touches_shared_hub_or_user_files(tmp_path):
    root = tmp_path / "hub" / ".velora-downloads"
    cache, owned = fixture_cache(root)
    shared = tmp_path / "hub" / "models--mlx-community--parakeet-tdt-0.6b-v2"
    shared.mkdir()
    original = shared / "user-original.bin"
    original.write_bytes(b"keep")
    home = tmp_path / "velora"
    derived = home / "quant-cache" / "matching-derived"
    derived.mkdir(parents=True)
    (derived / "velora-quant.json").write_text(json.dumps({
        "format": "velora-quant", "model_id": MODEL}))
    (derived / "model.safetensors").write_bytes(b"derived")
    assert model_storage.remove_owned(MODEL, root, home) > 0
    assert not owned.exists() and not derived.exists()
    assert original.read_bytes() == b"keep"
    assert (cache._base / "owner.lock").exists()
    assert (home / "quant-cache" / ".build.lock").exists()


def test_remove_refuses_writer_lock_without_mutating(tmp_path):
    cache, owned = fixture_cache(tmp_path / "cache")
    with cache._lock():
        with pytest.raises(BlockingIOError):
            model_storage.remove_owned(MODEL, tmp_path / "cache", tmp_path / "home")
    assert owned.exists()


def test_remove_rejects_paths_and_symlink_escape(tmp_path):
    with pytest.raises(ValueError):
        model_storage.remove_owned(str(tmp_path / "user-model.bin"), tmp_path / "cache")
    home = tmp_path / "home"
    home.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (home / "quant-cache").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError):
        model_storage.remove_owned(MODEL, tmp_path / "cache", home)
    assert outside.exists()


async def test_coordinator_fences_ensure_until_cancelled_remove_really_finishes(tmp_path, monkeypatch):
    started, finish = threading.Event(), threading.Event()

    def remove(*_args):
        started.set()
        assert finish.wait(5)
        return 10

    monkeypatch.setattr(model_storage, "remove_owned", remove)
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    task = asyncio.create_task(coordinator.remove(MODEL))
    try:
        for _ in range(100):
            if started.is_set():
                break
            await asyncio.sleep(0.01)
        assert started.is_set()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        with pytest.raises(DownloadError) as error:
            await coordinator.ensure(MODEL, "stt")
        assert error.value.code == "model_removing"
    finally:
        finish.set()
        await coordinator.close()
    assert not coordinator._removals


async def test_coordinator_refuses_active_model(tmp_path):
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    coordinator._active["stt"] = MODEL
    try:
        with pytest.raises(DownloadError) as error:
            await coordinator.remove(MODEL)
        assert error.value.code == "model_in_use"
    finally:
        await coordinator.close()
