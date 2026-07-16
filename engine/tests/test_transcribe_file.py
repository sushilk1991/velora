"""File-transcription command over the real unix socket (fake STT backend):
happy path, dictation priority (job waits for a live session), busy rejection,
cancel, and bad-input errors."""

import asyncio
import wave
from unittest.mock import AsyncMock

import numpy as np
import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

from velora_engine.media import SAMPLE_RATE


def _write_wav(path, seconds: float = 2.0) -> None:
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    pcm16 = (0.3 * np.sin(2 * np.pi * 440 * t) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm16.tobytes())


async def test_transcribe_file_happy_path(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "meeting notes from the file")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)

    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "job1"})

    # Immediate ack, before any decoding (lets the app detect dropped cmds).
    ack = await client.recv_event("transcribe_accepted")
    assert ack["id"] == "job1"

    started = await client.recv_event("transcribe_started")
    assert started["id"] == "job1"
    assert started["chunks"] == 1
    assert abs(started["duration_s"] - 2.0) < 0.3

    progress = await client.recv_event("transcribe_progress")
    assert progress["fraction"] == 1.0

    done = await client.recv_event("transcribed", timeout=10)
    assert done["id"] == "job1"
    assert done["path"] == str(clip)
    assert done["text"] == "meeting notes from the file"
    assert not eng._transcribing


async def test_transcribe_file_applies_explicit_mode(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "meeting notes from the file")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)
    eng._apply_formatting = AsyncMock(
        return_value=("Formatted notes.", "Note", 17, True, "llm"))

    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "formatted",
        "mode": "Note",
    })
    await client.recv_event("transcribe_accepted")
    done = await client.recv_event("transcribed", timeout=10)

    assert done["text"] == "Formatted notes."
    assert done["mode"] == "Note"
    assert done["cleanup_ms"] == 17
    assert done["cleanup_applied"] is True
    eng._apply_formatting.assert_awaited_once_with(
        "meeting notes from the file",
        bundle_id=None,
        app_name="Local file",
        explicit_mode="Note",
        cancel_event=eng._transcribe_preempt,
    )


async def test_explicit_formatting_is_preempted_then_retried_for_dictation(
    engine, tmp_path, monkeypatch
):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "background file words")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)
    generation_started = asyncio.Event()
    file_calls = 0

    async def formatting(raw, *, app_name, cancel_event=None, **_kwargs):
        nonlocal file_calls
        if app_name != "Local file":
            return raw, "Default", 0, False, "foreground"
        file_calls += 1
        if file_calls == 1:
            generation_started.set()
            while not cancel_event.is_set():
                await asyncio.sleep(0.01)
            return raw, "Note", 1, False, "cancelled"
        return "Formatted after dictation.", "Note", 2, True, "llm"

    eng._apply_formatting = formatting
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "preempt-format",
        "mode": "Note",
    })
    await client.recv_event("transcribe_accepted")
    await asyncio.wait_for(generation_started.wait(), timeout=5)

    await client.send_json({"cmd": "start", "session": "foreground", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "foreground"})
    final = await client.recv_event("final", timeout=10)
    assert final["session"] == "foreground"
    done = await client.recv_event("transcribed", timeout=10)
    assert done["text"] == "Formatted after dictation."
    assert file_calls >= 2


async def test_cancel_during_explicit_formatting_never_emits_success(
    engine, tmp_path, monkeypatch
):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "background file words")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)
    generation_started = asyncio.Event()

    async def formatting(raw, *, cancel_event=None, **_kwargs):
        generation_started.set()
        while not cancel_event.is_set():
            await asyncio.sleep(0.01)
        return raw, "Note", 1, False, "cancelled"

    eng._apply_formatting = formatting
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "cancel-format",
        "mode": "Note",
    })
    await client.recv_event("transcribe_accepted")
    await asyncio.wait_for(generation_started.wait(), timeout=5)
    await client.send_json({"cmd": "transcribe_cancel"})
    failed = await client.recv_event("transcribe_failed", timeout=10)
    assert failed["id"] == "cancel-format"
    assert failed["error"] == "cancelled"
    with pytest.raises(asyncio.TimeoutError):
        await client.recv_event("transcribed", timeout=0.5)


async def test_long_explicit_transcript_formats_in_bounded_chunks(
    engine, tmp_path, monkeypatch
):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "word " * 7000)
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)
    sizes = []

    async def formatting(raw, **_kwargs):
        sizes.append(len(raw))
        return raw, "Note", 0, False, "test"

    eng._apply_formatting = formatting
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "bounded",
        "mode": "Note",
    })
    await client.recv_event("transcribe_accepted")
    await client.recv_event("transcribed", timeout=10)
    assert len(sizes) >= 2
    assert max(sizes) <= 12_000


async def test_transcribe_file_rejects_invalid_mode(engine, tmp_path):
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "bad-mode",
        "mode": {"not": "a string"},
    })
    failed = await client.recv_event("transcribe_failed")
    assert failed["id"] == "bad-mode"
    assert failed["error"] == "invalid formatting mode"
    assert not eng._transcribing


async def test_transcribe_file_missing_file(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "transcribe_file", "path": "/nope/x.m4a", "id": "j"})
    evt = await client.recv_event("transcribe_failed")
    assert "not found" in evt["error"]
    assert not eng._transcribing


async def test_transcribe_file_missing_path(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "transcribe_file", "id": "j"})
    evt = await client.recv(timeout=5)
    assert evt["event"] == "error"


async def test_transcribe_waits_for_live_dictation(engine, tmp_path, monkeypatch):
    """Dictation priority: a job started mid-session must not produce its
    result (nor touch the backend) until the session finalizes."""
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "spoken words")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)

    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "live1", "context": {}})
    for _ in range(3):
        await client.send_audio(AUDIO)
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "j2"})
    await client.recv_event("transcribe_started")

    # While the session is open the job stays paused: no transcribed event.
    with pytest.raises(asyncio.TimeoutError):
        await client.recv_event("transcribed", timeout=1.2)

    await client.send_json({"cmd": "stop", "session": "live1"})
    final = await client.recv_event("final", timeout=10)
    assert final["session"] == "live1"
    assert "spoken words" in final["raw"]

    done = await client.recv_event("transcribed", timeout=10)
    assert done["id"] == "j2"
    assert done["text"] == "spoken words"


async def test_transcribe_busy_rejects_second_job(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "text")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)

    client = await connect(sock)
    await client.recv_event("ready")

    # Hold the job paused behind an open session so the second request
    # deterministically sees _transcribing == True.
    await client.send_json({"cmd": "start", "session": "s", "context": {}})
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "a"})
    await client.recv_event("transcribe_started")
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "b"})
    evt = await client.recv_event("transcribe_failed")
    assert evt["id"] == "b"
    assert "already running" in evt["error"]

    await client.send_json({"cmd": "transcribe_cancel"})
    failed = await client.recv_event("transcribe_failed", timeout=10)
    assert failed["id"] == "a"
    assert failed["error"] == "cancelled"
    assert not eng._transcribing
    await client.send_json({"cmd": "cancel", "session": "s"})


async def test_transcribe_cancel_while_paused(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "text")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)

    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "s", "context": {}})
    await client.send_json({"cmd": "transcribe_file", "path": str(clip), "id": "c"})
    await client.recv_event("transcribe_started")
    await client.send_json({"cmd": "transcribe_cancel"})
    failed = await client.recv_event("transcribe_failed", timeout=10)
    assert failed["error"] == "cancelled"
    assert not eng._transcribing
    # The live session is untouched by the cancelled job.
    await client.send_json({"cmd": "stop", "session": "s"})
    final = await client.recv_event("final", timeout=10)
    assert final["session"] == "s"


async def test_transcription_cancellation_is_kind_and_job_scoped(
    engine, tmp_path, monkeypatch
):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "text")
    eng, sock = engine
    clip = tmp_path / "memo.wav"
    _write_wav(clip)

    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "scope", "context": {}})
    await client.send_json({
        "cmd": "transcribe_file", "path": str(clip), "id": "file-job",
    })
    await client.recv_event("transcribe_started")

    await client.send_json({"cmd": "meeting_transcribe_cancel", "id": "meeting-job"})
    await client.send_json({"cmd": "transcribe_cancel", "id": "other-file-job"})
    with pytest.raises(asyncio.TimeoutError):
        await client.recv_event("transcribe_failed", timeout=0.5)
    assert eng._transcribing

    await client.send_json({"cmd": "transcribe_cancel", "id": "file-job"})
    failed = await client.recv_event("transcribe_failed", timeout=10)
    assert failed["id"] == "file-job"
    assert failed["error"] == "cancelled"
    await client.send_json({"cmd": "cancel", "session": "scope"})


async def test_engine_shutdown_emits_terminal_file_failure(engine, tmp_path):
    eng, sock = engine
    clip = tmp_path / "shutdown.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")

    eng._send = AsyncMock()
    eng._transcribing = True
    eng._file_transcribe_job_id = "shutdown-file"
    eng.shutdown.set()
    await eng._run_transcribe_file({"path": str(clip), "id": "shutdown-file"})

    payloads = [call.args[0] for call in eng._send.await_args_list]
    assert payloads == [{
        "event": "transcribe_failed",
        "id": "shutdown-file",
        "error": "engine shutting down",
    }]
    assert not eng._transcribing
