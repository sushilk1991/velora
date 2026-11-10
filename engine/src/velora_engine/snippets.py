"""Literal, whole-utterance snippets. A saved body is never executed or rewritten."""
from functools import lru_cache
import json
from pathlib import Path


def key(text: str) -> str:
    return " ".join(text.strip().strip(".!?").split()).lower()


@lru_cache(maxsize=8)
def _read(path: str, modified: int, size: int) -> dict[str, str]:
    try:
        value = json.loads(Path(path).read_bytes())
        if not isinstance(value, dict) or type(value.get("version")) is not int or value.get("version") != 1:
            return {}
        rows = value.get("snippets")
        if not isinstance(rows, list) or len(rows) > 200:
            return {}
        output: dict[str, str] = {}
        for row in rows:
            if not isinstance(row, dict):
                return {}
            trigger, text = row.get("trigger"), row.get("text")
            if (not isinstance(trigger, str) or not 0 < len(trigger) <= 60
                    or not isinstance(text, str) or not text.strip() or len(text) > 4_000
                    or "\x00" in text or any(ord(char) < 32 for char in trigger)):
                return {}
            normalized = key(trigger)
            if not normalized or normalized in output:
                return {}
            output[normalized] = text
        return output
    except (OSError, ValueError, UnicodeError):
        return {}


def expansion(home: Path, raw: str) -> str | None:
    path = home / "snippets.json"
    try:
        stat = path.stat()
        if stat.st_size > 4_000_000:
            return None
        return _read(str(path), stat.st_mtime_ns, stat.st_size).get(key(raw))
    except OSError:
        return None
