"""Cleanup-model prompt preparation, cache reuse, and deadline behavior."""

from __future__ import annotations

from typing import Any
import asyncio
import contextlib
import threading
import time
from types import SimpleNamespace

import pytest

import velora_engine.cleanup as cleanup_mod
from velora_engine.cleanup import (
    CleanupEngine,
    CleanupResult,
    COPY_DRAFT_PASS_TOKENS,
    _PrefixCancelled,
    _copy_draft,
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
        self.extended: list[list[int]] = []
        self.cache_creations = 0

    def _make_prompt_cache(self):
        self.cache_creations += 1
        return [FakeCache()]

    def _prefill_tokens_locked(self, tokens, cancel_event=None):
        self.prefilled = list(tokens)
        return [FakeCache([list(tokens)], "prepared")]

    def _prefill_into_cache_locked(self, cache, tokens, cancel_event=None):
        if cancel_event is not None and cancel_event.is_set():
            raise _PrefixCancelled
        self.extended.append(list(tokens))
        if not cache[0].state:
            cache[0].state = [[]]
        cache[0].state[0].extend(tokens)
        return cache


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
async def test_prepare_prefix_rejects_single_candidate_without_caching_transcript():
    engine = RecordingCleanup()
    try:
        result = await engine.prepare_prefix([("stable", "private transcript")])

        assert result.applied is False
        assert result.reason == "insufficient_candidates"
        assert engine.prefilled == []
        assert engine._prepared_cache is None
    finally:
        engine.close()


class WarmStepCleanup(RecordingCleanup):
    """Counts the one-token warm-up forward instead of running a model."""

    def __init__(self):
        super().__init__()
        self.warm_steps: list[int] = []

    def _warm_step_locked(self, tokens, snapshot):
        self.warm_steps.append(len(tokens))


@pytest.mark.asyncio
async def test_prepare_prefix_extends_the_warm_snapshot_instead_of_the_whole_prompt():
    # Stop-time preparation for a new app/mode must cost only the delta after
    # the static snapshot (~600 tokens), not the whole ~3k-token prompt.
    engine = WarmStepCleanup()
    engine._warm("stable instructions")
    static_tokens = list(engine._prepared_tokens)
    system = "stable instructions\n\nFormatting strength: FULL."
    engine.prefilled = []
    try:
        result = await engine.prepare_prefix([
            (system, "alpha"),
            (system + "\n\nScreen context", "zulu"),
        ])

        assert result.applied is True
        assert result.tokens == len(engine._prepared_tokens)
        assert engine.prefilled == []
        assert engine.extended == [engine._prepared_tokens[len(static_tokens):]]
        assert engine._fallback_prepared_tokens == static_tokens
        assert engine.warm_steps == []
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_prepare_prefix_of_installed_prefix_only_warms_the_model():
    # An idle writing model pays ~600 ms to page its weights back in on the
    # first forward. Re-preparing a prefix that is already installed must run
    # one warm-up step over it and never re-prefill it.
    engine = WarmStepCleanup()
    candidates = [
        ("stable instructions", "alpha"),
        ("stable instructions plus entity", "zulu"),
    ]
    try:
        first = await engine.prepare_prefix(candidates)
        prepared = list(engine._prepared_tokens)
        engine.prefilled = []

        second = await engine.prepare_prefix(candidates)

        assert second.applied is True
        assert second.tokens == first.tokens == len(prepared)
        assert engine.prefilled == []
        assert engine.extended == []
        assert engine.warm_steps == [len(prepared)]
        assert engine._prepared_tokens == prepared
    finally:
        engine.close()


def test_static_warm_cache_matches_extended_runtime_system_prompt():
    engine = RecordingCleanup()
    try:
        engine._warm("stable instructions")
        runtime = engine._prompt_tokens(
            "stable instructions\n\nFormatting strength: FULL.",
            "raw transcript",
        )

        _cache, common, hit = engine._cache_for_tokens(runtime)

        assert hit is True
        assert common == len(engine._prepared_tokens)
        assert common > len("<system>stable instructions")
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_unhealthy_engine_rejects_prefix_preparation_without_queueing():
    engine = RecordingCleanup()
    engine.unhealthy = True
    try:
        result = await engine.prepare_prefix([("stable", "transcript")])

        assert result.applied is False
        assert result.reason == "llm_unhealthy"
        assert engine.prefilled == []
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_cancelled_prefix_preparation_keeps_last_completed_snapshot():
    engine = RecordingCleanup()
    engine._prepared_tokens = [1, 2, 3]
    engine._prepared_cache = _snapshot_prompt_cache([FakeCache([[1, 2, 3]])])
    cancel = threading.Event()
    cancel.set()
    try:
        result = await engine.prepare_prefix(
            [("new stable prompt", "transcript")], cancel_event=cancel
        )

        assert result.applied is False
        assert result.reason == "cancelled"
        _cache, common, hit = engine._cache_for_tokens([1, 2, 3, 4])
        assert (common, hit) == (3, True)
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


def test_copy_draft_continues_the_transcript_after_the_output_tail():
    source = [ord(c) for c in "we should ship it today"]
    output = [ord(c) for c in "We should sh"]

    # " sh" first appears in " should"; the cursor says output is past it.
    draft, start = _copy_draft(source, output, cursor=len("we should"), limit=11)

    assert "".join(map(chr, draft)) == "ip it today"
    assert start == len("we should sh")
    # A one-token tail matches too often by chance to draft from.
    assert _copy_draft(source, [ord("Q"), ord("w")], cursor=0, limit=11) == ([], 0)


EOS = 0


class DraftTokenizer(CharacterTokenizer):
    eos_token_ids = {EOS}

    @staticmethod
    def decode(tokens):
        return "".join(chr(t) for t in tokens)


class GreedyOracle:
    """Fake model whose greedy output is ``target``, then EOS.

    It reads the whole fed history from the cache, the way a recurrent layer
    carries it: a rejected draft left in the cache derails every later token.
    """

    vocab = 128

    def __init__(self, target: str):
        self.target = [ord(c) for c in target] + [EOS]
        self.prompt: list[int] = []
        self.forwards = 0
        self.pass_sizes: list[int] = []

    def next_token(self, history: list[int]) -> int:
        output = history[len(self.prompt):]
        if output != self.target[:len(output)] or len(output) >= len(self.target):
            return ord("?")
        return self.target[len(output)]

    def __call__(self, inputs, cache):
        import mlx.core as mx

        self.forwards += 1
        self.pass_sizes.append(inputs.shape[1])
        if not cache[0].state:
            cache[0].state = [[]]
        history = cache[0].state[0]
        rows = []
        for token in inputs[0].tolist():
            history.append(token)
            row = [0.0] * self.vocab
            row[self.next_token(history)] = 1.0
            rows.append(row)
        return mx.array([rows])


def _oracle_cleanup(monkeypatch, target: str):
    """RecordingCleanup on a GreedyOracle; stock generation steps one token."""
    import mlx.core as mx
    import mlx_lm

    engine = RecordingCleanup()
    engine._tokenizer = DraftTokenizer()
    oracle = GreedyOracle(target)
    engine._model = oracle
    # Copy-draft runs only on benched models; treat the fake as one.
    monkeypatch.setattr(
        cleanup_mod, "COPY_DRAFT_MODELS", frozenset({engine.model_id}), raising=False)

    def one_token_at_a_time(model, _tokenizer, prompt, max_tokens, prompt_cache, **_kwargs):
        engine._prefill_into_cache_locked(prompt_cache, list(prompt[:-1]))
        pending = list(prompt[-1:])
        for count in range(1, max_tokens + 1):
            token = int(mx.argmax(model(mx.array([pending]), prompt_cache)[0, -1]).item())
            if token == EOS:
                return
            yield SimpleNamespace(text=chr(token), token=token, generation_tokens=count)
            pending = [token]

    monkeypatch.setattr(mlx_lm, "stream_generate", one_token_at_a_time)
    return engine, oracle


@contextlib.contextmanager
def recorded_generation_context(monkeypatch):
    """Swap mlx_lm's wired_limit and generation stream for recorders.

    Yields (stream, wired): the stream to expect model calls on, and the
    wired-limit events in order: ("enter", streams) then ("exit", None).
    """
    import importlib

    import mlx.core as mx

    # `mlx_lm.generate` as an attribute is the generate() function.
    generate_mod = importlib.import_module("mlx_lm.generate")
    stream = mx.new_stream(mx.default_device())
    wired: list[tuple[str, Any]] = []

    @contextlib.contextmanager
    def recording_wired_limit(_model, streams=None):
        wired.append(("enter", streams))
        try:
            yield
        finally:
            wired.append(("exit", None))

    monkeypatch.setattr(generate_mod, "generation_stream", stream)
    monkeypatch.setattr(generate_mod, "wired_limit", recording_wired_limit)
    yield stream, wired


def _observed_model(oracle, on_forward):
    """The oracle as a model callable that runs ``on_forward(n)`` first."""

    def model(inputs, cache):
        on_forward(oracle.forwards + 1)
        return oracle(inputs, cache)

    return model


def test_dictation_cleanup_verifies_transcript_drafts_in_bulk(monkeypatch):
    # "uh" is dropped and "," inserted mid-draft: two rejected drafts.
    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    try:
        result = engine._run(raw, "rules", timeout_ms=1_000, copy_draft=True)

        assert result.applied is True
        assert result.text == target
        # Stock greedy decoding needs one forward per output token plus EOS;
        # drafts cut that by at least a third, in passes no longer than the
        # cheap size (the first pass is the transcript's last prompt token).
        assert oracle.forwards <= (len(target) + 1) * 2 // 3
        assert max(oracle.pass_sizes) <= COPY_DRAFT_PASS_TOKENS
    finally:
        engine.close()


def test_transformations_keep_one_token_decoding(monkeypatch):
    # "uh" is dropped and "," inserted mid-draft: two rejected drafts.
    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    try:
        result = engine._run(raw, "rules", timeout_ms=1_000, check_ratio=False)

        assert result.text == target
        assert oracle.forwards == len(target) + 1
    finally:
        engine.close()


def test_runtime_prefix_extension_preserves_exact_prompt_and_static_fallback(
    monkeypatch,
):
    engine = RecordingCleanup()
    engine._warm("stable instructions")
    static_tokens = list(engine._prepared_tokens)
    system = "stable instructions\n\nFormatting strength: FULL."
    raw = "raw transcript"
    candidates = [
        (system, "alpha transcript"),
        (system, "zulu transcript"),
    ]
    expected = engine._prompt_tokens(system, raw)
    observed: list[int] = []

    def generate(*_args, prompt, prompt_cache, **_kwargs):
        observed.extend(prompt_cache[0].state[0])
        observed.extend(prompt)
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", generate)
    try:
        result = engine._run(
            raw,
            system,
            timeout_ms=100,
            check_ratio=False,
            prefix_candidates=candidates,
        )

        assert result.applied is True
        assert result.text == "fixed"
        assert observed == expected
        assert len(engine._prepared_tokens) > len(static_tokens)
        assert engine._fallback_prepared_tokens == static_tokens
        assert engine.extended == [
            engine._prepared_tokens[len(static_tokens):]
        ]

        other_mode = engine._prompt_tokens(
            "stable instructions\n\nRomanize output.",
            raw,
        )
        _cache, common, hit = engine._cache_for_tokens(other_mode)
        assert hit is True
        assert common == len(static_tokens)
    finally:
        engine.close()


def test_action_prefix_is_session_scoped_and_cleanup_prefix_survives(monkeypatch):
    import mlx.core as mx
    import mlx_lm

    engine = RecordingCleanup()
    engine._warm("stable dictation instructions")
    dictation_tokens = list(engine._prepared_tokens)
    dictation_snapshot = engine._prepared_cache
    action_system = "independent action agent protocol"
    action_raw = "open Slack"
    candidates = [
        (action_system, "alpha action"),
        (action_system, "zulu action"),
    ]

    def generate(*_args, **_kwargs):
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    clear_calls = 0

    def clear_cache():
        nonlocal clear_calls
        clear_calls += 1

    monkeypatch.setattr(mlx_lm, "stream_generate", generate)
    monkeypatch.setattr(mx, "clear_cache", clear_cache)
    try:
        result = engine._run(
            action_raw,
            action_system,
            timeout_ms=100,
            check_ratio=False,
            prefix_candidates=candidates,
            cache_scope="action",
        )

        assert result.applied is True
        assert engine._action_prepared_tokens
        assert engine._action_prepared_cache is not None
        assert engine._prepared_tokens == dictation_tokens
        assert engine._prepared_cache is dictation_snapshot

        action_request = engine._action_prepared_tokens + [999]
        _cache, common, hit = engine._cache_for_tokens(action_request)
        assert (common, hit) == (0, False)
        _cache, common, hit = engine._cache_for_tokens(
            action_request, cache_scope="action"
        )
        assert (common, hit) == (len(engine._action_prepared_tokens), True)

        stable_action_tokens = list(engine._action_prepared_tokens)
        stable_action_snapshot = engine._action_prepared_cache
        engine._install_prepared_prefix(
            stable_action_tokens + [1, 2, 3],
            [FakeCache([[1, 2, 3]])],
            cache_scope="action",
        )
        assert engine._action_prepared_tokens == stable_action_tokens
        assert engine._action_prepared_cache is stable_action_snapshot

        engine._release_action_memory()

        assert engine._action_prepared_tokens == []
        assert engine._action_prepared_cache is None
        assert engine._prepared_tokens == dictation_tokens
        assert engine._prepared_cache is dictation_snapshot
        assert clear_calls == 1
    finally:
        engine.close()


def test_unrelated_prefix_cannot_evict_the_smaller_warm_base():
    engine = RecordingCleanup()
    engine._warm("stable dictation instructions")
    base_tokens = list(engine._prepared_tokens)
    base_snapshot = engine._prepared_cache
    try:
        unrelated = engine._prompt_tokens(
            "independent verifier with a much longer changing UI tree", "a")
        engine._install_prepared_prefix(
            unrelated,
            [FakeCache([list(unrelated)], "verifier")],
        )

        assert engine._prepared_tokens == unrelated
        assert engine._fallback_prepared_tokens == base_tokens
        assert engine._fallback_prepared_cache is base_snapshot

        even_larger = unrelated + list(range(100))
        engine._install_prepared_prefix(
            even_larger,
            [FakeCache([list(even_larger)], "larger")],
        )
        assert engine._fallback_prepared_tokens == base_tokens
        assert engine._fallback_prepared_cache is base_snapshot
    finally:
        engine.close()


def test_failed_runtime_prefix_extension_restores_clean_static_snapshot(
    monkeypatch,
):
    engine = RecordingCleanup()
    engine._warm("stable instructions")
    static_tokens = list(engine._prepared_tokens)
    static_snapshot = engine._prepared_cache
    system = "stable instructions\n\nFormatting strength: FULL."
    raw = "raw transcript"
    candidates = [
        (system, "alpha transcript"),
        (system, "zulu transcript"),
    ]

    def partial_then_fail(cache, tokens, cancel_event=None):
        cache[0].state[0].extend(tokens[:3])
        raise RuntimeError("prefill failed")

    observed: list[int] = []

    def generate(*_args, prompt, prompt_cache, **_kwargs):
        observed.extend(prompt_cache[0].state[0])
        observed.extend(prompt)
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    import mlx_lm

    monkeypatch.setattr(
        engine,
        "_prefill_into_cache_locked",
        partial_then_fail,
    )
    monkeypatch.setattr(mlx_lm, "stream_generate", generate)
    try:
        result = engine._run(
            raw,
            system,
            timeout_ms=100,
            check_ratio=False,
            prefix_candidates=candidates,
        )

        assert result.applied is True
        assert observed == engine._prompt_tokens(system, raw)
        assert engine._prepared_tokens == static_tokens
        assert engine._prepared_cache is static_snapshot
    finally:
        engine.close()


def test_runtime_prefix_snapshot_failure_keeps_atomic_old_pair(
    monkeypatch,
):
    import velora_engine.cleanup as cleanup_mod
    import mlx_lm

    engine = RecordingCleanup()
    engine._warm("stable instructions")
    static_tokens = list(engine._prepared_tokens)
    static_snapshot = engine._prepared_cache
    system = "stable instructions\n\nFormatting strength: FULL."
    raw = "raw transcript"
    candidates = [
        (system, "alpha transcript"),
        (system, "zulu transcript"),
    ]
    expected = engine._prompt_tokens(system, raw)
    observed: list[int] = []

    def snapshot_fails(_cache):
        raise RuntimeError("snapshot failed")

    def generate(*_args, prompt, prompt_cache, **_kwargs):
        observed.extend(prompt_cache[0].state[0])
        observed.extend(prompt)
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    monkeypatch.setattr(cleanup_mod, "_snapshot_prompt_cache", snapshot_fails)
    monkeypatch.setattr(mlx_lm, "stream_generate", generate)
    try:
        result = engine._run(
            raw,
            system,
            timeout_ms=100,
            check_ratio=False,
            prefix_candidates=candidates,
        )

        assert result.applied is True
        assert observed == expected
        assert engine._prepared_tokens == static_tokens
        assert engine._prepared_cache is static_snapshot
    finally:
        engine.close()


def test_soft_deadline_starts_after_first_output_token(monkeypatch):
    engine = RecordingCleanup()
    engine._cache_for_tokens = (
        lambda _tokens, cache_scope=None: ([FakeCache()], 7, True)
    )

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
        assert result.input_tokens == len(engine._prompt_tokens("system", "raw"))
    finally:
        engine.close()


def test_soft_deadline_still_bounds_slow_output(monkeypatch):
    engine = RecordingCleanup()
    engine._cache_for_tokens = (
        lambda _tokens, cache_scope=None: ([FakeCache()], 0, False)
    )

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


@pytest.mark.parametrize("cancel_at", [0, 256, 1024])
def test_prefill_cancel_is_safe(monkeypatch, cancel_at):
    engine = RecordingCleanup()
    cancel = threading.Event()
    completed = []
    caches = []
    released = []

    def prefill(*_args, **kwargs):
        caches.append(kwargs["prompt_cache"])
        progress = kwargs.get("prompt_progress_callback", lambda *_: None)
        for processed in [0, 256, 1024]:
            if processed == cancel_at:
                cancel.set()
            progress(processed, 1024)
            completed.append(processed)
        yield SimpleNamespace(text="raw", token=1, generation_tokens=1)

    import mlx.core as mx
    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", prefill)
    monkeypatch.setattr(mx, "clear_cache", lambda: released.append(list(caches[-1])))
    try:
        engine._warm("system")
        snapshot = engine._prepared_cache
        # check_ratio=False keeps stream_generate's own prefill; dictation's
        # copy-draft prefill is covered by the test below.
        result = engine._run(
            "raw", "system", timeout_ms=100, check_ratio=False, cancel_event=cancel,
        )

        assert result.reason == "cancelled"
        assert completed == [step for step in [0, 256, 1024] if step < cancel_at]
        assert result.text == "raw"
        assert result.applied is False
        assert engine.loaded is True
        assert engine.unhealthy is False
        assert engine._prepared_cache is snapshot
        assert released == [[]]

        # A later uncancelled request must use the same warm model normally.
        final = engine._run("raw", "system", timeout_ms=100, check_ratio=False)
        assert final.text == "raw"
        assert final.applied is True
    finally:
        engine.close()


def test_copy_draft_is_requested_explicitly_not_implied_by_check_ratio(monkeypatch):
    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    try:
        result = engine._run(raw, "rules", timeout_ms=1_000, check_ratio=True)

        assert result.text == target
        assert oracle.forwards == len(target) + 1
    finally:
        engine.close()


def test_copy_draft_runs_only_on_benched_models(monkeypatch):
    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    monkeypatch.setattr(cleanup_mod, "COPY_DRAFT_MODELS", frozenset())
    try:
        result = engine._run(raw, "rules", timeout_ms=1_000, copy_draft=True)

        assert result.text == target
        assert oracle.forwards == len(target) + 1
    finally:
        engine.close()


def test_copy_draft_ships_only_on_the_benched_4b_tiers():
    """The 4B tiers passed the exact-match and stop-to-final bench; 2B was never
    benched, so the low-RAM tier keeps one-token decoding."""
    assert cleanup_mod.COPY_DRAFT_MODELS == {
        "mlx-community/Qwen3.5-4B-MLX-8bit",
        "mlx-community/Qwen3.5-4B-MLX-4bit",
    }


def test_copy_draft_runs_inside_wired_limit_on_the_generation_stream(monkeypatch):
    """Copy-draft sets up the GPU the way stream_generate does."""
    import mlx.core as mx

    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    seen: list[tuple[bool, bool]] = []
    with recorded_generation_context(monkeypatch) as (stream, wired):
        engine._model = _observed_model(oracle, lambda _n: seen.append((
            wired[-1:] == [("enter", [stream])],
            mx.default_stream(mx.default_device()) == stream,
        )))
        try:
            result = engine._run(raw, "rules", timeout_ms=1_000, copy_draft=True)
        finally:
            engine.close()

    assert result.text == target
    assert seen and all(inside and on_stream for inside, on_stream in seen)
    assert wired == [("enter", [stream]), ("exit", None)]


def test_cancelled_stock_generation_is_closed_before_its_cache_is_cleared(monkeypatch):
    import mlx_lm

    engine = RecordingCleanup()
    engine._tokenizer = DraftTokenizer()
    caches: list[list[Any]] = []

    def make_prompt_cache():
        caches.append([FakeCache()])
        return caches[-1]

    engine._make_prompt_cache = make_prompt_cache
    cancel = threading.Event()
    closed_with: list[int] = []

    def generate(_model, _tokenizer, prompt, max_tokens, prompt_cache, **_kwargs):
        try:
            for count in range(1, max_tokens + 1):
                if count == 2:
                    cancel.set()
                yield SimpleNamespace(text="a", token=ord("a"), generation_tokens=count)
        finally:
            closed_with.append(len(prompt_cache))

    monkeypatch.setattr(mlx_lm, "stream_generate", generate)
    try:
        result = engine._run(
            "we should ship it today", "rules", timeout_ms=1_000, cancel_event=cancel)

        assert result.reason == "cancelled"
        # Closed while its cache still existed, then the cache was dropped.
        assert closed_with == [1]
        assert caches[-1] == []
    finally:
        engine.close()


def test_copy_draft_cancelled_between_passes_stops_and_closes(monkeypatch):
    raw = "we should uh ship it today okay"
    engine, oracle = _oracle_cleanup(monkeypatch, "We should ship it today, okay.")
    oracle.prompt = engine._prompt_tokens("rules", raw)
    cancel = threading.Event()
    with recorded_generation_context(monkeypatch) as (_stream, wired):
        # Cancel lands after pass 1 computed its tokens, before pass 2.
        def cancel_after_first_pass(n):
            if n == 2:
                raise AssertionError("a pass ran after the cancel")

        model = _observed_model(oracle, cancel_after_first_pass)

        def first_pass_then_cancel(inputs, cache):
            logits = model(inputs, cache)
            cancel.set()
            return logits

        engine._model = first_pass_then_cancel
        try:
            engine._warm("rules")
            snapshot = engine._prepared_cache
            result = engine._run(
                raw, "rules", timeout_ms=1_000, cancel_event=cancel, copy_draft=True)

            assert result.reason == "cancelled"
            assert result.applied is False
            assert oracle.forwards == 1
            assert wired[-1] == ("exit", None)
            assert engine._prepared_cache is snapshot
        finally:
            engine.close()


def test_copy_draft_timeout_mid_pass_returns_raw_and_closes(monkeypatch):
    raw = "we should uh ship it today okay"
    target = "We should ship it today, okay."
    engine, oracle = _oracle_cleanup(monkeypatch, target)
    oracle.prompt = engine._prompt_tokens("rules", raw)
    with recorded_generation_context(monkeypatch) as (_stream, wired):
        # Every pass after the first outlasts the whole output budget, so the
        # first token of pass 2 times out with the rest of that pass unread.
        engine._model = _observed_model(
            oracle, lambda n: time.sleep(0.05) if n > 1 else None)
        try:
            result = engine._run(raw, "rules", timeout_ms=10, copy_draft=True)
        finally:
            engine.close()

    assert result.reason == "timeout"
    assert result.applied is False
    assert result.text == raw
    assert 0 < result.output_tokens < len(target)
    assert wired == [("enter", [wired[0][1][0]]), ("exit", None)]


class EndOfTurnTokenizer(DraftTokenizer):
    """Chat template with an end-of-turn EOS right after the user text, as
    Qwen's <|im_end|>: a draft copied past the transcript's end carries it."""

    @staticmethod
    def apply_chat_template(messages, **_kwargs):
        system = messages[0]["content"]
        user = messages[1]["content"]
        return (
            [ord(c) for c in f"<system>{system}</system><user>{user}"]
            + [EOS]
            + [ord(c) for c in "<bot>"]
        )


def test_copy_draft_stops_at_an_eos_drafted_from_the_prompt(monkeypatch):
    raw = "we should ship it today"
    engine, oracle = _oracle_cleanup(monkeypatch, raw)
    engine._tokenizer = EndOfTurnTokenizer()
    oracle.prompt = engine._prompt_tokens("rules", raw)
    try:
        result = engine._run(raw, "rules", timeout_ms=1_000, copy_draft=True)

        assert result.applied is True
        assert result.text == raw
        assert result.output_tokens == len(raw)
        assert oracle.forwards < len(raw)
    finally:
        engine.close()


class HFCharacterTokenizer:
    """The Hugging Face surface mlx_lm's TokenizerWrapper reads."""

    eos_token_id = EOS
    bos_token = None
    chat_template = None
    clean_up_tokenization_spaces = False
    apply_chat_template = staticmethod(CharacterTokenizer.apply_chat_template)

    @staticmethod
    def get_vocab():
        return {}

    @staticmethod
    def encode(text, add_special_tokens=False):
        return [ord(c) for c in text]

    @staticmethod
    def decode(tokens):
        return "".join(chr(t) for t in tokens if t != EOS)


CEILING_RAW = "we should ship it today"
CEILING_TARGET = "We should ship it today."


@pytest.mark.parametrize("copy_draft", [False, True], ids=["stock", "copy_draft"])
@pytest.mark.parametrize(
    ("max_tokens", "reason"),
    [(len(CEILING_TARGET) + 1, None), (len(CEILING_TARGET), "length")],
    ids=["eos_is_the_last_allowed_token", "ceiling_before_eos"],
)
def test_eos_at_the_token_ceiling_counts_the_same_in_both_decoders(
    monkeypatch, copy_draft, max_tokens, reason
):
    """Real mlx_lm stream_generate: its closing step carries the EOS token.

    EOS is never output, so an answer whose EOS is the last allowed token is
    complete, and one cut off at the ceiling is "length", in either decoder.
    """
    from mlx_lm.tokenizer_utils import TokenizerWrapper

    engine = RecordingCleanup()
    engine._tokenizer = TokenizerWrapper(HFCharacterTokenizer(), eos_token_ids=[EOS])
    oracle = GreedyOracle(CEILING_TARGET)
    engine._model = oracle
    monkeypatch.setattr(
        cleanup_mod, "COPY_DRAFT_MODELS", frozenset({engine.model_id}), raising=False)
    oracle.prompt = engine._prompt_tokens("rules", CEILING_RAW)
    try:
        result = engine._run(
            CEILING_RAW, "rules", timeout_ms=1_000,
            copy_draft=copy_draft, max_tokens_override=max_tokens)

        assert result.reason == reason
        assert result.applied is (reason is None)
        assert result.text == (CEILING_TARGET if reason is None else CEILING_RAW)
        assert result.output_tokens == len(CEILING_TARGET)
    finally:
        engine.close()


def test_copy_draft_prefill_cancel_keeps_the_warm_snapshot(monkeypatch):
    raw = "we should uh ship it today okay"
    engine, oracle = _oracle_cleanup(monkeypatch, "We should ship it today, okay.")
    oracle.prompt = engine._prompt_tokens("rules", raw)
    cancel = threading.Event()
    prefill = engine._prefill_into_cache_locked

    def cancelled_mid_prefill(cache, tokens, cancel_event=None):
        cancel.set()
        return prefill(cache, tokens, cancel_event)

    engine._prefill_into_cache_locked = cancelled_mid_prefill
    try:
        engine._warm("rules")
        snapshot = engine._prepared_cache
        result = engine._run(
            raw, "rules", timeout_ms=1_000, cancel_event=cancel, copy_draft=True)

        assert result.reason == "cancelled"
        assert result.applied is False
        assert oracle.forwards == 0
        assert engine._prepared_cache is snapshot
    finally:
        engine.close()


def test_input_token_ceiling_refuses_before_mlx_prefill(monkeypatch):
    engine = RecordingCleanup()

    def should_not_generate(*_args, **_kwargs):
        raise AssertionError("oversize prompt must be rejected before MLX generation")
        yield

    import mlx_lm

    monkeypatch.setattr(mlx_lm, "stream_generate", should_not_generate)
    try:
        result = engine._run(
            "large screen", "controller rules", timeout_ms=100,
            check_ratio=False, max_input_tokens=8,
        )

        assert result.applied is False
        assert result.reason == "context_limit"
        assert result.input_tokens > 8
        assert engine.cache_creations == 0
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
        assert engine.unhealthy is True
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_hard_watchdog_starts_when_generation_enters_worker(monkeypatch):
    import velora_engine.cleanup as cleanup_mod

    engine = RecordingCleanup()
    blocker_started = threading.Event()
    blocker_release = threading.Event()

    def block_worker():
        blocker_started.set()
        blocker_release.wait(0.5)

    blocker = engine._executor.submit(block_worker)
    assert blocker_started.wait(0.2)
    monkeypatch.setattr(cleanup_mod, "QUEUE_TIMEOUT_S", 0.2)
    monkeypatch.setattr(cleanup_mod, "HARD_TIMEOUT_GRACE_S", 0.01)
    monkeypatch.setattr(
        engine,
        "_run",
        lambda *_args, **_kwargs: CleanupResult("fixed", True, 1),
    )
    try:
        task = asyncio.create_task(engine.cleanup(
            "raw", "system", timeout_ms=10, check_ratio=False
        ))
        # This exceeds the runtime watchdog, but the generation has not begun.
        await asyncio.sleep(0.03)
        blocker_release.set()
        result = await asyncio.wait_for(task, 0.3)

        assert result.applied is True
        assert result.text == "fixed"
        assert engine.unhealthy is False
    finally:
        blocker_release.set()
        blocker.result(timeout=0.5)
        engine.close()


@pytest.mark.asyncio
async def test_queue_timeout_retires_unavailable_worker_without_running_followup(monkeypatch):
    import velora_engine.cleanup as cleanup_mod

    engine = RecordingCleanup()
    blocker_started = threading.Event()
    blocker_release = threading.Event()
    calls = []

    def block_worker():
        blocker_started.set()
        blocker_release.wait(0.5)

    blocker = engine._executor.submit(block_worker)
    assert blocker_started.wait(0.2)
    monkeypatch.setattr(cleanup_mod, "QUEUE_TIMEOUT_S", 0.02)
    monkeypatch.setattr(
        engine,
        "_run",
        lambda raw, *_args, **_kwargs: calls.append(raw),
    )
    try:
        result = await engine.cleanup(
            "must not run", "system", timeout_ms=10, check_ratio=False
        )

        assert result.reason == "timeout_queue"
        assert engine.unhealthy is True
        assert calls == []
    finally:
        blocker_release.set()
        blocker.result(timeout=0.5)
        engine.close()


@pytest.mark.asyncio
async def test_hard_watchdog_poison_rejects_followup_instead_of_queueing(monkeypatch):
    import velora_engine.cleanup as cleanup_mod

    engine = RecordingCleanup()
    calls = []

    def wedged(raw, *_args, **_kwargs):
        calls.append(raw)
        time.sleep(0.2)
        return None

    monkeypatch.setattr(cleanup_mod, "HARD_TIMEOUT_GRACE_S", 0.02)
    monkeypatch.setattr(engine, "_run", wedged)
    try:
        first = await engine.cleanup("first", "system", timeout_ms=10, check_ratio=False)
        started = time.perf_counter()
        followup = await engine.cleanup(
            "must not queue", "system", timeout_ms=10, check_ratio=False
        )

        assert first.reason == "timeout_hard"
        assert followup.reason == "llm_unhealthy"
        assert time.perf_counter() - started < 0.05
        assert calls == ["first"]
    finally:
        engine.close()
