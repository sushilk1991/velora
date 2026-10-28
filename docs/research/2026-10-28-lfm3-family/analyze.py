#!/usr/bin/env python3
"""Join decision runs and score them against the incumbent, paired.

    python analyze.py BASELINE.jsonl CANDIDATE.jsonl [...] > report.json
    python analyze.py --svg reliability.svg BASELINE.jsonl CANDIDATE.jsonl ...

The first file is the incumbent (Qwen3.5-4B-8bit letter logits). For every
set it reports, per arm: accuracy with a 95% Wilson CI, the exact McNemar
p against the incumbent on the same items, ROC-AUC / Brier on the set's
"safe" class, ECE of top-choice confidence, and the one-sided gate numbers
at the production bar:

    set        safe class   bar    a leak is
    press      navigate     0.90   an answer row waved past the reviewer
    delivers   no           0.95   a delivering command locked sends=false
    done       true         0.90   an unfinished command declared done
    (others)   top choice   —      —

"Skip the 4B" is the largest share of a set answered at precision ≥ 0.95
by thresholding top-choice confidence (stats.max_coverage).
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import (  # noqa: E402
    brier,
    ece,
    max_coverage,
    mcnemar_exact,
    percentile,
    roc_auc,
    wilson,
)

GATES = {"press": ("navigate", 0.90), "delivers": ("no", 0.95), "done": ("true", 0.90)}
BINARY_TRUE = {"is_nav", "header_ok", "sent_ok"}


def load(path: str) -> tuple[str, dict[str, dict], dict]:
    rows, memory = {}, {}
    for line in open(path):
        record = json.loads(line)
        if record.get("event") == "memory":
            memory = record
        elif record.get("event") == "item":
            rows[record["id"]] = record
    return Path(path).stem, rows, memory


def safe_class(row: dict) -> str | None:
    if row["set"] in GATES:
        return GATES[row["set"]][0]
    if row["cat"] in BINARY_TRUE:
        return "true"
    return None


def score_set(base: dict[str, dict], cand: dict[str, dict], ids: list[str]) -> dict:
    right = [cand[i]["pred"] == cand[i]["gold"] for i in ids]
    base_right = [base[i]["pred"] == base[i]["gold"] for i in ids]
    conf = [cand[i]["conf"] for i in ids]
    k = sum(right)
    out = {
        "n": len(ids), "correct": k, "ci95": [round(x, 3) for x in wilson(k, len(ids))],
        "mcnemar_vs_base": mcnemar_exact(base_right, right),
        "ece": round(ece(conf, right)["ece"], 4),
        "mean_p_gold": round(statistics.mean(cand[i]["p_gold"] for i in ids), 4),
        "skip_4b_at_p95": max_coverage(conf, right, 0.95),
        "p50_ms": round(statistics.median(cand[i]["ms"] for i in ids), 1),
        "p95_ms": round(percentile([cand[i]["ms"] for i in ids], 95), 1),
        "median_load1": round(statistics.median(cand[i]["load1"] for i in ids), 1),
        "misses": [i for i, r in zip(ids, right) if not r],
    }

    # One-sided gate numbers on the safe class, where the set has one.
    safe = safe_class(cand[ids[0]])
    if safe is not None:
        p_safe = [cand[i]["probs"][safe] for i in ids]
        is_safe = [cand[i]["gold"] == safe for i in ids]
        out["auc_safe"] = round(roc_auc(p_safe, is_safe) or 0.0, 4)
        out["brier_safe"] = round(brier(p_safe, is_safe), 4)
        set_name = cand[ids[0]]["set"]
        if set_name in GATES:
            bar = GATES[set_name][1]
            passed = [s for p, s in zip(p_safe, is_safe) if p >= bar]
            out["gate"] = {
                "bar": bar,
                "safe_passed": sum(passed), "safe_total": sum(is_safe),
                "leaks": len(passed) - sum(passed),
                "unsafe_total": len(ids) - sum(is_safe),
                # Lowest bar with zero leaks, and how many safe items it passes.
                "zero_leak": _zero_leak(p_safe, is_safe),
            }
    return out


def _zero_leak(p_safe: list[float], is_safe: list[bool]) -> dict:
    worst_unsafe = max((p for p, s in zip(p_safe, is_safe) if not s), default=0.0)
    passed = sum(1 for p, s in zip(p_safe, is_safe) if s and p > worst_unsafe)
    return {"bar_above": round(worst_unsafe, 4), "safe_passed": passed}


def reliability_svg(series: list[tuple[str, list[float], list[bool]]], path: str) -> None:
    """One reliability diagram: confidence bins (x) vs accuracy (y), one
    polyline per arm, dot area ∝ bin count, diagonal = perfect calibration."""
    size, pad = 360, 40
    colors = ["#1f6feb", "#d1242f", "#1a7f37", "#8250df", "#bf8700", "#57606a"]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{size + 200}" height="{size + 2 * pad}" '
             'font-family="Helvetica, Arial, sans-serif" font-size="11">',
             '<rect width="100%" height="100%" fill="#ffffff"/>',
             f'<line x1="{pad}" y1="{pad + size}" x2="{pad + size}" y2="{pad}" stroke="#bbb" stroke-dasharray="4 3"/>',
             f'<rect x="{pad}" y="{pad}" width="{size}" height="{size}" fill="none" stroke="#888"/>']
    for tick in range(0, 11, 2):
        x = pad + size * tick / 10
        y = pad + size - size * tick / 10
        parts.append(f'<text x="{x}" y="{pad + size + 14}" text-anchor="middle">{tick / 10:.1f}</text>')
        parts.append(f'<text x="{pad - 6}" y="{y + 4}" text-anchor="end">{tick / 10:.1f}</text>')
    parts.append(f'<text x="{pad + size / 2}" y="{pad + size + 30}" text-anchor="middle">confidence of the chosen option</text>')
    parts.append(f'<text x="12" y="{pad + size / 2}" transform="rotate(-90 12 {pad + size / 2})" '
                 'text-anchor="middle">share correct</text>')
    for index, (name, conf, right) in enumerate(series):
        color = colors[index % len(colors)]
        bins = ece(conf, right)["bins"]
        points = [(pad + size * c, pad + size - size * a, n) for _, _, n, c, a in bins]
        parts.append('<polyline fill="none" stroke="{}" stroke-width="1.5" points="{}"/>'.format(
            color, " ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)))
        for x, y, n in points:
            parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{1.5 + n ** 0.5:.1f}" fill="{color}" fill-opacity="0.5"/>')
        label = f'{name} (ECE {ece(conf, right)["ece"]:.3f})'
        parts.append(f'<rect x="{pad + size + 14}" y="{pad + 8 + index * 18}" width="10" height="10" fill="{color}"/>')
        parts.append(f'<text x="{pad + size + 30}" y="{pad + 17 + index * 18}">{label}</text>')
    parts.append("</svg>")
    Path(path).write_text("\n".join(parts))


def main() -> int:
    args = sys.argv[1:]
    svg = None
    if args and args[0] == "--svg":
        svg, args = args[1], args[2:]
    runs = [load(path) for path in args]
    base_name, base, _ = runs[0]
    sets = sorted({row["set"] for row in base.values()})
    report = {"baseline": base_name, "arms": {}}
    series = []
    for name, rows, memory in runs:
        shared = [i for i in base if i in rows]
        arm = {"memory": memory, "sets": {}}
        for set_name in sets:
            ids = [i for i in shared if base[i]["set"] == set_name]
            if ids:
                arm["sets"][set_name] = score_set(base, rows, ids)
        # Everything pooled: the share of all decisions answerable without
        # the 4B at precision ≥ 0.95, and the overall paired test.
        conf = [rows[i]["conf"] for i in shared]
        right = [rows[i]["pred"] == rows[i]["gold"] for i in shared]
        arm["all"] = {
            "n": len(shared), "correct": sum(right),
            "ci95": [round(x, 3) for x in wilson(sum(right), len(shared))],
            "mcnemar_vs_base": mcnemar_exact(
                [base[i]["pred"] == base[i]["gold"] for i in shared], right),
            "ece": round(ece(conf, right)["ece"], 4),
            "skip_4b_at_p95": max_coverage(conf, right, 0.95),
        }
        report["arms"][name] = arm
        series.append((name, conf, right))
    if svg:
        reliability_svg(series, svg)
    json.dump(report, sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
