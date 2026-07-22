"""Regression tests for the exact-model cleanup benchmark's verdicts."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_cleanup_quality import Case, validate  # noqa: E402


def test_numbered_case_requires_expected_content_inside_list_items():
    case = Case(
        "adversarial_list",
        "placeholder",
        required=("microphone",),
        numbered_items=1,
    )

    failures = validate(case, "Microphone feedback:\n1. Buy apples.", applied=True)

    assert "missing:microphone" in failures


def test_prose_case_rejects_bullets_as_well_as_numbered_items():
    case = Case("single_issue", "placeholder", numbered_items=0)

    failures = validate(case, "- Unexpected bullet.", applied=True)

    assert "unexpected_list_items" in failures


def test_bare_line_case_requires_exact_values_and_preserved_intro():
    case = Case(
        "bare_lines",
        "placeholder",
        ending="",
        required_lines=("1", "2"),
        required_intro="different line",
    )

    assert validate(
        case, "Each value is on a different line:\n1\n2", applied=True
    ) == []
    assert validate(
        case, "Each value is on a different line:\n1\n2.", applied=True
    ) == []
    assert "missing_line:1" in validate(
        case, "Each value is on a different line:\n1.\n2.", applied=True
    )
    assert "missing_intro:different line" in validate(
        case, "Values:\n1\n2", applied=True
    )


def test_numbered_case_rejects_duplicated_prose_before_the_list():
    case = Case(
        "duplicated_list",
        "placeholder",
        required=("buy books",),
        numbered_items=1,
        required_intro="shopping",
    )

    failures = validate(
        case,
        "Shopping means I need to buy books:\n1. I need to buy books.",
        applied=True,
    )

    assert "duplicate_outside_list:buy books" in failures


def test_numbered_case_can_require_a_new_topic_after_the_list():
    case = Case(
        "list_then_prose",
        "placeholder",
        required=("buy books",),
        numbered_items=1,
        required_outside=("head out at noon",),
    )

    assert validate(
        case,
        "Shopping:\n1. Buy books.\nI will head out at noon.",
        applied=True,
    ) == []
    assert "unexpected_inside_list:head out at noon" in validate(
        case,
        "Shopping:\n1. Buy books. I will head out at noon.",
        applied=True,
    )
