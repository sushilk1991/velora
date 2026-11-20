"""Table-driven unit tests for V-08 deterministic pre-passes."""

from __future__ import annotations

import pytest

from velora_engine.formatting import run_gate
from velora_engine.prepasses import spoken_numbers_to_digits, undo_title_case


# ---- undo_title_case ---------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "protected", "expected"),
    [
        # Classic Whisper Title Case artefact.
        (
            "We Need To Ship The Release Before Friday Tomorrow.",
            (),
            "We need to ship the release before Friday tomorrow.",
        ),
        # Preserves pronoun I, contractions, months, days, and acronyms.
        (
            "I'm Going To Update The API In January On Monday.",
            (),
            "I'm going to update the API in January on Monday.",
        ),
        # Preserves sentence starts across multiple sentences and newlines.
        (
            "We Need To Fix The Bug. The Build Is Still Failing.\nPlease Check The Logs.",
            (),
            "We need to fix the bug. The build is still failing.\nPlease check the logs.",
        ),
        # Preserves dictionary / entity proper nouns (including multi-word terms).
        (
            "We Need To Test Velora With Claude Code And AirPods Today.",
            ("Velora", "Claude Code", "AirPods"),
            "We need to test Velora with Claude Code and AirPods today.",
        ),
        # Preserves backticked and quoted spans verbatim.
        (
            'We Need To Rename "The Title Case" And `MyClassName` In The File.',
            (),
            'We need to rename "The Title Case" and `MyClassName` in the file.',
        ),
    ],
)
def test_undo_title_case_repairs_artefact(raw, protected, expected):
    assert undo_title_case(raw, protected_terms=protected) == expected


@pytest.mark.parametrize(
    "raw",
    [
        # Normal prose with proper nouns must stay untouched.
        "I met Priya Menon in New York to discuss SwiftPM and Core Audio.",
        # Proper noun list has no mid-sentence function words -> must stay untouched.
        "Priya Menon, Rahul Sharma, Omar Khan, Ananya Gupta",
        # Short titles (<5 words) stay untouched.
        "The New York Times",
        "Visual Studio Code",
        # All-caps shouting stays untouched.
        "STOP THE BUILD RIGHT NOW PLEASE",
        # Empty / short strings stay untouched.
        "",
        "Hello World",
    ],
)
def test_undo_title_case_false_positives_untouched(raw):
    assert undo_title_case(raw) == raw


# ---- spoken_numbers_to_digits ------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        # Currency
        ("it costs five dollars", "it costs $5"),
        ("that was twenty five dollars and fifty cents", "that was $25.50"),
        ("we paid two thousand five hundred dollars", "we paid $2,500"),
        ("they raised three point five million dollars", "they raised $3.5 million"),
        ("the ticket is forty euros", "the ticket is €40"),
        # Percentages
        ("latency dropped twenty percent", "latency dropped 20%"),
        ("accuracy is ninety nine point five percent", "accuracy is 99.5%"),
        ("margin rose five per cent", "margin rose 5%"),
        # Decimals
        ("pi is three point one four", "pi is 3.14"),
        ("threshold is zero point five", "threshold is 0.5"),
        ("version two point five ships soon", "version 2.5 ships soon"),
        # Clock times
        ("let us meet at three thirty pm", "let us meet at 3:30 pm"),
        ("alarm set for six oh five a.m.", "alarm set for 6:05 a.m."),
        ("call starts at six pm", "call starts at 6 pm"),
        ("dinner is at nine o'clock", "dinner is at 9 o'clock"),
        # Years
        ("born in nineteen eighty four", "born in 1984"),
        ("built in nineteen oh five", "built in 1905"),
        ("launched in two thousand twenty four", "launched in 2024"),
        ("since two thousand and eight", "since 2008"),
        ("shipping in twenty twenty six", "shipping in 2026"),
        ("twenty twenty six roadmap", "2026 roadmap"),
        # Date ordinals & compound ordinals
        ("due on March twenty first", "due on March 21st"),
        ("on the fourth of July", "on the 4th of July"),
        ("my twenty first birthday", "my 21st birthday"),
        # Unit-qualified counts
        ("takes five minutes", "takes 5 minutes"),
        ("uses eight gigabytes of RAM", "uses 8 gigabytes of RAM"),
        ("wait two hundred milliseconds", "wait 200 milliseconds"),
        ("in three days we ship", "in 3 days we ship"),
        ("about two weeks ago", "about 2 weeks ago"),
        ("costs five hundred rupees", "costs 500 rupees"),
        # Duration "thirty second timeout" becomes "30 second timeout", never "32nd timeout".
        ("use a thirty second timeout for the worker", "use a 30 second timeout for the worker"),
        # Multi-word compound cardinals (>= 21 or >= 100)
        ("we fixed twenty five bugs", "we fixed 25 bugs"),
        ("about one hundred twenty users", "about 120 users"),
        ("over two thousand five hundred tests", "over 2,500 tests"),
    ],
)
def test_spoken_numbers_to_digits_converts_determinate_cases(raw, expected):
    assert spoken_numbers_to_digits(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        # Classic false positives that must NEVER digitize.
        "one of the things we need to fix",
        "no one knows why that failed",
        "a good one to start with",
        "one day we will rewrite it",
        "wait one second please",
        "give me one minute",
        "at this point we should stop",
        "that is a very good point",
        "first of all we should test",
        "I am having second thoughts",
        "count from one to ten",
        "there are three priorities today first update the app second publish the post",
        "he has twenty twenty vision",
        # Quoted and backticked spans stay verbatim.
        "run `twenty five dollars` verbatim",
        'she wrote "five minutes" on the board',
    ],
)
def test_spoken_numbers_to_digits_preserves_false_positives(raw):
    assert spoken_numbers_to_digits(raw) == raw


# ---- run_gate integration ----------------------------------------------------


def test_run_gate_applies_prepasses_on_prose_and_skips_verbatim_modes(config):
    title_raw = "We Need To Save Twenty Five Dollars Before Friday Next Week"
    gate = run_gate(title_raw, config)
    assert gate.use_llm is True
    assert gate.text == "We need to save $25 before Friday next week"

    # Short utterance path also digitizes determinate forms.
    short = run_gate("meet at six pm", config)
    assert short.use_llm is False
    assert short.text == "Meet at 6 pm."

    # Raw mode stays strictly untouched.
    raw_gate = run_gate(title_raw, config, explicit_mode="Raw")
    assert raw_gate.use_llm is False
    assert raw_gate.text == title_raw

    # Short terminal command stays verbatim.
    term_gate = run_gate("echo twenty five dollars", config, bundle_id="com.apple.Terminal")
    assert term_gate.use_llm is False
    assert term_gate.text == "echo twenty five dollars"
