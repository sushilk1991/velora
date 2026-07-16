"""Resumable meeting transcription and preemptible structured notes."""

import asyncio
import json
import wave
from types import SimpleNamespace
from unittest.mock import AsyncMock

import numpy as np

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

from velora_engine.media import SAMPLE_RATE
from velora_engine.meeting_notes import (
    chunk_transcript,
    fallback_notes,
    merge_notes,
    parse_notes_json,
)


def _write_wav(path, seconds: float = 2.0) -> None:
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    pcm16 = (0.2 * np.sin(2 * np.pi * 330 * t) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm16.tobytes())


async def test_meeting_transcribe_emits_durable_segment_cursor(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "my meeting update")
    eng, sock = engine
    clip = tmp_path / "me.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "job", "meeting_id": "meeting-1",
        "speaker": "me", "path": str(clip), "start_chunk": 0,
    })

    accepted = await client.recv_event("meeting_transcribe_accepted")
    assert accepted["id"] == "job"
    started = await client.recv_event("meeting_transcribe_started")
    assert started["chunks"] == 1
    segment = await client.recv_event("meeting_segment")
    assert segment == {
        "event": "meeting_segment",
        "id": "job",
        "meeting_id": "meeting-1",
        "speaker": "me",
        "chunk_index": 0,
        "start_ms": 0,
        "end_ms": 2000,
        "text": "my meeting update",
    }
    await client.recv_event("meeting_transcribe_progress")
    done = await client.recv_event("meeting_transcribed")
    assert done["meeting_id"] == "meeting-1"
    assert not eng._transcribing

    # Relaunch recovery can ask for chunk 1. The engine decodes metadata but
    # emits no duplicate segment before completing the already-finished track.
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "resume", "meeting_id": "meeting-1",
        "speaker": "me", "path": str(clip), "start_chunk": 1,
    })
    await client.recv_event("meeting_transcribe_accepted")
    resumed = await client.recv_event("meeting_transcribe_started")
    assert resumed["start_chunk"] == 1
    done = await client.recv_event("meeting_transcribed")
    assert done["id"] == "resume"


async def test_meeting_transcribe_rejects_invalid_channel(engine, tmp_path):
    _eng, sock = engine
    clip = tmp_path / "clip.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "meeting_id": "m", "speaker": "Alice",
        "path": str(clip),
    })
    error = await client.recv_event("error")
    assert "speaker must be 'me' or 'them'" in error["message"]


async def test_meeting_busy_failures_have_stable_codes(engine, tmp_path):
    eng, sock = engine
    clip = tmp_path / "clip.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    eng._reprocessing = True
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "busy-track", "meeting_id": "m",
        "speaker": "me", "path": str(clip),
    })
    failed = await client.recv_event("meeting_transcribe_failed")
    assert failed["code"] == "busy"
    eng._reprocessing = False

    eng._transcribing = True
    await client.send_json({
        "cmd": "meeting_notes", "id": "busy-notes", "meeting_id": "m",
        "transcript": "[00:00] Me: update",
    })
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["code"] == "busy"
    eng._transcribing = False


async def test_meeting_notes_fall_back_locally_without_cleanup_model(engine):
    eng, sock = engine
    eng.cleanup = None
    client = await connect(sock)
    await client.recv_event("ready")
    transcript = "[00:00] Me: We should ship Friday.\n[00:05] Them: I agree."
    await client.send_json({
        "cmd": "meeting_notes", "id": "notes", "meeting_id": "m1",
        "transcript": transcript,
    })
    await client.recv_event("meeting_notes_accepted")
    await client.recv_event("meeting_notes_progress")
    ready = await client.recv_event("meeting_notes_ready")
    assert "ship Friday" in ready["summary"]
    assert ready["decisions"] == []
    assert ready["action_items"] == []
    assert not eng._meeting_notes_running


async def test_meeting_notes_return_strict_structured_output(engine):
    eng, sock = engine

    class FakeCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            assert kwargs["check_ratio"] is False
            assert kwargs["cancel_event"] is eng._meeting_notes_preempt
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": "The launch was approved.",
                    "decisions": ["Ship Friday"],
                    "action_items": ["Me: run release QA"],
                }),
            )

    eng.cleanup = FakeCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "structured", "meeting_id": "m2",
        "transcript": "[00:00] Them: The launch is approved. [00:03] Me: I will run QA.",
    })
    await client.recv_event("meeting_notes_accepted")
    await client.recv_event("meeting_notes_progress")
    ready = await client.recv_event("meeting_notes_ready")
    assert ready["summary"] == "The launch was approved."
    assert ready["decisions"] == ["Ship Friday"]
    assert ready["action_items"] == ["Me: run release QA"]


async def test_live_dictation_preempts_and_then_resumes_meeting_notes(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "foreground dictation")
    eng, sock = engine
    generation_started = asyncio.Event()

    class PreemptibleCleanup:
        loaded = True
        unhealthy = False
        calls = 0

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            if self.calls == 1:
                generation_started.set()
                cancel = kwargs["cancel_event"]
                while not cancel.is_set():
                    await asyncio.sleep(0.01)
                return SimpleNamespace(applied=False, text=raw)
            return SimpleNamespace(
                applied=True,
                text='{"summary":"Resumed notes","decisions":[],"action_items":[]}',
            )

    cleanup = PreemptibleCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "preempt", "meeting_id": "m3",
        "transcript": "[00:00] Me: background notes should yield.",
    })
    await client.recv_event("meeting_notes_accepted")
    await asyncio.wait_for(generation_started.wait(), timeout=2)

    await client.send_json({"cmd": "start", "session": "live", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "live"})
    final = await client.recv_event("final", timeout=10)
    assert final["session"] == "live"

    await client.recv_event("meeting_notes_progress", timeout=10)
    ready = await client.recv_event("meeting_notes_ready", timeout=10)
    assert ready["summary"] == "Resumed notes"
    assert cleanup.calls >= 2


def test_meeting_note_helpers_bound_and_validate_generation():
    chunks = chunk_transcript("first\n" + "x" * 25_000, max_chars=12_000)
    assert len(chunks) == 4
    assert all(len(chunk) <= 12_000 for chunk in chunks)
    parsed = parse_notes_json(
        '```json\n{"summary":"S","decisions":["D"],"action_items":["A"]}\n```'
    )
    assert parsed == {"summary": "S", "decisions": ["D"], "action_items": ["A"]}
    assert parse_notes_json("not json") is None
    assert fallback_notes(" ")["summary"] == ""
    merged = merge_notes([
        {"summary": "One", "decisions": ["Ship"], "action_items": ["Test"]},
        {"summary": "Two", "decisions": ["ship"], "action_items": ["Test", "Deploy"]},
    ])
    assert merged["summary"] == "One Two"
    assert merged["decisions"] == ["Ship"]
    assert merged["action_items"] == ["Test", "Deploy"]


async def test_engine_shutdown_emits_terminal_meeting_failures(engine, tmp_path):
    eng, sock = engine
    clip = tmp_path / "shutdown.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")

    eng._send = AsyncMock()
    eng.shutdown.set()
    eng._transcribing = True
    eng._meeting_transcribe_job_id = "shutdown-track"
    await eng._run_meeting_transcribe({
        "path": str(clip), "id": "shutdown-track", "meeting_id": "m-shutdown",
        "speaker": "me", "start_chunk": 0,
    })
    eng._meeting_notes_running = True
    eng._meeting_notes_job_id = "shutdown-notes"
    await eng._run_meeting_notes({
        "id": "shutdown-notes", "meeting_id": "m-shutdown",
        "transcript": "[00:00] Me: shutdown test",
    })

    payloads = [call.args[0] for call in eng._send.await_args_list]
    assert payloads == [
        {
            "event": "meeting_transcribe_failed", "id": "shutdown-track",
            "meeting_id": "m-shutdown", "speaker": "me",
            "code": "engine_shutdown", "error": "engine shutting down",
        },
        {
            "event": "meeting_notes_failed", "id": "shutdown-notes",
            "meeting_id": "m-shutdown", "code": "engine_shutdown",
            "error": "engine shutting down",
        },
    ]
    assert not eng._transcribing
    assert not eng._meeting_notes_running
