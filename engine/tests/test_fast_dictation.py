"""Fast dictation never invokes the writing model, including transliteration."""
import numpy as np
import pytest
from velora_engine.config import Config
from velora_engine import formatting, stt


@pytest.mark.parametrize("text,mode", [
    ("Here is a long message that would normally need the writing model to tidy it up", None),
    ("this is a longer explanation about this particular command", "Terminal"),
    ("यह एक लंबा हिंदी वाक्य है जिसे मैं अपने कंप्यूटर पर लिख रहा हूं", None),
])
def test_fast_gate_has_no_llm_even_with_romanization(home, text, mode):
    config = Config()
    config.data.update(cleanup_enabled=False, romanize_output=True, smart_terminal=True)
    gate = formatting.run_gate(text, config, explicit_mode=mode)
    assert gate.use_llm is False
    assert gate.romanize is False
    assert gate.reason == "cleanup_disabled"
    assert gate.text == text
    assert formatting.postprocess(gate.text, gate) == text


def test_fast_gate_keeps_explicit_dictionary_replacements(home):
    config = Config()
    config.data.update(cleanup_enabled=False, replacements={"Valora": "Velora"})
    gate = formatting.run_gate("Valora", config)
    assert not gate.use_llm
    assert formatting.postprocess(gate.text, gate) == "Velora"


@pytest.mark.parametrize("suffix,magic", [(".bin", b"lmgg"), (".gguf", b"GGUF")])
def test_imported_native_model_routes_by_header_not_filename(tmp_path, monkeypatch, suffix, magic):
    monkeypatch.delenv("VELORA_FAKE_STT", raising=False)
    path = tmp_path / ("user-chosen-model" + suffix)
    path.write_bytes(magic + b"fixture header")
    backend = stt.create_backend(str(path))
    assert isinstance(backend, stt.TranscribeCppWhisperBackend)
    assert backend.model_id == str(path)
    # Selecting the file uses the original location; no model copy created.
    assert [file for file in tmp_path.iterdir() if file.is_file()] == [path]


def test_imported_wrong_format_is_rejected_before_loading(tmp_path, monkeypatch):
    monkeypatch.delenv("VELORA_FAKE_STT", raising=False)
    path = tmp_path / "pytorch.bin"
    path.write_bytes(b"PK\x03\x04not a whisper.cpp model")
    with pytest.raises(ValueError, match="whisper.cpp"):
        stt.create_backend(str(path))
