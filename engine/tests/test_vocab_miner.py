"""Idle vocabulary miner (smartness-v2 §4): deterministic validation of LLM
nominations, ≥2-dictation promotion, checkpointing, banned-term handling
(including a concurrent app-side ban mid-step), caps, and the server hooks."""

import asyncio
import json
import sqlite3
from pathlib import Path

import pytest

from velora_engine.config import Config
from velora_engine.vocab_miner import (
    MAX_CANDIDATES,
    MAX_TERMS,
    VocabMiner,
    clean_line,
    validate_term,
)


def seed_history(home: Path, texts: list[str]) -> None:
    home.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(home / "history.sqlite3")
    conn.execute(
        """CREATE TABLE IF NOT EXISTS dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL,
            bundle_id TEXT, app_name TEXT, raw TEXT NOT NULL,
            final TEXT NOT NULL, mode TEXT, duration_ms INTEGER NOT NULL,
            cleanup_ms INTEGER, audio_path TEXT)"""
    )
    for t in texts:
        conn.execute(
            "INSERT INTO dictations (ts, raw, final, duration_ms) VALUES (0, '', ?, 0)", (t,)
        )
    conn.commit()
    conn.close()


def make_generate(lines, calls=None):
    async def _generate(system_prompt: str, user_text: str) -> str:
        if calls is not None:
            calls.append(user_text)
        return "\n".join(lines)

    return _generate


def read_state(home: Path) -> dict:
    return json.loads((home / "auto_learned.json").read_text())


# ---- validation ---------------------------------------------------------------

BATCH = "we shipped Velora today and Wispr Flow lost. also see main.py and authCheck"


@pytest.mark.parametrize(
    "term,ok",
    [
        ("Velora", True),
        ("Wispr Flow", True),
        ("main.py", True),
        ("authCheck", True),
        ("Hallucinated", False),  # not in the text — the LLM made it up
        ("shipped", False),  # single all-lowercase dictionary word
        ("The", False),  # stopword, however capitalized
        ("I", False),
        ("velora today and wispr flow", False),  # > 4 words
        ("x" * 41, False),  # > 40 chars
        ("123", False),  # no letter
        ("", False),
        ("ship", False),  # substring of 'shipped' — word boundary must fail it
    ],
)
def test_validate_term(term, ok):
    assert validate_term(term, BATCH, banned=set(), existing=set()) is ok


def test_validate_term_banned_and_existing():
    assert validate_term("Velora", BATCH, banned={"velora"}, existing=set()) is False
    assert validate_term("Velora", BATCH, banned=set(), existing={"velora"}) is False


def test_clean_line_strips_markers():
    assert clean_line("- Velora") == "Velora"
    assert clean_line("3. Wispr Flow") == "Wispr Flow"
    assert clean_line('  "authCheck"  ') == "authCheck"


# ---- mining steps ---------------------------------------------------------------


async def test_promote_at_two_distinct_rows(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["Velora is fast", "I opened Velora again", "nothing here"])
    miner = VocabMiner(home, make_generate(["Velora", "Fabricated"]))
    more = await miner.step()
    assert more is False
    state = read_state(home)
    assert state["terms"] == ["Velora"]  # 2 distinct rows → promoted
    assert "Velora" not in state["candidates"]
    assert "Fabricated" not in state["candidates"]  # failed validation
    assert state["checkpoint_id"] == 3
    assert miner.last_step_new_terms == 1
    # file must be private (transcript-derived data)
    assert ((home / "auto_learned.json").stat().st_mode & 0o777) == 0o600


async def test_candidate_promotes_across_steps(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["deployed Velora to prod"])
    miner = VocabMiner(home, make_generate(["Velora"]))
    await miner.step()
    state = read_state(home)
    assert state["terms"] == []
    assert state["candidates"]["Velora"] == {"count": 1, "rows": [1]}
    # a later dictation mentions it again → promote (rows list dedups)
    seed_history(home, ["Velora crashed"])
    await miner.step()
    state = read_state(home)
    assert state["terms"] == ["Velora"]
    assert state["checkpoint_id"] == 2


async def test_checkpoint_advances_on_empty_yield(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["just ordinary words here"])
    calls: list[str] = []
    miner = VocabMiner(home, make_generate([], calls))
    assert await miner.step() is False
    assert read_state(home)["checkpoint_id"] == 1
    assert len(calls) == 1
    # the same rows are never re-mined
    assert await miner.step() is False
    assert len(calls) == 1


async def test_generation_failure_does_not_advance_checkpoint(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["Velora rows to retry"])

    async def boom(system_prompt, user_text):
        raise RuntimeError("llm fell over")

    miner = VocabMiner(home, boom)
    assert await miner.step() is False
    assert not (home / "auto_learned.json").exists()  # rows retried next window


async def test_more_rows_flag_loops_batches(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, [f"row number {i}" for i in range(9)])  # 9 > one batch of 8
    miner = VocabMiner(home, make_generate([]))
    assert await miner.step() is True
    assert await miner.step() is False
    assert read_state(home)["checkpoint_id"] == 9


async def test_banned_term_never_readded(tmp_path):
    home = tmp_path / "vh"
    (home).mkdir(parents=True)
    (home / "auto_learned.json").write_text(json.dumps({"version": 1, "banned": ["Velora"]}))
    seed_history(home, ["Velora one", "Velora two"])
    miner = VocabMiner(home, make_generate(["Velora"]))
    await miner.step()
    state = read_state(home)
    assert state["terms"] == []
    assert state["banned"] == ["Velora"]


async def test_concurrent_app_ban_unioned_at_write(tmp_path):
    """The app bans a term while a step is mid-flight (between the miner's read
    and its write): the ban must survive and the term must not land in terms."""
    home = tmp_path / "vh"
    seed_history(home, ["Velora one", "Velora two"])
    path = home / "auto_learned.json"

    async def generate(system_prompt, user_text):
        # simulate AutoVocabStore.remove() racing the mining step
        path.write_text(json.dumps({"version": 1, "banned": ["Velora"], "app_key": True}))
        return "Velora"

    miner = VocabMiner(home, generate)
    await miner.step()
    state = read_state(home)
    assert state["terms"] == []
    assert state["banned"] == ["Velora"]
    assert state["app_key"] is True  # unknown app-side keys pass through


async def test_terms_cap_evicts_oldest(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["NewTerm alpha", "NewTerm beta"])
    old_terms = [f"Term{i}" for i in range(MAX_TERMS)]
    (home / "auto_learned.json").write_text(
        json.dumps({"version": 1, "checkpoint_id": 0, "terms": old_terms})
    )
    miner = VocabMiner(home, make_generate(["NewTerm"]))
    await miner.step()
    state = read_state(home)
    assert len(state["terms"]) == MAX_TERMS
    assert state["terms"][-1] == "NewTerm"
    assert "Term0" not in state["terms"]  # oldest (head) evicted
    assert "Term1" in state["terms"]


async def test_candidates_cap_deterministic_eviction(tmp_path):
    home = tmp_path / "vh"
    seed_history(home, ["Freshest candidate here"])
    crowd = {f"Cand{i}": {"count": 1, "rows": [0]} for i in range(MAX_CANDIDATES)}
    crowd["Popular"] = {"count": 1, "rows": [0]}  # same count as the crowd
    (home / "auto_learned.json").write_text(
        json.dumps({"version": 1, "checkpoint_id": 0, "candidates": crowd})
    )
    miner = VocabMiner(home, make_generate(["Freshest"]))
    await miner.step()
    state = read_state(home)
    assert len(state["candidates"]) == MAX_CANDIDATES
    assert "Freshest" in state["candidates"]  # newest tie survives; oldest evicted


async def test_missing_history_is_quiet_noop(tmp_path):
    home = tmp_path / "empty"
    home.mkdir()
    miner = VocabMiner(home, make_generate(["Velora"]))
    assert await miner.step() is False
    assert not (home / "auto_learned.json").exists()


# ---- config integration ---------------------------------------------------------


def test_auto_vocab_feeds_global_vocabulary(home):
    home.mkdir(parents=True, exist_ok=True)
    (home / "auto_learned.json").write_text(
        json.dumps({"version": 1, "terms": ["Velora", "Banned1"], "banned": ["Banned1"]})
    )
    config = Config()
    config.data["vocabulary"] = ["UserTerm"]
    assert config.auto_vocabulary == ["Velora"]
    assert config.global_vocabulary == ["UserTerm", "Velora"]


# ---- server hooks ---------------------------------------------------------------


async def test_engine_mines_when_idle_and_reloads_config(home, fake_stt):
    from velora_engine.server import Engine

    config = Config()
    eng = Engine(config, parent_pid=None)
    seed_history(config.home, ["Velora demo one", "Velora demo two"])

    class MinerCleanup:
        loaded = True
        model_id = "fake"

        async def cleanup(self, raw, system_prompt, timeout_ms=None, check_ratio=True):
            from velora_engine.cleanup import CleanupResult

            return CleanupResult("Velora", True, 3)

    eng.cleanup = MinerCleanup()
    await eng._mine_when_idle(0)  # noqa: SLF001
    assert read_state(config.home)["terms"] == ["Velora"]
    assert "Velora" in eng.config.global_vocabulary  # config reloaded live


async def test_engine_mining_skips_when_busy_or_disabled(home, fake_stt):
    from velora_engine.server import Engine, Session

    config = Config()
    eng = Engine(config, parent_pid=None)
    seed_history(config.home, ["Velora demo one", "Velora demo two"])
    called = []

    class MinerCleanup:
        loaded = True
        model_id = "fake"

        async def cleanup(self, raw, system_prompt, timeout_ms=None, check_ratio=True):
            called.append(raw)
            from velora_engine.cleanup import CleanupResult

            return CleanupResult("Velora", True, 3)

    eng.cleanup = MinerCleanup()
    eng.session = Session("busy", {})
    await eng._mine_when_idle(0)  # noqa: SLF001
    assert called == []  # a live session always wins

    eng.session = None
    eng.config.data["vocab_mining"] = False
    await eng._mine_when_idle(0)  # noqa: SLF001
    assert called == []  # user disabled mining
