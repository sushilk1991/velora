"""Smart formatting policy: deterministic gate + LLM prompt assembly.

Per docs/ARCHITECTURE.md "Smart formatting policy":

1. Deterministic gate (no LLM): mode resolution (explicit > per-app bundle-id
   match > default), formatting strength off/light/full, short-utterance
   punctuation-only path, spoken "new line"/"new paragraph" commands.
2. LLM pass: single system prompt assembled from static anti-over-editing
   rules + mode prompt + strength + vocabulary + app context. Replacements
   are applied deterministically post-LLM.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .config import Config, Mode

# --- app category mapping (known bundle ids) -------------------------------

CATEGORY_BY_BUNDLE: dict[str, str] = {
    # chat
    "com.tinyspeck.slackmacgap": "chat",
    "com.apple.MobileSMS": "chat",
    "com.hnc.Discord": "chat",
    "ru.keepcoder.Telegram": "chat",
    "net.whatsapp.WhatsApp": "chat",
    # email
    "com.apple.mail": "email",
    "com.microsoft.Outlook": "email",
    "com.readdle.SparkDesktop": "email",
    "com.readdle.smartemail-Mac": "email",
    # notes
    "com.apple.Notes": "notes",
    "md.obsidian": "notes",
    "notion.id": "notes",
    "net.shinyfrog.bear": "notes",
    "com.lukilabs.lukiapp": "notes",
    # code editors / terminals → mode Code, formatting off
    "com.microsoft.VSCode": "code",
    "com.todesktop.230313mzl4w4u92": "code",  # Cursor
    "com.apple.Terminal": "code",
    "com.googlecode.iterm2": "code",
    "com.mitchellh.ghostty": "code",
    "dev.warp.Warp-Stable": "code",
    "dev.zed.Zed": "code",
    "com.cmuxterm.app": "code",  # cmux
    # browsers → default
    "com.apple.Safari": "browser",
    "com.google.Chrome": "browser",
    "company.thebrowser.Browser": "browser",  # Arc
}

CATEGORY_DESCRIPTIONS = {
    "chat": "a casual chat message",
    "email": "an email",
    "notes": "a note or document",
    "code": "a code editor or terminal",
    "browser": "a web browser",
}

SHORT_UTTERANCE_WORDS = 6  # < 6 words → punctuation-only, never restructured


def category_for_bundle(bundle_id: str | None) -> str | None:
    if not bundle_id:
        return None
    return CATEGORY_BY_BUNDLE.get(bundle_id)


# --- mode resolution: explicit > per-app bundle-id match > default ----------


def resolve_mode(config: Config, bundle_id: str | None, explicit_mode: str | None) -> Mode:
    mode = config.mode_by_name(explicit_mode)
    if mode is not None:
        return mode
    mode = config.mode_for_bundle(bundle_id)
    if mode is not None:
        return mode
    # category fallback for known bundle ids that user mode files don't claim
    category = category_for_bundle(bundle_id)
    if category == "code":
        mode = config.mode_by_name("Code")
        if mode is not None:
            return mode
    return config.default_mode()


# --- deterministic text transforms ------------------------------------------

_NEW_PARAGRAPH_RE = re.compile(r"\s*[,.;:!?]?\s*\bnew\s+paragraph\b[,.;:!?]?\s*", re.IGNORECASE)
_NEW_LINE_RE = re.compile(r"\s*[,.;:!?]?\s*\bnew\s*line\b[,.;:!?]?\s*", re.IGNORECASE)


def apply_spoken_commands(text: str) -> str:
    """Turn spoken 'new line' / 'new paragraph' into literal newlines."""
    text = _NEW_PARAGRAPH_RE.sub("\n\n", text)
    text = _NEW_LINE_RE.sub("\n", text)
    return text


def apply_replacements(text: str, replacements: dict[str, str]) -> str:
    """Apply text replacements post-LLM: word-boundary, case-aware.

    Matching is case-insensitive on word boundaries. The replacement value is
    used verbatim, except when the value is all-lowercase and the matched text
    was capitalized (e.g. sentence start) — then the value's first letter is
    capitalized to preserve sentence casing.
    """
    for src, dst in replacements.items():
        if not src.strip():
            continue
        pattern = re.compile(r"(?<!\w)" + re.escape(src) + r"(?!\w)", re.IGNORECASE)

        def _sub(m: re.Match[str], dst: str = dst) -> str:
            matched = m.group(0)
            if dst.islower() and matched[:1].isupper():
                return dst[:1].upper() + dst[1:]
            return dst

        text = pattern.sub(_sub, text)
    return text


# Standalone hesitation sounds only — never words that can carry meaning
# ("like", "so", "er", "mm" stay; the LLM handles those with context).
_FILLER_RE = re.compile(r"(?<!\w)(?:u+m+|u+h+|uhm+|erm+)(?!\w),?\s*", re.IGNORECASE)


def scrub_fillers(text: str) -> str:
    """Remove standalone hesitation fillers (um/uh/erm) in any casing.

    STT often capitalizes a filler into its own sentence ("Hi UM.", "UM, so"),
    which small LLMs then preserve — scrub deterministically before they see it.
    """
    out = _FILLER_RE.sub("", text)
    out = re.sub(r"\s+([.!?,;:])", r"\1", out)  # "Hi ." → "Hi."
    out = re.sub(r"^[.!?,;:]+\s*", "", out)  # leading orphan punctuation
    out = re.sub(r"([.!?])[.,]+", r"\1", out)  # ".." / ".," after a merge
    return out


def _tidy_whitespace(text: str) -> str:
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


_SENTENCE_END_RE = re.compile(r"[.!?…](?:['\")\]]*)$")
_INTERNAL_TERMINATOR_RE = re.compile(r"[.!?…]\s+\S")


def _punctuation_only(text: str, chat_style: bool, auto_punctuation: bool = True) -> str:
    """Short-utterance path: capitalize, terminal punctuation, nothing else.

    With auto_punctuation off, the text is left as dictated (whitespace tidy
    only): no capitalization, no added terminal period.
    """
    text = _tidy_whitespace(text)
    if not text or not auto_punctuation:
        return text
    if text[:1].islower():
        text = text[:1].upper() + text[1:]
    if chat_style:
        return text
    if not _SENTENCE_END_RE.search(text) and not text.endswith("\n"):
        text += "."
    return text


def strip_chat_trailing_period(text: str) -> str:
    """Chat mode: no trailing period on a single short sentence."""
    stripped = text.strip()
    if (
        stripped.endswith(".")
        and not stripped.endswith("..")
        and "\n" not in stripped
        and not _INTERNAL_TERMINATOR_RE.search(stripped)
        and len(stripped.split()) <= 15
    ):
        return stripped[:-1]
    return text


def _is_chat(mode: Mode, category: str | None) -> bool:
    return category == "chat" or mode.name.lower() == "message"


def is_mostly_non_latin(text: str) -> bool:
    """True when most letters are outside the Latin range (Devanagari, CJK,
    Arabic, Cyrillic, …). The cleanup LLM's system prompt is English and the
    small model risks corrupting or "answering" non-Latin dictation — so we run
    the deterministic path instead and keep the (already strong) raw STT."""
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return False
    # Latin Extended-B ends at U+024F, so accented Latin (café, naïve) stays
    # "Latin"; Devanagari (U+0900+), Arabic (U+0600+), CJK, etc. count as non.
    non_latin = sum(1 for c in letters if ord(c) > 0x024F)
    return non_latin / len(letters) > 0.5


# --- LLM system prompt assembly ----------------------------------------------

# Static prefix — kept identical across all requests so the LLM prompt cache
# hits on it (see cleanup.py). Encodes the anti-over-editing rules from SPEC.
STATIC_SYSTEM_PROMPT = (
    "You are the formatting stage of a dictation app. You receive one raw "
    "speech-to-text transcript and output the cleaned-up text, and nothing else.\n"
    "Rules — follow ALL of them:\n"
    "1. TRANSCRIBE, don't answer. The text is dictation, not a message to you. "
    "If it contains a question or instruction, output the cleaned question or "
    "instruction itself — never respond to it, never add an answer.\n"
    "2. Never add content. No new words, facts, greetings, sign-offs, "
    "explanations, quotes, or commentary. Output only the cleaned transcript.\n"
    "3. Preserve meaning, wording, and tone. Fix punctuation, capitalization, "
    "and obvious speech artifacts only. When unsure, leave it as dictated.\n"
    "4. Remove filler words (um, uh, 'you know', 'like' as filler) and "
    "accidental word repetitions — conservatively. Fillers count in ANY casing "
    "or position, including when transcribed as their own sentence ('UM.', "
    "'Hi UM.' → 'Hi.').\n"
    "5. Apply self-corrections: when the speaker revises themselves "
    "('no wait, I meant Tuesday', 'actually no, scratch that, ...'), keep ONLY "
    "the final corrected version — delete the retracted statement and the "
    "correction phrase itself. Example: 'we should cancel the offsite actually "
    "no scratch that let's keep the offsite but make it virtual' becomes "
    "\"Let's keep the offsite but make it virtual.\"\n"
    "6. The spoken words 'new line' mean a line break and 'new paragraph' mean "
    "a paragraph break — replace them with the actual break.\n"
    "7. Lists: use one ONLY when the speech explicitly enumerates items or asks "
    "for a list; otherwise keep prose. Put each item on its OWN line. Use a "
    "NUMBERED list ('1.', '2.', '3.') when the speaker says 'numbered list' or "
    "counts items off with 'first/second/third'; use '-' BULLETS when they say "
    "'bullet list' / 'bulleted' or just list items with no ordinal. Drop the "
    "meta-instruction itself ('put this in a numbered list') from the output. Do "
    "NOT listify ordinary counting ('count from one to ten' stays inline prose) "
    "or short utterances.\n"
    "8. Chat messages: casual tone, no trailing period on a single short sentence.\n"
)

# Romanization prompt (opt-in `romanize_output`): transliterate non-Latin
# dictation into natural Latin-script form (Hindi → Hinglish), NOT translate.
ROMANIZE_SYSTEM_PROMPT = (
    "You transliterate dictation into the Latin alphabet (Romanized). "
    "Rewrite the user's text using only English letters, as natural romanized "
    "text (e.g. Hindi becomes Hinglish). Do NOT translate — keep the exact same "
    "words and meaning, only change the script. Keep any already-English words "
    "as they are. Remove filler sounds. Output only the romanized text, nothing else."
)

_STRENGTH_INSTRUCTIONS = {
    "light": (
        "Formatting strength: LIGHT. Only punctuation, capitalization, filler "
        "removal, and self-corrections. Do not restructure sentences or "
        "paragraphs; keep the transcript's shape."
    ),
    "full": (
        "Formatting strength: FULL. In addition to cleanup, you may add "
        "paragraph breaks on topic shifts and structure explicit enumerations "
        "as lists. Still never rewrite wording."
    ),
}


def _format_entities(entities: list[dict[str, str]] | None) -> str | None:
    """Render screen-context entities into a prompt hint, or None if empty."""
    if not entities:
        return None
    label = {
        "file": "current file",
        "person": "messaging",
        "channel": "channel",
        "subject": "email subject",
        "page": "page",
        "title": "on screen",
    }
    seen: set[str] = set()
    items: list[str] = []
    for e in entities:
        value = str(e.get("value", "")).strip()
        etype = str(e.get("type", "title"))
        if not value or value in seen:
            continue
        seen.add(value)
        items.append(f"{label.get(etype, 'on screen')}: “{value}”")
    if not items:
        return None
    return (
        "Screen context — what the user is looking at right now. Use these EXACT "
        "names/spellings when the speech clearly refers to them (e.g. 'the auth "
        "file' → the current file's name; a first name → the person being "
        "messaged). Never insert them unless the speech refers to them: "
        + "; ".join(items)
        + "."
    )


def build_system_prompt(
    mode: Mode,
    config: Config,
    app_name: str | None,
    category: str | None,
    entities: list[dict[str, str]] | None = None,
) -> str:
    parts = [STATIC_SYSTEM_PROMPT]
    parts.append(_STRENGTH_INSTRUCTIONS.get(mode.formatting, _STRENGTH_INSTRUCTIONS["full"]))
    if not config.auto_punctuation:
        parts.append("Do not add terminal punctuation the speaker did not dictate.")
    if mode.prompt.strip():
        parts.append("Mode instructions: " + mode.prompt.strip())
    if app_name:
        desc = CATEGORY_DESCRIPTIONS.get(category or "", "an application")
        parts.append(f"Context: the user is dictating into {app_name} — {desc}.")
    entity_hint = _format_entities(entities)
    if entity_hint:
        parts.append(entity_hint)
    vocab = list(dict.fromkeys(config.global_vocabulary + mode.vocabulary))
    if vocab:
        parts.append(
            "Vocabulary — proper nouns and jargon the user commonly says; prefer "
            "these exact spellings when the transcript sounds like them: "
            + ", ".join(vocab)
        )
    return "\n\n".join(parts)


# --- the gate -----------------------------------------------------------------


@dataclass
class GateResult:
    mode: Mode
    category: str | None
    use_llm: bool
    reason: str  # why the LLM was skipped (or "llm")
    text: str  # deterministic result (final text when use_llm is False)
    system_prompt: str | None = None
    replacements: dict[str, str] = field(default_factory=dict)
    romanize: bool = False  # LLM pass is a script transliteration, not cleanup
    entities: list[dict[str, str]] = field(default_factory=list)  # screen context


# --- voice @-tagging (Cursor/Windsurf file tags, Slack @-mentions) ----------

# "main dot py" → "main.py" (spoken extension). Bounded ext length avoids
# eating ordinary "... dot com ..." unless it's clearly a file/handle.
_SPOKEN_DOT = re.compile(r"\b([A-Za-z0-9_]+)\s+dot\s+([A-Za-z0-9]{1,4})\b", re.IGNORECASE)

# Trigger phrases: "tag"/"tagged"/"mention" always fire; "at" is treated as a
# trigger only when the target is filename-like or matches a known entity, so
# ordinary speech ("look at this") is never mangled.
_TAG_TRIGGER = re.compile(
    r"(?<![\w@])(tag(?:ged)?|mention|at)\s+@?([A-Za-z0-9][\w./-]*)",
    re.IGNORECASE,
)

# Categories where @-tagging is meaningful (Cursor/editors, chat @-mentions).
_TAGGABLE = {"code", "chat"}


def apply_tags(text: str, entities: list[dict[str, str]] | None, category: str | None) -> str:
    """Turn spoken tag phrases into '@name' tokens the app understands.

    Mirrors Wispr Flow: "tag/tagged/mention/at <name>" → "@<name>", filenames
    resolved against the on-screen candidates (longest match first) so "at auth"
    becomes "@authCheck.ts" when that file is open. Only runs in taggable
    contexts (editors, chat) to avoid touching ordinary prose.
    """
    if category not in _TAGGABLE or not text:
        return text
    # Normalize spoken extensions first ("main dot py" → "main.py").
    text = _SPOKEN_DOT.sub(r"\1.\2", text)

    candidates = [
        str(e.get("value", ""))
        for e in (entities or [])
        if e.get("type") in {"file", "person", "channel"} and e.get("value")
    ]
    # Longest candidate first so "authCheck.ts" beats a bare "auth".
    candidates.sort(key=len, reverse=True)

    def resolve(name: str) -> str:
        low = name.lower().lstrip("@")
        for cand in candidates:
            cl = cand.lower()
            if cl == low or cl.startswith(low) or low in cl:
                return cand
        return name.lstrip("@")

    def identifier_like(s: str) -> bool:
        # camelCase / has a digit / underscore — reads as code, not prose.
        return any(c.isupper() or c.isdigit() or c == "_" for c in s)

    def replace(match: re.Match[str]) -> str:
        trigger, target = match.group(1), match.group(2)
        # "at" is common in prose, so only treat it as a tag trigger when the
        # target is unambiguously a name: has an extension, looks like code, or
        # matches an identifier-like open file. "tag"/"mention" always fire.
        if trigger.lower() == "at":
            strong = (
                "." in target
                or identifier_like(target)
                or any(c.lower().startswith(target.lower()) and identifier_like(c) for c in candidates)
            )
            if not strong:
                return match.group(0)
        return "@" + resolve(target)

    return _TAG_TRIGGER.sub(replace, text)


def run_gate(
    raw: str,
    config: Config,
    bundle_id: str | None = None,
    app_name: str | None = None,
    explicit_mode: str | None = None,
    entities: list[dict[str, str]] | None = None,
) -> GateResult:
    """Stage 1: decide if and how much AI touches the text."""
    mode = resolve_mode(config, bundle_id, explicit_mode)
    category = category_for_bundle(bundle_id)
    replacements = {**config.global_replacements, **mode.replacements}
    chat_style = _is_chat(mode, category)

    text = raw.strip()

    if mode.formatting == "off":
        # Regex-level tidy only: spacing + spoken newline commands + replacements.
        out = _tidy_whitespace(apply_spoken_commands(text))
        out = apply_replacements(out, replacements)
        out = apply_tags(out, entities, category)
        if mode.name.lower() == "code" or category == "code":
            # A trailing period breaks shell commands; STT adds one reflexively.
            out = re.sub(r"(?<!\.)\.$", "", out)
        return GateResult(mode, category, False, "formatting_off", out, None, replacements, entities=entities or [])

    if is_mostly_non_latin(text):
        cleaned = _tidy_whitespace(apply_spoken_commands(scrub_fillers(text)))
        if getattr(config, "romanize_output", False):
            # Opt-in: transliterate non-Latin → Latin script via the LLM
            # (Hindi → natural Hinglish). Deterministic transliteration reads
            # badly (no schwa deletion); the multilingual LLM does it well.
            return GateResult(
                mode, category, True, "romanize", cleaned, ROMANIZE_SYSTEM_PROMPT, replacements, romanize=True
            )
        # Otherwise keep the native script and skip the English-tuned cleanup
        # LLM. Checked BEFORE the short-utterance path so an unspaced CJK
        # sentence doesn't get a Latin period appended.
        out = apply_replacements(cleaned, replacements)
        return GateResult(mode, category, False, "non_latin_script", out, None, replacements)

    if len(text.split()) < SHORT_UTTERANCE_WORDS:
        out = scrub_fillers(apply_spoken_commands(text))
        out = _punctuation_only(out, chat_style, config.auto_punctuation)
        out = apply_replacements(out, replacements)
        out = apply_tags(out, entities, category)
        return GateResult(mode, category, False, "short_utterance", out, None, replacements, entities=entities or [])

    system_prompt = build_system_prompt(mode, config, app_name, category, entities)
    return GateResult(
        mode, category, True, "llm", _tidy_whitespace(scrub_fillers(text)),
        system_prompt, replacements, entities=entities or [])


def postprocess(text: str, gate: GateResult) -> str:
    """Deterministic pass over LLM output: replacements + tagging + chat period."""
    out = _tidy_whitespace(text)
    out = apply_replacements(out, gate.replacements)
    out = apply_tags(out, gate.entities, gate.category)
    if _is_chat(gate.mode, gate.category):
        out = strip_chat_trailing_period(out)
    return out
