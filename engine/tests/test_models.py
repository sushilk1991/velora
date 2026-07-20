"""Model download behavior at the Hugging Face boundary."""

import hashlib
from pathlib import Path

import huggingface_hub
from huggingface_hub.errors import LocalEntryNotFoundError

from velora_engine import models


def _write_valid_q8(monkeypatch, path: Path) -> None:
    payload = b"test q8 artifact"
    path.write_bytes(payload)
    monkeypatch.setattr(
        models, "TRANSCRIBE_CPP_Q8_SHA256", hashlib.sha256(payload).hexdigest())
    models._verified_sha256.cache_clear()


def test_transcribe_cpp_download_fetches_only_the_q8_artifact(monkeypatch, tmp_path):
    downloaded = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, downloaded)
    calls: list[dict] = []

    def fake_download(**kwargs):
        calls.append(kwargs)
        return str(downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    path = models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL)

    assert Path(path) == downloaded
    assert calls == [{
        "repo_id": "handy-computer/whisper-large-v3-turbo-gguf",
        "filename": "whisper-large-v3-turbo-Q8_0.gguf",
        "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
        "local_files_only": True,
    }]


def test_transcribe_cpp_download_goes_online_only_after_local_cache_miss(
    monkeypatch, tmp_path
):
    downloaded = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, downloaded)
    calls: list[dict] = []

    def fake_download(**kwargs):
        calls.append(kwargs)
        if kwargs.get("local_files_only"):
            raise LocalEntryNotFoundError("not cached")
        return str(downloaded)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.ensure_downloaded(models.TRANSCRIBE_CPP_Q8_MODEL) == str(downloaded)
    assert calls == [
        {
            "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
            "filename": "whisper-large-v3-turbo-Q8_0.gguf",
            "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
            "local_files_only": True,
        },
        {
            "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
            "filename": "whisper-large-v3-turbo-Q8_0.gguf",
            "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
            "force_download": True,
        },
    ]


def test_transcribe_cpp_cache_probe_checks_only_the_q8_artifact(monkeypatch, tmp_path):
    calls: list[dict] = []
    cached = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    _write_valid_q8(monkeypatch, cached)

    def fake_download(**kwargs):
        calls.append(kwargs)
        return str(cached)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is True
    assert calls == [{
        "repo_id": models.TRANSCRIBE_CPP_Q8_MODEL,
        "filename": "whisper-large-v3-turbo-Q8_0.gguf",
        "revision": "d222c9f621c1128299248f2ded4d8a1820519780",
        "local_files_only": True,
    }]


def test_transcribe_cpp_cache_probe_reports_missing_artifact(monkeypatch):
    def fake_download(**_kwargs):
        raise LocalEntryNotFoundError("not cached")

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fake_download)

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is False


def test_transcribe_cpp_cache_probe_rejects_corrupt_artifact(monkeypatch, tmp_path):
    cached = tmp_path / "whisper-large-v3-turbo-Q8_0.gguf"
    cached.write_bytes(b"corrupt")
    monkeypatch.setattr(
        huggingface_hub, "hf_hub_download", lambda **_kwargs: str(cached))
    monkeypatch.setattr(models, "TRANSCRIBE_CPP_Q8_SHA256", "0" * 64)
    models._verified_sha256.cache_clear()

    assert models.is_cached(models.TRANSCRIBE_CPP_Q8_MODEL) is False
