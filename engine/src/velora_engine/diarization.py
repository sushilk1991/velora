"""Offline speaker diarization for the meeting pipeline (sherpa-onnx).

Splits the remote/system-audio track of a meeting into per-speaker turns so a
multi-person call reads "Speaker 1 / Speaker 2" instead of one monolithic
"Them". Everything runs on-device: pyannote segmentation-3.0 + NeMo titanet
(both ONNX, CPU) — chosen by a measured spike over the alternatives because
titanet keeps peak RSS flat (~530 MB on meeting-length audio) where the
3D-Speaker embedding models grow past 4 GB, which would sink a 16 GB Mac.
Speed: ~2 s per audio-minute at 2 threads (more threads measured slower).

Models (~46 MB total) download once to ``~/.velora/models/diarization`` from
the sherpa-onnx GitHub releases, sha256-pinned.
"""
from __future__ import annotations

import logging
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Callable

import numpy as np

from .config import velora_home

log = logging.getLogger("velora.diarization")


def models_dir() -> Path:
    # Resolved lazily: tests override the home via the VELORA_HOME env var.
    return velora_home() / "models" / "diarization"

_SEG_NAME = "pyannote-segmentation-3-0.onnx"
_SEG_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
)
_SEG_TAR_MEMBER = "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
_SEG_SHA256 = "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"

_EMB_NAME = "nemo_en_titanet_small.onnx"
_EMB_URL = (
    # "recongition" is not a typo here — it is the real tag name upstream.
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "speaker-recongition-models/nemo_en_titanet_small.onnx"
)
_EMB_SHA256 = "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e"

DOWNLOAD_BYTES = 6_900_000 + 40_257_283  # tarball + titanet, for progress UI

# Auto speaker count with these settings beat fixed-count in every spike test:
# the segmentation model emits ~0.35 s phantom overlap segments at some turn
# boundaries, and a fixed cluster count lets the phantom eat a real speaker's
# slot; min_duration_on=0.5 removes it cleanly in auto mode instead.
_CLUSTER_THRESHOLD = 0.5
_MIN_DURATION_ON = 0.5
_MIN_DURATION_OFF = 0.5
_NUM_THREADS = 2


@dataclass(frozen=True)
class Turn:
    """One diarized speaker turn, in seconds within the track."""

    start: float
    end: float
    speaker: str  # "s1", "s2", … numbered by order of first appearance


def available() -> bool:
    """True when the sherpa-onnx wheel is importable."""
    try:
        import sherpa_onnx  # noqa: F401
    except Exception:  # noqa: BLE001 — any import failure means unavailable
        return False
    return True


def models_ready() -> bool:
    root = models_dir()
    return (root / _SEG_NAME).is_file() and (root / _EMB_NAME).is_file()


def _verify(path: Path, expected: str) -> None:
    digest = sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        path.unlink(missing_ok=True)
        raise ValueError(f"checksum mismatch for {path.name}: {digest}")


def _download(url: str, dest: Path, progress: Callable[[int], None] | None) -> None:
    """Stream ``url`` to ``dest`` atomically (tmp file + rename)."""
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as resp, tmp.open("wb") as out:
            done = 0
            while True:
                block = resp.read(256 * 1024)
                if not block:
                    break
                out.write(block)
                done += len(block)
                if progress is not None:
                    progress(done)
        tmp.replace(dest)
    finally:
        tmp.unlink(missing_ok=True)


def ensure_models(progress: Callable[[int], None] | None = None) -> None:
    """Download + verify both models if missing. Raises on failure.

    ``progress`` receives cumulative bytes downloaded (vs DOWNLOAD_BYTES).
    """
    root = models_dir()
    root.mkdir(parents=True, exist_ok=True)
    base = 0

    seg = root / _SEG_NAME
    if not seg.is_file():
        log.info("diarization: downloading segmentation model")
        with tempfile.TemporaryDirectory(dir=root) as tmpdir:
            tarball = Path(tmpdir) / "seg.tar.bz2"
            _download(_SEG_URL, tarball,
                      (lambda n: progress(base + n)) if progress else None)
            with tarfile.open(tarball, "r:bz2") as tar:
                member = tar.getmember(_SEG_TAR_MEMBER)
                member.name = seg.name  # flatten, and never trust archive paths
                tar.extract(member, root, filter="data")
        _verify(seg, _SEG_SHA256)
    base += 6_900_000

    emb = root / _EMB_NAME
    if not emb.is_file():
        log.info("diarization: downloading speaker-embedding model")
        _download(_EMB_URL, emb,
                  (lambda n: progress(base + n)) if progress else None)
        _verify(emb, _EMB_SHA256)


def diarize(pcm: np.ndarray) -> list[Turn]:
    """Diarize 16 kHz mono float32 samples into ordered speaker turns.

    Returns turns sorted by start time, speakers renumbered s1, s2, … by
    first appearance. Raises on any backend failure — callers fall back to
    the single-speaker path.
    """
    import sherpa_onnx

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(models_dir() / _SEG_NAME)),
            num_threads=_NUM_THREADS),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(models_dir() / _EMB_NAME), num_threads=_NUM_THREADS),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=-1, threshold=_CLUSTER_THRESHOLD),
        min_duration_on=_MIN_DURATION_ON,
        min_duration_off=_MIN_DURATION_OFF,
    )
    if not config.validate():
        raise ValueError("invalid diarization config (models missing?)")
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)
    if sd.sample_rate != 16_000:
        raise ValueError(f"unexpected diarization sample rate {sd.sample_rate}")

    result = sd.process(np.ascontiguousarray(pcm, dtype=np.float32))
    segments = result.sort_by_start_time()

    order: dict[int, str] = {}
    turns: list[Turn] = []
    for seg in segments:
        if seg.speaker not in order:
            order[seg.speaker] = f"s{len(order) + 1}"
        turns.append(Turn(float(seg.start), float(seg.end), order[seg.speaker]))
    return turns


def plan_chunks(
    turns: list[Turn],
    total_samples: int,
    sample_rate: int = 16_000,
    max_chunk_s: float = 60.0,
    merge_gap_s: float = 1.0,
    pad_s: float = 0.2,
) -> list[tuple[int, int, str]]:
    """Turn diarized turns into transcription chunks.

    Adjacent same-speaker turns closer than ``merge_gap_s`` merge into one
    chunk; merged spans longer than ``max_chunk_s`` split evenly (whisper
    batch quality drops past a minute). Boundaries get ``pad_s`` of padding,
    clamped so chunks never overlap a neighbouring turn — segmentation edges
    land within ~100 ms of the true boundary and padding protects word onsets.

    Returns (start_sample, end_sample, speaker) tuples, chronological. Must be
    deterministic for a given track: chunk indexes are the resume cursor.
    """
    if not turns:
        return []
    merged: list[list[float | str]] = []
    for turn in turns:
        if (merged and merged[-1][2] == turn.speaker
                and turn.start - float(merged[-1][1]) <= merge_gap_s):
            merged[-1][1] = turn.end
        else:
            merged.append([turn.start, turn.end, turn.speaker])

    chunks: list[tuple[int, int, str]] = []
    for i, (start, end, speaker) in enumerate(merged):
        start_f, end_f = float(start), float(end)
        if end_f - start_f < 0.3:
            # Too short to carry a word; padding must not resurrect it.
            continue
        prev_end = float(merged[i - 1][1]) if i > 0 else 0.0
        next_start = (
            float(merged[i + 1][0]) if i + 1 < len(merged)
            else total_samples / sample_rate
        )
        start_f = max(start_f - pad_s, prev_end, 0.0)
        end_f = min(end_f + pad_s, next_start, total_samples / sample_rate)
        if end_f - start_f < 0.2:
            continue
        # Even split keeps pieces comparable instead of a 60 s + 2 s tail.
        span = end_f - start_f
        pieces = max(1, int(np.ceil(span / max_chunk_s)))
        piece_len = span / pieces
        for p in range(pieces):
            a = start_f + p * piece_len
            b = min(end_f, a + piece_len)
            sa, sb = int(a * sample_rate), int(b * sample_rate)
            sb = min(sb, total_samples)
            if sb - sa >= int(0.2 * sample_rate):
                chunks.append((sa, sb, str(speaker)))
    return chunks
