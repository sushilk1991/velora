"""Shipping regressions found by the independent Codex reviews."""
import json
import threading
from types import SimpleNamespace

import numpy as np
import pytest

from velora_engine import bark, models, download_worker
from velora_engine.download_cache import _Cache, _check_manifest


def test_ane_legacy_import_uses_real_repository(tmp_path, monkeypatch):
    import huggingface_hub
    from huggingface_hub.errors import LocalEntryNotFoundError
    spec = download_worker._resolve_manifest(models.BARK_ANE_MODEL, None)
    _check_manifest(spec)
    calls = []

    def offline(repo, **kwargs):
        calls.append(repo)
        assert repo == models.BARK_MODEL
        raise LocalEntryNotFoundError("fixture cache empty")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", offline)
    download_worker._import_hub(_Cache(tmp_path, spec.model), spec, lambda _: None)
    assert calls == [models.BARK_MODEL]


@pytest.mark.parametrize("coreml", [False, True])
def test_nonempty_neighbors_do_not_hide_missing_speech_piece(coreml):
    audio = np.full(16000, 0.1, dtype=np.float32)
    answers = iter(["first piece", "", "last piece"])
    if coreml:
        model = object.__new__(bark.BarkCoreMLModel)
        model._tr = SimpleNamespace(_piece=lambda _: next(answers),
                                    dec=SimpleNamespace(detok=lambda x: x))
    else:
        model = object.__new__(bark.BarkModel)
        model._decode_piece = lambda _: next(answers)
    model._lock = threading.Lock()
    model.pieces = lambda _: [audio, audio, audio]
    with pytest.raises(bark.BarkError, match="empty"):
        model.decode(audio)


@pytest.mark.parametrize("coreml", [False, True])
def test_empty_digital_silence_piece_is_safe(coreml):
    audio = np.zeros(16000, dtype=np.float32)
    if coreml:
        model = object.__new__(bark.BarkCoreMLModel)
        model._tr = SimpleNamespace(_piece=lambda _: "", dec=SimpleNamespace(detok=lambda x: x))
    else:
        model = object.__new__(bark.BarkModel)
        model._decode_piece = lambda _: ""
    model._lock = threading.Lock()
    model.pieces = lambda _: [audio]
    assert model.decode(audio) == ""


@pytest.mark.parametrize("coreml", [False, True])
def test_long_room_tone_pause_does_not_fail_whole_transcript(coreml):
    speech = np.full(16000, 0.1, dtype=np.float32)
    room = (np.random.default_rng(0).standard_normal(16000 * 75)
            * 10 ** (-55 / 20)).astype(np.float32)
    answers = iter(["first words", "", "last words"])
    if coreml:
        model = object.__new__(bark.BarkCoreMLModel)
        model._tr = SimpleNamespace(_piece=lambda _: next(answers),
                                    dec=SimpleNamespace(detok=lambda x: x))
    else:
        model = object.__new__(bark.BarkModel)
        model._decode_piece = lambda _: next(answers)
    model._lock = threading.Lock()
    model.pieces = lambda _: [speech, room, speech]
    assert model.decode(speech) == "first words last words"


def test_mlx_cache_hashes_are_verified_not_just_sizes(tmp_path):
    identity = {"variant": "fixture"}
    files = {}
    for name in bark._PACKED_FILES:
        path = tmp_path / name
        path.write_bytes(b"original")
        files[name] = {"size": 8, "sha256": bark.bm.sha256_file(path)}
    (tmp_path / bark.MLX_MANIFEST).write_text(json.dumps({"identity": identity, "files": files}))
    assert bark._published_mlx(tmp_path, identity)
    (tmp_path / "model.safetensors").write_bytes(b"modified")
    assert not bark._published_mlx(tmp_path, identity)


def test_coreml_cache_hashes_are_verified_not_just_sizes(tmp_path):
    compiled = tmp_path / "BarkEncoder.mlmodelc"
    compiled.mkdir()
    (compiled / "coremldata.bin").write_bytes(b"original")
    identity = {"variant": "fixture"}
    manifest = {"identity": identity, "files": bark._compiled_files(compiled)}
    (tmp_path / bark.COREML_MANIFEST).write_text(json.dumps(manifest))
    assert bark._published_coreml(tmp_path, identity)
    (compiled / "coremldata.bin").write_bytes(b"modified")
    assert not bark._published_coreml(tmp_path, identity)


def test_coreml_manifest_path_cannot_escape_cache(tmp_path):
    (tmp_path / bark.COREML_MANIFEST).write_text(json.dumps({
        "identity": {}, "files": {"../secrets": {"size": 0, "sha256": "0" * 64}},
    }))
    assert not bark._published_coreml(tmp_path, {})
