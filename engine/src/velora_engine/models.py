"""Model registry + download management (huggingface_hub)."""

from __future__ import annotations

import functools
import hashlib
import logging
import json
import struct
import zipfile
import re
import shutil
import time
from dataclasses import asdict, dataclass
from pathlib import Path

log = logging.getLogger("velora.models")

TRANSCRIBE_CPP_Q8_MODEL = "handy-computer/whisper-large-v3-turbo-gguf"
TRANSCRIBE_CPP_Q8_REVISION = "d222c9f621c1128299248f2ded4d8a1820519780"
TRANSCRIBE_CPP_Q8_SHA256 = "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448"
# Registry sizes are decimal gigabytes of download (Hub byte counts).
_BYTES_PER_GB = 10**9
_SINGLE_FILE_MODELS = {
    TRANSCRIBE_CPP_Q8_MODEL: "whisper-large-v3-turbo-Q8_0.gguf",
}
_SINGLE_FILE_REVISIONS = {
    TRANSCRIBE_CPP_Q8_MODEL: TRANSCRIBE_CPP_Q8_REVISION,
}


@dataclass(frozen=True)
class ModelInfo:
    id: str
    name: str  # short title for the Models pane ("Whisper Turbo")
    kind: str  # "stt" | "cleanup"
    backend: str  # "parakeet" | "whisper" | "transcribe-cpp" | "mlx-lm"
    size: str  # human-readable download size
    description: str


REGISTRY: list[ModelInfo] = [
    ModelInfo(
        id="mlx-community/whisper-large-v3-turbo",
        name="Whisper Turbo",
        kind="stt",
        backend="whisper",
        size="1.6 GB",
        description=(
            "Fast, and understands 99 languages, including Hindi, Indian "
            "English, Mandarin, Arabic, Spanish and French."
        ),
    ),
    ModelInfo(
        id=TRANSCRIBE_CPP_Q8_MODEL,
        name="Whisper Turbo Q8 (Experimental)",
        kind="stt",
        backend="transcribe-cpp",
        size="0.9 GB",
        description=(
            "Faster and smaller than Whisper Turbo, with the same languages. "
            "Still in testing."
        ),
    ),
    ModelInfo(
        id="mlx-community/whisper-large-v3-mlx",
        name="Whisper Large",
        kind="stt",
        backend="whisper",
        size="3.1 GB",
        description=(
            "Most accurate with strong accents and background noise. Slower, "
            "and twice the download."
        ),
    ),
    ModelInfo(
        id="knownsense/whisper-hindi-apex-mlx",
        name="Whisper Hinglish",
        kind="stt",
        backend="whisper",
        size="1.6 GB",
        description=(
            "Best when you mix Hindi and English. Writes Hindi in English "
            "letters."
        ),
    ),
    ModelInfo(
        id="mlx-community/parakeet-tdt-0.6b-v3",
        name="Parakeet v3",
        kind="stt",
        backend="parakeet",
        size="2.5 GB",
        description=(
            "Fastest. English and 24 European languages. No Hindi, Mandarin "
            "or Arabic."
        ),
    ),
    ModelInfo(
        id="mlx-community/parakeet-tdt-0.6b-v2",
        name="Parakeet v2",
        kind="stt",
        backend="parakeet",
        size="2.5 GB",
        description="Fastest for English. English only.",
    ),
    ModelInfo(
        id="mlx-community/whisper-large-v3-turbo-q4",
        name="Whisper Turbo Small",
        kind="stt",
        backend="whisper",
        size="0.5 GB",
        description="Smallest download, 99 languages. Less accurate.",
    ),
    # --- cleanup / formatting LLMs, smallest first ---
    ModelInfo(
        id="mlx-community/Qwen3.5-2B-MLX-4bit",
        name="Compact",
        kind="cleanup",
        backend="mlx-lm",
        size="1.7 GB",
        description=(
            "For Macs with 8 GB of memory. Uses the least memory and disk."
        ),
    ),
    ModelInfo(
        id="mlx-community/Qwen3.5-4B-MLX-4bit",
        name="Balanced",
        kind="cleanup",
        backend="mlx-lm",
        size="3.1 GB",
        description=(
            "For Macs with 16 GB of memory. The Quality model in about half "
            "the memory."
        ),
    ),
    ModelInfo(
        id="mlx-community/Qwen3.5-4B-MLX-8bit",
        name="Quality",
        kind="cleanup",
        backend="mlx-lm",
        size="5.2 GB",
        description=(
            "For Macs with 24 GB of memory or more. The cleanest writing."
        ),
    ),
]

_BY_ID = {m.id: m for m in REGISTRY}

# Cleanup-model tiers by physical RAM (GB), largest that fits first.
# STT default stays whisper-turbo regardless — it's the same 1.5 GB everywhere.
_CLEANUP_TIERS: list[tuple[int, str]] = [
    (24, "mlx-community/Qwen3.5-4B-MLX-8bit"),
    (14, "mlx-community/Qwen3.5-4B-MLX-4bit"),
    (0, "mlx-community/Qwen3.5-2B-MLX-4bit"),
]

# Writing models a previous build shipped as a RAM-tier default, each mapped to
# its replacement in the SAME size class — a user who took a small model for
# speed and disk keeps a small model. `Config` rewrites a matching
# `cleanup_model` once (guarded by a config marker), the server's normal
# startup path downloads the replacement with the usual progress UI, and the
# old weights are pruned only after the replacement has actually loaded.
SUPERSEDED_CLEANUP_MODELS: dict[str, str] = {
    "mlx-community/Qwen3-1.7B-8bit": "mlx-community/Qwen3.5-2B-MLX-4bit",
    "mlx-community/Qwen3-4B-Instruct-2507-4bit": "mlx-community/Qwen3.5-4B-MLX-4bit",
}


@functools.lru_cache(maxsize=1)
def physical_ram_gb() -> float:
    """Total physical RAM in GB (macOS `hw.memsize`); 16.0 if it can't be read.

    Cached: RAM doesn't change at runtime and this shells out to `sysctl`, which
    shouldn't run on the event loop for every `status` request."""
    import subprocess

    try:
        out = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], timeout=2)
        return int(out.strip()) / (1024**3)
    except Exception:  # noqa: BLE001 — detection is best-effort
        return 16.0


def recommended_cleanup_model(ram_gb: float | None = None) -> str:
    """Pick the best cleanup model that comfortably fits this Mac's RAM."""
    ram = ram_gb if ram_gb is not None else physical_ram_gb()
    for min_gb, model_id in _CLEANUP_TIERS:
        if ram >= min_gb:
            return model_id
    return _CLEANUP_TIERS[-1][1]


def registry_payload() -> list[dict[str, str]]:
    return [asdict(m) for m in REGISTRY]


def lookup(model_id: str) -> ModelInfo | None:
    return _BY_ID.get(model_id)


@functools.lru_cache(maxsize=8)
def _verified_sha256(path: str, size: int, mtime_ns: int, expected: str) -> bool:
    """Hash an immutable Hub artifact once per process/stat identity."""
    del size, mtime_ns  # cache-key inputs; the path is streamed below
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == expected


def _single_file_is_valid(model_id: str, path: str) -> bool:
    if model_id != TRANSCRIBE_CPP_Q8_MODEL:
        return True
    try:
        stat = Path(path).stat()
        return _verified_sha256(
            str(Path(path).resolve()), stat.st_size, stat.st_mtime_ns,
            TRANSCRIBE_CPP_Q8_SHA256,
        )
    except OSError:
        return False


# Bound legacy tensor-header JSON parsing before reading data.
_MAX_SAFE_HEADER = 100_000_000
_SAFE_LENGTH_BYTES = 8
_WHISPER_DIMENSIONS = (
    "n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
    "n_vocab", "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer",
)


def _blob_valid(path: Path) -> bool:
    """Verify Hub symlink identities when available; plain legacy files lack digests."""
    from .download_cache import _File, _file_valid

    if not path.is_file() or path.stat().st_size == 0:
        return False
    if not path.is_symlink():
        return True
    digest = path.resolve().name
    if re.fullmatch(r"[0-9a-f]{64}", digest):
        return _file_valid(path, _File(path.name, path.stat().st_size, digest, "sha256"))
    if re.fullmatch(r"[0-9a-f]{40}", digest):
        return _file_valid(path, _File(path.name, path.stat().st_size, digest, "git-sha1"))
    return False


def _weights_valid(path: Path) -> bool:
    # Legacy cache checks format/extent plus available blob digests, not model
    # tensor semantics. The live backend load remains the adoption gate.
    if not _blob_valid(path):
        return False
    if path.suffix == ".npz":
        with zipfile.ZipFile(path) as archive:
            return bool(archive.namelist()) and archive.testzip() is None
    with path.open("rb") as handle:
        length_bytes = handle.read(_SAFE_LENGTH_BYTES)
        if len(length_bytes) != _SAFE_LENGTH_BYTES:
            return False
        length = struct.unpack("<Q", length_bytes)[0]
        if not 0 < length <= min(_MAX_SAFE_HEADER, path.stat().st_size - _SAFE_LENGTH_BYTES):
            return False
        header = json.loads(handle.read(length))
    data_size = path.stat().st_size - length - _SAFE_LENGTH_BYTES
    end = 0
    tensors = []
    for name, tensor in header.items():
        if name == "__metadata__":
            continue
        start, stop = tensor["data_offsets"]
        if not isinstance(tensor["shape"], list) or not tensor["dtype"]:
            return False
        if not isinstance(start, int) or not isinstance(stop, int) or start < 0 or stop < start:
            return False
        tensors.append((start, stop))
    for start, stop in sorted(tensors):
        if start != end:
            return False
        end = stop
    return bool(tensors) and end == data_size


def _json_valid(path: Path) -> bool:
    return _blob_valid(path) and isinstance(json.loads(path.read_text()), dict)


def _legacy_valid(model_id: str, path: str) -> bool:
    """Backend-required artifact check for pre-manifest installed snapshots."""
    root = Path(path)
    info = lookup(model_id)
    backend = info.backend if info else "mlx-lm"
    try:
        if not _json_valid(root / "config.json"):
            return False
        config = json.loads((root / "config.json").read_text())
        if backend == "whisper":
            if any(not isinstance(config.get(key), int) or config[key] <= 0 for key in _WHISPER_DIMENSIONS):
                return False
            weights = root / "weights.safetensors"
            if not weights.exists():
                weights = root / "weights.npz"
            return _weights_valid(weights)
        if backend == "parakeet":
            if not config.get("target") or not config.get("encoder") or not config.get("preprocessor"):
                return False
            return _weights_valid(root / "model.safetensors")
        if not config.get("model_type"):
            return False
        if not _json_valid(root / "tokenizer_config.json"):
            return False
        tokenizer = root / "tokenizer.json"
        if tokenizer.exists():
            if not _json_valid(tokenizer):
                return False
        elif not _blob_valid(root / "tokenizer.model"):
            return False
        index = root / "model.safetensors.index.json"
        if index.exists():
            if not _json_valid(index):
                return False
            mapping = json.loads(index.read_text())["weight_map"]
            names = set(mapping.values())
            if not names:
                return False
            weights = []
            for name in names:
                candidate = Path(name)
                if candidate.is_absolute() or ".." in candidate.parts:
                    return False
                weights.append(root / candidate)
        else:
            weights = list(root.glob("model*.safetensors"))
            # Shard numbering provides a completeness check even without an index.
            for weight in weights:
                match = re.fullmatch(r"model-(\d+)-of-(\d+)\.safetensors", weight.name)
                if match and len(weights) != int(match.group(2)):
                    return False
        return bool(weights) and all(_weights_valid(weight) for weight in weights)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile):
        return False


def _owned_cached(model_id: str) -> str | None:
    from .download_cache import _Cache, _cache_root

    try:
        cached = _Cache(_cache_root(), model_id)._cached()
        return cached[0] if cached else None
    except (OSError, ValueError):
        return None


def _legacy_cached(model_id: str) -> str | None:
    from huggingface_hub import hf_hub_download, snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    try:
        filename = _SINGLE_FILE_MODELS.get(model_id)
        if filename:
            path = hf_hub_download(repo_id=model_id, filename=filename,
                                   revision=_SINGLE_FILE_REVISIONS[model_id], local_files_only=True)
            if not _single_file_is_valid(model_id, path):
                raise ValueError("legacy pinned artifact integrity failed")
            return path
        path = snapshot_download(repo_id=model_id, local_files_only=True)
        if not _legacy_valid(model_id, path):
            raise ValueError("legacy required artifact integrity failed")
        return path
    except LocalEntryNotFoundError:
        return None


def ensure_downloaded(model_id: str) -> str:
    """Return the local snapshot path, downloading only when not cached.

    Local-first: a complete cached snapshot is used without any network
    request — the Hub is only contacted when files are actually missing.
    """
    local_path = Path(model_id).expanduser()
    if local_path.exists():
        resolved = str(local_path.resolve())
        log.info("model loaded from pinned local path %s", resolved)
        return resolved

    # Recovery downloads remain usable through existing synchronous model APIs.
    owned = _owned_cached(model_id)
    if owned is not None:
        return owned

    from huggingface_hub import hf_hub_download, snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    filename = _SINGLE_FILE_MODELS.get(model_id)
    if filename is not None:
        revision = _SINGLE_FILE_REVISIONS[model_id]
        try:
            path = hf_hub_download(
                repo_id=model_id,
                filename=filename,
                revision=revision,
                local_files_only=True,
            )
            if _single_file_is_valid(model_id, path):
                log.info("model %s found in verified local cache at %s", model_id, path)
                return path
            log.warning("cached model %s failed SHA-256 verification; replacing it", model_id)
        except LocalEntryNotFoundError:
            pass
        log.info("downloading model %s artifact %s ...", model_id, filename)
        t0 = time.perf_counter()
        path = hf_hub_download(
            repo_id=model_id, filename=filename, revision=revision,
            force_download=True,
        )
        if not _single_file_is_valid(model_id, path):
            raise OSError(f"downloaded model {model_id} failed SHA-256 verification")
        log.info("model %s ready at %s (%.1fs)", model_id, path, time.perf_counter() - t0)
        return path

    try:
        path = snapshot_download(repo_id=model_id, local_files_only=True)
        if _legacy_valid(model_id, path):
            log.info("model %s found in local cache at %s", model_id, path)
            return path
        log.warning("model %s has an incomplete or corrupt legacy cache", model_id)
    except LocalEntryNotFoundError:
        pass

    log.info("downloading model %s ...", model_id)
    t0 = time.perf_counter()
    path = snapshot_download(repo_id=model_id)
    if not _legacy_valid(model_id, path):
        raise OSError("Model cache integrity failed. Required model files are missing or corrupt.")
    log.info("model %s ready at %s (%.1fs)", model_id, path, time.perf_counter() - t0)
    return path


def is_cached(model_id: str) -> bool:
    """Probe owned manifests or backend-required legacy files without network."""
    try:
        return _owned_cached(model_id) is not None or _legacy_cached(model_id) is not None
    except Exception:  # noqa: BLE001 — probe must never raise
        return False


def expected_bytes(model_id: str) -> int | None:
    """Approximate download size from the registry ("1.6 GB" → bytes).

    GB is decimal, like the Hub's byte counts and the on-disk cache that
    download progress divides by this.
    """
    info = lookup(model_id)
    if info is None:
        return None
    m = re.match(r"([\d.]+)\s*GB", info.size or "")
    return int(float(m.group(1)) * _BYTES_PER_GB) if m else None


def _repo_cache_dir(model_id: str) -> Path | None:
    """Hub cache directory for a repo id, or None if the constant moved."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
    except ImportError:  # pragma: no cover — constant moved
        return None
    return Path(HF_HUB_CACHE) / f"models--{model_id.replace('/', '--')}"


def remove_from_cache(model_id: str) -> int:
    """Delete a superseded model's Hub cache dir; returns bytes reclaimed.

    Hard-gated to `SUPERSEDED_CLEANUP_MODELS`: this deletes multi-GB weights,
    so it must be impossible to point at an arbitrary repo — including the
    model the user is currently running. Callers must additionally wait until
    the replacement has loaded (see `_prune_superseded_models`), so a failed
    upgrade never leaves a user with no writing model at all.
    """
    if model_id not in SUPERSEDED_CLEANUP_MODELS:
        raise ValueError(f"not a superseded model, refusing to delete: {model_id}")
    repo_dir = _repo_cache_dir(model_id)
    if repo_dir is None or not repo_dir.is_dir():
        return 0
    freed = cached_bytes(model_id)
    shutil.rmtree(repo_dir, ignore_errors=True)
    return 0 if repo_dir.is_dir() else freed


def cached_bytes(model_id: str) -> int:
    """Bytes currently on disk in the hub cache for this repo — includes
    in-flight `.incomplete` blobs, so it grows during a download and drives
    the first-run progress UI."""
    repo_dir = _repo_cache_dir(model_id)
    if repo_dir is None:
        return 0
    total = 0
    seen = set()
    if repo_dir.is_dir():
        for p in repo_dir.rglob("*"):
            try:
                if p.is_file():
                    stat = p.stat()
                    identity = (stat.st_dev, stat.st_ino)
                    if identity in seen:
                        continue
                    seen.add(identity)
                    total += stat.st_size
            except OSError:  # pragma: no cover — racing the downloader
                pass
    return total
