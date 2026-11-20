"""Prompt snapshot gate (V-11) wired into `make test-engine`.

Renders the compiled cleanup prompt (active rules, system prompt, and matched
few-shot chat turns) for each built-in LLM mode across five representative
transcripts. Any unreviewed drift fails the test with a unified diff.

Regenerate deliberately after an intentional prompt edit:
    UPDATE_PROMPT_SNAPSHOTS=1 uv run --directory engine pytest tests/test_prompt_snapshots.py
"""

from __future__ import annotations

import difflib
import os
from pathlib import Path

import pytest

from velora_engine.config import Config
from velora_engine.formatting import compile_system_prompt

SNAPSHOT_DIR = Path(__file__).parent / "snapshots" / "prompts"

MODES = ("Default", "Message", "Email", "Note", "Code")

REPRESENTATIVE_TRANSCRIPTS: tuple[tuple[str, str], ...] = (
    (
        "plain_prose",
        "we should probably move the quarterly planning meeting to next Tuesday afternoon",
    ),
    (
        "self_correction_and_take_back",
        "the budget looks fine actually scratch that tell Priya we need another pass on pricing",
    ),
    (
        "spoken_punctuation_and_homophones",
        "the car breaks failed full stop check the grocery isle before leaving",
    ),
    (
        "counted_list_with_skipped_ordinal",
        "three errands today first return the parcel second collect the keys fourth pick up medicine",
    ),
    (
        "emoji_and_counter_example",
        "great job on the launch rocket emoji we still need better emoji support",
    ),
)


def _render_mode_snapshot(mode_name: str, config: Config) -> str:
    mode = config.mode_by_name(mode_name)
    assert mode is not None, f"missing built-in mode {mode_name!r}"
    category = {"Message": "chat", "Email": "email", "Note": "notes", "Code": "code"}.get(
        mode_name
    )
    sections: list[str] = [f"# Prompt snapshot: {mode.name} (formatting={mode.formatting})"]
    for case_name, transcript in REPRESENTATIVE_TRANSCRIPTS:
        compiled = compile_system_prompt(
            mode,
            config,
            app_name=None,
            category=category,
            entities=None,
            transcript=transcript,
        )
        rules_line = ", ".join(compiled.active_rules) or "(none)"
        lines = [
            f"## {case_name}",
            f"transcript: {transcript}",
            f"active_rules: {rules_line}",
            "--- system_prompt ---",
            compiled.system_prompt,
            f"--- examples ({len(compiled.examples)}) ---",
        ]
        for idx, (ex_user, ex_assistant) in enumerate(compiled.examples, 1):
            lines.append(f"[{idx}] U: {ex_user}")
            lines.append(f"[{idx}] A: {ex_assistant}")
        sections.append("\n".join(lines))
    return "\n\n".join(sections) + "\n"


@pytest.mark.parametrize("mode_name", MODES)
def test_prompt_snapshot_matches_golden(mode_name: str, home: Path):
    config = Config(home)
    rendered = _render_mode_snapshot(mode_name, config)
    snap_path = SNAPSHOT_DIR / f"{mode_name.lower()}.txt"

    if os.environ.get("UPDATE_PROMPT_SNAPSHOTS") == "1":
        SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
        snap_path.write_text(rendered, encoding="utf-8")
        return

    assert snap_path.is_file(), (
        f"Missing prompt snapshot {snap_path}. "
        "Run with UPDATE_PROMPT_SNAPSHOTS=1 to generate."
    )
    expected = snap_path.read_text(encoding="utf-8")
    if rendered != expected:
        diff = "".join(
            difflib.unified_diff(
                expected.splitlines(keepends=True),
                rendered.splitlines(keepends=True),
                fromfile=str(snap_path),
                tofile="rendered",
            )
        )
        pytest.fail(
            "Prompt snapshot drifted (run with UPDATE_PROMPT_SNAPSHOTS=1 if intentional):\n"
            + diff
        )
