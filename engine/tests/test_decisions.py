"""Typed decisions: the pure arithmetic and the engine's one-prefill seam."""

from __future__ import annotations

import math
import threading
import time

import pytest
from test_cleanup import RecordingCleanup

from velora_engine.decisions import (
    MAX_OPTIONS,
    MAX_QUESTIONS,
    MAX_STATE_CHARS,
    OPTION_LABELS,
    STATUS_CANCELLED,
    STATUS_CONTEXT_LIMIT,
    STATUS_ERROR,
    STATUS_OK,
    STATUS_TIMEOUT,
    STATUS_UNAVAILABLE,
    Answer,
    DecisionError,
    DecisionResult,
    Question,
    answer_from_logprobs,
    decision_message,
    validate_questions,
)

KIND = Question("kind", "What does the command ask for?", (
    ("open_app", "open an app"),
    ("web", "search the web"),
    ("other", "something else"),
))
DELIVERS = Question("delivers", "Does it deliver anything to a person?", (
    ("no", "no"),
    ("yes", "yes"),
))


# ---- arithmetic -----------------------------------------------------------

def test_answer_renormalises_over_the_option_letters():
    answer = answer_from_logprobs(DELIVERS, [math.log(0.6), math.log(0.2)])

    assert answer.choice == "no"
    assert answer.p("no") == pytest.approx(0.75)
    assert answer.p("yes") == pytest.approx(0.25)
    assert answer.confidence == pytest.approx(0.75)
    # The letters held 80% of the model's mass; the rest wanted other text.
    assert answer.label_mass == pytest.approx(0.8)


def test_answer_survives_letters_the_model_finds_implausible():
    """Log-probabilities near -1000 underflow exp() to 0. The answer must
    still be a distribution, flagged by its label mass as meaningless."""
    answer = answer_from_logprobs(DELIVERS, [-1000.0, -1001.0])

    assert sum(answer.probabilities.values()) == pytest.approx(1.0)
    assert answer.choice == "no"
    assert answer.label_mass < 1e-100


def test_answer_needs_one_logprob_per_option():
    with pytest.raises(DecisionError):
        answer_from_logprobs(KIND, [0.0, 0.0])


# ---- validation -----------------------------------------------------------

@pytest.mark.parametrize("questions, state", [
    ([], "state"),
    ([KIND] * (MAX_QUESTIONS + 1), "state"),
    ([KIND], "x" * (MAX_STATE_CHARS + 1)),
    ([KIND, KIND], "state"),
    ([Question("one", "pick", (("a", "a"),))], "state"),
    ([Question("many", "pick", tuple(
        (str(i), str(i)) for i in range(MAX_OPTIONS + 1)))], "state"),
    ([Question("dup", "pick", (("a", "a"), ("a", "b")))], "state"),
    ([Question("blank", "pick", (("a", "a"), ("b", "  ")))], "state"),
    ([Question("mute", "  ", (("a", "a"), ("b", "b")))], "state"),
])
def test_malformed_question_sets_are_refused(questions, state):
    with pytest.raises(DecisionError):
        validate_questions(state, questions)


def test_question_from_dict_refuses_a_bare_option():
    with pytest.raises(DecisionError):
        Question.from_dict({"key": "k", "instructions": "pick",
                            "options": ["a", "b"]})


def test_types_round_trip_through_the_worker_protocol():
    assert Question.from_dict(KIND.to_dict()) == KIND
    result = DecisionResult(
        STATUS_OK, {"delivers": Answer("no", {"no": 0.9, "yes": 0.1}, 0.8)},
        ms=12, prefix_tokens=40, state_tokens=90)

    restored = DecisionResult.from_dict(result.to_dict())

    assert restored == result
    assert restored.ok is True


def test_questions_share_the_state_as_a_byte_identical_prefix():
    """The state is prefilled once only because every question's message
    starts with the same bytes; the options come after it."""
    first = decision_message("command: open slack", KIND)
    second = decision_message("command: open slack", DELIVERS)

    shared = "STATE:\ncommand: open slack\n\nQUESTION: "
    assert first.startswith(shared) and second.startswith(shared)
    assert "A. open an app\nB. search the web\nC. something else" in first
    assert first.endswith("Reply with one letter.")


# ---- engine seam ----------------------------------------------------------

class DecidingCleanup(RecordingCleanup):
    """A CleanupEngine whose forward passes are recorded, not run.

    Everything else — tokenising, prefix reuse, snapshots, forking — is the
    production `_decide_locked`.
    """

    def __init__(self, *logprobs: list[float]):
        super().__init__()
        self.logprobs = list(logprobs)
        self.prefix_prefills = 0
        self.state_extensions: list[list[int]] = []
        self.readouts: list[tuple[list[int], list[int], list[int]]] = []
        # Runs inside each forward pass: a cancel or a stall arriving there.
        self.during_readout = lambda: None

    def _prefill_tokens_locked(self, tokens, cancel_event=None):
        self.prefix_prefills += 1
        return super()._prefill_tokens_locked(tokens, cancel_event)

    def _extend_decision_cache_locked(self, cache, tokens, cancel_event):
        self.state_extensions.append(list(tokens))
        return self._prefill_into_cache_locked(cache, tokens, cancel_event)

    def _answer_logprobs_locked(self, cache, suffix, label_ids, cancel_event):
        self.readouts.append((list(cache[0].state[0]), list(suffix), list(label_ids)))
        # A real forward pass extends the cache it is given, so a fork shared
        # between questions would show up in the next readout's state.
        cache[0].state[0].extend(suffix)
        self.during_readout()
        return self.logprobs.pop(0)


@pytest.mark.asyncio
async def test_engine_prefills_the_state_once_and_forks_it_per_question():
    engine = DecidingCleanup(
        [math.log(0.9), math.log(0.05), math.log(0.05)],
        [math.log(0.02), math.log(0.98)],
    )
    try:
        state = "command: open slack"
        result = await engine.decide(state, [KIND, DELIVERS], system_prompt="sys")

        assert result.status == STATUS_OK
        assert result.answers["kind"].choice == "open_app"
        assert result.answers["delivers"].choice == "yes"

        prompts = [engine._prompt_tokens("sys", decision_message(state, q))
                   for q in (KIND, DELIVERS)]
        shared = []
        for left, right in zip(*prompts):
            if left != right:
                break
            shared.append(left)
        assert result.state_tokens == len(shared)
        # One warm preamble, one extension with the state, then each question
        # reads from its own fork of exactly the shared tokens.
        assert engine.prefix_prefills == 1
        assert engine.state_extensions == [shared[result.prefix_tokens:]]
        for (forked, suffix, label_ids), prompt, question in zip(
                engine.readouts, prompts, (KIND, DELIVERS)):
            assert forked == shared
            assert suffix == prompt[len(shared):]
            assert label_ids == [ord(label) for label in
                                 OPTION_LABELS[:len(question.options)]]
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_engine_reuses_the_warm_preamble_across_decisions():
    engine = DecidingCleanup([0.0, -5.0], [0.0, -5.0])
    try:
        first = await engine.decide("command: open slack", [DELIVERS], system_prompt="sys")
        second = await engine.decide("command: open notes", [DELIVERS], system_prompt="sys")

        assert first.ok and second.ok
        assert engine.prefix_prefills == 1
        assert second.prefix_tokens == first.prefix_tokens > len("<system>sys")
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_engine_refuses_an_oversized_prompt_before_any_forward_pass():
    engine = DecidingCleanup()
    try:
        result = await engine.decide("command: open slack", [KIND],
                                     system_prompt="sys", max_input_tokens=10)

        assert result.status == STATUS_CONTEXT_LIMIT
        assert engine.readouts == [] and engine.state_extensions == []
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_engine_decide_reports_failures_as_statuses():
    engine = DecidingCleanup()
    try:
        malformed = await engine.decide("state", [KIND, KIND])
        assert malformed.status == STATUS_ERROR

        cancel = threading.Event()
        cancel.set()
        cancelled = await engine.decide("state", [KIND], cancel_event=cancel)
        assert cancelled.status == STATUS_CANCELLED
        # A cancel that is already set touches no MLX state at all.
        assert engine.prefix_prefills == 0 and engine.readouts == []

        engine.loaded = False
        unloaded = await engine.decide("state", [KIND])
        assert unloaded.status == STATUS_UNAVAILABLE
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_an_answer_read_after_a_cancel_is_not_used():
    engine = DecidingCleanup([0.0, -5.0])
    cancel = threading.Event()
    engine.during_readout = cancel.set
    try:
        result = await engine.decide("state", [DELIVERS], cancel_event=cancel)

        assert result.status == STATUS_CANCELLED
        assert result.answers == {}
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_an_answer_read_past_the_deadline_is_not_used():
    engine = DecidingCleanup([0.0, -5.0])
    engine.during_readout = lambda: time.sleep(0.08)
    try:
        result = await engine.decide("state", [DELIVERS], timeout_ms=40)

        assert result.status == STATUS_TIMEOUT
        assert result.answers == {}
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_action_memory_release_drops_the_decision_preamble(monkeypatch):
    """The preamble snapshot carries the hybrid model's fixed-size recurrent
    state; it goes with the rest of an action's memory."""
    import mlx.core as mx

    monkeypatch.setattr(mx, "clear_cache", lambda: None)
    engine = DecidingCleanup([0.0, -5.0], [0.0, -5.0])
    try:
        await engine.decide("command: open slack", [DELIVERS], system_prompt="sys")
        assert engine._decision_prefix is not None

        engine._release_action_memory()
        await engine.decide("command: open notes", [DELIVERS], system_prompt="sys")

        assert engine.prefix_prefills == 2
    finally:
        engine.close()


@pytest.mark.asyncio
async def test_identical_questions_under_different_keys_still_get_a_readout():
    """Two keys may ask the same visible question. Their prompts then share
    every token, and the readout still needs one live input position."""
    twin = Question("delivers_again", DELIVERS.instructions, DELIVERS.options)
    engine = DecidingCleanup([0.0, -5.0], [0.0, -5.0])
    try:
        result = await engine.decide("state", [DELIVERS, twin], system_prompt="sys")

        assert result.status == STATUS_OK
        assert all(len(suffix) == 1 for _, suffix, _ in engine.readouts)
    finally:
        engine.close()
