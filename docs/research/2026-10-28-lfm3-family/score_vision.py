#!/usr/bin/env python3
"""Score run_vision.py output per question.

    python score_vision.py RUN.jsonl [...]

Per question (modal, loaded) and variant (easy, hard): accuracy at P = 0.5 with its 95% CI, ROC-AUC,
pairs where both screens of a pair are right (the layout is identical, so
only the state can tell them apart), the largest share of screens answered
at precision >= 0.95, and p50 latency with the load it ran at.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import max_coverage, percentile, roc_auc, wilson  # noqa: E402


def main() -> int:
    for path in sys.argv[1:]:
        rows = [json.loads(line) for line in open(path)]
        groups = sorted({(r["q"], r.get("variant", "easy")) for r in rows})
        for question, variant in groups:
            mine = [r for r in rows if r["q"] == question and r.get("variant", "easy") == variant]
            right = [(r["p_yes"] >= 0.5) == r["gold"] for r in mine]
            pairs: dict[str, list[bool]] = {}
            for r, ok in zip(mine, right):
                pairs.setdefault(r["id"].rsplit("_", 1)[0], []).append(ok)
            # Answer "yes" or "no" when P is far enough from 0.5; precision
            # counts both directions.
            conf = [max(r["p_yes"], 1 - r["p_yes"]) for r in mine]
            ms = [r["ms"] for r in mine]
            print(json.dumps({
                "run": Path(path).stem, "q": question, "variant": variant, "n": len(mine),
                "correct": sum(right), "accuracy_ci95": [round(x, 3) for x in wilson(sum(right), len(right))],
                "auc": round(roc_auc([r["p_yes"] for r in mine], [r["gold"] for r in mine]), 3),
                "pairs_both_right": sum(all(v) for v in pairs.values()), "pairs": len(pairs),
                "coverage_at_p95": round(max_coverage(conf, right, 0.95)["coverage"], 3),
                "ms_p50": round(statistics.median(ms)), "ms_p95": round(percentile(ms, 95)),
                "tokens": round(statistics.median(r["tokens"] for r in mine)),
                "median_load1": round(statistics.median(r["load1"] for r in mine), 1),
                "mlx_active_gb": round(max(r["mlx_active"] for r in mine) / 1e9, 2),
            }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
