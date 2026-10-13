"""Model download behavior at the Hugging Face boundary."""

import hashlib
from pathlib import Path

import huggingface_hub
import pytest
from huggingface_hub.errors import LocalEntryNotFoundError

from velora_engine import download_cache, models


@pytest.fixture(autouse=True)
def isolated_owned_cache(monkeypatch, tmp_path):
    # A user's verified download must not satisfy a mocked Hub cache miss.
    # Each test may still populate this isolated root to exercise owned reuse.
    monkeypatch.setattr(download_cache, "_cache_root", lambda: tmp_path / "owned-cache")


def test_ensure_downloaded_accepts_an_exact_local_snapshot(monkeypatch, tmp_path):
    snapshot = tmp_path / "pinned-snapshot"
    snapshot.mkdir()

    def unexpected_download(**_kwargs):
        raise AssertionError("a pinned local snapshot must not contact the Hub")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", unexpected_download)

    assert models.ensure_downloaded(str(snapshot)) == str(snapshot.resolve())


def _write_valid_q8(monkeypatch, path: Path) -> None:
    payload = b"test q8 artifact"
    path.write_bytes(payload)
    monkeypatch.setattr(
        models, "TRANSCRIBE_CPP_Q8_SHA256", hashlib.sha256(payload).hexdigest())
    models._verified_sha256.cache_clear()


def test_transcribe_cpp_download_fetches_only_the_q8_artifact(monkeypatch, tmp_path):
    downloaded = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, downloaded)
    calls: list[dict] = []

    def fake_download(**kwargs):
        calls.append(kwargs)
        return str(downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    path = models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL)

    assert Path(path) == downloaded
    assert calls == [{
        "repo_id": "handy-computer/whisper-large-v3-turbo-gguf",
        "filename": "whisper-large-v3-turbo-Q8_0.gguf",
        "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
        "local_files_only": True,
    }]


def test_transcribe_cpp_download_goes_online_only_after_local_cache_miss(
    monkeypatch, tmp_path
):
    downloaded = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, downloaded)
    calls: list[dict] = []

    def fake_download(**kwargs):
        calls.append(kwargs)
        if kwargs.get("local_files_only"):
            raise LocalEntryNotFoundError("not cached")
        return str(downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL) == str(downloaded)
    assert calls == [
        {
            "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
            "filename": "whisper-large-v3-turbo-Q8_0.gguf",
            "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
            "local_files_only": True,
        },
        {
            "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
            "filename": "whisper-large-v3-turbo-Q8_0.gguf",
            "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
            "force_download": True,
        },
    ]


def test_transcribe_cpp_cache_probe_checks_only_the_q8_artifact(monkeypatch, tmp_path):
    calls: list[dict] = []
    cached = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, cached)

    def fake_download(**kwargs):
        calls.append(kwargs)
        return str(cached)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is True
    assert calls == [{
        "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
        "filename": "whisper-large-v3-turbo-Q8_0.gguf",
        "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
        "local_files_only": True,
    }]


def test_transcribe_cpp_cache_probe_reports_missing_artifact(monkeypatch):
    def fake_download(**_kwargs):
        raise LocalEntryNotFoundError("not cached")

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is False


def test_transcribe_cpp_cache_probe_rejects_corrupt_artifact(monkeypatch, tmp_path):
    cached = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    cached.write_bytes(b"corrupt")
    monkeypatch.setattr(
        huggingface_hub, "hf_hub_download", lambda **_kwargs: str(cached))
    monkeypatch.setattr(models, "TRANSCRIBE_CPP_Q8_SHA256", "0" * 64)
    models._verified_sha256.cache_clear()

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is False


def test_transcribe_cpp_replaces_a_corrupt_cached_artifact(monkeypatch, tmp_path):
    cached = tmp_path / "cached.gguf"
    cached.write_bytes(b"corrupt")
    downloaded = tmp_path / "downloaded.gguf"
    _write_valid_q8(monkeypatch, downloaded)
    calls: list[dict] = []

    def fake_download(**kwargs):
        calls.append(kwargs)
        return str(cached if kwargs.get("local_files_only") else downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL) == str(downloaded)
    assert calls[-1]["force_download"] is True


def test_transcribe_cpp_rejects_a_corrupt_download(monkeypatch, tmp_path):
    downloaded = tmp_path / "corrupt.gguf"
    downloaded.write_bytes(b"corrupt")
    monkeypatch.setattr(models, "TRANSCRIBE_CPP_Q8_SHA256", "0" * 64)
    models._verified_sha256.cache_clear()

    def fake_download(**kwargs):
        if kwargs.get("local_files_only"):
            raise LocalEntryNotFoundError("not cached")
        return str(downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    with pytest.raises(OSError, match="failed SHA-256 verification"):
        models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL)


def test_snapshot_model_download_is_offline_first(monkeypatch, tmp_path):
    model_id = "mlx-community/whisper-large-v3-turbo"
    _legacy_config(tmp_path)
    _legacy_weights(tmp_path / "weights.safetensors")
    calls: list[dict] = []

    def fake_snapshot_download(**kwargs):
        calls.append(kwargs)
        if kwargs.get("local_files_only"):
            raise LocalEntryNotFoundError("not cached")
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", fake_snapshot_download)

    assert models.ensure_downloaded(model_id) == str(tmp_path)
    assert calls == [
        {"repo_id": model_id, "local_files_only": True},
        {"repo_id": model_id},
    ]


def test_model_helpers_cover_tiers_sizes_and_probe_failures(monkeypatch):
    assert models.recommended_cleanup_model(8).endswith("Qwen3.5-2B-MLX-4bit")
    assert models.recommended_cleanup_model(16).endswith("Qwen3.5-4B-MLX-4bit")
    assert models.recommended_cleanup_model(32).endswith("Qwen3.5-4B-MLX-8bit")
    assert models.expected_bytes("missing/model") is None
    # Registry sizes are decimal GB, the unit Hub byte counts come in.
    assert models.expected_bytes(models.TRANSCRIBE_CPP_Q8_MODEL) == int(0.9 * 10**9)
    assert models.expected_bytes("mlx-community/parakeet-tdt-0.6b-v2") == int(2.5 * 10**9)

    def unavailable_cache(**_kwargs):
        raise RuntimeError("cache unavailable")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", unavailable_cache)
    assert models.is_cached("mlx-community/whisper-large-v3-turbo") is False


# ---- superseded-model upgrade path -------------------------------------------


def test_superseded_map_points_at_real_registry_entries():
    for old_id, new_id in models.SUPERSEDED_CLEANUP_MODELS.items():
        info = models.lookup(new_id)
        assert info is not None, f"{new_id} is not in the registry"
        assert info.kind == "cleanup"
        # An old id must be gone from the picker, or users could re-select the
        # model the upgrade just deleted from disk.
        assert models.lookup(old_id) is None
        # No chains: a replacement that is itself superseded would need two
        # passes, but the migration marker only lets it run once.
        assert new_id not in models.SUPERSEDED_CLEANUP_MODELS


def test_every_tier_default_is_a_current_registry_entry():
    for _min_gb, model_id in models._CLEANUP_TIERS:
        assert models.lookup(model_id) is not None
        assert model_id not in models.SUPERSEDED_CLEANUP_MODELS


def test_remove_from_cache_refuses_models_outside_the_superseded_map(tmp_path,
                                                                    monkeypatch):
    import huggingface_hub.constants as hub_constants

    monkeypatch.setattr(hub_constants, "HF_HUB_CACHE", str(tmp_path))
    for protected in ("mlx-community/Qwen3.5-4B-MLX-8bit",
                      "mlx-community/whisper-large-v3-turbo",
                      "../../etc"):
        victim = tmp_path / f"models--{protected.replace('/', '--')}"
        victim.mkdir(parents=True, exist_ok=True)
        (victim / "weights.bin").write_bytes(b"x" * 32)
        with pytest.raises(ValueError):
            models.remove_from_cache(protected)
        assert (victim / "weights.bin").exists()


def test_remove_from_cache_deletes_a_superseded_model_and_reports_bytes(
        tmp_path, monkeypatch):
    import huggingface_hub.constants as hub_constants

    monkeypatch.setattr(hub_constants, "HF_HUB_CACHE", str(tmp_path))
    old_id = next(iter(models.SUPERSEDED_CLEANUP_MODELS))
    repo = tmp_path / f"models--{old_id.replace('/', '--')}"
    (repo / "blobs").mkdir(parents=True)
    (repo / "blobs" / "weights.bin").write_bytes(b"x" * 4096)

    assert models.remove_from_cache(old_id) == 4096
    assert not repo.exists()
    # Idempotent: a second pass (or a fresh install) reclaims nothing quietly.
    assert models.remove_from_cache(old_id) == 0


# Settings › Models shows each entry's name as the row title and its
# description as the caption, verbatim. A missing name made the app fall back
# to the whole description sentence ("Default — fast & multilingual (…)") as
# the title; dashes in that copy read as machine-written.
_MAX_MODEL_NAME_CHARS = 32
_DASHES = ("—", "–")


def test_every_model_has_a_short_display_name():
    for info in models.REGISTRY:
        assert info.name, info.id
        assert len(info.name) <= _MAX_MODEL_NAME_CHARS, info.id


def test_model_copy_has_no_em_or_en_dashes():
    for info in models.REGISTRY:
        for text in (info.name, info.description):
            assert not any(dash in text for dash in _DASHES), (info.id, text)


def test_registry_payload_carries_the_display_name():
    payload = models.registry_payload()

    assert [entry["name"] for entry in payload] == [m.name for m in models.REGISTRY]


def _legacy_weights(path, payload=b"x"):
    import json
    import struct

    header = json.dumps({"weight": {"dtype": "U8", "shape": [len(payload)],
                                      "data_offsets": [0, len(payload)]}}).encode()
    path.write_bytes(struct.pack("<Q", len(header)) + header + payload)


@pytest.mark.parametrize("model_id", ["mlx-community/whisper-large-v3-turbo", "custom/whisper-tiny"])
def test_legacy_whisper_offline(tmp_path, monkeypatch, model_id):
    import mlx.core as mx
    from mlx.utils import tree_flatten
    from mlx_whisper.whisper import Whisper, ModelDimensions
    from mlx_whisper.load_models import load_model
    import json

    _legacy_config(tmp_path)
    dimensions = ModelDimensions(**json.loads((tmp_path / "config.json").read_text()))
    tiny_model = Whisper(dimensions)
    mx.save_safetensors(str(tmp_path / "weights.safetensors"), dict(tree_flatten(tiny_model.parameters())))
    calls = []

    def offline(**kwargs):
        calls.append(kwargs)
        assert kwargs.get("local_files_only"), "usable legacy cache went online"
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", offline)
    assert models.is_cached(model_id)
    assert models.ensure_downloaded(model_id) == str(tmp_path)
    assert len(calls) == 2
    # A real backend load proves this legacy fixture is usable, not just nonempty.
    assert load_model(str(tmp_path)).dims == dimensions


@pytest.mark.parametrize("damage", ["missing", "corrupt", "digest"])
def test_legacy_shard_integrity(tmp_path, monkeypatch, damage):
    import json

    (tmp_path / "config.json").write_text('{"model_type":"qwen"}')
    (tmp_path / "tokenizer_config.json").write_text('{}')
    (tmp_path / "tokenizer.json").write_text('{"model":{}}')
    (tmp_path / "model.safetensors.index.json").write_text(json.dumps({
        "weight_map": {"first": "model-00001.safetensors", "second": "model-00002.safetensors"}}))
    _legacy_weights(tmp_path / "model-00001.safetensors")
    second = tmp_path / "model-00002.safetensors"
    if damage == "corrupt":
        second.write_bytes(b"broken")
    if damage == "digest":
        blob = tmp_path / ("0" * 64)
        _legacy_weights(blob)
        second.symlink_to(blob)
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: str(tmp_path))
    assert not models.is_cached("mlx-community/Qwen3.5-2B-MLX-4bit")


def test_cache_bytes_unique(tmp_path, monkeypatch):
    monkeypatch.setattr(models, "_repo_cache_dir", lambda _: tmp_path)
    blob = tmp_path / "blob"
    blob.write_bytes(b"12345")
    (tmp_path / "snapshot").symlink_to(blob)
    assert models.cached_bytes("example/model") == 5


def test_legacy_config_incomplete(tmp_path, monkeypatch):
    (tmp_path / "config.json").write_text('{}')
    _legacy_weights(tmp_path / "weights.safetensors")
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: str(tmp_path))
    assert not models.is_cached("mlx-community/whisper-large-v3-turbo")


def _legacy_config(path):
    import json

    values = {"n_mels": 2, "n_audio_ctx": 2, "n_audio_state": 4,
              "n_audio_head": 2, "n_audio_layer": 1, "n_vocab": 10,
              "n_text_ctx": 2, "n_text_state": 4, "n_text_head": 2, "n_text_layer": 1}
    (path / "config.json").write_text(json.dumps(values))


@pytest.mark.parametrize("backend", ["whisper", "parakeet"])
def test_custom_speech_offline(tmp_path, monkeypatch, backend):
    import json

    model_id = "custom/whisper-model" if backend == "whisper" else "custom/speech-model"
    if backend == "whisper":
        _legacy_config(tmp_path)
        _legacy_weights(tmp_path / "weights.safetensors")
    else:
        (tmp_path / "config.json").write_text(json.dumps({
            "target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel",
            "encoder": {"feat_in": 2}, "preprocessor": {"features": 2}}))
        _legacy_weights(tmp_path / "model.safetensors")

    def offline(**kwargs):
        assert kwargs.get("local_files_only"), "custom installed model went online"
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", offline)
    assert models.is_cached(model_id)
    assert models.ensure_downloaded(model_id) == str(tmp_path)
    assert models._legacy_cached(model_id) == str(tmp_path)


@pytest.mark.parametrize("backend", ["whisper", "parakeet"])
def test_custom_speech_corrupt(tmp_path, monkeypatch, backend):
    import json

    model_id = "custom/whisper-model" if backend == "whisper" else "custom/speech-model"
    if backend == "whisper":
        _legacy_config(tmp_path)
        (tmp_path / "weights.safetensors").write_bytes(b"invalid")
    else:
        (tmp_path / "config.json").write_text(json.dumps({
            "target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel",
            "encoder": {"feat_in": 2}, "preprocessor": {"features": 2}}))
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: str(tmp_path))
    assert not models.is_cached(model_id)


def test_registered_kind_retained(tmp_path, monkeypatch):
    _legacy_config(tmp_path)
    _legacy_weights(tmp_path / "weights.safetensors")
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: str(tmp_path))
    assert not models.is_cached("mlx-community/Qwen3.5-2B-MLX-4bit")
