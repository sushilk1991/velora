"""Compiled cleanup prompt architecture (V-06 / V-07 / V-09 / V-10 / V-11)."""

from .compiler import (
    CORE_SYSTEM_PREFIX,
    MAX_FEW_SHOT_EXAMPLES,
    CompiledPrompt,
    compile_prompt,
)
from .cues import TranscriptCues, detect_cues
from .tables import EMOJI_TABLE, HOMOPHONE_TABLE, TAKE_BACK_PHRASES

__all__ = [
    "CORE_SYSTEM_PREFIX",
    "CompiledPrompt",
    "EMOJI_TABLE",
    "HOMOPHONE_TABLE",
    "MAX_FEW_SHOT_EXAMPLES",
    "TAKE_BACK_PHRASES",
    "TranscriptCues",
    "compile_prompt",
    "detect_cues",
]
