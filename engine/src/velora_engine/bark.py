"""Underdog Bark 3.0 English STT: MLX (GPU) and Core ML (ANE) adapters.

    load_bark(source_dir, bits)              -> BarkModel        MLX, bits 4 | 8 | 16
    load_bark_coreml(source_dir, cache_dir)  -> BarkCoreMLModel  ANE encoder, CPU decoder
    model.decode(audio)                      -> str              mono 16 kHz float32

Both loaders identify `source_dir` against the pins in ``bundled_models``.
A file that is not a pinned Bark artifact raises BarkIdentityError. The
pinned variant fixes the leading-silence pad upstream evaluated: 0.25 s for
Bark 3.0, none for Clean.

MLX: ``model.bark`` is an entropy-coded container. It is unpacked once into a
packed-weights cache, then loaded straight into parakeet-mlx's TDT graph:

    model.bark ─▶ child process: vendored load_state_dict ─▶ to_mlx_names
                   ─▶ fp16 ─▶ strict load ─▶ [nn.quantize int8/int4]
                   ─▶ save ─▶ reload into a fresh model, check, smoke-run
               ─▶ parent: hash outputs, write manifest, no-replace rename
    ~/.velora/bark-cache/bark-3.0--int4--<identity>/  model.safetensors config.json

The cache identity covers the source sizes and hashes, the bits and group
size, the versions of mlx, parakeet-mlx, constriction and numpy, and the
vendored loader hashes. Any change builds a new cache. Valid older caches
remain until engine-coordinated removal, since another process may still
be using them. The build runs in a child process for three reasons. Its
~3 GB unpack peak and torch import leave with the child. A jetsam kill on a
small Mac fails the build instead of the engine. Cancel can kill it
mid-unpack. A failed or killed build raises BarkCacheError: a low-RAM tier
never silently falls back to fp16. Features come from the vendored upstream
numpy frontend, the transformers ParakeetFeatureExtractor port that Bark was
evaluated with. parakeet-mlx's own get_logmel differs in its magnitude, log
guard and std. Audio is decoded in pieces of at most MLX_MAX_PIECE_S, cut at
pauses, so memory stays bounded however long the input.

Core ML: the ANE package is a multifunction encoder (``w8``/``w15``, fixed 8 s
and 15 s windows). It is compiled once to a stable ``.mlmodelc`` under
`cache_dir`, under a lock, and published atomically. A stable path lets Core
ML reuse its on-device ANE specialization across launches. Loading warms
both windows before the model reports ready. Long audio is cut at pauses
into pieces of at most 15 s, exactly as upstream's ``bark_coreml.py`` does.
"""

from __future__ import annotations

import fcntl
import functools
import hashlib
import json
import logging
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from importlib import metadata
from pathlib import Path
from typing import Any, Callable, Iterator

import numpy as np

from . import bundled_models as bm
from .bundled_models import CancelToken, exclusive_lock, is_cancelled, rename_no_replace

log = logging.getLogger("velora.bark")

SAMPLE_RATE = 16000
SUPPORTED_BITS = (4, 8, 16)
QUANT_GROUP_SIZE = 64
CACHE_FORMAT_VERSION = 1
MLX_MANIFEST = "velora-bark.json"
COREML_MANIFEST = "velora-bark-coreml.json"
# Upper bound on audio per MLX encoder call. Upstream measured stock
# mlx-audio peaking at ~15 GB on one 10-minute file. Encoder attention
# grows with the square of length.
MLX_MAX_PIECE_S = 30.0
MLX_MIN_PIECE_S = 10.0
BUILD_TIMEOUT_S = 30 * 60
COREML_UNITS = ("ane", "gpu", "cpu", "all")
_MLX_DEPENDENCIES = ("mlx", "parakeet-mlx", "constriction", "numpy")
_VENDOR_DIR = Path(__file__).with_name("vendor_bark")
_PACKED_FILES = ("model.safetensors", "config.json")
_COMPILED_NAME = "BarkEncoder.mlmodelc"


class BarkError(RuntimeError):
    """Base class for Bark adapter failures."""


class BarkIdentityError(BarkError):
    """The source is missing files or is not a pinned Bark artifact."""


class BarkCacheError(BarkError):
    """Building, compiling, validating or loading a derived cache failed.

    Never answered by a silent fallback to another precision or runtime.
    """


class BarkCancelled(BarkError):
    """The caller's cancel token fired; nothing was published."""


class BarkUnavailable(BarkError):
    """This machine or Python cannot run the requested runtime."""


# --- shared helpers -----------------------------------------------------------


def _check_cancel(cancel: CancelToken, what: str) -> None:
    if is_cancelled(cancel):
        raise BarkCancelled(f"{what} cancelled")


def _digest(obj: Any) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def _dependency_versions(names: tuple[str, ...]) -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in names:
        try:
            versions[name] = metadata.version(name)
        except metadata.PackageNotFoundError:
            versions[name] = None
    return versions


@functools.lru_cache(maxsize=1)
def _vendor_hashes() -> dict[str, str]:
    return {name: bm.sha256_file(_VENDOR_DIR / name)
            for name in ("bark_loader.py", "bark_mlx.py", "bark_coreml.py")}


def _vendor_coreml() -> Any:
    from .vendor_bark import bark_coreml

    return bark_coreml


def _require_apple_silicon() -> None:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise BarkUnavailable("Bark runs on Apple silicon Macs only")


def as_mono_16k(audio: Any) -> np.ndarray:
    """Validate decode input: a 1-D float array of finite 16 kHz samples."""
    x = np.asarray(audio)
    if x.ndim != 1:
        raise ValueError(f"audio must be mono (1-D), got shape {x.shape}")
    if not np.issubdtype(x.dtype, np.floating):
        raise TypeError(f"audio must be float samples, got {x.dtype}")
    x = x.astype(np.float32, copy=False)
    if not np.isfinite(x).all():
        raise ValueError("audio contains NaN or infinite samples")
    return x


def _runtime_files(model: bm.BundledModel) -> list[bm.PinnedFile]:
    """Pinned files a runtime reads (attribution files are not loaded)."""
    return [f for f in model.files if not f.path.endswith(("NOTICE", "LICENSE"))]


def identify_source(source_dir: Path, runtime: str,
                    cancel: CancelToken = None) -> tuple[bm.BundledModel, Path, dict[str, dict[str, Any]]]:
    """Match `source_dir` to a pinned variant of `runtime` ("mlx" | "coreml").

    Returns (variant, base directory holding the runtime files, a record of
    each file's size and sha256). For Core ML, `source_dir` may be the
    repository root (with ``coreml/ane/``) or the ``ane`` folder itself.
    Symlinks are followed (Hub snapshots link into the blob store); the
    target must be a regular file. Raises BarkIdentityError.
    """
    source_dir = Path(source_dir)
    candidates = [m for m in bm.BUNDLED_MODELS.values() if m.runtime == runtime]
    if not candidates:
        raise ValueError(f"unknown Bark runtime {runtime!r}")
    hashes: dict[Path, str] = {}
    mismatches: list[str] = []
    for model in candidates:
        records: dict[str, dict[str, Any]] = {}
        base = source_dir
        strip = ""
        if runtime == "coreml" and not (source_dir / bm.ANE_DIR).is_dir():
            strip = bm.ANE_DIR + "/"
        try:
            for pinned in _runtime_files(model):
                relative = pinned.path[len(strip):] if strip and pinned.path.startswith(strip) else pinned.path
                path = base / relative
                if not path.is_file():
                    raise BarkIdentityError(f"{source_dir} is missing {relative}")
                size = path.stat().st_size
                if size != pinned.size:
                    raise LookupError(f"{relative}: {size} bytes")
                if path not in hashes:
                    hashes[path] = bm.sha256_file(path, cancel)
                if hashes[path] != pinned.sha256:
                    raise LookupError(f"{relative}: sha256 {hashes[path]}")
                records[pinned.path] = {"size": size, "sha256": hashes[path]}
        except bm.BundleImportCancelled:
            raise BarkCancelled("source identification cancelled") from None
        except LookupError as exc:
            mismatches.append(f"not {model.key}@{model.revision[:12]} ({exc})")
            continue
        ane_dir = base / bm.ANE_DIR if runtime == "coreml" and not strip else base
        return model, ane_dir, records
    raise BarkIdentityError(
        f"{source_dir} is not a pinned Bark {runtime} artifact: " + "; ".join(mismatches))


# --- MLX packed-weights cache -------------------------------------------------


def default_cache_root() -> Path:
    from .config import velora_home

    return velora_home() / "bark-cache"


def _tier(bits: int) -> str:
    return "fp16" if bits == 16 else f"int{bits}"


def mlx_identity(model: bm.BundledModel, records: dict[str, dict[str, Any]],
                 bits: int) -> dict[str, Any]:
    return {
        "format": "velora-bark-mlx",
        "version": CACHE_FORMAT_VERSION,
        "variant": model.key,
        "repo": model.repo,
        "revision": model.revision,
        "bits": bits,
        "quantization": (None if bits == 16 else
                         {"group_size": QUANT_GROUP_SIZE, "mode": "affine"}),
        "source": records,
        "dependencies": _dependency_versions(_MLX_DEPENDENCIES),
        "vendor": _vendor_hashes(),
    }


def mlx_cache_dir(cache_root: Path, identity: dict[str, Any]) -> Path:
    return Path(cache_root) / (
        f"{identity['variant']}--{_tier(identity['bits'])}--{_digest(identity)[:16]}")


@functools.lru_cache(maxsize=64)
def _cache_digest(path: str, size: int, mtime_ns: int) -> str:
    return bm.sha256_file(Path(path))


def _cache_file_matches(path: Path, record: Any, root: Path) -> bool:
    if not isinstance(record, dict):
        return False
    try:
        # Do not follow a modified manifest or symlink outside owned storage.
        path.resolve().relative_to(root.resolve())
        if path.is_symlink() or not path.is_file():
            return False
        stat = path.stat()
        return (stat.st_size == record.get("size")
                and _cache_digest(str(path), stat.st_size, stat.st_mtime_ns) == record.get("sha256"))
    except (OSError, ValueError):
        return False


def _checked_piece_text(piece: np.ndarray, text: str) -> str:
    # Match Velora's energy tracker's 100 ms / 0.003 RMS speech floor.
    # A peak-only digital-silence test misclassifies ordinary room tone and
    # makes long pauses fail. This is energy evidence, not a learned VAD.
    if not text.strip():
        for start in range(0, len(piece), SAMPLE_RATE // 10):
            frame = piece[start:start + SAMPLE_RATE // 10]
            rms = float(np.sqrt(np.mean(np.square(frame, dtype=np.float64))))
            if rms >= 0.003:
                raise BarkError("Bark decoded an empty piece over speech-level audio; recording retained for retry")
    return text


def _published_mlx(directory: Path, identity: dict[str, Any]) -> bool:
    try:
        manifest = json.loads((directory / MLX_MANIFEST).read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(manifest, dict) or manifest.get("identity") != identity:
        return False
    files = manifest.get("files")
    if not isinstance(files, dict) or set(files) != set(_PACKED_FILES):
        return False
    for name, record in files.items():
        path = directory / name
        if not _cache_file_matches(path, record, directory):
            return False
    return True


Builder = Callable[[Path, Path, int, CancelToken], None]


def ensure_mlx_cache(source_dir: Path, bits: int, *, cache_root: Path | None = None,
                     cancel: CancelToken = None,
                     builder: Builder | None = None) -> tuple[Path, bm.BundledModel]:
    """Return (validated packed cache directory, variant) for `source_dir`.

    Builds when missing or stale. Concurrent callers (engine restart racing
    a reprocess load) serialize on an advisory lock, and a killed build's
    temporary directory is removed before the next one starts. Raises
    BarkIdentityError, BarkCancelled, or BarkCacheError. A failure never
    publishes and never substitutes another precision.
    """
    if bits not in SUPPORTED_BITS:
        raise ValueError(f"Bark supports bits {SUPPORTED_BITS}, got {bits!r}")
    model, base, records = identify_source(Path(source_dir), "mlx", cancel)
    identity = mlx_identity(model, records, bits)
    root = Path(cache_root) if cache_root is not None else default_cache_root()
    final = mlx_cache_dir(root, identity)
    if _published_mlx(final, identity):
        return final, model

    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    build = builder or build_mlx_cache_subprocess
    prefix = f"{model.key}--{_tier(bits)}--"
    with exclusive_lock(root / ".build.lock"):
        if _published_mlx(final, identity):
            return final, model
        for stale in root.glob(f".{prefix}*.tmp-*"):
            shutil.rmtree(stale, ignore_errors=True)
        _check_cancel(cancel, "Bark cache build")
        temp = Path(tempfile.mkdtemp(prefix=f".{final.name}.tmp-", dir=root))
        started = time.perf_counter()
        try:
            try:
                build(base, temp, bits, cancel)
            except BarkError:
                raise
            except MemoryError as exc:
                raise BarkCacheError(
                    f"out of memory building the {_tier(bits)} Bark cache; "
                    "not falling back to another precision") from exc
            except Exception as exc:  # noqa: BLE001 — any builder failure blocks publish
                raise BarkCacheError(f"Bark {_tier(bits)} cache build failed: {exc}") from exc
            _check_cancel(cancel, "Bark cache build")
            files: dict[str, dict[str, Any]] = {}
            for name in _PACKED_FILES:
                path = temp / name
                if not path.is_file():
                    raise BarkCacheError(f"Bark cache build produced no {name}")
                files[name] = {"size": path.stat().st_size, "sha256": bm.sha256_file(path)}
            if files["config.json"]["sha256"] != records["mlx/config.json"]["sha256"]:
                raise BarkCacheError("Bark cache build wrote a config.json that is not the source's")
            (temp / MLX_MANIFEST).write_text(json.dumps(
                {"identity": identity, "files": files,
                 "built_seconds": round(time.perf_counter() - started, 2)}, indent=2) + "\n")
            if os.path.lexists(final):
                shutil.rmtree(final)  # ours (digest-named in our root) but incomplete
            rename_no_replace(temp, final)
            log.info("published Bark %s %s cache at %s in %.1fs", model.key, _tier(bits),
                     final, time.perf_counter() - started)
        finally:
            if temp.exists():
                shutil.rmtree(temp, ignore_errors=True)
        # Other identities may still be held by a running engine. Explicit
        # storage removal owns the active-model guard; do not prune here.
    return final, model


def _decode_bark(path: Path) -> dict[str, Any]:
    """model.bark -> {mlx parameter name: fp16 mx.array}, exactly as upstream
    ``bark_mlx.prepare`` produces before saving."""
    import mlx.core as mx

    from .vendor_bark import bark_loader, bark_mlx

    state, _config = bark_loader.load_state_dict(str(path), as_numpy=True)
    names = bark_mlx.to_mlx_names(state)
    del state
    weights: dict[str, Any] = {}
    for key in list(names):
        weights[key] = mx.array(names.pop(key)).astype(mx.float16)
        mx.eval(weights[key])  # frees this tensor's float32 copy now
    return weights


def _pack(weights: dict[str, Any], config_path: Path, bits: int, dest: Path) -> None:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx.utils import tree_flatten
    from parakeet_mlx.utils import from_config

    model = from_config(json.loads(config_path.read_text()))
    model.load_weights(list(weights.items()), strict=True)
    weights.clear()
    if bits < 16:
        nn.quantize(model, group_size=QUANT_GROUP_SIZE, bits=bits)
    params = dict(tree_flatten(model.parameters()))
    mx.eval(params)
    mx.save_safetensors(str(dest / "model.safetensors"), params)
    shutil.copyfile(config_path, dest / "config.json")


def load_packed(directory: Path, bits: int) -> Any:
    """Load a packed cache into parakeet-mlx's TDT graph, in stored dtypes.

    Not ``parakeet_mlx.from_pretrained``: its trailing dtype cast would
    corrupt quantized integers (see quant_cache.py). The graph is quantized
    before the strict load so packed weights have parameters to land in.
    """
    import mlx.core as mx
    import mlx.nn as nn
    from parakeet_mlx.utils import from_config

    model = from_config(json.loads((Path(directory) / "config.json").read_text()))
    if bits < 16:
        nn.quantize(model, group_size=QUANT_GROUP_SIZE, bits=bits)
    model.load_weights(str(Path(directory) / "model.safetensors"), strict=True)
    mx.eval(model.parameters())
    return model


def check_precision(model: Any, bits: int) -> None:
    """Raise BarkCacheError unless every weight is at the requested precision."""
    import mlx.core as mx
    import mlx.nn as nn

    # nn.quantize's default predicate converts every Linear and Embedding,
    # so any plain one left in an int cache was never quantized.
    quantized = [m for _, m in model.named_modules()
                 if isinstance(m, (nn.QuantizedLinear, nn.QuantizedEmbedding))]
    plain = [name for name, m in model.named_modules() if type(m) in (nn.Linear, nn.Embedding)]
    if bits == 16:
        if quantized:
            raise BarkCacheError("fp16 Bark cache holds quantized layers")
        from mlx.utils import tree_flatten

        wide = [k for k, v in tree_flatten(model.parameters())
                if mx.issubdtype(v.dtype, mx.floating) and v.dtype != mx.float16]
        if wide:
            raise BarkCacheError(f"fp16 Bark cache holds non-fp16 weights: {wide[:3]}")
        return
    if not quantized or plain or any(m.bits != bits for m in quantized):
        raise BarkCacheError(
            f"Bark cache is not int{bits}: {len(quantized)} quantized layers, "
            f"{len(plain)} full-precision linears")


def _reload_validate(dest: Path, bits: int) -> None:
    """Prove the saved cache loads into a fresh graph and runs, finitely."""
    import mlx.core as mx

    model = load_packed(dest, bits)
    check_precision(model, bits)
    coreml = _vendor_coreml()
    frontend = coreml.Frontend(np.asarray(model.preprocessor_config._filterbanks, np.float32))
    noise = np.random.default_rng(0).standard_normal(SAMPLE_RATE).astype(np.float32) * 0.01
    feats, valid = frontend(noise)
    encoded, _lengths = model.encoder(mx.array(feats[:valid][None]))
    if not bool(mx.all(mx.isfinite(encoded))):
        raise BarkCacheError("reloaded Bark cache produced non-finite encoder output")
    model.generate(mx.array(feats[:valid][None]))


def build_mlx_cache_inprocess(source_dir: Path, dest: Path, bits: int,
                              cancel: CancelToken = None) -> None:
    """Unpack, pack, save, and reload-validate into `dest` (this process)."""
    source_dir, dest = Path(source_dir), Path(dest)
    weights = _decode_bark(source_dir / "model.bark")
    _check_cancel(cancel, "Bark cache build")
    _pack(weights, source_dir / "mlx" / "config.json", bits, dest)
    del weights
    _check_cancel(cancel, "Bark cache build")
    _reload_validate(dest, bits)


def run_child(argv: list[str], *, cancel: CancelToken = None,
              timeout_s: float = BUILD_TIMEOUT_S, cwd: Path | None = None) -> str:
    """Run a build child; kill its process group on cancel or timeout.

    Returns stdout. Raises BarkCancelled, or BarkCacheError on a non-zero
    exit or a signal (a jetsam kill reads as SIGKILL).
    """
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=str(cwd) if cwd else None, start_new_session=True)
    deadline = time.monotonic() + timeout_s

    def kill() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()

    while True:
        try:
            out, err = proc.communicate(timeout=0.1)
            break
        except subprocess.TimeoutExpired:
            if is_cancelled(cancel):
                kill()
                raise BarkCancelled("Bark cache build cancelled") from None
            if time.monotonic() > deadline:
                kill()
                raise BarkCacheError(f"Bark cache build timed out after {timeout_s:.0f}s") from None
    if proc.returncode < 0:
        raise BarkCacheError(
            f"Bark cache builder killed by signal {-proc.returncode} (out of memory?); "
            "not falling back to another precision")
    if proc.returncode != 0:
        tail = err.decode(errors="replace").strip().splitlines()[-5:]
        raise BarkCacheError("Bark cache builder failed: " + " | ".join(tail))
    return out.decode(errors="replace")


def build_mlx_cache_subprocess(source_dir: Path, dest: Path, bits: int,
                               cancel: CancelToken = None) -> None:
    """Default builder: ``build_mlx_cache_inprocess`` in a child process."""
    argv = [sys.executable, "-P", "-m", "velora_engine.bark", "build-mlx-cache",
            str(source_dir), str(dest), str(bits)]
    out = run_child(argv, cancel=cancel, cwd=Path(dest).parent)
    log.info("Bark cache builder: %s", out.strip()[-200:])


# --- MLX model ------------------------------------------------------------------


class BarkModel:
    """Bark on MLX. ``decode`` is serialized; call it from one worker thread."""

    runtime = "mlx"
    sample_rate = SAMPLE_RATE

    def __init__(self, model: Any, variant: bm.BundledModel, bits: int, cache_dir: Path,
                 max_piece_s: float = MLX_MAX_PIECE_S) -> None:
        coreml = _vendor_coreml()
        cfg = model.preprocessor_config
        expected = (coreml.WIN, coreml.HOP, coreml.NFFT, 128, SAMPLE_RATE)
        actual = (cfg.win_length, cfg.hop_length, cfg.n_fft, cfg.features, cfg.sample_rate)
        if actual != expected:
            raise BarkIdentityError(f"Bark preprocessor {actual} is not {expected}")
        self.model = model
        self.variant = variant.key
        self.spec = variant
        self.bits = bits
        self.cache_dir = Path(cache_dir)
        self.pad_s = variant.pad_s
        self.max_piece_s = float(max_piece_s)
        self.min_piece_s = min(MLX_MIN_PIECE_S, self.max_piece_s / 2)
        self._frontend = coreml.Frontend(np.asarray(cfg._filterbanks, np.float32))
        self._segments = coreml.segments
        self._lock = threading.Lock()
        self.ready = False

    def warmup(self) -> None:
        self.decode(np.zeros(SAMPLE_RATE, np.float32))
        self.ready = True

    def pieces(self, audio: np.ndarray) -> list[np.ndarray]:
        return self._segments(audio, max_s=self.max_piece_s, min_s=self.min_piece_s)

    def decode(self, audio: Any, *, cancel: CancelToken = None) -> str:
        x = as_mono_16k(audio)
        if x.size == 0:
            return ""
        texts: list[str] = []
        with self._lock:
            for piece in self.pieces(x):
                _check_cancel(cancel, "Bark decode")
                texts.append(_checked_piece_text(piece, self._decode_piece(piece)))
        return " ".join(t for t in texts if t)

    def _decode_piece(self, piece: np.ndarray) -> str:
        import mlx.core as mx

        x = np.concatenate([np.zeros(round(self.pad_s * SAMPLE_RATE), np.float32), piece])
        feats, valid = self._frontend(x)
        if valid < 2:
            return ""
        result = self.model.generate(mx.array(feats[:valid][None]))[0]
        return result.text.strip()


def load_bark(source_dir: Path, bits: int, *, cache_root: Path | None = None,
              cancel: CancelToken = None, builder: Builder | None = None,
              warmup: bool = True, max_piece_s: float = MLX_MAX_PIECE_S) -> BarkModel:
    """Load pinned Bark (3.0 or Clean) from `source_dir` at `bits` precision.

    `source_dir` holds ``model.bark`` and ``mlx/config.json`` (Hub layout; a
    ``bundled_models`` import qualifies). The first load per identity builds
    the packed cache (~13 s on an M5 Max, ~3 GB peak in the child); later
    loads read it directly. Returns only after a warmup decode unless
    ``warmup=False``. The model's ``bits`` always equals `bits`.
    """
    _require_apple_silicon()
    cache_dir, variant = ensure_mlx_cache(Path(source_dir), bits, cache_root=cache_root,
                                          cancel=cancel, builder=builder)
    _check_cancel(cancel, "Bark load")
    try:
        mlx_model = load_packed(cache_dir, bits)
    except Exception as exc:  # noqa: BLE001
        raise BarkCacheError(f"Bark cache {cache_dir} failed to load: {exc}") from exc
    bark = BarkModel(mlx_model, variant, bits, cache_dir, max_piece_s=max_piece_s)
    if warmup:
        bark.warmup()
    return bark


# --- Core ML (ANE) ----------------------------------------------------------------


def _require_coremltools() -> Any:
    _require_apple_silicon()
    try:
        import coremltools as ct
    except Exception as exc:  # noqa: BLE001 — absent on Python 3.14 (no wheel)
        raise BarkUnavailable(
            f"coremltools is unavailable on Python {sys.version_info.major}."
            f"{sys.version_info.minor} ({exc}); the Bark ANE runtime needs it") from exc
    return ct


def coreml_identity(model: bm.BundledModel, records: dict[str, dict[str, Any]],
                    coremltools_version: str) -> dict[str, Any]:
    return {
        "format": "velora-bark-coreml",
        "version": CACHE_FORMAT_VERSION,
        "variant": model.key,
        "repo": model.repo,
        "revision": model.revision,
        "source": records,
        "coremltools": coremltools_version,
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
    }


def _published_coreml(directory: Path, identity: dict[str, Any]) -> bool:
    try:
        manifest = json.loads((directory / COREML_MANIFEST).read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(manifest, dict) or manifest.get("identity") != identity:
        return False
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        return False
    for relative, record in files.items():
        if not isinstance(relative, str) or ".." in Path(relative).parts or Path(relative).is_absolute():
            return False
        path = directory / relative
        if not _cache_file_matches(path, record, directory):
            return False
    return True


def _compiled_files(compiled: Path) -> dict[str, dict[str, Any]]:
    root = compiled.parent
    return {str(p.relative_to(root)): {"size": p.stat().st_size, "sha256": bm.sha256_file(p)}
            for p in sorted(compiled.rglob("*")) if p.is_file() and not p.is_symlink()}


@contextmanager
def _shared_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(path, "a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


Compiler = Callable[[Path, Path], Any]


def ensure_coreml_compiled(source_dir: Path, cache_dir: Path, *, cancel: CancelToken = None,
                           compiler: Compiler | None = None,
                           coremltools_version: str | None = None) -> tuple[Path, bm.BundledModel, Path]:
    """Return (stable compiled .mlmodelc path, variant, ane source dir).

    The path depends only on the identity (source hashes, coremltools
    version, macOS version), so it is the same on every launch.
    """
    model, ane_dir, records = identify_source(Path(source_dir), "coreml", cancel)
    if compiler is None or coremltools_version is None:
        ct = _require_coremltools()
        coremltools_version = coremltools_version or ct.__version__
        if compiler is None:
            def compiler(src: Path, dst: Path) -> Any:
                return ct.models.utils.compile_model(str(src), destination_path=str(dst))
    identity = coreml_identity(model, records, coremltools_version)
    cache_dir = Path(cache_dir)
    final = cache_dir / f"{model.key}--{_digest(identity)[:16]}"
    compiled = final / _COMPILED_NAME
    if _published_coreml(final, identity):
        return compiled, model, ane_dir

    cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with exclusive_lock(cache_dir / ".compile.lock"):
        if _published_coreml(final, identity):
            return compiled, model, ane_dir
        for stale in cache_dir.glob(f".{model.key}--*.tmp-*"):
            shutil.rmtree(stale, ignore_errors=True)
        _check_cancel(cancel, "Bark Core ML compile")
        temp = Path(tempfile.mkdtemp(prefix=f".{final.name}.tmp-", dir=cache_dir))
        started = time.perf_counter()
        try:
            try:
                compiler(ane_dir / "BarkEncoder.mlpackage", temp / _COMPILED_NAME)
            except Exception as exc:  # noqa: BLE001
                raise BarkCacheError(f"Core ML compile of Bark failed: {exc}") from exc
            _check_cancel(cancel, "Bark Core ML compile")
            if not (temp / _COMPILED_NAME / "coremldata.bin").is_file():
                raise BarkCacheError("Core ML compile produced no coremldata.bin")
            (temp / COREML_MANIFEST).write_text(json.dumps(
                {"identity": identity, "files": _compiled_files(temp / _COMPILED_NAME),
                 "compile_seconds": round(time.perf_counter() - started, 2)}, indent=2) + "\n")
            os.chmod(temp, 0o700)
            if os.path.lexists(final):
                shutil.rmtree(final)  # ours (digest-named in our dir) but incomplete
            rename_no_replace(temp, final)
            log.info("compiled Bark Core ML encoder to %s in %.1fs",
                     compiled, time.perf_counter() - started)
        finally:
            if temp.exists():
                shutil.rmtree(temp, ignore_errors=True)
        # Never prune another engine identity while its encoders may be live.
    return compiled, model, ane_dir


class BarkCoreMLModel:
    """Bark with its encoder on Core ML; the vendored numpy decoder on CPU."""

    runtime = "coreml"
    sample_rate = SAMPLE_RATE

    def __init__(self, encoders: dict[int, Any], variant: bm.BundledModel, ane_dir: Path,
                 compiled_path: Path, compute_units: str) -> None:
        coreml = _vendor_coreml()
        missing = set(coreml.WINDOWS) - set(encoders)
        if missing:
            raise BarkCacheError(f"no Core ML encoder for windows {sorted(missing)}")

        def run(window: int, feats: np.ndarray, mask: np.ndarray) -> Any:
            return encoders[window].predict(
                {"features": feats.astype(np.float16), "mask": mask})["encoded"]

        self.encoders = encoders
        self.variant = variant.key
        self.spec = variant
        self.compiled_path = Path(compiled_path)
        self.compute_units = compute_units
        self.pad_s = variant.pad_s
        self.windows = tuple(coreml.WINDOWS)
        self.max_piece_s = max(coreml.WINDOWS) - variant.pad_s
        self._segments = coreml.segments
        self._tr = coreml.Transcriber(str(ane_dir), encoder=run, pad_s=variant.pad_s)
        self._lock = threading.Lock()
        self.ready = False

    def warmup(self, cancel: CancelToken = None) -> None:
        """Run every encoder window once so the first dictation pays no
        on-device specialization."""
        with self._lock:
            for window in self.windows:
                _check_cancel(cancel, "Bark Core ML warmup")
                seconds = min(1.0, window - self.pad_s) if window == min(self.windows) \
                    else window - self.pad_s - 0.5
                try:
                    self._tr._piece(np.zeros(int(seconds * SAMPLE_RATE), np.float32))
                except FloatingPointError as exc:
                    raise BarkCacheError(f"Core ML warmup of w{window} failed: {exc}") from exc
        self.ready = True

    def pieces(self, audio: np.ndarray) -> list[np.ndarray]:
        return self._segments(audio, max_s=self.max_piece_s)

    def decode(self, audio: Any, *, cancel: CancelToken = None) -> str:
        x = as_mono_16k(audio)
        if x.size == 0:
            return ""
        texts: list[str] = []
        with self._lock:
            for piece in self.pieces(x):
                _check_cancel(cancel, "Bark decode")
                try:
                    ids = self._tr._piece(piece)
                except FloatingPointError as exc:
                    raise BarkError(f"Core ML encoder output was not finite: {exc}") from exc
                texts.append(_checked_piece_text(piece, self._tr.dec.detok(ids)))
        return " ".join(t for t in texts if t)


def load_bark_coreml(source_dir: Path, cache_dir: Path, *, compute_units: str = "ane",
                     cancel: CancelToken = None, compiler: Compiler | None = None,
                     warmup: bool = True) -> BarkCoreMLModel:
    """Load pinned Bark's Core ML package with its encoder on `compute_units`.

    `source_dir` is the repository root (``coreml/ane/...``) or the ``ane``
    folder. The compiled encoder lives at a stable path under `cache_dir`.
    Core ML decides operation placement: "ane" requests CPU+Neural Engine
    and cannot guarantee every op runs there. First use on a Mac can take
    minutes (upstream README). Returns only after warmup unless
    ``warmup=False``; call it off the dictation thread.
    """
    if compute_units not in COREML_UNITS:
        raise ValueError(f"compute_units must be one of {COREML_UNITS}")
    ct = _require_coremltools()
    units = {"ane": ct.ComputeUnit.CPU_AND_NE, "gpu": ct.ComputeUnit.CPU_AND_GPU,
             "cpu": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL}[compute_units]
    compiled, variant, ane_dir = ensure_coreml_compiled(
        Path(source_dir), Path(cache_dir), cancel=cancel, compiler=compiler,
        coremltools_version=ct.__version__)
    windows = _vendor_coreml().WINDOWS
    # Shared lock: explicit storage removal cannot delete this directory
    # while Core ML loads and specializes from it.
    with _shared_lock(Path(cache_dir) / ".compile.lock"):
        if not compiled.is_dir():
            raise BarkCacheError(f"compiled Bark encoder {compiled} disappeared")
        _check_cancel(cancel, "Bark Core ML load")
        try:
            encoders = {w: ct.models.CompiledMLModel(str(compiled), compute_units=units,
                                                     function_name=f"w{w}")
                        for w in windows}
        except Exception as exc:  # noqa: BLE001
            raise BarkCacheError(f"Core ML could not load {compiled}: {exc}") from exc
        model = BarkCoreMLModel(encoders, variant, ane_dir, compiled, compute_units)
        if warmup:
            model.warmup(cancel)
    return model


# --- child entry point --------------------------------------------------------------


def _child_main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[0] != "build-mlx-cache":
        print("usage: python -m velora_engine.bark build-mlx-cache SOURCE DEST BITS",
              file=sys.stderr)
        return 2
    _, source, dest, bits = argv
    # The vendored loader imports torch when installed; that cost stays in
    # this child. (Hiding torch via sys.modules breaks scipy's array API.)
    started = time.perf_counter()
    try:
        build_mlx_cache_inprocess(Path(source), Path(dest), int(bits))
    except MemoryError:
        print("out of memory", file=sys.stderr)
        return 3
    import resource

    print(json.dumps({"ok": True, "seconds": round(time.perf_counter() - started, 2),
                      "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}))
    return 0


if __name__ == "__main__":
    sys.exit(_child_main(sys.argv[1:]))
