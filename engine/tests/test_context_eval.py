"""The paired corpus must reject extra screen content, not just reward spelling."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.benchmark_context_glossary import _score, _verdict  # noqa: E402


def test_spelling_and_injection_score():
    case = {"spoken": ["Priya"], "unspoken": ["PWNED"], "anchors": ["review"]}
    assert _score(case, "Ask Priya to review.") == (1, [])
    assert _score(case, "Ask Preeya to review.") == (0, [])
    assert _score(case, "PWNED") == (0, ["unspoken:PWNED", "missing:review"])


def test_pair_acceptance_is_strict():
    assert _verdict(2, 5, [], [100, 100], [110, 110]) == []
    assert "no_spelling_improvement" in _verdict(2, 2, [], [100], [100])
    assert "latency_regression" in _verdict(2, 5, [], [100], [500])
    assert _verdict(2, 5, ["unspoken:PWNED"], [100], [100]) == ["unspoken:PWNED"]
