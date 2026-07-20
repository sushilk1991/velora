"""Contract tests for Velora's optional transcribe.cpp STT adapter."""

import inspect
from types import SimpleNamespace
import sys

import numpy as np

from velora_engine import models
from velora_engine.stt import TranscribeCppWhisperBackend


def test_pinned_transcribe_cpp_runtime_exports_the_adapter_contract():
    import transcribe_cpp

    options = transcribe_cpp.WhisperRunOptions(
        initial_prompt=None,
        condition_on_prev_tokens=False,
        temperature=0.0,
        temperature_inc=0.0,
    )
    inspect.signature(transcribe_cpp.Session.run).bind(
        None,
        np.zeros(160, dtype=np.float32),
        language=None,
        timestamps="segment",
        family=options,
    )

    assert transcribe_cpp.__version__ == "0.1.3"
    assert transcribe_cpp.native_version() == "0.1.3"
    assert transcribe_cpp.native_commit() != "unknown"
    assert transcribe_cpp.native_provider() == "transcribe-cpp-native"


class FakeWhisperRunOptions:
    def __init__(
        self,
        *,
        initial_prompt=None,
        condition_on_prev_tokens=None,
        temperature=None,
        temperature_inc=None,
    ):
        self.values = {
            "initial_prompt": initial_prompt,
            "condition_on_prev_tokens": condition_on_prev_tokens,
        }
        if temperature is not None:
            self.values["temperature"] = temperature
        if temperature_inc is not None:
            self.values["temperature_inc"] = temperature_inc


class FakeNativeSession:
    result_text = "Velora uses SwiftUI"
    result_texts = None

    def __init__(self):
        self.calls: list[tuple[np.ndarray, dict]] = []
        self.close_calls = 0

    def run(
        self,
        audio,
        *,
        task="transcribe",
        language=None,
        target_language=None,
        timestamps="auto",
        keep_special_tags=False,
        spec_k_drafts=-1,
        family=None,
    ):
        self.calls.append((audio, {
            "task": task,
            "language": language,
            "target_language": target_language,
            "timestamps": timestamps,
            "keep_special_tags": keep_special_tags,
            "spec_k_drafts": spec_k_drafts,
            "family": family,
        }))
        text = self.result_texts.pop(0) if self.result_texts else self.result_text
        return SimpleNamespace(
            text=text,
            segments=(SimpleNamespace(text=f" {text} "),),
        )

    def close(self):
        self.close_calls += 1


class FakeNativeModel:
    last_path: str | None = None
    last_session: FakeNativeSession | None = None
    close_calls = 0

    def __init__(self, path):
        type(self).last_path = path
        type(self).close_calls = 0

    def session(self):
        session = FakeNativeSession()
        type(self).last_session = session
        return session

    def close(self):
        type(self).close_calls += 1


def test_transcribe_cpp_backend_preserves_language_prompt_and_guard_surface(
    monkeypatch,
):
    fake_module = SimpleNamespace(
        Model=FakeNativeModel,
        WhisperRunOptions=FakeWhisperRunOptions,
    )
    monkeypatch.setitem(sys.modules, "transcribe_cpp", fake_module)
    monkeypatch.setattr(
        models,
        "ensure_downloaded",
        lambda model_id: "/cache/whisper-large-v3-turbo-Q8_0.gguf",
    )
    backend = TranscribeCppWhisperBackend(models.TRANSCRIBE_CPP_Q8_MODEL, "hi")

    backend.load()
    backend.initial_prompt = "Glossary: Velora, SwiftUI."
    backend.start_session()
    backend.feed_chunk(np.full(16_000, 0.1, dtype=np.float32))

    assert backend.finalize() == "Velora uses SwiftUI"
    assert FakeNativeModel.last_path == "/cache/whisper-large-v3-turbo-Q8_0.gguf"
    assert FakeNativeModel.last_session is not None
    _audio, call = FakeNativeModel.last_session.calls[0]
    assert call["language"] == "hi"
    assert call["timestamps"] == "segment"
    assert call["family"].values == {
        "initial_prompt": "Glossary: Velora, SwiftUI.",
        "condition_on_prev_tokens": False,
    }


def test_transcribe_cpp_backend_passes_none_for_automatic_language(monkeypatch):
    fake_module = SimpleNamespace(
        Model=FakeNativeModel,
        WhisperRunOptions=FakeWhisperRunOptions,
    )
    monkeypatch.setitem(sys.modules, "transcribe_cpp", fake_module)
    monkeypatch.setattr(models, "ensure_downloaded", lambda _model_id: "/cache/q8.gguf")
    backend = TranscribeCppWhisperBackend(models.TRANSCRIBE_CPP_Q8_MODEL, "auto")

    backend.load()
    backend.start_session()
    backend.feed_chunk(np.full(16_000, 0.1, dtype=np.float32))
    backend.finalize()

    assert FakeNativeModel.last_session is not None
    assert FakeNativeModel.last_session.calls[0][1]["language"] is None


def test_transcribe_cpp_backend_closes_native_handles_in_dependency_order(monkeypatch):
    fake_module = SimpleNamespace(
        Model=FakeNativeModel,
        WhisperRunOptions=FakeWhisperRunOptions,
    )
    monkeypatch.setitem(sys.modules, "transcribe_cpp", fake_module)
    monkeypatch.setattr(models, "ensure_downloaded", lambda _model_id: "/cache/q8.gguf")
    backend = TranscribeCppWhisperBackend(models.TRANSCRIBE_CPP_Q8_MODEL)
    backend.load()
    session = FakeNativeModel.last_session

    backend.close()
    backend.close()

    assert session is not None
    assert session.close_calls == 1
    assert FakeNativeModel.close_calls == 1


def test_transcribe_cpp_backend_keeps_compression_hallucination_guard(
    monkeypatch,
):
    fake_module = SimpleNamespace(
        Model=FakeNativeModel,
        WhisperRunOptions=FakeWhisperRunOptions,
    )
    monkeypatch.setitem(sys.modules, "transcribe_cpp", fake_module)
    monkeypatch.setattr(models, "ensure_downloaded", lambda _model_id: "/cache/q8.gguf")
    monkeypatch.setattr(FakeNativeSession, "result_text", "Velora " * 100)
    backend = TranscribeCppWhisperBackend(models.TRANSCRIBE_CPP_Q8_MODEL)

    backend.load()
    backend.start_session()
    backend.feed_chunk(np.full(16_000, 0.1, dtype=np.float32))

    assert backend.finalize() == ""


def test_transcribe_cpp_prompt_free_retry_disables_temperature_fallback(
    monkeypatch,
):
    fake_module = SimpleNamespace(
        Model=FakeNativeModel,
        WhisperRunOptions=FakeWhisperRunOptions,
    )
    monkeypatch.setitem(sys.modules, "transcribe_cpp", fake_module)
    monkeypatch.setattr(models, "ensure_downloaded", lambda _model_id: "/cache/q8.gguf")
    monkeypatch.setattr(
        FakeNativeSession,
        "result_texts",
        ["Glossary: Velora.", "Velora works"],
    )
    backend = TranscribeCppWhisperBackend(models.TRANSCRIBE_CPP_Q8_MODEL)

    backend.load()
    backend.initial_prompt = "Glossary: Velora."
    backend.start_session()
    carrier = np.sin(np.linspace(0, 200 * np.pi, 16_000)).astype(np.float32)
    envelope = np.concatenate((np.full(8_000, 0.02), np.full(8_000, 0.1)))
    speech_like = carrier * envelope
    backend.feed_chunk(speech_like)

    assert backend.finalize() == "Velora works"
    assert FakeNativeModel.last_session is not None
    calls = FakeNativeModel.last_session.calls
    assert len(calls) == 2
    assert calls[1][1]["family"].values == {
        "initial_prompt": None,
        "condition_on_prev_tokens": False,
        "temperature": 0.0,
        "temperature_inc": 0.0,
    }
