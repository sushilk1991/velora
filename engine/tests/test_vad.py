"""Unit tests for V-01 neural VAD (Silero via sherpa-onnx) + RMS fallback."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pytest

from velora_engine.stt import (
    SAMPLE_RATE,
    ParakeetBackend,
    SilenceTracker,
    WhisperBackend,
    create_silence_tracker,
)
from velora_engine.vad import (
    DEFAULT_TRIM_PAD_S,
    MIN_VAD_CLIP_S,
    SILERO_WINDOW_SAMPLES,
    NeuralSilenceTracker,
    resolve_model_path,
)


@dataclass
class _FakeSegment:
    start: int
    samples: list[float]


class _FakeNeuralVad:
    """Deterministic fake sherpa_onnx.VoiceActivityDetector keyed on RMS > threshold."""

    def __init__(self, threshold: float = 0.05, *, fail_on_call: int | None = None) -> None:
        self.threshold = threshold
        self.fail_on_call = fail_on_call
        self.calls = 0
        self.cursor = 0
        self.in_speech = False
        self.seg_start = 0
        self.seg_buf: list[float] = []
        self.queue: list[_FakeSegment] = []
        self.popped = 0

    def accept_waveform(self, samples) -> None:
        self.calls += 1
        if self.fail_on_call is not None and self.calls >= self.fail_on_call:
            raise RuntimeError("vad exploded")
        arr = np.asarray(samples, dtype=np.float32)
        rms = float(np.sqrt(np.mean(np.square(arr, dtype=np.float64)))) if arr.size else 0.0
        voiced = rms >= self.threshold
        if voiced:
            if not self.in_speech:
                self.in_speech = True
                self.seg_start = self.cursor
                self.seg_buf = []
            self.seg_buf.extend(arr.tolist())
        elif self.in_speech:
            self.queue.append(_FakeSegment(self.seg_start, list(self.seg_buf)))
            self.in_speech = False
            self.seg_buf = []
        self.cursor += len(arr)

    def is_speech_detected(self) -> bool:
        return self.in_speech

    def empty(self) -> bool:
        return len(self.queue) == 0

    @property
    def front(self) -> _FakeSegment:
        return self.queue[0]

    def pop(self) -> None:
        self.queue.pop(0)
        self.popped += 1

    def flush(self) -> None:
        if self.in_speech and self.seg_buf:
            self.queue.append(_FakeSegment(self.seg_start, list(self.seg_buf)))
            self.in_speech = False
            self.seg_buf = []

    def reset(self) -> None:
        self.cursor = 0
        self.in_speech = False
        self.seg_start = 0
        self.seg_buf = []
        self.queue.clear()


def _tone(seconds: float, amp: float = 0.15) -> np.ndarray:
    n = int(round(seconds * SAMPLE_RATE))
    t = np.arange(n, dtype=np.float32) / SAMPLE_RATE
    return (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def _silence(seconds: float, amp: float = 0.0) -> np.ndarray:
    n = int(round(seconds * SAMPLE_RATE))
    return np.full(n, amp, dtype=np.float32)


def test_fallback_to_rms_when_model_absent(home, monkeypatch):
    monkeypatch.delenv("VELORA_SILERO_VAD_MODEL", raising=False)
    assert resolve_model_path() is None

    tracker = create_silence_tracker()
    assert tracker.neural_active is False

    chunk = _tone(0.1, amp=0.1)
    assert tracker.feed(chunk) is True
    assert tracker.is_speaking is True
    assert tracker.trailing_silence_s == 0.0

    for _ in range(5):
        assert tracker.feed(_silence(0.1)) is False
    assert tracker.is_speaking is False
    assert tracker.trailing_silence_s == pytest.approx(0.5)

    # Without neural model, trim_silence is a zero-copy no-op.
    clip = np.concatenate([_silence(1.0), _tone(1.0), _silence(1.0)])
    assert tracker.trim_silence(clip) is clip


def test_neural_tracker_streaming_and_queue_drain():
    det = _FakeNeuralVad(threshold=0.05)
    tracker = NeuralSilenceTracker(SilenceTracker(), detector_factory=lambda: det)
    assert tracker.neural_active is True

    # Low-level room noise (0.01 RMS) would trigger RMS tracker (>0.003), but
    # neural VAD rejects it as silence.
    for _ in range(4):
        assert tracker.feed(_silence(0.1, amp=0.01)) is False
    # 0.4 s = 6400 samples = 12 full 512-sample Silero windows (0.384 s).
    assert 0.35 <= tracker.trailing_silence_s <= 0.41
    assert tracker.is_speaking is False

    # Real speech resets trailing silence and keeps RMS speech_level calibrated.
    assert tracker.feed(_tone(0.2, amp=0.2)) is True
    assert tracker.is_speaking is True
    assert tracker.trailing_silence_s == 0.0
    assert tracker.speech_level > 0.02

    # Transition back to silence drains completed segments so memory stays O(1).
    # First 0.1 s chunk carries the 128-sample residual tail of the tone in its first window;
    # subsequent silent chunks report strictly False and advance trailing silence.
    tracker.feed(_silence(0.1))
    for _ in range(4):
        assert tracker.feed(_silence(0.1)) is False
    assert det.empty() is True
    assert det.popped >= 1
    assert tracker.is_speaking is False
    assert 0.42 <= tracker.trailing_silence_s <= 0.52

    tracker.consume_pause()
    assert tracker.trailing_silence_s == 0.0

    tracker.reset()
    assert tracker.is_speaking is False
    assert det.cursor == 0


def test_trim_silence_removes_leading_and_trailing_silence_with_padding():
    tracker = NeuralSilenceTracker(
        SilenceTracker(),
        detector_factory=lambda: _FakeNeuralVad(threshold=0.05),
    )
    # 1.5s silence + 1.0s speech + 0.5s interior pause + 1.0s speech + 2.0s trailing silence = 6.0s
    clip = np.concatenate([
        _silence(1.5),
        _tone(1.0, amp=0.2),
        _silence(0.5),
        _tone(1.0, amp=0.2),
        _silence(2.0),
    ])
    trimmed = tracker.trim_silence(clip, pad_s=DEFAULT_TRIM_PAD_S)
    # Expected span: ~[1.5 - 0.15, 4.0 + 0.15] = ~2.8s (far shorter than 6.0s, keeps interior pause).
    trimmed_s = len(trimmed) / SAMPLE_RATE
    assert 2.6 <= trimmed_s <= 3.1
    assert len(trimmed) < len(clip) * 0.6


def test_trim_silence_short_clip_below_min_falls_back_untouched():
    tracker = NeuralSilenceTracker(
        SilenceTracker(),
        detector_factory=lambda: _FakeNeuralVad(threshold=0.05),
    )
    short = _silence(MIN_VAD_CLIP_S - 0.05)
    assert tracker.trim_silence(short) is short


def test_trim_silence_returns_empty_when_clip_has_no_neural_speech():
    tracker = NeuralSilenceTracker(
        SilenceTracker(),
        detector_factory=lambda: _FakeNeuralVad(threshold=0.05),
    )
    noise_only = _silence(1.2, amp=0.01)
    trimmed = tracker.trim_silence(noise_only)
    assert trimmed.size == 0


def test_neural_tracker_degrades_gracefully_on_detector_error():
    det = _FakeNeuralVad(threshold=0.05, fail_on_call=2)
    tracker = NeuralSilenceTracker(SilenceTracker(), detector_factory=lambda: det)

    # First chunk succeeds (sub-chunk or 3 windows -> fails on call 2 -> degrades to RMS).
    assert tracker.feed(_tone(0.1, amp=0.2)) is True
    assert tracker.neural_active is False
    assert tracker.feed(_silence(0.1)) is False
    assert tracker.trailing_silence_s == pytest.approx(0.1)


def test_whisper_and_parakeet_finalize_trim_trailing_silence(monkeypatch):
    # 0.5s silence + 1.0s speech + 2.5s trailing silence = 4.0s clip.
    clip = np.concatenate([_silence(0.5), _tone(1.0, amp=0.2), _silence(2.5)])
    chunk = SAMPLE_RATE // 10

    # --- WhisperBackend ---
    w = WhisperBackend("mlx-community/whisper-large-v3-turbo")
    w._silence = create_silence_tracker(lambda: _FakeNeuralVad(threshold=0.05))
    w._loaded = True
    seen_whisper: list[int] = []

    def fake_w_decode(audio, **kwargs):
        seen_whisper.append(len(audio))
        return "hello world"

    monkeypatch.setattr(w, "_decode", fake_w_decode)
    for i in range(0, len(clip), chunk):
        w.feed_chunk(clip[i : i + chunk])
    assert w.finalize() == "hello world"
    assert len(seen_whisper) == 1
    assert seen_whisper[0] < len(clip) * 0.5  # trimmed leading & trailing silence

    # --- ParakeetBackend ---
    p = ParakeetBackend("mlx-community/parakeet-tdt-0.6b-v3")
    p._silence = create_silence_tracker(lambda: _FakeNeuralVad(threshold=0.05))
    p._model = object()
    seen_parakeet: list[int] = []

    def fake_p_transcribe(audio):
        seen_parakeet.append(len(audio))
        return "hello world"

    monkeypatch.setattr(p, "_transcribe", fake_p_transcribe)
    for i in range(0, len(clip), chunk):
        p.feed_chunk(clip[i : i + chunk])
    assert p.finalize() == "hello world"
    assert len(seen_parakeet) == 1
    assert seen_parakeet[0] < len(clip) * 0.5
    assert SILERO_WINDOW_SAMPLES == 512
