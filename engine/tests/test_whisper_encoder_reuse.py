"""Whisper decodes encode each audio window once.

Stock `mlx_whisper.transcribe(language=None)` encodes the silence-padded
clip to detect the language, then encodes the first decode window again,
and re-encodes a window on every temperature fallback. The encoder is ~40%
of a dictation's decode, so `WhisperBackend` detects on the decode window
itself and reuses that encoding.

These tests run the real `mlx_whisper.transcribe` on a tiny random-weight
model, so they count what the library actually does, not a fake of it.
How many windows a random model decodes varies, so the rule is checked
per window: every encoder pass is a window the decoder uses, and no
window is encoded twice.
"""

import hashlib

import mlx.core as mx
import numpy as np
import pytest
from mlx_whisper import decoding as mlx_whisper_decoding
from mlx_whisper import whisper as mlx_whisper_model
from mlx_whisper.transcribe import ModelHolder

import mlx_whisper
from velora_engine import stt
from velora_engine.stt import SAMPLE_RATE, WhisperBackend

TINY_PATH = "tiny-random-whisper"
FALLBACK_COMPRESSION = 99.0  # far above transcribe's 2.4 threshold


def window_id(mel) -> str:
    """Content hash of a mel window, with or without its batch axis."""
    return hashlib.sha1(np.asarray(mel).tobytes()).hexdigest()


@pytest.fixture
def windows(monkeypatch):
    """Install a tiny multilingual Whisper; record encoded and decoded windows."""
    mx.random.seed(0)
    dims = mlx_whisper_model.ModelDimensions(
        n_mels=128, n_audio_ctx=1500, n_audio_state=8, n_audio_head=1,
        n_audio_layer=1, n_vocab=51866, n_text_ctx=64, n_text_state=8,
        n_text_head=1, n_text_layer=1)
    model = mlx_whisper_model.Whisper(dims, mx.float16)
    model.set_dtype(mx.float16)
    mx.eval(model.parameters())
    monkeypatch.setattr(ModelHolder, "model", model)
    monkeypatch.setattr(ModelHolder, "model_path", TINY_PATH)
    # Every decode "repeats itself", so each window runs the whole
    # temperature ladder: the retries that must reuse the encoding.
    monkeypatch.setattr(mlx_whisper_decoding, "compression_ratio",
                        lambda _text: FALLBACK_COMPRESSION)
    # A random model is never sure of a language; these tests are about
    # sure detections, test_an_unsure_detection_* about the other kind.
    monkeypatch.setattr(stt, "_SURE_LANGUAGE_P", 0.0)

    seen = {"encoded": [], "decoded": []}
    encode = mlx_whisper_model.AudioEncoder.__call__
    decode = mlx_whisper_model.Whisper.decode

    def counting_encode(self, x):
        seen["encoded"].append(window_id(x))
        return encode(self, x)

    def recording_decode(self, mel, options):
        seen["decoded"].append(window_id(mel))
        return decode(self, mel, options)

    monkeypatch.setattr(mlx_whisper_model.AudioEncoder, "__call__", counting_encode)
    monkeypatch.setattr(mlx_whisper_model.Whisper, "decode", recording_decode)
    return seen


def backend(language: str) -> WhisperBackend:
    whisper = WhisperBackend(TINY_PATH, language)
    whisper._model_path = TINY_PATH
    return whisper


def seconds(duration: float) -> np.ndarray:
    rng = np.random.default_rng(7)
    return (rng.standard_normal(int(duration * SAMPLE_RATE)) * 0.1).astype(
        np.float32)


def assert_each_window_encoded_once(seen):
    encoded, decoded = seen["encoded"], seen["decoded"]
    assert len(decoded) > len(set(decoded)), "no temperature fallback ran"
    assert len(encoded) == len(set(encoded)), "a window was encoded twice"
    assert set(encoded) == set(decoded), "a pass encoded a window no decode used"


def test_auto_language_short_clip(windows):
    result = backend("auto")._transcribe(seconds(4), None)

    assert result["language"]
    assert_each_window_encoded_once(windows)


def test_auto_language_long_clip(windows):
    """Only the first window needs the language; later windows are new
    audio and each still costs exactly one pass."""
    backend("auto")._transcribe(seconds(45), None)

    assert_each_window_encoded_once(windows)


def test_fixed_language_is_passed_through(windows):
    result = backend("de")._transcribe(seconds(4), None)

    assert result["language"] == "de"
    assert_each_window_encoded_once(windows)


def test_a_failed_detection_keeps_no_encoding(windows, monkeypatch):
    """Detection encodes before it can fail; the encoding must not stay
    pinned on the shared model until the next dictation."""
    def failing_logits(self, tokens, audio_features):
        raise RuntimeError("metal out of memory")

    monkeypatch.setattr(mlx_whisper_model.Whisper, "logits", failing_logits)

    with pytest.raises(RuntimeError):
        backend("auto")._transcribe(seconds(4), None)

    assert windows["encoded"], "detection never reached the encoder"
    assert ModelHolder.model.encoder.memo.entry is None


def test_an_unsure_detection_keeps_the_stock_language(windows, monkeypatch):
    """Short or noisy clips detect near chance. There the padding
    difference can flip the language (a 5.8 s English dictation read as
    Japanese), so an unsure clip takes stock's answer instead."""
    monkeypatch.setattr(stt, "_SURE_LANGUAGE_P", 1.01)  # nothing is sure
    for duration in (2, 4, 7):
        audio = seconds(duration)
        expected = mlx_whisper.transcribe(
            audio, path_or_hf_repo=TINY_PATH, condition_on_previous_text=False,
            language=None, fp16=True, temperature=0.0)["language"]

        result = backend("auto")._transcribe(audio, None, temperature=0.0)

        assert result["language"] == expected
