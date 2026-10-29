"""Score runs: bench failures, held-out agreement with the 4B, paired tests.

Usage: python3 score.py runs/teacher.jsonl runs/<arm>.jsonl [...]

Bench: a case passes when validate() returns nothing. Dev: the newest 104
owner takes; "same" means the student's final text equals the 4B's, and
similarity is difflib's ratio on the final texts. McNemar is exact
(binomial on discordant pairs), against the first arm listed after the
teacher.
"""
import difflib
import json
import sys
from math import comb


def mcnemar(b, c):
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    return min(1.0, 2 * sum(comb(n, i) for i in range(k + 1)) / 2 ** n)


def load(path):
    return [json.loads(line) for line in open(path)]


teacher = {r["name"]: r for r in load(sys.argv[1]) if r["set"] == "dev"}
arms = [(path.split("/")[-1].removesuffix(".jsonl"), load(path)) for path in sys.argv[2:]]
base_name, base_rows = arms[0]
base_pass = {r["name"]: not r["failures"] for r in base_rows if r["set"] == "bench"}

print(f"{'arm':28} {'bench fail':>10} {'McNemar':>14} {'dev n':>5} {'rejected':>8} "
      f"{'same as 4B':>10} {'sim':>5} {'p50 wall':>8} {'p50 ttft':>8}")
for name, rows in arms:
    bench = [r for r in rows if r["set"] == "bench"]
    dev = [r for r in rows if r["set"] == "dev" and r["name"] in teacher]
    fails = sum(1 for r in bench if r["failures"])
    b = sum(1 for r in bench if base_pass.get(r["name"]) and r["failures"])
    c = sum(1 for r in bench if not base_pass.get(r["name"], True) and not r["failures"])
    test = f"{b}/{c} p={mcnemar(b, c):.3f}" if name != base_name else "—"
    rejected = sum(1 for r in dev if not r["applied"])
    same = sum(1 for r in dev if r["output"] == teacher[r["name"]]["output"])
    sim = (sum(difflib.SequenceMatcher(None, r["output"], teacher[r["name"]]["output"]).ratio()
               for r in dev) / len(dev)) if dev else float("nan")
    walls = sorted(r["wall_ms"] for r in bench) or [0]
    ttfts = sorted(r.get("ttft_ms", 0) for r in bench) or [0]
    print(f"{name:28} {fails:>10} {test:>14} {len(dev):>5} {rejected:>8} {same:>10} "
          f"{sim:>5.3f} {walls[len(walls) // 2]:>8.0f} {ttfts[len(ttfts) // 2]:>8.0f}")
    failing = sorted(r["name"] for r in bench if r["failures"])
    print(f"{'':28} failing: {', '.join(failing) if failing else 'none'}")
