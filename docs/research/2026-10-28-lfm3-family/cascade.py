#!/usr/bin/env python3
"""Skip the 4B: a small model answers when it is sure, the 4B takes the rest.

    python cascade.py INCUMBENT.jsonl SMALL.jsonl [...]

    item ─► small model ─┬─ conf >= t ─► small model's answer   (4B skipped)
                         └─ conf <  t ─► 4B's answer

For each small model, the threshold t is the lowest at which the items it
keeps hold precision >= 0.95 (stats.max_coverage). Reports the skipped
share, the cascade's accuracy against the 4B alone with an exact McNemar,
and the skipped items the small model got wrong. Latency is in latency.py:
the cascade always pays the small model's call, and the 4B's on the rest.

The in-sample threshold is fit on the items it is scored on, so it flatters
the cascade. The held-out line fits t on four sets and applies it to the
fifth, for each set in turn: the rate a new kind of decision would see.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import max_coverage, mcnemar_exact, wilson  # noqa: E402

MIN_PRECISION = 0.95


def _rows(path: str) -> dict[str, dict]:
    return {r["id"]: r for r in map(json.loads, open(path)) if "id" in r}


def _held_out(incumbent: dict, small: dict, ids: list[str]) -> dict:
    """Leave one set out: t from the other sets, scored on this one."""
    skipped, wrong, alone, both, by_set = 0, [], [], [], {}
    for held in sorted({small[i]["set"] for i in ids}):
        fit = [i for i in ids if small[i]["set"] != held]
        threshold = max_coverage([small[i]["conf"] for i in fit],
                                 [small[i]["pred"] == small[i]["gold"] for i in fit],
                                 MIN_PRECISION)["threshold"]
        mine = [i for i in ids if small[i]["set"] == held]
        by_set[held] = {"threshold": threshold, "n": len(mine), "skipped": 0, "wrong": 0}
        for i in mine:
            take = threshold is not None and small[i]["conf"] >= threshold
            by_set[held]["skipped"] += take
            by_set[held]["wrong"] += take and small[i]["pred"] != small[i]["gold"]
            row = small[i] if take else incumbent[i]
            skipped += take
            if take and row["pred"] != row["gold"]:
                wrong.append(i)
            alone.append(incumbent[i]["pred"] == incumbent[i]["gold"])
            both.append(row["pred"] == row["gold"])
    return {"skipped": skipped, "skipped_share": round(skipped / len(ids), 3),
            "skipped_precision": round(1 - len(wrong) / skipped, 3) if skipped else None,
            "skipped_precision_ci95": [round(x, 3) for x in wilson(skipped - len(wrong), skipped)] if skipped else None,
            "cascade_correct": sum(both), "mcnemar_vs_incumbent": mcnemar_exact(alone, both),
            "skipped_wrong": wrong, "by_set": by_set}


def main() -> int:
    incumbent = _rows(sys.argv[1])
    for path in sys.argv[2:]:
        small = _rows(path)
        ids = [i for i in incumbent if i in small]
        right = [small[i]["pred"] == small[i]["gold"] for i in ids]
        best = max_coverage([small[i]["conf"] for i in ids], right, MIN_PRECISION)
        threshold = best["threshold"]
        skipped = [i for i in ids if threshold is not None and small[i]["conf"] >= threshold]

        def cascade(i: str) -> bool:
            row = small[i] if i in skipped else incumbent[i]
            return row["pred"] == row["gold"]

        alone = [incumbent[i]["pred"] == incumbent[i]["gold"] for i in ids]
        both = [cascade(i) for i in ids]
        print(json.dumps({
            "small": Path(path).stem, "n": len(ids), "threshold": threshold,
            "skipped": len(skipped), "skipped_share": round(len(skipped) / len(ids), 3),
            "skipped_precision_ci95": [round(x, 3) for x in wilson(
                sum(small[i]["pred"] == small[i]["gold"] for i in skipped), len(skipped))] if skipped else None,
            "incumbent_correct": sum(alone), "cascade_correct": sum(both),
            "mcnemar_vs_incumbent": mcnemar_exact(alone, both),
            "skipped_by_set": {s: sum(1 for i in skipped if small[i]["set"] == s)
                               for s in sorted({small[i]["set"] for i in ids})},
            "skipped_wrong": [i for i in skipped if small[i]["pred"] != small[i]["gold"]],
            "held_out": _held_out(incumbent, small, ids),
        }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
