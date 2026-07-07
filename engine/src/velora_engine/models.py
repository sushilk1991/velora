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
