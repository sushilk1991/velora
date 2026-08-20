"""Resumable meeting transcription and preemptible structured notes."""

# The imported pytest fixture intentionally shares its name with test parameters.
# ruff: noqa: F811

import asyncio
import contextlib
import json
import shutil
import tempfile
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import numpy as np
import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

from velora_engine.media import SAMPLE_RATE, load_media
from velora_engine.meeting_notes import (
    chunk_transcript,
    merge_notes,
    parse_notes_json,
)
from velora_engine.config import Config
from velora_engine.server import Engine


@pytest.fixture(autouse=True)
def decode_protocol_fixtures_with_generic_media(monkeypatch):
    """Keep protocol tests independent from the production CAF trust boundary."""
    from velora_engine import server as server_mod

    monkeypatch.setattr(
        server_mod,
        "load_meeting_media",
        lambda path, *, meeting_root: load_media(path),
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


async def test_meeting_transcribe_uses_app_owned_source_limit(engine, monkeypatch):
    from velora_engine import server as server_mod

    seen = {}

    def fake_load(path, *, meeting_root):
        seen["path"] = path
        seen["meeting_root"] = meeting_root
        return np.tile(AUDIO, 3)

    monkeypatch.setattr(server_mod, "load_meeting_media", fake_load)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "meeting words")
    _eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "large",
        "meeting_id": "meeting-large", "speaker": "me",
        "path": "/app-owned/meeting.caf", "start_chunk": 0,
    })

    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    await client.recv_event("meeting_segment")
    await client.recv_event("meeting_transcribe_progress")
    await client.recv_event("meeting_transcribed")

    assert seen["path"] == "/app-owned/meeting.caf"
    assert seen["meeting_root"] == _eng.config.home / "meetings"


async def test_dense_remote_track_skips_expensive_diarization(
    engine, tmp_path, monkeypatch, caplog
):
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "dense meeting words")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(
        diar_mod,
        "ensure_models",
        lambda: pytest.fail("dense track must skip diarization models"),
    )
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.43)
    caplog.set_level("INFO", logger="velora.server")
    _eng, sock = engine
    clip = tmp_path / "dense-them.wav"
    _write_wav(clip, seconds=10.0)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "dense",
        "meeting_id": "meeting-dense", "speaker": "them",
        "path": str(clip), "start_chunk": 0,
    })

    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    await client.recv_event("meeting_segment")
    await client.recv_event("meeting_transcribe_progress")
    await client.recv_event("meeting_transcribed")

    assert any(
        "diarization: meeting-dense skipping CPU plan for 43% active track"
        in record.message
        for record in caplog.records
    )


async def test_long_remote_track_skips_diarization_before_activity_scan(
    engine, tmp_path, monkeypatch, caplog
):
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "long meeting words")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(server_mod, "_DIARIZATION_MAX_TRACK_S", 5)
    monkeypatch.setattr(
        server_mod,
        "speech_window_fraction",
        lambda _pcm: pytest.fail("long track must skip the activity scan"),
    )
    monkeypatch.setattr(
        diar_mod,
        "ensure_models",
        lambda: pytest.fail("long track must skip diarization models"),
    )
    caplog.set_level("INFO", logger="velora.server")
    _eng, sock = engine
    clip = tmp_path / "long-them.wav"
    _write_wav(clip, seconds=10.0)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "long",
        "meeting_id": "meeting-long", "speaker": "them",
        "path": str(clip), "start_chunk": 0,
    })

    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    await client.recv_event("meeting_segment")
    await client.recv_event("meeting_transcribe_progress")
    await client.recv_event("meeting_transcribed")

    assert any(
        "diarization: meeting-long skipping CPU plan for 10s long track"
        in record.message
        for record in caplog.records
    )


async def test_meeting_transcribe_keeps_audio_only_clusters_labeled_them(
    engine, tmp_path, monkeypatch
):
    """Audio clusters improve speech chunking but cannot establish identity."""
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod
    from velora_engine.diarization import Turn

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "diarized words")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(diar_mod, "ensure_models", lambda: None)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.4)
    monkeypatch.setattr(
        diar_mod, "diarize",
        lambda pcm: [Turn(0.0, 4.0, "s1"), Turn(4.6, 9.5, "s2")])
    _eng, sock = engine
    clip = tmp_path / "them.wav"
    _write_wav(clip, seconds=10.0)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "djob", "meeting_id": "meeting-d",
        "speaker": "them", "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    started = await client.recv_event("meeting_transcribe_started")
    assert started["chunks"] == 1
    assert started["speaker"] == "them"

    segment = await client.recv_event("meeting_segment")
    assert segment["speaker"] == "them"
    assert segment["chunk_index"] == 0
    assert segment["start_ms"] == 0
    assert segment["end_ms"] >= 9500
    await client.recv_event("meeting_transcribe_progress")
    done = await client.recv_event("meeting_transcribed")
    assert done["chunks"] == 1


async def test_meeting_transcribe_single_speaker_falls_back_to_them(
    engine, tmp_path, monkeypatch
):
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod
    from velora_engine.diarization import Turn

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "solo caller")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(diar_mod, "ensure_models", lambda: None)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.4)
    monkeypatch.setattr(diar_mod, "diarize", lambda pcm: [Turn(0.0, 2.0, "s1")])
    _eng, sock = engine
    clip = tmp_path / "them.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "sjob", "meeting_id": "meeting-s",
        "speaker": "them", "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    segment = await client.recv_event("meeting_segment")
    assert segment["speaker"] == "them"  # 1:1 call reads as plain Them


async def test_meeting_transcribe_five_clusters_still_uses_stable_them(
    engine, tmp_path, monkeypatch
):
    """Plausible-looking cluster counts still do not establish identity."""
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod
    from velora_engine.diarization import Turn

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "stable five-cluster words")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(diar_mod, "ensure_models", lambda: None)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.4)
    monkeypatch.setattr(
        diar_mod,
        "diarize",
        lambda pcm: [
            Turn(float(index * 2), float(index * 2) + 1.5, f"s{index + 1}")
            for index in range(5)
        ],
    )
    _eng, sock = engine
    clip = tmp_path / "five-clusters.wav"
    _write_wav(clip, seconds=10.0)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "five", "meeting_id": "meeting-five",
        "speaker": "them", "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    started = await client.recv_event("meeting_transcribe_started")
    assert started["chunks"] == 1
    segment = await client.recv_event("meeting_segment")
    assert segment["speaker"] == "them"
    assert segment["text"] == "stable five-cluster words"


async def test_meeting_transcribe_implausible_clusters_fall_back_to_them(
    engine, tmp_path, monkeypatch
):
    """Cluster explosions must not become hundreds of tiny speaker chunks."""
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod
    from velora_engine.diarization import Turn

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "stable words")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(diar_mod, "ensure_models", lambda: None)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.4)
    monkeypatch.setattr(
        diar_mod,
        "diarize",
        lambda pcm: [
            Turn(float(index), float(index) + 0.8, f"s{index + 1}")
            for index in range(12)
        ],
    )
    _eng, sock = engine
    clip = tmp_path / "clustered.wav"
    _write_wav(clip, seconds=12.0)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "cjob", "meeting_id": "meeting-c",
        "speaker": "them", "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    started = await client.recv_event("meeting_transcribe_started")
    assert started["chunks"] == 1
    segment = await client.recv_event("meeting_segment")
    assert segment["speaker"] == "them"
    assert segment["text"] == "stable words"


async def test_meeting_transcribe_diarization_failure_falls_back(
    engine, tmp_path, monkeypatch
):
    from velora_engine import diarization as diar_mod
    from velora_engine import server as server_mod

    def boom(pcm):
        raise RuntimeError("onnx exploded")

    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "still transcribed")
    monkeypatch.setattr(diar_mod, "available", lambda: True)
    monkeypatch.setattr(diar_mod, "ensure_models", lambda: None)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _pcm: 0.4)
    monkeypatch.setattr(diar_mod, "diarize", boom)
    _eng, sock = engine
    clip = tmp_path / "them.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "fjob", "meeting_id": "meeting-f",
        "speaker": "them", "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    segment = await client.recv_event("meeting_segment")
    assert segment["speaker"] == "them"
    assert segment["text"] == "still transcribed"


async def test_meeting_glossary_excludes_auto_mined_terms(engine) -> None:
    eng, _sock = engine
    eng.config.data["vocabulary"] = ["Velora"]
    eng.config._learned_vocab = ["Sushil"]
    eng.config._auto_vocab = ["random-hallucination"]
    prompt = eng._meeting_glossary()
    assert prompt is not None
    assert "Velora" in prompt and "Sushil" in prompt
    assert "random-hallucination" not in prompt


async def test_old_meeting_plan_version_is_rejected(engine, tmp_path) -> None:
    eng, _sock = engine
    plan = tmp_path / "old-plan.json"
    plan.write_text(json.dumps({
        "version": 2,
        "spans": [[0, 16_000, "s1"]],
    }))
    assert eng._load_meeting_plan(plan, 32_000) is None


async def test_meeting_resume_without_cached_plan_restarts_track(
    engine, tmp_path, monkeypatch, caplog
):
    """A resume cursor whose chunk plan is gone (crash before the cache was
    written, or an upgraded install) must restart from zero and say so —
    silently emitting `meeting_transcribed` with nothing would truncate the
    transcript."""
    caplog.set_level("INFO", logger="velora.server")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "recovered words")
    _eng, sock = engine
    clip = tmp_path / "them.wav"
    _write_wav(clip)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "r1", "meeting_id": "meeting-lost-plan",
        "speaker": "them", "path": str(clip), "start_chunk": 5,
    })
    await client.recv_event("meeting_transcribe_accepted")
    # Loading and planning a restarted remote track can exceed the generic
    # five-second protocol timeout under branch-coverage instrumentation.
    # This assertion is about restart correctness, not startup latency.
    started = await client.recv_event("meeting_transcribe_started", timeout=15)
    assert started["restarted"] is True
    assert started["start_chunk"] == 0
    segment = await client.recv_event("meeting_segment")
    assert segment["chunk_index"] == 0
    assert segment["text"] == "recovered words"
    await client.recv_event("meeting_transcribed")

    # Now the plan is cached — a legit resume past the end completes quietly.
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "r2", "meeting_id": "meeting-lost-plan",
        "speaker": "them", "path": str(clip), "start_chunk": 1,
    })
    await client.recv_event("meeting_transcribe_accepted")
    resumed = await client.recv_event("meeting_transcribe_started")
    assert resumed["restarted"] is False
    assert resumed["start_chunk"] == 1
    done = await client.recv_event("meeting_transcribed")
    assert done["id"] == "r2"
    assert any(
        "meeting transcription done meeting-lost-plan/them" in record.message
        and "0/1 chunks processed this attempt" in record.message
        for record in caplog.records
    )


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


async def test_meeting_notes_fail_honestly_without_cleanup_model(engine):
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
    failed = await client.recv()
    assert failed["event"] == "meeting_notes_failed"
    assert failed["code"] == "generation_failed"
    assert "model" in failed["error"].lower()
    assert not eng._meeting_notes_running


async def test_meeting_notes_wait_for_real_cleanup_startup_lifecycle(
    home, monkeypatch
):
    from velora_engine import models
    from velora_engine import server as server_mod

    allow_model_ready = asyncio.Event()

    class LoadingCleanup:
        loaded = False
        unhealthy = False
        calls = 0
        model_id = "test/meeting-notes"

        async def load_async(self, _prompt):
            await allow_model_ready.wait()
            self.loaded = True

        async def aclose(self):
            return None

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": "Recovered after model warm-up.",
                    "decisions": [],
                    "action_items": [],
                }),
            )

    config = Config(home)
    config.data.update({
        "cleanup_enabled": True,
        "cleanup_model": LoadingCleanup.model_id,
        "save_audio": False,
    })
    cleanup = LoadingCleanup()
    eng = Engine(config, parent_pid=None, hard_exit=Mock())
    eng._stt_call = AsyncMock(return_value=None)
    eng._prune_superseded_models = AsyncMock(return_value=None)
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(models, "is_cached", lambda _model_id: True)
    monkeypatch.setattr(eng, "_new_cleanup_process", lambda _model_id: cleanup)

    sock_dir = Path(tempfile.mkdtemp(prefix="velora-meeting-startup-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    try:
        for _ in range(100):
            if sock.exists():
                break
            await asyncio.sleep(0.01)
        client = await connect(sock)
        await client.recv_event("ready")
        assert eng.cleanup is None
        assert eng._cleanup_loading is cleanup

        await client.send_json({
            "cmd": "meeting_notes", "id": "startup-notes",
            "meeting_id": "m-startup",
            "transcript": "[00:00] Me: Resume these saved notes on launch.",
        })
        await client.recv_event("meeting_notes_accepted")
        await asyncio.sleep(0.15)
        assert cleanup.calls == 0

        allow_model_ready.set()
        ready = await client.recv_event("meeting_notes_ready")
        assert ready["summary"] == "Recovered after model warm-up."
        assert cleanup.calls == 1
        assert eng.cleanup is cleanup
        assert eng._cleanup_loading is None
        assert not eng._meeting_notes_running
        client.close()
        await client.writer.wait_closed()
    finally:
        allow_model_ready.set()
        eng.shutdown.set()
        with contextlib.suppress(asyncio.CancelledError):
            await asyncio.wait_for(task, 5)
        shutil.rmtree(sock_dir, ignore_errors=True)


async def test_cleanup_startup_replacement_and_failure_close_only_their_worker(
    home, monkeypatch
):
    from velora_engine import models
    from velora_engine import server as server_mod

    class Cleanup:
        loaded = False
        unhealthy = False
        model_id = "test/startup-lifecycle"

        def __init__(self, *, failure: bool = False):
            self.failure = failure
            self.allow_load = asyncio.Event()
            self.load_started = asyncio.Event()
            self.close_calls = 0

        async def load_async(self, _prompt):
            self.load_started.set()
            await self.allow_load.wait()
            if self.failure:
                raise RuntimeError("fixture load failure")
            self.loaded = True

        async def aclose(self):
            self.close_calls += 1

    async def configured_engine(cleanup):
        config = Config(home)
        config.data.update({
            "cleanup_enabled": True,
            "cleanup_model": Cleanup.model_id,
            "save_audio": False,
        })
        eng = Engine(config, parent_pid=None, hard_exit=Mock())
        eng._stt_call = AsyncMock(return_value=None)
        eng._prune_superseded_models = AsyncMock(return_value=None)
        monkeypatch.setattr(eng, "_new_cleanup_process", lambda _model_id: cleanup)
        return eng

    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(models, "is_cached", lambda _model_id: True)

    superseded = Cleanup()
    eng = await configured_engine(superseded)
    load = asyncio.create_task(eng._load_models())
    await superseded.load_started.wait()
    replacement = Cleanup()
    replacement.loaded = True
    eng.cleanup = replacement
    superseded.allow_load.set()
    await load
    assert eng.cleanup is replacement
    assert eng._cleanup_loading is None
    assert superseded.close_calls == 1
    assert replacement.close_calls == 0

    failed = Cleanup(failure=True)
    failed_eng = await configured_engine(failed)
    failed_load = asyncio.create_task(failed_eng._load_models())
    await failed.load_started.wait()
    failed.allow_load.set()
    await failed_load
    assert failed_eng.cleanup is None
    assert failed_eng._cleanup_loading is None
    assert failed_eng.setup_complete is True
    assert failed.close_calls == 1


async def test_serve_waits_for_loading_cleanup_to_close_on_shutdown(home, monkeypatch):
    from velora_engine import models
    from velora_engine import server as server_mod

    class LoadingCleanup:
        loaded = False
        unhealthy = False
        model_id = "test/shutdown-loading-cleanup"

        def __init__(self):
            self.load_started = asyncio.Event()
            self.close_started = asyncio.Event()
            self.allow_close = asyncio.Event()
            self.close_calls = 0

        async def load_async(self, _prompt):
            self.load_started.set()
            await asyncio.Event().wait()

        async def aclose(self):
            self.close_calls += 1
            self.close_started.set()
            await self.allow_close.wait()

    config = Config(home)
    config.data.update({
        "cleanup_enabled": True,
        "cleanup_model": LoadingCleanup.model_id,
        "save_audio": False,
    })
    cleanup = LoadingCleanup()
    eng = Engine(config, parent_pid=None, hard_exit=Mock())
    eng._stt_call = AsyncMock(return_value=None)
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(models, "is_cached", lambda _model_id: True)
    monkeypatch.setattr(eng, "_new_cleanup_process", lambda _model_id: cleanup)

    sock_dir = Path(tempfile.mkdtemp(prefix="velora-cleanup-shutdown-"))
    task = asyncio.create_task(eng.serve(sock_dir / "e.sock"))
    try:
        await asyncio.wait_for(cleanup.load_started.wait(), 2)
        assert eng._cleanup_loading is cleanup
        eng.shutdown.set()
        await asyncio.wait_for(cleanup.close_started.wait(), 2)
        await asyncio.sleep(0.05)
        assert not task.done(), "serve returned before the loading worker was reaped"
        cleanup.allow_close.set()
        await asyncio.wait_for(task, 2)
        assert cleanup.close_calls == 1
        assert eng.cleanup is None
        assert eng._cleanup_loading is None
    finally:
        cleanup.allow_close.set()
        eng.shutdown.set()
        if not task.done():
            await asyncio.wait_for(task, 2)
        shutil.rmtree(sock_dir, ignore_errors=True)


async def test_replaced_startup_cleanup_closes_once_when_shutdown_interrupts_close(
    home, monkeypatch
):
    from velora_engine import models
    from velora_engine import server as server_mod

    class StartupCleanup:
        loaded = False
        unhealthy = False
        model_id = "test/replaced-startup-shutdown"

        def __init__(self):
            self.load_started = asyncio.Event()
            self.allow_load = asyncio.Event()
            self.close_started = asyncio.Event()
            self.allow_close = asyncio.Event()
            self.close_calls = 0

        async def load_async(self, _prompt):
            self.load_started.set()
            await self.allow_load.wait()
            self.loaded = True

        async def aclose(self):
            self.close_calls += 1
            self.close_started.set()
            await self.allow_close.wait()

    class ReplacementCleanup:
        loaded = True
        unhealthy = False
        model_id = "test/replacement"

        def __init__(self):
            self.close_calls = 0

        async def aclose(self):
            self.close_calls += 1

    config = Config(home)
    config.data.update({
        "cleanup_enabled": True,
        "cleanup_model": StartupCleanup.model_id,
        "save_audio": False,
    })
    startup = StartupCleanup()
    replacement = ReplacementCleanup()
    eng = Engine(config, parent_pid=None, hard_exit=Mock())
    eng._stt_call = AsyncMock(return_value=None)
    monkeypatch.setattr(server_mod, "fake_stt_enabled", lambda: False)
    monkeypatch.setattr(models, "is_cached", lambda _model_id: True)
    monkeypatch.setattr(eng, "_new_cleanup_process", lambda _model_id: startup)

    sock_dir = Path(tempfile.mkdtemp(prefix="velora-cleanup-replaced-shutdown-"))
    task = asyncio.create_task(eng.serve(sock_dir / "e.sock"))
    try:
        await asyncio.wait_for(startup.load_started.wait(), 2)
        eng.cleanup = replacement
        startup.allow_load.set()
        await asyncio.wait_for(startup.close_started.wait(), 2)

        eng.shutdown.set()
        await asyncio.sleep(0.05)
        assert startup.close_calls == 1
        assert not task.done(), "serve returned before the one startup close completed"

        startup.allow_close.set()
        await asyncio.wait_for(task, 2)
        assert startup.close_calls == 1
        assert replacement.close_calls == 1
        assert eng.cleanup is None
        assert eng._cleanup_loading is None
    finally:
        startup.allow_load.set()
        startup.allow_close.set()
        eng.shutdown.set()
        if not task.done():
            await asyncio.wait_for(task, 2)
        shutil.rmtree(sock_dir, ignore_errors=True)


async def test_meeting_notes_model_failure_is_not_reported_as_ready(engine):
    eng, sock = engine

    class TimedOutCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            return SimpleNamespace(
                applied=False, text=raw, reason="timeout_hard")

    eng.cleanup = TimedOutCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    transcript = "[00:00] Me: We should ship Friday.\n[00:05] Them: I agree."
    await client.send_json({
        "cmd": "meeting_notes", "id": "timed-out", "meeting_id": "m-timeout",
        "transcript": transcript,
    })
    await client.recv_event("meeting_notes_accepted")
    failed = await client.recv()
    assert failed["event"] == "meeting_notes_failed"
    assert failed["code"] == "generation_failed"
    assert "timeout_hard" in failed["error"]
    assert not eng._meeting_notes_running


async def test_meeting_notes_return_strict_structured_output(engine):
    eng, sock = engine

    class FakeCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            assert kwargs["check_ratio"] is False
            assert kwargs["cancel_event"] is eng._meeting_notes_preempt
            assert kwargs["timeout_ms"] == 20_000
            assert kwargs["max_tokens"] == 384
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


async def test_meeting_notes_multi_chunk_reduce_failure_keeps_valid_map_notes(engine):
    eng, sock = engine

    class ReduceFailureCleanup:
        loaded = True
        unhealthy = False
        calls = 0

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            if self.calls <= 2:
                assert len(raw) <= 4_000
                assert kwargs["max_tokens"] == 384
            if self.calls == 1:
                return SimpleNamespace(
                    applied=True,
                    text=json.dumps({
                        "summary": "First section.",
                        "decisions": ["Ship Friday"],
                        "action_items": ["Run QA", "A2", "A3", "A4", "A5"],
                    }),
                )
            if self.calls == 2:
                return SimpleNamespace(
                    applied=True,
                    text=json.dumps({
                        "summary": "Second section.",
                        "decisions": ["ship friday"],
                        "action_items": ["Deploy", "A7", "A8", "A9", "A10"],
                    }),
                )
            reduced_input = json.loads(raw)
            assert kwargs["max_tokens"] == 512
            assert isinstance(reduced_input, dict)
            assert set(reduced_input) == {"summary", "decisions", "action_items"}
            assert len(reduced_input["action_items"]) == 8
            return SimpleNamespace(
                applied=False, text=raw, reason="timeout_hard")

    cleanup = ReduceFailureCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "multi", "meeting_id": "m-multi",
        "transcript": "x" * 4_001,
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert cleanup.calls == 3
    assert ready["summary"] == "First section. Second section."
    assert ready["decisions"] == ["Ship Friday"]
    assert ready["action_items"] == [
        "Run QA", "A2", "A3", "A4", "A5", "Deploy", "A7", "A8",
    ]


async def test_meeting_notes_retries_failed_map_as_smaller_pieces(engine):
    eng, sock = engine

    class RetryCleanup:
        loaded = True
        unhealthy = False
        calls: list[tuple[int, int]] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls.append((len(raw), kwargs["max_tokens"]))
            if len(self.calls) == 1:
                return SimpleNamespace(
                    applied=False, text=raw, reason="timeout_hard")
            if kwargs["max_tokens"] == 512:
                return SimpleNamespace(
                    applied=True,
                    text=json.dumps({
                        "summary": "Recovered final notes.",
                        "decisions": ["Keep the bounded retry"],
                        "action_items": [],
                    }),
                )
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": f"Recovered part {len(self.calls) - 1}.",
                    "decisions": [],
                    "action_items": [],
                }),
            )

    cleanup = RetryCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "retry-small", "meeting_id": "m-retry",
        "transcript": "x" * 3_999,
    })
    await client.recv_event("meeting_notes_accepted")
    await client.recv_event("meeting_notes_progress")
    ready = await client.recv_event("meeting_notes_ready")

    assert ready["summary"] == "Recovered final notes."
    assert cleanup.calls[:3] == [(3_999, 384), (2_000, 384), (1_999, 384)]
    assert cleanup.calls[3][1] == 512


async def test_meeting_notes_retries_short_failed_map_once(engine):
    eng, sock = engine

    class RetryCleanup:
        loaded = True
        unhealthy = False
        calls: list[tuple[int, int]] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls.append((len(raw), kwargs["max_tokens"]))
            if len(self.calls) == 1:
                return SimpleNamespace(
                    applied=False, text=raw, reason="timeout_hard")
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": "Recovered short tail.",
                    "decisions": [],
                    "action_items": [],
                }),
            )

    cleanup = RetryCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "retry-tail",
        "meeting_id": "m-retry-tail", "transcript": "x" * 1_500,
    })
    await client.recv_event("meeting_notes_accepted")
    await client.recv_event("meeting_notes_progress")
    ready = await client.recv_event("meeting_notes_ready")

    assert ready["summary"] == "Recovered short tail."
    assert cleanup.calls == [(1_500, 384), (1_500, 384)]


async def test_meeting_notes_unhealthy_worker_restarts_without_failure_event(engine):
    eng, _sock = engine

    class UnhealthyCleanup:
        loaded = True
        unhealthy = False
        calls = 0

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            self.loaded = False
            self.unhealthy = True
            return SimpleNamespace(
                applied=False, text=raw, reason="timeout_hard")

    cleanup = UnhealthyCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    eng._meeting_notes_running = True

    await eng._run_meeting_notes({
        "id": "unhealthy-notes", "meeting_id": "m-unhealthy",
        "transcript": "x" * 3_999,
    })

    sent = [call.args[0] for call in eng._send.await_args_list]
    assert cleanup.calls == 1
    assert eng.shutdown.is_set()
    assert not any(item.get("event") == "meeting_notes_failed" for item in sent)
    assert not eng._meeting_notes_running


async def test_meeting_notes_recovering_worker_restarts_without_failure_event(
    engine, monkeypatch
):
    from velora_engine import server as server_mod

    eng, _sock = engine
    monkeypatch.setattr(server_mod, "MEETING_NOTES_MODEL_READY_WAIT_S", 0.0)

    class RecoveringCleanup:
        loaded = True
        unhealthy = False
        recovering = False
        calls = 0

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            self.loaded = False
            self.recovering = True
            return SimpleNamespace(
                applied=False, text=raw, reason="timeout_hard")

    cleanup = RecoveringCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    eng._meeting_notes_running = True

    await eng._run_meeting_notes({
        "id": "recovering-notes", "meeting_id": "m-recovering",
        "transcript": "x" * 3_999,
    })

    sent = [call.args[0] for call in eng._send.await_args_list]
    assert cleanup.calls == 1
    assert eng.shutdown.is_set()
    assert not any(item.get("event") == "meeting_notes_failed" for item in sent)
    assert not eng._meeting_notes_running


async def test_meeting_notes_cancel_during_recovery_wait_does_not_restart(engine):
    eng, sock = engine

    class RecoveringCleanup:
        unhealthy = False
        recovering = False
        calls = 0

        def __init__(self):
            self._loaded = True
            self.retry_wait_started = asyncio.Event()

        @property
        def loaded(self):
            if not self._loaded:
                self.retry_wait_started.set()
            return self._loaded

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            self._loaded = False
            self.recovering = True
            return SimpleNamespace(
                applied=False, text=raw, reason="timeout_hard")

    cleanup = RecoveringCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "cancel-recovery",
        "meeting_id": "m-cancel-recovery", "transcript": "x" * 3_999,
    })
    await client.recv_event("meeting_notes_accepted")
    await asyncio.wait_for(cleanup.retry_wait_started.wait(), timeout=2)
    await client.send_json({
        "cmd": "meeting_notes_cancel", "id": "cancel-recovery",
    })
    failed = await client.recv_event("meeting_notes_failed")

    assert failed["code"] == "cancelled"
    assert cleanup.calls == 1
    assert not eng.shutdown.is_set()
    assert not eng._meeting_notes_running


async def test_meeting_notes_schema_invalid_output_is_not_reported_as_ready(engine):
    eng, sock = engine

    class InvalidCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": 42,
                    "decisions": "Ship",
                    "action_items": [{"raw": "transcript excerpt"}],
                    "extra": "unexpected",
                }),
            )

    eng.cleanup = InvalidCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "invalid-schema",
        "meeting_id": "m-invalid", "transcript": "[00:00] Me: update",
    })
    await client.recv_event("meeting_notes_accepted")
    failed = await client.recv()
    assert failed["event"] == "meeting_notes_failed"
    assert failed["code"] == "generation_failed"


async def test_meeting_notes_cancel_during_reduce_never_emits_ready(engine):
    eng, sock = engine
    reduce_started = asyncio.Event()

    class CancelDuringReduceCleanup:
        loaded = True
        unhealthy = False
        calls = 0

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls += 1
            if self.calls <= 2:
                return SimpleNamespace(
                    applied=True,
                    text=json.dumps({
                        "summary": f"Section {self.calls}.",
                        "decisions": [],
                        "action_items": [],
                    }),
                )
            reduce_started.set()
            cancel = kwargs["cancel_event"]
            while not cancel.is_set():
                await asyncio.sleep(0.01)
            return SimpleNamespace(applied=False, text=raw, reason="cancelled")

    cleanup = CancelDuringReduceCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "cancel-reduce",
        "meeting_id": "m-cancel-reduce", "transcript": "x" * 4_001,
    })
    await client.recv_event("meeting_notes_accepted")
    await asyncio.wait_for(reduce_started.wait(), timeout=2)
    await client.send_json({
        "cmd": "meeting_notes_cancel", "id": "cancel-reduce",
    })
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["code"] == "cancelled"
    assert cleanup.calls == 3
    assert not eng._meeting_notes_running


async def test_meeting_notes_custom_prompt_keeps_schema_clause(engine):
    eng, sock = engine
    seen_prompts: list[str] = []

    class CapturingCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            seen_prompts.append(system_prompt)
            return SimpleNamespace(
                applied=True,
                text='{"summary":"Styled notes","decisions":[],"action_items":[]}',
            )

    eng.cleanup = CapturingCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "styled", "meeting_id": "m3",
        "transcript": "[00:00] Me: Keep the roadmap focused on retention.",
        "prompt": "Write terse, bullet-first notes aimed at a founder.",
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert ready["summary"] == "Styled notes"
    # The custom guidance leads the prompt, and the non-editable JSON schema
    # clause still rides along so parsing cannot be broken from Settings.
    assert seen_prompts, "the cleanup model never saw a prompt"
    assert seen_prompts[0].startswith("Write terse, bullet-first notes")
    assert "Return JSON only with exact keys summary" in seen_prompts[0]


async def test_meeting_notes_default_prompt_used_when_absent(engine):
    eng, sock = engine
    seen_prompts: list[str] = []

    class CapturingCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            seen_prompts.append(system_prompt)
            return SimpleNamespace(
                applied=True,
                text='{"summary":"Default notes","decisions":[],"action_items":[]}',
            )

    eng.cleanup = CapturingCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "plain", "meeting_id": "m4",
        "transcript": "[00:00] Me: Nothing custom here.",
    })
    await client.recv_event("meeting_notes_accepted")
    await client.recv_event("meeting_notes_ready")
    assert seen_prompts[0].startswith("Create faithful meeting notes")
    assert "Return JSON only with exact keys summary" in seen_prompts[0]


async def test_meeting_notes_truncates_oversized_prompt(engine):
    eng, sock = engine
    seen_prompts: list[str] = []

    class CapturingCleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            seen_prompts.append(system_prompt)
            return SimpleNamespace(
                applied=True,
                text='{"summary":"Trimmed","decisions":[],"action_items":[]}',
            )

    eng.cleanup = CapturingCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    # A completed meeting must never fail over prompt length: Swift bounds by
    # unicode scalars, but any skew (emoji, combining marks) gets truncated
    # here instead of rejected.
    await client.send_json({
        "cmd": "meeting_notes", "id": "too-big", "meeting_id": "m5",
        "transcript": "[00:00] Me: hi.", "prompt": "x" * 9_000,
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert ready["summary"] == "Trimmed"
    assert seen_prompts
    assert seen_prompts[0].startswith("x" * 8_000 + " Keep this partial summary")
    assert "Return JSON only with exact keys summary" in seen_prompts[0]


async def test_meeting_notes_rejects_non_string_prompt(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "not-a-string", "meeting_id": "m5",
        "transcript": "[00:00] Me: hi.", "prompt": 42,
    })
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["code"] == "invalid_arguments"
    assert not eng._meeting_notes_running


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
    assert parse_notes_json(
        '{"summary":42,"decisions":"D","action_items":[],"extra":"x"}'
    ) is None
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
