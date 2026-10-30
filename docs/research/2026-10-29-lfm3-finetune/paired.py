"""Paired held-out tests of one arm against another on the 104 dev takes.

Usage: python3 paired.py runs/teacher.jsonl runs/<arm a>.jsonl runs/<arm b>.jsonl

Acceptance: exact McNemar on takes one arm got accepted and the other did
not. Closeness: sign test on per-take difflib similarity to the 4B's text
(ties dropped). Bench: McNemar on the 27 cases, when both files have them.
"""
import difflib
import json
import sys
from math import comb

SIM_BARS = (0.90, 0.95)


def two_sided(b, c):
    n = b + c
    if n == 0:
        return 1.0
    return min(1.0, 2 * sum(comb(n, i) for i in range(min(b, c) + 1)) / 2 ** n)


def rows(path, set_name):
    return {r["name"]: r for r in map(json.loads, open(path)) if r["set"] == set_name}


teacher = rows(sys.argv[1], "dev")
a_path, b_path = sys.argv[2], sys.argv[3]
a, b = rows(a_path, "dev"), rows(b_path, "dev")
names = sorted(set(a) & set(b) & set(teacher))


def sim(r, n):
    return difflib.SequenceMatcher(None, r["output"], teacher[n]["output"]).ratio()


a_only = sum(1 for n in names if a[n]["applied"] and not b[n]["applied"])
b_only = sum(1 for n in names if b[n]["applied"] and not a[n]["applied"])
a_closer = sum(1 for n in names if sim(a[n], n) > sim(b[n], n))
b_closer = sum(1 for n in names if sim(b[n], n) > sim(a[n], n))
print(f"dev n={len(names)}  A={a_path}  B={b_path}")
print(f"accepted only by A {a_only}, only by B {b_only}, p={two_sided(a_only, b_only):.2g}")
print(f"closer to 4B: A {a_closer}, B {b_closer}, p={two_sided(a_closer, b_closer):.2g}")
for label, arm in (("A", a), ("B", b)):
    sims = [sim(arm[n], n) for n in names if arm[n]["applied"]]
    bars = ", ".join(f">={bar}: {sum(s >= bar for s in sims)}" for bar in SIM_BARS)
    exact = sum(1 for n in names if arm[n]["applied"] and arm[n]["output"] == teacher[n]["output"])
    print(f"{label}: accepted {len(sims)}, identical {exact}, {bars}")

ab, bb = rows(a_path, "bench"), rows(b_path, "bench")
cases = sorted(set(ab) & set(bb))
if cases:
    a_wins = sum(1 for n in cases if not ab[n]["failures"] and bb[n]["failures"])
    b_wins = sum(1 for n in cases if not bb[n]["failures"] and ab[n]["failures"])
    print(f"bench n={len(cases)}: passes only A {a_wins}, only B {b_wins}, p={two_sided(a_wins, b_wins):.2g}")
