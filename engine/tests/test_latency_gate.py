"""The stop-to-final latency gate: percentile math, the limit rule, and proof
that a real slowdown fails it.

The gate runs the engine's own stages (fake STT in fake mode) so these tests
execute it as a subprocess, exactly as CI or a developer would. The negative
control is the point: a gate that cannot fail is decoration.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ENGINE = Path(__file__).resolve().parents[1]
GATE = ENGINE / "scripts" / "latency_gate.py"
BASELINE = ENGINE / "tests" / "fixtures" / "latency_baseline.json"

sys.path.insert(0, str(ENGINE))

from scripts import latency_gate as gate  # noqa: E402


def run_gate(*arguments: str, baseline: Path | None = None) -> subprocess.CompletedProcess:
    environment = dict(os.environ)
    environment["PYTHONPATH"] = str(ENGINE / "src")
    # The gate isolates itself in fake mode; do not hand it a test's home or a
    # stray fake-STT switch from an outer harness.
    environment.pop("VELORA_FAKE_STT", None)
    environment.pop("VELORA_HOME", None)
    if baseline is not None:
        environment["VELORA_LATENCY_BASELINE"] = str(baseline)
    return subprocess.run(
        [sys.executable, str(GATE), *arguments],
        capture_output=True, text=True, timeout=180, env=environment,
    )


# ---- percentile math -------------------------------------------------------


def test_percentile_uses_linear_interpolation():
    values = [4.0, 1.0, 3.0, 2.0]
    assert gate.percentile(values, 0.0) == 1.0
    assert gate.percentile(values, 0.5) == 2.5
    assert gate.percentile(values, 1.0) == 4.0
    # p95 of four values interpolates 85 % of the way from 3 to 4.
    assert gate.percentile(values, 0.95) == pytest.approx(3.85)
    # Sorting is the function's job: a shuffled sample is the same sample.
    assert gate.percentile([4.0, 2.0, 1.0, 3.0], 0.95) == pytest.approx(3.85)


def test_percentile_handles_one_value_and_rejects_nonsense():
    assert gate.percentile([7.5], 0.5) == 7.5
    assert gate.percentile([7.5], 0.95) == 7.5
    with pytest.raises(ValueError):
        gate.percentile([], 0.5)
    with pytest.raises(ValueError):
        gate.percentile([1.0], 1.5)


def test_summarise_reports_both_stages_and_totals():
    rows = [
        {"stt_ms": 10.0, "cleanup_ms": 2.0, "total_ms": 12.0},
        {"stt_ms": 20.0, "cleanup_ms": 4.0, "total_ms": 24.0},
        {"stt_ms": 30.0, "cleanup_ms": 6.0, "total_ms": 36.0},
    ]
    summary = gate.summarise(rows)
    assert summary["takes"] == 3
    assert summary["p50_ms"] == 24.0
    assert summary["max_ms"] == 36.0
    assert summary["p95_ms"] == pytest.approx(34.8)
    assert summary["stt_p95_ms"] == pytest.approx(29.0)
    assert summary["cleanup_p95_ms"] == pytest.approx(5.8)


# ---- the limit rule --------------------------------------------------------


def test_limit_takes_the_larger_of_percentage_and_floor():
    # A slow baseline is governed by the percentage.
    assert gate.limit_for(100.0) == pytest.approx(115.0)
    # A sub-millisecond baseline is governed by the absolute floor, so jitter
    # in fake mode cannot flake the gate.
    assert gate.limit_for(0.9) == pytest.approx(2.9)
    assert gate.limit_for(0.9, max_regression_pct=100.0) == pytest.approx(2.9)


def test_evaluate_accepts_within_the_limit_and_rejects_beyond_it():
    slow = {"p95_ms": 100.0}
    assert gate.evaluate({"p95_ms": 100.0}, slow)["passed"]
    accepted = gate.evaluate({"p95_ms": 114.9}, slow)
    assert accepted["passed"] and accepted["limit_ms"] == pytest.approx(115.0)
    rejected = gate.evaluate({"p95_ms": 116.0}, slow)
    assert not rejected["passed"]
    assert rejected["delta_pct"] == pytest.approx(16.0)

    fast = {"p95_ms": 0.9}
    assert gate.evaluate({"p95_ms": 2.8}, fast)["passed"]
    assert not gate.evaluate({"p95_ms": 3.0}, fast)["passed"]


def test_regression_message_names_both_numbers():
    message = gate.regression_message(
        "fake", gate.evaluate({"p95_ms": 40.0}, {"p95_ms": 0.9}))
    assert message.startswith("latency regression (fake):")
    assert "40.000 ms" in message and "2.900 ms" in message


# ---- the checked-in baseline ----------------------------------------------


def test_checked_in_baseline_describes_fake_mode():
    assert BASELINE.exists(), "engine/tests/fixtures/latency_baseline.json is missing"
    data = json.loads(BASELINE.read_text())
    assert data["format"] == gate.BASELINE_FORMAT
    section = data["baselines"]["fake"]
    assert section["takes"] >= 4
    assert section["p95_ms"] > 0
    # A live baseline is recorded by hand on real hardware; absent is correct.
    assert "live" not in data["baselines"]


# ---- the gate itself -------------------------------------------------------


def test_gate_passes_against_the_checked_in_baseline():
    result = run_gate("--takes", "5")
    assert result.returncode == 0, result.stderr
    assert "fake: 5 takes" in result.stdout


def test_injected_delay_fails_the_gate():
    """The negative control: a 40 ms regression must fail, loudly."""
    result = run_gate("--takes", "3", "--inject-delay-ms", "40")
    assert result.returncode == 1, (
        f"the gate passed a 40 ms delay — it cannot detect regressions\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}")
    assert "latency regression (fake)" in result.stderr
    assert "exceeds" in result.stderr


def test_write_baseline_records_the_run_and_a_second_run_passes(tmp_path):
    baseline = tmp_path / "latency_baseline.json"
    written = run_gate("--takes", "4", "--write-baseline", "--baseline", str(baseline))
    assert written.returncode == 0, written.stderr
    data = json.loads(baseline.read_text())
    assert data["format"] == gate.BASELINE_FORMAT
    assert data["baselines"]["fake"]["takes"] == 4
    assert data["baselines"]["fake"]["p95_ms"] > 0

    compared = run_gate("--takes", "4", "--baseline", str(baseline))
    assert compared.returncode == 0, compared.stderr


def test_missing_mode_baseline_fails_before_loading_a_model(tmp_path):
    """A live run with no live baseline says so instead of loading weights and
    then complaining."""
    baseline = tmp_path / "latency_baseline.json"
    baseline.write_text(json.dumps({
        "format": gate.BASELINE_FORMAT,
        "baselines": {"fake": {"takes": 4, "p50_ms": 1.0, "p95_ms": 1.2}},
    }))
    result = run_gate("--live", "--takes", "2", "--baseline", str(baseline))
    assert result.returncode == 2
    assert "no live baseline" in result.stderr
    assert "--live --write-baseline" in result.stderr
