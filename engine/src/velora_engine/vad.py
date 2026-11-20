"""Neural voice activity detection (Silero VAD via sherpa-onnx) with RMS fallback.

Provides a drop-in tracker matching ``stt.SilenceTracker``'s interface plus
leading/trailing silence trimming before final STT decode (V-01).

When ``silero_vad.onnx`` is absent (first run, tests, or ``VELORA_FAKE_STT=1``)
or ``sherpa_onnx`` cannot initialize, every operation falls back cleanly to the
existing energy-based ``SilenceTracker`` with zero extra dependencies or RAM.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any, Protocol

import numpy as np

from .config import velora_home

log = logging.getLogger("velora.vad")

SAMPLE_RATE = 16_000
SILERO_WINDOW_SAMPLES = 512  # 32 ms @ 16 kHz — Silero VAD's native frame size
MIN_VAD_CLIP_S = 0.30  # Very short clips fall back to avoid misclassifying short words.
DEFAULT_TRIM_PAD_S = 0.15  # Preserve leading/trailing consonant & plosive onset/offset.
DEFAULT_THRESHOLD = 0.5
DEFAULT_MIN_SILENCE_S = 0.35
DEFAULT_MIN_SPEECH_S = 0.15
DEFAULT_MAX_SPEECH_S = 30.0
MODEL_FILENAME = "silero_vad.onnx"
MODEL_ENV_VAR = "VELORA_SILERO_VAD_MODEL"


class SpeechSegmentLike(Protocol):
    start: int
    samples: Any


class VadDetectorLike(Protocol):
    def accept_waveform(self, samples: Any) -> None: ...
    def is_speech_detected(self) -> bool: ...
    def empty(self) -> bool: ...
    @property
    def front(self) -> SpeechSegmentLike: ...
    def pop(self) -> None: ...
    def flush(self) -> None: ...
    def reset(self) -> None: ...


VadFactory = Callable[[], VadDetectorLike | None]


def models_dir() -> Path:
    """Directory for local VAD weights (resolved lazily for VELORA_HOME tests)."""
    return velora_home() / "models" / "vad"


def resolve_model_path(explicit_path: Path | str | None = None) -> Path | None:
    """Return an existing non-empty ``silero_vad.onnx`` path, or None."""
    candidates: list[Path] = []
    if explicit_path is not None:
        candidates.append(Path(explicit_path))
    env_override = os.environ.get(MODEL_ENV_VAR, "").strip()
    if env_override:
        candidates.append(Path(env_override).expanduser())
    candidates.append(models_dir() / MODEL_FILENAME)

    for path in candidates:
        try:
            if path.is_file() and path.stat().st_size > 0:
                return path
        except OSError:
            continue
    return None


def create_sherpa_silero_detector(
    model_path: Path | str | None = None,
    *,
    threshold: float = DEFAULT_THRESHOLD,
    min_silence_duration: float = DEFAULT_MIN_SILENCE_S,
    min_speech_duration: float = DEFAULT_MIN_SPEECH_S,
    max_speech_duration: float = DEFAULT_MAX_SPEECH_S,
    buffer_size_s: float = 60.0,
) -> VadDetectorLike | None:
    """Build a ``sherpa_onnx.VoiceActivityDetector`` backed by Silero VAD, or None."""
    resolved = resolve_model_path(model_path)
    if resolved is None:
        return None
    try:
        import sherpa_onnx
    except Exception:  # noqa: BLE001 — optional runtime fallback
        log.debug("sherpa_onnx unavailable; using RMS silence tracker", exc_info=True)
        return None

    try:
        silero_cfg = sherpa_onnx.SileroVadModelConfig(
            model=str(resolved),
            threshold=threshold,
            min_silence_duration=min_silence_duration,
            min_speech_duration=min_speech_duration,
            window_size=SILERO_WINDOW_SAMPLES,
            max_speech_duration=max_speech_duration,
        )
        vad_cfg = sherpa_onnx.VadModelConfig(
            silero_vad=silero_cfg,
            sample_rate=SAMPLE_RATE,
            num_threads=1,
            provider="cpu",
        )
        return sherpa_onnx.VoiceActivityDetector(
            vad_cfg, buffer_size_in_seconds=buffer_size_s
        )
    except Exception:  # noqa: BLE001 — corrupt/incompatible weights fall back safely
        log.warning("failed to initialize Silero VAD at %s; falling back to RMS", resolved, exc_info=True)
        return None


def available(model_path: Path | str | None = None) -> bool:
    """True when ``sherpa_onnx`` is importable and ``silero_vad.onnx`` is on disk."""
    if resolve_model_path(model_path) is None:
        return False
    try:
        import sherpa_onnx  # noqa: F401
    except Exception:  # noqa: BLE001
        return False
    return True


def _drain_segments(detector: VadDetectorLike) -> list[tuple[int, int]]:
    """Pop all queued speech segments from ``detector`` as ``(start, end)`` samples."""
    spans: list[tuple[int, int]] = []
    while not detector.empty():
        seg = detector.front
        start = int(seg.start)
        length = len(seg.samples)
        detector.pop()
        if length > 0:
            spans.append((start, start + length))
    return spans


class NeuralSilenceTracker:
    """Streaming Silero VAD tracker with transparent RMS fallback.

    Preserves the full ``SilenceTracker`` contract (``feed``,
    ``trailing_silence_s``, ``speech_level``, ``consume_pause``, ``reset``) and
    adds ``is_speaking`` plus pre-decode ``trim_silence``.
    """

    def __init__(
        self,
        rms_fallback: Any,
        *,
        detector_factory: VadFactory | None = None,
    ) -> None:
        self._rms = rms_fallback
        self._factory: VadFactory = (
            detector_factory if detector_factory is not None else create_sherpa_silero_detector
        )
        self._detector: VadDetectorLike | None = None
        self._detector_initialized = False
        self._pending = np.empty(0, dtype=np.float32)
        self._trailing_silence_samples = 0
        self._speaking = False

    def _ensure_detector(self) -> VadDetectorLike | None:
        if not self._detector_initialized:
            self._detector_initialized = True
            self._detector = self._factory()
        return self._detector

    @property
    def neural_active(self) -> bool:
        return self._ensure_detector() is not None

    @property
    def is_speaking(self) -> bool:
        return self._speaking

    @property
    def speech_level(self) -> float:
        """Adapted per-session RMS level (required by Whisper's fabrication guards)."""
        return self._rms.speech_level

    @property
    def trailing_silence_s(self) -> float:
        if self._ensure_detector() is None:
            return self._rms.trailing_silence_s
        return self._trailing_silence_samples / SAMPLE_RATE

    def feed(self, chunk: np.ndarray) -> bool:
        """Process one incoming 16 kHz chunk; returns True when speech is present."""
        if chunk.size == 0:
            return False
        rms_speech = self._rms.feed(chunk)
        detector = self._ensure_detector()
        if detector is None:
            self._speaking = rms_speech
            return rms_speech

        samples = np.asarray(chunk, dtype=np.float32).reshape(-1)
        buf = np.concatenate((self._pending, samples)) if self._pending.size else samples
        n_full = (len(buf) // SILERO_WINDOW_SAMPLES) * SILERO_WINDOW_SAMPLES
        speech_in_chunk = False
        last_speaking = self._speaking

        try:
            for offset in range(0, n_full, SILERO_WINDOW_SAMPLES):
                detector.accept_waveform(buf[offset : offset + SILERO_WINDOW_SAMPLES])
                window_speech = bool(detector.is_speech_detected())
                last_speaking = window_speech
                if window_speech:
                    speech_in_chunk = True
                    self._trailing_silence_samples = 0
                else:
                    self._trailing_silence_samples += SILERO_WINDOW_SAMPLES
                # Drain queued completed segments immediately so long sessions stay O(1) RAM.
                while not detector.empty():
                    detector.pop()
            self._pending = buf[n_full:]
            # If a chunk is smaller than one 512-sample frame, hold last speaking state.
            if n_full == 0:
                speech_in_chunk = self._speaking
                if not self._speaking:
                    self._trailing_silence_samples += len(samples)
        except Exception:  # noqa: BLE001 — degrade cleanly to RMS on runtime error
            log.warning("Silero VAD feed failed; degrading session to RMS fallback", exc_info=True)
            self._detector = None
            self._pending = np.empty(0, dtype=np.float32)
            self._speaking = rms_speech
            return rms_speech

        self._speaking = last_speaking
        return speech_in_chunk

    def consume_pause(self) -> None:
        self._rms.consume_pause()
        self._trailing_silence_samples = 0

    def reset(self) -> None:
        self._rms.reset()
        self._pending = np.empty(0, dtype=np.float32)
        self._trailing_silence_samples = 0
        self._speaking = False
        if self._detector is not None:
            try:
                self._detector.reset()
            except Exception:  # noqa: BLE001
                self._detector = None

    def trim_silence(
        self,
        audio: np.ndarray,
        *,
        pad_s: float = DEFAULT_TRIM_PAD_S,
        min_clip_s: float = MIN_VAD_CLIP_S,
    ) -> np.ndarray:
        """Trim dead leading and trailing silence before final STT decode.

        Clips shorter than ``min_clip_s`` (0.3 s) or sessions without a neural
        detector are returned unchanged so short utterances are never clipped.
        """
        if audio.size == 0 or len(audio) < int(min_clip_s * SAMPLE_RATE):
            return audio
        if self._ensure_detector() is None:
            return audio

        # Use a fresh detector instance for batch trimming so we never disturb
        # streaming state (or reuse a reset detector if factory returns one).
        trim_detector = self._factory()
        if trim_detector is None:
            return audio

        samples = np.asarray(audio, dtype=np.float32).reshape(-1)
        spans: list[tuple[int, int]] = []
        try:
            for offset in range(0, len(samples), SILERO_WINDOW_SAMPLES):
                window = samples[offset : offset + SILERO_WINDOW_SAMPLES]
                if len(window) < SILERO_WINDOW_SAMPLES:
                    padded = np.zeros(SILERO_WINDOW_SAMPLES, dtype=np.float32)
                    padded[: len(window)] = window
                    window = padded
                trim_detector.accept_waveform(window)
                spans.extend(_drain_segments(trim_detector))
            trim_detector.flush()
            spans.extend(_drain_segments(trim_detector))
        except Exception:  # noqa: BLE001 — never lose audio if VAD fails
            log.warning("Silero VAD trim_silence failed; decoding untrimmed audio", exc_info=True)
            return audio

        if not spans:
            return np.empty(0, dtype=np.float32)

        pad_samples = max(0, int(pad_s * SAMPLE_RATE))
        start = max(0, min(s for s, _ in spans) - pad_samples)
        end = min(len(samples), max(e for _, e in spans) + pad_samples)
        if start >= end:
            return np.empty(0, dtype=np.float32)
        return samples[start:end]
