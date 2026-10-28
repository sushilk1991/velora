#!/usr/bin/env python3
"""Score ASR runs on the owner's term set, paired against the first run.

    python score_asr.py TERMS_SET.jsonl BASELINE.jsonl CANDIDATE.jsonl [...]

Per run: term recall over every reference mention with its 95% Wilson CI,
exact McNemar against the baseline on the same mentions, empty outputs,
RTF p50/p95 with the load it ran at, and a whole-word agreement rate with
the baseline (how often the two wrote the same text; not accuracy). No
transcript text is printed.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[2] / "engine" / "scripts"))

from asr_set import OWNER_TERMS_ENV, TERMS, hits, terms_in  # noqa: E402
from stats import mcnemar_exact, percentile, wilson  # noqa: E402


def mention_hits(reference: list[str], text: str) -> list[bool]:
    said = set(terms_in(text, accept_variants=False))
    if "Claude Code" in reference and "Claude Code" not in said:
        said.discard("Claude")
    return [term in said for term in reference]


def main() -> int:
    terms = {json.loads(line)["id"]: json.loads(line) for line in open(sys.argv[1])}

    # A set built with the owner's terms scores as all misses without them.
    unknown = {t for take in terms.values() for t in take["terms"]} - set(TERMS)
    if unknown:
        raise SystemExit(f"{len(unknown)} reference terms are not loaded; set {OWNER_TERMS_ENV}")

    runs = []
    for path in sys.argv[2:]:
        rows = {}
        for line in open(path):
            record = json.loads(line)
            if "id" in record:
                rows[record["id"]] = record
        runs.append((Path(path).stem, rows))

    from benchmark_stt_backends import _edit_distance, _words

    base_name, base = runs[0]
    ids = [i for i in terms if all(i in rows for _, rows in runs)]
    base_hits = [h for i in ids for h in mention_hits(terms[i]["terms"], base[i]["text"])]
    for name, rows in runs:
        flat = [h for i in ids for h in mention_hits(terms[i]["terms"], rows[i]["text"])]
        test = mcnemar_exact(base_hits, flat)
        rtf = [rows[i]["rtf"] for i in ids]
        ref_words = sum(len(_words(base[i]["text"])) for i in ids)
        diff = sum(_edit_distance(_words(base[i]["text"]), _words(rows[i]["text"])) for i in ids)
        assert sum(flat) == sum(hits(terms[i]["terms"], rows[i]["text"]) for i in ids)
        print(json.dumps({
            "run": name, "takes": len(ids), "mentions": len(flat), "hits": sum(flat),
            "recall": round(sum(flat) / len(flat), 4),
            "recall_ci95": [round(x, 3) for x in wilson(sum(flat), len(flat))],
            "mcnemar_vs_base": test,
            "empty_outputs": sum(not rows[i]["text"].strip() for i in ids),
            "rtf_p50": round(statistics.median(rtf), 4), "rtf_p95": round(percentile(rtf, 95), 4),
            "median_load1": round(statistics.median(rows[i]["load1"] for i in ids), 1),
            "word_diff_vs_base_pct": round(100 * diff / max(1, ref_words), 1),
        }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
