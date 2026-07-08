"""Model registry + download management (huggingface_hub)."""

from __future__ import annotations

import functools
import logging
import time
from dataclasses import asdict, dataclass

log = logging.getLogger("velora.models")


@dataclass(frozen=True)
class ModelInfo:
    id: str
    kind: str  # "stt" | "cleanup"
    backend: str  # "parakeet" | "whisper" | "mlx-lm"
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


def ensure_downloaded(model_id: str) -> str:
    """Return the local snapshot path, downloading only when not cached.

    Local-first: a complete cached snapshot is used without any network
    request — the Hub is only contacted when files are actually missing.
    """
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

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
