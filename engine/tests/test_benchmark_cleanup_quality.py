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
