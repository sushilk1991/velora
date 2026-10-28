#!/usr/bin/env python3
"""The owner's term set: archived takes that contain the owner's own words.

Run from ``engine/`` with the engine venv (CPU only)::

    python ../docs/research/2026-10-28-lfm3-family/asr_set.py OUT.jsonl

A take enters when its kept text (history `final`) contains a curated term
and its audio is archived. Its reference is the set of canonical terms in
that text, with Whisper's learned misspellings folded onto the word the
owner said ("Valora" → Velora, "Cloud Code" → Claude Code).

Bias, stated up front: the reference comes from text that Whisper (with
the glossary) and cleanup produced. A term Whisper wrote some other way
and nobody fixed is missing from the reference, so Whisper's recall here
is an upper bound and a candidate's is fair only relative to it.

Only ids, paths, durations and term lists are written: no transcript text.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

import soundfile as sf

# Canonical term → spellings that count as that term in a reference (from
# ~/.velora/auto_learned.json: Whisper misspellings it learned). Hypotheses
# are scored on the canonical spelling only (hits()).
PUBLIC_TERMS = {
    "Velora": ("Velora", "Valora"),
    "Claude Code": ("Claude Code", "Cloud Code"),
    "Claude": ("Claude",),
    "Codex": ("Codex",),
    "sub-agents": ("sub-agents", "sub-agent", "subagents", "subagent"),
    "Gemini": ("Gemini",),
    "Xcode": ("Xcode",),
    "TestFlight": ("TestFlight",),
    "App Store": ("App Store",),
    "WhatsApp": ("WhatsApp",),
    "YouTube": ("YouTube",),
    "Instagram": ("Instagram",),
    "Telegram": ("Telegram",),
    "Stripe": ("Stripe",),
    "OpenAI": ("OpenAI",),
    "iCloud": ("iCloud",),
    "iPhone": ("iPhone",),
    "Whisper": ("Whisper",),
    "Qwen": ("Qwen",),
    "MLX": ("MLX",),
}
# The owner's own names (apps, people) live outside this public repo: a JSON
# object {canonical: [variants]} at $VELORA_BENCH_OWNER_TERMS, read here
# and by score_asr.py. Without it the set holds the public terms only.
OWNER_TERMS_ENV = "VELORA_BENCH_OWNER_TERMS"


def _owner_terms() -> dict[str, tuple[str, ...]]:
    path = os.environ.get(OWNER_TERMS_ENV)
    if not path:
        return {}
    return {k: tuple(v) for k, v in json.loads(Path(path).read_text()).items()}


TERMS = {**PUBLIC_TERMS, **_owner_terms()}
# Spelling-agnostic match: case, hyphens and inner spaces ignored, so
# "sub agents" and "subagents" both hit sub-agents.
MIN_S, MAX_S = 2.0, 30.0
MAX_TAKES = 160


def _squash(text: str) -> str:
    return re.sub(r"[\s\-]+", "", text.casefold())


def terms_in(text: str, accept_variants: bool = True) -> list[str]:
    """Canonical terms whose spelling (or accepted variant) appears in text,
    on word boundaries, once per term."""
    found = []
    for canonical, spellings in TERMS.items():
        options = spellings if accept_variants else (canonical,)
        for spelling in options:
            pattern = r"(?<![\w])" + r"[\s\-]*".join(
                re.escape(part) for part in re.split(r"[\s\-]+", spelling)) + r"(?![\w])"
            if re.search(pattern, text, re.IGNORECASE):
                found.append(canonical)
                break
    # "Claude" inside "Claude Code" is one mention, not two.
    if "Claude Code" in found and "Claude" in found:
        found.remove("Claude")
    return found


def hits(reference: list[str], hypothesis: str) -> int:
    """Reference terms the hypothesis wrote, canonical spelling required
    (a hypothesis writing "Valora" has not written Velora)."""
    said = set(terms_in(hypothesis, accept_variants=False))
    if "Claude Code" in reference and "Claude Code" not in said:
        said.discard("Claude")
    return sum(term in said for term in reference)


def main() -> int:
    home = Path.home() / ".velora"
    db = sqlite3.connect(home / "history.sqlite3")
    rows = db.execute(
        "select id, final, audio_path, app_name from dictations where final != '' order by id"
    ).fetchall()
    out = []
    for take_id, final, audio_path, app in rows:
        path = home / "audio" / (audio_path or "")
        if not audio_path or not path.exists():
            continue
        reference = terms_in(final)
        if not reference:
            continue
        info = sf.info(str(path))
        if not MIN_S <= info.duration <= MAX_S:
            continue
        out.append({"id": f"take{take_id}", "path": str(path), "seconds": round(info.duration, 2),
                    "app": app, "terms": reference})
    out = out[-MAX_TAKES:]  # the newest takes: today's mic, today's vocabulary
    with open(sys.argv[1], "w") as stream:
        for row in out:
            stream.write(json.dumps(row) + "\n")
    counts: dict[str, int] = {}
    for row in out:
        for term in row["terms"]:
            counts[term] = counts.get(term, 0) + 1
    print(json.dumps({"takes": len(out), "term_mentions": sum(counts.values()),
                      "seconds": round(sum(r["seconds"] for r in out)), "terms": counts}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
