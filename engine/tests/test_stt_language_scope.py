"""Language-scope STT defaults, RAM tiers, and derived quantized caches.

The quantized-cache publish protocol (build → validate → atomic rename
behind a lock) is tested with the real MLX round-trip where MLX is
importable; model downloads are never touched.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from velora_engine import quant_cache
from velora_engine.config import Config
from velora_engine.models import (
    LANGUAGE_SCOPES,
    WHISPER_CPP_BASE_EN,
    WHISPER_CPP_SMALL_EN,
    lookup,
    parakeet_quant_bits,
    recommended_stt_model,
)


def _mlx_importable() -> bool:
    try:
        import mlx.core  # noqa: F401

        return True
    except Exception:  # noqa: BLE001
        return False

# ---- language-scope defaults -----------------------------------------------


def test_recommended_stt_english_is_parakeet_at_every_ram():
    for ram in (4, 8, 16, 36, 128):
        assert recommended_stt_model("english", ram) == "mlx-community/parakeet-tdt-0.6b-v2"


def test_recommended_stt_multilingual_tiers_by_ram():
    assert recommended_stt_model("multilingual", 36) == "mlx-community/whisper-large-v3-turbo"
    assert recommended_stt_model("multilingual", 10) == "mlx-community/whisper-large-v3-turbo"
    # Below 10 GB the Q4 build halves the download for the same languages.
    assert recommended_stt_model("multilingual", 8) == "mlx-community/whisper-large-v3-turbo-q4"
    assert recommended_stt_model("multilingual", 4) == "mlx-community/whisper-large-v3-turbo-q4"


def test_recommended_stt_unknown_scope_falls_back_to_multilingual():
    assert recommended_stt_model("martian", 32) == "mlx-community/whisper-large-v3-turbo"
    assert recommended_stt_model("", 32) == "mlx-community/whisper-large-v3-turbo"


def test_language_scopes_constant():
    assert LANGUAGE_SCOPES == ("multilingual", "english")


def test_english_whisper_registry_entries_exist():
    base = lookup(WHISPER_CPP_BASE_EN)
    small = lookup(WHISPER_CPP_SMALL_EN)
    assert base is not None and base.backend == "transcribe-cpp" and base.kind == "stt"
    assert small is not None and small.backend == "transcribe-cpp" and small.kind == "stt"
    # The single-file ids are not Hub repo ids; the download layer must know.
    from velora_engine import models as models_mod

    assert models_mod._SINGLE_FILE_REPOS[WHISPER_CPP_BASE_EN] == "ggerganov/whisper.cpp"
    assert models_mod._SINGLE_FILE_REVISIONS[WHISPER_CPP_BASE_EN] == (
        models_mod.WHISPER_CPP_REVISION)
    assert models_mod._SINGLE_FILE_SHA256[WHISPER_CPP_SMALL_EN] == (
        models_mod.WHISPER_CPP_SMALL_EN_SHA256)


def test_single_file_valid_rejects_wrong_sha(tmp_path: Path):
    from velora_engine import models as models_mod

    bad = tmp_path / "ggml-base.en.bin"
    bad.write_bytes(b"not whisper")
    assert not models_mod._single_file_is_valid(WHISPER_CPP_BASE_EN, str(bad))
    # Ids without a pinned digest stay permissive (legacy behavior).
    assert models_mod._single_file_is_valid("some/unknown-model", str(bad))


# ---- config integration ----------------------------------------------------


def test_config_defaults_to_multilingual(home):
    cfg = Config()
    assert cfg.language_scope == "multilingual"
    assert cfg.data["language_scope"] == "multilingual"


def test_config_language_scope_validates(home):
    cfg = Config()
    cfg.data["language_scope"] = "english"
    assert cfg.language_scope == "english"
    cfg.data["language_scope"] = "  MULTILINGUAL "
    assert cfg.language_scope == "multilingual"
    cfg.data["language_scope"] = "nonsense"
    assert cfg.language_scope == "multilingual"


def test_first_config_write_adopts_scope_fitted_stt(home, monkeypatch):
    """A standalone engine with no app-projected choice picks the scope's
    recommendation once; a config that already carries stt_model is never
    rewritten."""
    from velora_engine import models as models_mod

    monkeypatch.setattr(models_mod, "physical_ram_gb", lambda: 8.0)

    cfg = Config()  # first-run: no config.json exists
    on_disk = json.loads(cfg.config_path.read_text())
    assert on_disk["stt_model"] == "mlx-community/whisper-large-v3-turbo-q4"
    assert on_disk["language_scope"] == "multilingual"

    # An explicit choice survives a reload untouched.
    cfg.data["language_scope"] = "english"
    cfg.save(keys={"language_scope"})
    cfg.data["stt_model"] = "mlx-community/parakeet-tdt-0.6b-v2"
    cfg.save(keys={"stt_model"})
    reloaded = Config()
    assert reloaded.stt_model == "mlx-community/parakeet-tdt-0.6b-v2"
    assert reloaded.language_scope == "english"


def test_reload_config_rejects_unknown_scope(home):
    cfg = Config()
    cfg.data["language_scope"] = "nonsense"
    assert cfg.language_scope == "multilingual"


# ---- quantization tier -----------------------------------------------------


def test_parakeet_quant_bits_by_ram():
    assert parakeet_quant_bits(36) is None
    assert parakeet_quant_bits(24) is None
    assert parakeet_quant_bits(16) == 8
    assert parakeet_quant_bits(12) == 8
    assert parakeet_quant_bits(8) == 4
    assert parakeet_quant_bits(0.5) == 4


# ---- quantized cache protocol ----------------------------------------------


def _fake_model_dir(tmp_path: Path) -> Path:
    source = tmp_path / "source"
    source.mkdir()
    (source / "config.json").write_text('{"target": "parakeet"}')
    (source / "model.safetensors").write_bytes(b"fp16-weights")
    return source


def test_cache_path_is_sanitized_and_tiered(tmp_path: Path):
    path = quant_cache.cache_path("mlx-community/parakeet-tdt-0.6b-v2", 8, home=tmp_path)
    assert path.parent.name == "quant-cache"
    assert "mlx-community--parakeet-tdt-0.6b-v2--int8--v1" == path.name
    # Ids that contain filesystem-hostile characters stay inside the root.
    weird = quant_cache.cache_path("a/b c:parakeet", 4, home=tmp_path)
    assert weird.parent.parent == tmp_path


def test_manifest_matches_requires_complete_exact_cache(tmp_path: Path):
    from velora_engine import config as config_mod

    source = _fake_model_dir(tmp_path)
    cache = quant_cache.cache_path("m", 8, home=tmp_path)
    assert not quant_cache.manifest_matches(cache, "m", source, 8)

    cache.mkdir(parents=True)
    (cache / "config.json").write_text("{}")
    (cache / "model.safetensors").write_bytes(b"q")
    # Missing manifest → invalid.
    assert not quant_cache.manifest_matches(cache, "m", source, 8)
    (cache / quant_cache.MANIFEST_NAME).write_text(json.dumps(
        quant_cache.expected_manifest("m", source, 8)))
    assert quant_cache.manifest_matches(cache, "m", source, 8)
    # A different source snapshot (upstream model updated) invalidates.
    other = tmp_path / "source2"
    other.mkdir()
    assert not quant_cache.manifest_matches(cache, "m", other, 8)
    # A different bits tier has its own directory.
    assert quant_cache.cache_path("m", 4, home=tmp_path) != cache


def test_ensure_quantized_builds_validates_and_publishes(tmp_path, monkeypatch):
    calls = {"build": 0, "validate": 0}

    def fake_build(source_dir, destination, bits):
        calls["build"] += 1
        (destination / "config.json").write_text("{}")
        (destination / "model.safetensors").write_bytes(b"quantized")

    def fake_load(directory):
        calls["validate"] += 1
        assert (directory / "model.safetensors").exists()
        return object()

    monkeypatch.setattr(quant_cache, "_build_quantized", fake_build)
    monkeypatch.setattr(quant_cache, "load_quantized_parakeet", fake_load)
    monkeypatch.setattr(quant_cache, "velora_home", lambda: tmp_path)

    source = _fake_model_dir(tmp_path)
    cache = quant_cache.ensure_quantized(source, "m", 8)
    assert cache == quant_cache.cache_path("m", 8, home=tmp_path)
    assert calls == {"build": 1, "validate": 1}
    assert json.loads((cache / quant_cache.MANIFEST_NAME).read_text()) == (
        quant_cache.expected_manifest("m", source, 8))

    # A second call is a no-op: the published manifest matches.
    quant_cache.ensure_quantized(source, "m", 8)
    assert calls == {"build": 1, "validate": 1}

    # A stale manifest (upstream moved) triggers one rebuild, atomically:
    # the old published directory is replaced only after the new build
    # validates, and a failed build leaves the old cache in place.
    source2 = tmp_path / "source2"
    source2.mkdir()
    (source2 / "config.json").write_text('{"target": "v2"}')
    (source2 / "model.safetensors").write_bytes(b"fp16-v2")

    def failing_build(source_dir, destination, bits):
        (destination / "config.json").write_text("{}")
        (destination / "model.safetensors").write_bytes(b"half-built")
        raise OSError("disk full mid-build")

    monkeypatch.setattr(quant_cache, "_build_quantized", failing_build)
    with pytest.raises(OSError):
        quant_cache.ensure_quantized(source2, "m", 8)
    # The old cache still serves, no temp directories linger.
    assert quant_cache.manifest_matches(cache, "m", source, 8)
    assert not list(cache.parent.glob(".*tmp-*"))


def test_ensure_quantized_rejects_unknown_bits(tmp_path):
    with pytest.raises(ValueError):
        quant_cache.ensure_quantized(tmp_path, "m", 5)


def test_reload_validation_failure_blocks_publish(tmp_path, monkeypatch):
    def fake_build(source_dir, destination, bits):
        (destination / "config.json").write_text("{}")
        (destination / "model.safetensors").write_bytes(b"quantized")

    def failing_load(directory):
        raise ValueError("corrupt weights")

    monkeypatch.setattr(quant_cache, "_build_quantized", fake_build)
    monkeypatch.setattr(quant_cache, "load_quantized_parakeet", failing_load)
    monkeypatch.setattr(quant_cache, "velora_home", lambda: tmp_path)

    source = _fake_model_dir(tmp_path)
    with pytest.raises(OSError):
        quant_cache.ensure_quantized(source, "m", 8)
    assert not quant_cache.cache_path("m", 8, home=tmp_path).exists()


@pytest.mark.skipif(
    not _mlx_importable(), reason="mlx not installed (CI without Apple silicon)"
)
def test_quantized_round_trip_preserves_linear_output(tmp_path):
    """A quantize → save → reload cycle reproduces the quantized model's
    outputs within quantization tolerance (proves the saved tensor layout
    matches the rebuilt QuantizedLinear graph)."""
    import mlx.core as mx
    import mlx.nn as nn

    class Tiny(nn.Module):
        def __init__(self):
            super().__init__()
            self.layers = [nn.Linear(64, 64) for _ in range(3)]
            self.proj = nn.Linear(64, 8)

        def __call__(self, x):
            for layer in self.layers:
                x = mx.maximum(layer(x), 0)
            return self.proj(x)

    model = Tiny()
    x = mx.random.normal((4, 64))
    nn.quantize(model, group_size=quant_cache.QUANT_GROUP_SIZE, bits=8)
    mx.eval(model.parameters())
    # Expected output comes from the QUANTIZED model: the round trip must
    # reproduce exactly the quantized computation, not the fp original.
    expected = model(x)

    out = tmp_path / "cache"
    out.mkdir()
    from mlx.utils import tree_flatten

    mx.save_safetensors(str(out / "model.safetensors"), dict(tree_flatten(model.parameters())))
    (out / quant_cache.MANIFEST_NAME).write_text(json.dumps({
        "format": "velora-quant",
        "version": quant_cache.CACHE_FORMAT_VERSION,
        "model_id": "tiny",
        "source": "unused",
        "bits": 8,
        "group_size": quant_cache.QUANT_GROUP_SIZE,
        "mode": "affine",
    }))
    (out / "config.json").write_text("{}")

    reloaded = Tiny()
    nn.quantize(reloaded, group_size=quant_cache.QUANT_GROUP_SIZE, bits=8)
    reloaded.load_weights(str(out / "model.safetensors"))
    mx.eval(reloaded.parameters())
    assert mx.allclose(reloaded(x), expected, atol=1e-4)