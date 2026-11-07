"""The tested English student request fields and personal-trial eligibility."""
from __future__ import annotations

from functools import lru_cache
import importlib.resources
import json
import unicodedata

from . import formatting


@lru_cache(maxsize=1)
def _stock_modes() -> dict:
    directory = importlib.resources.files("velora_engine").joinpath("modes_builtin")
    rows = [json.loads(path.read_text()) for path in directory.iterdir() if path.name.endswith(".json")]
    return {row["name"].casefold(): row for row in rows}


def build_native_context(gate, config, raw: str, *, app_name=None, entities=None):
    """Return the original full student controls, or None for standard routing.

    Auto language is an explicit English-trial choice, not a claim that script
    inspection can distinguish every language written with Latin letters.
    """
    if not gate.use_llm or gate.romanize or entities:
        return None
    # The student contract has no instruction to preserve the production
    # formatter's protected break markers. Keep explicit layout on standard.
    if "\n" in gate.text or formatting.BREAK_MARK in gate.text:
        return None
    language = config.language.casefold()
    if language not in ("en", "english", "auto") and not language.startswith("en-"):
        return None
    if any(char.isalpha() and not unicodedata.name(char, "").startswith("LATIN ") for char in raw):
        return None
    if any(marker in raw.casefold() for marker in ("<|", "<think>", "</think>")):
        return None
    stock = _stock_modes().get(gate.mode.name.casefold())
    if stock is None or gate.mode.prompt != stock["prompt"] or gate.mode.formatting != stock["formatting"]:
        return None
    instructions = [formatting._STRENGTH_INSTRUCTIONS.get(
        gate.mode.formatting, formatting._STRENGTH_INSTRUCTIONS["full"])]
    if not config.auto_punctuation:
        instructions.append("Do not add terminal punctuation the speaker did not dictate.")
    if gate.reason == "smart_terminal":
        instructions.append(formatting.SMART_TERMINAL_PROMPT)
    contextual = []
    formatting._append_contextual_prompt_parts(
        contextual, gate.mode, config, app_name, gate.category, None)
    instructions.extend(part for part in contextual if not part.startswith("Vocabulary —"))
    context = {
        "mode": gate.mode.name.lower(), "language": config.language,
        "romanize": False, "instructions": "\n\n".join(instructions),
        "vocabulary": list(dict.fromkeys(config.global_vocabulary + gate.mode.vocabulary)),
    }
    if any(marker in json.dumps(context, ensure_ascii=False).casefold()
           for marker in ("<|", "<think>", "</think>")):
        return None
    return context
