#!/usr/bin/env python3
"""Measure cleanup allocator policies in an isolated production worker.

Run from ``engine/`` and redirect stdout to retain the JSONL case evidence::

    uv run python scripts/benchmark_cleanup_resources.py --stress --uncapped > baseline.jsonl
    uv run python scripts/benchmark_cleanup_resources.py --stress \
      --cache-limit-mb 256 --compare-baseline baseline.jsonl > candidate.jsonl

The public quality fixtures and their per-case medians come from
``benchmark_cleanup_quality``. The optional allocator cap applies only inside
this benchmark's child process. Stress prefills 1,000 and 3,000 public synthetic
words, generating at most one token, before measuring the ordinary fixtures.
Neither probe changes the installed app or its model/settings selection.
Omitting allocator flags measures production policy; ``--uncapped`` restores
the fresh worker's MLX default, while an explicit zero disables buffer caching.

A comparison requires identical outputs and no new fixture failures; existing
baseline failures remain visible. Reported latency is cleanup wall time, not
microphone-to-insertion latency. Footprint includes Metal allocations that RSS
can omit. Run GPU benchmarks sequentially without other active inference.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, TextIO

try:
    from . import benchmark_cleanup_quality as quality
except ImportError:  # Direct script execution from engine/.
    import benchmark_cleanup_quality as quality

from velora_engine.cleanup_process import CleanupProcess
from velora_engine.config import Config
from velora_engine.formatting import STATIC_SYSTEM_PROMPT

STRESS_WORDS = (1000, 3000)
LOCK_PATH = Path("/tmp/velora-bench.lock")


@contextlib.contextmanager
def benchmark_lock():
    """Serialize native and resource benchmarks without locking their workers."""
    with LOCK_PATH.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def incumbent_snapshot_path() -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE

    return (
        Path(HF_HUB_CACHE) / ("models--" + quality.MODEL_ID.replace("/", "--"))
        / "snapshots" / quality.MODEL_REVISION
    ).resolve()


def worker_main(
    cache_limit_mb: int | None, arguments: list[str], *, uncapped: bool = False,
) -> None:
    """Enter the normal worker protocol, changing only its allocator budget."""
    from velora_engine import cleanup, cleanup_worker

    if cache_limit_mb is not None or uncapped:
        original_load = cleanup.CleanupEngine.load

        def load(self, *args, **kwargs):
            # Production applies its policy inside load(), so change that
            # child's policy entry rather than setting a cap it would reset.
            if uncapped:
                cleanup.ALLOCATOR_CACHE_LIMITS.pop(self.model_id, None)
            else:
                cleanup.ALLOCATOR_CACHE_LIMITS[self.model_id] = cache_limit_mb * 1024 * 1024
            return original_load(self, *args, **kwargs)

        cleanup.CleanupEngine.load = load
    sys.argv = [sys.argv[0], *arguments]
    cleanup_worker.main()


def stress_text(words: int) -> str:
    sentence = "please preserve every technical detail in this public update".split()
    return " ".join((sentence * ((words + len(sentence) - 1) // len(sentence)))[:words])


class JsonlRecorder(io.TextIOBase):
    """Forward the fixture runner's output while retaining its JSON records."""

    def __init__(self, destination: TextIO) -> None:
        self.destination = destination
        self.pending = ""
        self.records: list[dict[str, Any]] = []

    def write(self, value: str) -> int:
        self.destination.write(value)
        self.pending += value
        while "\n" in self.pending:
            line, self.pending = self.pending.split("\n", 1)
            if line.strip():
                record = json.loads(line)
                if isinstance(record, dict):
                    self.records.append(record)
        return len(value)

    def flush(self) -> None:
        self.destination.flush()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{number}: expected a JSON object")
        records.append(value)
    return records


def compare_records(
    baseline: list[dict[str, Any]], candidate: list[dict[str, Any]],
) -> dict[str, Any]:
    """Require the same workload, stable exact outputs and no new failures."""
    def cases(records):
        result = {}
        for record in records:
            if record.get("event") == "case":
                name = record["case"]
                if name in result:
                    raise ValueError(f"duplicate case evidence: {name}")
                result[name] = record
        return result

    old, new = cases(baseline), cases(candidate)
    missing, extra = sorted(old.keys() - new.keys()), sorted(new.keys() - old.keys())
    new_failures = {
        name: sorted(set(new[name].get("failures", [])) - set(old[name].get("failures", [])))
        for name in old.keys() & new.keys()
    }
    new_failures = {name: failures for name, failures in new_failures.items() if failures}
    drift = sorted(
        name for name in old.keys() & new.keys()
        if new[name].get("output") != old[name].get("output")
        or new[name].get("applied") != old[name].get("applied")
        or old[name].get("unique_outputs") != 1
        or new[name].get("unique_outputs") != 1
    )
    failures = []
    if not old or not new:
        failures.append("missing_case_evidence")
    if missing or extra:
        failures.append("case_coverage_mismatch")
    if new_failures:
        failures.append("new_quality_failures")
    if drift:
        failures.append("output_drift_or_unstable_output")
    # A cache experiment must not silently compare different model weights.
    old_summary = next((r for r in baseline if r.get("event") == "summary"), None)
    new_summary = next((r for r in candidate if r.get("event") == "summary"), None)
    if old_summary is None or new_summary is None:
        failures.append("missing_model_evidence")
    elif any(key not in old_summary or key not in new_summary for key in (
        "model", "resolved_revision", "weight_sha256",
    )):
        failures.append("missing_model_evidence")
    elif any(old_summary.get(key) != new_summary.get(key) for key in (
        "model", "resolved_revision", "weight_sha256",
    )):
        failures.append("model_evidence_mismatch")
    return {
        "event": "resource_comparison",
        "accepted": not failures,
        "no_new_quality_failures": not new_failures and not missing and not extra and bool(old),
        "no_output_drift": not drift and not missing and not extra and bool(old),
        "baseline_failed_cases": sorted(name for name, r in old.items() if r.get("failures")),
        "candidate_failed_cases": sorted(name for name, r in new.items() if r.get("failures")),
        "missing_cases": missing,
        "extra_cases": extra,
        "new_quality_failures": new_failures,
        "output_drift_cases": drift,
        "failures": failures,
    }


async def run(
    *, model: str, logical_model: str | None, cache_limit_mb: int | None,
    stress: bool, repeats: int, selected: set[str] | None,
    uncapped: bool = False,
    baseline: list[dict[str, Any]] | None = None,
) -> int:
    if uncapped and cache_limit_mb is not None:
        raise ValueError("--uncapped and --cache-limit-mb are mutually exclusive")
    local = Path(model).expanduser()
    if logical_model is not None and not local.is_dir():
        raise ValueError("--logical-model requires --model to be a local snapshot directory")
    if local.is_dir() and logical_model is None and local.resolve() != incumbent_snapshot_path():
        raise ValueError("local snapshots require --logical-model to identify model behavior")
    identity = logical_model or (quality.MODEL_ID if local.is_dir() else model)
    resolved = str(local.resolve()) if local.is_dir() else quality.resolve_benchmark_model(identity)
    active: set[CleanupProcess] = set()
    command = [sys.executable, str(Path(__file__).resolve()), "--worker"]
    if cache_limit_mb is not None:
        command.extend(["--cache-limit-mb", str(cache_limit_mb)])
    elif uncapped:
        command.append("--uncapped")

    class ResourceProcess(CleanupProcess):
        def __init__(self, source):
            super().__init__(identity, local_model_path=source, worker_command=command)
            active.add(self)

        async def load_async(self, *args, **kwargs):
            await super().load_async(*args, **kwargs)
            if stress:
                for words in STRESS_WORDS:
                    result = await self.cleanup(
                        stress_text(words), STATIC_SYSTEM_PROMPT,
                        timeout_ms=20000, max_tokens=1, copy_draft=False,
                    )
                    if result.reason != "length" or getattr(self, "unhealthy", False):
                        raise RuntimeError(f"stress prefill failed: {result.reason}")

        async def cleanup(self, *args, **kwargs):
            kwargs.setdefault("copy_draft", True)
            return await super().cleanup(*args, **kwargs)

        async def aclose(self):
            try:
                await super().aclose()
            finally:
                active.discard(self)

    recorder = JsonlRecorder(sys.stdout)
    old_home = os.environ.get("VELORA_HOME")
    original_process = quality.CleanupProcess
    original_resolver = quality.resolve_benchmark_model
    try:
        with tempfile.TemporaryDirectory(prefix="velora-resource-bench-") as home:
            os.environ["VELORA_HOME"] = home
            # Reuse the fixtures without changing the existing benchmark's API.
            quality.CleanupProcess = ResourceProcess
            quality.resolve_benchmark_model = lambda _model: resolved
            with contextlib.redirect_stdout(recorder):
                summary = await quality._run_model(identity, Config(), selected, repeats)
    finally:
        # The existing runner's finally begins after load and initial metrics;
        # these can fail too, including a stress prefill or cancelled setup.
        try:
            for engine in list(active):
                await engine.aclose()
        finally:
            quality.CleanupProcess = original_process
            quality.resolve_benchmark_model = original_resolver
            if old_home is None:
                os.environ.pop("VELORA_HOME", None)
            else:
                os.environ["VELORA_HOME"] = old_home
    print(json.dumps({
        **summary,
        "event": "resource_summary",
        "cache_limit_mb": cache_limit_mb,
        "allocator_policy": "mlx_default" if uncapped else (
            "override" if cache_limit_mb is not None else "production"
        ),
        "stress_words": list(STRESS_WORDS) if stress else [],
        "copy_draft": True,
        "all_quality_checks_passed": not summary["failed_cases"],
        "footprint_bytes": summary["footprint_after_inference"].get("current_bytes"),
        "cache_bytes": summary["mlx_inference"].get("cache_bytes"),
    }, ensure_ascii=False))
    if baseline is not None:
        comparison = compare_records(baseline, recorder.records)
        print(json.dumps(comparison, ensure_ascii=False))
        return 0 if comparison["accepted"] else 1
    return 0 if not summary["failed_cases"] else 1


def main() -> int:
    if "--worker" in sys.argv[1:]:
        # Parse only benchmark flags: --model and --fd belong to the worker.
        worker_parser = argparse.ArgumentParser(add_help=False)
        worker_parser.add_argument("--worker", action="store_true")
        worker_limits = worker_parser.add_mutually_exclusive_group()
        worker_limits.add_argument("--cache-limit-mb", type=int)
        worker_limits.add_argument("--uncapped", action="store_true")
        worker_args, remaining = worker_parser.parse_known_args()
        if worker_args.cache_limit_mb is not None and worker_args.cache_limit_mb < 0:
            worker_parser.error("--cache-limit-mb must be nonnegative")
        worker_main(worker_args.cache_limit_mb, remaining, uncapped=worker_args.uncapped)
        return 0
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=quality.MODEL_ID,
                        help="pinned model ID or exact local snapshot directory")
    parser.add_argument("--logical-model", help="required behavior ID for local weights outside the pinned incumbent snapshot")
    limits = parser.add_mutually_exclusive_group()
    limits.add_argument("--cache-limit-mb", type=int,
                        help="child MLX allocator cache cap in MiB; omit for production default")
    limits.add_argument("--uncapped", action="store_true",
                        help="remove the child's model policy override and use fresh MLX default")
    parser.add_argument("--stress", action="store_true")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--case", action="append", choices=[case.name for case in quality.CASES])
    parser.add_argument("--compare-baseline", type=Path)
    args = parser.parse_args()
    if args.cache_limit_mb is not None and args.cache_limit_mb < 0:
        parser.error("--cache-limit-mb must be nonnegative")
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    baseline = read_jsonl(args.compare_baseline) if args.compare_baseline else None
    with benchmark_lock():
        return asyncio.run(run(
            model=args.model, logical_model=args.logical_model,
            cache_limit_mb=args.cache_limit_mb, stress=args.stress,
            uncapped=args.uncapped,
            repeats=args.repeats, selected=set(args.case) if args.case else None,
            baseline=baseline,
        ))


if __name__ == "__main__":
    raise SystemExit(main())
