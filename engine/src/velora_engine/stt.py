"""STT backends behind one interface.

- ParakeetBackend: parakeet-mlx `transcribe_stream` — audio is processed DURING
  recording so stop→transcript only flushes the tail.
- WhisperBackend: mlx-whisper — accumulates PCM, batch-transcribes on stop,
  with hallucination guard (compression/repetition checks, repeated-tail trim).
- FakeBackend: for tests (VELORA_FAKE_STT=1), no model downloads.

All heavy imports are lazy (inside load()) so tests never touch MLX.
"""

from __future__ import annotations

import logging
import math
import os
import re
import time
from typing import Any, Protocol

import numpy as np

log = logging.getLogger("velora.stt")

SAMPLE_RATE = 16_000

# Feed parakeet in ~0.5s increments: each add_audio() call runs the encoder,
# so per-100ms-frame calls would waste compute for no latency win.
_PARAKEET_FEED_SAMPLES = SAMPLE_RATE // 2


class STTBackend(Protocol):
    """Interface: load, feed_chunk, finalize, reset."""

    model_id: str

    def load(self) -> None: ...

    def start_session(self) -> None: ...

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        """Feed Float32 PCM; may return an updated partial transcript."""
        ...

    def finalize(self) -> str:
        """End the session and return the full transcript."""
        ...

    def reset(self) -> None:
        """Discard any in-flight session state."""
        ...


class ParakeetBackend:
    """Streaming STT via parakeet-mlx (default)."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        self._stream: Any = None
        self._pending: list[np.ndarray] = []
        self._pending_samples = 0

    def load(self) -> None:
        from parakeet_mlx import from_pretrained

        from .models import ensure_downloaded

        t0 = time.perf_counter()
        # Resolve to the local snapshot so a cached model loads with zero
        # network requests (local-first).
        self._model = from_pretrained(ensure_downloaded(self.model_id))
        log.info("parakeet loaded %s in %.2fs", self.model_id, time.perf_counter() - t0)

    def start_session(self) -> None:
        self.reset()
        # depth=2: first two encoder layers carry exact cache across chunks —
        # good accuracy/latency tradeoff for dictation.
        self._stream = self._model.transcribe_stream(context_size=(256, 256), depth=2)
        self._stream.__enter__()

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        if self._stream is None:
            return None
        self._pending.append(chunk)
        self._pending_samples += len(chunk)
        if self._pending_samples < _PARAKEET_FEED_SAMPLES:
            return None
        self._flush_pending()
        return self._stream.result.text

    def _flush_pending(self) -> None:
        import mlx.core as mx

        if not self._pending:
            return
        audio = np.concatenate(self._pending)
        self._pending = []
        self._pending_samples = 0
        self._stream.add_audio(mx.array(audio))

    def finalize(self) -> str:
        if self._stream is None:
            return ""
        # Flush the tail plus a little silence so the draft region decodes.
        self._pending.append(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        self._flush_pending()
        text = self._stream.result.text.strip()
        self.reset()
        return text

    def reset(self) -> None:
        if self._stream is not None:
            try:
                self._stream.__exit__(None, None, None)
            except Exception:  # noqa: BLE001
                log.exception("parakeet stream teardown failed")
        self._stream = None
        self._pending = []
        self._pending_samples = 0


# --- whisper hallucination guard ---------------------------------------------

_COMPRESSION_RATIO_THRESHOLD = 2.4
_LOGPROB_THRESHOLD = -1.2


def _trim_repeated_tail(text: str) -> str:
    """Trim Whisper's classic end-of-audio repetition loops.

    Repeatedly drops the final phrase (5..2 words) while it is an immediate
    repeat of the preceding words.
    """
    words = text.split()
    changed = True
    while changed and len(words) >= 4:
        changed = False
        for n in range(5, 1, -1):
            if len(words) >= 2 * n:
                tail = [w.strip(".,!?;:").lower() for w in words[-n:]]
                prev = [w.strip(".,!?;:").lower() for w in words[-2 * n : -n]]
                if tail == prev:
                    words = words[:-n]
                    changed = True
                    break
    return " ".join(words)


def guard_whisper_result(result: dict[str, Any]) -> str:
    """Drop hallucinated segments, then trim repeated tails."""
    segments = result.get("segments") or []
    kept: list[str] = []
    for seg in segments:
        seg_text = (seg.get("text") or "").strip()
        if not seg_text:
            continue
        cr = seg.get("compression_ratio")
        lp = seg.get("avg_logprob")
        # Log lengths only — never transcript text (privacy: engine.log is plaintext).
        if cr is not None and cr > _COMPRESSION_RATIO_THRESHOLD:
            log.info("whisper guard: dropped segment (compression_ratio=%.2f, %d chars)", cr, len(seg_text))
            continue
        if lp is not None and lp < _LOGPROB_THRESHOLD and cr is not None and cr > 2.0:
            log.info("whisper guard: dropped segment (logprob=%.2f cr=%.2f, %d chars)", lp, cr, len(seg_text))
            continue
        # drop non-text junk (e.g. "!!!!" runs)
        if not re.search(r"[A-Za-z0-9]", seg_text):
            continue
        kept.append(seg_text)
    text = " ".join(kept).strip() or (result.get("text") or "").strip()
    return _trim_repeated_tail(text)


def whisper_language(language: str | None) -> str | None:
    """Map config `language` to mlx-whisper's arg: "auto"/empty → None (autodetect)."""
    if not language:
        return None
    language = language.strip()
    if not language or language.lower() == "auto":
        return None
    return language


class WhisperBackend:
    """Fallback batch STT via mlx-whisper, with hallucination guard."""

    def __init__(self, model_id: str, language: str = "auto") -> None:
        self.model_id = model_id
        self.language = language
        self._model_path = model_id  # resolved to a local path in load()
        self._chunks: list[np.ndarray] = []
        self._loaded = False

    def load(self) -> None:
        import mlx.core as mx
        from mlx_whisper.load_models import load_model

        from .models import ensure_downloaded

        self._model_path = ensure_downloaded(self.model_id)
        t0 = time.perf_counter()
        model = load_model(self._model_path, dtype=mx.float16)
        mx.eval(model.parameters())
        del model  # mlx_whisper's ModelHolder reloads by repo id at transcribe time
        self._loaded = True
        log.info("whisper weights warmed %s in %.2fs", self.model_id, time.perf_counter() - t0)

    def start_session(self) -> None:
        self._chunks = []

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self._chunks.append(chunk)
        return None

    def finalize(self) -> str:
        import mlx_whisper

        if not self._chunks:
            return ""
        audio = np.concatenate(self._chunks)
        self._chunks = []
        # Whole-recording batch decode. The accumulated PCM is bounded by the
        # server's max_recording_s cap (default 300s ≈ 18 MB Float32), so this
        # can't grow without limit — but long batches are still slow.
        duration_s = len(audio) / SAMPLE_RATE
        if duration_s > 60:
            log.warning("whisper batch transcribe of %.0fs of audio — expect high stop→final latency", duration_s)
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._model_path,
            condition_on_previous_text=False,
            language=whisper_language(self.language),
            fp16=True,
        )
        return guard_whisper_result(result)

    def reset(self) -> None:
        self._chunks = []


class FakeBackend:
    """Deterministic backend for tests — no models, no downloads.

    Selected when VELORA_FAKE_STT=1. Transcript comes from VELORA_FAKE_STT_TEXT
    (default below); finalize also reports the number of samples received so
    integration tests can assert audio actually flowed.
    """

    DEFAULT_TEXT = "hello world this is a fake transcript"

    def __init__(self, model_id: str = "fake", language: str = "auto") -> None:
        self.model_id = model_id
        self.language = language
        self.samples = 0
        self.sessions = 0

    def load(self) -> None:
        pass

    def start_session(self) -> None:
        self.samples = 0
        self.sessions += 1

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self.samples += len(chunk)
        return f"partial after {self.samples} samples"

    def finalize(self) -> str:
        text = os.environ.get("VELORA_FAKE_STT_TEXT", self.DEFAULT_TEXT)
        self.samples = 0
        return text

    def reset(self) -> None:
        self.samples = 0


def fake_stt_enabled() -> bool:
    return os.environ.get("VELORA_FAKE_STT", "") == "1"


def create_backend(model_id: str, language: str = "auto") -> STTBackend:
    """Backend selection from config (and VELORA_FAKE_STT for tests).

    `language` is honored by whisper only ("auto" → autodetect); parakeet is
    English-only, so it ignores the setting.
    """
    if fake_stt_enabled():
        return FakeBackend(model_id, language)
    if "whisper" in model_id.lower():
        return WhisperBackend(model_id, language)
    return ParakeetBackend(model_id)


def transcribe_clip(backend: STTBackend, pcm: np.ndarray, chunk_samples: int = SAMPLE_RATE) -> str:
    """Batch-transcribe a whole PCM clip through any backend (used by reprocess).

    Drives the same start/feed/finalize path a live session uses, so streaming
    (parakeet) and batch (whisper) backends both work. Runs on the caller's
    thread — MLX is thread-affine, so call this on the STT executor.
    """
    backend.start_session()
    for i in range(0, len(pcm), chunk_samples):
        backend.feed_chunk(pcm[i : i + chunk_samples])
    return backend.finalize()


def pcm_from_payload(payload: bytes) -> np.ndarray:
    """Decode an AUDIO frame payload: 16kHz mono Float32 LE."""
    if len(payload) % 4 != 0:
        raise ValueError(f"audio payload length {len(payload)} not a multiple of 4")
    arr = np.frombuffer(payload, dtype="<f4").astype(np.float32, copy=False)
    if arr.size and not math.isfinite(float(np.max(np.abs(arr)))):
        arr = np.nan_to_num(arr)
    return arr
