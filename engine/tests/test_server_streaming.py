"""Streaming segment cleanup over the real unix socket (smartness-v2 §2):
FakeBackend segment mode + a fake cleanup engine — partials per segment,
concurrent chunk cleanup, stitched finalize, retraction merge, cancel, and the
exact legacy behavior when streaming_cleanup is off."""

# ruff: noqa: F811

import asyncio
import sys
from pathlib import Path

import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — fixture reuse

import velora_engine.cleanup_process as cleanup_process_mod
import velora_engine.server as server_mod
from velora_engine.cleanup import CleanupResult
from velora_engine.cleanup_process import CleanupProcess
from velora_engine.server import _join_chunks, _numbering_restarts, _project_partial

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
        self.allowed_terms_calls: list[list[str] | None] = []
        self.recovery_events: list[str] = []

    async def defer_recovery(self):
        self.recovery_events.append("defer")

    def resume_recovery(self):
        self.recovery_events.append("resume")

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None, prefix_candidates=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        self.allowed_terms_calls.append(allowed_terms)
        if self.delay:
            await asyncio.sleep(self.delay)
        return CleanupResult(text=f"<{raw}>", applied=True, ms=7)


class RestartingListCleanup(FakeCleanup):
    """Simulate independently cleaned chunks that each start numbering at 1."""

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None, prefix_candidates=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        self.allowed_terms_calls.append(allowed_terms)
        if raw == SEG1:
            text = "1. Saving is slow.\n2. Search misses files."
        elif raw == SEG2:
            text = "1. Errors give no recovery step."
        else:
            text = (
                "1. Saving is slow.\n"
                "2. Search misses files.\n"
                "3. Errors give no recovery step."
            )
        return CleanupResult(text=text, applied=True, ms=7)


class PendingLastCleanup(FakeCleanup):
    """Keep the last live chunk pending until finalization replaces it."""

    def __init__(
        self,
        fail_merged: bool = False,
        merged_delay: float = 0.0,
    ):
        super().__init__()
        self.last_started = asyncio.Event()
        self.fail_merged = fail_merged
        self.merged_delay = merged_delay

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None, prefix_candidates=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        self.allowed_terms_calls.append(allowed_terms)
        if raw == SEG2:
            self.last_started.set()
            await asyncio.Event().wait()
        merged = f"{SEG2} {TAIL}"
        if raw == merged and self.merged_delay:
            await asyncio.sleep(self.merged_delay)
        if self.fail_merged and raw == merged:
            return CleanupResult(text=raw, applied=False, ms=7, reason="test")
        return CleanupResult(text=f"<{raw}>", applied=True, ms=7)


class FirstCallHangsCleanup(FakeCleanup):
    def __init__(self):
        super().__init__()
        self.started = asyncio.Event()
        self.call_count = 0

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None, prefix_candidates=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        self.allowed_terms_calls.append(allowed_terms)
        self.call_count += 1
        if self.call_count == 1:
            self.started.set()
            await asyncio.Event().wait()
        return CleanupResult(text=f"<{raw}>", applied=True, ms=7)


class HardTimeoutThenRecoveringCleanup(FakeCleanup):
    """A streaming request poisons the worker; replacement never becomes ready."""

    def __init__(self):
        super().__init__()
        self.timed_out = asyncio.Event()
        self.is_finalizing = lambda: None
        self.resume_finalizing_states: list[bool | None] = []

    async def cleanup(
        self, raw, system_prompt, timeout_ms=None, check_ratio=True,
        cancel_event=None, allowed_terms=None, prefix_candidates=None,
    ):
        self.calls.append((raw, system_prompt))
        self.cancel_events.append(cancel_event)
        self.allowed_terms_calls.append(allowed_terms)
        if not self.timed_out.is_set():
            self.loaded = False
            self.timed_out.set()
            return CleanupResult(
                text=raw, applied=False, ms=1_500, reason="timeout_hard"
            )
        return CleanupResult(
            text=raw, applied=False, ms=0, reason="llm_recovering"
        )

    def resume_recovery(self):
        super().resume_recovery()
        self.resume_finalizing_states.append(self.is_finalizing())


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
    # Raw words appear immediately; each completed cleanup then replaces only
    # the stable prefix while the unconfirmed tail remains visible.
    while not partials or partials[-1] != f"<{SEG1}> <{SEG2}>":
        evt = await client.recv(timeout=5)
        if evt.get("event") == "partial":
            partials.append(evt["text"])
    assert partials == [
        SEG1,
        f"<{SEG1}>",
        f"<{SEG1}> {SEG2}",
        f"<{SEG1}> <{SEG2}>",
    ]
    assert eng.session is not None
    await client.send_json({"cmd": "stop", "session": "st1"})

    # transcript still fires FIRST, with the full raw text
    transcript = await client.recv_event("transcript")
    assert transcript["raw"] == f"{SEG1} {SEG2} {TAIL}"

    final = await client.recv_event("final")
    assert final["cleanup_applied"] is True
    assert final["cleanup_ms"] == 7  # the tail chunk's ms, not the sum
    assert final["cleanup_recovery_pending"] is False
    assert final["cleanup_recovery_wait_ms"] == 0
    assert final["text"] == f"<{SEG1}> <{SEG2}> <{TAIL}>."
    assert final["raw"] == f"{SEG1} {SEG2} {TAIL}"

    # three chunk cleanups: seg1, seg2, tail — seg2 and tail carry seam context
    assert [c[0] for c in cleanup.calls] == [SEG1, SEG2, TAIL]
    assert "Previous text (context only" not in cleanup.calls[0][1]
    assert f"<{SEG1}>" in cleanup.calls[1][1]
    assert "Previous text (context only, do NOT repeat it)" in cleanup.calls[1][1]
    assert f"<{SEG2}>" in cleanup.calls[2][1]
    assert cleanup.recovery_events == ["defer", "resume"]
    client.close()


async def test_mid_session_cleanup_timeout_falls_back_before_recovery(
    engine,
    segments,
):
    eng, sock = engine
    cleanup = HardTimeoutThenRecoveringCleanup()
    cleanup.is_finalizing = lambda: eng._finalizing
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "recover-final", "context": {}})
    for _ in range(2):  # close the first fake streaming segment
        await client.send_audio(AUDIO)
    await asyncio.wait_for(cleanup.timed_out.wait(), 1)
    await client.send_json({"cmd": "stop", "session": "recover-final"})

    transcript = await client.recv_event("transcript")
    assert transcript["raw"]
    final = await client.recv_event("final", timeout=2)
    assert final["cleanup_applied"] is False
    assert final["text"] == f"{transcript['raw']}."
    assert final["total_ms"] < 1_000
    assert final["cleanup_recovery_pending"] is True
    assert final["cleanup_recovery_wait_ms"] == 0
    assert cleanup.loaded is False
    assert cleanup.recovery_events == ["defer", "resume"]
    assert cleanup.resume_finalizing_states == [False]
    client.close()


async def test_real_cleanup_timeout_finalizes_then_recovers_for_next_session(
    engine,
    monkeypatch,
):
    hanging = "__hang__ alpha one two three four five six"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", hanging)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)
    monkeypatch.setattr(cleanup_process_mod, "adaptive_timeout_ms", lambda _raw: 50)
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        worker_command=[
            sys.executable,
            str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
        ],
        hard_timeout_grace_s=0.05,
        queue_timeout_s=0.2,
        cancel_grace_s=0.1,
        on_unhealthy=eng._queue_cleanup_unhealthy_restart,
    )
    await cleanup.load_async("warm prompt")
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "real-timeout", "context": {}})
        for _ in range(2):
            await client.send_audio(AUDIO)
        for _ in range(200):
            if not cleanup.loaded:
                break
            await asyncio.sleep(0.005)
        assert cleanup.loaded is False

        await client.send_json({"cmd": "stop", "session": "real-timeout"})
        transcript = await client.recv_event("transcript")
        final = await client.recv_event("final", timeout=2)
        assert final["text"] == f"{transcript['raw']}."
        assert final["cleanup_applied"] is False
        assert final["cleanup_recovery_pending"] is True
        assert final["cleanup_recovery_wait_ms"] == 0
        assert final["total_ms"] < 1_000

        for _ in range(400):
            if cleanup.loaded:
                break
            await asyncio.sleep(0.005)
        assert cleanup.loaded is True

        monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", SEG1)
        await client.send_json({"cmd": "start", "session": "after-recovery", "context": {}})
        for _ in range(2):
            await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "after-recovery"})
        recovered = await client.recv_event("final")
        assert recovered["cleanup_applied"] is True
        assert SEG1.upper() in recovered["text"]
    finally:
        client.close()
        await cleanup.aclose()
        eng.cleanup = None


async def test_final_tail_replaces_only_unfinished_last_chunk(engine, segments):
    eng, sock = engine
    cleanup = PendingLastCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "tail-priority", "context": {}})
    for _ in range(4):
        await client.send_audio(AUDIO)
    await asyncio.wait_for(cleanup.last_started.wait(), 1)
    await client.send_json({"cmd": "stop", "session": "tail-priority"})
    final = await client.recv_event("final")

    merged = f"{SEG2} {TAIL}"
    assert [raw for raw, _prompt in cleanup.calls] == [SEG1, SEG2, merged]
    assert final["text"] == f"<{SEG1}> <{merged}>."
    assert final["cleanup_applied"] is True
    assert cleanup.cancel_events[1] is not None
    assert cleanup.cancel_events[1].is_set()
    assert f"<{SEG1}>" in cleanup.calls[-1][1]
    client.close()


async def test_priority_tail_uses_its_own_generation_budget(
    engine,
    segments,
    monkeypatch,
):
    monkeypatch.setattr(server_mod, "STREAM_GATHER_TIMEOUT_S", 0.02)
    eng, sock = engine
    cleanup = PendingLastCleanup(merged_delay=0.08)
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "tail-budget", "context": {}})
    for _ in range(4):
        await client.send_audio(AUDIO)
    await asyncio.wait_for(cleanup.last_started.wait(), 1)
    await client.send_json({"cmd": "stop", "session": "tail-budget"})
    final = await client.recv_event("final")

    merged = f"{SEG2} {TAIL}"
    assert [raw for raw, _prompt in cleanup.calls] == [SEG1, SEG2, merged]
    assert final["text"] == f"<{SEG1}> <{merged}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_unapplied_priority_tail_uses_whole_text_fallback(engine, segments):
    eng, sock = engine
    cleanup = PendingLastCleanup(fail_merged=True)
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "tail-fallback", "context": {}})
    for _ in range(4):
        await client.send_audio(AUDIO)
    await asyncio.wait_for(cleanup.last_started.wait(), 1)
    await client.send_json({"cmd": "stop", "session": "tail-fallback"})
    final = await client.recv_event("final")

    raw = f"{SEG1} {SEG2} {TAIL}"
    assert [call[0] for call in cleanup.calls][-1] == raw
    assert final["text"] == f"<{raw}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_final_tail_cancel_then_merge_keeps_real_worker_warm(
    engine,
    monkeypatch,
):
    hanging = "__cancel__"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{hanging}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        worker_command=[
            sys.executable,
            str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
        ],
        queue_timeout_s=0.2,
        cancel_grace_s=0.2,
    )
    await cleanup.load_async("warm prompt")
    original_pid = cleanup.pid
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "real-tail-priority", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        # First chunk completes immediately; the fixture holds the second until
        # it receives the production protocol's cooperative cancel.
        for _ in range(100):
            if cleanup._pending:
                await asyncio.sleep(0.03)
                if cleanup._pending:
                    break
            await asyncio.sleep(0.01)

        await client.send_json({"cmd": "stop", "session": "real-tail-priority"})
        final = await client.recv_event("final")

        assert final["cleanup_applied"] is True
        assert SEG1.upper() in final["text"]
        assert f"{hanging} {TAIL}".upper() in final["text"]
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        client.close()
        await cleanup.aclose()
        eng.cleanup = None


async def test_romanize_fallback_waits_for_real_chunk_cancellation(
    engine,
    monkeypatch,
):
    hanging = "__cancel__"
    tail = (
        "यह अंतिम लंबा हिस्सा है और इसे रोमन में आना चाहिए क्योंकि पूरी "
        "बात को एक साथ समझना जरूरी है"
    )
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{hanging}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    cleanup = CleanupProcess(
        "fake",
        worker_command=[
            sys.executable,
            str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
        ],
        queue_timeout_s=0.2,
        cancel_grace_s=0.2,
    )
    await cleanup.load_async("warm prompt")
    original_pid = cleanup.pid
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "romanize-cancel", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        for _ in range(100):
            if (
                cleanup._pending
                and eng.session is not None
                and len(eng.session.chunk_raws) == 2
            ):
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and len(eng.session.chunk_raws) == 2

        await client.send_json({"cmd": "stop", "session": "romanize-cancel"})
        final = await client.recv_event("final")

        assert final["cleanup_applied"] is True
        assert SEG1.upper() in final["text"]
        assert hanging.upper() in final["text"]
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        client.close()
        await cleanup.aclose()
        eng.cleanup = None


async def test_stitch_mismatch_waits_for_real_chunk_cancellation(
    engine,
    monkeypatch,
):
    hanging = "__cancel__"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{hanging}")
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        worker_command=[
            sys.executable,
            str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
        ],
        queue_timeout_s=0.2,
        cancel_grace_s=0.2,
    )
    await cleanup.load_async("warm prompt")
    original_pid = cleanup.pid
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "stitch-cancel", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        for _ in range(100):
            if (
                cleanup._pending
                and eng.session is not None
                and len(eng.session.chunk_raws) == 2
            ):
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and len(eng.session.chunk_raws) == 2
        eng.session.chunk_raws[0] = "tampered integrity probe"

        await client.send_json({"cmd": "stop", "session": "stitch-cancel"})
        final = await client.recv_event("final")

        assert final["cleanup_applied"] is True
        assert SEG1.upper() in final["text"]
        assert hanging.upper() in final["text"]
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        client.close()
        await cleanup.aclose()
        eng.cleanup = None


async def test_stream_gather_timeout_cooperatively_cancels_before_fallback(
    engine,
    monkeypatch,
):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", SEG1)
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)
    monkeypatch.setattr(server_mod, "STREAM_GATHER_TIMEOUT_S", 0.02)
    eng, sock = engine
    cleanup = FirstCallHangsCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await client.send_json({"cmd": "start", "session": "gather-timeout", "context": {}})
    for _ in range(2):
        await client.send_audio(AUDIO)
    await asyncio.wait_for(cleanup.started.wait(), 1)
    await client.send_json({"cmd": "stop", "session": "gather-timeout"})
    final = await client.recv_event("final")

    assert final["text"] == f"<{SEG1}>."
    assert final["cleanup_applied"] is True
    assert cleanup.cancel_events[0] is not None
    assert cleanup.cancel_events[0].is_set()
    assert [call[0] for call in cleanup.calls] == [SEG1, SEG1]
    client.close()


def test_join_chunks_keeps_generated_list_items_on_separate_lines():
    assert _join_chunks([
        "I found three issues:",
        "1. Saving is slow.\n2. Search misses files.",
        "3. Errors give no recovery step.",
    ]) == (
        "I found three issues:\n"
        "1. Saving is slow.\n"
        "2. Search misses files.\n"
        "3. Errors give no recovery step."
    )


def test_numbering_restart_detection_checks_model_output_without_rewriting_it():
    assert not _numbering_restarts(["1. First.\n2. Second.", "3. Third."])
    assert _numbering_restarts(["1. First.\n2. Second.", "1. Third."])
    assert _numbering_restarts(["1. First.\n2. Second.", "4. Fourth."])
    assert _numbering_restarts(["2. Second.", "3. Third."])


def test_smart_partial_replaces_stable_raw_prefix_with_cleaned_text():
    assert _project_partial(
        "let's meet at 3 pm no wait make that 6 pm next topic",
        ["let's meet at 3 pm no wait make that 6 pm"],
        ["Let's meet at 6 p.m."],
    ) == "Let's meet at 6 p.m. next topic"


def test_smart_partial_keeps_raw_when_chunk_mapping_is_not_exact():
    raw = "a newly decoded hypothesis"
    assert _project_partial(raw, ["different segment"], ["Clean."]) == raw


def test_smart_partial_uses_only_contiguous_completed_chunks():
    assert _project_partial(
        f"{SEG1} {SEG2} {TAIL}",
        [SEG1, SEG2],
        ["Clean alpha."],
    ) == f"Clean alpha. {SEG2} {TAIL}"


async def test_streaming_numbering_restart_falls_back_to_whole_text(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)
    eng, sock = engine
    cleanup = RestartingListCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(
        client,
        "streaming-list-restart",
        chunks=4,
        context={"bundle_id": "com.apple.Terminal", "app_name": "Terminal"},
    )
    final = await client.recv_event("final")
    raw = f"{SEG1} {SEG2}"

    assert [call[0] for call in cleanup.calls] == [SEG1, SEG2, raw]
    assert "continue with the next number; never restart at 1" in cleanup.calls[1][1]
    assert final["text"] == (
        "1. Saving is slow.\n"
        "2. Search misses files.\n"
        "3. Errors give no recovery step."
    )
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


async def test_romanize_enabled_keeps_latin_long_session_streaming(engine, segments):
    """The Romanize preference applies only to non-Latin speech. English must
    keep the during-recording cleanup path instead of paying one whole-text
    generation after stop."""
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "romanize-latin", chunks=4)
    final = await client.recv_event("final")

    assert [call[0] for call in cleanup.calls] == [SEG1, SEG2, TAIL]
    assert final["text"] == f"<{SEG1}> <{SEG2}> <{TAIL}>."
    assert final["cleanup_applied"] is True
    client.close()


async def test_romanize_enabled_non_latin_uses_whole_text_path(engine, monkeypatch):
    segment = "यह पहली समस्या है और इसे पूरा रखना है"
    tail = "यह दूसरा वाक्य है"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", segment)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "romanize-non-latin", chunks=2)
    final = await client.recv_event("final")
    raw = f"{segment} {tail}"

    assert [call[0] for call in cleanup.calls] == [raw]
    assert final["text"] == f"<{raw}>"
    assert final["cleanup_applied"] is True
    client.close()


async def test_romanize_latin_segment_with_non_latin_tail_uses_whole_text(engine, monkeypatch):
    tail = (
        "यह दूसरी समस्या है और इसे पूरा रखना है क्योंकि यह अंतिम लंबा हिस्सा है "
        "और इसे रोमन में आना चाहिए"
    )
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", SEG1)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine
    eng.config.data["romanize_output"] = True
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "romanize-mixed-tail", chunks=2)
    final = await client.recv_event("final")
    raw = f"{SEG1} {tail}"

    # The Latin segment may be pre-cleaned during speech, but the unseen Hindi
    # tail must make finalize discard that assembly and romanize the FULL raw.
    assert [call[0] for call in cleanup.calls] == [SEG1, raw]
    assert final["text"] == f"<{raw}>"
    assert final["cleanup_applied"] is True
    client.close()


async def test_native_script_tail_uses_whole_text_multilingual_cleanup(engine, monkeypatch):
    tail = (
        "यह दूसरी समस्या है और इसे पूरा रखना है क्योंकि यह अंतिम लंबा हिस्सा है "
        "और इसकी भाषा तथा सूची की संरचना नहीं बदलनी चाहिए"
    )
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", SEG1)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    eng, sock = engine
    eng.config.data["romanize_output"] = False
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")

    await run_dictation(client, "native-script-tail", chunks=2)
    final = await client.recv_event("final")
    raw = f"{SEG1} {tail}"

    assert [call[0] for call in cleanup.calls] == [SEG1, raw]
    assert final["text"] == f"<{raw}>"
    assert final["cleanup_applied"] is True
    client.close()


async def test_cleanup_allows_only_global_and_active_mode_vocabulary(engine, segments):
    eng, sock = engine
    eng.config.data["vocabulary"] = ["GlobalTerm"]
    eng.config.modes["code"].vocabulary = ["ModeOnlyTerm"]
    eng.config.modes["note"].vocabulary = ["InactiveTerm"]
    cleanup = FakeCleanup()
    eng.cleanup = cleanup

    await eng._apply_formatting(  # noqa: SLF001 — verify the whole-text boundary
        "one two three four five six seven", None, None, "Code", [])
    assert cleanup.allowed_terms_calls[-1] == ["GlobalTerm", "ModeOnlyTerm"]

    await eng._apply_formatting(
        "one two three four five six seven", None, None, None, [])
    assert cleanup.allowed_terms_calls[-1] == ["GlobalTerm"]
    assert "InactiveTerm" not in cleanup.allowed_terms_calls[-1]

    client = await connect(sock)
    await client.recv_event("ready")
    await run_dictation(client, "active-mode-vocab", chunks=4, context={"mode": "Code"})
    await client.recv_event("final")
    assert cleanup.allowed_terms_calls
    assert all(
        terms == ["GlobalTerm", "ModeOnlyTerm"]
        for terms in cleanup.allowed_terms_calls[-2:]
    )
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


async def test_retraction_merge_waits_for_real_worker_cancellation(
    engine,
    monkeypatch,
):
    hanging = "__cancel__"
    correction = "no wait make that six pm on monday"
    monkeypatch.setenv(
        "VELORA_FAKE_STT_SEGMENTS",
        f"{hanging}|{correction}",
    )
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)
    eng, sock = engine
    cleanup = CleanupProcess(
        "fake",
        worker_command=[
            sys.executable,
            str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
        ],
        queue_timeout_s=0.2,
        cancel_grace_s=0.2,
    )
    await cleanup.load_async("warm prompt")
    original_pid = cleanup.pid
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await run_dictation(client, "real-retraction-cancel", chunks=4)
        final = await client.recv_event("final")

        merged = f"{hanging} {correction}"
        assert merged.upper() in final["text"]
        assert final["cleanup_applied"] is True
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        client.close()
        await cleanup.aclose()
        eng.cleanup = None


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


async def test_chunk_llm_receives_converted_breaks(engine, monkeypatch):
    # The original regression: chunks reached the model RAW, literal "new
    # line" words included. They must arrive converted, with breaks as the
    # ⏎ transport marker, and decode back to a real newline in the final.
    seg = "alpha item speed new line beta item privacy stays here"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", seg)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", TAIL)
    eng, sock = engine
    cleanup = FakeCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    await run_dictation(client, "brk")
    await client.recv_event("transcript")
    final = await client.recv_event("final")
    sent = cleanup.calls[0][0]
    assert "new line" not in sent.lower()
    assert "⏎" in sent
    assert "\n" in final["text"]
    client.close()
