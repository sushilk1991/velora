"""Bounded, testable helpers for local meeting-note generation."""

from __future__ import annotations

import json
import re
from typing import Any

MAX_SUMMARY_CHARS = 4_000
MAX_NOTE_ITEMS = 8
MAX_NOTE_ITEM_CHARS = 1_000
_NOTES_KEYS = {"summary", "decisions", "action_items"}


def chunk_transcript(text: str, max_chars: int = 12_000) -> list[str]:
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


def parse_notes_json(raw: str) -> dict[str, Any] | None:
    text = raw.strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL | re.IGNORECASE)
    if fenced:
        text = fenced.group(1)
    try:
        value = json.loads(text)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or set(value) != _NOTES_KEYS:
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
    summary = value["summary"].strip()[:MAX_SUMMARY_CHARS]
    if not summary:
        return None
    decisions = _strings(value["decisions"])
    actions = _strings(value["action_items"])
    return {"summary": summary, "decisions": decisions, "action_items": actions}


def merge_notes(parts: list[dict[str, Any]]) -> dict[str, Any]:
    summaries = [str(part.get("summary") or "").strip() for part in parts]
    summaries = [value for value in summaries if value]
    return {
        "summary": " ".join(summaries)[:MAX_SUMMARY_CHARS],
        "decisions": _dedupe(item for part in parts for item in _strings(part.get("decisions"))),
        "action_items": _dedupe(
            item for part in parts for item in _strings(part.get("action_items"))
        ),
    }


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
