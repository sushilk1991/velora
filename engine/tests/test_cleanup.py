"""Cleanup-model prompt preparation, cache reuse, and deadline behavior."""

from __future__ import annotations

from typing import Any
import asyncio
import threading
import time
from types import SimpleNamespace

import pytest

from velora_engine.cleanup import (
    CleanupEngine,
    _restore_prompt_cache,
    _snapshot_prompt_cache,
)


class CharacterTokenizer:
    """Deterministic tokenizer whose token boundaries are visible in tests."""

    @staticmethod
    def apply_chat_template(messages, **_kwargs):
        system = messages[0]["content"]
        user = messages[1]["content"]
        return [ord(c) for c in f"<system>{system}</system><user>{user}"]

    @staticmethod
    def encode(text):
        return [ord(c) for c in text]


class FakeCache:
    def __init__(self, state: Any = None, meta_state: Any = "fake"):
        self._state = [] if state is None else state
        self._meta_state = meta_state

    @property
    def state(self):
        return self._state

    @state.setter
    def state(self, value):
        self._state = value

    @property
    def meta_state(self):
        return self._meta_state

    @meta_state.setter
    def meta_state(self, value):
        self._meta_state = value

    @classmethod
    def from_state(cls, state, meta_state):
        return cls(state, meta_state)


class RecordingCleanup(CleanupEngine):
    def __init__(self):
        super().__init__("fake")
        self._tokenizer = CharacterTokenizer()
        self._model = object()
        self.loaded = True
        self.prefilled: list[int] = []
        self.cache_creations = 0

    def _make_prompt_cache(self):
        self.cache_creations += 1
        return [FakeCache()]

    def _prefill_tokens_locked(self, tokens, cancel_event=None):
        self.prefilled = list(tokens)
        return [FakeCache([list(tokens)], "prepared")]


@pytest.mark.asyncio
async def test_prepare_prefix_caches_only_exact_common_prompt_tokens():
    engine = RecordingCleanup()
    try:
        result = await engine.prepare_prefix([
            ("stable instructions", "alpha transcript"),
            ("stable instructions plus volatile entity", "zulu transcript"),
        ])
        first = engine._prompt_tokens("stable instructions", "alpha transcript")
        second = engine._prompt_tokens(
            "stable instructions plus volatile entity", "zulu transcript"
        )
        expected = []
        for left, right in zip(first, second):
            if left != right:
                break
            expected.append(left)
        assert result.applied is True
        assert result.tokens == len(expected)
        assert engine.prefilled == expected
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_prepared_prefix_is_forked_for_every_matching_request():
    engine = RecordingCleanup()
    try:
        await engine.prepare_prefix([
            ("stable", "alpha"),
            ("stable plus dynamic", "zulu"),
        ])
        prepared = list(engine._prepared_tokens)
        full = prepared + [91, 92, 93]

        first_cache, first_common, first_hit = engine._cache_for_tokens(full)
        first_cache[0].state[0].append(999)
        second_cache, second_common, second_hit = engine._cache_for_tokens(full)

        assert (first_common, first_hit) == (len(prepared), True)
        assert (second_common, second_hit) == (len(prepared), True)
        assert first_cache is not second_cache
        assert second_cache[0].state == [prepared]
    finally:
        engine.close()


def test_prompt_cache_snapshot_copies_containers_not_model_arrays():
    model_array = object()
    original = [FakeCache([[model_array]], {"offsets": [3]})]
    snapshot = _snapshot_prompt_cache(original)
    original[0].state[0].append("mutation")
    original[0].meta_state["offsets"].append(4)

    restored = _restore_prompt_cache(snapshot)
    assert restored[0].state == [[model_array]]
    assert restored[0].state[0][0] is model_array
    assert restored[0].meta_state == {"offsets": [3]}


def test_prepared_prefix_mismatch_uses_fresh_cache():
    engine = RecordingCleanup()
    try:
        engine._prepared_tokens = [1, 2, 3]
        engine._prepared_cache = _snapshot_prompt_cache([FakeCache([[1, 2, 3]])])
        cache, common, hit = engine._cache_for_tokens([1, 9, 3, 4])
        assert common == 0
        assert hit is False
        assert engine.cache_creations == 1
        assert cache[0].state == []
    finally:
        engine.close()


def test_soft_deadline_starts_after_first_output_token(monkeypatch):
    engine = RecordingCleanup()
    engine._cache_for_tokens = lambda _tokens: ([FakeCache()], 7, True)

    def slow_prefill_then_fast_output(*_args, **_kwargs):
        time.sleep(0.03)  # longer than the 10ms output budget
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", slow_prefill_then_fast_output)
    try:
        result = engine._run("raw", "system", timeout_ms=10, check_ratio=False)
        assert result.applied is True
        assert result.text == "fixed"
        assert result.reason is None
        assert result.ttft_ms >= 20
    finally:
        engine.close()


def test_soft_deadline_still_bounds_slow_output(monkeypatch):
    engine = RecordingCleanup()
    engine._cache_for_tokens = lambda _tokens: ([FakeCache()], 0, False)

    def slow_output(*_args, **_kwargs):
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)
        time.sleep(0.03)
        yield SimpleNamespace(text=" too late", token=2, generation_tokens=2)

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", slow_output)
    try:
        result = engine._run("raw", "system", timeout_ms=10, check_ratio=False)
        assert result.applied is False
        assert result.text == "raw"
        assert result.reason == "timeout"
    finally:
        engine.close()


def test_cooperative_cancel_is_not_reported_as_quality_timeout(monkeypatch):
    engine = RecordingCleanup()
    event = threading.Event()
    event.set()

    def should_not_generate(*_args, **_kwargs):
        raise AssertionError("cancelled cleanup should not enter generation")
        yield

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", should_not_generate)
    try:
        result = engine._run(
            "raw", "system", timeout_ms=10, check_ratio=False, cancel_event=event
        )
        assert result.applied is False
        assert result.reason == "cancelled"
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_cancelled_worker_releases_single_executor_for_final_cleanup(monkeypatch):
    engine = RecordingCleanup()
    started = threading.Event()
    cancel = threading.Event()
    call_lock = threading.Lock()
    call_count = 0

    def streaming(*_args, **_kwargs):
        nonlocal call_count
        with call_lock:
            index = call_count
            call_count += 1
        if index == 0:
            started.set()
            while True:
                time.sleep(0.01)
                yield SimpleNamespace(text="", token=1, generation_tokens=1)
        else:
            yield SimpleNamespace(text="fixed", token=2, generation_tokens=1)

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", streaming)
    try:
        obsolete = asyncio.create_task(engine.cleanup(
            "obsolete", "system", timeout_ms=500, check_ratio=False,
            cancel_event=cancel,
        ))
        assert await asyncio.to_thread(started.wait, 0.5)
        cancel.set()
        cancelled = await asyncio.wait_for(obsolete, 0.5)
        assert cancelled.reason == "cancelled"

        final = await asyncio.wait_for(
            engine.cleanup("raw", "system", timeout_ms=100, check_ratio=False),
            0.5,
        )
        assert final.applied is True
        assert final.text == "fixed"
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_outer_hard_watchdog_still_bounds_a_wedged_generation(monkeypatch):
    import velora_engine.cleanup as cleanup_mod

    engine = RecordingCleanup()

    def wedged(*_args, **_kwargs):
        time.sleep(0.2)
        raise AssertionError("watchdog should return before this finishes")

    monkeypatch.setattr(cleanup_mod, "HARD_TIMEOUT_GRACE_S", 0.02)
    monkeypatch.setattr(engine, "_run", wedged)
    try:
        started = time.perf_counter()
        result = await engine.cleanup(
            "raw", "system", timeout_ms=10, check_ratio=False
        )
        assert time.perf_counter() - started < 0.15
        assert result.reason == "timeout_hard"
    finally:
        engine.close()
