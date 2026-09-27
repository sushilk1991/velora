"""Resumable meeting transcription and preemptible structured notes."""

# The imported pytest fixture intentionally shares its name with test parameters.
# ruff: noqa: F811

import asyncio
import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import numpy as np
import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

from velora_engine import media
from velora_engine.media import MeetingAudio, SAMPLE_RATE
from velora_engine.meeting_notes import (
    chunk_transcript,
    merge_notes,
    parse_notes_json,
)
from velora_engine.config import Config
from velora_engine.server import Engine
from velora_engine import server as server_mod

_REAL_CONVERT_MEETING = media._convert_meeting


def _fixture_track(pcm: np.ndarray, directory: Path) -> MeetingAudio:
    """Return the same converted-file type that production meeting jobs own."""
    import soundfile as sf

    path = directory / f"converted-{os.urandom(8).hex()}.caf"
    sf.write(str(path), pcm, SAMPLE_RATE, format="CAF", subtype="PCM_16")
    return MeetingAudio(path)


@pytest.fixture(autouse=True)
def convert_protocol_caf(monkeypatch, tmp_path):
    """Exercise real meeting validation and reads with a local CAF converter."""
    import soundfile as sf

    def convert(src, _duration, *, cancel, timeout_s=None):
        if cancel():
            raise media.TransientMediaError("meeting audio cancelled")
        pcm, rate = sf.read(str(src), dtype="float32")
        assert rate == SAMPLE_RATE
        return _fixture_track(pcm, tmp_path)

    monkeypatch.setattr(media, "_convert_meeting", convert)


def _write_caf(path, seconds: float = 2.0) -> Path:
    """Write a Velora-owned 16 kHz track under the test meeting root."""
    import soundfile as sf

    root = Path(os.environ["VELORA_HOME"]) / "meetings"
    root.mkdir(parents=True, exist_ok=True)
    source = root / Path(path).with_suffix(".caf").name
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    pcm16 = (0.2 * np.sin(2 * np.pi * 330 * t) * 32767.0).astype("<i2")
    sf.write(str(source), pcm16, SAMPLE_RATE, format="CAF", subtype="PCM_16")
    return source


async def test_meeting_transcribe_emits_durable_segment_cursor(engine, tmp_path, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "my meeting update")
    eng, sock = engine
    clip = _write_caf("me.wav")
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
    assert done["silent"] is False
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


async def test_meeting_transcribe_uses_app_owned_source_limit(engine, tmp_path, monkeypatch):
    from velora_engine import server as server_mod

    seen = {}

    def fake_load(path, *, meeting_root, cancel=None, failure_path=None, **_kwargs):
        seen["path"] = path
        seen["meeting_root"] = meeting_root
        return _fixture_track(np.tile(AUDIO, 3), tmp_path)

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
    clip = _write_caf("dense-them.wav", seconds=10.0)
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
    clip = _write_caf("long-them.wav", seconds=10.0)
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
    clip = _write_caf("them.wav", seconds=10.0)
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
    clip = _write_caf("them.wav")
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
    clip = _write_caf("five-clusters.wav", seconds=10.0)
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
    clip = _write_caf("clustered.wav", seconds=12.0)
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
    clip = _write_caf("them.wav")
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


async def test_v3_plan_resumes_exactly(
    engine, tmp_path, monkeypatch
):
    """A mid-track v3 cursor decodes each remaining sample range once."""
    import soundfile as sf

    eng, sock = engine
    clip = _write_caf("resume-v3.caf", seconds=6)
    source_pcm, _rate = sf.read(str(clip), dtype="float32")
    converted = tmp_path / "v3-converted.caf"
    sf.write(str(converted), source_pcm, SAMPLE_RATE,
             format="CAF", subtype="PCM_16")
    expected_pcm, _rate = sf.read(str(converted), dtype="float32")
    ranges = []
    reader_threads = []
    decoded = []

    class TrackingAudio(MeetingAudio):
        def read(self, start, end, *, cancel=None):
            ranges.append((start, end))
            reader_threads.append(threading.current_thread())
            return super().read(start, end, cancel=cancel)

    track = TrackingAudio(converted)
    monkeypatch.setattr(
        __import__("velora_engine.server", fromlist=["load_meeting_media"]),
        "load_meeting_media", lambda *_args, **_kwargs: track)

    def decode(_stt, chunk):
        decoded.append(chunk.copy())
        return f"chunk-{len(decoded)}"

    monkeypatch.setattr(
        __import__("velora_engine.server", fromlist=["transcribe_clip"]),
        "transcribe_clip", decode)
    spans = [
        (0, 2 * SAMPLE_RATE),
        (2 * SAMPLE_RATE, 4 * SAMPLE_RATE),
        (4 * SAMPLE_RATE, 6 * SAMPLE_RATE),
    ]
    plan = eng._meeting_plan_path("resume-v3", "me")
    plan.parent.mkdir(parents=True, exist_ok=True)
    plan.write_text(json.dumps({
        "version": 3,
        "spans": [[a, b, "me"] for a, b in spans],
    }))
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "v3", "meeting_id": "resume-v3",
        "speaker": "me", "path": str(clip), "start_chunk": 1,
    })
    await client.recv_event("meeting_transcribe_accepted")
    started = await client.recv_event("meeting_transcribe_started")
    assert started["restarted"] is False
    assert started["start_chunk"] == 1
    segments = [await client.recv_event("meeting_segment") for _ in spans[1:]]
    assert [event["chunk_index"] for event in segments] == [1, 2]
    done = await client.recv_event("meeting_transcribed")
    assert done["chunks"] == len(spans)
    assert ranges[-2:] == spans[1:]
    assert all(thread is not threading.main_thread() for thread in reader_threads[-2:])
    assert len(decoded) == 2
    for chunk, (start, end) in zip(decoded, spans[1:], strict=True):
        assert np.array_equal(chunk, expected_pcm[start:end])
    assert np.array_equal(np.concatenate(decoded), expected_pcm[spans[1][0]:])
    client.close()


async def test_cancel_stops_conversion(engine, monkeypatch):
    """The existing cancel command reaches a converter running in a worker."""
    _eng, sock = engine
    clip = _write_caf("cancel-convert.caf")
    started = threading.Event()
    stopped = threading.Event()

    def stalled_convert(_source, _duration, *, cancel):
        started.set()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if cancel():
                stopped.set()
                raise media.TransientMediaError("meeting audio conversion cancelled")
            time.sleep(0.01)
        raise AssertionError("cancel did not reach converter")

    monkeypatch.setattr(media, "_convert_meeting", stalled_convert)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "convert-cancel",
        "meeting_id": "convert-cancel", "speaker": "me",
        "path": str(clip), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    assert await asyncio.to_thread(started.wait, 2)
    await client.send_json({"cmd": "meeting_transcribe_cancel", "id": "convert-cancel"})
    failed = await client.recv_event("meeting_transcribe_failed", timeout=3)
    assert failed["code"] == "cancelled"
    assert stopped.is_set()
    client.close()


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
    clip = _write_caf("them.wav")
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
    """An argument error names the job: MeetingProcessor only settles work on
    an id-matched event, so a bare `error` left the track waiting forever."""
    _eng, sock = engine
    clip = _write_caf("clip.wav")
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "bad-channel", "meeting_id": "m",
        "speaker": "Alice", "path": str(clip),
    })
    failed = await client.recv_event("meeting_transcribe_failed")
    assert failed["id"] == "bad-channel"
    assert failed["meeting_id"] == "m"
    assert failed["code"] == "invalid_arguments"
    assert "speaker must be 'me' or 'them'" in failed["error"]


async def test_meeting_transcribe_names_unusable_audio(engine, tmp_path, monkeypatch):
    """The app skips a track only when its file can never be transcribed.
    Every other failure is transient and retries the whole job, so a
    rejected or empty file needs its own code."""
    from velora_engine import server as server_mod

    def rejecting_load(path, *, meeting_root, cancel=None, failure_path=None, **_kwargs):
        raise ValueError("unsupported meeting audio format")

    _eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    monkeypatch.setattr(server_mod, "load_meeting_media", rejecting_load)
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "rejected", "meeting_id": "m",
        "speaker": "them", "path": str(tmp_path / "them.caf"),
    })
    rejected = await client.recv_event("meeting_transcribe_failed")
    assert rejected["code"] == "unsupported_audio"

    # A file that could not be read this time (converter timeout, full
    # disk, still being written) is retried by the app, never skipped.
    def unreadable_now(path, *, meeting_root, cancel=None, failure_path=None, **_kwargs):
        raise server_mod.TransientMediaError("meeting audio conversion timed out")

    monkeypatch.setattr(server_mod, "load_meeting_media", unreadable_now)
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "transient", "meeting_id": "m",
        "speaker": "them", "path": str(tmp_path / "them.caf"),
    })
    transient = await client.recv_event("meeting_transcribe_failed")
    assert transient["code"] == "audio_load_failed"
    assert "timed out" in transient["error"]

    # A blip of audio is valid but holds no speech; it has its own issue.
    monkeypatch.setattr(
        server_mod, "load_meeting_media",
                lambda path, *, meeting_root, cancel=None, failure_path=None, **_kwargs: _fixture_track(
            np.zeros(SAMPLE_RATE // 10, dtype=np.float32), tmp_path))
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "short", "meeting_id": "m",
        "speaker": "them", "path": str(tmp_path / "them.caf"),
    })
    short = await client.recv_event("meeting_transcribe_failed")
    assert short["code"] == "too_short"


async def test_meeting_notes_invalid_arguments_name_the_job(engine):
    _eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "blank-notes", "meeting_id": "m",
        "transcript": "   ",
    })
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["id"] == "blank-notes"
    assert failed["meeting_id"] == "m"
    assert failed["code"] == "invalid_arguments"
    assert "transcript" in failed["error"]


# Exact zeros, and ±1 LSB dither: both within one 16-bit step, the line
# the app's silent-mic alert also draws (MeetingPCMLevel.isSilent).
@pytest.mark.parametrize("frame_pair", [b"\x00\x00" * 2, b"\x01\x00\xff\xff"])
async def test_meeting_transcribed_flags_digitally_silent_track(
    engine, tmp_path, monkeypatch, frame_pair
):
    """A microphone that delivers exact zeros (lid-closed built-in mic, a
    muted interface) used to finish as an ordinary empty track. The app needs
    the flag to tell the user their side was never heard.

    Whisper hallucinates on digital silence ("Thank you."), so the fake
    returns text too: a silent track must never reach STT or emit lines."""
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "Thank you.")
    import soundfile as sf

    root = Path(os.environ["VELORA_HOME"]) / "meetings"
    root.mkdir(parents=True, exist_ok=True)
    silent = root / "me.caf"
    sf.write(
        str(silent), np.frombuffer(frame_pair * SAMPLE_RATE, dtype="<i2"),
        SAMPLE_RATE, format="CAF", subtype="PCM_16",
    )
    _eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "silent", "meeting_id": "m-silent",
        "speaker": "me", "path": str(silent), "start_chunk": 0,
    })
    events = []
    while not events or events[-1]["event"] != "meeting_transcribed":
        events.append(await client.recv())
    assert "meeting_segment" not in [event["event"] for event in events]
    assert events[-1]["silent"] is True


async def test_meeting_busy_failures_have_stable_codes(engine, tmp_path):
    eng, sock = engine
    clip = _write_caf("clip.wav")
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
    assert ready["partial"] is False


async def test_meeting_notes_keep_other_chunks_when_one_chunk_fails(engine):
    """One section that times out even after its bounded retry used to throw
    away every other section's notes. Keep them and flag the notes partial."""
    eng, sock = engine

    class OneBadChunkCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            if kwargs["max_tokens"] == 512:
                self.calls.append("reduce")
                return SimpleNamespace(
                    applied=True,
                    text=json.dumps({
                        "summary": "Sections A and C.",
                        "decisions": [],
                        "action_items": [],
                    }),
                )
            self.calls.append(raw[:1])
            if raw.startswith("B"):
                return SimpleNamespace(
                    applied=False, text=raw, reason="timeout_hard")
            return SimpleNamespace(
                applied=True,
                text=json.dumps({
                    "summary": f"Section {raw[:1]}.",
                    "decisions": [],
                    "action_items": [],
                }),
            )

    cleanup = OneBadChunkCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "partial", "meeting_id": "m-partial",
        "transcript": "\n".join(letter * 3_000 for letter in "ABC"),
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    assert ready["partial"] is True
    assert ready["summary"] == "Sections A and C."
    assert cleanup.calls == ["A", "B", "B", "C", "reduce"]
    assert not eng._meeting_notes_running


def _section_notes(letter: str) -> SimpleNamespace:
    return SimpleNamespace(
        applied=True,
        text=json.dumps({
            "summary": f"Section {letter}.", "decisions": [], "action_items": [],
        }),
    )


async def test_meeting_notes_restart_when_the_model_goes_away_after_some_sections(
    engine,
):
    """A model that goes away mid-meeting (its worker died and is
    recovering) fails every later section too. Notes from the sections
    before it are a fragment, not the meeting's notes: restart the engine
    and let the app requeue the whole notes job, as with no sections done."""
    eng, _sock = engine

    class ModelLostCleanup:
        loaded = True
        unhealthy = False
        recovering = False
        calls: list[str] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls.append(raw[:1])
            if raw.startswith("A"):
                return _section_notes("A")
            self.recovering = True
            return SimpleNamespace(applied=False, text=raw, reason="llm_recovering")

    cleanup = ModelLostCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    eng._meeting_notes_running = True

    await eng._run_meeting_notes({
        "id": "lost", "meeting_id": "m-lost",
        "transcript": "\n".join(letter * 3_000 for letter in "ABC"),
    })

    sent = [call.args[0]["event"] for call in eng._send.await_args_list]
    assert cleanup.calls == ["A", "B"]
    assert eng.shutdown.is_set()
    assert "meeting_notes_ready" not in sent
    assert "meeting_notes_failed" not in sent
    assert not eng._meeting_notes_running


async def test_meeting_notes_fail_when_the_model_is_gone_and_cannot_restart(engine):
    """A model that is not loaded and not recovering cannot be brought
    back by a restart either. Fail the notes job for Retry Notes instead of
    shipping the sections before the outage as the meeting's notes."""
    eng, sock = engine

    class ModelGoneCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls.append(raw[:1])
            if raw.startswith("A"):
                return _section_notes("A")
            return SimpleNamespace(applied=False, text=raw, reason="llm_not_loaded")

    cleanup = ModelGoneCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "gone", "meeting_id": "m-gone",
        "transcript": "\n".join(letter * 3_000 for letter in "ABC"),
    })
    await client.recv_event("meeting_notes_accepted")
    failed = await client.recv_event("meeting_notes_failed")

    assert failed["code"] == "generation_failed"
    assert "llm_not_loaded" in failed["error"]
    assert cleanup.calls == ["A", "B"]
    assert not eng.shutdown.is_set()


async def test_meeting_notes_keep_recovered_pieces_when_a_later_piece_fails(engine):
    """A failed section is retried as smaller pieces. A piece that fails
    after others succeeded must not throw the recovered pieces away."""
    eng, sock = engine

    class LaterPieceFailsCleanup:
        loaded = True
        unhealthy = False
        calls: list[int] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            self.calls.append(len(raw))
            if len(self.calls) == 2:
                return _section_notes("one")
            return SimpleNamespace(applied=False, text=raw, reason="timeout_hard")

    cleanup = LaterPieceFailsCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "pieces", "meeting_id": "m-pieces",
        "transcript": "x" * 3_999,
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    assert cleanup.calls == [3_999, 2_000, 1_999]
    assert ready["partial"] is True
    assert ready["summary"] == "Section one."


async def test_meeting_notes_keep_going_after_a_streak_of_section_failures(engine):
    """A section that times out says nothing about the next one, so a
    streak of failed sections must not cost the sections after it. The
    streak only caps the cost: after MEETING_NOTES_MAX_CONSECUTIVE_FAILURES
    in a row, each section gets one attempt and no split retry."""
    from velora_engine import server as server_mod

    eng, sock = engine

    class StreakCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []
        reduce_input = ""

        async def cleanup(self, raw, system_prompt, **kwargs):
            if kwargs["max_tokens"] == server_mod.MEETING_NOTES_REDUCE_MAX_TOKENS:
                self.calls.append("reduce")
                self.reduce_input = raw
                return _section_notes("A and F")
            self.calls.append(raw[:1])
            if raw[:1] in "AF":
                return _section_notes(raw[:1])
            return SimpleNamespace(applied=False, text=raw, reason="timeout_hard")

    cleanup = StreakCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "streak", "meeting_id": "m-streak",
        "transcript": "\n".join(letter * 3_000 for letter in "ABCDEF"),
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    assert server_mod.MEETING_NOTES_MAX_CONSECUTIVE_FAILURES == 3
    # B-D each get a split retry; E, past the streak, gets one attempt.
    assert cleanup.calls == [
        "A", "B", "B", "C", "C", "D", "D", "E", "F", "reduce"]
    assert "Section F." in cleanup.reduce_input
    assert ready["partial"] is True


async def test_meeting_notes_content_failures_keep_the_split_retry(engine):
    """Only deadline and malformed-output failures count toward the streak.
    A section the model answered with unusable content costs no timeout, so
    three of them in a row must not take the split retry from a later
    section that timed out once."""
    from velora_engine import server as server_mod

    eng, sock = engine

    class ContentThenTimeoutCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []
        reduce_input = ""
        timed_out = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            if kwargs["max_tokens"] == server_mod.MEETING_NOTES_REDUCE_MAX_TOKENS:
                self.calls.append("reduce")
                self.reduce_input = raw
                return _section_notes("A, E and F")
            self.calls.append(raw[:1])
            if raw[:1] in "BCD":
                return SimpleNamespace(applied=False, text=raw, reason="empty_output")
            if raw[:1] == "E" and not self.timed_out:
                self.timed_out = True
                return SimpleNamespace(applied=False, text=raw, reason="timeout_hard")
            return _section_notes(raw[:1])

    cleanup = ContentThenTimeoutCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "content", "meeting_id": "m-content",
        "transcript": "\n".join(letter * 3_000 for letter in "ABCDEF"),
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    # B-D fail on content and get no split retry; E still gets one, as
    # two smaller pieces.
    assert cleanup.calls == ["A", "B", "C", "D", "E", "E", "E", "F", "reduce"]
    assert "Section E." in cleanup.reduce_input
    assert ready["partial"] is True


async def test_meeting_notes_streak_counts_timeouts_the_split_recovered(engine):
    """The streak caps what a slow model costs. A section whose first
    attempt timed out cost that timeout even when its split retry
    recovered, so it counts; resetting there gave every section of a slow
    meeting a timeout plus a split."""
    from velora_engine import server as server_mod

    eng, sock = engine

    class SlowFirstAttemptCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []

        async def cleanup(self, raw, system_prompt, **kwargs):
            if kwargs["max_tokens"] == server_mod.MEETING_NOTES_REDUCE_MAX_TOKENS:
                self.calls.append("reduce")
                return _section_notes("A to C")
            self.calls.append(raw[:1])
            # Whole sections time out; the smaller split pieces finish.
            if len(raw) > server_mod.MEETING_NOTES_RETRY_CHUNK_CHARS:
                return SimpleNamespace(applied=False, text=raw, reason="timeout_hard")
            return _section_notes(raw[:1])

    cleanup = SlowFirstAttemptCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "slow", "meeting_id": "m-slow",
        "transcript": "\n".join(letter * 3_000 for letter in "ABCD"),
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    # A-C each time out and recover as two pieces; D, past the streak,
    # gets one attempt.
    assert cleanup.calls == [
        "A", "A", "A", "B", "B", "B", "C", "C", "C", "D", "reduce"]
    assert ready["partial"] is True


async def test_meeting_notes_output_limit_keeps_every_split_retry(engine):
    """A detailed custom prompt can push every full section past the map
    token cap while its halves fit. Hitting that cap costs no timeout, so it
    must not build the streak: in 0.24.2 every section got its split retry,
    and the notes must not come out partial."""
    from velora_engine import server as server_mod

    eng, sock = engine

    class LongAnswerCleanup:
        loaded = True
        unhealthy = False
        calls: list[str] = []
        reduce_input = ""

        async def cleanup(self, raw, system_prompt, **kwargs):
            if kwargs["max_tokens"] == server_mod.MEETING_NOTES_REDUCE_MAX_TOKENS:
                self.calls.append("reduce")
                self.reduce_input = raw
                return _section_notes("A to E")
            self.calls.append(raw[:1])
            if len(raw) > server_mod.MEETING_NOTES_RETRY_CHUNK_CHARS:
                return SimpleNamespace(applied=False, text=raw, reason="length")
            return _section_notes(raw[:1])

    cleanup = LongAnswerCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_notes", "id": "long", "meeting_id": "m-long",
        "transcript": "\n".join(letter * 3_000 for letter in "ABCDE"),
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    assert cleanup.calls == [
        letter for letter in "ABCDE" for _ in range(3)] + ["reduce"]
    assert all(f"Section {letter}." in cleanup.reduce_input for letter in "ABCDE")
    assert ready["partial"] is False


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


async def test_engine_shutdown_emits_terminal_meeting_failures(engine, tmp_path, monkeypatch):
    eng, sock = engine
    clip = _write_caf("shutdown.wav")
    client = await connect(sock)
    await client.recv_event("ready")

    cancel_observed = threading.Event()

    def cancelled_convert(_src, _duration, *, cancel):
        if cancel():
            cancel_observed.set()
            raise media.TransientMediaError("meeting audio cancelled")
        return _fixture_track(np.tile(AUDIO, 3), tmp_path)

    monkeypatch.setattr(media, "_convert_meeting", cancelled_convert)

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
    assert cancel_observed.is_set()


async def test_terminal_releases_job(engine, monkeypatch):
    """The next meeting can start at the terminal event without busy or eviction."""
    eng, _sock = engine
    clip = _write_caf("release-before-event.caf")
    ended = Mock(wraps=eng._end_batch_job)
    release = Mock(wraps=eng._release_stt_memory)
    monkeypatch.setattr(eng, "_end_batch_job", ended)
    monkeypatch.setattr(eng, "_release_stt_memory", release)
    eng._transcribing = True
    eng._meeting_transcribe_job_id = "first"

    async def send(payload):
        if payload["event"] != "meeting_transcribed":
            return
        assert not eng._transcribing
        assert eng._meeting_transcribe_job_id is None
        assert not eng._meeting_transcribe_cancel
        ended.assert_called_once_with(lower_priority=False)
        eng._transcribing = True

    monkeypatch.setattr(eng, "_send", send)
    await eng._run_meeting_transcribe({
        "path": str(clip), "id": "first", "meeting_id": "release",
        "speaker": "me", "start_chunk": 0,
    })
    release.assert_not_called()
    eng._transcribing = False


async def test_wedged_close_frees_job(engine, monkeypatch, tmp_path):
    """A blocked reader close cannot keep the next track busy."""
    eng, _sock = engine
    track = _fixture_track(np.full(2 * SAMPLE_RATE, 0.2, dtype=np.float32), tmp_path)
    monkeypatch.setattr(server_mod, "load_meeting_media", lambda *_a, **_k: track)
    delivered = asyncio.Event()
    release = threading.Event()
    real_close = track.close

    def close():
        release.wait(3)
        real_close()

    async def send(payload):
        if payload["event"] == "meeting_transcribed":
            assert not eng._transcribing
            assert eng._meeting_transcribe_job_id is None
            delivered.set()

    monkeypatch.setattr(track, "close", close)
    monkeypatch.setattr(eng, "_send", send)
    eng._transcribing = True
    eng._meeting_transcribe_job_id = "wedged"
    task = asyncio.create_task(eng._run_meeting_transcribe({
        "path": "/synthetic/track.caf", "id": "wedged",
        "meeting_id": "wedged", "speaker": "me", "start_chunk": 0,
    }))
    try:
        await asyncio.wait_for(delivered.wait(), 1)
    finally:
        release.set()
        await task


@pytest.mark.parametrize("stop,code", [
    ("cancel", "cancelled"), ("shutdown", "engine_shutdown"),
])
async def test_stop_wins_load_race(engine, monkeypatch, stop, code):
    """A decoder verdict returned after stop cannot skip the source."""
    eng, _sock = engine
    eng._send = AsyncMock()

    def reject(*_args, **_kwargs):
        if stop == "shutdown":
            eng.shutdown.set()
        else:
            eng._meeting_transcribe_cancel = True
        raise ValueError("input rejected")

    monkeypatch.setattr(server_mod, "load_meeting_media", reject)
    await eng._run_meeting_transcribe({
        "path": "/synthetic/bad.caf", "id": "race", "meeting_id": "race",
        "speaker": "me", "start_chunk": 0,
    })
    events = [call.args[0] for call in eng._send.await_args_list]
    assert events[-1]["code"] == code


@pytest.mark.parametrize("stop_at", ["models", "diarize"])
async def test_shutdown_stops_diarize(engine, tmp_path, monkeypatch, stop_at):
    """A shutdown during model work or diarization ends the job."""
    eng, _sock = engine
    eng._send = AsyncMock()
    track = _fixture_track(np.full(2 * SAMPLE_RATE, 0.2, dtype=np.float32), tmp_path)
    monkeypatch.setattr(server_mod, "load_meeting_media", lambda *_a, **_k: track)
    monkeypatch.setattr(server_mod.diarization, "available", lambda: True)
    monkeypatch.setattr(server_mod, "speech_window_fraction", lambda _a: 0.3)
    monkeypatch.setattr(server_mod.diarization, "ensure_models",
                        eng.shutdown.set if stop_at == "models" else lambda: None)
    calls = []

    def diarize(_audio):
        calls.append(True)
        if stop_at == "models":
            pytest.fail("diarization ran after shutdown")
        eng.shutdown.set()
        return []

    monkeypatch.setattr(server_mod.diarization, "diarize", diarize)

    await eng._run_meeting_transcribe({
        "path": "/synthetic/track.caf", "id": "stop", "meeting_id": "stop",
        "speaker": "them", "start_chunk": 0,
    })
    events = [call.args[0] for call in eng._send.await_args_list]
    assert events[-1]["code"] == "engine_shutdown"
    assert len(calls) == (stop_at == "diarize")
    assert not eng._meeting_plan_path("stop", "them").exists()


async def test_diarization_read_retries(engine, tmp_path, monkeypatch):
    """A read fault never pins a plan without diarization."""
    eng, _sock = engine
    eng._send = AsyncMock()
    track = _fixture_track(np.full(2 * SAMPLE_RATE, 0.2, dtype=np.float32), tmp_path)
    monkeypatch.setattr(track, "peak", lambda *, cancel: 0.2)

    def fail_read(_start, _end, *, cancel):
        raise media.TransientMediaError("read fault")

    monkeypatch.setattr(track, "read", fail_read)
    monkeypatch.setattr(server_mod, "load_meeting_media", lambda *_a, **_k: track)
    monkeypatch.setattr(server_mod.diarization, "available", lambda: True)
    await eng._run_meeting_transcribe({
        "path": "/synthetic/track.caf", "id": "read", "meeting_id": "read",
        "speaker": "them", "start_chunk": 0,
    })
    events = [call.args[0] for call in eng._send.await_args_list]
    assert events[-1]["code"] == server_mod.MEETING_AUDIO_LOAD_FAILED
    assert not eng._meeting_plan_path("read", "them").exists()


async def test_shutdown_mid_slice_read(engine, tmp_path, monkeypatch):
    """A server read stopped by shutdown ends as engine_shutdown."""
    eng, _sock = engine
    eng._send = AsyncMock()
    track = _fixture_track(np.full(2 * SAMPLE_RATE, 0.2, dtype=np.float32), tmp_path)
    original = track.read
    reads = 0

    def read(start, end, *, cancel):
        nonlocal reads
        reads += 1
        if reads > 1:
            eng.shutdown.set()
            raise media.TransientMediaError("read stopped")
        return original(start, end, cancel=cancel)

    monkeypatch.setattr(track, "read", read)
    monkeypatch.setattr(server_mod, "load_meeting_media", lambda *_a, **_k: track)
    await eng._run_meeting_transcribe({
        "path": "/synthetic/track.caf", "id": "slice", "meeting_id": "slice",
        "speaker": "me", "start_chunk": 0,
    })
    events = [call.args[0] for call in eng._send.await_args_list]
    assert reads > 1
    assert events[-1]["code"] == "engine_shutdown"


async def test_skip_then_manual_retry(engine, monkeypatch):
    """A permanent skip consumes its strike so Retry starts fresh."""
    eng, sock = engine
    clip = _write_caf("manual-retry.caf")
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")))
    client = await connect(sock)
    await client.recv_event("ready")
    failure_path = eng._meeting_plan_path("manual-retry", "me").with_suffix(
        media.MEETING_FAILURE_SUFFIX)

    for attempt, code in enumerate((server_mod.MEETING_AUDIO_LOAD_FAILED,
                                    server_mod.MEETING_UNSUPPORTED_AUDIO,
                                    server_mod.MEETING_AUDIO_LOAD_FAILED)):
        await client.send_json({
            "cmd": "meeting_transcribe", "id": f"retry-{attempt}",
            "meeting_id": "manual-retry", "speaker": "me", "path": str(clip),
            "start_chunk": 0,
        })
        await client.recv_event("meeting_transcribe_accepted")
        failed = await client.recv_event("meeting_transcribe_failed")
        assert failed["code"] == code
        assert failure_path.exists() is (attempt != 1)
    client.close()


@pytest.mark.skipif(shutil.which("afconvert") is None or shutil.which("afinfo") is None,
                    reason="Core Audio tools missing")
@pytest.mark.parametrize("empty,codes", [
    (False, (server_mod.MEETING_AUDIO_LOAD_FAILED, server_mod.MEETING_UNSUPPORTED_AUDIO)),
    (True, (server_mod.MEETING_TRACK_TOO_SHORT,)),
])
async def test_corrupt_them_keeps_notes(engine, monkeypatch, empty, codes):
    """A bad legacy track is skipped while the good mic track makes notes."""
    eng, sock = engine
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "The release is approved")
    me = _write_caf("me-for-notes.caf")
    them = me.parent / "them.m4a"
    source = me
    if empty:
        import soundfile as sf
        source = me.parent / "zero.wav"
        sf.write(str(source), np.empty(0, dtype=np.float32), 48_000)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(source), str(them)],
                   check=True, capture_output=True, timeout=30)
    if not empty:
        raw = them.read_bytes()
        them.write_bytes(raw[:raw.index(b"moov") - 4])
    originals = [(path.read_bytes(), path.stat().st_mtime_ns) for path in (them, me)]

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, _raw, _prompt, **_kwargs):
            return SimpleNamespace(applied=True, text=json.dumps({
                "summary": "The release is approved.",
                "decisions": ["Release approved"], "action_items": [],
            }))

    eng.cleanup = Cleanup()
    failure_path = eng._meeting_plan_path("two-track", "them").with_suffix(
        media.MEETING_FAILURE_SUFFIX)
    client = await connect(sock)
    await client.recv_event("ready")
    for attempt, code in enumerate(codes):
        await client.send_json({
            "cmd": "meeting_transcribe", "id": f"them-{attempt}",
            "meeting_id": "two-track", "speaker": "them", "path": str(them),
            "start_chunk": 0,
        })
        await client.recv_event("meeting_transcribe_accepted")
        failed = await client.recv_event("meeting_transcribe_failed")
        assert failed["code"] == code
        if empty:
            assert not failure_path.exists()

    await client.send_json({
        "cmd": "meeting_transcribe", "id": "me", "meeting_id": "two-track",
        "speaker": "me", "path": str(me), "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    segment = await client.recv_event("meeting_segment")
    assert segment["text"] == "The release is approved"
    await client.recv_event("meeting_transcribed")

    await client.send_json({
        "cmd": "meeting_notes", "id": "notes", "meeting_id": "two-track",
        "transcript": f"[00:00] Me: {segment['text']}",
    })
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert ready["summary"] == "The release is approved."
    assert [(path.read_bytes(), path.stat().st_mtime_ns) for path in (them, me)] == originals
    client.close()


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
async def test_restart_sweeps_converter(home, fake_stt, tmp_path,
                                        meeting_temp_root, monkeypatch):
    """SIGKILL during the real converter leaves a sweepable partial file."""
    clip = _write_caf("restart-conversion.caf")
    marker = tmp_path / "converter-started"
    child = r"""
import asyncio
import os
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace
from velora_engine import media
from velora_engine.config import Config
from velora_engine.server import Engine

media._meeting_temp_root = lambda: Path(os.environ["TEST_TEMP_ROOT"])
media.shutil.disk_usage = lambda _path: SimpleNamespace(free=10**12)
marker = Path(os.environ["TEST_MARKER"])
class Process:
    returncode = None
    def __init__(self, args, **_kwargs):
        self.args = args
        output = Path(args[-1])
        output.write_bytes(b"partial converter output")
        marker.write_text(str(output))
    def communicate(self, timeout=None):
        time.sleep(0.02)
        raise subprocess.TimeoutExpired(self.args, timeout)
    def kill(self):
        pass
original_popen = subprocess.Popen
def popen(args, **kwargs):
    if args[0] == "afconvert":
        return Process(args, **kwargs)
    return original_popen(args, **kwargs)
media.subprocess.Popen = popen
async def send(_payload):
    pass
async def run():
    eng = Engine(Config())
    eng._send = send
    await eng._run_meeting_transcribe({
        "path": os.environ["TEST_CLIP"], "id": "restart",
        "meeting_id": "restart", "speaker": "me", "start_chunk": 0,
    })
asyncio.run(run())
"""
    env = {**os.environ, "TEST_TEMP_ROOT": str(meeting_temp_root),
           "TEST_MARKER": str(marker), "TEST_CLIP": str(clip),
           "VELORA_FAKE_STT": "1"}
    process = subprocess.Popen([sys.executable, "-c", child], env=env)
    try:
        async with asyncio.timeout(20):
            while not marker.exists():
                await asyncio.sleep(0.01)
        orphan = Path(marker.read_text())
        assert orphan.exists()
    finally:
        process.kill()
        await asyncio.to_thread(process.wait, 5)

    restarted = Engine(Config(), hard_exit=Mock())
    restarted._send = AsyncMock()
    monkeypatch.setattr(media, "_convert_meeting", _REAL_CONVERT_MEETING)
    msg = {"path": str(clip), "id": "retry", "meeting_id": "restart",
           "speaker": "me", "start_chunk": 0}

    async def serve(_socket_path):
        assert not orphan.exists()
        await restarted._run_meeting_transcribe(msg)

    monkeypatch.setattr(restarted, "serve", serve)
    monkeypatch.setattr(server_mod, "Engine", lambda _config, parent_pid: restarted)
    monkeypatch.setattr(asyncio.get_running_loop(), "add_signal_handler",
                        lambda *_args: None)
    await server_mod._amain(SimpleNamespace(socket=None, parent_pid=None))
    events = [call.args[0]["event"] for call in restarted._send.await_args_list]
    assert events[-1] == "meeting_transcribed"
    assert list((meeting_temp_root / media._MEETING_TEMP_DIR).iterdir()) == []
    assert list((home / "cache" / "meeting-plans").glob("*.failure*")) == []
