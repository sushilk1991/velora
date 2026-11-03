"""Regression coverage for catalog file selectors through the whole pipeline."""
import hashlib
from types import SimpleNamespace

import huggingface_hub
import pytest

from velora_engine import download_worker as worker, models
from velora_engine.download_cache import _Cache, _File, _Manifest, _check_manifest
from velora_engine.downloads import DownloadCoordinator

IDS = (models.WHISPER_CPP_BASE_EN, models.WHISPER_CPP_SMALL_EN)


@pytest.mark.parametrize("model", IDS)
async def test_coordinator_accepts_registered_file_selector(model, tmp_path, monkeypatch):
    import sys
    monkeypatch.setattr(DownloadCoordinator, "_command", lambda *args: [
        sys.executable, "-c",
        'import json; print(json.dumps({"event":"result","path":"/cache/model","revision":"' +
        models.WHISPER_CPP_REVISION + '"}))',
    ])
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        result = await coordinator.ensure(model, "stt")
        assert result.path == "/cache/model"
        assert coordinator.snapshot()["downloads"][0]["model"] == model
    finally:
        await coordinator.close()


async def test_unregistered_colon_selector_still_rejected(tmp_path):
    coordinator = DownloadCoordinator(cache_root=tmp_path)
    try:
        with pytest.raises(ValueError):
            await coordinator.ensure("example/repo:unregistered", "stt")
    finally:
        await coordinator.close()


@pytest.mark.parametrize("model", IDS)
def test_worker_maps_repo_at_every_hub_boundary(model, tmp_path, monkeypatch):
    payload = b"fixture weights for " + model.encode()
    digest = hashlib.sha256(payload).hexdigest()
    revision = models.WHISPER_CPP_REVISION
    filename = models._SINGLE_FILE_MODELS[model]
    monkeypatch.setitem(models._SINGLE_FILE_SHA256, model, digest)
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)
    calls = []

    class API:
        def model_info(self, repo, **kwargs):
            assert repo == models.WHISPER_CPP_REPO
            assert kwargs["revision"] == revision
            calls.append("manifest")
            return SimpleNamespace(sha=revision, siblings=[SimpleNamespace(
                rfilename=filename, size=len(payload),
                lfs=SimpleNamespace(sha256=digest), blob_id=None)])

    monkeypatch.setattr(huggingface_hub, "HfApi", API)

    def hub_url(repo, name, **kwargs):
        assert repo == models.WHISPER_CPP_REPO and name == filename
        calls.append("url")
        return "https://example.test/model"

    monkeypatch.setattr(huggingface_hub, "hf_hub_url", hub_url)
    monkeypatch.setattr(huggingface_hub, "get_hf_file_metadata", lambda *a, **k:
                        SimpleNamespace(commit_hash=revision, size=len(payload),
                                        location="https://example.test/weights", etag=digest))
    from huggingface_hub.errors import LocalEntryNotFoundError

    def legacy_import(repo, name, **kwargs):
        assert repo == models.WHISPER_CPP_REPO and name == filename
        calls.append("legacy-import")
        raise LocalEntryNotFoundError("fixture cache empty")

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", legacy_import)

    def transfer(cache, spec, file, url, etag, emit):
        assert spec.model == model and spec.revision == revision
        path = cache._complete(spec, file)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)

    monkeypatch.setattr(worker, "_transfer_file", transfer)
    path, commit = worker._run(model, tmp_path, False, lambda _: None)
    from pathlib import Path
    assert Path(path).read_bytes() == payload
    assert commit == revision
    assert calls == ["manifest", "legacy-import", "url"]
    # Offline relaunch uses the verified owned manifest and no Hub APIs.
    calls.clear()
    assert worker._run(model, tmp_path, False, lambda _: None) == (path, commit)
    assert calls == []


@pytest.mark.parametrize("model", IDS)
def test_legacy_probe_maps_repo_and_verifies_pin(model, tmp_path, monkeypatch):
    path = tmp_path / "model.bin"
    path.write_bytes(b"fixture")
    monkeypatch.setitem(models._SINGLE_FILE_SHA256, model, hashlib.sha256(b"fixture").hexdigest())

    def cached(**kwargs):
        assert kwargs["repo_id"] == models.WHISPER_CPP_REPO
        assert kwargs["local_files_only"] is True
        return str(path)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", cached)
    assert models._legacy_cached(model) == str(path)
    path.write_bytes(b"modified")
    with pytest.raises(ValueError):
        models._legacy_cached(model)


@pytest.mark.parametrize("model", IDS)
def test_owned_manifest_cannot_weaken_shipped_pin(model):
    file = _File(models._SINGLE_FILE_MODELS[model], 9,
                 models._SINGLE_FILE_SHA256[model], "sha256")
    valid = _Manifest(model, models._SINGLE_FILE_REVISIONS[model], (file,))
    _check_manifest(valid)
    for bad in (
        _Manifest(model, "0" * 40, (file,)),
        _Manifest(model, valid.revision, (_File(file.name, 9, "0" * 64, "sha256"),)),
        _Manifest(model, valid.revision, (file, file)),
    ):
        with pytest.raises(ValueError):
            _check_manifest(bad)
