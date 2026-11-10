"""Admission is serialized with batch STT; supplied-only files have no personal hints."""

import asyncio
import threading

import pytest

from test_server import connect, engine  # noqa: F401
from test_transcribe_file import _write_wav
from velora_engine import models, server
from velora_engine.config import Mode


async def _wait_for(condition):
    for _ in range(200):
        if condition():
            return
        await asyncio.sleep(0.005)
    raise AssertionError("condition did not settle")


async def test_keyboard_admission_does_not_change_language_of_running_decode(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    eng.stt.language = "en"
    entered, release = threading.Event(), threading.Event()
    languages = []

    def batch_decode():
        languages.append(eng.stt.language)
        entered.set()
        release.wait(3)
        languages.append(eng.stt.language)

    decode = asyncio.create_task(eng._stt_call(batch_decode))
    try:
        assert await asyncio.to_thread(entered.wait, 1)
        await client.send_json({"cmd": "start", "session": "serialized-language", "context": {
            "keyboard_route": {"input_source": "test.source", "language": "hi", "model": eng.stt.model_id}}})
        await _wait_for(lambda: eng._starting)
        await asyncio.sleep(.02)
        assert eng.stt.language == "en"
        release.set()
        await decode
        await client.recv_event("session_route")
        assert languages == ["en", "en"]
        assert eng._session_stt(eng.session).language == "hi"
        await client.send_json({"cmd": "cancel", "session": "serialized-language"})
        await client.recv_event("cancelled")
    finally:
        release.set()
        await decode


async def test_failed_admission_restores_the_backend_language(engine, monkeypatch):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    eng.stt.language = "en"
    eng.stt.initial_prompt = "existing batch hints"

    def fails():
        assert eng.stt.language == "hi"
        raise RuntimeError("cannot begin the take")

    monkeypatch.setattr(eng.stt, "start_session", fails)
    await client.send_json({"cmd": "start", "session": "failed-language", "context": {
        "keyboard_route": {"input_source": "test.source", "language": "hi", "model": eng.stt.model_id}}})
    await client.recv_event("error")
    await _wait_for(lambda: eng._start_task is None)
    assert eng.stt.language == "en"
    assert eng.stt.initial_prompt == "existing batch hints"
    assert eng.session is None


async def test_cancelled_admission_restores_language_before_the_next_take(engine, monkeypatch):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    eng.config.data["language"] = "en"
    eng.stt.language = "en"
    entered, release = threading.Event(), threading.Event()
    begin = eng.stt.start_session
    calls = 0

    def blocked_begin():
        nonlocal calls
        calls += 1
        if calls == 1:
            entered.set()
            release.wait(3)
        begin()

    monkeypatch.setattr(eng.stt, "start_session", blocked_begin)
    try:
        await client.send_json({"cmd": "start", "session": "cancelled-language", "context": {
            "keyboard_route": {"input_source": "test.source", "language": "hi", "model": eng.stt.model_id}}})
        assert await asyncio.to_thread(entered.wait, 1)
        await client.send_json({"cmd": "cancel", "session": "cancelled-language"})
        await client.recv_event("cancelled", timeout=1)
        await client.send_json({"cmd": "start", "session": "next-language", "context": {
            "keyboard_route": {"input_source": "test.source", "language": "es", "model": eng.stt.model_id}}})
        release.set()
        route = await client.recv_event("session_route")
        assert route["session"] == "next-language" and eng.stt.language == "es"
        await client.send_json({"cmd": "cancel", "session": "next-language"})
        await client.recv_event("cancelled")
        await _wait_for(lambda: eng._cancel_active_task is None and not eng._starting)
        assert eng.stt.language == "en"
    finally:
        release.set()


async def test_cold_keyboard_load_announces_stop_wait_bound(engine, monkeypatch, tmp_path):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    entered, release = asyncio.Event(), asyncio.Event()
    monkeypatch.setattr(models, "cached_model_path", lambda _: str(tmp_path))

    async def load(backend, path, **kwargs):
        entered.set()
        await release.wait()

    monkeypatch.setattr(eng, "_load_stt_local", load)
    try:
        await client.send_json({"cmd": "start", "session": "cold-language", "context": {
            "keyboard_route": {"input_source": "test.source", "language": "es",
                               "model": "mlx-community/whisper-large-v3-mlx"}}})
        await asyncio.wait_for(entered.wait(), 1)
        assert eng._start_wait_deadline is not None
        await client.send_json({"cmd": "stop", "session": "cold-language"})
        progress = await client.recv_event("finalize_started", timeout=1)
        assert progress["session"] == "cold-language" and progress["stall_after_s"] > 50
        release.set()
        assert (await client.recv_event("final"))["session"] == "cold-language"
    finally:
        release.set()


async def test_agent_file_formatting_cannot_read_personal_dictionary(engine, monkeypatch, tmp_path):
    eng, sock = engine
    clip = tmp_path / "supplied.wav"
    _write_wav(clip)
    eng.config.data.update(vocabulary=["SecretProduct"], replacements={"project": "PRIVATE-VALUE"})
    eng.config._learned_vocab = ["LearnedSecret"]
    eng.config._learned_soft = {"project": "SoftSecret"}
    prompts = []

    def transcribe(backend, chunk):
        prompts.append(backend.initial_prompt)
        return "project"

    monkeypatch.setattr(server, "transcribe_clip", transcribe)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "supplied",
                            "mode": "Default", "personal_context": False})
    result = await client.recv_event("transcribed")
    assert prompts == [None]
    assert "PRIVATE-VALUE" not in result["text"] and "Secret" not in result["text"]


async def test_agent_file_rejects_saved_custom_mode(engine, tmp_path):
    eng, sock = engine
    clip = tmp_path / "supplied.wav"
    _write_wav(clip)
    eng.config.modes["private"] = Mode(name="Private", formatting="off", prompt="Private instructions")
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "private-mode",
                            "mode": "Private", "personal_context": False})
    result = await client.recv_event("transcribe_failed")
    assert result["id"] == "private-mode" and "mode" in result["error"].lower()
