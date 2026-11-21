"""Long meetings are condensed, never truncated: head and tail survive whole."""
from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from velora_engine.meeting_notes import (
    MAX_CONDENSED_CHARS,
    MAX_SUMMARY_CHARS,
    SINGLE_PASS_CHARS,
    compose_condensed_transcript,
    condense_middle_transcript,
    split_head_middle_tail,
    with_omission_note,
)

from test_server import connect, engine  # noqa: F401


def transcript(minutes: int = 120, filler: str = "filler ") -> str:
    """A synthetic meeting with an opening marker and a closing action item."""
    lines = ["[00:00] Me: OPENING: the launch budget is approved."]
    for minute in range(minutes):
        lines.append(f"[{minute:03d}:00] Them: middle discussion {minute} " + filler * 100)
    lines.append(f"[{minutes:03d}:00] Me: ACTION: Sam sends the signed contract by Friday.")
    return "\n".join(lines)


def assert_tiles(plan, text: str) -> None:
    """Head, middle spans and tail cover the source; seams only hold whitespace."""
    bounds = [
        (len(plan.head), plan.middle_spans[0][0]),
        *[(end, next_start) for (_start, end), (next_start, _) in
          zip(plan.middle_spans, plan.middle_spans[1:])],
        (plan.middle_spans[-1][1], plan.total_chars - len(plan.tail)),
    ]
    for start, end in plan.middle_spans:
        assert start < end
    for gap_start, gap_end in bounds:
        assert gap_start <= gap_end
        assert not text[gap_start:gap_end].strip()  # a seam drops no words


def test_short_transcript_bypasses_map_reduce_entirely():
    text = "[00:00] Me: We agreed to ship on Friday.\n[00:10] Them: Confirmed."
    calls: list[str] = []

    result = condense_middle_transcript(text, lambda chunk: calls.append(chunk) or "digest")

    assert calls == []
    assert result.text == text
    assert result.truncated is False
    assert result.middle_chunks == 0 and result.omitted_spans == []
    assert result.note is None


def test_transcript_exactly_at_the_budget_stays_a_single_pass():
    text = "x" * SINGLE_PASS_CHARS
    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)
    assert plan.truncated is False and plan.middle_chunks == []
    assert condense_middle_transcript(text, lambda chunk: "digest").text == text


def test_two_hour_meeting_keeps_head_and_tail_verbatim_and_condenses_the_middle():
    text = transcript()
    assert len(text) > 4 * SINGLE_PASS_CHARS

    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)
    assert plan.truncated
    assert text.startswith(plan.head) and text.endswith(plan.tail)
    assert_tiles(plan, text)
    assert len(plan.middle_chunks) >= 4
    assert all(len(chunk) <= SINGLE_PASS_CHARS for chunk in plan.middle_chunks)
    # The closing action item and the opening context are outside the middle.
    assert "ACTION: Sam sends" in plan.tail
    assert "OPENING:" in plan.head

    seen: list[str] = []

    def condense(chunk: str) -> str:
        seen.append(chunk)
        return f"DIGEST {len(seen)}"

    result = condense_middle_transcript(text, condense)

    assert len(seen) == len(plan.middle_chunks)
    assert result.truncated and result.note is None and result.omitted_spans == []
    assert result.text.startswith(plan.head.strip())
    assert result.text.endswith(plan.tail.strip())
    assert all(f"DIGEST {index}" in result.text for index in range(1, len(seen) + 1))
    # The raw middle is replaced by its digests, not dropped along with it.
    assert "middle discussion 60" not in result.text
    assert len(result.text) < len(plan.head) + len(plan.tail) + 2 * len(plan.middle_chunks) * 40


def test_one_uncondensable_section_is_reported_and_never_fails_the_summary():
    text = transcript()
    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)
    calls = {"n": 0}

    def condense(chunk: str) -> str | None:
        calls["n"] += 1
        if calls["n"] == 2:
            raise RuntimeError("the notes model died mid-section")
        return f"DIGEST {calls['n']}"

    result = condense_middle_transcript(text, condense)

    assert calls["n"] == len(plan.middle_chunks)  # one failure does not stop the rest
    assert result.omitted_spans == [plan.middle_spans[1]]
    assert result.text.count("DIGEST") == len(plan.middle_chunks) - 1
    assert result.note is not None
    assert "1 middle section" in result.note
    assert "could not be condensed" in result.note
    # The note locates the gap and claims nothing about what it said.
    assert "%" in result.note and "middle discussion" not in result.note
    assert "ACTION: Sam sends the signed contract" in result.text


def test_every_middle_failure_still_yields_honest_notes():
    text = transcript()
    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)

    result = condense_middle_transcript(text, lambda chunk: None)

    assert result.text == "\n\n".join([plan.head.strip(), plan.tail.strip()])
    assert len(result.omitted_spans) == len(plan.middle_chunks)
    assert result.note is not None and str(len(plan.middle_chunks)) in result.note

    summary = with_omission_note("The team reviewed the quarter.", result.note)
    assert summary.startswith("The team reviewed the quarter.")
    assert summary.endswith(result.note)
    assert len(summary) <= MAX_SUMMARY_CHARS


def test_omission_note_survives_a_summary_that_already_uses_the_budget():
    note = "Note: 1 middle section of this transcript, roughly 40\u201350% of the way through, could not be condensed. That part of the meeting is not reflected above; it was omitted rather than guessed at."
    summary = "z" * MAX_SUMMARY_CHARS

    merged = with_omission_note(summary, note)

    assert len(merged) <= MAX_SUMMARY_CHARS
    assert merged.endswith(note)  # the note wins the space, the summary yields


def test_digest_shapes_are_bounded_and_bad_ones_fail_closed():
    text = transcript()
    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)
    answers: list[object] = [123, "  \n\t ", "word " * 5_000]
    answers += [f"DIGEST {index}" for index in range(len(plan.middle_chunks))]
    pending = iter(answers)

    result = condense_middle_transcript(text, lambda chunk: pending.__next__())

    assert result.omitted_spans == plan.middle_spans[:2]  # non-string and blank
    digest = next(part for part in result.text.split("\n\n") if part.startswith("word"))
    assert len(digest) == MAX_CONDENSED_CHARS
    assert len(result.omitted_spans) == 2


def test_tiny_budget_covers_the_source_without_losing_a_character():
    text = "\n".join(f"line {index} " + "x" * 40 for index in range(20))

    plan = split_head_middle_tail(text, 100)

    assert plan.truncated and plan.middle_chunks
    assert_tiles(plan, text)
    assert len(plan.head) + len(plan.tail) < len(text)
    assert text.startswith(plan.head) and text.endswith(plan.tail)


def test_budget_below_the_clamp_floor_is_rejected():
    with pytest.raises(ValueError):
        split_head_middle_tail("x" * 500, 99)
    with pytest.raises(ValueError):
        condense_middle_transcript("x" * 500, lambda chunk: "digest", 99)


def test_pathological_single_line_is_hard_split_and_loses_nothing():
    text = "x" * 50_000

    plan = split_head_middle_tail(text, SINGLE_PASS_CHARS)

    assert plan.head and plan.tail and len(plan.middle_chunks) >= 2
    assert_tiles(plan, text)
    assert all(len(chunk) <= SINGLE_PASS_CHARS for chunk in plan.middle_chunks)
    # No newlines to rejoin: the chunks concatenate back to the exact source.
    assert plan.head + "".join(plan.middle_chunks) + plan.tail == text


def test_empty_and_blank_input_never_reaches_the_model():
    for text in ("", "   \n\n  "):
        calls: list[str] = []
        result = condense_middle_transcript(
            text, lambda chunk: calls.append(chunk) or "digest")
        assert calls == []
        assert result.text == text
        assert not result.truncated and result.note is None


def test_compose_requires_one_digest_per_middle_chunk():
    plan = split_head_middle_tail(transcript(), SINGLE_PASS_CHARS)
    with pytest.raises(ValueError):
        compose_condensed_transcript(plan, ["only one"])


async def test_long_meeting_notes_carry_the_omission_note_to_the_app(engine):
    eng, sock = engine
    condense_calls = {"n": 0}
    map_payloads: list[str] = []

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            if "Compress this middle section" in system_prompt:
                condense_calls["n"] += 1
                if condense_calls["n"] == 2:
                    return SimpleNamespace(
                        applied=False, text=raw, reason="length")
                return SimpleNamespace(
                    applied=True, text="They reviewed the quarter's spend.", reason=None)
            map_payloads.append(raw)
            return SimpleNamespace(applied=True, text=json.dumps({
                "summary": "Launch approved; spend reviewed.",
                "decisions": ["Approve launch budget"],
                "action_items": ["Sam sends the signed contract by Friday"],
            }))

    eng.cleanup = Cleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "meeting_notes", "id": "long", "meeting_id": "longmeeting",
                            "transcript": transcript()})
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")

    assert ready["partial"] is True
    assert ready["summary"].startswith("Launch approved; spend reviewed.")
    assert "could not be condensed" in ready["summary"]
    assert ready["action_items"] == ["Sam sends the signed contract by Friday"]
    assert condense_calls["n"] > 1
    # The head and the tail reached the model verbatim; the raw middle did not.
    payload = "\n".join(map_payloads)
    assert "OPENING: the launch budget is approved." in payload
    assert "ACTION: Sam sends the signed contract by Friday." in payload
    assert "middle discussion 60" not in payload
    assert not eng._meeting_notes_running
