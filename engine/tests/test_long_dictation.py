"""Long dictation stays one lossless, progressively cleaned final result."""

# ruff: noqa: F811 — imported pytest fixture shares its argument name

import asyncio
import contextlib
import re
import threading
import time
from unittest.mock import AsyncMock

import numpy as np
import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — isolated fake-STT fixture
from test_server_streaming import SEG1, SEG2
from velora_engine.cleanup import CleanupResult, TIMEOUT_CEILING_MS
from velora_engine.server import (
    CLEANUP_PIECE_WORDS, CLEANUP_SINGLE_CALL_UNITS, Session,
    _cleanup_units, _split_cleanup_pieces,
)


def words(count: int) -> str:
    return " ".join(f"word{index:04d}" for index in range(count))


def test_space_joined_cjk_is_bounded():
    raw = " ".join(["这是一个需要完整保留的长段落" * 20] * 30)
    pieces = _split_cleanup_pieces(raw)
    assert len(pieces) > 30
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert "".join(pieces).replace(" ", "") == raw.replace(" ", "")


def test_mixed_script_tokens_count_all_characters():
    raw = " ".join(["中文" + "a" * 100] * 30)
    pieces = _split_cleanup_pieces(raw)
    assert _cleanup_units(raw) > CLEANUP_SINGLE_CALL_UNITS
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert "".join(pieces).replace(" ", "") == raw.replace(" ", "")


def test_single_token_is_intact():
    for token in [
        "https://example.com/" + "日本語" * 80,
        "/Users/example/" + "资料" * 80,
        "name@" + "例子" * 80 + ".com",
        "a" * 200,
    ]:
        assert _split_cleanup_pieces(token) == [token]


def test_sentence_boundary_precedes_word_limit():
    raw = words(59) + " end. " + words(100)
    pieces = _split_cleanup_pieces(raw)
    assert pieces[0].endswith("end.")
    assert " ".join(pieces).split() == raw.split()
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS


def test_retraction_marker_and_target_share_piece():
    raw = words(CLEANUP_PIECE_WORDS - 8) \
        + ". target sentence scratch that " + words(40)
    pieces = _split_cleanup_pieces(raw)
    assert any(part.startswith("target sentence scratch that") for part in pieces)
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert " ".join(pieces).split() == raw.split()


def test_scratch_all_seam_sees_entire_previous_piece():
    previous = " ".join(f"old{index:04d}" for index in range(CLEANUP_PIECE_WORDS - 10))
    raw = previous + ". keep this sentence scratch all " + words(30)
    pieces = _split_cleanup_pieces(raw)
    assert pieces[0].startswith("old0000")
    assert pieces[0].endswith("old0064.")
    assert pieces[1].startswith("keep this sentence scratch all")
    assert max(map(_cleanup_units, pieces)) <= CLEANUP_PIECE_WORDS
    assert " ".join(pieces).split() == raw.split()


def test_second_retraction_at_seam_is_not_hidden_by_first():
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


async def test_long_formatting_cleans_every_piece(engine, monkeypatch):
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


async def test_short_formatting_keeps_one_prompt(engine):
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


async def test_streaming_prompt_keeps_shipped_context(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    session = Session("stream-context", {})
    session.stream_prompt = "Original prompt"
    await eng._clean_chunk_text(session, "next word", words(50))
    prompt = cleanup.calls[0][1]
    assert "word0035" in prompt and "word0049" in prompt
    assert "word0034" not in prompt
    assert "greeting or sign-off" not in prompt
    assert "Preserve its tone" not in prompt


async def test_hour_scale_text_has_no_total_cleanup_cap(engine):
    eng, _ = engine
    cleanup = BudgetCleanup()
    eng.cleanup = cleanup
    raw = words(9000)
    text, _, _, applied, _ = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) == 9000 // CLEANUP_PIECE_WORDS
    assert_words_once(text, 9000)


async def test_email_mode_keeps_one_prompt(engine):
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


async def test_email_variants_do_not_repeat_envelope(engine):
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


async def test_cancel_stops_between_pieces(engine):
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


async def test_cancel_wait_is_bounded_when_chunk_ignores_cancel(engine, monkeypatch):
    import velora_engine.server as server

    monkeypatch.setattr(server, "FINALIZE_CANCEL_UNWIND_S", 0.01)
    eng, _ = engine
    session = Session("slow-cancel", {})
    release = asyncio.Event()

    async def stubborn_chunk():
        try:
            await release.wait()
        except asyncio.CancelledError:
            await release.wait()
        return None

    task = asyncio.create_task(stubborn_chunk())
    session.chunk_tasks.append(task)
    await asyncio.sleep(0)
    try:
        await asyncio.wait_for(eng._cancel_chunk_tasks_and_wait(session), 0.1)
        assert not task.done()
    finally:
        release.set()
        with contextlib.suppress(asyncio.CancelledError):
            await task


async def test_piece_head_retraction_merges_previous(engine):
    eng, _ = engine
    cleanup = BudgetCleanup(limit=CLEANUP_PIECE_WORDS)
    eng.cleanup = cleanup
    first = " ".join(f"first{index:04d}" for index in range(65))
    raw = first + ". target phrase no wait " + words(90)
    await eng._apply_formatting(raw, None, None, None)
    assert any(call[0].startswith("target phrase no wait") for call in cleanup.calls)
    assert all(_cleanup_units(call[0]) <= CLEANUP_PIECE_WORDS for call in cleanup.calls)


async def test_numbered_list_continues_across_seam(engine):
    eng, _ = engine

    class ListCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            return CleanupResult(f"1. {raw}", result.applied, result.ms)

    cleanup = ListCleanup()
    eng.cleanup = cleanup
    text, _, _, applied, _ = await eng._apply_formatting(words(150), None, None, None)
    assert applied
    assert "\n1. " in text
    assert "\n2. " not in text
    assert "never restart at 1" in cleanup.calls[1][1]


async def test_one_failed_piece_preserves_all_others(engine):
    eng, _ = engine

    class OneFailure(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            if len(self.calls) == 2:
                return CleanupResult(raw, False, 7, "timeout")
            return result

    cleanup = OneFailure()
    eng.cleanup = cleanup
    count = CLEANUP_PIECE_WORDS * 3 - 1
    text, _, _, applied, reason = await eng._apply_formatting(words(count), None, None, None)
    assert not applied
    assert reason == "partial_cleanup"
    assert len(cleanup.calls) == 3
    assert text.count("<") == 2
    assert_words_once(text, count)


async def test_no_cleaned_pieces_reports_unavailable(engine):
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


async def test_context_length_failure_retries_piece_without_context(engine):
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


async def test_cleanup_progress_after_each_piece(engine):
    eng, _ = engine
    eng.cleanup = BudgetCleanup()
    eng._send = AsyncMock()
    session = Session("progress", {})
    count = CLEANUP_PIECE_WORDS * 3 - 1
    await eng._apply_formatting(words(count), None, None, None, session=session)
    events = [call.args[0] for call in eng._send.await_args_list]
    assert [event["completed"] for event in events] == [1, 2, 3]
    assert all(event["event"] == "finalize_progress" for event in events)


async def test_filler_gate_preserves_words_across_pieces(engine):
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


async def test_stt_progress_precedes_cleanup(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", words(30))
    eng, sock = engine
    eng.cleanup = BudgetCleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "stt-progress", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "stt-progress"})
        await client.recv_event("transcript")
        stt = await client.recv_event("finalize_progress")
        cleanup = await client.recv_event("finalize_progress")
        final = await client.recv_event("final")
        assert stt["stage"] == "stt"
        assert cleanup["stage"] == "cleanup"
        assert final["cleanup_applied"]
    finally:
        client.close()


async def test_priority_merged_tail_falls_back_to_pieces(engine, monkeypatch):
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
        assert any(len(raw.split()) > cleanup.limit for raw, _, _ in cleanup.calls)
        assert sum(raw == SEG1 for raw, _, _ in cleanup.calls) == 1
        assert SEG1 in final["text"]
        assert SEG2 in final["text"]
        assert all(f"word{index:04d}" in final["text"] for index in range(550))
    finally:
        client.close()


async def test_long_romanize_scales_per_piece(engine):
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


async def test_unspaced_native_script_has_bounded_pieces(engine):
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


async def test_single_native_call_scales_timeout(engine):
    eng, _ = engine
    eng.config.data["romanize_output"] = False
    cleanup = BudgetCleanup(limit=CLEANUP_SINGLE_CALL_UNITS)
    eng.cleanup = cleanup
    raw = "中" * (CLEANUP_SINGLE_CALL_UNITS - 5)
    _, _, _, applied, reason = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert reason != "chunked"
    assert len(cleanup.calls) == 1
    assert cleanup.calls[0][2]["timeout_ms"] > TIMEOUT_CEILING_MS / 2


async def test_space_joined_native_script_keeps_every_character(engine):
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


async def test_single_call_budget_keeps_prompt_and_reason(engine):
    eng, _ = engine
    cleanup = BudgetCleanup(limit=130)
    eng.cleanup = cleanup
    raw = words(120)
    text, _, _, applied, reason = await eng._apply_formatting(raw, None, None, None)
    assert applied
    assert len(cleanup.calls) == 1
    assert reason != "chunked"
    assert_words_once(text, 120)


async def test_file_piece_resume_keeps_completed_work(engine):
    eng, _ = engine
    cancel = threading.Event()
    completed = []

    class PreemptingCleanup(BudgetCleanup):
        async def cleanup(self, raw, prompt, **kwargs):
            result = await super().cleanup(raw, prompt, **kwargs)
            if len(self.calls) == 1:
                cancel.set()
            return result

    cleanup = PreemptingCleanup()
    eng.cleanup = cleanup
    raw = words(220)
    await eng._apply_formatting(
        raw, None, "Local file", None, cancel_event=cancel,
        resume_parts=completed)
    assert len(completed) == 1
    cancel.clear()
    text, _, _, applied, _ = await eng._apply_formatting(
        raw, None, "Local file", None, cancel_event=cancel,
        resume_parts=completed)
    assert applied
    assert len(cleanup.calls) == 3
    assert_words_once(text, 220)


async def test_worker_recovers_between_pieces(engine):
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


async def test_wedged_warmup_queue_zero_only_hits_first_piece(engine):
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


async def test_pretranscript_abandon_keeps_audio_and_mode(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "spoken words")
    eng, sock = engine
    eng.config.data["audio_max_mb"] = 0.000001
    eng.config.data["save_audio"] = True
    original_finalize = eng.stt.finalize

    def slow_finalize():
        time.sleep(0.2)
        return original_finalize()

    eng.stt.finalize = slow_finalize
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({
            "cmd": "start", "session": "abandon-before-stt",
            "context": {"mode": "Email"},
        })
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "abandon-before-stt"})
        await client.send_json({"cmd": "abandon_finalize", "session": "abandon-before-stt"})
        final = await client.recv_event("final")
        assert final["text"] == ""
        assert final["mode"] == "Email"
        assert final["audio"] == eng.audio.name_for("abandon-before-stt")
        assert final["reason"] == "finalize_stalled"
        assert not eng._finalizing
        assert await eng._final_archives["abandon-before-stt"]
        assert eng.audio.path_for(final["audio"]).exists()
        recovered = await client.recv_event("finalize_recovered")
        assert recovered["raw"] == "spoken words"
        assert recovered["text"]
    finally:
        client.close()


async def test_abandon_uses_live_retention_setting(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "late words")
    eng, sock = engine
    eng.config.data["save_audio"] = True
    started = threading.Event()
    release = threading.Event()
    original_finalize = eng.stt.finalize

    def waiting_finalize():
        started.set()
        release.wait(5)
        return original_finalize()

    eng.stt.finalize = waiting_finalize
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "privacy-change", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "privacy-change"})
        await client.recv_event("finalize_started")
        assert await asyncio.to_thread(started.wait, 2)
        eng.config.data["save_audio"] = False
        await client.send_json({"cmd": "abandon_finalize", "session": "privacy-change"})
        final = await client.recv_event("final")
        assert final.get("audio") is None
        release.set()
        recovered = await client.recv_event("finalize_recovered")
        assert recovered["text"] == "Late words."
        for _ in range(100):
            if not (eng.audio.active_dir / "privacy-change.pcm16.part").exists():
                break
            await asyncio.sleep(0.01)
        assert not (eng.audio.active_dir / "privacy-change.pcm16.part").exists()
        assert not (eng.config.audio_dir / eng.audio.name_for("privacy-change")).exists()
    finally:
        release.set()
        client.close()


async def test_stale_abandon_is_silent(engine):
    _, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "abandon_finalize", "session": "old"})
        await client.send_json({"cmd": "ping"})
        assert (await client.recv())["event"] == "pong"
    finally:
        client.close()


def test_formatting_off_stall_uses_exact_gate_text(engine):
    from velora_engine import formatting

    eng, _ = engine
    session = Session("raw-gate", {"mode": "Raw"})
    raw = "um literal new line words"
    gate = formatting.run_gate(raw, eng.config, explicit_mode="Raw")
    assert not gate.use_llm
    text, mode = eng._fallback_final_text(session, raw)
    assert text == gate.text
    assert mode == gate.mode.name


async def test_reuse_applied_chunks_after_gap(engine):
    eng, _ = engine
    eng.cleanup = BudgetCleanup()
    session = Session("gap", {})
    session.chunk_raws = [SEG1, SEG2, "third segment with more words here now"]
    eng.stt.segments_used_for_final = True
    eng.stt.final_tail = ""

    async def finished(text, applied):
        return _ChunkResult(text, 7, applied)

    cancelled = asyncio.Event()

    async def pending():
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    from velora_engine.server import _ChunkResult
    session.chunk_tasks = [
        asyncio.create_task(finished(f"<{session.chunk_raws[0]}>", True)),
        asyncio.create_task(pending()),
        asyncio.create_task(finished(f"<{session.chunk_raws[2]}>", True)),
    ]
    await asyncio.sleep(0)
    result = await eng._reuse_streaming_prefix(session, " ".join(session.chunk_raws))
    assert result is not None
    assert cancelled.is_set()
    assert [call[0] for call in eng.cleanup.calls] == [SEG2]
    assert result[0].count(SEG1) == 1
    assert result[0].count(session.chunk_raws[2]) == 1


async def test_cleanup_abandon_keeps_deterministic_text(engine, monkeypatch):
    raw = "um hello new line world " + words(50)
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", raw)
    eng, sock = engine
    eng.config.data["save_audio"] = True

    class WedgedCleanup(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.started = asyncio.Event()

        async def cleanup(self, raw, prompt, **kwargs):
            self.started.set()
            await asyncio.Event().wait()

    cleanup = WedgedCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "abandon-cleanup", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "abandon-cleanup"})
        await client.recv_event("transcript")
        await asyncio.wait_for(cleanup.started.wait(), 2)
        await client.send_json({"cmd": "abandon_finalize", "session": "abandon-cleanup"})
        final = await client.recv_event("final")
        assert "um" not in final["text"]
        assert "\n" in final["text"]
        assert final["raw"] == raw
        assert final["audio"] == eng.audio.name_for("abandon-cleanup")
        assert not final["cleanup_applied"]
        assert final["reason"] == "finalize_stalled"
        assert not eng._finalizing
        eng.cleanup = BudgetCleanup()
        await client.send_json({
            "cmd": "edit_text", "id": "after-abandon",
            "text": "draft text", "instruction": "fix grammar",
        })
        edited = await client.recv_event("edited")
        assert edited["id"] == "after-abandon"
    finally:
        client.close()


async def test_wedged_stt_has_no_timer_progress(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "heartbeat transcript")
    eng, sock = engine
    original_finalize = eng.stt.finalize
    started = threading.Event()
    release = threading.Event()

    def slow_finalize():
        started.set()
        release.wait(5)
        return original_finalize()

    eng.stt.finalize = slow_finalize
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "heartbeat", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "heartbeat"})
        assert await asyncio.to_thread(started.wait, 2)
        first = await client.recv_event("finalize_progress")
        assert first["stage"] == "stt"
        with pytest.raises(asyncio.TimeoutError):
            await client.recv_event("finalize_progress", timeout=0.05)
        release.set()
        progress = await client.recv_event("finalize_progress")
        assert progress["stage"] == "stt"
        assert progress["completed"] == 1
        await client.recv_event("final")
    finally:
        release.set()
        client.close()


async def test_drain_wait_has_no_timer_progress(engine, monkeypatch):
    eng, sock = engine
    original_drain = eng._drain_feeder
    started = asyncio.Event()
    release = asyncio.Event()

    async def slow_drain(session):
        started.set()
        await release.wait()
        await original_drain(session)

    eng._drain_feeder = slow_drain
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "drain-heartbeat", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "drain-heartbeat"})
        await asyncio.wait_for(started.wait(), 2)
        first = await client.recv_event("finalize_progress")
        assert first["stage"] == "stt"
        with pytest.raises(asyncio.TimeoutError):
            await client.recv_event("finalize_progress", timeout=0.05)
        release.set()
        progress = await client.recv_event("finalize_progress")
        assert progress["stage"] == "stt" and progress["completed"] == 1
        await client.recv_event("final")
    finally:
        release.set()
        client.close()


@pytest.mark.parametrize("source", ["archive", "ephemeral", "ram_spill", "append_failed"])
async def test_backlog_feeds_every_frame_live(engine, monkeypatch, source):
    import velora_engine.server as server

    eng, sock = engine
    eng.config.data["cleanup_enabled"] = False
    monkeypatch.setattr(server, "QUEUE_MAX_FRAMES", 3)
    started = threading.Event()
    release = threading.Event()
    seen = []

    def feed(chunk):
        started.set()
        release.wait(5)
        seen.extend(round(float(chunk[index]) * 1000)
                    for index in range(0, len(chunk), 1600))

    monkeypatch.setattr(eng.stt, "feed_chunk", feed)
    monkeypatch.setattr(eng.stt, "finalize", lambda: " ".join(map(str, seen)))
    if source != "archive" and source != "append_failed":
        eng.config.data["save_audio"] = False
    if source == "ram_spill":
        monkeypatch.setattr(server, "BACKLOG_RAM_BYTES", 1600 * 2)
        monkeypatch.setattr(eng, "_new_temp_spool", lambda: None)
    if source == "append_failed":
        original = eng.audio.begin_active

        def failing_spool(session_id):
            spool = original(session_id)
            append = spool.append
            calls = 0

            def fail_later(chunk):
                nonlocal calls
                calls += 1
                if calls <= 7:
                    return append(chunk)
                if calls == 8:
                    spool._handle.write(b"\x01\x00" * (len(chunk) // 2))
                return False

            spool.append = fail_later
            return spool

        monkeypatch.setattr(eng.audio, "begin_active", failing_spool)

    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "backlog", "context": {}})
        await client.send_audio(np.full(1600, 0.001, dtype=np.float32))
        assert await asyncio.to_thread(started.wait, 2)
        session = eng.session
        assert session is not None
        for index in range(2, 21):
            await client.send_audio(np.full(1600, index / 1000, dtype=np.float32))
        for _ in range(200):
            if session.samples == 20 * 1600 and session.backlog_cursor is not None:
                break
            await asyncio.sleep(0.01)
        assert session.backlog_cursor is not None
        release.set()
        for _ in range(200):
            if session.backlog_cursor == session.samples:
                break
            await asyncio.sleep(0.01)
        assert session.backlog_cursor == session.samples
        if source == "ram_spill":
            assert session.backlog_file is not None
            assert session.backlog_file.stat().st_mode & 0o777 == 0o600
        await client.send_json({"cmd": "stop", "session": "backlog"})
        progress = await client.recv_event("finalize_progress")
        assert progress["stage"] == "catchup"
        assert progress["completed"] > 0
        final = await client.recv_event("final")
        assert final["raw"].split() == list(map(str, range(1, 21)))
        assert session.backlog_file is None
        if source in {"ephemeral", "ram_spill"}:
            assert "audio" not in final
    finally:
        release.set()
        client.close()


async def test_failed_catchup_redecodes_preserved_clip(engine, monkeypatch):
    import velora_engine.server as server

    eng, sock = engine
    eng.config.data["cleanup_enabled"] = False
    monkeypatch.setattr(server, "QUEUE_MAX_FRAMES", 2)
    started = threading.Event()
    release = threading.Event()
    failed = False
    seen = []
    original_start = eng.stt.start_session

    def start():
        seen.clear()
        original_start()

    def feed(chunk):
        nonlocal failed
        started.set()
        release.wait(5)
        if not failed and len(seen) >= 3:
            failed = True
            raise OSError("injected feed failure")
        seen.extend(round(float(chunk[index]) * 1000)
                    for index in range(0, len(chunk), 1600))

    monkeypatch.setattr(eng.stt, "start_session", start)
    monkeypatch.setattr(eng.stt, "feed_chunk", feed)
    monkeypatch.setattr(eng.stt, "finalize", lambda: " ".join(map(str, seen)))
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "failed-feed", "context": {}})
        await client.send_audio(np.full(1600, 0.001, dtype=np.float32))
        assert await asyncio.to_thread(started.wait, 2)
        for index in range(2, 11):
            await client.send_audio(np.full(1600, index / 1000, dtype=np.float32))
        await client.send_json({"cmd": "stop", "session": "failed-feed"})
        release.set()
        final = await client.recv_event("final")
        assert failed
        assert final["raw"].split() == list(map(str, range(1, 11)))
    finally:
        release.set()
        client.close()


async def test_failed_catchup_with_streaming_uses_whole_text(engine, monkeypatch):
    import velora_engine.server as server

    tail = words(60)
    raw = f"{SEG1} {SEG2} {tail}"
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", tail)
    monkeypatch.setattr(server, "QUEUE_MAX_FRAMES", 1)
    eng, sock = engine
    cleanup = BudgetCleanup(limit=CLEANUP_SINGLE_CALL_UNITS)
    eng.cleanup = cleanup
    started = threading.Event()
    release = threading.Event()
    failed = False
    calls = 0
    original_feed = eng.stt.feed_chunk

    def feed(chunk):
        nonlocal calls, failed
        calls += 1
        if calls == 1:
            started.set()
            release.wait(5)
        if calls == 4 and not failed:
            failed = True
            raise OSError("catch-up feed failure")
        return original_feed(chunk)

    eng.stt.feed_chunk = feed
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "stream-backlog", "context": {}})
        await client.send_audio(AUDIO)
        assert await asyncio.to_thread(started.wait, 2)
        for _ in range(24):
            await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "stream-backlog"})
        release.set()
        final = await client.recv_event("final")
        assert failed
        assert eng.stt.sessions == 2
        assert final["raw"] == raw
        assert [token.lower().strip("<>.") for token in final["text"].split()] == raw.split()
        assert cleanup.calls
    finally:
        release.set()
        client.close()


@pytest.mark.parametrize("abandon", [False, True])
async def test_live_retention_on_adopts_temporary_audio(engine, abandon):
    eng, sock = engine
    eng.config.data["save_audio"] = False
    eng.config.data["cleanup_enabled"] = False
    session_id = "retention-on-abandon" if abandon else "retention-on"
    started = threading.Event()
    release = threading.Event()
    original_finalize = eng.stt.finalize

    def waiting_finalize():
        started.set()
        release.wait(5)
        return original_finalize()

    if abandon:
        eng.stt.finalize = waiting_finalize
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": session_id, "context": {}})
        await client.send_audio(AUDIO)
        for _ in range(100):
            if eng.session is not None and eng.session.samples == len(AUDIO):
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and eng.session.temp_spool is not None
        temporary = eng.session.temp_spool.path
        assert temporary.stat().st_mode & 0o777 == 0o600
        eng.config.data["save_audio"] = True
        await client.send_json({"cmd": "stop", "session": session_id})
        if abandon:
            await client.recv_event("finalize_started")
            assert await asyncio.to_thread(started.wait, 2)
            await client.send_json({"cmd": "abandon_finalize", "session": session_id})
        final = await client.recv_event("final")
        assert final["audio"] == eng.audio.name_for(session_id)
        assert await eng._final_archives[session_id]
        assert not temporary.exists()
    finally:
        release.set()
        client.close()


def test_engine_start_sweeps_old_private_backlog(engine):
    from velora_engine.server import Engine

    eng, _ = engine
    directory = eng._backlog_dir()
    stale = directory / "orphan.pcm16.tmp"
    stale.write_bytes(b"private audio")
    replacement = Engine(eng.config)
    assert not stale.exists()
    assert replacement.audio.dir == eng.audio.dir


@pytest.mark.parametrize("during_catchup", [False, True])
async def test_cancel_stops_backlog_feeder(engine, monkeypatch, during_catchup):
    import velora_engine.server as server

    eng, sock = engine
    monkeypatch.setattr(server, "QUEUE_MAX_FRAMES", 2)
    first = threading.Event()
    release_first = threading.Event()
    catchup = threading.Event()
    release_catchup = threading.Event()
    calls = 0

    def feed(_chunk):
        nonlocal calls
        calls += 1
        if calls == 1:
            first.set()
            release_first.wait(5)
        if calls == 4:
            catchup.set()
            release_catchup.wait(5)

    monkeypatch.setattr(eng.stt, "feed_chunk", feed)
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "cancel-backlog", "context": {}})
        await client.send_audio(np.full(1600, 0.1, dtype=np.float32))
        assert await asyncio.to_thread(first.wait, 2)
        session = eng.session
        assert session is not None
        for _ in range(7):
            await client.send_audio(np.full(1600, 0.1, dtype=np.float32))
        await client.send_json({"cmd": "stop", "session": "cancel-backlog"})
        for _ in range(200):
            if session.backlog_cursor is not None:
                break
            await asyncio.sleep(0.01)
        assert session.backlog_cursor is not None
        if during_catchup:
            release_first.set()
            assert await asyncio.to_thread(catchup.wait, 2)
        await client.send_json({"cmd": "cancel", "session": "cancel-backlog"})
        await client.recv_event("cancelled")
        assert session.feeder is not None and session.feeder.done()
        assert not eng._finalizing
    finally:
        release_first.set()
        release_catchup.set()
        client.close()


async def test_esc_during_whole_text_pieces_unblocks_start(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", words(650))
    eng, sock = engine

    class WaitingCleanup(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.started = asyncio.Event()

        async def cleanup(self, raw, prompt, **kwargs):
            self.started.set()
            await asyncio.Event().wait()

    cleanup = WaitingCleanup()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "esc-pieces", "context": {}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "esc-pieces"})
        await asyncio.wait_for(cleanup.started.wait(), 2)
        await client.send_json({"cmd": "cancel", "session": "esc-pieces"})
        await client.recv_event("cancelled")
        await client.send_json({"cmd": "start", "session": "after-esc", "context": {}})
        for _ in range(100):
            if eng.session is not None and eng.session.id == "after-esc":
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and eng.session.id == "after-esc"
    finally:
        client.close()


async def test_esc_during_priority_tail_unblocks_start(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", words(550))
    eng, sock = engine

    class WaitingTail(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.chunk_started = asyncio.Event()
            self.priority_started = asyncio.Event()
            self.priority_cancel = None

        async def cleanup(self, raw, prompt, **kwargs):
            if raw == SEG2:
                self.chunk_started.set()
                await asyncio.Event().wait()
            if raw.startswith(SEG2):
                self.priority_cancel = kwargs.get("cancel_event")
                self.priority_started.set()
                await asyncio.Event().wait()
            return await super().cleanup(raw, prompt, **kwargs)

    cleanup = WaitingTail()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "esc-priority", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        await asyncio.wait_for(cleanup.chunk_started.wait(), 2)
        await client.send_json({"cmd": "stop", "session": "esc-priority"})
        await asyncio.wait_for(cleanup.priority_started.wait(), 2)
        await client.send_json({"cmd": "cancel", "session": "esc-priority"})
        await client.recv_event("cancelled")
        assert cleanup.priority_cancel is not None
        assert cleanup.priority_cancel.is_set()
        await client.send_json({"cmd": "start", "session": "after-priority", "context": {}})
        for _ in range(100):
            if eng.session is not None and eng.session.id == "after-priority":
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and eng.session.id == "after-priority"
    finally:
        client.close()


async def test_esc_unblocks_stubborn_finalize(engine, monkeypatch):
    import velora_engine.server as server

    monkeypatch.setattr(server, "FINALIZE_CANCEL_UNWIND_S", 0.01)
    eng, sock = engine
    old = Session("old-final", {})
    release = asyncio.Event()

    async def stubborn_finalize():
        try:
            await release.wait()
        except asyncio.CancelledError:
            await release.wait()

    task = asyncio.create_task(stubborn_finalize())
    eng._finalizing = True
    eng._finalizing_session = old
    eng._finalizing_session_id = old.id
    eng._finalize_task = task
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "cancel", "session": old.id})
        await client.recv_event("cancelled")
        await client.send_json({"cmd": "start", "session": "after-stubborn-esc", "context": {}})
        for _ in range(100):
            if eng.session is not None and eng.session.id == "after-stubborn-esc":
                break
            await asyncio.sleep(0.01)
        assert eng.session is not None and eng.session.id == "after-stubborn-esc"
    finally:
        release.set()
        await task
        client.close()


async def test_streaming_fallback_reuses_clean_prefix(engine, monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", f"{SEG1}|{SEG2}")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", words(220))
    eng, sock = engine

    class FailedPriority(BudgetCleanup):
        def __init__(self):
            super().__init__()
            self.chunk_started = asyncio.Event()
            self.failed = False

        async def cleanup(self, raw, prompt, **kwargs):
            if raw == SEG2:
                self.chunk_started.set()
                await asyncio.Event().wait()
            result = await super().cleanup(raw, prompt, **kwargs)
            if raw.startswith(SEG2) and not self.failed:
                self.failed = True
                return CleanupResult(raw, False, 7, "timeout")
            return result

    cleanup = FailedPriority()
    eng.cleanup = cleanup
    client = await connect(sock)
    await client.recv_event("ready")
    try:
        await client.send_json({"cmd": "start", "session": "reuse-prefix", "context": {}})
        for _ in range(4):
            await client.send_audio(AUDIO)
        await asyncio.wait_for(cleanup.chunk_started.wait(), 2)
        await client.send_json({"cmd": "stop", "session": "reuse-prefix"})
        final = await client.recv_event("final", timeout=10)
        assert sum(raw == SEG1 for raw, _, _ in cleanup.calls) == 1
        assert final["text"].count(SEG1) == 1
        assert_words_once(final["text"], 220)
    finally:
        client.close()
