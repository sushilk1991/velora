"""Summarize latency.sh: per arm, both bracketing passes pooled.

Usage: python3 latency_summary.py runs/latency
"""
import json
import re
import sys
from pathlib import Path

ARMS = {"A": "Qwen 4B-8bit (shipped)", "B": "Qwen 2B-4bit (small tier)", "C": "LFM3-8bit + LoRA (fused)"}


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


root = Path(sys.argv[1])
pooled = {}
for path in sorted(root.glob("*.jsonl")):
    arm = re.match(r"\d+-([ABC])", path.stem).group(1)
    pooled.setdefault(arm, []).extend(json.loads(line) for line in open(path))

print(f"{'arm':28} {'n':>3} {'p50 wall':>9} {'p95 wall':>9} {'p50 ttft':>9} {'decode tok/s p50':>17} {'bench fails/pass':>17}")
for arm in "ABC":
    rows = pooled.get(arm, [])
    if not rows:
        continue
    rates = [r["answer_tokens"] / ((r["wall_ms"] - r["ttft_ms"]) / 1000)
             for r in rows if r["wall_ms"] > r["ttft_ms"] and r["answer_tokens"]]
    fails = sum(1 for r in rows if r["failures"]) / 2
    print(f"{ARMS[arm]:28} {len(rows):>3} {pct([r['wall_ms'] for r in rows], .5):>9.0f} "
          f"{pct([r['wall_ms'] for r in rows], .95):>9.0f} {pct([r['ttft_ms'] for r in rows], .5):>9.0f} "
          f"{pct(rates, .5):>17.0f} {fails:>17.1f}")
