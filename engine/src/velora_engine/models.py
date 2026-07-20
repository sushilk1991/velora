"""Model registry + download management (huggingface_hub)."""

from __future__ import annotations

import functools
import hashlib
import logging
import re
import time
from dataclasses import asdict, dataclass
from pathlib import Path

log = logging.getLogger("velora.models")

TRANSCRIBE_CPP_Q8_MODEL = "handy-computer/whisper-large-v3-turbo-gguf"
TRANSCRIBE_CPP_Q8_REVISION = "d222c9f621c1128299248f2ded4d8a1820519780"
TRANSCRIBE_CPP_Q8_SHA256 = "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448"
_SINGLE_FILE_MODELS = {
    TRANSCRIBE_CPP_Q8_MODEL: "whisper-large-v3-turbo-Q8_0.gguf",
}
_SINGLE_FILE_REVISIONS = {
    TRANSCRIBE_CPP_Q8_MODEL: TRANSCRIBE_CPP_Q8_REVISION,
}


@dataclass(frozen=True)
class ModelInfo:
    id: str
    kind: str  # "stt" | "cleanup"
    backend: str  # "parakeet" | "whisper" | "transcribe-cpp" | "mlx-lm"
    size: str  # human-readable download size
    description: str


REGISTRY: list[ModelInfo] = [
    ModelInfo(
        id="mlx-community/whisper-large-v3-turbo",
        kind="stt",
        backend="whisper",
        size="1.6 GB",
        description=(
            "Default — fast & multilingual (99 languages incl. Hindi, Indian "
            "English, Mandarin, Arabic, Spanish, French). Best all-round balance."
        ),
    ),
    ModelInfo(
        id=TRANSCRIBE_CPP_Q8_MODEL,
        kind="stt",
        backend="transcribe-cpp",
        size="0.85 GB",
        description=(
            "Experimental — faster multilingual Whisper via transcribe.cpp "
            "(Q8, Hindi and Indian English)."
        ),
    ),
    ModelInfo(
        id="mlx-community/whisper-large-v3-mlx",
        kind="stt",
        backend="whisper",
        size="3.1 GB",
        description=(
            "Highest accuracy. Full Whisper large-v3 — same languages as the "
            "default but more accurate on hard accents and noise. Slower, larger."
        ),
    ),
    ModelInfo(
        id="knownsense/whisper-hindi-apex-mlx",
        kind="stt",
        backend="whisper",
        size="1.6 GB",
        description=(
            "Hindi & Hinglish specialist (Romanized output). Fine-tuned on 700+ "
            "hours of Hindi/English code-switching — best for heavy Hinglish."
        ),
    ),
    ModelInfo(
        id="mlx-community/parakeet-tdt-0.6b-v3",
        kind="stt",
        backend="parakeet",
        size="2.5 GB",
        description=(
            "Fastest — live streaming preview while you speak. English + 24 "
            "European languages (no Hindi/Mandarin/Arabic)."
        ),
    ),
    ModelInfo(
        id="mlx-community/parakeet-tdt-0.6b-v2",
        kind="stt",
        backend="parakeet",
        size="2.3 GB",
        description="Fastest English-only, live streaming. Lowest latency for pure English.",
    ),
    ModelInfo(
        id="mlx-community/whisper-large-v3-turbo-q4",
        kind="stt",
        backend="whisper",
        size="0.5 GB",
        description="Smallest multilingual. 4-bit turbo — least disk/RAM, roughest quality.",
    ),
    # --- cleanup / formatting LLMs, smallest first ---
    ModelInfo(
        id="mlx-community/Qwen3-1.7B-8bit",
        kind="cleanup",
        backend="mlx-lm",
        size="1.9 GB",
        description=(
            "Compact — for 8 GB Macs. Qwen3-1.7B (8-bit): lightest RAM/disk, still "
            "handles punctuation and filler cleanup well. Recommended on low-memory Macs."
        ),
    ),
    ModelInfo(
        id="mlx-community/Qwen3-4B-Instruct-2507-4bit",
        kind="cleanup",
        backend="mlx-lm",
        size="2.3 GB",
        description=(
            "Balanced — for 16 GB Macs. Qwen3-4B (4-bit): strong cleanup at about "
            "half the memory of the 8-bit build."
        ),
    ),
    ModelInfo(
        id="mlx-community/Qwen3.5-4B-MLX-8bit",
        kind="cleanup",
        backend="mlx-lm",
        size="4.3 GB",
        description=(
            "Quality — for 24 GB+ Macs. Qwen3.5-4B (8-bit): highest-precision "
            "cleanup and best instruction-following."
        ),
    ),
]

_BY_ID = {m.id: m for m in REGISTRY}

# Cleanup-model tiers by physical RAM (GB), largest that fits first.
# STT default stays whisper-turbo regardless — it's the same 1.5 GB everywhere.
_CLEANUP_TIERS: list[tuple[int, str]] = [
    (24, "mlx-community/Qwen3.5-4B-MLX-8bit"),
    (14, "mlx-community/Qwen3-4B-Instruct-2507-4bit"),
    (0, "mlx-community/Qwen3-1.7B-8bit"),
]


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


def ensure_downloaded(model_id: str) -> str:
    """Return the local snapshot path, downloading only when not cached.

    Local-first: a complete cached snapshot is used without any network
    request — the Hub is only contacted when files are actually missing.
    """
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
        log.info("model %s found in local cache at %s", model_id, path)
        return path
    except LocalEntryNotFoundError:
        pass

    log.info("downloading model %s ...", model_id)
    t0 = time.perf_counter()
    path = snapshot_download(repo_id=model_id)
    log.info("model %s ready at %s (%.1fs)", model_id, path, time.perf_counter() - t0)
    return path


def is_cached(model_id: str) -> bool:
    """True when a complete snapshot exists locally (no network touched)."""
    from huggingface_hub import hf_hub_download, snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    try:
        filename = _SINGLE_FILE_MODELS.get(model_id)
        if filename is not None:
            path = hf_hub_download(
                repo_id=model_id,
                filename=filename,
                revision=_SINGLE_FILE_REVISIONS[model_id],
                local_files_only=True,
            )
            return _single_file_is_valid(model_id, path)
        snapshot_download(repo_id=model_id, local_files_only=True)
        return True
    except LocalEntryNotFoundError:
        return False
    except Exception:  # noqa: BLE001 — probe must never raise
        return False


def expected_bytes(model_id: str) -> int | None:
    """Approximate download size from the registry ("1.6 GB" → bytes)."""
    info = lookup(model_id)
    if info is None:
        return None
    m = re.match(r"([\d.]+)\s*GB", info.size or "")
    return int(float(m.group(1)) * 1024**3) if m else None


def cached_bytes(model_id: str) -> int:
    """Bytes currently on disk in the hub cache for this repo — includes
    in-flight `.incomplete` blobs, so it grows during a download and drives
    the first-run progress UI."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
    except ImportError:  # pragma: no cover — constant moved
        return 0
    repo_dir = Path(HF_HUB_CACHE) / f"models--{model_id.replace('/', '--')}"
    total = 0
    if repo_dir.is_dir():
        for p in repo_dir.rglob("*"):
            try:
                if p.is_file():
                    total += p.stat().st_size
            except OSError:  # pragma: no cover — racing the downloader
                pass
    return total
