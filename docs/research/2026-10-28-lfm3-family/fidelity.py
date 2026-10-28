#!/usr/bin/env python3
"""Does a quantized export answer like its fp16 reference?

    python fidelity.py decisions REFERENCE.jsonl QUANTIZED.jsonl [...]
    python fidelity.py speech    REFERENCE.jsonl QUANTIZED.jsonl [...]

decisions  run_decisions.py rows: argmax agreement on `pred`, |Δ p_gold|
speech     run_speech.py d1 rows: agreement of P(speech) >= 0.5, |Δ p_speech|

Prints the agreement rate, the median and max drift, and the ids where
the answer flipped. PR #25 used the same check (argmax agreement) before
scoring LFM3's 4- and 8-bit exports.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

FIELDS = {"decisions": ("pred", "p_gold"), "speech": (None, "p_speech")}


def _rows(path: str) -> dict[str, dict]:
    return {r["id"]: r for r in map(json.loads, open(path)) if "id" in r}


def main() -> int:
    kind, reference_path, *quantized = sys.argv[1:]
    answer_field, prob_field = FIELDS[kind]
    reference = _rows(reference_path)

    def answer(row: dict):
        return row[answer_field] if answer_field else row[prob_field] >= 0.5

    for path in quantized:
        rows = _rows(path)
        ids = [i for i in reference if i in rows]
        flipped = [i for i in ids if answer(rows[i]) != answer(reference[i])]
        drift = [abs(rows[i][prob_field] - reference[i][prob_field]) for i in ids]
        print(json.dumps({
            "reference": Path(reference_path).stem, "run": Path(path).stem, "n": len(ids),
            "agreement": round(1 - len(flipped) / len(ids), 4),
            "median_drift": round(statistics.median(drift), 4), "max_drift": round(max(drift), 4),
            "flipped": flipped,
        }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
