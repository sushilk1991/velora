"""Streaming segment cleanup over the real unix socket (smartness-v2 §2):
FakeBackend segment mode + a fake cleanup engine — partials per segment,
concurrent chunk cleanup, stitched finalize, retraction merge, cancel, and the
exact legacy behavior when streaming_cleanup is off."""

import asyncio

import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

from velora_engine.cleanup import CleanupResult

SEG1 = "alpha one two three four five six"
SEG2 = "beta seven eight nine ten eleven twelve"
TAIL = "tail words arrive at the very end"


class FakeCleanup:
    """Stands in for CleanupEngine: deterministic, capturable, optionally slow."""

    def __init__(self, delay: float = 0.0):
        self.loaded = True
        self.model_id = "fake-cleanup"
        self.delay = delay
        self.calls: list[tuple[str, str]] = []
        self.cancel_events = []

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        if self.delay:
            await asyncio.sleep(self.delay)
        return CleanupResult(text=f"<{raw}>", applied=True, ms=7)


@pytest.fixture
def segments(monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)


async def run_dictation(client, session_id: str, chunks: int = 6, context: dict | None = None):
    await client.send_json({"cmd": "start", "session": session_id, "context": context or {}})
    for _ in range(chunks):  # FakeBackend closes one segment per 2 AUDIO chunks
        await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": session_id})


async def test_streaming_pipeline_end_to_end(engine, segments):
    eng, sock = engine
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "st1", "context": {}})
    partials = []
    for _ in range(4):
        await client.send_audio(AUDIO)
    # both segments emit a partial (whisper-style running text)
    while len(partials) < 2:
        evt = await client.recv(timeout=5)
        if evt.get("event") == "partial":
            partials.append(evt["text"])
    assert partials == [SEG1, f"{SEG1} {SEG2}"]
    assert eng.session is not None
    assert eng.session.prefix_cancel.is_set(), "committed cleanup preempts optional prefill"
    await client.send_json({"cmd": "stop", "session": "st1"})

    # transcript still fires FIRST, with the full raw text
    transcript = await client.recv_event("transcript")
    assert transcript["raw"] == f"{SEG1} {SEG2} {TAIL}"

    final = await client.recv_event("final")
    assert final["cleanup_applied"] is True
    assert final["cleanup_ms"] == 7  # the tail chunk's ms, not the sum
    assert final["text"] == f"<{SEG1}> <{SEG2}> <{TAIL}>."
    assert final["raw"] == f"{SEG1} {SEG2} {TAIL}"

    # three chunk cleanups: seg1, seg2, tail — seg2 and tail carry seam context
    assert [c[0] for c in cleanup.calls] == [SEG1, SEG2, TAIL]
    assert "Previous text (context only" not in cleanup.calls[0][1]
    assert f"<{SEG1}>" in cleanup.calls[1][1]
    assert "Previous text (context only, do NOT repeat it)" in cleanup.calls[1][1]
    assert f"<{SEG2}>" in cleanup.calls[2][1]
    client.close()


async def test_short_first_segment_does_not_disable_long_session_streaming(engine, monkeypatch):
    eng, sock = engine
    short_first = "alpha beta"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{short_first}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "short-first", chunks=4)
    final = await client.recv_event("final")

    assert [call[0] for call in cleanup.calls] == [short_first, SEG2, TAIL]
    assert final["text"] == f"<{short_first}> <{SEG2}> <{TAIL}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_short_first_terminal_segment_keeps_long_session_streaming(engine, monkeypatch):
    eng, sock = engine
    short_first = "alpha beta"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{short_first}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(
        client,
        "short-first-terminal",
        chunks=4,
        context={"bundle_id": "com.apple.Terminal", "app_name": "Terminal"},
    )
    final = await client.recv_event("final")

    assert [call[0] for call in cleanup.calls] == [short_first, SEG2, TAIL]
    assert final["text"] == f"<{short_first}> <{SEG2}> <{TAIL}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_retraction_segment_merges_with_previous(engine, monkeypatch):
    eng, sock = engine
    seg2 = "no wait make that six pm on monday"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{seg2}")
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)  # no tail
    cleanup = FakeCleanup(delay=0.2)  # slow: first task still pending at merge
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "st2", chunks=4)
    final = await client.recv_event("final")
    merged = f"{SEG1} {seg2}"
    # the retraction segment was NOT cleaned alone: one merged chunk
    assert final["text"] == f"<{merged}>."
    assert merged in [c[0] for c in cleanup.calls]
    assert seg2 not in [c[0] for c in cleanup.calls]  # never cleaned in isolation
    assert cleanup.cancel_events[0] is not None
    assert cleanup.cancel_events[0].is_set()  # replaced worker was cooperatively stopped
    assert cleanup.cancel_events[-1] is not None
    assert not cleanup.cancel_events[-1].is_set()
    client.close()


async def test_cancel_cancels_chunk_tasks(engine, segments):
    eng, sock = engine
    eng.cleanup = FakeCleanup(delay=5.0)  # tasks will still be pending
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "st3", "context": {}})
    for _ in range(4):
        await client.send_audio(AUDIO)
    for _ in range(100):
        if eng.session is not None and eng.session.chunk_tasks:
            break
        await asyncio.sleep(0.01)
    tasks = list(eng.session.chunk_tasks)
    assert tasks
    await client.send_json({"cmd": "cancel", "session": "st3"})
    await client.recv_event("cancelled")
    await asyncio.sleep(0.05)  # let cancellation propagate
    assert all(t.cancelled() for t in tasks)
    assert eng.session is None
    assert eng.cleanup.cancel_events
    assert all(event is not None and event.is_set() for event in eng.cleanup.cancel_events)

    # engine healthy: a fresh (non-streaming) dictation completes
    eng.cleanup.delay = 0.0
    await client.send_json({"cmd": "start", "session": "st3b", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "st3b"})
    final = await client.recv_event("final")
    assert final["session"] == "st3b"
    client.close()


async def test_streaming_cleanup_off_uses_whole_text_path(engine, segments):
    eng, sock = engine
    eng.config.data["streaming_cleanup"] = False
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "st4", "context": {}})
    partial_seen = False
    for _ in range(4):
        await client.send_audio(AUDIO)
    # segments are still decoded for HUD preview partials
    evt = await client.recv(timeout=5)
    if evt.get("event") == "partial":
        partial_seen = True
    assert partial_seen
    await client.send_json({"cmd": "stop", "session": "st4"})

    final = await client.recv_event("final")
    raw = f"{SEG1} {SEG2} {TAIL}"
    # exactly the legacy path: ONE cleanup over the whole raw text
    assert [c[0] for c in cleanup.calls] == [raw]
    assert final["text"] == f"<{raw}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_streaming_falls_back_when_cleanup_missing(engine, segments):
    """No cleanup LLM at all: segments are preview-only and the final result
    is the deterministic whole-text path (exactly as before this feature)."""
    eng, sock = engine
    assert eng.cleanup is None  # fake_stt never loads one
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "st5", chunks=4)
    final = await client.recv_event("final")
    raw = f"{SEG1} {SEG2} {TAIL}"
    assert final["raw"] == raw
    assert final["cleanup_applied"] is False
    assert final["text"] == raw + "."  # deterministic path adds final punctuation
    client.close()


async def test_glossary_initial_prompt_set_from_start_entities(engine, monkeypatch):
    eng, sock = engine
    eng.config.data["vocabulary"] = ["Velora"]
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({
        "cmd": "start", "session": "g1",
        "context": {"entities": [
            {"type": "person", "value": "Priya Sharma"},
            {"type": "nearby", "value": "do not use this"},
        ]},
    })
    for _ in range(50):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)
    assert eng.stt.initial_prompt == "Glossary: Velora, Priya Sharma."
    await client.send_json({"cmd": "cancel", "session": "g1"})
    await client.recv_event("cancelled")

    # no vocab and no entities → prompt cleared
    eng.config.data["vocabulary"] = []
    await client.send_json({"cmd": "start", "session": "g2", "context": {}})
    await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": "g2"})
    await client.recv_event("final")
    assert eng.stt.initial_prompt is None
    client.close()
