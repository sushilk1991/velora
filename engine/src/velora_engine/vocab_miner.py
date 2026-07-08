"""Idle vocabulary miner (smartness-v2 §4) — the local LLM works when nothing
is happening: it extracts proper nouns, product/people/project names, and
technical jargon from recent dictation history into a persistent
auto-vocabulary the cleanup prompt and the whisper glossary then feed on.

All local: reads ~/.velora/history.sqlite3 (read-only), writes
~/.velora/auto_learned.json. The FILE FORMAT IS PINNED — the Swift app reads it
(Settings list) and writes it (deleting a term moves it to `banned`), so:
unknown keys must be preserved, writes are atomic and 0600, and a banned term
must never be re-added.

Anti-hallucination stance: the LLM only NOMINATES terms; every nomination is
validated deterministically (must literally occur in the batch text, shape
checks, stopwords) before it can even become a candidate. Candidates are
promoted to active terms once seen in ≥2 distinct dictations.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
from pathlib import Path
from typing import Awaitable, Callable

log = logging.getLogger("velora.vocab")

BATCH_ROWS = 8  # history rows mined per step (one ~0.5s generation per idle window)
BATCH_CHAR_CAP = 2000  # cap on the concatenated transcripts sent to the LLM
MAX_TERM_WORDS = 4
MAX_TERM_CHARS = 40
MAX_LINES = 10  # nominations considered per generation, mirrors the prompt cap
PROMOTE_AT = 2  # distinct dictations a candidate must appear in
MAX_TERMS = 100
MAX_CANDIDATES = 300
MAX_BANNED = 500  # matches the app's cap so neither side grows the list unbounded

EXTRACTION_SYSTEM_PROMPT = (
    "You extract vocabulary from dictation transcripts. List the proper nouns, "
    "product names, people or project names, and technical jargon that appear "
    "in the user's text. One term per line, at most 10 lines, exactly as "
    "spelled in the text. No commentary, no numbering. If there are none, "
    "output nothing."
)

# Junky capitalized starts the LLM sometimes nominates ("I", "The", ...) —
# rejected as single-word terms regardless of casing.
_STOPWORDS = frozenset(
    "i the a an it we you he she they this that and or but so if then is are was "
    "were be been am do does did not no yes ok okay hi hey hello thanks thank "
    "please today tomorrow yesterday".split()
)


def _term_pattern(term: str) -> re.Pattern[str]:
    """Case-insensitive word-boundary occurrence check for a (multi-word) term."""
    return re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)


def clean_line(line: str) -> str:
    """Strip list markers/quotes the LLM tends to wrap nominations in."""
    line = line.strip()
    line = re.sub(r"^(?:[-*•]|\d+[.)])\s*", "", line)
    return line.strip().strip("\"'“”‘’").strip()


def validate_term(term: str, batch_text: str, banned: set[str], existing: set[str]) -> bool:
    """Deterministic anti-hallucination gate for one LLM-nominated term.

    `banned`/`existing` are lowercase sets. A term must literally occur in the
    batch text (word-boundary, case-insensitive) — the direct test that the
    LLM didn't invent it — and must LOOK like a name: single all-lowercase
    dictionary-ish words are rejected (they'd poison the glossary), so a
    single-word term needs a capital, digit, or dot/underscore/hyphen.
    """
    if not term or len(term) > MAX_TERM_CHARS:
        return False
    words = term.split()
    if not 1 <= len(words) <= MAX_TERM_WORDS:
        return False
    if not any(c.isalpha() for c in term):
        return False
    low = term.lower()
    if low in banned or low in existing:
        return False
    if len(words) == 1:
        if low in _STOPWORDS:
            return False
        if not (any(c.isupper() or c.isdigit() for c in term) or any(c in "._-" for c in term)):
            return False
    return bool(_term_pattern(term).search(batch_text))


class VocabMiner:
    """One `step()` mines a batch of history rows; the server loops it across
    idle windows. `generate(system_prompt, user_text) -> raw LLM text` is
    injected so tests never need a model."""

    def __init__(self, home: Path, generate: Callable[[str, str], Awaitable[str]]) -> None:
        self.home = home
        self._generate = generate
        # How many terms the last step promoted — the server reloads config
        # (and logs counts only; never term values) when this is non-zero.
        self.last_step_new_terms = 0

    @property
    def _state_path(self) -> Path:
        return self.home / "auto_learned.json"

    @property
    def _history_path(self) -> Path:
        return self.home / "history.sqlite3"

    # ---- state io -------------------------------------------------------

    def _read_state(self) -> dict:
        try:
            data = json.loads(self._state_path.read_text())
            if isinstance(data, dict):
                return data
        except FileNotFoundError:
            pass
        except Exception as exc:  # noqa: BLE001 — corrupt file: start fresh, don't crash
            log.warning("auto_learned.json unreadable (%s); starting fresh", exc)
        return {}

    def _write_state(self, state: dict) -> None:
        """Atomic 0600 write, RE-READING the file first: the app may have
        banned a term while this step was running — its `banned` additions are
        unioned in and honored, and any app-side keys we don't know about are
        preserved (format is shared with Swift)."""
        fresh = self._read_state()
        banned: list[str] = []
        for b in list(fresh.get("banned") or []) + list(state.get("banned") or []):
            b = str(b)
            if b and b not in banned:
                banned.append(b)
        if len(banned) > MAX_BANNED:
            banned = banned[-MAX_BANNED:]
        banned_low = {b.lower() for b in banned}
        out = dict(fresh)  # unknown keys pass through untouched
        out["version"] = 1
        out["checkpoint_id"] = state.get("checkpoint_id", 0)
        out["terms"] = [t for t in state.get("terms", []) if str(t).lower() not in banned_low]
        out["candidates"] = {
            k: v for k, v in (state.get("candidates") or {}).items() if str(k).lower() not in banned_low
        }
        out["banned"] = banned
        tmp = self._state_path.with_name(self._state_path.name + ".tmp")
        tmp.write_text(json.dumps(out, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        tmp.replace(self._state_path)

    # ---- history --------------------------------------------------------

    def _read_rows(self, checkpoint_id: int) -> tuple[list[tuple[int, str]], bool]:
        """Up to BATCH_ROWS `(id, final)` rows past the checkpoint, plus a
        more-rows-remain flag. Missing db/table (fresh install, app not run
        yet) is a quiet no-op, never an error."""
        if not self._history_path.exists():
            return [], False
        try:
            # mode=ro: the app owns this database; the miner must never create
            # or lock it.
            conn = sqlite3.connect(f"file:{self._history_path}?mode=ro", uri=True)
            try:
                cur = conn.execute(
                    "SELECT id, final FROM dictations WHERE id > ? ORDER BY id LIMIT ?",
                    (checkpoint_id, BATCH_ROWS + 1),
                )
                fetched = [(int(r[0]), str(r[1] or "")) for r in cur.fetchall()]
            finally:
                conn.close()
        except sqlite3.Error as exc:
            log.info("history unavailable for mining (%s)", exc)
            return [], False
        return fetched[:BATCH_ROWS], len(fetched) > BATCH_ROWS

    # ---- the mining step --------------------------------------------------

    async def step(self) -> bool:
        """Mine one batch. Returns True when more unmined rows remain (the
        caller loops across idle windows). Never raises on bad state/db. A
        failed GENERATION does not advance the checkpoint — those rows are
        retried next idle window; an empty yield DOES advance it (the rows
        were processed, there was just nothing worth learning)."""
        self.last_step_new_terms = 0
        state = self._read_state()
        try:
            checkpoint = int(state.get("checkpoint_id", 0))
        except (TypeError, ValueError):
            checkpoint = 0
        rows, more = self._read_rows(checkpoint)
        if not rows:
            return False

        batch_text = "\n".join(final for _, final in rows if final.strip())[:BATCH_CHAR_CAP]
        raw_output = ""
        if batch_text.strip():
            try:
                raw_output = await self._generate(EXTRACTION_SYSTEM_PROMPT, batch_text) or ""
            except Exception:  # noqa: BLE001 — transient LLM failure: retry these rows later
                log.exception("vocab extraction generation failed — will retry")
                return False

        terms: list[str] = [str(t) for t in state.get("terms", []) or []]
        banned_low = {str(b).lower() for b in state.get("banned", []) or []}
        candidates: dict[str, dict] = {
            str(k): dict(v) for k, v in (state.get("candidates") or {}).items() if isinstance(v, dict)
        }
        existing_low = {t.lower() for t in terms}
        candidates_low = {k.lower(): k for k in candidates}

        promoted = 0
        for line in raw_output.splitlines()[:MAX_LINES]:
            term = clean_line(line)
            if not validate_term(term, batch_text, banned_low, existing_low):
                continue
            # Count DISTINCT history rows the term occurs in (dedup via the
            # rows list) — "seen in ≥2 dictations" is the promotion bar.
            pattern = _term_pattern(term)
            hit_rows = [row_id for row_id, final in rows if pattern.search(final)]
            if not hit_rows:
                continue
            key = candidates_low.get(term.lower(), term)
            entry = candidates.get(key, {"count": 0, "rows": []})
            known_rows = {int(r) for r in entry.get("rows", []) if isinstance(r, (int, float))}
            known_rows.update(hit_rows)
            entry["rows"] = sorted(known_rows)
            entry["count"] = len(known_rows)
            candidates[key] = entry
            candidates_low[key.lower()] = key
            if entry["count"] >= PROMOTE_AT:
                del candidates[key]
                candidates_low.pop(key.lower(), None)
                terms.append(key)
                existing_low.add(key.lower())
                promoted += 1

        # Caps: terms evict the OLDEST (list head); candidates evict the
        # lowest-count first, oldest among ties — deterministic either way.
        if len(terms) > MAX_TERMS:
            terms = terms[-MAX_TERMS:]
        if len(candidates) > MAX_CANDIDATES:
            ranked = sorted(
                enumerate(candidates.items()), key=lambda x: (-int(x[1][1].get("count", 0)), -x[0])
            )
            keep = {k for _, (k, _) in ranked[:MAX_CANDIDATES]}
            candidates = {k: v for k, v in candidates.items() if k in keep}

        # Advance the checkpoint even when nothing validated: the same rows
        # must never be re-mined (idle compute is a budget too).
        state["checkpoint_id"] = max(row_id for row_id, _ in rows)
        state["terms"] = terms
        state["candidates"] = candidates
        try:
            self._write_state(state)
        except OSError:
            log.exception("could not persist auto_learned.json")
            return False
        self.last_step_new_terms = promoted
        if promoted:
            log.info(
                "vocab miner: promoted %d terms (%d active, %d candidates)",
                promoted, len(terms), len(candidates),
            )
        return more
