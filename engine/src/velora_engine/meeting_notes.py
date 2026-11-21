"""Bounded, testable helpers for local meeting-note generation."""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("velora.meeting_notes")

MAX_SUMMARY_CHARS = 4_000
MAX_NOTE_ITEMS = 8
MAX_NOTE_ITEM_CHARS = 1_000
_NOTES_KEYS = {"summary", "decisions", "action_items"}

# Transcript text a single notes pass reads. The reducer keeps only
# MAX_NOTE_ITEMS decisions and MAX_SUMMARY_CHARS of summary after merging, so
# past ~5 map sections its bounded merge starts dropping whatever came last —
# usually the closing decisions and action items. Below that the chunk/map/
# reduce path is enough; above it the middle is condensed first.
SINGLE_PASS_CHARS = 20_000
# The head and the tail of a long meeting stay verbatim. The opening frames
# what the meeting is about; the closing carries the decisions and action
# items people actually leave with. Those are the two parts a summary must
# never lose.
_HEAD_RATIO = 0.3
_TAIL_RATIO = 0.3
# How far a head/tail cut may travel to land on a line boundary, so a cut
# never splits a speaker label or leaves half a word at the seam.
_LINE_SNAP_CHARS = 200
# One middle digest is bounded whatever the model returns: the digests, not
# the raw middle, are what the final composition reads.
MAX_CONDENSED_CHARS = 1_200
# An omission note names at most this many missing ranges before it just
# counts the rest.
_MAX_LISTED_OMISSIONS = 4
# One chunk of transcript handed to the notes model at a time.
DEFAULT_CHUNK_CHARS = 12_000


def chunk_transcript(text: str, max_chars: int = DEFAULT_CHUNK_CHARS) -> list[str]:
    """Split at transcript lines, then hard-split pathological long lines."""
    if max_chars < 100:
        raise ValueError("max_chars is too small")
    chunks: list[str] = []
    current: list[str] = []
    size = 0
    for original in text.splitlines():
        pieces = [original[i : i + max_chars] for i in range(0, len(original), max_chars)] or [""]
        for line in pieces:
            added = len(line) + (1 if current else 0)
            if current and size + added > max_chars:
                chunks.append("\n".join(current).strip())
                current, size = [], 0
            current.append(line)
            size += len(line) + (1 if len(current) > 1 else 0)
    if current:
        chunks.append("\n".join(current).strip())
    return [chunk for chunk in chunks if chunk]


@dataclass(frozen=True)
class HeadMiddleTail:
    """An oversized transcript split so only its middle has to be compressed."""

    head: str
    middle_chunks: list[str]
    tail: str
    # Character spans of ``middle_chunks`` in the original transcript, in
    # order. A span reports where an omitted section came from; it is exact
    # except across a hard split of one pathological line.
    middle_spans: list[tuple[int, int]]
    total_chars: int
    truncated: bool


@dataclass(frozen=True)
class CondensedTranscript:
    """Text to send the notes model, plus what had to be left out of it."""

    text: str
    truncated: bool
    middle_chunks: int
    omitted_spans: list[tuple[int, int]]
    # Set when at least one middle section could not be condensed. Callers
    # must carry it into the delivered summary; dropping it would present an
    # incomplete meeting as a complete one.
    note: str | None


def split_head_middle_tail(
    text: str,
    max_chars: int = SINGLE_PASS_CHARS,
    *,
    middle_chunk_chars: int | None = None,
    head_ratio: float = _HEAD_RATIO,
    tail_ratio: float = _TAIL_RATIO,
) -> HeadMiddleTail:
    """Split a transcript too long for one pass into head, middle, and tail.

    A transcript within ``max_chars`` comes back untouched (``truncated``
    False, no middle) so the caller's single-pass behaviour stays exactly as
    it was. Beyond that budget the head and the tail each keep their share of
    it verbatim and only the middle is offered for compression. Head, middle
    spans, and tail tile the original text with no gap and no overlap.
    """
    if max_chars < 100:
        raise ValueError("max_chars is too small")
    total = len(text)
    if total <= max_chars:
        return HeadMiddleTail(text, [], "", [], total, False)
    head_budget = max(1, int(max_chars * head_ratio))
    tail_budget = max(1, int(max_chars * tail_ratio))
    # The clamp keeps a middle at tiny budgets: a snapped head must never eat
    # the tail's share and drop text without recording it.
    head_end = min(_snap_forward(text, head_budget), max(0, total - tail_budget))
    tail_start = max(_snap_backward(text, total - tail_budget), head_end)
    middle = text[head_end:tail_start]
    chunks, spans = _chunk_middle(
        middle,
        offset=head_end,
        chunk_chars=middle_chunk_chars or min(max_chars, DEFAULT_CHUNK_CHARS),
    )
    return HeadMiddleTail(text[:head_end], chunks, text[tail_start:], spans, total, True)


def condense_middle_transcript(
    text: str,
    condense_fn: Callable[[str], str | None],
    max_chars: int = SINGLE_PASS_CHARS,
    *,
    middle_chunk_chars: int | None = None,
) -> CondensedTranscript:
    """Compress the middle of a long transcript, keeping head and tail verbatim.

    ``condense_fn`` receives one bounded middle chunk and returns a short
    digest, or None when that chunk cannot be compressed. A chunk that fails
    never fails the whole summary and is never dropped silently: its span
    lands in ``note``, which the caller must put in front of the reader.
    """
    plan = split_head_middle_tail(
        text, max_chars, middle_chunk_chars=middle_chunk_chars)
    if not plan.truncated:
        return CondensedTranscript(text, False, 0, [], None)
    return compose_condensed_transcript(
        plan, [_condense(condense_fn, chunk) for chunk in plan.middle_chunks])


def compose_condensed_transcript(
    plan: HeadMiddleTail, digests: list[str | None]
) -> CondensedTranscript:
    """Assemble head + digests + tail, recording every chunk left out.

    Takes the digests separately so an async caller can condense chunks one
    model call at a time and still compose, and report on, the result with
    this one pure function.
    """
    if len(digests) != len(plan.middle_chunks):
        raise ValueError("one digest per middle chunk is required")
    kept: list[str] = []
    omitted: list[tuple[int, int]] = []
    for digest, span in zip(digests, plan.middle_spans):
        if digest is None:
            omitted.append(span)
        else:
            kept.append(digest)
    parts = [plan.head.strip(), *kept, plan.tail.strip()]
    return CondensedTranscript(
        "\n\n".join(part for part in parts if part),
        plan.truncated,
        len(plan.middle_chunks),
        omitted,
        omission_note(omitted, plan.total_chars),
    )


def omission_note(spans: list[tuple[int, int]], total_chars: int) -> str | None:
    """Say in the summary itself which middle sections are missing.

    It locates the gap in the meeting rather than apologising to the model,
    and claims nothing about what the missing part said — the notes are
    incomplete, not invented.
    """
    if not spans or total_chars <= 0:
        return None
    listed = sorted(spans)[:_MAX_LISTED_OMISSIONS]
    places = " and ".join(
        f"roughly {_percent(start, total_chars)}–{_percent(end, total_chars)}%"
        for start, end in listed)
    extra = len(spans) - len(listed)
    more = f" (and {extra} more)" if extra > 0 else ""
    sections = f"{len(spans)} middle section" + ("s" if len(spans) != 1 else "")
    return (
        f"Note: {sections} of this transcript{more}, {places} of the way through, "
        "could not be condensed. That part of the meeting is not reflected "
        "above; it was omitted rather than guessed at."
    )


def with_omission_note(
    summary: str, note: str | None, max_chars: int = MAX_SUMMARY_CHARS
) -> str:
    """Append the omission note after the model's summary, never inside it.

    The summary gives way to the note, not the other way around: a bounded
    summary that hides the omission reads as complete coverage.
    """
    if not note or not note.strip():
        return summary
    note = note.strip()[:max_chars]
    body = summary.strip()
    room = max_chars - len(note) - 1
    if room <= 0:
        return note
    return f"{body[:room].rstrip()} {note}".strip() if body else note


def _chunk_middle(
    middle: str, *, offset: int, chunk_chars: int
) -> tuple[list[str], list[tuple[int, int]]]:
    if not middle:
        return [], []
    chunks = chunk_transcript(middle, max_chars=max(chunk_chars, 100))
    spans: list[tuple[int, int]] = []
    cursor = 0
    for chunk in chunks:
        found = middle.find(chunk, cursor)
        # A hard-split line is rejoined with a newline in the chunk text and
        # no longer matches literally; the running cursor is still the right
        # place, and every later span stays ordered.
        start = found if found >= 0 else cursor
        cursor = start + len(chunk)
        spans.append((offset + start, offset + min(len(middle), cursor)))
    return chunks, spans


def _condense(condense_fn: Callable[[str], str | None], chunk: str) -> str | None:
    try:
        digest = condense_fn(chunk)
    except Exception:  # noqa: BLE001 — one section must not lose the meeting
        log.warning("meeting middle section could not be condensed", exc_info=True)
        return None
    if not isinstance(digest, str):
        return None
    return " ".join(digest.split())[:MAX_CONDENSED_CHARS] or None


def _snap_forward(text: str, n: int) -> int:
    """Cut at ``n``, pulled back to the nearest line start."""
    pos = text.rfind("\n", max(0, n - _LINE_SNAP_CHARS), n)
    return pos + 1 if pos > 0 else n


def _snap_backward(text: str, n: int) -> int:
    """Cut at ``n``, pushed forward to the nearest line start."""
    pos = text.find("\n", n, n + _LINE_SNAP_CHARS)
    return pos + 1 if pos >= 0 else n


def _percent(position: int, total: int) -> int:
    return max(0, min(100, int(round(100 * position / total))))


def parse_notes_json(raw: str) -> dict[str, Any] | None:
    text = raw.strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL | re.IGNORECASE)
    if fenced:
        text = fenced.group(1)
    try:
        value = json.loads(text)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or set(value) not in (_NOTES_KEYS, _NOTES_KEYS | {"chapters"}):
        return None
    if not isinstance(value["summary"], str):
        return None
    if not isinstance(value["decisions"], list) or not isinstance(
        value["action_items"], list
    ):
        return None
    if any(not isinstance(item, str) for item in value["decisions"]):
        return None
    if any(not isinstance(item, str) for item in value["action_items"]):
        return None
    if "chapters" in value and not isinstance(value["chapters"], list):
        return None
    summary = value["summary"].strip()[:MAX_SUMMARY_CHARS]
    if not summary:
        return None
    decisions = _strings(value["decisions"])
    actions = _strings(value["action_items"])
    result = {"summary": summary, "decisions": decisions, "action_items": actions}
    if "chapters" in value:
        result["chapters"] = [item for item in value["chapters"] if isinstance(item, dict)][:80]
    return result


def merge_notes(parts: list[dict[str, Any]]) -> dict[str, Any]:
    summaries = [str(part.get("summary") or "").strip() for part in parts]
    summaries = [value for value in summaries if value]
    result = {
        "summary": " ".join(summaries)[:MAX_SUMMARY_CHARS],
        "decisions": _dedupe(item for part in parts for item in _strings(part.get("decisions"))),
        "action_items": _dedupe(
            item for part in parts for item in _strings(part.get("action_items"))
        ),
    }
    if any("chapters" in part for part in parts):
        result["chapters"] = [chapter for part in parts for chapter in part.get("chapters", [])][:80]
    return result


def _strings(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [
        item.strip()[:MAX_NOTE_ITEM_CHARS]
        for item in value
        if isinstance(item, str) and item.strip()
    ][:MAX_NOTE_ITEMS]


def _dedupe(values: Any) -> list[str]:
    output: list[str] = []
    seen: set[str] = set()
    for value in values:
        key = value.casefold()
        if key not in seen:
            seen.add(key)
            output.append(value)
    return output[:MAX_NOTE_ITEMS]
