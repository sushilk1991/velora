#!/usr/bin/env python3
"""Run serial public64 ablations, or compare existing artifacts without inference.

The immutable baseline may contain a known length failure. Matching it is
relative runtime parity, never model qualification or semantic acceptance.
"""
import argparse
import collections
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "native" / "cleanup"
VARIANTS = {
    "copy3": [],
    "direct_argmax": ["--direct-argmax"],
    "rollback": ["--recurrent-rollback"],
    "draft2": ["--draft-max", "2"],
    "draft4": ["--draft-max", "4"],
    "draft6": ["--draft-max", "6"],
    "draft8": ["--draft-max", "8"],
    "backend": ["--backend-sampling"],
    "backend_token_only": ["--backend-sampling", "--backend-token-only"],
    "rollback_direct": ["--recurrent-rollback", "--direct-argmax"],
    "rollback4": ["--recurrent-rollback", "--draft-max", "4"],
    "rollback6": ["--recurrent-rollback", "--draft-max", "6"],
    "rollback8": ["--recurrent-rollback", "--draft-max", "8"],
}
DEFAULT_VARIANTS = "direct_argmax,rollback,draft2,draft4,draft6,draft8,backend,backend_token_only"
EXACT_FIELDS = ("status", "answer", "diagnostic_partial_text", "prompt_tokens", "output_tokens", "error")
RESPONSE_FIELDS = ("status", "text", "partial_text", "prompt_tokens", "output_tokens", "error")
READY_IDENTITY = ("model_sha256", "template_sha256", "llama_commit", "architecture", "vocab_size", "context_tokens")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_artifact(path):
    path = Path(path)
    rows, errors = [], []
    if path.exists():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                    raise ValueError("row lacks string id")
                rows.append(row)
            except (ValueError, TypeError) as exc:
                errors.append({"line": number, "error": str(exc)})
    else:
        errors.append({"error": "missing results file"})
    meta_path = Path(str(path) + ".meta.json")
    meta = {}
    try:
        meta = json.loads(meta_path.read_text())
        if not isinstance(meta, dict):
            raise ValueError("metadata is not an object")
    except (OSError, ValueError) as exc:
        errors.append({"error": "metadata: " + str(exc)})
    return {"path": str(path), "rows": rows, "meta": meta, "read_errors": errors,
            "sha256": digest(path) if path.exists() else None,
            "meta_sha256": digest(meta_path) if meta_path.exists() else None}


def finite_numbers(values):
    return [float(v) for v in values if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0]


def timings(values):
    values = sorted(finite_numbers(values))
    return {"count": len(values), "p50_ms": statistics.median(values) if values else None,
            "p95_ms": values[int(.95 * (len(values) - 1))] if values else None,
            "sum_ms": sum(values)}


def accounting(rows, expected=64):
    spans, span_counts, batches, counters = (collections.Counter() for _ in range(4))
    for row in rows:
        for key, value in (row.get("copy_draft") or {}).items():
            if key in ("proposed", "accepted", "rollbacks", "snapshot_saved_bytes", "forward_calls", "forward_tokens") and finite_numbers([value]):
                counters[key] += value
        for key in ("sampled_tokens", "filtered_rows_checked"):
            value = (row.get("backend_sampling") or {}).get(key)
            if finite_numbers([value]):
                counters["backend_" + key] += value
        trace = row.get("runtime_trace") or {}
        for key, value in trace.get("spans", {}).items():
            spans[key] += value["ms"]
            span_counts[key] += value["count"]
        batches.update(trace.get("decode_batch_sizes", {}))
    status = collections.Counter(row.get("status", "missing_status") for row in rows)
    return {
        "expected_rows": expected, "recorded_rows": len(rows),
        "status_counts": dict(status), "non_eos_ids": [row["id"] for row in rows if row.get("status") != "eos"],
        "all_recorded_latency": timings([value * 1000 for value in finite_numbers([r.get("seconds") for r in rows])]),
        "all_recorded_worker": timings([r.get("worker_ms") for r in rows]),
        "work_counters": dict(counters), "trace_span_sum_ms": dict(spans),
        "trace_span_counts": dict(span_counts), "decode_batch_sizes": dict(batches),
        "trace_warning": "Nested CPU spans; sample waits include queued GPU work. Do not sum spans as disjoint GPU time.",
    }


def recovery(meta):
    return {
        "repeat_equal": meta.get("repeat_equal") is True,
        "repeat_eos": meta.get("repeat_statuses") == ["eos", "eos"],
        "cancelled": meta.get("cancel_status") == "cancelled",
        "after_cancel_eos": meta.get("after_cancel_status") == "eos",
        "state_recovery": (meta.get("state_recovery") or {}).get("passed") is True,
        "supervisor_exit_zero": meta.get("supervisor_exit_code") == 0,
    }


def compare(baseline, candidate, expected=64):
    base_rows, rows = baseline["rows"], candidate["rows"]
    base_ids, ids = [r["id"] for r in base_rows], [r["id"] for r in rows]
    base_map, row_map = {r["id"]: r for r in base_rows}, {r["id"]: r for r in rows}
    duplicates = sorted(key for key, count in collections.Counter(ids).items() if count > 1)
    missing = [key for key in base_ids if key not in row_map]
    unexpected = [key for key in ids if key not in base_map]
    mismatches = []
    for identity in base_ids:
        if identity in row_map:
            changed = [key for key in EXACT_FIELDS if base_map[identity].get(key) != row_map[identity].get(key)]
            if changed:
                mismatches.append({"id": identity, "fields": changed})
    bm, cm = baseline["meta"], candidate["meta"]
    provenance_checks = {
        key: bm.get(key) is not None and bm.get(key) == cm.get(key)
        for key in ("model_sha256", "binary_sha256", "data_sha256", "context_tokens", "max_tokens", "temperature", "prefix_reuse")
    }
    for key in READY_IDENTITY:
        bv = bm.get("ready", {}).get(key)
        provenance_checks["ready." + key] = bv is not None and bv == cm.get("ready", {}).get(key)
    expected_source = bm.get("source_sha256", {})
    for key in ("benchmark.py", "benchmark_checks.py", "supervise.py"):
        provenance_checks["source." + key] = expected_source.get(key) is not None and expected_source.get(key) == cm.get("source_sha256", {}).get(key)
    base_recovery, current_recovery = recovery(bm), recovery(cm)
    token_only_checks = {}
    if cm.get("backend_token_only"):
        token_only_checks["worker_flag_enabled"] = cm.get("ready", {}).get("backend_token_only") is True
        token_only_checks["nonzero_filtered_samples_every_row"] = bool(rows) and all(
            (r.get("backend_sampling") or {}).get("enabled") is True
            and (r.get("backend_sampling") or {}).get("token_only") is True
            and (r.get("backend_sampling") or {}).get("sampled_tokens", 0) > 0
            and (r.get("backend_sampling") or {}).get("sampled_tokens") == (r.get("backend_sampling") or {}).get("filtered_rows_checked")
            for r in rows)
    recovery_mismatches = []
    br = (bm.get("state_recovery") or {}).get("responses", {})
    cr = (cm.get("state_recovery") or {}).get("responses", {})
    for name in ("changed_system", "restored_system", "context_error", "context_recovery"):
        if name not in br or name not in cr:
            recovery_mismatches.append({"probe": name, "fields": ["missing_response"]})
        else:
            changed = [key for key in RESPONSE_FIELDS if br[name].get(key) != cr[name].get(key)]
            if changed:
                recovery_mismatches.append({"probe": name, "fields": changed})
    complete = len(base_ids) == expected == len(ids) and len(set(base_ids)) == expected and not duplicates and not missing and not unexpected
    exact = complete and not mismatches and not candidate["read_errors"] and not baseline["read_errors"]
    passed = exact and ids == base_ids and all(provenance_checks.values()) and all(base_recovery.values()) and all(current_recovery.values()) and all(token_only_checks.values()) and not recovery_mismatches
    ratio = None
    if passed:
        values = [row_map[key].get("seconds", 0) / base_map[key]["seconds"] for key in base_ids if base_map[key].get("seconds", 0) > 0]
        ratio = statistics.median(values) if len(values) == expected else None
    trace_matched = bm.get("trace_runtime") == cm.get("trace_runtime")
    return {
        "candidate": candidate["path"], "candidate_sha256": candidate["sha256"], "candidate_meta_sha256": candidate["meta_sha256"],
        "relative_runtime_parity": passed, "model_qualified": False, "semantic_quality_evaluated": False,
        "complete_expected_rows": complete, "same_row_order": ids == base_ids,
        "missing_ids": missing, "unexpected_ids": unexpected, "duplicate_ids": duplicates,
        "exact_mismatches": mismatches, "read_errors": candidate["read_errors"],
        "provenance_checks": provenance_checks, "recovery_checks": current_recovery,
        "token_only_checks": token_only_checks,
        "recovery_mismatches": recovery_mismatches,
        "accounting": accounting(rows, expected), "matched_latency_ratio_median": ratio,
        "trace_setting_matches_baseline": trace_matched,
        "speed_comparison_eligible": passed and trace_matched and ratio is not None,
        "timing_caution": "One fresh-process comparison is diagnostic; require repeated interleaved trace-off runs for speed claims.",
        "qualification_limit": "Exact reproduction of a known length failure is relative parity only. Failed rows remain in the full timing denominator.",
    }


def write_summary(path, value):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def checked_baseline(path):
    baseline = load_artifact(path)
    rows = baseline["rows"]
    if baseline["read_errors"] or len(rows) != 64 or len({r["id"] for r in rows}) != 64:
        raise ValueError("baseline must contain exactly 64 unique valid rows and metadata")
    if any(row.get("status") not in ("eos", "length") for row in rows):
        raise ValueError("baseline has failures beyond the permitted explicit length status")
    if not all(recovery(baseline["meta"]).values()):
        raise ValueError("baseline recovery probes did not all pass")
    return baseline


def assert_unchanged(baseline):
    if digest(baseline["path"]) != baseline["sha256"] or digest(baseline["path"] + ".meta.json") != baseline["meta_sha256"]:
        raise RuntimeError("immutable baseline changed during ablations")


def run_process(command, log_path, timeout):
    started = time.monotonic()
    with open(log_path, "x") as log:
        child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                code = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                code = child.wait()
        except BaseException:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise
    return {"returncode": code, "timed_out": timed_out, "wall_seconds": time.monotonic() - started}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    for name in ("run", "compare"):
        p = sub.add_parser(name)
        p.add_argument("--baseline", required=True)
        if name == "compare":
            p.add_argument("--candidate", action="append", required=True)
            p.add_argument("--out", required=True)
        else:
            p.add_argument("--binary", required=True)
            p.add_argument("--model", required=True)
            p.add_argument("--sha256", required=True)
            p.add_argument("--data", required=True)
            p.add_argument("--out-dir", required=True)
            p.add_argument("--variants", default=DEFAULT_VARIANTS)
            p.add_argument("--repetitions", type=int, default=1)
            p.add_argument("--trace-runtime", action="store_true")
            p.add_argument("--timeout", type=float, default=300)
            p.add_argument("--lock", default="/tmp/velora-bench.lock")
    args = parser.parse_args()
    baseline = checked_baseline(args.baseline)
    summary = {"baseline": baseline["path"], "baseline_sha256": baseline["sha256"],
               "baseline_meta_sha256": baseline["meta_sha256"], "baseline_accounting": accounting(baseline["rows"]),
               "model_qualified": False, "semantic_quality_evaluated": False, "comparisons": []}
    if args.operation == "compare":
        if Path(args.out).exists():
            raise FileExistsError(args.out)
        summary["comparisons"] = [compare(baseline, load_artifact(path)) for path in args.candidate]
        assert_unchanged(baseline)
        write_summary(args.out, summary)
    else:
        variants = args.variants.split(",")
        if not variants or any(name not in VARIANTS for name in variants) or len(set(variants)) != len(variants):
            parser.error("variants must be distinct names from: " + ",".join(VARIANTS))
        if not 1 <= args.repetitions <= 10 or not 1 <= args.timeout <= 3600:
            parser.error("repetitions must be1..10; timeout1..3600 seconds")
        bm = baseline["meta"]
        if digest(args.binary) != bm["binary_sha256"] or digest(args.data) != bm["data_sha256"] or args.sha256 != bm["model_sha256"]:
            raise ValueError("binary, model identity or data differs from immutable baseline")
        data_rows = [json.loads(line) for line in Path(args.data).read_text().splitlines() if line.strip()]
        if len(data_rows) != 64 or any(row.get("visibility") != "public" for row in data_rows):
            raise ValueError("exactly64 public rows required")
        if [r["id"] for r in data_rows] != [r["id"] for r in baseline["rows"]]:
            raise ValueError("data identity/order differs from baseline")
        out_dir = Path(args.out_dir).resolve()
        out_dir.mkdir(parents=True, exist_ok=False)
        summary_path = out_dir / "summary.json"
        summary["requested_order"] = variants
        summary["repetitions"] = args.repetitions
        write_summary(summary_path, summary)
        with open(args.lock, "a+") as lock:
            # Fail immediately instead of waiting behind an unobserved GPU job.
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            for repetition in range(args.repetitions):
                for name in variants if repetition % 2 == 0 else reversed(variants):
                    assert_unchanged(baseline)
                    if digest(args.binary) != bm["binary_sha256"]:
                        raise RuntimeError("binary changed during matrix")
                    out = out_dir / f"{repetition + 1:02d}-{name}.jsonl"
                    command = [sys.executable, str(NATIVE / "benchmark.py"), "--binary", str(Path(args.binary).resolve()),
                               "--model", str(Path(args.model).resolve()), "--sha256", args.sha256,
                               "--data", str(Path(args.data).resolve()), "--out", str(out),
                               "--limit", "64", "--context", str(bm["context_tokens"]), "--copy-draft"]
                    if bm.get("prefix_reuse"):
                        command.append("--prefix-cache")
                    if args.trace_runtime:
                        command.append("--trace-runtime")
                    command += VARIANTS[name]
                    # benchmark.py imports the frozen public training renderer.
                    old_path = os.environ.get("PYTHONPATH")
                    os.environ["PYTHONPATH"] = str(ROOT / "training" / "cleanup") + (os.pathsep + old_path if old_path else "")
                    try:
                        process = run_process(command, str(out) + ".log", args.timeout)
                    finally:
                        if old_path is None:
                            os.environ.pop("PYTHONPATH", None)
                        else:
                            os.environ["PYTHONPATH"] = old_path
                    assert_unchanged(baseline)
                    result = compare(baseline, load_artifact(out))
                    result.update({"variant": name, "repetition": repetition + 1, "process": process})
                    # Exit1 is expected with a preserved length failure; metadata
                    # and exact statuses determine parity. Other exits are not.
                    if process["timed_out"] or process["returncode"] not in (0, 1):
                        result["relative_runtime_parity"] = False
                        result["speed_comparison_eligible"] = False
                    summary["comparisons"].append(result)
                    write_summary(summary_path, summary)
                    print(json.dumps({"variant": name, "repetition": repetition + 1,
                                      "parity": result["relative_runtime_parity"],
                                      "statuses": result["accounting"]["status_counts"],
                                      "p50_ms": result["accounting"]["all_recorded_latency"]["p50_ms"]}), flush=True)
    return 0 if summary["comparisons"] and all(r["relative_runtime_parity"] for r in summary["comparisons"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
