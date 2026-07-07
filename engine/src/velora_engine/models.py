"""Model registry + download management (huggingface_hub)."""

from __future__ import annotations

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
        id="mlx-community/parakeet-tdt-0.6b-v2",
        kind="stt",
        backend="parakeet",
        size="2.3 GB",
        description="Default. Fastest and most accurate English STT; streams during recording.",
    ),
    ModelInfo(
        id="mlx-community/whisper-large-v3-turbo",
        kind="stt",
        backend="whisper",
        size="1.5 GB",
        description="Fallback. Multilingual; batch transcription with hallucination guard.",
    ),
    ModelInfo(
        id="mlx-community/distil-whisper-large-v3",
        kind="stt",
        backend="whisper",
        size="1.4 GB",
        description="Alternative Whisper distil model; fast, slightly rougher output.",
    ),
    ModelInfo(
        id="mlx-community/Qwen3-4B-Instruct-2507-4bit",
        kind="cleanup",
        backend="mlx-lm",
        size="2.1 GB",
        description="Default cleanup/formatting LLM (4-bit instruct).",
    ),
]

_BY_ID = {m.id: m for m in REGISTRY}


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
