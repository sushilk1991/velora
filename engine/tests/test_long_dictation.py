"""Long dictation keeps one complete result with bounded work."""

# ruff: noqa: F811 — imported pytest fixture shares its argument name

import asyncio
import os
import re
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest.mock import AsyncMock

import numpy as np
import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — isolated fake-STT fixture
from test_server_streaming import SEG1, SEG2
from velora_engine.cleanup import CleanupResult, TIMEOUT_CEILING_MS
from velora_engine.server import (
    CLEANUP_PIECE_WORDS, CLEANUP_SINGLE_CALL_UNITS, PIECE_RECOVERY_WAIT_MAX_S, Session,
    _cleanup_units, _split_cleanup_pieces,
)
from velora_engine import protocol
from velora_engine.cleanup_process import CleanupProcess
from test_cleanup_process import fixture_command
import velora_engine.server as server_mod

async def test_stale_cancel_keeps_live(engine, caplog):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "active", "context": {}})
        await client.send_audio(AUDIO)
        with caplog.at_level("DEBUG", logger="velora.server"):
            await client.send_json({"cmd": "cancel", "session": "older"})
            await client.send_json({"cmd": "ping"})
            await client.recv_event("pong")
        if eng._start_task is not None:
            await asyncio.wait_for(eng._start_task, 2)
        assert "ignored cancel for 'older' while 'active' is active" in caplog.text
        assert eng.session is not None and eng.session.id == "active"
        assert not eng.session.cancelled
        await client.send_json({"cmd": "cancel", "session": "active"})
        await client.recv_event("cancelled")
    finally:
        client.close()


async def test_stale_cancel_keeps_final(engine, monkeypatch):
    eng, sock = engine
    entered = threading.Event()
    release = threading.Event()
    finalize = eng.stt.finalize

    def held_final():
        entered.set()
        release.wait()
        return finalize()

    monkeypatch.setattr(eng.stt, "finalize", held_final)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "finalizing", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "finalizing"})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await client.send_json({"cmd": "cancel", "session": "older"})
        await client.send_json({"cmd": "ping"})
        await client.recv_event("pong")
        assert eng._finalizing_session is not None
        assert not eng._finalizing_session.cancelled
        release.set()
        assert (await client.recv_event("final"))["session"] == "finalizing"
    finally:
        release.set()
        client.close()


async def test_cancel_wedge_deletes(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = True
    entered = threading.Event()
    release = threading.Event()
    finalize = eng.stt.finalize

    def held_final():
        entered.set()
        release.wait()
        return finalize()

    monkeypatch.setattr(eng.stt, "finalize", held_final)
    deleted = asyncio.Event()
    discard = eng.audio.discard_active

    def discard_and_signal(spool):
        discard(spool)
        deleted.set()

    monkeypatch.setattr(eng.audio, "discard_active", discard_and_signal)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "esc-wedge", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "esc-wedge"})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        spool = eng.audio.active_dir / "esc-wedge.pcm16.part"
        assert spool.exists()
        await client.send_json({"cmd": "cancel", "session": "esc-wedge"})
        await asyncio.wait_for(deleted.wait(), 2)
        assert not spool.exists()
        assert eng._finalizing
        await client.send_json({"cmd": "start", "session": "after-esc", "context": {}})
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong"))["event"] == "pong"
        assert eng._start_session_id == "after-esc"
        release.set()
        assert (await client.recv_event("cancelled"))["session"] == "esc-wedge"
        client.close()
        await client.writer.wait_closed()
        next_client = await connect(sock)
        await next_client.recv_event("ready")
        await next_client.send_json({"cmd": "ping"})
        assert (await next_client.recv_event("pong"))["event"] == "pong"
        assert not eng.audio.pending_interrupted()
        next_client.close()
    finally:
        release.set()
        client.close()


async def test_cancel_cold_load(engine, monkeypatch):
    eng, sock = engine
    entered = asyncio.Event()
    release = asyncio.Event()

    async def held_load(cancel_event=None):
        entered.set()
        if cancel_event is None:
            await release.wait()
        else:
            await asyncio.to_thread(cancel_event.wait)
        return False

    monkeypatch.setattr(eng, "_ensure_cleanup_loaded", held_load)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "cold-load", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "cold-load"})
        await asyncio.wait_for(entered.wait(), 2)
        await client.send_json({"cmd": "cancel", "session": "cold-load"})
        assert (await client.recv_event("cancelled", timeout=2))["session"] == "cold-load"
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong", timeout=1))["event"] == "pong"
    finally:
        release.set()
        client.close()


async def test_reconnect_one_final(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = True
    entered = threading.Event()
    release = threading.Event()
    finalize = eng.stt.finalize

    def held_final():
        entered.set()
        release.wait()
        return finalize()

    monkeypatch.setattr(eng.stt, "finalize", held_final)
    disconnected = asyncio.Event()
    cleanup = eng._client_cleanup

    async def signal_cleanup(writer):
        await cleanup(writer)
        disconnected.set()

    monkeypatch.setattr(eng, "_client_cleanup", signal_cleanup)
    first = await connect(sock)
    await first.recv_event("ready")
    try:
        await first.send_json({"cmd": "start", "session": "one-final", "context": {}})
        await first.send_audio(AUDIO)
        await first.send_json({"cmd": "stop", "session": "one-final"})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        first.close()
        await first.writer.wait_closed()
        await asyncio.wait_for(disconnected.wait(), 2)
        second = await connect(sock)
        await second.recv_event("ready")
        if eng._interrupted_tasks:
            await asyncio.gather(*eng._interrupted_tasks)
        await second.send_json({"cmd": "ping"})
        assert (await second.recv_event("pong"))["event"] == "pong"
        assert "one-final" not in eng._recoverable_sessions
        release.set()
        assert (await second.recv_event("final"))["session"] == "one-final"
        second.close()
    finally:
        release.set()
        first.close()


async def test_sigkill_recovery_one_row(home):
    socket_dir = Path(tempfile.mkdtemp(prefix="velora-proc-"))
    socket_path = socket_dir / "e.sock"
    env = os.environ.copy()
    env["VELORA_HOME"] = str(home)
    env["VELORA_FAKE_STT"] = "1"
    script = """
import asyncio
import sys
import threading
from pathlib import Path
from velora_engine.config import Config
from velora_engine.server import Engine

async def run():
    config = Config()
    config.data["cleanup_enabled"] = False
    engine = Engine(config, parent_pid=None)
    if sys.argv[2] == "hold":
        engine.stt.finalize = lambda: threading.Event().wait()
    task = asyncio.create_task(engine.serve(Path(sys.argv[1])))
    await engine.stt_ready.wait()
    print("LISTENING", flush=True)
    await task

asyncio.run(run())
"""

    async def launch(mode):
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-c", script, str(socket_path), mode,
            env=env, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL)
        assert proc.stdout is not None
        assert await asyncio.wait_for(proc.stdout.readline(), 10) == b"LISTENING\n"
        return proc

    first = None
    second = None
    try:
        first = await launch("hold")
        client = await connect(socket_path)
        await client.recv_event("ready")
        await client.send_json({"cmd": "start", "session": "killed-final", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "killed-final"})
        assert (await client.recv_event("finalize_started"))["session"] == "killed-final"
        first.kill()
        assert await asyncio.wait_for(first.wait(), 5) == -9
        client.close()

        second = await launch("recover")
        next_client = await connect(socket_path)
        await next_client.recv_event("ready")
        recovered = await next_client.recv_event("interrupted_dictation")
        assert recovered["session"] == "killed-final"
        await next_client.send_json({
            "cmd": "reprocess", "audio": recovered["audio"],
            "id": 81, "recovery": True,
        })
        result = await next_client.recv_event("reprocessed")
        assert result["id"] == 81
        assert result["raw"]
        await next_client.send_json({"cmd": "ack_interrupted", "session": "killed-final"})
        assert (await next_client.recv_event("interrupted_ack"))["session"] == "killed-final"
        await next_client.send_json({"cmd": "ping"})
        assert (await next_client.recv())["event"] == "pong"
        with pytest.raises(asyncio.TimeoutError):
            await next_client.recv(timeout=0.05)
        next_client.close()
    finally:
        for proc in (first, second):
            if proc is not None and proc.returncode is None:
                proc.kill()
                await asyncio.wait_for(proc.wait(), 5)
        shutil.rmtree(socket_dir)


def test_whisper_span_bound(engine, monkeypatch):
    from velora_engine import stt

    eng, _ = engine
    backend = stt.WhisperBackend("test-model")
    monkeypatch.setattr(backend, "_decode", lambda *args, **kwargs: "words")
    backend.start_session()
    for _ in range(20):
        backend.feed_chunk(np.zeros(stt.SAMPLE_RATE, dtype=np.float32))
    assert backend.finalize_decode_samples() == 0
    for _ in range(20):
        backend.feed_chunk(np.ones(stt.SAMPLE_RATE, dtype=np.float32) * 0.1)
        request = backend.take_preview_request()
        if request is not None:
            backend.decode_preview(request)
    assert backend.finalize_decode_samples() == 40 * stt.SAMPLE_RATE
    assert eng._stt_stall_s(backend.finalize_decode_samples()) == 160


def test_parakeet_span_bound(engine):
    from velora_engine import stt

    eng, _ = engine
    backend = stt.ParakeetBackend("test-model")
    backend.start_session()
    for _ in range(100):
        backend.feed_chunk(np.ones(stt.SAMPLE_RATE, dtype=np.float32) * 0.1)
    assert backend.pending_decode_samples() == 100 * stt.SAMPLE_RATE
    assert eng._stt_stall_s(backend.pending_decode_samples()) == 400


def test_parakeet_continuous_cap():
    from velora_engine import stt

    backend = stt.ParakeetBackend("test-model")
    backend._model = object()
    backend._transcribe = lambda pcm: f"segment {len(pcm)}"
    backend.start_session()
    backend._model = object()
    for _ in range(100):
        backend.feed_chunk(np.ones(stt.SAMPLE_RATE, dtype=np.float32) * 0.1)
    assert 75 * stt.SAMPLE_RATE <= backend.decoded_samples() <= 90 * stt.SAMPLE_RATE
    assert backend.pending_decode_samples() < stt.PARAKEET_SPAN_CAP_S * stt.SAMPLE_RATE
    assert len(backend._segments) == 1


async def test_full_queue_admits_audio(engine, monkeypatch):
    eng, sock = engine
    entered = threading.Event()
    release = threading.Event()
    feed = eng.stt.feed_chunk

    def held_feed(chunk):
        entered.set()
        release.wait()
        return feed(chunk)

    monkeypatch.setattr(eng.stt, "feed_chunk", held_feed)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "full-queue", "context": {}})
        await client.send_audio(np.ones(1600, dtype=np.float32))
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        frame = protocol.encode_frame(
            protocol.FRAME_AUDIO, np.ones(1600, dtype="<f4").tobytes())
        client.writer.write(frame * 600)
        client.writer.write(protocol.encode_json({"cmd": "ping"}))
        await client.recv_event("pong")
        assert eng.session is not None and eng.session.samples == 601 * 1600
        assert eng.session.queue.qsize() == 600
        await client.send_json({"cmd": "cancel", "session": "full-queue"})
        await client.recv_event("cancelled")
    finally:
        release.set()
        client.close()


async def test_max_over_hour(engine):
    eng, sock = engine
    eng.config.data["max_recording_s"] = 86_400
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "day-limit", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "ping"})
        await client.recv_event("pong")
        if eng._start_task is not None:
            await asyncio.wait_for(eng._start_task, 2)
        assert eng.config.max_recording_s == 86_400
        assert eng.session is not None and eng.session.samples == len(AUDIO)
        await client.send_json({"cmd": "cancel", "session": "day-limit"})
        await client.recv_event("cancelled")
    finally:
        client.close()


async def test_socket_backlog_control(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = False
    eng.config.data["max_recording_s"] = 3600
    entered = threading.Event()
    release = threading.Event()
    feed = eng.stt.feed_chunk
    seen = [0]

    def slow_feed(chunk):
        entered.set()
        release.wait()
        seen[0] += 1
        feed(chunk)
        return None

    monkeypatch.setattr(eng.stt, "feed_chunk", slow_feed)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "backlog", "context": {}})
        frame = protocol.encode_frame(
            protocol.FRAME_AUDIO, np.ones(8000, dtype="<f4").tobytes())
        client.writer.write(frame)
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        client.writer.write(frame * 609)
        client.writer.write(protocol.encode_json({"cmd": "ping"}))
        client.writer.write(protocol.encode_json({
            "cmd": "stop", "session": "backlog"}))
        pong = await client.recv_event("pong", timeout=2)
        started = await client.recv_event("finalize_started", timeout=2)
        assert pong["event"] == "pong"
        assert started["session"] == "backlog"
        assert started["stall_after_s"] >= 20
        assert eng._finalizing_session.samples == 610 * 8000
        release.set()
        assert (await client.recv_event("final", timeout=10))["session"] == "backlog"
        assert seen[0] == 610
    finally:
        release.set()
        client.close()


async def test_socket_backlog_escape(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = False
    entered = threading.Event()
    release = threading.Event()
    feed = eng.stt.feed_chunk

    def slow_feed(chunk):
        entered.set()
        release.wait()
        return feed(chunk)

    monkeypatch.setattr(eng.stt, "feed_chunk", slow_feed)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "escape", "context": {}})
        frame = protocol.encode_frame(
            protocol.FRAME_AUDIO, np.ones(8000, dtype="<f4").tobytes())
        client.writer.write(frame)
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        client.writer.write(frame * 609)
        client.writer.write(protocol.encode_json({"cmd": "cancel", "session": "escape"}))
        cancelled = await client.recv_event("cancelled", timeout=2)
        assert cancelled["session"] == "escape"
        assert eng.session is None
    finally:
        release.set()
        client.close()


@pytest.mark.parametrize("retain", [True, False])
async def test_freeze_restarts_recovery(engine, monkeypatch, retain):
    monkeypatch.setenv(
        "VELORA_FAKE_STT_SEGMENTS", "first words|second words|third words")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "final tail")
    eng, sock = engine
    eng.config.data["save_audio"] = retain
    entered = threading.Event()
    release = threading.Event()
    finalize = eng.stt.finalize

    def frozen_final():
        entered.set()
        release.wait()
        return finalize()

    monkeypatch.setattr(eng.stt, "finalize", frozen_final)
    client = await connect(sock)
    await client.recv_event("ready")
    replacement = None
    replaced_task = None
    try:
        await client.send_json({"cmd": "start", "session": "tail-freeze", "context": {}})
        for _ in range(6):
            await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "tail-freeze"})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        assert eng.stt._emitted_segments == [
            "first words", "second words", "third words"]
        spool = eng.audio.active_dir / "tail-freeze.pcm16.part"
        if retain:
            assert spool.exists()
        else:
            assert not spool.exists()
        client.close()
        await client.writer.wait_closed()
        # A replacement engine sees the same spool state that survives a
        # supervised process exit. Its socket is independent of the wedge.
        from velora_engine.server import Engine
        replacement = Engine(eng.config, parent_pid=None)
        next_sock = sock.with_name("r.sock")
        listening = asyncio.Event()
        start_server = asyncio.start_unix_server

        async def signal_listening(*args, **kwargs):
            server = await start_server(*args, **kwargs)
            listening.set()
            return server

        monkeypatch.setattr(asyncio, "start_unix_server", signal_listening)
        replaced_task = asyncio.create_task(replacement.serve(next_sock))
        await asyncio.wait_for(listening.wait(), 2)
        next_client = await connect(next_sock)
        await next_client.recv_event("ready")
        if retain:
            recovered = await next_client.recv_event("interrupted_dictation")
            assert recovered["session"] == "tail-freeze"
            assert recovered["duration_s"] > 0
            await next_client.send_json({
                "cmd": "reprocess", "audio": recovered["audio"],
                "id": 81, "recovery": True,
            })
            assert (await next_client.recv_event("reprocessed"))["id"] == 81
        else:
            assert not replacement.audio.pending_interrupted()
        await next_client.send_json({
            "cmd": "start", "session": "after-freeze", "context": {}})
        await next_client.send_audio(AUDIO)
        await next_client.send_json({"cmd": "stop", "session": "after-freeze"})
        assert (await next_client.recv_event("final"))["session"] == "after-freeze"
        next_client.close()
    finally:
        release.set()
        client.close()
        if replacement is not None and replaced_task is not None:
            replacement.shutdown.set()
            await asyncio.wait_for(replaced_task, 5)


def words(count: int) -> str:
    return " ".join(f"word{index:04d}" for index in range(count))


def test_cjk_pieces_bounded():
    raw = " ".join(["这是一个需要完整保留的长段落" * 20] * 30)
    pieces = _split_cleanup_pieces(raw)
    assert len(pieces) > 30
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert "".join(pieces).replace(" ", "") == raw.replace(" ", "")


def test_mixed_units_bounded():
    raw = " ".join(["中文" + "a" * 100] * 30)
    pieces = _split_cleanup_pieces(raw)
    assert _cleanup_units(raw) > CLEANUP_SINGLE_CALL_UNITS
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert "".join(pieces).replace(" ", "") == raw.replace(" ", "")


def test_protected_token_intact():
    for token in [
        "https://example.com/" + "日本語" * 80,
        "/Users/example/" + "资料" * 80,
        "name@" + "例子" * 80 + ".com",
        "a" * 200,
    ]:
        assert _split_cleanup_pieces(token) == [token]


def test_sentence_seam():
    raw = words(59) + " end. " + words(100)
    pieces = _split_cleanup_pieces(raw)
    assert pieces[0].endswith("end.")
    assert " ".join(pieces).split() == raw.split()
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS


def test_retraction_seam():
    raw = words(CLEANUP_PIECE_WORDS - 8) \
        + ". target sentence scratch that " + words(40)
    pieces = _split_cleanup_pieces(raw)
    assert any(part.startswith("target sentence scratch that") for part in pieces)
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert " ".join(pieces).split() == raw.split()


def test_sentence_head_retraction():
    raw = words(CLEANUP_PIECE_WORDS - 9) + ". Send it Friday. Scratch that, Monday. " \
        + words(40)
    pieces = _split_cleanup_pieces(raw)
    assert any(piece.startswith("Send it Friday. Scratch that, Monday.")
               for piece in pieces)
    assert " ".join(pieces).split() == raw.split()


def test_first_sent_retraction():
    raw = words(CLEANUP_PIECE_WORDS - 8) \
        + " target phrase. Scratch that, Monday. " + words(40)
    pieces = _split_cleanup_pieces(raw)
    assert len(pieces[0].split()) > 1
    assert any("target phrase. Scratch that, Monday." in piece for piece in pieces)
    assert " ".join(pieces).split() == raw.split()


def test_runon_retraction_seam():
    raw = words(CLEANUP_PIECE_WORDS - 8) \
        + " target phrase scratch that Monday " + words(40)
    pieces = _split_cleanup_pieces(raw)
    assert any("target phrase scratch that Monday" in piece for piece in pieces)
    assert " ".join(pieces).split() == raw.split()


def test_scratch_all_seam():
    previous = " ".join(f"old{index:04d}" for index in range(CLEANUP_PIECE_WORDS - 10))
    raw = previous + ". keep this sentence scratch all " + words(30)
    pieces = _split_cleanup_pieces(raw)
    assert pieces[0].startswith("old0000")
    assert pieces[0].endswith("old0064.")
    assert pieces[1].startswith("keep this sentence scratch all")
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert " ".join(pieces).split() == raw.split()


def test_second_retraction_seam():
    raw = "scratch that " + words(CLEANUP_PIECE_WORDS - 12) \
        + ". another sentence scratch all " + words(30)
    pieces = _split_cleanup_pieces(raw)
    assert pieces[1].startswith("another sentence scratch all")
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert " ".join(pieces).split() == raw.split()


def assert_words_once(text: str, count: int) -> None:
    assert re.findall(r"word\d{4}", text) == [
        f"word{index:04d}" for index in range(count)
    ]


class BudgetCleanup:
    loaded = True

    def __init__(self, limit: int = CLEANUP_PIECE_WORDS):
        self.limit = limit
        self.calls = []

    async def cleanup(self, raw, prompt, **kwargs):
        self.calls.append((raw, prompt, kwargs))
        if len(raw.split()) > self.limit:
            return CleanupResult(raw, False, 0, "timeout")
        return CleanupResult(f"<{raw}>", True, 7)


async def test_long_cleanup_pieces(engine, monkeypatch):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    raw = words(650)
    import velora_engine.formatting as formatting
    postprocess = formatting.postprocess
    replace = formatting.apply_replacements
    tag = formatting.apply_tags
    calls = []
    replacements = []
    tags = []

    def once(text, gate):
        calls.append(text)
        return postprocess(text, gate)

    def replace_once(text, rules):
        replacements.append(text)
        return replace(text, rules)

    def tag_once(text, entities, category):
        tags.append(text)
        return tag(text, entities, category)

    monkeypatch.setattr(formatting, "postprocess", once)
    monkeypatch.setattr(formatting, "apply_replacements", replace_once)
    monkeypatch.setattr(formatting, "apply_tags", tag_once)
    text, _, _, applied, reason = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert reason == "chunked"
    assert len(cleanup.calls) > 1
    assert all(len(call[0].split()) <= cleanup.limit for call in cleanup.calls)
    assert_words_once(text, 650)
    assert all("Previous text" in call[1] for call in cleanup.calls[1:])
    assert len(calls) == 1
    assert len(replacements) == 1
    assert len(tags) == 1


async def test_piece_gate_once(engine, monkeypatch):
    eng, _ = engine
    eng.cleanup = BudgetCleanup()
    import velora_engine.formatting as formatting
    scrub = formatting.scrub_fillers
    calls = []

    def count_scrub(text):
        calls.append(text)
        return scrub(text)

    monkeypatch.setattr(formatting, "scrub_fillers", count_scrub)
    await eng._apply_formatting(words(250), None, None, None)
    assert len(calls) == 2  # gate and final postprocess, never each piece


async def test_short_prompt_unchanged(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    raw = words(30)
    await eng._apply_formatting(raw, None, None, None)
    import velora_engine.formatting as formatting
    gate = formatting.run_gate(raw, eng.config)
    assert len(cleanup.calls) == 1
    assert cleanup.calls[0][0] == raw
    assert cleanup.calls[0][1] == gate.system_prompt


async def test_hour_cleanup_bounded(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    raw = words(9000)
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) == 9000 // CLEANUP_PIECE_WORDS
    assert_words_once(text, 9000)


async def test_email_prompt(engine):
    eng, _ = engine
    class EmailCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(
                f"Dear Team,\n{result.text}\nBest regards,", result.applied, result.ms)

    cleanup = EmailCleanup()
    eng.cleanup = cleanup
    raw = words(CLEANUP_PIECE_WORDS * 2 + 25)
    import velora_engine.formatting as formatting
    gate = formatting.run_gate(raw, eng.config, explicit_mode="Email")
    text, _, _, _, _ = await eng._apply_formatting(raw, None, None, "Email")
    assert len(cleanup.calls) == 3
    assert cleanup.calls[0][1] == gate.system_prompt
    assert all(call[1].startswith(gate.system_prompt) for call in cleanup.calls)
    assert all("repeating its greeting or sign-off" in call[1]
               for call in cleanup.calls[1:])
    assert text.count("Dear Team,") == 1
    assert text.count("Best regards,") == 1


async def test_email_envelope_once(engine):
    eng, _ = engine

    class VariedEmail(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            index = len(self.calls) - 1
            greetings = ["Dear Team,", "Hello Team,", "Hi Team,"]
            signoffs = ["Best regards,", "Sincerely,", "Regards,"]
            return CleanupResult(
                f"{greetings[index]}\n{result.text}\n{signoffs[index]}",
                result.applied, result.ms,
            )

    cleanup = VariedEmail()
    eng.cleanup = cleanup
    raw = words(CLEANUP_PIECE_WORDS * 2 + 25)
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, "Email")
    assert applied
    assert sum(text.count(value) for value in [
        "Dear Team,", "Hello Team,", "Hi Team,",
    ]) == 1
    assert sum(text.count(value) for value in [
        "Best regards,", "Sincerely,", "Regards,",
    ]) == 1
    assert_words_once(text, CLEANUP_PIECE_WORDS * 2 + 25)


async def test_email_break_envelope(engine):
    eng, _ = engine

    class BreakEmail(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(
                f"Dear Team,⏎{result.text}⏎Best regards,⏎Alex",
                result.applied, result.ms)

    eng.cleanup = BreakEmail()
    text, _, _, _, _ = await eng._apply_formatting(
        words(CLEANUP_PIECE_WORDS * 2 + 25), None, None, "Email")
    assert text.count("Dear Team,") == 1
    assert text.count("Best regards,") == 1
    assert text.count("Alex") == 1


async def test_email_signoff_with_name(engine):
    eng, _ = engine

    class SignedCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(
                f"Dear Team,\n{result.text}\nBest regards,\nAlex",
                result.applied, result.ms)

    eng.cleanup = SignedCleanup()
    text, _, _, _, _ = await eng._apply_formatting(
        words(CLEANUP_PIECE_WORDS * 2 + 10), None, None, "Email")
    assert text.count("Best regards,") == 1
    assert text.count("\nAlex") == 1


async def test_cancel_between_pieces(engine):
    eng, _ = engine
    cancel = threading.Event()

    class CancellingCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            cancel.set()
            return result

    cleanup = CancellingCleanup()
    eng.cleanup = cleanup
    await eng._apply_formatting(words(650), None, None, None, cancel_event=cancel)
    assert len(cleanup.calls) == 1


async def test_piece_head_retraction(engine):
    eng, _ = engine
    cleanup = BudgetCleanup(limit=CLEANUP_PIECE_WORDS)
    eng.cleanup = cleanup
    first = " ".join(f"first{index:04d}" for index in range(65))
    raw = first + ". target phrase no wait " + words(90)
    await eng._apply_formatting(raw, None, None, None)
    assert any(call[0].startswith("target phrase no wait") for call in cleanup.calls)
    assert all(_cleanup_units(call[0]) <= CLEANUP_PIECE_WORDS for call in cleanup.calls)


async def test_list_seam(engine):
    eng, _ = engine

    class ListCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(f"1. {raw}", result.applied, result.ms)

    cleanup = ListCleanup()
    eng.cleanup = cleanup
    text, _, _, applied, _ = await eng._apply_formatting(words(150), None, None, None)
    assert applied
    assert re.findall(r"(?m)^\s*(\d+)\. ", text) == ["1", "2"]
    assert "never restart at 1" in cleanup.calls[1][1]


async def test_separate_lists(engine):
    eng, _ = engine

    class SeparateLists(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            if len(self.calls) == 1:
                return CleanupResult(f"1. Milk⏎2. Eggs⏎{result.text}", True, 7)
            return CleanupResult(f"1. Call Bob⏎2. Email Ann⏎{result.text}", True, 7)

    eng.cleanup = SeparateLists()
    text, _, _, _, _ = await eng._apply_formatting(words(150), None, None, None)
    assert re.findall(r"(?m)^(\d+)\. ", text) == ["1", "2", "1", "2"]
    assert "never restart at 1" not in eng.cleanup.calls[1][1]


async def test_break_list_seam(engine):
    eng, _ = engine

    class BreakList(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(f"1. {result.text}⏎", True, 7)

    eng.cleanup = BreakList()
    text, _, _, _, _ = await eng._apply_formatting(words(150), None, None, None)
    assert re.findall(r"(?m)^(\d+)\. ", text) == ["1", "2"]


async def test_failed_piece_keeps_words(engine):
    eng, _ = engine

    class OneFailure(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            if len(self.calls) == 2:
                return CleanupResult(raw, False, 7, "timeout")
            return result

    cleanup = OneFailure()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    count = CLEANUP_PIECE_WORDS * 3 - 1
    text, _, _, applied, reason = await eng._apply_formatting(
        words(count), None, None, None, session=Session("failed-piece", {}))
    assert not applied
    assert reason == "partial_cleanup"
    assert len(cleanup.calls) == 3
    assert text.count("<") == 2
    assert_words_once(text, count)
    events = [call.args[0] for call in eng._send.await_args_list]
    assert [event["completed"] for event in events] == [1, 2, 3]


async def test_all_pieces_unavailable(engine):
    eng, _ = engine

    class FailedCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            self.calls.append((raw, prompt, kwargs))
            return CleanupResult(raw, False, 7, "timeout")

    cleanup = FailedCleanup()
    eng.cleanup = cleanup
    raw = words(CLEANUP_PIECE_WORDS * 2)
    text, _, _, applied, reason = await eng._apply_formatting(raw, None, None, None)
    assert not applied
    assert reason == "cleanup_unavailable"
    assert_words_once(text, CLEANUP_PIECE_WORDS * 2)


async def test_retry_without_context(engine):
    eng, _ = engine

    class ContextLengthCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            if "Previous text" in prompt:
                return CleanupResult(raw, False, 7, "length")
            return result

    cleanup = ContextLengthCleanup()
    eng.cleanup = cleanup
    text, _, _, applied, _ = await eng._apply_formatting(words(150), None, None, None)
    assert applied
    assert len(cleanup.calls) == 3
    assert "Previous text" in cleanup.calls[1][1]
    assert "Previous text" not in cleanup.calls[2][1]
    assert text.count("<") == 2


async def test_cleanup_piece_progress(engine):
    eng, _ = engine
    eng.cleanup = BudgetCleanup()
    eng._send = AsyncMock()
    session = Session("progress", {})
    count = CLEANUP_PIECE_WORDS * 3 - 1
    await eng._apply_formatting(words(count), None, None, None, session=session)
    events = [call.args[0] for call in eng._send.await_args_list]
    assert [event["completed"] for event in events] == [1, 2, 3]
    assert all(event["event"] == "finalize_progress" for event in events)


async def test_filler_gate_pieces(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    first = " ".join(f"first{index:04d}" for index in range(70))
    second = " ".join(f"second{index:04d}" for index in range(70))
    session = Session("segments", {})
    await eng._apply_formatting(
        "um " + first + " " + second, None, None, None, session=session)
    assert len(cleanup.calls) == 2
    assert "first0000" in cleanup.calls[0][0]
    assert "second0069" in cleanup.calls[-1][0]


async def test_stt_before_cleanup(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", words(30))
    eng, sock = engine
    eng.cleanup = BudgetCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "stt-progress", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "stt-progress"})
        events = []
        while True:
            event = await client.recv()
            events.append(event)
            if event["event"] == "final":
                break
        stages = [event["stage"] for event in events
                  if event["event"] == "finalize_progress"]
        final = events[-1]
        assert stages[0] == "stt" and stages[-1] == "cleanup"
        assert final["cleanup_applied"]
    finally:
        client.close()


async def test_priority_tail_bounded(engine, monkeypatch):
    tail = words(550)
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine

    class PendingLast(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.started = asyncio.Event()

        async def cleanup(self, raw, prompt, **kwargs):
            if raw == SEG2:
                self.started.set()
                await asyncio.Event().wait()
            return await super().cleanup(raw, prompt, **kwargs)

    cleanup = PendingLast()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "long-tail", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        await asyncio.wait_for(cleanup.started.wait(), 2)
        await client.send_json({"cmd": "stop", "session": "long-tail"})
        final = await client.recv_event("final", timeout=10)
        assert final["cleanup_applied"]
        assert all(_cleanup_units(raw) <= cleanup.limit
                   for raw, _, _ in cleanup.calls)
        assert sum(raw == SEG1 for raw, _, _ in cleanup.calls) == 1
        assert SEG1 in final["text"]
        assert SEG2 in final["text"]
        assert all(f"word{index:04d}" in final["text"] for index in range(550))
    finally:
        client.close()


@pytest.mark.parametrize("retract", [True, False])
async def test_stream_tail_bounded(engine, monkeypatch, retract):
    tail = ("scratch that " if retract else "") + words(550)
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "stream-tail", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "stream-tail"})
        final = await client.recv_event("final", timeout=10)
        assert final["text"]
        assert all(_cleanup_units(raw) <= CLEANUP_PIECE_WORDS
                   for raw, _, _ in cleanup.calls)
        assert all(f"word{index:04d}" in final["text"] for index in range(550))
    finally:
        client.close()


async def test_priority_merge_pieces(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    session = Session("priority-pieces", {})
    session.stream_prompt = "Original prompt"
    session.chunk_raws = [words(100)]
    pending = asyncio.create_task(asyncio.Event().wait())
    session.chunk_tasks = [pending]
    tail = " ".join(f"tail{index:04d}" for index in range(250))
    eng.stt.segments_used_for_final = True
    eng.stt.final_tail = tail
    raw = session.chunk_raws[0] + " " + tail
    result = await eng._streaming_result(session, raw)
    assert result is not None and result[3]
    assert len(cleanup.calls) > 1
    assert all(_cleanup_units(call[0]) <= CLEANUP_PIECE_WORDS
               for call in cleanup.calls)


async def test_romanize_pieces_bounded(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = True
    class RomanizingCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            self.calls.append((raw, prompt, kwargs))
            return CleanupResult(raw.replace("शब्द", "shabd"), True, 7)

    cleanup = RomanizingCleanup()
    eng.cleanup = cleanup
    raw = " ".join(["यह शब्द यहाँ है"] * 85) + "\n" + " ".join(["यह शब्द यहाँ है"] * 85)
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) > 1
    assert all("Romanize" in call[1] or "romanize" in call[1]
               for call in cleanup.calls)
    assert all("⏎" not in call[0] for call in cleanup.calls)
    assert all(call[2]["timeout_ms"] >= 4000 for call in cleanup.calls)
    assert text.count("shabd") == 170
    assert "शब्द" not in text
    assert "\n" in text


async def test_native_pieces_bounded(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = False

    class NativeCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            self.calls.append((raw, prompt, kwargs))
            if len(raw) > self.limit:
                return CleanupResult(raw, False, 0, "timeout")
            return CleanupResult(raw, True, 7)

    cleanup = NativeCleanup()
    eng.cleanup = cleanup
    raw = "这是一个需要完整保留的长段落。" * 80
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) > 1
    assert all(len(call[0]) <= cleanup.limit for call in cleanup.calls)
    assert text == raw


async def test_native_short_main_call(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = False
    cleanup = BudgetCleanup(limit=1000)
    eng.cleanup = cleanup
    raw = "中" * (CLEANUP_SINGLE_CALL_UNITS + 5)
    session = Session("short-native", {})
    session.samples = 5 * 16_000
    _, _, _, applied, reason = await eng._apply_formatting(
        raw, None, None, None, session=session)
    assert applied
    assert reason != "chunked"
    assert len(cleanup.calls) == 1
    from velora_engine.cleanup import adaptive_timeout_ms
    assert cleanup.calls[0][2]["timeout_ms"] == adaptive_timeout_ms(raw)


async def test_native_reprocess_once(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = False
    cleanup = BudgetCleanup(limit=1000)
    eng.cleanup = cleanup
    raw = "中" * (CLEANUP_SINGLE_CALL_UNITS + 5)
    _, _, _, applied, reason = await eng._apply_formatting(
        raw, None, None, None)
    assert applied and reason != "chunked"
    assert len(cleanup.calls) == 1


@pytest.mark.parametrize("recovery", [True, False])
async def test_recovery_yields_to_start(engine, monkeypatch, recovery):
    eng, sock = engine
    eng.config.data["cleanup_enabled"] = False
    audio = eng.audio.save("windowed-recovery", np.ones(12 * 16_000, dtype=np.float32) * 0.1)
    assert audio is not None
    monkeypatch.setattr(eng.audio, "load", lambda _name: (_ for _ in ()).throw(
        AssertionError("whole clip loaded")))
    monkeypatch.setattr(server_mod, "batch_ranges", lambda count, read_span: [
        (start, min(start + 16_000, count)) for start in range(0, count, 16_000)
    ])
    entered = threading.Event()
    release = threading.Event()
    calls = 0

    def decode(_backend, pcm):
        nonlocal calls
        assert len(pcm) <= 16_000
        calls += 1
        if calls == 1:
            entered.set()
            assert release.wait(5)
        return f"part{calls}"

    monkeypatch.setattr(server_mod, "transcribe_clip", decode)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "reprocess", "audio": audio, "id": 71,
                                "recovery": recovery})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        assert await asyncio.to_thread(eng._reprocess_preempt.wait, 2)
        release.set()
        await client.send_json({"cmd": "ping"})
        recovered = None
        while True:
            event = await client.recv()
            if event["event"] == "reprocessed":
                recovered = event
            if event["event"] == "pong":
                break
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "cancel", "session": "live"})
        cancelled = False
        while not cancelled or recovered is None:
            try:
                event = await client.recv(timeout=2)
            except asyncio.TimeoutError:
                pytest.fail(
                    f"recovery stalled: queue={eng._recovery_queue!r} "
                    f"running={eng._reprocessing} paused={eng._recovery_paused} "
                    f"session={eng.session!r} cancelled={cancelled} "
                    f"starting={eng._starting} finalizing={eng._finalizing} "
                    f"cancelling={eng._cancelling_session} "
                    f"active={eng._cancel_active_task!r} "
                    f"transcribing={eng._transcribing} editing={eng._editing}")
            if event["event"] == "cancelled":
                cancelled = event["session"] == "live"
            if event["event"] == "reprocessed":
                recovered = event
        assert cancelled
        assert recovered["id"] == 71
        assert recovered["raw"].count("part") == 12
    finally:
        release.set()
        client.close()


async def test_wedged_recovery_controls(engine, monkeypatch):
    eng, sock = engine
    audio = eng.audio.save("wedged-recovery", AUDIO)
    assert audio is not None
    entered = threading.Event()
    release = threading.Event()

    def decode(_backend, _pcm):
        entered.set()
        release.wait()
        return "recovered"

    monkeypatch.setattr(server_mod, "transcribe_clip", decode)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "reprocess", "audio": audio, "id": 72,
                                "recovery": True})
        assert await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong", timeout=1))["event"] == "pong"
        await client.send_json({"cmd": "cancel", "session": "live"})
        assert (await client.recv_event("cancelled", timeout=1))["session"] == "live"
    finally:
        release.set()
        client.close()


async def test_recovery_bound_busy(engine, monkeypatch):
    eng, sock = engine
    audio = eng.audio.save("bound-recovery", AUDIO)
    assert audio is not None
    monkeypatch.setattr(eng, "_stt_stall_s", lambda _samples: 0.02)
    entered = threading.Event()
    release = threading.Event()

    def decode(_backend, _pcm):
        entered.set()
        release.wait()
        return "recovered"

    monkeypatch.setattr(server_mod, "transcribe_clip", decode)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "reprocess", "audio": audio, "id": 73,
                                "recovery": True})
        assert await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "live"})
        started = None
        while True:
            busy = await client.recv(timeout=1)
            if busy.get("event") == "finalize_started":
                started = busy
            if busy.get("event") == "error":
                break
        assert started is not None and started["stall_after_s"] > 0.02
        assert busy["message"] == "busy recovering"
        assert busy["recovering_id"] == 73
        assert (eng.audio.active_dir / "live.pcm16.part").is_file()
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong", timeout=1))["event"] == "pong"
    finally:
        release.set()
        client.close()


async def test_stop_after_window(engine, monkeypatch):
    eng, sock = engine
    audio = eng.audio.save("release-wait", AUDIO)
    assert audio is not None
    cleanup_entered = asyncio.Event()
    cleanup_release = asyncio.Event()
    release_entered = threading.Event()
    release_done = threading.Event()

    async def held_cleanup(*args, **kwargs):
        cleanup_entered.set()
        await cleanup_release.wait()
        return "recovered", None, 0, False, ""

    def held_release():
        release_entered.set()
        release_done.wait()

    monkeypatch.setattr(eng, "_apply_formatting", held_cleanup)
    monkeypatch.setattr(eng, "_release_stt_memory", held_release)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "reprocess", "audio": audio, "id": 74,
                                "recovery": True})
        await asyncio.wait_for(cleanup_entered.wait(), 2)
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        assert await asyncio.wait_for(
            asyncio.to_thread(eng._reprocess_preempt.wait), 2)
        cleanup_release.set()
        assert await asyncio.wait_for(asyncio.to_thread(release_entered.wait), 2)
        assert eng._reprocess_window_bound_s is None
        assert eng._start_wait_deadline is not None
        remaining = eng._start_wait_deadline - time.monotonic()
        await client.send_json({"cmd": "stop", "session": "live"})
        started = await client.recv_event("finalize_started", timeout=1)
        assert started["stall_after_s"] > remaining
    finally:
        cleanup_release.set()
        release_done.set()
        client.close()


async def test_deferred_owns_state(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = True
    entered = asyncio.Event()
    release_a = asyncio.Event()
    release_b = asyncio.Event()
    original = eng._cmd_start

    async def held_start(msg):
        if msg["session"] == "a":
            entered.set()
            try:
                await release_a.wait()
            except asyncio.CancelledError:
                await release_a.wait()
                raise
        if msg["session"] == "b":
            await release_b.wait()
        await original(msg)

    monkeypatch.setattr(eng, "_cmd_start", held_start)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        # One buffered burst lets B claim shared state before A unwinds.
        await client.send_json({"cmd": "start", "session": "a", "context": {}})
        await asyncio.wait_for(entered.wait(), 2)
        start_a = eng._start_task
        client.writer.write(protocol.encode_json({"cmd": "cancel", "session": "a"}))
        client.writer.write(protocol.encode_json({"cmd": "start", "session": "b", "context": {}}))
        await client.writer.drain()
        assert (await client.recv_event("cancelled"))["session"] == "a"
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "b"})
        await client.send_json({"cmd": "ping"})
        await client.recv_event("pong")
        spool = eng.audio.active_dir / "b.pcm16.part"
        assert spool.is_file() and spool.stat().st_size == len(AUDIO) * 2
        assert eng._start_stop is not None
        release_a.set()
        assert start_a is not None
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(start_a, 2)
        assert spool.is_file() and eng._start_stop is not None
        release_b.set()
        final = await client.recv_event("final")
        assert final["session"] == "b" and not final.get("auto_stopped", False)
    finally:
        release_a.set()
        release_b.set()
        client.close()


async def test_deferred_frame_cap(engine):
    eng, _ = engine
    eng.config.data["max_recording_s"] = 0.05
    eng._start_session_id = "capped"
    eng._start_spool = eng.audio.begin_active("capped")
    gate = asyncio.Event()
    eng._start_task = asyncio.create_task(gate.wait())
    try:
        await eng._dispatch(protocol.FRAME_AUDIO, AUDIO.tobytes())
        assert eng._start_audio_samples == 800
        assert len(eng._start_audio[0]) == 800 * 4
        assert eng._start_spool is not None
        assert eng._start_spool.path.stat().st_size == 800 * 2
    finally:
        gate.set()
        await eng._start_task
        eng._start_task = None
        if eng._start_spool is not None:
            eng.audio.discard_active(eng._start_spool)


async def test_cancel_unwind_survives(engine, monkeypatch):
    eng, sock = engine
    entered = threading.Event()
    release = threading.Event()
    reset = eng.stt.reset
    resumed = asyncio.Event()
    b_entered = asyncio.Event()
    original_resume = eng._resume_cleanup_recovery
    original_start = eng._cmd_start

    def held_reset():
        entered.set()
        release.wait()
        reset()

    def resume():
        original_resume()
        resumed.set()

    async def observe_start(msg):
        if msg["session"] == "b":
            b_entered.set()
        await original_start(msg)

    monkeypatch.setattr(eng.stt, "reset", held_reset)
    monkeypatch.setattr(eng, "_resume_cleanup_recovery", resume)
    monkeypatch.setattr(eng, "_cmd_start", observe_start)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "a", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "ping"})
        await client.recv_event("pong")
        if eng._start_task is not None:
            await asyncio.wait_for(eng._start_task, 2)
        eng.stt.windowed_finalize = True
        await client.send_json({"cmd": "cancel", "session": "a"})
        await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await client.send_json({"cmd": "start", "session": "b", "context": {}})
        await asyncio.wait_for(b_entered.wait(), 2)
        await client.send_json({"cmd": "cancel", "session": "b"})
        release.set()
        await asyncio.wait_for(resumed.wait(), 2)
        assert not eng.stt.windowed_finalize
        assert eng._cancel_active_task is None or eng._cancel_active_task.done()
    finally:
        release.set()
        client.close()


async def test_duplicate_cancel(engine, monkeypatch):
    eng, sock = engine
    entered = asyncio.Event()
    release = asyncio.Event()
    original = eng._abort_session

    async def held_abort(*args, **kwargs):
        entered.set()
        await release.wait()
        await original(*args, **kwargs)

    monkeypatch.setattr(eng, "_abort_session", held_abort)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "ping"})
        await client.recv_event("pong")
        if eng._start_task is not None:
            await asyncio.wait_for(eng._start_task, 2)
        client.writer.write(protocol.encode_json({"cmd": "cancel", "session": "live"}))
        client.writer.write(protocol.encode_json({"cmd": "cancel", "session": "live"}))
        await client.writer.drain()
        await asyncio.wait_for(entered.wait(), 2)
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong"))["event"] == "pong"
        assert len(eng._cancel_confirm_tasks) == 1
        active = eng._cancel_active_task
        assert active is not None
        release.set()
        assert (await client.recv_event("cancelled"))["session"] == "live"
        await asyncio.wait_for(active, 2)
        await client.send_json({"cmd": "ping"})
        assert (await client.recv())["event"] == "pong"
        assert not eng._cancel_confirm_tasks
    finally:
        release.set()
        client.close()


async def test_model_load_refuses_start(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["save_audio"] = True
    audio = eng.audio.save("held-load", AUDIO)
    assert audio is not None
    entered = asyncio.Event()
    release = asyncio.Event()
    original = eng._stt_for_reprocess

    async def held_model(model_id, language):
        entered.set()
        await release.wait()
        return await original(model_id, language)

    monkeypatch.setattr(eng, "_stt_for_reprocess", held_model)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "reprocess", "audio": audio, "id": 92})
        await asyncio.wait_for(entered.wait(), 2)
        await client.send_json({"cmd": "start", "session": "live", "context": {}})
        await client.send_audio(AUDIO)
        busy = await client.recv(timeout=1)
        assert busy["message"] == "busy reprocessing a clip — try again in a moment"
        if eng._start_task is not None:
            await asyncio.wait_for(eng._start_task, 2)
        assert not list(eng.audio.active_dir.glob("*.pcm16.part"))
        release.set()
        assert (await client.recv_event("reprocessed"))["id"] == 92
        client.close()
        await client.writer.wait_closed()
        reconnected = await connect(sock)
        ready = await reconnected.recv_event("ready")
        if not ready["setup_complete"]:
            await reconnected.recv_event("setup_complete")
        await reconnected.send_json({"cmd": "ping"})
        assert (await reconnected.recv())["event"] == "pong"
        reconnected.close()
    finally:
        release.set()
        client.close()


async def test_reprocess_during_final(engine, monkeypatch):
    eng, _ = engine
    eng.config.data["cleanup_enabled"] = False
    audio = eng.audio.save("other-clip", np.tile(AUDIO, 20))
    assert audio is not None
    chunk = np.ones(16_000, dtype=np.float32) * 0.1
    session = Session("live", {})
    session.samples = 2 * len(chunk)
    eng._send = AsyncMock()
    eng.stt.needs_windowed_fallback = True
    monkeypatch.setattr(eng.stt, "finalize", lambda: "")
    monkeypatch.setattr(eng.stt, "take_fallback_chunks",
                        lambda: ("", [chunk] * 2), raising=False)
    monkeypatch.setattr(server_mod, "batch_ranges", lambda _count, _read: [
        (0, len(chunk)), (len(chunk), 2 * len(chunk)),
    ])
    entered = threading.Event()
    release = threading.Event()
    calls = 0

    def decode(_backend, _pcm):
        nonlocal calls
        calls += 1
        if calls == 1:
            entered.set()
            release.wait()
        return f"part{calls}"

    monkeypatch.setattr(server_mod, "transcribe_clip", decode)
    eng._begin_finalize(session)
    final_task = eng._finalize_task
    assert final_task is not None
    try:
        assert await asyncio.wait_for(asyncio.to_thread(entered.wait), 2)
        await eng._cmd_reprocess({"audio": audio, "id": 93})
        refused = [call.args[0] for call in eng._send.await_args_list
                   if call.args[0].get("event") == "reprocess_failed"]
        assert len(refused) == 1
        assert refused[0]["error"] == "reprocess: busy (another job in progress)"
    finally:
        release.set()
        await asyncio.wait_for(final_task, 2)
        if eng._reprocess_task is not None:
            await asyncio.wait_for(eng._reprocess_task, 2)
    final = [call.args[0] for call in eng._send.await_args_list
             if call.args[0].get("event") == "final"][0]
    assert final["raw"] == "part1 part2"
    assert calls == 2


async def test_native_chars_preserved(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = False

    class NativeCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            self.calls.append((raw, prompt, kwargs))
            return CleanupResult(raw, _cleanup_units(raw) <= self.limit, 7)

    cleanup = NativeCleanup()
    eng.cleanup = cleanup
    raw = " ".join(["这是完整的段落" * 45] * 20)
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) > 20
    assert all(_cleanup_units(call[0]) <= cleanup.limit for call in cleanup.calls)
    assert all(
        call[2]["timeout_ms"] == TIMEOUT_CEILING_MS
        for call in cleanup.calls if _cleanup_units(call[0]) == CLEANUP_PIECE_WORDS
    )
    assert text.replace(" ", "") == raw.replace(" ", "")


async def test_single_call_budget(engine):
    eng, _ = engine
    cleanup = BudgetCleanup(limit=130)
    eng.cleanup = cleanup
    raw = words(120)
    text, _, _, applied, reason = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) == 1
    assert reason != "chunked"
    assert_words_once(text, 120)


async def test_worker_piece_recovery(engine):
    eng, _ = engine

    class RecoveringCleanup(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.recovery_deadline = 0.0

        async def cleanup(self, raw, prompt, **kwargs):
            if not self.loaded:
                self.calls.append((raw, prompt, kwargs))
                return CleanupResult(raw, False, 0, "llm_not_loaded")
            result = await super().cleanup(raw, prompt, **kwargs)
            if len(self.calls) == 2:
                self.loaded = False
                return CleanupResult(raw, False, 7, "timeout_hard")
            return result

        def resume_recovery(self):
            asyncio.get_running_loop().call_later(0.01, setattr, self, "loaded", True)

    cleanup = RecoveringCleanup()
    eng.cleanup = cleanup
    eng._send = AsyncMock()
    eng._cleanup_recovery_deferred = True
    count = CLEANUP_PIECE_WORDS * 3 - 1
    text, _, _, applied, reason = await eng._apply_formatting(
        words(count), None, None, None, session=Session("recovery", {}))
    assert not applied
    assert reason == "partial_cleanup"
    assert len(cleanup.calls) == 3
    assert text.count("<") == 2
    assert_words_once(text, count)
    events = [call.args[0] for call in eng._send.await_args_list]
    assert any(event.get("stage") == "recovery" for event in events)
    failed = next(index for index, event in enumerate(events)
                  if event.get("stage") == "cleanup" and event.get("completed") == 2)
    recovered = next(index for index, event in enumerate(events)
                     if event.get("stage") == "recovery")
    assert failed < recovered
    assert events[failed]["stall_after_s"] >= PIECE_RECOVERY_WAIT_MAX_S


async def test_cleanup_load_bound(engine, monkeypatch):
    import velora_engine.cleanup_process as process

    eng, _ = engine
    monkeypatch.setattr(process, "LOAD_TIMEOUT_S", 1.0)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    eng.cleanup = cleanup
    try:
        await cleanup.load_async("warm prompt")
        assert await cleanup.hibernate()
        request = cleanup._request
        attempts = [0]

        async def one_timeout(operation, **payload):
            if operation == "load":
                attempts[0] += 1
                if attempts[0] == 1:
                    await asyncio.Event().wait()
            return await request(operation, **payload)

        monkeypatch.setattr(cleanup, "_request", one_timeout)
        eng._send = AsyncMock()
        await eng._apply_formatting(
            words(30), None, None, None,
            session=Session("load-bound", {}))
        events = [call.args[0] for call in eng._send.await_args_list]
        load = next(event for event in events if event.get("stage") == "cleanup_load")
        attempts_expected = process.RECOVERY_ATTEMPTS
        reap_expected = 2 * process.EXIT_WAIT_S + process.KILL_REAP_TIMEOUT_S
        backoff_expected = process.RECOVERY_BACKOFF_S * sum(range(1, attempts_expected))
        expected = (
            process.RETIRED_EXIT_TIMEOUT_S
            + attempts_expected * (process.LOAD_TIMEOUT_S + reap_expected)
            + backoff_expected + eng._cleanup_stall_s()
        )
        assert load["stall_after_s"] == pytest.approx(expected)
        assert attempts[0] == 2
    finally:
        await cleanup.aclose()


async def test_warmup_one_piece(engine):
    eng, _ = engine
    eng._send = AsyncMock()
    eng._finish_cleanup_warmup = AsyncMock(return_value=0.0)

    class RecoveringQueue(BudgetCleanup):
        recovery_deadline = 0.0

        async def cleanup(self, raw, prompt, **kwargs):
            self.calls.append((raw, prompt, kwargs))
            if kwargs.get("queue_timeout_s") == 0.0:
                self.loaded = False
                return CleanupResult(raw, False, 0, "timeout_queue")
            if not self.loaded:
                return CleanupResult(raw, False, 0, "llm_not_loaded")
            return CleanupResult(f"<{raw}>", True, 7)

        def resume_recovery(self):
            asyncio.get_running_loop().call_later(0.01, setattr, self, "loaded", True)

    cleanup = RecoveringQueue()
    eng.cleanup = cleanup
    eng._cleanup_recovery_deferred = True
    raw = words(220)
    text, _, _, applied, reason = await eng._apply_formatting(
        raw, None, None, None, session=Session("warmup", {}))
    assert not applied and reason == "partial_cleanup"
    assert [call[2].get("queue_timeout_s") for call in cleanup.calls] == [0.0, None, None]
    assert text.count("<") == 2
    assert_words_once(text, 220)


async def test_fallback_windows(engine, monkeypatch):
    eng, _ = engine
    session = Session("window-fallback", {})
    session.samples = 180 * 16_000
    eng._send = AsyncMock()
    decodes = []
    chunk = np.zeros(16_000, dtype=np.float32)
    chunks = [chunk] * 180

    async def decode(_fn, _backend, pcm):
        decodes.append(len(pcm))
        return f"part{len(decodes)}"

    monkeypatch.setattr(eng, "_stt_call", decode)
    text = await eng._decode_windows(session, chunks)
    events = [call.args[0] for call in eng._send.await_args_list]
    progress = [event for event in events if event.get("stage") == "stt_window"]
    assert len(decodes) > 1
    assert len(progress) == len(decodes)
    assert all(event["stage"] == "stt_window" for event in progress)
    assert max(decodes) <= 90 * 16_000
    assert sum(decodes) == session.samples
    assert text.split() == [f"part{index}" for index in range(1, len(decodes) + 1)]


async def test_failed_window_keeps_rest(engine, monkeypatch):
    eng, _ = engine
    eng.config.data["cleanup_enabled"] = False
    session = Session("gap-final", {})
    chunk = np.ones(16_000, dtype=np.float32) * 0.1
    session.samples = 3 * len(chunk)
    eng._send = AsyncMock()
    eng.stt.needs_windowed_fallback = True
    monkeypatch.setattr(eng.stt, "finalize", lambda: "")
    monkeypatch.setattr(
        eng.stt, "take_fallback_chunks", lambda: ("", [chunk] * 3), raising=False)
    monkeypatch.setattr(server_mod, "batch_ranges", lambda _count, _read: [
        (0, len(chunk)), (len(chunk), 2 * len(chunk)),
        (2 * len(chunk), 3 * len(chunk)),
    ])
    calls = 0

    async def decode(fn, *args):
        nonlocal calls
        if fn is server_mod.transcribe_clip:
            calls += 1
            if calls in (2, 3):
                raise RuntimeError("window failed")
            return f"part{calls}"
        return fn(*args)

    monkeypatch.setattr(eng, "_stt_call", decode)
    await eng._finalize_session_inner(session)
    finals = [call.args[0] for call in eng._send.await_args_list
              if call.args[0].get("event") == "final"]
    assert len(finals) == 1
    assert finals[0]["raw"] == "part1 part4"
    assert "part1" in finals[0]["text"].lower()
    assert "part4" in finals[0]["text"].lower()
    assert finals[0]["failed_window_count"] == 1
    assert finals[0]["failed_window_s"] == pytest.approx(1)
    progress = [call.args[0] for call in eng._send.await_args_list
                if call.args[0].get("stage") == "stt_window"]
    assert [event["completed"] for event in progress] == [1, 2, 3]


async def test_retry_rearms_window(engine, monkeypatch):
    eng, _ = engine
    session = Session("retry-window", {})
    eng._send = AsyncMock()
    retry_started = asyncio.Event()
    retry_release = asyncio.Event()
    calls = 0
    span = 0

    async def decode(_fn, _backend, pcm):
        nonlocal calls, span
        calls += 1
        span = len(pcm)
        if calls == 1:
            raise RuntimeError("first attempt failed")
        retry_started.set()
        await retry_release.wait()
        return "healthy retry"

    monkeypatch.setattr(eng, "_stt_call", decode)
    task = asyncio.create_task(eng._decode_windows(
        session, [np.ones(16_000, dtype=np.float32)] * 100))
    try:
        await asyncio.wait_for(retry_started.wait(), 2)
        events = [call.args[0] for call in eng._send.await_args_list]
        assert any(event.get("stage") == "stt_retry"
                   and event["stall_after_s"] == eng._stt_stall_s(span)
                   for event in events)
    finally:
        retry_release.set()
        await task


async def test_cancel_stops_windows(engine, monkeypatch):
    eng, _ = engine
    session = Session("cancel-windows", {})
    eng._send = AsyncMock()
    calls = [0]

    async def decode(_fn, _backend, _pcm):
        calls[0] += 1
        session.cancelled = True
        return "first window"

    monkeypatch.setattr(eng, "_stt_call", decode)
    chunk = np.ones(16_000, dtype=np.float32)
    await eng._decode_windows(session, [chunk] * 360)
    assert calls[0] == 1


@pytest.mark.parametrize("backend_name", ["WhisperBackend", "ParakeetBackend"])
def test_backend_defers_whole(backend_name):
    from velora_engine import stt

    backend = getattr(stt, backend_name)("test-model")
    backend.windowed_finalize = True
    backend._chunks = [np.ones(1, dtype=np.float32)]
    backend._samples = 91 * stt.SAMPLE_RATE
    if backend_name == "WhisperBackend":
        backend._session_had_speech = True
    assert backend.finalize() == ""
    assert backend.needs_windowed_fallback
    prefix, chunks = backend.take_fallback_chunks()
    assert prefix == ""
    assert chunks[0].shape == (1,)
    assert not backend._chunks


@pytest.mark.parametrize("backend_name", ["WhisperBackend", "ParakeetBackend"])
def test_backend_defers_tail(backend_name):
    from velora_engine import stt

    backend = getattr(stt, backend_name)("test-model")
    backend.windowed_finalize = True
    committed = np.ones(10 * stt.SAMPLE_RATE, dtype=np.float32)
    tail = np.ones(91 * stt.SAMPLE_RATE, dtype=np.float32)
    backend._chunks = [committed, tail]
    backend._samples = 101 * stt.SAMPLE_RATE
    backend._decoded_samples = 10 * stt.SAMPLE_RATE
    backend._segments = ["first words"]
    if backend_name == "WhisperBackend":
        backend._session_had_speech = True
    assert backend.finalize() == ""
    assert backend.needs_windowed_fallback
    prefix, chunks = backend.take_fallback_chunks()
    assert prefix == "first words"
    assert sum(map(len, chunks)) == len(tail)


async def test_auto_final_keeps_frame(engine):
    eng, sock = engine
    eng.config.data["max_recording_s"] = 0.01
    eng.config.data["save_audio"] = False
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "limit", "context": {}})
        await client.send_audio(AUDIO)
        stopped = await client.recv_event("recording_auto_stopped")
        final = await client.recv_event("final")
        assert stopped["session"] == "limit"
        assert stopped["duration_s"] == 0.01
        assert final["session"] == "limit" and final["auto_stopped"]
    finally:
        client.close()
