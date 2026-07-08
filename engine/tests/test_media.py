"""File-transcription media decoding + batch splitting (pure + afconvert)."""

import wave
from pathlib import Path

import numpy as np
import pytest

from velora_engine.media import SAMPLE_RATE, load_media, split_for_batch


def _tone(seconds: float, freq: float = 440.0, rate: int = SAMPLE_RATE) -> np.ndarray:
    t = np.arange(int(seconds * rate)) / rate
    return (0.3 * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _write_wav(path: Path, pcm: np.ndarray, rate: int, channels: int = 1) -> None:
    pcm16 = (pcm * 32767.0).astype("<i2")
    if channels == 2:
        pcm16 = np.column_stack([pcm16, pcm16]).ravel()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16.tobytes())


# ---- split_for_batch ----


def test_short_clip_is_one_chunk():
    pcm = _tone(30.0)
    chunks = split_for_batch(pcm)
    assert len(chunks) == 1
    assert chunks[0] is pcm


def test_long_clip_splits_at_silence_and_concatenates():
    # 3 minutes of tone with a clear 2s silence around 55s and 115s.
    pcm = _tone(180.0)
    for at in (55.0, 115.0):
        lo = int(at * SAMPLE_RATE)
        pcm[lo : lo + 2 * SAMPLE_RATE] = 0.0
    chunks = split_for_batch(pcm, target_s=60.0, search_s=15.0)
    assert len(chunks) >= 2
    # Lossless: chunks concatenate to the exact original.
    assert np.array_equal(np.concatenate(chunks), pcm)
    # The first cut lands inside the silent gap, not mid-tone.
    cut = len(chunks[0])
    assert 55 * SAMPLE_RATE <= cut <= 57.5 * SAMPLE_RATE
    # No chunk is degenerate.
    assert all(len(c) >= 20 * SAMPLE_RATE for c in chunks)


def test_split_handles_constant_audio():
    # No silence anywhere — still splits, still lossless.
    pcm = _tone(200.0)
    chunks = split_for_batch(pcm)
    assert len(chunks) >= 2
    assert np.array_equal(np.concatenate(chunks), pcm)


# ---- load_media ----


def test_load_media_missing_file():
    with pytest.raises(ValueError, match="not found"):
        load_media("/nonexistent/velora-test.m4a")


def test_load_media_wav_resamples_to_16k_mono(tmp_path):
    # 44.1kHz stereo in → 16kHz mono float32 out (via afconvert on macOS,
    # soundfile fallback elsewhere).
    src = tmp_path / "clip.wav"
    _write_wav(src, _tone(2.0, rate=44100), rate=44100, channels=2)
    pcm = load_media(str(src))
    assert pcm.dtype == np.float32
    assert pcm.ndim == 1
    assert abs(len(pcm) - 2 * SAMPLE_RATE) < SAMPLE_RATE // 10
    assert float(np.max(np.abs(pcm))) > 0.1


def test_load_media_rejects_garbage(tmp_path):
    src = tmp_path / "notaudio.m4a"
    src.write_bytes(b"this is not audio at all" * 100)
    with pytest.raises(ValueError):
        load_media(str(src))
