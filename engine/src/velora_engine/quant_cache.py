"""Derived quantized caches for parakeet MLX models.

One fp16 download serves every RAM tier: the engine quantizes locally
(affine, group_size=64, via mlx.nn.quantize) into a derived cache directory
under ``~/.velora/quant-cache`` and loads from it. The alternative — shipping
or downloading a separate int8/int4 repo per tier — triples the download
surface for the same weights.

The publish protocol is modeled on the pattern the Woof dictation app ships
(MIT): build into a private temporary directory, validate the saved weights
reload, then atomically rename into place behind an advisory lock. A cache
directory only becomes visible once it is complete, and a failed or
interrupted build leaves no half-published cache. The manifest pins the
source snapshot path, quantization parameters, and cache format revision,
so an updated upstream model (or a changed group size) rebuilds the cache
instead of silently serving stale weights.

``mlx.nn.quantize`` replaces ``mlx.nn.Linear`` layers with
``QuantizedLinear``; the saved safetensors carry packed integer weights plus
per-group scales. Loading therefore must NOT go through
``parakeet_mlx.from_pretrained`` — its trailing dtype cast would corrupt the
packed integers — so this module owns the load path too
(:func:`load_quantized_parakeet`).
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

from .config import velora_home

log = logging.getLogger("velora.quant_cache")

QUANT_GROUP_SIZE = 64
CACHE_FORMAT_VERSION = 1
MANIFEST_NAME = "velora-quant.json"
REQUIRED_FILES = ("config.json", "model.safetensors", MANIFEST_NAME)


def _sanitize(model_id: str) -> str:
    """Filesystem-safe cache component for a Hub model id."""
    return re.sub(r"[^A-Za-z0-9._-]+", "--", model_id.strip()) or "model"


def cache_path(model_id: str, bits: int, home: Path | None = None) -> Path:
    """Directory a derived int{bits} cache for `model_id` lives in."""
    root = (home or velora_home()) / "quant-cache"
    return root / f"{_sanitize(model_id)}--int{bits}--v{CACHE_FORMAT_VERSION}"


def expected_manifest(model_id: str, source_dir: Path, bits: int) -> dict[str, Any]:
    return {
        "format": "velora-quant",
        "version": CACHE_FORMAT_VERSION,
        "model_id": model_id,
        "source": str(source_dir),
        "bits": bits,
        "group_size": QUANT_GROUP_SIZE,
        "mode": "affine",
    }


def manifest_matches(cache_dir: Path, model_id: str, source_dir: Path, bits: int) -> bool:
    """True when the published cache is complete and was built from exactly
    this source snapshot with these parameters."""
    try:
        manifest = json.loads((cache_dir / MANIFEST_NAME).read_text())
    except (OSError, ValueError):
        return False
    if manifest != expected_manifest(model_id, source_dir, bits):
        return False
    return all((cache_dir / name).is_file() for name in REQUIRED_FILES)


def _build_quantized(source_dir: Path, destination: Path, bits: int) -> None:
    """Quantize the model at `source_dir` into a fresh `destination`."""
    import mlx.core as mx
    import mlx.nn as nn
    from mlx.utils import tree_flatten
    from parakeet_mlx.utils import from_config

    config = json.loads((source_dir / "config.json").read_text())
    model = from_config(config)
    model.load_weights(str(source_dir / "model.safetensors"))
    nn.quantize(model, group_size=QUANT_GROUP_SIZE, bits=bits)
    mx.eval(model.parameters())
    mx.save_safetensors(
        str(destination / "model.safetensors"),
        dict(tree_flatten(model.parameters())),
    )
    shutil.copy2(source_dir / "config.json", destination / "config.json")
    del model


def _reload_validates(destination: Path) -> bool:
    """Prove the saved weights load into a fresh model before publishing."""
    try:
        load_quantized_parakeet(destination)
    except Exception:  # noqa: BLE001 — any reload failure must block publish
        return False
    return True


def ensure_quantized(source_dir: Path, model_id: str, bits: int) -> Path:
    """Return a validated int`bits` cache directory for `model_id`, building
    it from `source_dir` when missing or stale.

    Raises on a build failure (the caller falls back to the fp16 original).
    Concurrency: two processes (engine restart racing a reprocess load)
    serialize on an advisory lock; a stale temporary directory from a killed
    build is removed before a new build starts.
    """
    if bits not in (4, 8):
        raise ValueError(f"unsupported quantization bits {bits!r}")
    source_dir = Path(source_dir)
    cache_dir = cache_path(model_id, bits)
    if manifest_matches(cache_dir, model_id, source_dir, bits):
        return cache_dir

    cache_dir.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (cache_dir.parent / ".build.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            if manifest_matches(cache_dir, model_id, source_dir, bits):
                return cache_dir

            for stale in cache_dir.parent.glob(f".{cache_dir.name}.tmp-*"):
                shutil.rmtree(stale, ignore_errors=True)

            temp = Path(tempfile.mkdtemp(
                prefix=f".{cache_dir.name}.tmp-", dir=cache_dir.parent))
            try:
                os.chmod(temp, 0o700)
                _build_quantized(source_dir, temp, bits)
                (temp / MANIFEST_NAME).write_text(json.dumps(
                    expected_manifest(model_id, source_dir, bits), indent=2) + "\n")
                if not _reload_validates(temp):
                    raise OSError(
                        f"quantized cache for {model_id} int{bits} failed reload validation")
                if cache_dir.exists():
                    shutil.rmtree(cache_dir)
                temp.rename(cache_dir)
                log.info("published int%d quantized cache for %s at %s",
                         bits, model_id, cache_dir)
                return cache_dir
            finally:
                if temp.exists():
                    shutil.rmtree(temp, ignore_errors=True)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def load_quantized_parakeet(directory: Path) -> Any:
    """Load a quantized parakeet model from a cache directory.

    Two things make this differ from ``parakeet_mlx.from_pretrained``:

    1. Its trailing ``astype(dtype)`` over every parameter would corrupt
      QuantizedLinear's packed integers — quantized weights must stay in
      their stored dtypes.
    2. The model graph itself must be quantized (Linear → QuantizedLinear)
      BEFORE the strict ``load_weights``, or the saved ``weight``/
      ``biases``/``scales`` tensors have no parameters to land in.

    The quantization parameters come from the cache manifest, so the loader
    can never disagree with how the weights were produced. The vocabulary
    (tokenizer) is part of config.json, so no extra files are needed beyond
    the two the cache publishes.
    """
    import mlx.core as mx
    import mlx.nn as nn
    from parakeet_mlx.utils import from_config

    directory = Path(directory)
    manifest = json.loads((directory / MANIFEST_NAME).read_text())
    if manifest.get("format") != "velora-quant":
        raise ValueError(f"{directory} is not a Velora quantized cache")
    config = json.loads((directory / "config.json").read_text())
    model = from_config(config)
    nn.quantize(model, group_size=int(manifest["group_size"]),
                bits=int(manifest["bits"]))
    model.load_weights(str(directory / "model.safetensors"))
    mx.eval(model.parameters())
    return model