"""Bounded, testable helpers for local meeting-note generation."""

from __future__ import annotations

import json
import re
from typing import Any


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
    if not isinstance(value, dict):
        return None
    summary = str(value.get("summary") or "").strip()
    decisions = _strings(value.get("decisions"))
    actions = _strings(value.get("action_items"))
    if not summary and not decisions and not actions:
        return None
    return {"summary": summary, "decisions": decisions, "action_items": actions}


def merge_notes(parts: list[dict[str, Any]]) -> dict[str, Any]:
    summaries = [str(part.get("summary") or "").strip() for part in parts]
    summaries = [value for value in summaries if value]
    return {
        "summary": " ".join(summaries)[:4_000],
        "decisions": _dedupe(item for part in parts for item in _strings(part.get("decisions"))),
        "action_items": _dedupe(
            item for part in parts for item in _strings(part.get("action_items"))
        ),
    }


def fallback_notes(transcript: str) -> dict[str, Any]:
    compact = " ".join(transcript.split())
    if not compact:
        return {"summary": "", "decisions": [], "action_items": []}
    summary = compact[:800]
    if len(compact) > 800:
        summary = summary.rsplit(" ", 1)[0] + "…"
    return {"summary": summary, "decisions": [], "action_items": []}


def _strings(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item).strip()[:1_000] for item in value if str(item).strip()][:100]


def _dedupe(values: Any) -> list[str]:
    output: list[str] = []
    seen: set[str] = set()
    for value in values:
        key = value.casefold()
        if key not in seen:
            seen.add(key)
            output.append(value)
    return output[:100]
