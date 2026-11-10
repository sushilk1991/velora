"""Audio-derived subtitle cues. Never infer word timing from stored text.

mlx-whisper uses decoder cross-attention + dynamic time warping; those times
are estimates, not forced alignment of the meeting's stored transcript.
The initial qualified model is full Whisper Turbo. Quantized/custom Whisper,
Parakeet, Bark and whisper.cpp need separate timing qualification.
"""
from __future__ import annotations

import hashlib
import math
import re
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SUPPORTED_MODELS = frozenset({"mlx-community/whisper-large-v3-turbo"})
MAX_LINE = 42
MAX_CUE_S = 7.0
MAX_WORDS = 2_000_000
MAX_CUES = 200_000


class SubtitleError(ValueError):
    pass


@dataclass(frozen=True)
class TimedWord:
    text: str
    start: float
    end: float


def validate_track(path: str, *, meeting_id: str, root: Path) -> Path:
    """Only the exact app-owned, non-symlink track for this meeting."""
    try:
        uuid.UUID(meeting_id)
        candidate = Path(path)
        expected = root / meeting_id
        if (not candidate.is_absolute() or candidate.parent != expected
                or candidate.name not in {"me.caf", "them.caf", "them.m4a"}
                or stat.S_ISLNK(root.lstat().st_mode)
                or not stat.S_ISDIR(expected.lstat().st_mode)
                or not stat.S_ISREG(candidate.lstat().st_mode)
                or candidate.resolve(strict=True) != candidate):
            raise SubtitleError("subtitle audio must be an owned meeting track")
        return candidate
    except (ValueError, OSError) as exc:
        raise SubtitleError("subtitle audio is unavailable or outside its meeting") from exc


def source_fingerprint(path: Path, *, cancel: Callable[[], bool] = lambda: False) -> str:
    """Hash source bytes and descriptor identity; reject concurrent replacement."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        import os
        before = os.fstat(source.fileno())
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if not stat.S_ISREG(before.st_mode):
            raise SubtitleError("subtitle audio is not a regular file")
        while chunk := source.read(1024 * 1024):
            if cancel(): raise SubtitleError("cancelled")
            digest.update(chunk)
        if identity(before) != identity(os.fstat(source.fileno())) or identity(before) != identity(path.stat()):
            raise SubtitleError("subtitle audio changed; generate again")
    return digest.hexdigest() + ":" + ":".join(map(str, identity(before)))


def _number(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise SubtitleError("invalid word timing")
    return float(value)


def _normalized(text: str) -> str:
    return re.sub(r"\s+", "", text).casefold()


def validate_words(result: dict[str, Any], *, duration_s: float, offset_s: float = 0) -> list[TimedWord]:
    """Fail the window on untrustworthy metadata; never hide lost alignment.

    No repair by spreading words across a segment. Millisecond rounding is
    deferred to cue publication. Word probabilities and decoding diagnostics
    are quality guards, not an accuracy guarantee.
    """
    words: list[TimedWord] = []
    segments = result.get("segments")
    if not isinstance(segments, list): raise SubtitleError("recognizer returned no word timing")
    previous = 0.0
    for segment in segments:
        if not isinstance(segment, dict): raise SubtitleError("invalid word timing")
        text = segment.get("text", "")
        if not isinstance(text, str): raise SubtitleError("invalid recognized text")
        if not text.strip(): continue
        aligned = segment.get("words")
        if not isinstance(aligned, list) or not aligned: raise SubtitleError("recognizer returned no word timing")
        if (_number(segment.get("avg_logprob", -99)) < -1.0
                or _number(segment.get("compression_ratio", 99)) > 2.4
                or _number(segment.get("no_speech_prob", 1)) > .6):
            raise SubtitleError("recognition confidence is too low for subtitles")
        recognized: list[str] = []
        low_probability = 0
        for word in aligned:
            if not isinstance(word, dict): raise SubtitleError("invalid word timing")
            token = word.get("word")
            if not isinstance(token, str): raise SubtitleError("invalid recognized word")
            if not token.strip(): continue
            if any(ord(c) < 32 and not c.isspace() for c in token): raise SubtitleError("invalid recognized word")
            token = " ".join(token.split())
            start, end = _number(word.get("start")), _number(word.get("end"))
            probability = _number(word.get("probability"))
            if not (0 <= probability <= 1): raise SubtitleError("invalid word probability")
            low_probability += probability < .25
            if not (0 <= start < end <= duration_s and start >= previous
                    and end - start <= MAX_CUE_S and len(token) <= MAX_LINE):
                raise SubtitleError("word timing is reversed, overlapping, out of range or unreadable")
            words.append(TimedWord(token, offset_s + start, offset_s + end))
            recognized.append(token)
            previous = end
            if len(words) > MAX_WORDS: raise SubtitleError("too many subtitle words")
        if _normalized("".join(recognized)) != _normalized(text):
            raise SubtitleError("recognized words do not match the timed text")
        if low_probability > max(1, len(recognized) * .3):
            raise SubtitleError("too many uncertain words for subtitles")
    # Repeated generated credits / loops can have high decoder confidence.
    tokens = [re.sub(r"\W", "", w.text).casefold() for w in words]
    for size in range(1, 7):
        for start in range(max(0, len(tokens) - size * 5 + 1)):
            phrase = tokens[start:start + size]
            if phrase and phrase * 5 == tokens[start:start + size * 5]:
                raise SubtitleError("repeated recognition looks unreliable; use the timed transcript")
    return words


def _wrap(tokens: list[TimedWord], first_limit: int = MAX_LINE) -> str | None:
    lines = [""]
    for word in tokens:
        proposed = (lines[-1] + " " + word.text).strip()
        if len(proposed) <= (first_limit if len(lines) == 1 else MAX_LINE): lines[-1] = proposed
        elif len(lines) == 1 and lines[0] and len(word.text) <= MAX_LINE: lines.append(word.text)
        else: return None
    return "\n".join(lines)


def build_cues(words: list[TimedWord], *, speaker: str) -> list[dict[str, Any]]:
    cues: list[dict[str, Any]] = []
    pending: list[TimedWord] = []
    def flush() -> None:
        if not pending: return
        text = _wrap(pending, first_limit=30)
        start, end = round(pending[0].start * 1000), round(pending[-1].end * 1000)
        if text is None or end <= start or len(text.replace("\n", " ")) / ((end-start)/1000) > 35:
            raise SubtitleError("aligned speech is too dense for readable subtitles")
        cues.append({"start_ms": start, "end_ms": end, "text": text, "speaker": speaker})
        pending.clear()
    for word in words:
        if pending and (word.start - pending[-1].end >= .65
                or word.end - pending[0].start > MAX_CUE_S
                or _wrap(pending + [word], first_limit=30) is None
                or (pending[-1].text.endswith((".", "?", "!", "。", "؟")) and pending[-1].end - pending[0].start >= 1.)):
            flush()
        pending.append(word)
    flush()
    if len(cues) > MAX_CUES: raise SubtitleError("too many subtitle cues")
    return cues
