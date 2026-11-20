"""Unit tests for V-12 Step 1 phonetic post-decode glossary corrector."""

from __future__ import annotations

import pytest

from velora_engine.formatting import postprocess, run_gate
from velora_engine.phonetic_glossary import apply_phonetic_glossary, phonetic_key


@pytest.mark.parametrize(
    ("raw", "terms", "expected"),
    [
        # Single-word phonetic mishearings
        ("ship Velorra today", ("Velora",), "ship Velora today"),
        ("ask Preea about the release", ("Priya",), "ask Priya about the release"),
        ("open Herder in the terminal", ("Herdr",), "open Herdr in the terminal"),
        ("deploy to Kubernetties now", ("Kubernetes",), "deploy to Kubernetes now"),
        # Case normalization for exact matches
        ("push to github with swiftpm", ("GitHub", "SwiftPM"), "push to GitHub with SwiftPM"),
        # Split-word compound mishearings
        ("compare with super whisper locally", ("Superwhisper",), "compare with Superwhisper locally"),
        ("deploy on kuber netties cluster", ("Kubernetes",), "deploy on Kubernetes cluster"),
    ],
)
def test_phonetic_glossary_fixes_misheard_names(raw, terms, expected):
    assert apply_phonetic_glossary(raw, terms) == expected


@pytest.mark.parametrize(
    ("raw", "terms"),
    [
        # Common English words must NEVER be fuzzy-replaced by similar names.
        ("open the file and merge the branch", ("Kile", "Marge")),
        ("that was a great launch with clear notes", ("Gradle", "Clair")),
        ("check the phone and store the value", ("Fona", "Stora")),
        # Short acronyms (<4 letters) are excluded from fuzzy matching.
        ("the ape ate all the apples", ("API", "SQL")),
        # Quoted and backticked spans stay verbatim.
        ("keep `Velorra` and \"Preea\" unchanged", ("Velora", "Priya")),
        # Ambiguous tie between two equidistant glossary terms stays untouched.
        ("talk to Kaira tomorrow", ("Kara", "Kira")),
    ],
)
def test_phonetic_glossary_preserves_false_positives(raw, terms):
    assert apply_phonetic_glossary(raw, terms) == raw


def test_phonetic_glossary_wired_into_short_and_postprocess_paths(config):
    config.data["vocabulary"] = ["Velora", "Priya", "Superwhisper"]

    # Short utterance path (works even without LLM / on Parakeet).
    short = run_gate("ship Velorra to Preea", config)
    assert short.use_llm is False
    assert short.text == "Ship Velora to Priya."

    # LLM postprocess path.
    gate = run_gate(
        "we should compare Velorra with super whisper before messaging Preea tomorrow",
        config,
    )
    assert gate.use_llm is True
    assert postprocess("We should compare Velorra with super whisper before messaging Preea tomorrow.", gate) == (
        "We should compare Velora with Superwhisper before messaging Priya tomorrow."
    )

    # Raw mode stays strictly verbatim.
    raw_gate = run_gate("ship Velorra to Preea", config, explicit_mode="Raw")
    assert raw_gate.text == "ship Velorra to Preea"
    assert phonetic_key("Velorra") == phonetic_key("Velora")
