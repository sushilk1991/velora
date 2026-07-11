"""Cleanup-model prompt preparation, cache reuse, and deadline behavior."""

from __future__ import annotations

from typing import Any

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
