"""Bark adapters: source identity, packed-cache lifecycle, Core ML compile and
warmup, bounded decoding, cancellation. Offline and deterministic: fake pins,
fake builders, a fake parakeet model and a fake coremltools stand in for the
real weights and frameworks. The vendored upstream frontend, decoder and
segmenter run for real on tiny inputs.

A real-artifact smoke runs only when VELORA_BARK_BUNDLES points at bundles
from scripts/prepare-bundled-model.py (see test_real_bundles_smoke)."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import types
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from velora_engine import bark
from velora_engine import bundled_models as bm

VENDOR = Path(bark.__file__).with_name("vendor_bark")
SR = bark.SAMPLE_RATE


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _variant(key, runtime, files, pad_s=0.25, notice="NOTICE"):
    return bm.BundledModel(
        key=key, repo=f"Example/{key}", revision=_sha(key.encode())[:40], runtime=runtime,
        pad_s=pad_s, files=tuple(bm.PinnedFile(p, len(d), _sha(d)) for p, d in files.items()),
        notice=notice)


CONFIG = b'{"fake-config": true}\n'
MAIN_FILES = {"model.bark": b"main weights " * 300, "mlx/config.json": CONFIG, "NOTICE": b"main\n"}
CLEAN_FILES = {"model.bark": b"clean weights!" * 400, "mlx/config.json": CONFIG, "NOTICE": b"clean\n"}


def _write(root: Path, files: dict[str, bytes]) -> Path:
    for path, data in files.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_bytes(data)
    return root


@pytest.fixture
def pins(monkeypatch):
    main = _variant("fake-bark", "mlx", MAIN_FILES, pad_s=0.25)
    clean = _variant("fake-bark-clean", "mlx", CLEAN_FILES, pad_s=0.0)
    monkeypatch.setattr(bm, "BUNDLED_MODELS", {main.key: main, clean.key: clean})
    return SimpleNamespace(main=main, clean=clean)


@pytest.fixture
def deps(monkeypatch):
    versions = {"mlx": "1.0", "parakeet-mlx": "1.0", "constriction": "0.5.0", "numpy": "2.0"}
    monkeypatch.setattr(bark, "_dependency_versions", lambda names: dict(versions))
    return versions


def fake_builder(calls: list | None = None, *, delay: float = 0.0):
    def build(source_dir, dest, bits, cancel):
        if calls is not None:
            calls.append((Path(source_dir), bits))
        time.sleep(delay)
        (dest / "model.safetensors").write_bytes(b"packed-%d" % bits)
        shutil.copyfile(Path(source_dir) / "mlx" / "config.json", dest / "config.json")
    return build


def _published(root: Path) -> list[str]:
    return sorted(p.name for p in root.iterdir() if not p.name.startswith(".")) if root.exists() else []


def _temps(root: Path) -> list[str]:
    return sorted(p.name for p in root.iterdir() if ".tmp-" in p.name) if root.exists() else []


# --- vendored upstream code -------------------------------------------------------


def test_vendored_files_are_byte_exact_pinned_upstream():
    upstream = json.loads((VENDOR / "UPSTREAM.json").read_text())
    assert upstream["repo"] == bm.BARK_REPO and upstream["revision"] == bm.BARK_REVISION
    assert upstream["modified"] is False and upstream["license"] == "CC-BY-4.0"
    for entry in upstream["files"]:
        data = (VENDOR / entry["path"]).read_bytes()
        assert len(data) == entry["size"], entry["path"]
        assert _sha(data) == entry["sha256"], entry["path"]
        # git's blob id: the Hub lists it for every file at the revision.
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        assert blob == entry["git_blob"], entry["path"]
    assert {e["path"] for e in upstream["files"]} == {
        "bark_loader.py", "bark_mlx.py", "bark_coreml.py", "LICENSE", "NOTICE"}


# --- source identity --------------------------------------------------------------


def test_identify_picks_the_variant_by_content(pins, tmp_path):
    main = bark.identify_source(_write(tmp_path / "a", MAIN_FILES), "mlx")
    clean = bark.identify_source(_write(tmp_path / "b", CLEAN_FILES), "mlx")
    assert main[0] is pins.main and clean[0] is pins.clean
    assert main[2]["model.bark"] == {"size": len(MAIN_FILES["model.bark"]),
                                     "sha256": _sha(MAIN_FILES["model.bark"])}


@pytest.mark.parametrize("damage", ["same-size-other-bytes", "other-size", "missing"])
def test_identify_refuses_anything_unpinned(pins, tmp_path, damage):
    source = _write(tmp_path / "src", MAIN_FILES)
    weights = source / "model.bark"
    if damage == "same-size-other-bytes":
        weights.write_bytes(MAIN_FILES["model.bark"][:-1] + b"?")
    elif damage == "other-size":
        weights.write_bytes(b"short")
    else:
        weights.unlink()
    with pytest.raises(bark.BarkIdentityError):
        bark.identify_source(source, "mlx")


def test_identify_follows_hub_snapshot_symlinks(pins, tmp_path):
    blobs = _write(tmp_path / "blobs", MAIN_FILES)
    snapshot = tmp_path / "snapshot"
    (snapshot / "mlx").mkdir(parents=True)
    (snapshot / "model.bark").symlink_to(blobs / "model.bark")
    (snapshot / "mlx" / "config.json").symlink_to(blobs / "mlx" / "config.json")
    assert bark.identify_source(snapshot, "mlx")[0] is pins.main


# --- MLX packed cache -------------------------------------------------------------


def test_cache_builds_once_then_reuses(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    calls: list = []

    first, variant = bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder(calls))
    second, _ = bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder(calls))

    assert first == second and variant is pins.main and len(calls) == 1
    assert first.name.startswith("fake-bark--int4--")
    manifest = json.loads((first / bark.MLX_MANIFEST).read_text())
    identity = manifest["identity"]
    assert identity["bits"] == 4 and identity["quantization"] == {"group_size": 64, "mode": "affine"}
    assert identity["source"]["model.bark"]["sha256"] == _sha(MAIN_FILES["model.bark"])
    assert identity["dependencies"] == deps
    assert set(identity["vendor"]) == {"bark_loader.py", "bark_mlx.py", "bark_coreml.py"}
    assert manifest["files"]["model.safetensors"]["sha256"] == _sha(b"packed-4")
    assert _temps(root) == []


def test_each_precision_and_variant_gets_its_own_cache(pins, deps, tmp_path):
    root = tmp_path / "cache"
    main = _write(tmp_path / "main", MAIN_FILES)
    clean = _write(tmp_path / "clean", CLEAN_FILES)
    dirs = {bark.ensure_mlx_cache(main, b, cache_root=root, builder=fake_builder())[0].name
            for b in (4, 8, 16)}
    dirs.add(bark.ensure_mlx_cache(clean, 16, cache_root=root, builder=fake_builder())[0].name)
    assert len(dirs) == 4 and set(_published(root)) == dirs


@pytest.mark.parametrize("change", ["dependency", "source"])
def test_new_cache_identity_preserves_potentially_live_old_cache(pins, deps, tmp_path, monkeypatch, change):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    calls: list = []
    old, _ = bark.ensure_mlx_cache(source, 8, cache_root=root, builder=fake_builder(calls))
    if change == "dependency":
        deps["mlx"] = "2.0"  # e.g. an engine update moved mlx
    else:
        newer = dict(MAIN_FILES, **{"model.bark": b"updated main weights" * 100})
        updated = _variant("fake-bark", "mlx", newer)
        monkeypatch.setitem(bm.BUNDLED_MODELS, "fake-bark", updated)
        _write(source, newer)
    new, _ = bark.ensure_mlx_cache(source, 8, cache_root=root, builder=fake_builder(calls))
    assert new != old and len(calls) == 2
    assert old.exists() and set(_published(root)) == {old.name, new.name}


def test_a_damaged_published_cache_is_rebuilt(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    calls: list = []
    published, _ = bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder(calls))
    (published / "model.safetensors").write_bytes(b"trunc")
    again, _ = bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder(calls))
    assert again == published and len(calls) == 2
    assert (again / "model.safetensors").read_bytes() == b"packed-4"


@pytest.mark.parametrize("failure", [RuntimeError("boom"), MemoryError(),
                                     bark.BarkCacheError("validation failed")])
def test_a_failed_build_publishes_nothing_and_never_falls_back(pins, deps, tmp_path, monkeypatch, failure):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    loaded = []
    monkeypatch.setattr(bark, "load_packed", lambda d, bits: loaded.append(bits))

    def failing(source_dir, dest, bits, cancel):
        (dest / "model.safetensors").write_bytes(b"partial")
        raise failure

    with pytest.raises(bark.BarkCacheError) as info:
        bark.load_bark(source, 4, cache_root=root, builder=failing)
    if isinstance(failure, MemoryError):
        assert "not falling back" in str(info.value)
    assert loaded == []  # no fp16 (or any) model was loaded instead
    assert _published(root) == [] and _temps(root) == []


def test_a_build_that_rewrites_the_config_is_rejected(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)

    def wrong_config(source_dir, dest, bits, cancel):
        (dest / "model.safetensors").write_bytes(b"w")
        (dest / "config.json").write_bytes(b"{}")

    with pytest.raises(bark.BarkCacheError):
        bark.ensure_mlx_cache(source, 16, cache_root=tmp_path / "c", builder=wrong_config)
    assert _published(tmp_path / "c") == []


def test_cancel_before_or_during_a_build_publishes_nothing(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    calls: list = []
    with pytest.raises(bark.BarkCancelled):
        bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder(calls),
                              cancel=lambda: True)
    assert calls == []

    cancel = threading.Event()

    def cancelled_mid_build(source_dir, dest, bits, token):
        fake_builder()(source_dir, dest, bits, token)
        cancel.set()

    with pytest.raises(bark.BarkCancelled):
        bark.ensure_mlx_cache(source, 4, cache_root=root, builder=cancelled_mid_build, cancel=cancel)
    assert _published(root) == [] and _temps(root) == []


def test_a_killed_builds_temporary_directory_is_removed(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    stale = root / ".fake-bark--int4--0123456789abcdef.tmp-dead"
    stale.mkdir(parents=True)
    (stale / "model.safetensors").write_bytes(b"half")
    bark.ensure_mlx_cache(source, 4, cache_root=root, builder=fake_builder())
    assert not stale.exists()


def test_concurrent_loads_build_once(pins, deps, tmp_path):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    calls: list = []
    results: list = []
    threads = [threading.Thread(target=lambda: results.append(bark.ensure_mlx_cache(
        source, 8, cache_root=root, builder=fake_builder(calls, delay=0.2))[0])) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(calls) == 1 and len(set(results)) == 1 and len(results) == 3


def test_unsupported_bits_are_refused(pins, tmp_path):
    with pytest.raises(ValueError):
        bark.ensure_mlx_cache(_write(tmp_path / "s", MAIN_FILES), 3, cache_root=tmp_path / "c")


def test_inprocess_build_runs_reload_validation_before_publish(pins, deps, tmp_path, monkeypatch):
    source = _write(tmp_path / "src", MAIN_FILES)
    root = tmp_path / "cache"
    steps: list[str] = []
    monkeypatch.setattr(bark, "_decode_bark", lambda path: steps.append("decode") or {"w": 1})

    def pack(weights, config_path, bits, dest):
        steps.append(f"pack{bits}")
        (dest / "model.safetensors").write_bytes(b"w")
        shutil.copyfile(config_path, dest / "config.json")

    def reject(dest, bits):
        steps.append("validate")
        raise bark.BarkCacheError("reloaded weights are not int4")

    monkeypatch.setattr(bark, "_pack", pack)
    monkeypatch.setattr(bark, "_reload_validate", reject)
    with pytest.raises(bark.BarkCacheError):
        bark.ensure_mlx_cache(source, 4, cache_root=root, builder=bark.build_mlx_cache_inprocess)
    assert steps == ["decode", "pack4", "validate"] and _published(root) == []

    monkeypatch.setattr(bark, "_reload_validate", lambda dest, bits: steps.append("ok"))
    published, _ = bark.ensure_mlx_cache(source, 4, cache_root=root,
                                         builder=bark.build_mlx_cache_inprocess)
    assert steps[-1] == "ok" and published.is_dir()


def test_check_precision_catches_unquantized_or_wrong_width_weights():
    import mlx.core as mx
    import mlx.nn as nn

    class Tiny(nn.Module):
        def __init__(self):
            super().__init__()
            self.proj = nn.Linear(64, 64)
            self.embed = nn.Embedding(5, 64)

    model = Tiny()
    with pytest.raises(bark.BarkCacheError):
        bark.check_precision(model, 4)  # silently full precision
    with pytest.raises(bark.BarkCacheError):
        bark.check_precision(model, 16)  # float32, not fp16
    model.update(nn.utils.tree_map(lambda p: p.astype(mx.float16), model.parameters()))
    bark.check_precision(model, 16)
    nn.quantize(model, group_size=64, bits=4)
    bark.check_precision(model, 4)
    with pytest.raises(bark.BarkCacheError):
        bark.check_precision(model, 8)
    with pytest.raises(bark.BarkCacheError):
        bark.check_precision(model, 16)


# --- the build child ----------------------------------------------------------------


def test_run_child_returns_output_and_reports_failures():
    assert bark.run_child([sys.executable, "-c", "print('built')"]).strip() == "built"
    with pytest.raises(bark.BarkCacheError, match="exploded"):
        bark.run_child([sys.executable, "-c", "import sys; sys.exit('exploded')"])
    with pytest.raises(bark.BarkCacheError, match="signal 9"):
        bark.run_child([sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGKILL)"])


def test_run_child_cancel_and_timeout_kill_the_build(tmp_path):
    marker = tmp_path / "grandchild-alive"
    started_marker = tmp_path / "grandchild-started"
    grandchild = tmp_path / "grandchild.py"
    grandchild.write_text(f"import time\nopen({str(started_marker)!r}, 'w').close()\n"
                          f"time.sleep(3)\nopen({str(marker)!r}, 'w').close()\n")
    child = tmp_path / "child.py"
    # The child spawns a grandchild; killing the process group stops both.
    child.write_text("import subprocess, sys, time\n"
                     f"subprocess.Popen([sys.executable, {str(grandchild)!r}])\n"
                     "time.sleep(60)\n")
    cancel = threading.Event()
    threading.Timer(0.5, cancel.set).start()
    started = time.monotonic()
    with pytest.raises(bark.BarkCancelled):
        bark.run_child([sys.executable, str(child)], cancel=cancel)
    assert time.monotonic() - started < 10
    with pytest.raises(bark.BarkCacheError, match="timed out"):
        bark.run_child([sys.executable, "-c", "import time; time.sleep(60)"], timeout_s=0.3)
    time.sleep(3.5)
    assert started_marker.exists() and not marker.exists()


def test_child_entry_point_rejects_bad_arguments():
    result = subprocess.run([sys.executable, "-P", "-m", "velora_engine.bark", "nope"],
                            capture_output=True, text=True, check=False)
    assert result.returncode == 2 and "usage" in result.stderr


# --- MLX model ----------------------------------------------------------------------


class FakeParakeet:
    """Stands in for parakeet-mlx's TDT model: records each mel it decodes."""

    def __init__(self, text="hello", on_generate=None):
        import librosa

        self.preprocessor_config = SimpleNamespace(
            win_length=400, hop_length=160, n_fft=512, features=128, sample_rate=SR,
            _filterbanks=librosa.filters.mel(sr=SR, n_fft=512, n_mels=128, fmin=0, fmax=8000,
                                             norm="slaney"))
        self.mels: list[tuple[int, ...]] = []
        self.text = text
        self.on_generate = on_generate

    def generate(self, mel):
        self.mels.append(tuple(mel.shape))
        if self.on_generate:
            self.on_generate()
        return [SimpleNamespace(text=f" {self.text} ")]


def _speechlike(seconds: float, gap_every_s: float = 7.0) -> np.ndarray:
    rng = np.random.default_rng(1)
    x = rng.standard_normal(int(seconds * SR)).astype(np.float32) * 0.2
    for start in np.arange(gap_every_s, seconds, gap_every_s):
        x[int(start * SR):int((start + 0.4) * SR)] *= 0.001
    return x


def _mlx_model(pins, fake=None, **kwargs):
    return bark.BarkModel(fake or FakeParakeet(), kwargs.pop("variant", pins.main), 4,
                          Path("/nonexistent"), **kwargs)


def test_decode_pads_like_upstream_and_returns_text(pins):
    main, clean = FakeParakeet(), FakeParakeet()
    assert _mlx_model(pins, main).decode(np.zeros(SR, np.float32)) == "hello"
    _mlx_model(pins, clean, variant=pins.clean).decode(np.zeros(SR, np.float64))
    assert main.mels == [(1, (SR + SR // 4) // 160, 128)]  # 0.25 s leading silence
    assert clean.mels == [(1, SR // 160, 128)]  # Clean: none


@pytest.mark.parametrize("audio, error", [
    (np.zeros((2, SR), np.float32), ValueError),
    (np.zeros(SR, np.int16), TypeError),
    (np.array([0.0, np.nan], np.float32), ValueError),
])
def test_decode_validates_input(pins, audio, error):
    with pytest.raises(error):
        _mlx_model(pins).decode(audio)


def test_decode_of_nothing_is_empty_without_a_model_call(pins):
    fake = FakeParakeet()
    assert _mlx_model(pins, fake).decode(np.zeros(0, np.float32)) == ""
    assert fake.mels == []


def test_long_audio_decodes_in_bounded_pieces(pins):
    fake = FakeParakeet()
    model = _mlx_model(pins, fake)
    text = model.decode(_speechlike(95.0))
    frames_cap = int((model.max_piece_s + model.pad_s) * 100) + 1
    assert len(fake.mels) >= 4 and all(m[1] <= frames_cap for m in fake.mels)
    assert text == " ".join(["hello"] * len(fake.mels))


def test_cancel_stops_between_pieces(pins):
    cancel = threading.Event()
    fake = FakeParakeet(on_generate=cancel.set)
    with pytest.raises(bark.BarkCancelled):
        _mlx_model(pins, fake).decode(_speechlike(95.0), cancel=cancel)
    assert len(fake.mels) == 1


def test_a_model_with_another_frontend_is_refused(pins):
    fake = FakeParakeet()
    fake.preprocessor_config.hop_length = 128
    with pytest.raises(bark.BarkIdentityError):
        _mlx_model(pins, fake)


def test_load_bark_warms_up_and_keeps_the_requested_precision(pins, deps, tmp_path, monkeypatch):
    fake = FakeParakeet()
    loads = []
    monkeypatch.setattr(bark, "load_packed", lambda d, bits: loads.append((d, bits)) or fake)
    model = bark.load_bark(_write(tmp_path / "src", MAIN_FILES), 8, cache_root=tmp_path / "c",
                           builder=fake_builder())
    assert model.ready and model.bits == 8 and model.variant == "fake-bark"
    assert [b for _, b in loads] == [8] and loads[0][0] == model.cache_dir
    assert len(fake.mels) == 1  # the warmup decode


def test_a_published_cache_that_fails_to_load_is_an_error(pins, deps, tmp_path, monkeypatch):
    def broken(directory, bits):
        raise ValueError("bad safetensors header")

    monkeypatch.setattr(bark, "load_packed", broken)
    with pytest.raises(bark.BarkCacheError, match="failed to load"):
        bark.load_bark(_write(tmp_path / "src", MAIN_FILES), 4, cache_root=tmp_path / "c",
                       builder=fake_builder())


# --- Core ML ------------------------------------------------------------------------

H, D = 4, 8  # tiny decoder: LSTM width and joint width
DURATIONS = [0, 1, 2, 3, 1000]


def _decoder_npz(token_bias: list[float]) -> bytes:
    import io

    rng = np.random.default_rng(0)
    arrays = {
        "decoder.embedding.weight": rng.standard_normal((3, H)).astype(np.float32),
        "decoder.decoder_projector.weight": rng.standard_normal((D, H)).astype(np.float32),
        "decoder.decoder_projector.bias": np.zeros(D, np.float32),
        "joint.head.weight": np.zeros((3 + len(DURATIONS), D), np.float32),
        # Token logits, then duration logits: always pick the 1000-frame
        # duration, so each piece emits exactly one token.
        "joint.head.bias": np.array(token_bias + [0, 0, 0, 0, 5], np.float32),
        "mel_filters": np.abs(rng.standard_normal((128, 257))).astype(np.float32) * 0.01,
    }
    for i in range(2):
        arrays[f"decoder.lstm.weight_ih_l{i}"] = rng.standard_normal((4 * H, H)).astype(np.float32)
        arrays[f"decoder.lstm.weight_hh_l{i}"] = rng.standard_normal((4 * H, H)).astype(np.float32)
        arrays[f"decoder.lstm.bias_ih_l{i}"] = np.zeros(4 * H, np.float32)
        arrays[f"decoder.lstm.bias_hh_l{i}"] = np.zeros(4 * H, np.float32)
    buffer = io.BytesIO()
    np.savez(buffer, **arrays)
    return buffer.getvalue()


VOCAB = json.dumps({"pieces": ["▁hi", "▁there"], "special_ids": [], "blank_id": 2,
                    "vocab_size": 3, "durations": DURATIONS, "max_symbols_per_step": 10}).encode()
PKG = "coreml/ane/BarkEncoder.mlpackage"


def _ane_files(token_bias=(5.0, 0.0, 0.0)) -> dict[str, bytes]:
    return {
        f"{PKG}/Data/com.apple.CoreML/model.mlmodel": b"fake mlmodel",
        f"{PKG}/Data/com.apple.CoreML/weights/weight.bin": b"fake weights" * 50,
        f"{PKG}/Manifest.json": b"{}",
        "coreml/ane/decoder.npz": _decoder_npz(list(token_bias)),
        "coreml/ane/vocab.json": VOCAB,
        "coreml/NOTICE": b"main\n",
    }


class FakeCoreML:
    """A coremltools stand-in that records compiles, loads and predictions."""

    def __init__(self, version="9.0"):
        self.compiles: list[tuple[Path, Path]] = []
        self.loads: list[tuple[str, object, str]] = []
        self.predictions: list[tuple[str, tuple[int, ...]]] = []
        self.encoded_value = 0.0
        self.fail_compile = False
        self.compile_writes_bundle = True
        fake = self

        class CompiledMLModel:
            def __init__(self, path, compute_units=None, function_name=None):
                fake.loads.append((path, compute_units, function_name))
                self.function_name = function_name

            def predict(self, inputs):
                features = inputs["features"]
                assert features.dtype == np.float16 and inputs["mask"].dtype == np.int32
                fake.predictions.append((self.function_name, features.shape))
                frames = (features.shape[1] - 1) // 8 + 1
                return {"encoded": np.full((1, frames, D), fake.encoded_value, np.float32)}

        def compile_model(src, destination_path=None):
            fake.compiles.append((Path(src), Path(destination_path)))
            if fake.fail_compile:
                raise RuntimeError("compiler crashed")
            out = Path(destination_path)
            out.mkdir(parents=True)
            if fake.compile_writes_bundle:
                (out / "coremldata.bin").write_bytes(b"compiled")
                (out / "model.mil").write_bytes(b"mil")
            return str(out)

        self.module = types.ModuleType("coremltools")
        self.module.__version__ = version
        self.module.ComputeUnit = SimpleNamespace(
            CPU_AND_NE="CPU_AND_NE", CPU_AND_GPU="CPU_AND_GPU", CPU_ONLY="CPU_ONLY", ALL="ALL")
        models = types.ModuleType("coremltools.models")
        models.CompiledMLModel = CompiledMLModel
        models.utils = types.ModuleType("coremltools.models.utils")
        models.utils.compile_model = compile_model
        self.module.models = models


@pytest.fixture
def coreml(monkeypatch, tmp_path):
    fake = FakeCoreML()
    monkeypatch.setitem(sys.modules, "coremltools", fake.module)
    files = _ane_files()
    variant = _variant("fake-bark-ane", "coreml", files, notice="coreml/NOTICE")
    monkeypatch.setattr(bm, "BUNDLED_MODELS", {variant.key: variant})
    fake.variant = variant
    fake.source = _write(tmp_path / "ane-src", files)
    fake.cache = tmp_path / "coreml-cache"
    return fake


def test_coreml_compiles_once_to_a_stable_path_and_warms_up_before_ready(coreml):
    model = bark.load_bark_coreml(coreml.source, coreml.cache)

    assert model.ready and model.variant == "fake-bark-ane"
    assert len(coreml.compiles) == 1
    src, dst = coreml.compiles[0]
    assert src == coreml.source / PKG and model.compiled_path.name == "BarkEncoder.mlmodelc"
    assert model.compiled_path.parent.parent == coreml.cache
    assert sorted((p, u, f) for p, u, f in coreml.loads) == [
        (str(model.compiled_path), "CPU_AND_NE", "w15"), (str(model.compiled_path), "CPU_AND_NE", "w8")]
    assert sorted(f for f, _ in coreml.predictions) == ["w15", "w8"]  # warmup hit both windows

    again = bark.load_bark_coreml(coreml.source, coreml.cache)
    assert again.compiled_path == model.compiled_path and len(coreml.compiles) == 1
    manifest = json.loads((model.compiled_path.parent / bark.COREML_MANIFEST).read_text())
    assert manifest["identity"]["coremltools"] == "9.0"
    assert "BarkEncoder.mlmodelc/coremldata.bin" in manifest["files"]


def test_coreml_accepts_the_ane_folder_itself(coreml):
    model = bark.load_bark_coreml(coreml.source / "coreml" / "ane", coreml.cache)
    assert model.ready and coreml.compiles[0][0] == coreml.source / PKG


def test_coreml_recompiles_when_the_toolchain_changes(coreml, monkeypatch):
    first = bark.load_bark_coreml(coreml.source, coreml.cache).compiled_path
    coreml.module.__version__ = "9.1"
    second = bark.load_bark_coreml(coreml.source, coreml.cache).compiled_path
    monkeypatch.setattr(bark.platform, "mac_ver", lambda: ("99.0", ("", "", ""), "arm64"))
    third = bark.load_bark_coreml(coreml.source, coreml.cache).compiled_path
    assert len({first, second, third}) == 3 and len(coreml.compiles) == 3
    assert first.exists() and second.exists() and third.exists()


@pytest.mark.parametrize("failure", ["compile-raises", "no-bundle"])
def test_coreml_compile_failures_publish_nothing(coreml, failure):
    if failure == "compile-raises":
        coreml.fail_compile = True
    else:
        coreml.compile_writes_bundle = False
    with pytest.raises(bark.BarkCacheError):
        bark.load_bark_coreml(coreml.source, coreml.cache)
    assert _published(coreml.cache) == [] and _temps(coreml.cache) == []
    assert coreml.loads == []


def test_coreml_stale_compile_temp_is_removed(coreml):
    stale = coreml.cache / ".fake-bark-ane--0123456789abcdef.tmp-dead"
    stale.mkdir(parents=True)
    bark.load_bark_coreml(coreml.source, coreml.cache)
    assert not stale.exists()


def test_coreml_concurrent_loads_compile_once(coreml):
    models: list = []
    threads = [threading.Thread(target=lambda: models.append(
        bark.load_bark_coreml(coreml.source, coreml.cache))) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(models) == 3 and len(coreml.compiles) == 1


def test_coreml_non_finite_warmup_never_reports_ready(coreml):
    coreml.encoded_value = float("nan")
    with pytest.raises(bark.BarkCacheError, match="warmup"):
        bark.load_bark_coreml(coreml.source, coreml.cache)


def test_coreml_decodes_long_audio_in_windows_of_at_most_15s(coreml):
    model = bark.load_bark_coreml(coreml.source, coreml.cache)
    coreml.predictions.clear()
    text = model.decode(_speechlike(40.0))
    pieces = len(coreml.predictions)
    assert pieces >= 3 and text == " ".join(["hi"] * pieces)
    assert {f for f, _ in coreml.predictions} <= {"w8", "w15"}
    assert all(shape[1] <= 15 * 100 + 1 for _, shape in coreml.predictions)
    assert model.decode(np.zeros(SR // 2, np.float32)) == "hi"
    assert coreml.predictions[-1][0] == "w8"


def test_coreml_decode_cancel_and_bad_output(coreml):
    model = bark.load_bark_coreml(coreml.source, coreml.cache)
    coreml.predictions.clear()
    calls = iter([False, True])
    with pytest.raises(bark.BarkCancelled):
        model.decode(_speechlike(40.0), cancel=lambda: next(calls, True))
    assert len(coreml.predictions) == 1
    coreml.encoded_value = float("inf")
    with pytest.raises(bark.BarkError, match="not finite"):
        model.decode(np.zeros(SR, np.float32))


def test_coreml_cancel_before_compile(coreml):
    with pytest.raises(bark.BarkCancelled):
        bark.load_bark_coreml(coreml.source, coreml.cache, cancel=lambda: True)
    assert coreml.compiles == []


def test_coreml_identity_is_checked(coreml):
    (coreml.source / "coreml" / "ane" / "vocab.json").write_bytes(VOCAB.replace(b"hi", b"ho"))
    with pytest.raises(bark.BarkIdentityError):
        bark.load_bark_coreml(coreml.source, coreml.cache)


def test_coreml_unavailable_without_coremltools(coreml, monkeypatch):
    monkeypatch.setitem(sys.modules, "coremltools", None)  # as on Python 3.14: no wheel
    with pytest.raises(bark.BarkUnavailable):
        bark.load_bark_coreml(coreml.source, coreml.cache)
    with pytest.raises(ValueError):
        bark.load_bark_coreml(coreml.source, coreml.cache, compute_units="npu")


# --- optional real-artifact smoke ---------------------------------------------------


@pytest.mark.skipif(not os.environ.get("VELORA_BARK_BUNDLES"),
                    reason="set VELORA_BARK_BUNDLES to bundles from prepare-bundled-model.py")
@pytest.mark.parametrize("key, bits", [("bark-3.0", 4), ("bark-3.0-clean", 16), ("bark-3.0-ane", None)])
def test_real_bundles_smoke(tmp_path, key, bits):
    """Real weights; builds caches under tmp_path (ANE's first load can take
    minutes). Synthesizes speech with macOS `say`."""
    bundle = Path(os.environ["VELORA_BARK_BUNDLES"]) / key
    if not bundle.is_dir():
        pytest.skip(f"no {key} bundle")
    aiff, wav = tmp_path / "s.aiff", tmp_path / "s.wav"
    subprocess.run(["say", "-o", str(aiff), "The quick brown fox jumps over the lazy dog."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", str(aiff), str(wav)],
                   check=True)
    import soundfile

    audio, sr = soundfile.read(wav, dtype="float32")
    assert sr == SR
    if bits is None:
        model = bark.load_bark_coreml(bundle, Path(os.environ.get(
            "VELORA_BARK_ANE_CACHE", tmp_path / "ane-cache")))
    else:
        model = bark.load_bark(bundle, bits, cache_root=tmp_path / "cache")
    text = model.decode(audio).lower()
    assert "quick brown fox" in text and "lazy dog" in text, text
