"""Owned download manifests, integrity and restart containment."""
import hashlib
import json

import pytest

from velora_engine.download_cache import _Cache, _File, _Manifest


def manifest(payload=b"weights", revision="a" * 40):
    return _Manifest("example/model", revision, (
        _File("weights.bin", len(payload), hashlib.sha256(payload).hexdigest(), "sha256"),
    ))


def test_offline_cache_integrity(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    spec = manifest()
    cache._save_manifest(spec)
    path = cache._complete(spec, spec.files[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"weights")
    assert cache._cached() == (str(path.parent), spec)
    path.write_bytes(b"corrupt")
    assert cache._cached() is None
    path.unlink()
    assert cache._cached() is None


def test_missing_shard(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    spec = manifest()
    shard = _File("second.bin", 1, hashlib.sha256(b"x").hexdigest(), "sha256")
    spec = _Manifest(spec.model, spec.revision, (*spec.files, shard))
    cache._save_manifest(spec)
    path = cache._complete(spec, spec.files[0])
    path.parent.mkdir(parents=True)
    path.write_bytes(b"weights")
    assert cache._cached() is None


def test_restart_owned_only(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    other = _Cache(tmp_path, "other/model")
    spec = manifest()
    cache._save_manifest(spec)
    for owner in (cache, other):
        part = owner._partial(spec, spec.files[0])
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(b"wei")
    complete = cache._complete(spec, spec.files[0])
    complete.parent.mkdir(parents=True)
    complete.write_bytes(b"weights")
    cache._restart()
    assert not cache._partial(spec, spec.files[0]).exists()
    assert other._partial(spec, spec.files[0]).exists()
    assert complete.read_bytes() == b"weights"


def test_restart_symlink_escape(tmp_path):
    cache = _Cache(tmp_path / "cache", "example/model")
    outside = tmp_path / "outside"
    outside.mkdir()
    victim = outside / "keep.part"
    victim.write_bytes(b"keep")
    cache._base.mkdir(parents=True)
    (cache._base / "partials").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        cache._restart()
    assert victim.read_bytes() == b"keep"


def test_manifest_paths_identity(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    cache._save_manifest(manifest())
    with pytest.raises(ValueError, match="immutable"):
        cache._save_manifest(manifest(b"changed"))
    with pytest.raises(ValueError):
        cache._save_manifest(_Manifest("example/model", "../escape", manifest().files))
    with pytest.raises(ValueError):
        cache._save_manifest(_Manifest("example/model", "b" * 40, (
            _File("../escape", 1, "0" * 64, "sha256"),)))


def test_lock_excludes_owner(tmp_path):
    first = _Cache(tmp_path, "example/model")
    second = _Cache(tmp_path, "example/model")
    with first._lock():
        with pytest.raises(BlockingIOError):
            with second._lock():
                pass
    with second._lock():
        pass


def test_manifest_has_no_secrets(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    cache._save_manifest(manifest())
    text = (cache._base / "manifests" / ("a" * 40 + ".json")).read_text()
    assert set(json.loads(text)) == {"model", "revision", "files"}
    assert "http" not in text


def test_q8_manifest_keeps_pin(tmp_path):
    from velora_engine import models

    cache = _Cache(tmp_path, models.TRANSCRIBE_CPP_Q8_MODEL)
    spec = _Manifest(models.TRANSCRIBE_CPP_Q8_MODEL, models.TRANSCRIBE_CPP_Q8_REVISION, (
        _File(models._SINGLE_FILE_MODELS[models.TRANSCRIBE_CPP_Q8_MODEL], 3, "0" * 64, "sha256"),))
    with pytest.raises(ValueError, match="pinned"):
        cache._save_manifest(spec)


def test_restart_keeps_unknowns(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    spec = manifest()
    cache._save_manifest(spec)
    part = cache._partial(spec, spec.files[0])
    part.parent.mkdir(parents=True)
    part.write_bytes(b"partial")
    unknown = part.parent / "someone-elses.part"
    unknown.write_bytes(b"not owned")
    cache._restart()
    assert unknown.read_bytes() == b"not owned"
    assert not part.exists()


def test_manifest_absent_invalid(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    assert cache._manifest() is None
    cache._base.mkdir(parents=True)
    (cache._base / "current.json").write_text("broken json")
    with pytest.raises(ValueError, match="manifest"):
        cache._manifest()


def test_corruption_vs_incomplete(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    spec = manifest()
    cache._save_manifest(spec)
    assert not cache._has_corruption(spec)
    part = cache._partial(spec, spec.files[0])
    part.parent.mkdir(parents=True)
    part.write_bytes(b"wei")
    assert not cache._has_corruption(spec)
    part.write_bytes(b"invalid")
    assert cache._has_corruption(spec)
    part.unlink()
    complete = cache._complete(spec, spec.files[0])
    complete.parent.mkdir(parents=True)
    complete.write_bytes(b"invalid")
    assert cache._has_corruption(spec)


def test_quarantine_rejects_links(tmp_path):
    from velora_engine.download_cache import _ManifestError

    cache = _Cache(tmp_path / "cache", "example/model")
    outside = tmp_path / "outside.json"
    outside.write_text("untouched")
    with cache._lock():
        current = cache._base / "current.json"
        current.symlink_to(outside)
        with pytest.raises(ValueError, match="symlink"):
            cache._quarantine(_ManifestError((current,)))
    assert outside.read_text() == "untouched"
    assert current.is_symlink()


def test_quarantine_scope(tmp_path):
    from velora_engine.download_cache import _ManifestError

    cache = _Cache(tmp_path, "example/model")
    with cache._lock():
        foreign = cache._base / "foreign.json"
        foreign.write_text("untouched")
        with pytest.raises(ValueError, match="unowned"):
            cache._quarantine(_ManifestError((foreign,)))
    assert foreign.read_text() == "untouched"


def test_valid_manifest_unchanged(tmp_path):
    cache = _Cache(tmp_path, "example/model")
    spec = manifest()
    with cache._lock():
        cache._save_manifest(spec)
        path = cache._base / "manifests" / (spec.revision + ".json")
        original = path.read_bytes()
        with pytest.raises(ValueError, match="immutable"):
            cache._save_manifest(manifest(b"different"))
        assert path.read_bytes() == original
        assert not (cache._base / "quarantine").exists()
