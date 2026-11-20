"""Fast, pure cue detection over raw/prepared dictation transcripts (V-06)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .tables import EMOJI_TABLE, HOMOPHONE_TABLE, TAKE_BACK_PHRASES

_PUNCT_CUE_RE = re.compile(
    r"\b(?:"
    r"full\s+stop|period|comma|question\s+mark|exclamation\s+(?:mark|point)"
    r"|colon|semicolon|semi-colon|open\s+quote|close\s+quote|end\s+quote"
    r"|open\s+paren(?:thesis)?|close\s+paren(?:thesis)?|dash|hyphen"
    r"|virgule|deux\s+points|point\s+d'interrogation|komma|punkt|punto"
    r")\b",
    re.IGNORECASE,
)

_LINE_BREAK_CUE_RE = re.compile(
    r"⏎|\n|\b(?:new|next)\s*(?:line|paragraph)\b",
    re.IGNORECASE,
)

_TAKE_BACK_RE = re.compile(
    r"\b(?:" + "|".join(re.escape(p) for p in TAKE_BACK_PHRASES) + r")\b",
    re.IGNORECASE,
)

_SELF_CORRECTION_RE = re.compile(
    r"\b(?:"
    r"no\s+no|no\s+wait|wait\s+no|actually|i\s+mean|oh\s+sorry|sorry\s+no"
    r"|make\s+that|correction|or\s+rather|not\s+\w+\s+but|instead\s+of"
    r"|no\s+sorry|wait\s+actually"
    r")\b",
    re.IGNORECASE,
)

_META_EDIT_RE = re.compile(
    r"\b(?:change|replace|edit|update|fix|make)\s+the\s+(?:previous|last)\s+(?:line|sentence)\b",
    re.IGNORECASE,
)

_BARE_LINES_RE = re.compile(
    r"\b(?:each(?:\s+of\s+them)?(?:\s+is)?\s+on\s+(?:a\s+)?(?:different|new|separate|its\s+own)\s+line"
    r"|on\s+separate\s+lines)\b",
    re.IGNORECASE,
)

_LIST_REQUEST_RE = re.compile(
    r"\b(?:"
    r"(?:make|create|write|start|put\s+(?:this|these|it)\s+in)\s+a\s+(?:numbered\s+|bullet(?:ed)?\s+)?list"
    r"|bullet\s+points?|bulleted\s+list|numbered\s+list"
    r"|each(?:\s+of\s+them)?(?:\s+is)?\s+on\s+(?:a\s+)?(?:different|new|separate|its\s+own)\s+line"
    r"|on\s+separate\s+lines"
    r")\b",
    re.IGNORECASE,
)

# Explicit counted collections or spoken ordinal sequences (markers-only policy, V-10).
_COUNTED_COLLECTION_RE = re.compile(
    r"\b(?:two|three|four|five|six|seven|eight|nine|ten|\d+)\s+"
    r"(?:items?|things?|points?|priorities|errands?|issues?|steps?|tasks?|"
    r"problems?|reasons?|options?|questions?|goals?|bugs?|changes?|parts?|requests?|feedback\s+points?)\b",
    re.IGNORECASE,
)
_ORDINAL_NOMINAL_DETS = frozenset(
    "my the a an our his her their this that your its".split()
)
_ORDINAL_FIRST_RE = re.compile(r"\b(?:first|1st|number\s+one)\b", re.IGNORECASE)
_ORDINAL_SECOND_RE = re.compile(r"\b(?:second|2nd|number\s+two)\b", re.IGNORECASE)


def _preceded_by_nominal_det(text: str, start: int) -> bool:
    prev = re.findall(r"[A-Za-z']+", text[:start])[-1:]
    return bool(prev) and prev[0].lower() in _ORDINAL_NOMINAL_DETS


def _has_ordinal_sequence(text: str) -> bool:
    """True when a non-nominal 'first' is followed within 160 chars by a non-nominal 'second'."""
    for first in _ORDINAL_FIRST_RE.finditer(text):
        if _preceded_by_nominal_det(text, first.start()):
            continue
        window_start = first.end()
        window_end = min(len(text), window_start + 160)
        for second in _ORDINAL_SECOND_RE.finditer(text, window_start, window_end):
            if not _preceded_by_nominal_det(text, second.start()):
                return True
    return False
_COUNTING_UP_RE = re.compile(
    r"\b(?:one\b.{1,80}\btwo\b.{1,80}\bthree\b"
    r"|six\b.{1,80}\bseven\b.{1,80}\beight\b"
    r"|step\s+one\b.{1,80}\bstep\s+two\b)"
    r"|第一.{1,80}第二"
    r"|पहली.{1,80}दूसरी",
    re.IGNORECASE | re.DOTALL,
)
_EXPLICIT_ISSUE_INTRO_RE = re.compile(
    r"\b(?:a\s+few|several|multiple)\s+(?:pieces?\s+of\s+feedback|issues?|problems?|feedback\s+points?|tasks?|items?|things?)\b",
    re.IGNORECASE,
)

_EMOJI_WORD_RE = re.compile(r"\bemoji\b", re.IGNORECASE)
_EMOJI_NAMES_RE = re.compile(
    r"\b(" + "|".join(re.escape(k) for k in sorted(EMOJI_TABLE, key=len, reverse=True)) + r")\b",
    re.IGNORECASE,
)

_WORD_TOKEN_RE = re.compile(r"[A-Za-z']+")


@dataclass(frozen=True)
class TranscriptCues:
    """Detected cue set and matched table items for one transcript."""

    cues: frozenset[str]
    matched_homophones: tuple[str, ...] = ()
    matched_emojis: tuple[tuple[str, str], ...] = ()

    def has(self, cue: str) -> bool:
        return cue in self.cues


def detect_cues(text: str) -> TranscriptCues:
    """Inspect ``text`` and return all active cue tags + matched table entries."""
    if not text:
        return TranscriptCues(frozenset())

    cues: set[str] = set()
    if _PUNCT_CUE_RE.search(text):
        cues.add("spoken_punctuation")
    if _LINE_BREAK_CUE_RE.search(text):
        cues.add("line_breaks")
    if _TAKE_BACK_RE.search(text):
        cues.add("take_backs")
        cues.add("self_correction")
    elif _SELF_CORRECTION_RE.search(text):
        cues.add("self_correction")
    if _META_EDIT_RE.search(text):
        cues.add("meta_edit")
        cues.add("self_correction")
    if _BARE_LINES_RE.search(text):
        cues.add("bare_lines")
    if _LIST_REQUEST_RE.search(text):
        cues.add("list_request")
    if (
        _COUNTED_COLLECTION_RE.search(text)
        or _has_ordinal_sequence(text)
        or _COUNTING_UP_RE.search(text)
        or _EXPLICIT_ISSUE_INTRO_RE.search(text)
    ):
        cues.add("counted_ordinals")

    # Emoji cue fires ONLY when the word "emoji" appears (never on bare words
    # like "that party was fire"), collecting any known emoji names present.
    matched_emojis: list[tuple[str, str]] = []
    if _EMOJI_WORD_RE.search(text):
        seen_names: set[str] = set()
        for match in _EMOJI_NAMES_RE.finditer(text):
            key = match.group(1).lower()
            if key not in seen_names:
                seen_names.add(key)
                matched_emojis.append((key, EMOJI_TABLE[key]))
        cues.add("emoji")

    # Homophone cue fires ONLY for homophone families whose words appear here.
    words_lower = {w.lower() for w in _WORD_TOKEN_RE.findall(text)}
    matched_homophones: list[str] = []
    if words_lower:
        for family, hint in HOMOPHONE_TABLE:
            if words_lower & family:
                matched_homophones.append(hint)
        if matched_homophones:
            cues.add("homophones")

    return TranscriptCues(
        cues=frozenset(cues),
        matched_homophones=tuple(matched_homophones),
        matched_emojis=tuple(matched_emojis),
    )
