"""Decode arbitrary audio files to 16 kHz mono float32 (file transcription).

Prefers macOS's built-in `afconvert` (m4a/mp3/aac/alac/wav/aiff/caf with
proper sample-rate conversion — covers Voice Memos and meeting recordings);
falls back to soundfile (ogg/flac/opus) with linear resampling when afconvert
can't read the file. No third-party ffmpeg dependency.
"""

from __future__ import annotations

import logging
import os
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

log = logging.getLogger("velora.media")

SAMPLE_RATE = 16000
# Refuse absurd inputs before decoding: 2 GiB of source audio, 4 h decoded.
MAX_FILE_BYTES = 2 * 1024**3
MAX_DURATION_S = 4 * 3600
_AFCONVERT_TIMEOUT_S = 600


def _read_wav_16k(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        if w.getframerate() != SAMPLE_RATE or w.getsampwidth() != 2:
            raise ValueError(f"unexpected wav format from converter: {w.getframerate()}Hz")
        frames = w.readframes(w.getnframes())
    pcm16 = np.frombuffer(frames, dtype="<i2")
    return (pcm16.astype(np.float32) / 32768.0).astype(np.float32)


def _load_via_afconvert(src: Path) -> np.ndarray:
    fd, tmp_name = tempfile.mkstemp(suffix=".wav", prefix="velora-media-")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        proc = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1",
             str(src), str(tmp)],
            capture_output=True,
            timeout=_AFCONVERT_TIMEOUT_S,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or b"").decode("utf-8", "replace").strip()
            raise ValueError(f"afconvert failed: {detail.splitlines()[-1] if detail else proc.returncode}")
        return _read_wav_16k(tmp)
    finally:
        tmp.unlink(missing_ok=True)


def _load_via_soundfile(src: Path) -> np.ndarray:
    try:
        import soundfile as sf
    except ImportError as exc:  # pragma: no cover — soundfile ships with the engine
        raise ValueError("no decoder available for this format") from exc
    data, sr = sf.read(str(src), dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    data = np.asarray(data, dtype=np.float32)
    if sr != SAMPLE_RATE and len(data):
        # Linear resample — adequate for speech recognition input.
        n_out = int(round(len(data) * SAMPLE_RATE / sr))
        x_out = np.linspace(0.0, len(data) - 1.0, n_out, dtype=np.float64)
        data = np.interp(x_out, np.arange(len(data), dtype=np.float64), data).astype(np.float32)
    return data


def load_media(path: str) -> np.ndarray:
    """Decode `path` to float32 mono 16 kHz. Raises ValueError with a concise,
    user-showable message on anything unreadable."""
    src = Path(path)
    if not src.is_file():
        raise ValueError("file not found")
    if src.stat().st_size > MAX_FILE_BYTES:
        raise ValueError("file too large (over 2 GB)")
    try:
        pcm = _load_via_afconvert(src)
    except (ValueError, subprocess.TimeoutExpired, FileNotFoundError) as exc:
        log.info("afconvert path failed (%s); trying soundfile", exc)
        try:
            pcm = _load_via_soundfile(src)
        except Exception as sf_exc:  # noqa: BLE001 — collapse to one user-facing error
            raise ValueError(f"unsupported or unreadable audio file ({sf_exc})") from sf_exc
    if not np.all(np.isfinite(pcm)):
        pcm = np.nan_to_num(pcm)
    if len(pcm) > MAX_DURATION_S * SAMPLE_RATE:
        raise ValueError("audio longer than 4 hours")
    return pcm


def split_for_batch(
    pcm: np.ndarray,
    target_s: float = 60.0,
    search_s: float = 15.0,
    sample_rate: int = SAMPLE_RATE,
) -> list[np.ndarray]:
    """Split a long clip into ~target_s chunks cut at the quietest moment near
    each boundary, so batch decodes don't slice through words. Short clips
    (≤ target + 30 s) come back whole. Chunks concatenate to the original.
    """
    step = int(target_s * sample_rate)
    tail_min = 30 * sample_rate
    if len(pcm) <= step + tail_min:
        return [pcm]
    search = int(search_s * sample_rate)
    win = int(0.3 * sample_rate)
    chunks: list[np.ndarray] = []
    start = 0
    while len(pcm) - start > step + tail_min:
        end = start + step
        # Quietest 0.3 s window inside the last `search_s` of the chunk.
        seg = pcm[end - search : end].astype(np.float64)
        energy = np.convolve(seg * seg, np.ones(win), mode="valid")
        cut = end - search + int(np.argmin(energy)) + win // 2
        chunks.append(pcm[start:cut])
        start = cut
    chunks.append(pcm[start:])
    return chunks
