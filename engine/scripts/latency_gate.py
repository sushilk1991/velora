#!/usr/bin/env python3
"""Stop-to-final latency gate: synthetic dictations, p50/p95, checked-in baseline.

    python engine/scripts/latency_gate.py                 # gate against fixtures
    python engine/scripts/latency_gate.py --write-baseline
    python engine/scripts/latency_gate.py --inject-delay-ms 40   # negative control
    python engine/scripts/latency_gate.py --live          # real speech model

What is measured, per take, on the paths a real dictation uses:

1. `stt_ms`    — `stt.transcribe_clip`, which drives start/feed/finalize exactly
                 as a live session does (batch and streaming backends alike).
2. `cleanup_ms`— the deterministic post-STT pipeline: `formatting.run_gate` then
                 `formatting.postprocess` for the resolved mode. This runs on
                 every dictation, model or not, so a quadratic regex or a new
                 per-word pass shows up here.
3. `total_ms`  — the two stages together. The gate compares this.

Fake mode (default) sets `VELORA_FAKE_STT=1`, points `VELORA_HOME` at a throwing
away directory and feeds a fixed transcript, so it is deterministic and needs no
model, no network and no user settings. Live mode (`--live`) runs the configured
speech model against the same synthetic audio and does NOT measure LLM cleanup —
that path is `scripts/benchmark_cleanup_latency.py`, which owns it. Baselines are
kept per mode and are never compared across modes.

The gate fails when p95 exceeds `max(baseline * 1.15, baseline + 2 ms)`. The
absolute floor keeps sub-millisecond jitter in fake mode from flaking; the
percentage keeps a real regression meaningful on live numbers.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ENGINE / "tests" / "fixtures" / "latency_baseline.json"
BASELINE_FORMAT = 1

MAX_REGRESSION_PCT = 15.0
ABSOLUTE_FLOOR_MS = 2.0
DEFAULT_TAKES = 8
CLIP_SECONDS = 2.0
SAMPLE_RATE = 16_000

# Deterministic stand-in transcript for fake mode: long enough that the
# deterministic formatting stage does real work (list detection, replacements,
# punctuation) on every take, short enough to stay a dictation.
FAKE_TRANSCRIPT = (
    "okay so before the demo on friday we need three things first is the readme "
    "i mean the changelog second is a smoke test on the intel laptop and third "
    "is telling priya about the room change the meeting is in room four no room "
    "six and we should send the invite to the whole team by wednesday i think "
    "the rest can wait until we are back"
)


# ---------------------------------------------------------------- statistics


def percentile(values: list[float], fraction: float) -> float:
    """Linear-interpolated percentile (numpy's default method), no numpy needed.

    Deterministic and easy to reason about in a test: p50 of an even-sized
    sample is the mean of the two middle values, p95 interpolates toward the
    maximum.
    """
    if not values:
        raise ValueError("percentile needs at least one value")
    if not 0.0 <= fraction <= 1.0:
        raise ValueError("fraction must be between 0 and 1")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[int(position)]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def summarise(rows: list[dict]) -> dict:
    totals = [row["total_ms"] for row in rows]
    return {
        "takes": len(rows),
        "p50_ms": round(percentile(totals, 0.5), 3),
        "p95_ms": round(percentile(totals, 0.95), 3),
        "max_ms": round(max(totals), 3),
        "stt_p95_ms": round(percentile([row["stt_ms"] for row in rows], 0.95), 3),
        "cleanup_p95_ms": round(
            percentile([row["cleanup_ms"] for row in rows], 0.95), 3),
    }


def limit_for(
    baseline_p95_ms: float,
    max_regression_pct: float = MAX_REGRESSION_PCT,
    floor_ms: float = ABSOLUTE_FLOOR_MS,
) -> float:
    """The worst p95 this gate accepts for that baseline."""
    return max(
        baseline_p95_ms * (1.0 + max_regression_pct / 100.0),
        baseline_p95_ms + floor_ms,
    )


def evaluate(
    summary: dict,
    baseline: dict,
    max_regression_pct: float = MAX_REGRESSION_PCT,
    floor_ms: float = ABSOLUTE_FLOOR_MS,
) -> dict:
    """Compare one run's summary against one baseline section."""
    base = float(baseline["p95_ms"])
    observed = float(summary["p95_ms"])
    limit = limit_for(base, max_regression_pct, floor_ms)
    delta_pct = ((observed - base) / base * 100.0) if base > 0 else 0.0
    return {
        "passed": observed <= limit,
        "observed_p95_ms": observed,
        "baseline_p95_ms": base,
        "limit_ms": round(limit, 3),
        "delta_pct": round(delta_pct, 1),
    }


def regression_message(mode: str, verdict: dict) -> str:
    return (
        f"latency regression ({mode}): p95 {verdict['observed_p95_ms']:.3f} ms "
        f"exceeds the {verdict['limit_ms']:.3f} ms limit "
        f"(baseline {verdict['baseline_p95_ms']:.3f} ms, "
        f"{verdict['delta_pct']:+.1f}%)"
    )


# ---------------------------------------------------------------- the pipeline


def synthetic_pcm(index: int, seconds: float = CLIP_SECONDS):
    """A deterministic 16 kHz clip: a swept tone under a fixed noise floor.

    Not speech, and it does not need to be: this gate measures how long a clip
    of this length takes to decode and format. The same clip at the same index
    is byte-identical on every run and every machine.
    """
    import numpy as np

    frames = int(seconds * SAMPLE_RATE)
    t = np.arange(frames, dtype=np.float32) / SAMPLE_RATE
    sweep = 0.08 * np.sin(2 * math.pi * (180.0 + 40.0 * index) * t)
    rng = np.random.default_rng(1000 + index)
    floor = 0.004 * rng.standard_normal(frames)
    # A pause in the middle, so a VAD-driven path is exercised the same way
    # every time rather than decoding one unbroken tone.
    gate = np.ones(frames, dtype=np.float32)
    gate[frames // 3: frames // 2] = 0.0
    return ((sweep + floor) * gate).astype(np.float32)


def prepare_environment(live: bool) -> str | None:
    """Isolate the run. Returns a scratch home to remove afterwards."""
    if live:
        # The configured models and language live in the real home; a live run
        # is explicitly asked for and reads them rather than inventing them.
        return None
    os.environ["VELORA_FAKE_STT"] = "1"
    os.environ["VELORA_FAKE_STT_TEXT"] = FAKE_TRANSCRIPT
    home = tempfile.mkdtemp(prefix="velora-latency-")
    os.environ["VELORA_HOME"] = home
    return home


def run_takes(takes: int, inject_delay_ms: float = 0.0) -> list[dict]:
    """Time `takes` synthetic dictations through the real stop-to-final stages."""
    from velora_engine import formatting, stt
    from velora_engine.config import Config

    config = Config()
    backend = stt.create_backend(config.stt_model, config.language)
    delay_s = max(0.0, inject_delay_ms) / 1000.0
    rows: list[dict] = []
    for index in range(takes):
        pcm = synthetic_pcm(index)
        started = time.perf_counter()
        if delay_s:
            # The negative control: a stage that got slower, injected where a
            # real regression would land (inside the measured pipeline).
            time.sleep(delay_s)
        raw = stt.transcribe_clip(backend, pcm)
        decoded = time.perf_counter()
        gate = formatting.run_gate(raw, config)
        final = formatting.postprocess(raw, gate)
        finished = time.perf_counter()
        rows.append({
            "index": index,
            "stt_ms": round((decoded - started) * 1000.0, 3),
            "cleanup_ms": round((finished - decoded) * 1000.0, 3),
            "total_ms": round((finished - started) * 1000.0, 3),
            "chars": len(final),
        })
    return rows


# ---------------------------------------------------------------- baseline file


def load_baseline(path: Path) -> dict:
    if not path.exists():
        return {"format": BASELINE_FORMAT, "baselines": {}}
    data = json.loads(path.read_text())
    if data.get("format") != BASELINE_FORMAT:
        raise ValueError(
            f"{path} has format {data.get('format')!r}, expected {BASELINE_FORMAT}")
    data.setdefault("baselines", {})
    return data


def store_baseline(path: Path, mode: str, summary: dict) -> None:
    """Record one mode's section atomically: a half-written baseline is worse
    than none."""
    data = load_baseline(path)
    data["baselines"][mode] = summary
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = path.with_suffix(path.suffix + ".tmp")
    staging.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    staging.replace(path)


# ---------------------------------------------------------------- command line


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stop-to-final latency gate (synthetic dictations, p50/p95).")
    parser.add_argument("--takes", type=int, default=DEFAULT_TAKES,
                        help=f"synthetic dictations to time (default {DEFAULT_TAKES})")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE,
                        help="baseline JSON (default engine/tests/fixtures/latency_baseline.json)")
    parser.add_argument("--max-regression-pct", type=float, default=MAX_REGRESSION_PCT,
                        help=f"allowed p95 growth (default {MAX_REGRESSION_PCT:.0f}%%)")
    parser.add_argument("--floor-ms", type=float, default=ABSOLUTE_FLOOR_MS,
                        help=f"absolute p95 allowance (default {ABSOLUTE_FLOOR_MS:.0f} ms)")
    parser.add_argument("--inject-delay-ms", type=float, default=0.0,
                        help="negative control: sleep this long inside each take")
    parser.add_argument("--write-baseline", action="store_true",
                        help="record this run as the baseline for its mode")
    parser.add_argument("--live", action="store_true",
                        help="use the configured speech model instead of the fake backend")
    parser.add_argument("--json", action="store_true",
                        help="print the summary and verdict as JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.takes < 1:
        print("latency gate: --takes must be at least 1", file=sys.stderr)
        return 2
    mode = "live" if args.live else "fake"

    # Fail fast on a missing or unreadable baseline: a live run costs a model
    # load, and discovering the baseline is absent after it would be rude.
    section = None
    if not args.write_baseline:
        try:
            baseline = load_baseline(args.baseline)
        except (OSError, ValueError) as error:
            print(f"latency gate: {error}", file=sys.stderr)
            return 2
        section = baseline["baselines"].get(mode)
        if section is None:
            flag = "--live --write-baseline" if args.live else "--write-baseline"
            print(
                f"latency gate: no {mode} baseline in {args.baseline}; "
                f"run {flag} first",
                file=sys.stderr)
            return 2

    scratch_home = prepare_environment(args.live)
    try:
        try:
            rows = run_takes(args.takes, args.inject_delay_ms)
        except Exception as error:  # noqa: BLE001 — report, never a fake pass
            print(f"latency gate: could not run in {mode} mode: {error}",
                  file=sys.stderr)
            return 2
        summary = summarise(rows)

        if args.write_baseline:
            store_baseline(args.baseline, mode, summary)
            payload = {"mode": mode, "wrote_baseline": str(args.baseline),
                       "summary": summary}
            print(json.dumps(payload, indent=2) if args.json else
                  f"wrote {args.baseline} ({mode}): p50 {summary['p50_ms']:.3f} ms, "
                  f"p95 {summary['p95_ms']:.3f} ms over {summary['takes']} takes")
            return 0

        assert section is not None  # checked before the run
        verdict = evaluate(summary, section, args.max_regression_pct, args.floor_ms)
        if args.json:
            print(json.dumps({"mode": mode, "summary": summary,
                              "verdict": verdict}, indent=2))
        else:
            print(f"{mode}: {summary['takes']} takes, "
                  f"p50 {summary['p50_ms']:.3f} ms, p95 {summary['p95_ms']:.3f} ms "
                  f"(baseline {verdict['baseline_p95_ms']:.3f} ms, "
                  f"limit {verdict['limit_ms']:.3f} ms)")
        if not verdict["passed"]:
            print(regression_message(mode, verdict), file=sys.stderr)
            return 1
        return 0
    finally:
        if scratch_home:
            shutil.rmtree(scratch_home, ignore_errors=True)


if __name__ == "__main__":
    sys.path.insert(0, str(ENGINE / "src"))
    raise SystemExit(main())
