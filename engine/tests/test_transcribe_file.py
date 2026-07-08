"""File-transcription command over the real unix socket (fake STT backend):
happy path, dictation priority (job waits for a live session), busy rejection,
cancel, and bad-input errors."""

import asyncio
import wave

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
