"""Acceptance-rule tests for the STT backend bakeoff."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_stt_backends import (  # noqa: E402
    BenchmarkCase,
    CaseResult,
    _glossary_score,
    evaluate,
    validate_coverage,
)


def test_candidate_passes_only_when_p50_and_p95_clear_ten_percent():
    results = [
        CaseResult(
            name=f"case-{index}",
            cohort="indian_english",
            reference_words=10,
            baseline_errors=1,
            candidate_errors=1,
            baseline_glossary=(1, 1),
            candidate_glossary=(1, 1),
            baseline_ms=100.0 + index,
            candidate_ms=80.0 + index,
            baseline_failure=False,
            candidate_failure=False,
        )
        for index in range(20)
    ]

    verdict = evaluate(results, min_speedup_pct=10.0)

    assert verdict.accepted is True
    assert verdict.failures == ()
    assert verdict.p50_speedup_pct >= 10.0
    assert verdict.p95_speedup_pct >= 10.0


def test_candidate_fails_for_any_cohort_glossary_or_guard_regression():
    results = [
        CaseResult(
            name="hindi-quality",
            cohort="hindi",
            reference_words=10,
            baseline_errors=1,
            candidate_errors=2,
            baseline_glossary=(2, 2),
            candidate_glossary=(1, 2),
            baseline_ms=100.0,
            candidate_ms=50.0,
            baseline_failure=False,
            candidate_failure=True,
        )
    ]

    verdict = evaluate(results)

    assert verdict.accepted is False
    assert "quality_regression:hindi:2>1" in verdict.failures
    assert "glossary_regression:0.500<1.000" in verdict.failures
    assert "new_guard_or_stitch_failures:1" in verdict.failures


def test_full_gate_requires_target_languages_silence_and_long_audio():
    cases = [
        BenchmarkCase("english", Path("en.wav"), "hello", "indian_english", ()),
        BenchmarkCase("hindi", Path("hi.wav"), "नमस्ते", "hindi", ()),
        BenchmarkCase("hinglish", Path("mix.wav"), "kal meeting", "hinglish", ()),
    ]

    failures = validate_coverage(cases, [5.0, 5.0, 5.0], min_cases=18)

    assert "insufficient_cases:3<18" in failures
    assert "missing_silence_or_noise_case" in failures
    assert "missing_long_case:need_at_least_45s" in failures


def test_candidate_must_keep_up_with_live_audio_ingestion():
    result = CaseResult(
        name="slow-stream",
        cohort="indian_english",
        reference_words=2,
        baseline_errors=0,
        candidate_errors=0,
        baseline_glossary=(0, 0),
        candidate_glossary=(0, 0),
        baseline_ms=100.0,
        candidate_ms=50.0,
        baseline_failure=False,
        candidate_failure=False,
        baseline_ingest_rtf=0.4,
        candidate_ingest_rtf=1.01,
    )

    verdict = evaluate([result])

    assert verdict.accepted is False
    assert "candidate_ingest_rtf:1.010>0.900" in verdict.failures


def test_glossary_recall_uses_whole_normalized_token_sequences():
    glossary = ("art", "New Delhi", "SwiftUI")

    assert _glossary_score("cart in new, Delhi; with SwiftUI", glossary) == (2, 3)
