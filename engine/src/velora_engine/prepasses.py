"""Deterministic pre-passes run before the cleanup LLM (V-08).

Two pure, conservative passes that handle patterns small local LLMs do least
reliably:

1. ``undo_title_case``: repairs Whisper's occasional all-Title-Case output
   ("We Need To Ship The Release By Friday") while protecting sentence starts,
   pronoun "I", calendar names, acronyms, mixed-case identifiers, and user
   vocabulary / glossary terms.
2. ``spoken_numbers_to_digits``: converts spoken numbers to digits ONLY in
   determinate, unambiguous contexts (decimals, percentages, dollars/euros,
   explicit clock times, 1900–2099 years, date ordinals, unit-qualified counts,
   and multi-word compound cardinals >= 21 or >= 100). Idiomatic standalone
   words ("one of the things", "a second", "first of all", "three priorities")
   are left untouched.
"""

from __future__ import annotations

import re
from collections.abc import Collection

# --- Title-case repair -------------------------------------------------------

# Common lowercase function words. Real lists of proper nouns ("Priya Menon,
# Rahul Sharma, Omar Khan") contain none of these, whereas Whisper's Title Case
# artefact capitalizes them mid-sentence ("We Need To Ship The Release").
_TITLE_CASE_FUNCTION_WORDS = frozenset(
    "a an the to of and in for with is are was were be been being "
    "that this these those on at by from as or but not nor so if "
    "it its we our us they them their you your he him his she her "
    "have has had do does did will would should could can may might must "
    "about into onto over under after before between through during "
    "because while where when then than also just very much more most "
    "only some any each every all both few many other such no too "
    "up out off down back here there".split()
)

_CALENDAR_PROPER = frozenset(
    "monday tuesday wednesday thursday friday saturday sunday "
    "january february march april may june july august september "
    "october november december".split()
)

_I_CONTRACTIONS = frozenset({"i", "i'm", "i've", "i'll", "i'd"})

# Splits text into alternating (unquoted, protected-span) segments so quoted or
# backticked literals are never rewritten by deterministic pre-passes.
_PROTECTED_SPAN_RE = re.compile(r'(`[^`\n]*`|"[^"\n]*")')
_ALPHA_WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")


def _is_title_cased(word: str) -> bool:
    if len(word) == 1:
        return word.isupper()
    return word[0].isupper() and word[1:].islower()


def _is_all_caps_acronym(word: str) -> bool:
    letters = word.replace("'", "")
    return len(letters) >= 2 and letters.isupper()


def _is_mixed_case_brand(word: str) -> bool:
    """True for CamelCase / brand casing like iOS, macOS, GitHub, AirPods."""
    if len(word) < 2:
        return False
    return any(c.isupper() for c in word[1:]) and any(c.islower() for c in word)


def _is_sentence_start(text: str, pos: int, *, at_text_start: bool = True) -> bool:
    prefix = text[:pos]
    stripped = prefix.rstrip(" \t")
    if not stripped:
        return at_text_start
    if stripped[-1] in "\n.!?…":
        return True
    # After a closing quote/paren that follows terminal punctuation.
    if len(stripped) >= 2 and stripped[-1] in "\"')]" and stripped[-2] in ".!?…":
        return True
    return False


def _protected_term_spans(
    text: str, protected_terms: Collection[str]
) -> list[tuple[int, int, str]]:
    """Return non-overlapping (start, end, canonical) spans for protected terms."""
    cleaned = sorted(
        {t.strip() for t in protected_terms if isinstance(t, str) and len(t.strip()) >= 2},
        key=len,
        reverse=True,
    )
    if not cleaned:
        return []
    pattern = re.compile(
        r"(?<!\w)(?:" + "|".join(re.escape(t) for t in cleaned) + r")(?!\w)",
        re.IGNORECASE,
    )
    canonical_by_fold = {t.casefold(): t for t in cleaned}
    spans: list[tuple[int, int, str]] = []
    for match in pattern.finditer(text):
        canonical = canonical_by_fold[match.group(0).casefold()]
        # Only protect terms that actually carry uppercase letters (or acronyms);
        # an all-lowercase dictionary word shouldn't stay Title-Cased.
        if any(c.isupper() for c in canonical):
            spans.append((match.start(), match.end(), canonical))
    return spans


def undo_title_case(
    text: str,
    *,
    protected_terms: Collection[str] = (),
) -> str:
    """Repair Whisper's all-Title-Case artefact conservatively.

    Triggers only when the text has >= 5 alphabetic words (excluding acronyms),
    >= 85% of them are Title-Cased, and at least 2 non-sentence-initial words
    are Title-Cased English function words (e.g. "The", "To", "Of", "In").
    """
    if not text or len(text) < 12:
        return text

    parts = _PROTECTED_SPAN_RE.split(text)
    eligible = 0
    titled = 0
    mid_function_titled = 0

    for idx in range(0, len(parts), 2):
        seg = parts[idx]
        for match in _ALPHA_WORD_RE.finditer(seg):
            word = match.group(0)
            if _is_all_caps_acronym(word) or _is_mixed_case_brand(word):
                continue
            eligible += 1
            if _is_title_cased(word):
                titled += 1
                if (
                    word.lower() in _TITLE_CASE_FUNCTION_WORDS
                    and not _is_sentence_start(seg, match.start(), at_text_start=(idx == 0))
                ):
                    mid_function_titled += 1

    if eligible < 5 or mid_function_titled < 2 or (titled / eligible) < 0.85:
        return text

    rebuilt: list[str] = []
    for idx, seg in enumerate(parts):
        if idx % 2 == 1:
            rebuilt.append(seg)
            continue
        seg_starts_sentence = idx == 0 or (
            idx >= 2 and _is_sentence_start(parts[idx - 1], len(parts[idx - 1]), at_text_start=False)
        )
        protected = _protected_term_spans(seg, protected_terms)
        out_chunks: list[str] = []
        cursor = 0

        def _rewrite_plain(sub: str, base_offset: int) -> str:
            def _word_repl(m: re.Match[str]) -> str:
                word = m.group(0)
                if not _is_title_cased(word):
                    return word
                low = word.lower()
                if low in _I_CONTRACTIONS or low in _CALENDAR_PROPER:
                    return word
                abs_pos = base_offset + m.start()
                if _is_sentence_start(seg, abs_pos, at_text_start=seg_starts_sentence):
                    return word
                return low

            return _ALPHA_WORD_RE.sub(_word_repl, sub)

        for start, end, canonical in protected:
            if start < cursor:
                continue
            out_chunks.append(_rewrite_plain(seg[cursor:start], cursor))
            out_chunks.append(canonical)
            cursor = end
        out_chunks.append(_rewrite_plain(seg[cursor:], cursor))
        rebuilt.append("".join(out_chunks))

    return "".join(rebuilt)


# --- Spoken numbers to digits ------------------------------------------------

_UNITS: dict[str, int] = {
    "zero": 0,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
}
_TEENS: dict[str, int] = {
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
    "thirteen": 13,
    "fourteen": 14,
    "fifteen": 15,
    "sixteen": 16,
    "seventeen": 17,
    "eighteen": 18,
    "nineteen": 19,
}
_TENS: dict[str, int] = {
    "twenty": 20,
    "thirty": 30,
    "forty": 40,
    "fifty": 50,
    "sixty": 60,
    "seventy": 70,
    "eighty": 80,
    "ninety": 90,
}
_SCALES: dict[str, int] = {
    "hundred": 100,
    "thousand": 1_000,
}
_LARGE_SCALES: frozenset[str] = frozenset({"million", "billion"})

_ORDINAL_UNITS: dict[str, int] = {
    "first": 1,
    "second": 2,
    "third": 3,
    "fourth": 4,
    "fifth": 5,
    "sixth": 6,
    "seventh": 7,
    "eighth": 8,
    "ninth": 9,
}
_ORDINAL_TEENS: dict[str, int] = {
    "tenth": 10,
    "eleventh": 11,
    "twelfth": 12,
    "thirteenth": 13,
    "fourteenth": 14,
    "fifteenth": 15,
    "sixteenth": 16,
    "seventeenth": 17,
    "eighteenth": 18,
    "nineteenth": 19,
}
_ORDINAL_TENS: dict[str, int] = {
    "twentieth": 20,
    "thirtieth": 30,
    "fortieth": 40,
    "fiftieth": 50,
    "sixtieth": 60,
    "seventieth": 70,
    "eightieth": 80,
    "ninetieth": 90,
}

_MONTHS_PATTERN = (
    r"January|February|March|April|May|June|July|August|"
    r"September|October|November|December"
)

_UNIT_WORDS_ALT = "|".join(sorted(_UNITS, key=len, reverse=True))
_TEEN_WORDS_ALT = "|".join(sorted(_TEENS, key=len, reverse=True))
_TENS_WORDS_ALT = "|".join(sorted(_TENS, key=len, reverse=True))
_SIMPLE_NUM_ALT = f"(?:{_TENS_WORDS_ALT})(?:[-\\s]+(?:{_UNIT_WORDS_ALT}))?|(?:{_TEEN_WORDS_ALT})|(?:{_UNIT_WORDS_ALT})"

# Multi-word cardinal up to 999,999 (e.g., "two thousand five hundred", "one hundred and twenty",
# "forty two", or single "five").
_HUNDRED_GROUP = (
    rf"(?:(?:(?:{_UNIT_WORDS_ALT})|a)\s+hundred(?:\s+(?:and\s+)?(?:{_SIMPLE_NUM_ALT}))?|(?:{_SIMPLE_NUM_ALT}))"
)
_CARDINAL_PHRASE = (
    rf"(?:{_HUNDRED_GROUP}\s+thousand(?:\s+(?:and\s+)?{_HUNDRED_GROUP})?|{_HUNDRED_GROUP})"
)

# Multi-word compound cardinal ONLY (never a bare single word <= 20):
# either >= 21 ("twenty one"), or contains "hundred" / "thousand".
_COMPOUND_TENS_UNIT = rf"(?:{_TENS_WORDS_ALT})(?:[-\s]+(?:{_UNIT_WORDS_ALT}))"
_COMPOUND_HUNDRED = (
    rf"(?:(?:{_UNIT_WORDS_ALT})\s+hundred(?:\s+(?:and\s+)?(?:{_SIMPLE_NUM_ALT}))?)"
)
_COMPOUND_THOUSAND = (
    rf"(?:(?:{_HUNDRED_GROUP})\s+thousand(?:\s+(?:and\s+)?{_HUNDRED_GROUP})?)"
)
_COMPOUND_CARDINAL = rf"(?:{_COMPOUND_THOUSAND}|{_COMPOUND_HUNDRED}|{_COMPOUND_TENS_UNIT})"

_ORDINAL_SINGLE_ALT = "|".join(
    sorted((*_ORDINAL_UNITS, *_ORDINAL_TEENS, *_ORDINAL_TENS), key=len, reverse=True)
)
_ORDINAL_COMPOUND_ALT = rf"(?:{_TENS_WORDS_ALT})(?:[-\s]+(?:{'|'.join(sorted(_ORDINAL_UNITS, key=len, reverse=True))}))"
_ORDINAL_PHRASE = rf"(?:{_ORDINAL_COMPOUND_ALT}|{_ORDINAL_SINGLE_ALT})"

# Units where even single-word numbers ("five minutes", "eight gigabytes") should digitize.
_STRICT_UNITS = (
    r"milliseconds?|msecs?|ms|seconds?|secs?|minutes?|mins?|hours?|hrs?|"
    r"kilobytes?|kb|megabytes?|mb|gigabytes?|gb|terabytes?|tb|bytes?|"
    r"hertz|hz|khz|mhz|ghz|pixels?|px|mm|cm|km|kg|mg|lbs?|oz|miles?|mph|"
    r"fps|wpm|rpm|degrees?|rupees?|yen|cents?|pounds?"
)
# Calendar units where "2 days" / "3 weeks" digitize, while "one day" / "one year" stay words.
_CALENDAR_UNITS = r"days|weeks|months|years"
# Units where "one <unit>" is often idiomatic ("wait one second", "just one minute").
_IDIOMATIC_SINGULAR_UNITS = frozenset({"second", "minute", "pound", "cent"})

# Nouns after "twenty second ..." / "thirty second ..." that mean a duration, not 22nd/32nd.
_DURATION_NOUNS = frozenset(
    "delay delays timeout timeouts pause pauses timer timers clip clips "
    "video videos break breaks window windows interval intervals limit limits "
    "cap caps gap gaps buffer buffers wait waits span spans hold holds".split()
)


def _ordinal_suffix(n: int) -> str:
    if 11 <= (n % 100) <= 13:
        return f"{n}th"
    return f"{n}{({1: 'st', 2: 'nd', 3: 'rd'}).get(n % 10, 'th')}"


def _parse_cardinal(phrase: str) -> int | None:
    """Parse an English cardinal phrase (0..999,999) into an int."""
    tokens = [t for t in re.split(r"[\s-]+", phrase.strip().lower()) if t and t != "and"]
    if not tokens:
        return None
    total = 0
    current = 0
    for tok in tokens:
        if tok == "a":
            if current != 0:
                return None
            current = 1
        elif tok in _UNITS:
            current += _UNITS[tok]
        elif tok in _TEENS:
            current += _TEENS[tok]
        elif tok in _TENS:
            current += _TENS[tok]
        elif tok == "hundred":
            current = (current or 1) * 100
        elif tok == "thousand":
            total += (current or 1) * 1_000
            current = 0
        else:
            return None
    return total + current


def _parse_ordinal(phrase: str) -> int | None:
    tokens = [t for t in re.split(r"[\s-]+", phrase.strip().lower()) if t]
    if len(tokens) == 1:
        tok = tokens[0]
        if tok in _ORDINAL_UNITS:
            return _ORDINAL_UNITS[tok]
        if tok in _ORDINAL_TEENS:
            return _ORDINAL_TEENS[tok]
        if tok in _ORDINAL_TENS:
            return _ORDINAL_TENS[tok]
        return None
    if len(tokens) == 2 and tokens[0] in _TENS and tokens[1] in _ORDINAL_UNITS:
        return _TENS[tokens[0]] + _ORDINAL_UNITS[tokens[1]]
    return None


def _format_int(n: int, *, comma: bool = True) -> str:
    if comma and n >= 1_000:
        return f"{n:,}"
    return str(n)


# Compiled patterns for each determinate numeric context.

_DECIMAL_RE = re.compile(
    rf"\b(?P<whole>{_CARDINAL_PHRASE})\s+point\s+"
    rf"(?P<frac>(?:(?:{_UNIT_WORDS_ALT}|oh)(?:\s+(?:{_UNIT_WORDS_ALT}|oh)){{0,5}})|(?:{_TENS_WORDS_ALT})(?:[-\s]+(?:{_UNIT_WORDS_ALT}))?|(?:{_TEEN_WORDS_ALT}))\b",
    re.IGNORECASE,
)

_PERCENT_RE = re.compile(
    rf"\b(?P<num>\d+(?:\.\d+)?|{_CARDINAL_PHRASE})\s+per\s?cent\b",
    re.IGNORECASE,
)

_CURRENCY_DOLLARS_CENTS_RE = re.compile(
    rf"\b(?P<dollars>{_CARDINAL_PHRASE})\s+dollars?\s+(?:and\s+)?(?P<cents>{_SIMPLE_NUM_ALT})\s+cents?\b",
    re.IGNORECASE,
)

_CURRENCY_LARGE_RE = re.compile(
    rf"\b(?P<num>\d+(?:\.\d+)?|{_CARDINAL_PHRASE})\s+(?P<scale>million|billion)\s+(?P<cur>dollars?|euros?)\b",
    re.IGNORECASE,
)

_CURRENCY_SIMPLE_RE = re.compile(
    rf"\b(?P<num>\d+(?:\.\d+)?|{_CARDINAL_PHRASE})\s+(?P<cur>dollars?|euros?)\b",
    re.IGNORECASE,
)

# Clock times: "three thirty pm", "six oh five a.m.", "six pm", "nine o'clock".
_HOUR_ALT = r"twelve|eleven|ten|nine|eight|seven|six|five|four|three|two|one"
_MINUTE_ALT = (
    rf"(?:oh\s+(?:{_UNIT_WORDS_ALT})|"
    rf"(?:twenty|thirty|forty|fifty)(?:[-\s]+(?:{_UNIT_WORDS_ALT}))?|"
    rf"(?:{_TEEN_WORDS_ALT}))"
)
_TIME_HM_RE = re.compile(
    rf"\b(?P<hour>{_HOUR_ALT})\s+(?P<minute>{_MINUTE_ALT})\s*(?P<meridiem>a\.?m\.?|p\.?m\.?)(?!\w)",
    re.IGNORECASE,
)
_TIME_AT_HM_RE = re.compile(
    rf"\b(?P<prep>at|by|around|before|after|until|till|from)\s+"
    rf"(?P<hour>{_HOUR_ALT})\s+"
    rf"(?P<minute>oh\s+(?:{_UNIT_WORDS_ALT})|fifteen|thirty|forty[-\s]+five|twenty|forty|fifty|ten)\b",
    re.IGNORECASE,
)
_TIME_H_RE = re.compile(
    rf"\b(?P<hour>{_HOUR_ALT})\s+(?P<meridiem>a\.?m\.?|p\.?m\.?|o'clock)(?!\w)",
    re.IGNORECASE,
)

# Years: "nineteen eighty four" (1984), "nineteen oh five" (1905),
# "two thousand twenty four" (2024), "in twenty twenty six" (in 2026).
_YEAR_19XX_RE = re.compile(
    rf"\bnineteen\s+(?P<tail>oh\s+(?:{_UNIT_WORDS_ALT})|hundred|(?:{_TENS_WORDS_ALT})(?:[-\s]+(?:{_UNIT_WORDS_ALT}))?|(?:{_TEEN_WORDS_ALT}))\b",
    re.IGNORECASE,
)
_YEAR_2000_RE = re.compile(
    rf"\btwo\s+thousand(?:\s+and)?\s+(?P<tail>(?:{_TENS_WORDS_ALT})(?:[-\s]+(?:{_UNIT_WORDS_ALT}))?|(?:{_TEEN_WORDS_ALT})|(?:{_UNIT_WORDS_ALT}))\b",
    re.IGNORECASE,
)
_YEAR_20XX_CONTEXT_RE = re.compile(
    rf"\b(?P<prep>in|by|since|from|until|before|after|around|circa|year|of)\s+"
    rf"twenty\s+(?P<tail>oh\s+(?:{_UNIT_WORDS_ALT})|(?:twenty|thirty)(?:[-\s]+(?:{_UNIT_WORDS_ALT}))?|(?:{_TEEN_WORDS_ALT}))\b",
    re.IGNORECASE,
)
_YEAR_202X_BARE_RE = re.compile(
    rf"\btwenty\s+twenty[-\s]+(?P<unit>one|two|three|four|five|six|seven|eight|nine)\b",
    re.IGNORECASE,
)

# Date ordinals: "March twenty first" → "March 21st", "fourth of July" → "4th of July".
_MONTH_ORDINAL_RE = re.compile(
    rf"\b(?P<month>{_MONTHS_PATTERN})\s+(?P<ord>{_ORDINAL_PHRASE})\b",
    re.IGNORECASE,
)
_ORDINAL_OF_MONTH_RE = re.compile(
    rf"\b(?P<ord>{_ORDINAL_PHRASE})\s+of\s+(?P<month>{_MONTHS_PATTERN})\b",
    re.IGNORECASE,
)

# Compound ordinals ("twenty first" → "21st"), excluding bare "first"/"second"/"third".
_COMPOUND_ORDINAL_RE = re.compile(
    rf"\b(?P<ord>{_ORDINAL_COMPOUND_ALT})\b(?:\s+(?P<next>[A-Za-z]+))?",
    re.IGNORECASE,
)

# Unit-qualified cardinals ("five minutes", "eight gigabytes", "three days").
_STRICT_UNIT_RE = re.compile(
    rf"\b(?P<num>{_CARDINAL_PHRASE})\s+(?P<unit>{_STRICT_UNITS})\b",
    re.IGNORECASE,
)
_CALENDAR_UNIT_RE = re.compile(
    rf"\b(?P<num>{_CARDINAL_PHRASE})\s+(?P<unit>{_CALENDAR_UNITS})\b",
    re.IGNORECASE,
)

# Standalone compound cardinals (>= 21, or hundred/thousand).
_STANDALONE_COMPOUND_RE = re.compile(
    rf"\b(?P<num>{_COMPOUND_CARDINAL})\b",
    re.IGNORECASE,
)


def _convert_decimal(m: re.Match[str]) -> str:
    whole_raw = m.group("whole")
    # Never convert "a point five" (article "a" is not a whole number).
    if whole_raw.strip().lower() == "a":
        return m.group(0)
    whole = _parse_cardinal(whole_raw)
    if whole is None:
        return m.group(0)
    frac_raw = m.group("frac").strip().lower()
    tokens = [t for t in re.split(r"[\s-]+", frac_raw) if t]
    # Sequence of single digits ("one four" → "14", "oh five" → "05") or a teen/tens number.
    if all(t in _UNITS or t == "oh" for t in tokens):
        frac_str = "".join("0" if t == "oh" else str(_UNITS[t]) for t in tokens)
    else:
        val = _parse_cardinal(frac_raw)
        if val is None:
            return m.group(0)
        frac_str = str(val)
    return f"{whole}.{frac_str}"


def _convert_percent(m: re.Match[str]) -> str:
    raw = m.group("num")
    if raw.strip().lower() == "a":
        return m.group(0)
    if raw[0].isdigit():
        return f"{raw}%"
    val = _parse_cardinal(raw)
    if val is None:
        return m.group(0)
    return f"{_format_int(val)}%"


def _currency_symbol(word: str) -> str:
    return "€" if word.lower().startswith("euro") else "$"


def _convert_dollars_cents(m: re.Match[str]) -> str:
    if m.group("dollars").strip().lower() == "a":
        return m.group(0)
    dollars = _parse_cardinal(m.group("dollars"))
    cents = _parse_cardinal(m.group("cents"))
    if dollars is None or cents is None or not (0 <= cents <= 99):
        return m.group(0)
    return f"${_format_int(dollars)}.{cents:02d}"


def _convert_currency_large(m: re.Match[str]) -> str:
    raw = m.group("num")
    if raw.strip().lower() == "a":
        return m.group(0)
    sym = _currency_symbol(m.group("cur"))
    scale = m.group("scale").lower()
    if raw[0].isdigit():
        return f"{sym}{raw} {scale}"
    val = _parse_cardinal(raw)
    if val is None:
        return m.group(0)
    return f"{sym}{_format_int(val)} {scale}"


def _convert_currency_simple(m: re.Match[str]) -> str:
    raw = m.group("num")
    if raw.strip().lower() == "a":
        return m.group(0)
    sym = _currency_symbol(m.group("cur"))
    if raw[0].isdigit():
        return f"{sym}{raw}"
    val = _parse_cardinal(raw)
    if val is None:
        return m.group(0)
    return f"{sym}{_format_int(val)}"


def _convert_time_hm(m: re.Match[str]) -> str:
    hour = _parse_cardinal(m.group("hour"))
    min_raw = m.group("minute").strip().lower()
    if min_raw.startswith("oh "):
        minute = _parse_cardinal(min_raw[3:])
    else:
        minute = _parse_cardinal(min_raw)
    if hour is None or minute is None or not (1 <= hour <= 12) or not (0 <= minute <= 59):
        return m.group(0)
    return f"{hour}:{minute:02d} {m.group('meridiem')}"


def _convert_time_at_hm(m: re.Match[str]) -> str:
    hour = _parse_cardinal(m.group("hour"))
    min_raw = m.group("minute").strip().lower()
    if min_raw.startswith("oh "):
        minute = _parse_cardinal(min_raw[3:])
    else:
        minute = _parse_cardinal(min_raw)
    if hour is None or minute is None or not (1 <= hour <= 12) or not (0 <= minute <= 59):
        return m.group(0)
    return f"{m.group('prep')} {hour}:{minute:02d}"


def _convert_time_h(m: re.Match[str]) -> str:
    hour = _parse_cardinal(m.group("hour"))
    if hour is None or not (1 <= hour <= 12):
        return m.group(0)
    return f"{hour} {m.group('meridiem')}"


def _parse_year_tail(tail: str) -> int | None:
    low = tail.strip().lower()
    if low == "hundred":
        return 0
    if low.startswith("oh "):
        val = _parse_cardinal(low[3:])
        return val if val is not None and 1 <= val <= 9 else None
    val = _parse_cardinal(low)
    return val if val is not None and 1 <= val <= 99 else None


def _convert_year_19xx(m: re.Match[str]) -> str:
    tail = _parse_year_tail(m.group("tail"))
    if tail is None:
        return m.group(0)
    return f"{1900 + tail}"


def _convert_year_2000(m: re.Match[str]) -> str:
    tail = _parse_year_tail(m.group("tail"))
    if tail is None:
        return m.group(0)
    # Guard: "two thousand five hundred" is 2,500, not the year 2005 + "hundred".
    if re.match(r"\s+hundred\b", m.string[m.end():], re.IGNORECASE):
        return m.group(0)
    return f"{2000 + tail}"


def _convert_year_20xx_context(m: re.Match[str]) -> str:
    tail = _parse_year_tail(m.group("tail"))
    if tail is None or tail > 39:
        return m.group(0)
    return f"{m.group('prep')} {2000 + tail}"


def _convert_year_202x_bare(m: re.Match[str]) -> str:
    unit = _UNITS.get(m.group("unit").lower())
    if unit is None:
        return m.group(0)
    return f"{2020 + unit}"


def _convert_month_ordinal(m: re.Match[str]) -> str:
    val = _parse_ordinal(m.group("ord"))
    if val is None or not (1 <= val <= 31):
        return m.group(0)
    return f"{m.group('month')} {_ordinal_suffix(val)}"


def _convert_ordinal_of_month(m: re.Match[str]) -> str:
    val = _parse_ordinal(m.group("ord"))
    if val is None or not (1 <= val <= 31):
        return m.group(0)
    return f"{_ordinal_suffix(val)} of {m.group('month')}"


def _convert_compound_ordinal(m: re.Match[str]) -> str:
    ord_raw = m.group("ord")
    nxt = m.group("next")
    # "thirty second timeout" means a 30-second timeout, not 32nd!
    if ord_raw.lower().endswith("second") and nxt and nxt.lower() in _DURATION_NOUNS:
        return m.group(0)
    val = _parse_ordinal(ord_raw)
    if val is None:
        return m.group(0)
    suffix = f" {nxt}" if nxt else ""
    return f"{_ordinal_suffix(val)}{suffix}"


def _convert_strict_unit(m: re.Match[str]) -> str:
    raw = m.group("num")
    unit = m.group("unit")
    low_raw = raw.strip().lower()
    if low_raw == "a":
        return m.group(0)
    if low_raw == "one" and unit.lower() in _IDIOMATIC_SINGULAR_UNITS:
        return m.group(0)
    val = _parse_cardinal(raw)
    if val is None:
        return m.group(0)
    return f"{_format_int(val)} {unit}"


def _convert_calendar_unit(m: re.Match[str]) -> str:
    raw = m.group("num")
    if raw.strip().lower() in {"a", "one"}:
        return m.group(0)
    val = _parse_cardinal(raw)
    if val is None or val < 2:
        return m.group(0)
    return f"{_format_int(val)} {m.group('unit')}"


def _convert_standalone_compound(m: re.Match[str]) -> str:
    raw = m.group("num")
    if raw.strip().lower().startswith("a "):
        return m.group(0)
    val = _parse_cardinal(raw)
    if val is None or val < 21:
        return m.group(0)
    return _format_int(val)


def _convert_numbers_segment(text: str) -> str:
    # Order matters: more specific contexts (decimals, currency, times, years,
    # dates, units) run before generic compound cardinals.
    text = _DECIMAL_RE.sub(_convert_decimal, text)
    text = _CURRENCY_DOLLARS_CENTS_RE.sub(_convert_dollars_cents, text)
    text = _CURRENCY_LARGE_RE.sub(_convert_currency_large, text)
    text = _CURRENCY_SIMPLE_RE.sub(_convert_currency_simple, text)
    text = _PERCENT_RE.sub(_convert_percent, text)
    text = _TIME_HM_RE.sub(_convert_time_hm, text)
    text = _TIME_AT_HM_RE.sub(_convert_time_at_hm, text)
    text = _TIME_H_RE.sub(_convert_time_h, text)
    text = _YEAR_19XX_RE.sub(_convert_year_19xx, text)
    text = _YEAR_2000_RE.sub(_convert_year_2000, text)
    text = _YEAR_20XX_CONTEXT_RE.sub(_convert_year_20xx_context, text)
    text = _YEAR_202X_BARE_RE.sub(_convert_year_202x_bare, text)
    text = _MONTH_ORDINAL_RE.sub(_convert_month_ordinal, text)
    text = _ORDINAL_OF_MONTH_RE.sub(_convert_ordinal_of_month, text)
    text = _COMPOUND_ORDINAL_RE.sub(_convert_compound_ordinal, text)
    text = _STRICT_UNIT_RE.sub(_convert_strict_unit, text)
    text = _CALENDAR_UNIT_RE.sub(_convert_calendar_unit, text)
    text = _STANDALONE_COMPOUND_RE.sub(_convert_standalone_compound, text)
    return text


def spoken_numbers_to_digits(text: str) -> str:
    """Convert spoken numbers to digits in bounded, unambiguous contexts.

    Quoted and backticked spans are preserved untouched.
    """
    if not text:
        return text
    parts = _PROTECTED_SPAN_RE.split(text)
    for idx in range(0, len(parts), 2):
        parts[idx] = _convert_numbers_segment(parts[idx])
    return "".join(parts)
