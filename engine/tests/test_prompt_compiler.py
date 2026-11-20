"""Unit tests for V-06/V-07/V-09/V-10 compiled prompt architecture & KV-cache safety."""

from __future__ import annotations

from velora_engine import formatting
from velora_engine.formatting import build_prefill_prompt_candidates, run_gate
from velora_engine.prompts import (
    CORE_SYSTEM_PREFIX,
    MAX_FEW_SHOT_EXAMPLES,
    detect_cues,
)


def test_core_prefix_is_dramatically_smaller_than_legacy_monolith():
    # Legacy STATIC_SYSTEM_PROMPT was ~6,100 chars (~2,398 tokens).
    # Keeping the immutable core prefix compact cuts KV-cache RAM and cold-warm time.
    assert len(CORE_SYSTEM_PREFIX) < 1_200
    assert formatting.STATIC_SYSTEM_PROMPT == CORE_SYSTEM_PREFIX


def test_kv_cache_prefix_matches_every_cue_combination_exactly(config):
    """Session-start prefill LCP MUST be an exact prefix of every cue-compiled prompt."""
    candidates = build_prefill_prompt_candidates(
        config,
        bundle_id="com.tinyspeck.slackmacgap",
        app_name="Slack",
        explicit_mode=None,
        entities=[{"type": "person", "value": "Priya"}],
    )
    assert len(candidates) == 2
    stable_prefix = candidates[0][0]

    transcripts = [
        "we should ship the release by friday afternoon if tests stay green",
        "let us meet at 3 pm no no make that 6 pm full stop",
        "three priorities today first fix the brakes second ship the rocket emoji third reply",
        "scratch all of that just tell him I will call back tomorrow morning",
    ]
    for text in transcripts:
        gate = run_gate(
            text,
            config,
            bundle_id="com.tinyspeck.slackmacgap",
            app_name="Slack",
            entities=[{"type": "person", "value": "Priya"}],
        )
        assert gate.use_llm is True
        assert gate.system_prompt is not None
        assert gate.system_prompt.startswith(stable_prefix), (
            f"KV prefix busted for transcript: {text!r}"
        )


def test_plain_prose_emits_minimal_rules_and_no_unneeded_examples(config):
    gate = run_gate(
        "we should probably move the quarterly planning meeting to next Tuesday afternoon",
        config,
    )
    assert gate.active_rules == ("prose",)
    assert gate.examples == ()
    assert "Self-corrections" not in (gate.system_prompt or "")
    assert "Spoken punctuation" not in (gate.system_prompt or "")
    assert "Homophones" not in (gate.system_prompt or "")
    assert "Emoji:" not in (gate.system_prompt or "")


def test_emoji_rule_requires_explicit_cue_and_respects_light_mode(config):
    # Bare word "fire" MUST NOT trigger emoji rule.
    bare = run_gate("that party last night was fire and everyone stayed really late", config)
    assert "emoji" not in bare.active_rules

    # Explicit "rocket emoji" triggers emoji rule + positive/negative few-shot pair.
    explicit = run_gate(
        "great job on the launch rocket emoji we shipped ahead of schedule",
        config,
    )
    assert "emoji" in explicit.active_rules
    assert "🚀" in (explicit.system_prompt or "")
    assert any("rocket emoji" in u for u, _ in explicit.examples)
    assert any("emoji picker" in u for u, _ in explicit.examples)

    # formatting="light" (Code mode) keeps emoji OFF even with explicit cue.
    light = run_gate(
        "great job on the launch rocket emoji we shipped ahead of schedule",
        config,
        explicit_mode="Code",
    )
    assert light.mode.formatting == "light"
    assert "emoji" not in light.active_rules


def test_homophones_emit_only_matched_families(config):
    gate = run_gate(
        "the car breaks failed right before the grocery isle this morning",
        config,
    )
    assert "homophones" in gate.active_rules
    prompt = gate.system_prompt or ""
    assert "brakes" in prompt
    assert "aisle" in prompt
    # Unrelated homophone families must not bloat the prompt.
    assert "stationery" not in prompt
    assert "cereal" not in prompt


def test_take_backs_and_self_correction_include_positive_and_negative_examples(config):
    gate = run_gate(
        "that was my thinking on pricing scratch all of that just tell him i will call back",
        config,
    )
    assert "self_correction" in gate.active_rules
    assert "take_backs" in gate.active_rules
    assert any("scratch all of that" in u for u, _ in gate.examples)
    assert any("oh sorry i'm late" in u for u, _ in gate.examples)


def test_few_shot_examples_respect_hard_cap(config):
    kitchen_sink = (
        "three priorities today first check the car breaks full stop "
        "second rocket emoji no no scratch that change the previous line "
        "and make it 6 pm new line third verify the isle"
    )
    gate = run_gate(kitchen_sink, config)
    assert len(gate.examples) <= MAX_FEW_SHOT_EXAMPLES
    assert len(gate.examples) >= 4


def test_markers_only_list_counter_examples_stay_prose(config):
    counter_examples = (
        "the tasks are moving along nicely and we expect a smooth release tomorrow",
        "we should book four rooms five desks for the offsite next month",
        "it was my first time visiting the second floor of the new office building",
    )
    for raw in counter_examples:
        gate = run_gate(raw, config)
        assert "lists" not in gate.active_rules, raw
        assert "prose" in gate.active_rules, raw


def test_cue_detector_multilingual_punctuation():
    cues = detect_cues("bonjour tout le monde virgule comment ca va")
    assert cues.has("spoken_punctuation")
