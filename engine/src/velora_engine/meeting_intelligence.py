"""Validate semantic chapter proposals against actual, coarse transcript blocks.

The notes model proposes topics; this module only accepts their real source
ranges. It never estimates sentence/word timestamps or creates time buckets.
"""
from __future__ import annotations

from typing import Any
import re

MAX_PASSAGES = 20_000
MAX_CHAPTERS = 80


def _source_key(value: Any) -> str | None:
    # The prompt displays [@me:0]. Some local models copy the display marker
    # despite the output-schema instruction. The underlying key must still
    # match an actual visible source exactly.
    return value.removeprefix("@") if isinstance(value, str) else None


def prepare_passages(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > MAX_PASSAGES:
        return []
    result: list[dict[str, Any]] = []
    keys: set[str] = set()
    total_chars = 0
    for item in value:
        if not isinstance(item, dict):
            return []
        key, text = item.get("key"), item.get("text")
        start, end = item.get("start_ms"), item.get("end_ms")
        if (not isinstance(key, str) or re.fullmatch(r"(?:me|them|recording|s[1-9][0-9]?):[0-9]+", key) is None or len(key) > 80 or key in keys
                or not isinstance(text, str) or not text.strip() or len(text) > 100_000
                or type(start) is not int or type(end) is not int or start < 0 or end <= start):
            return []
        total_chars += len(text) + len(key) + 8
        if total_chars > 2_000_000:
            return []
        keys.add(key)
        result.append({"key": key, "text": text, "start_ms": start, "end_ms": end})
    return sorted(result, key=lambda p: (p["start_ms"], p["key"].split(":")[0], int(p["key"].split(":")[-1]) if p["key"].split(":")[-1].isdigit() else 0))


def validate_chapters(candidates: Any, passages: Any) -> list[dict[str, str]]:
    sources = prepare_passages(passages)
    if not sources or not isinstance(candidates, list):
        return []
    indexes = {p["key"]: i for i, p in enumerate(sources)}
    result: list[dict[str, str]] = []
    last_end = -1
    # Sort by actual transcript order; map chunks may include repeated context.
    proposals = sorted((c for c in candidates if isinstance(c, dict)),
                       key=lambda c: indexes.get(_source_key(c.get("start_key")), len(sources)))
    for chapter in proposals:
        title = chapter.get("title")
        start, end = indexes.get(_source_key(chapter.get("start_key"))), indexes.get(_source_key(chapter.get("end_key")))
        if (not isinstance(title, str) or not title.strip() or len(title) > 160
                or start is None or end is None or end < start or start <= last_end):
            continue
        first, final = sources[start], sources[end]
        if result and start == last_end + 1 and result[-1]["title"].casefold() == title.strip().casefold():
            result[-1]["endKey"] = final["key"]
            result[-1]["endText"] = final["text"]
        else:
            result.append({"title": title.strip(), "startKey": first["key"], "endKey": final["key"],
                           "startText": first["text"], "endText": final["text"]})
        last_end = end
        if len(result) == MAX_CHAPTERS:
            break
    return result


def chapters_in_chunk(candidates: Any, chunk: str) -> list[dict[str, Any]]:
    """A map response cannot cite a real block that was outside its context."""
    if not isinstance(candidates, list):
        return []
    visible = set(re.findall(r"\[@((?:me|them|recording|s[1-9][0-9]?):[0-9]+)\]", chunk))
    return [{**c, "start_key": _source_key(c.get("start_key")), "end_key": _source_key(c.get("end_key"))}
            for c in candidates if isinstance(c, dict)
            and _source_key(c.get("start_key")) in visible
            and _source_key(c.get("end_key")) in visible][:80]
