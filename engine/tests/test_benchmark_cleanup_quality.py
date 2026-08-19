"""Regression tests for the exact-model cleanup benchmark's verdicts."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_cleanup_quality import (  # noqa: E402
    MODEL_ID,
    MODEL_REVISION,
    S1_MINI_MODEL_ID,
    S1_MINI_REVISION,
    Case,
    evaluate_candidate,
    resolve_benchmark_model,
    s1_mini_prompt,
    validate,
)


def test_s1_mini_candidate_uses_exact_documented_control_shape():
    system, user = s1_mini_prompt(Case(
        "fixture",
        "send the report by friday",
        bundle_id="com.apple.mail",
        numbered_items=3,
    ))

    assert system.startswith("You are a text normalizer")
    assert user.startswith(
        "[Styling: semi-formal] [Structure: prose] [Context: email]\n"
    )
    assert user.endswith("send the report by friday")


def test_s1_mini_control_does_not_leak_the_expected_answer():
    prose = s1_mini_prompt(Case(
        "prose", "same input", numbered_items=0,
    ))
    list_expected = s1_mini_prompt(Case(
        "list", "same input", numbered_items=3,
    ))

    assert prose == list_expected


def test_benchmark_pins_baseline_and_candidate_snapshots(monkeypatch, tmp_path):
    calls: list[dict] = []

    def fake_snapshot_download(**kwargs):
        calls.append(kwargs)
        return str(tmp_path)

    monkeypatch.setattr(
        "huggingface_hub.snapshot_download", fake_snapshot_download)

    assert resolve_benchmark_model(MODEL_ID) == str(tmp_path)
    assert resolve_benchmark_model(S1_MINI_MODEL_ID) == str(tmp_path)
    assert calls == [
        {
            "repo_id": MODEL_ID,
            "revision": MODEL_REVISION,
            "local_files_only": True,
        },
        {
            "repo_id": S1_MINI_MODEL_ID,
            "revision": S1_MINI_REVISION,
            "local_files_only": True,
        },
    ]


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


def _summary(
    model: str,
    *,
    failed_cases=(),
    p50=1000.0,
    p95=1500.0,
    active_bytes=4_000_000_000,
):
    return {
        "model": model,
        "failed_cases": list(failed_cases),
        "p50_wall_ms": p50,
        "p95_wall_ms": p95,
        "mlx_inference": {"active_bytes": active_bytes},
    }


def test_candidate_requires_quality_speed_and_memory_improvements():
    verdict = evaluate_candidate(
        _summary("baseline"),
        _summary(
            "candidate",
            p50=700.0,
            p95=1000.0,
            active_bytes=2_000_000_000,
        ),
        min_speedup_pct=10.0,
        min_memory_reduction_pct=10.0,
    )

    assert verdict["accepted"] is True
    assert verdict["p50_speedup_pct"] == 30.0
    assert verdict["active_memory_reduction_pct"] == 50.0


def test_candidate_rejects_any_absolute_quality_failure():
    verdict = evaluate_candidate(
        _summary("baseline", failed_cases=("old_failure",)),
        _summary(
            "candidate",
            failed_cases=("old_failure", "new_failure"),
            p50=500.0,
            p95=700.0,
            active_bytes=1_000_000_000,
        ),
        min_speedup_pct=10.0,
        min_memory_reduction_pct=10.0,
    )

    assert verdict["accepted"] is False
    assert any(
        failure.startswith("candidate_quality_failures:")
        for failure in verdict["failures"]
    )
    assert "new_quality_failures:new_failure" in verdict["failures"]
