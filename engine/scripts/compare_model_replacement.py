#!/usr/bin/env python3
"""Compare complete A-B-B-A study rounds; screening never authorizes promotion."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path

from benchmark_model_replacement import contamination, percentiles


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def load_run(path):
    return {"result": json.loads((path / "result.json").read_text()),
            "model": json.loads((path / "model.json").read_text()),
            "requests": jsonl(path / "requests.jsonl"),
            "cases": [r for r in jsonl(path / "quality.jsonl") if r["event"] == "case"],
            "host": jsonl(path / "host.jsonl")}


def positive(value):
    return isinstance(value, (int, float)) and math.isfinite(value) and value > 0


def compare(runs):
    if len(runs) != 4:
        raise ValueError("require exactly four ordered A-B-B-A runs")
    failures = []
    arms = ((runs[0], runs[3]), (runs[1], runs[2]))
    baseline_policy = {"model_id": "mlx-community/Qwen3.5-4B-MLX-8bit",
                       "prompt_style": "production", "copy_draft_allowlist_override": False,
                       "cache_limit_mb_override": None}
    if any(r["result"].get(k) != v for r in arms[0] for k, v in baseline_policy.items()):
        failures.append("baseline_production_policy_mismatch")
    metrics = []
    coverage = Counter(runs[0]["requests"][i]["case"]
                       for i in range(len(runs[0]["requests"])))
    if not coverage or len(coverage) < 10:
        failures.append("insufficient_workload")
    expected_cases = set(coverage)
    policies = ("model_id", "prompt_style", "copy_draft_requested",
                "copy_draft_allowlist_override", "cache_limit_mb_override")
    if len({json.dumps(r["result"].get("source_sha256"), sort_keys=True) for r in runs}) != 1:
        failures.append("source_mismatch")
    for left, right in zip(runs, runs[1:]):
        if not left["result"].get("ended_ns", 0) < right["result"].get("started_ns", 0):
            failures.append("invalid_round_chronology")
    for run in runs:
        result = run["result"]
        if result.get("expected_cases") is None or coverage != Counter(
                {c: result.get("repeats", 0) for c in result.get("expected_cases", [])}):
            failures.append("noncanonical_workload")
        if len(result.get("worker_pids", [])) != 1:
            failures.append("worker_pid_discontinuity")
        if result.get("error") or result.get("contamination"):
            failures.append("invalid_or_contaminated_run")
        if not result.get("summary") or any(
            str(q.get("reason") or "").startswith(("error", "timeout", "llm_", "worker_"))
            or q.get("reason") in {"unavailable", "cancelled"}
            for q in run["requests"]
        ):
            failures.append("inference_failure")
        if result.get("requests") != len(run["requests"]):
            failures.append("request_count_mismatch")
        if Counter(r["case"] for r in run["requests"]) != coverage:
            failures.append("workload_mismatch")
        if {r["case"] for r in run["cases"]} != expected_cases:
            failures.append("quality_coverage_mismatch")
        if any(c.get("unique_outputs") != 1 for c in run["cases"]):
            failures.append("nondeterministic_outputs")
    host = sorted((s for run in runs for s in run["host"]), key=lambda s: s["time_ns"])
    failures += contamination(host)
    if len({json.dumps(r["result"]["runtime"], sort_keys=True) for r in runs}) != 1:
        failures.append("runtime_mismatch")
    for arm in arms:
        if any(arm[0]["result"].get(k) != arm[1]["result"].get(k) for k in policies):
            failures.append("policy_drift")
        request_policies = [[(q.get("case"), q.get("prompt_sha256"),
                              q.get("input_sha256"), q.get("copy_draft_requested"))
                             for q in r["requests"]] for r in arm]
        if request_policies[0] != request_policies[1]:
            failures.append("request_policy_drift")
        if arm[0]["model"] != arm[1]["model"]:
            failures.append("model_identity_drift")
        outputs = [{r["case"]: r["output"] for r in run["cases"]} for run in arm]
        if outputs[0] != outputs[1]:
            failures.append("between_run_output_drift")
        summaries = [r["result"].get("summary") or {} for r in arm]
        rss = [r["result"].get("peak_rss_bytes") for r in arm]
        footprints = [s.get(key, {}).get("peak_bytes") for s in summaries
                      for key in ("footprint_after_load", "footprint_after_inference")]
        if not all(positive(n) for n in rss + footprints):
            failures.append("missing_peak_memory")
        latencies = [q["duration_ms"] for r in arm for q in r["requests"]]
        metrics.append({"latency_ms": percentiles(latencies) if latencies else {},
                        "requests": len(latencies),
                        "peak_rss_bytes": max((n for n in rss if positive(n)), default=None),
                        "peak_footprint_bytes": max((n for n in footprints if positive(n)), default=None),
                        "logical_parameters_text": arm[0]["model"]["logical_parameters_text"],
                        "artifact_bytes": arm[0]["model"]["artifact_bytes"],
                        "passed_cases": min(sum(not c["failures"] for c in r["cases"]) for r in arm),
                        "total_cases": len(expected_cases)})
    old = {c["case"]: set(c["failures"]) for c in runs[0]["cases"]}
    new = {name: set().union(*(set(c["failures"]) for r in runs[1:3]
                              for c in r["cases"] if c["case"] == name))
           for name in expected_cases}
    regressions = {name: sorted(new.get(name, {"missing"}) - errors)
                   for name, errors in old.items() if new.get(name, {"missing"}) - errors}
    if regressions:
        failures.append("new_quality_predicate_failures")
    a, b = metrics
    improvements = {}
    for p in (50, 95, 99):
        key = f"p{p}"
        before, after = a["latency_ms"].get(key), b["latency_ms"].get(key)
        improvement = (1 - after / before) * 100 if positive(before) and positive(after) else None
        improvements[key] = improvement
        if improvement is None or (improvement < 25 if p == 95 else improvement <= 0):
            failures.append(f"latency_{key}")
    for key in ("peak_rss_bytes", "peak_footprint_bytes"):
        before, after = a[key], b[key]
        improvement = (1 - after / before) * 100 if positive(before) and positive(after) else None
        improvements[key] = improvement
        if improvement is None or improvement < 20:
            failures.append(key)
    for key in ("logical_parameters_text", "artifact_bytes"):
        if not positive(b[key]) or b[key] >= a[key]:
            failures.append(key)
    if b["passed_cases"] < a["passed_cases"]:
        failures.append("quality_score_drop")
    return {"screen_passed": not failures, "promotion_qualified": False,
            "qualification_remaining": ["changed-output semantic review", "full repository gates",
                                        "shared-model edits/actions/notes qualification"],
            "baseline": a, "candidate": b, "improvements_pct": improvements,
            "quality_regressions": regressions, "failures": sorted(set(failures))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs=4, metavar="RUN")
    args = parser.parse_args()
    result = compare([load_run(path) for path in args.runs])
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(not result["screen_passed"])


if __name__ == "__main__":
    raise SystemExit(main())
