#!/usr/bin/env python3
"""WER on the EdAcc set, per accent, paired against the first run.

    python score_wer.py NORMALIZER.json EDACC_SET.jsonl BASELINE.jsonl CANDIDATE.jsonl [...]

NORMALIZER.json is Whisper's English spelling map (openai/whisper-large-v3-turbo
normalizer.json); text goes through transformers' EnglishTextNormalizer,
the Open ASR Leaderboard's normalizer, so numbers, fillers and British vs
American spelling don't count as errors.

Per run and accent: corpus WER with a 95% bootstrap CI (2,000 resamples of
utterances; the Indian group has 3 speakers, so this CI is narrower than a
per-speaker one would be), a paired sign test against the baseline (exact
McNemar over utterances where one run made fewer errors), empty outputs,
runaway outputs (more inserted words than the reference has), and RTF.
"""

from __future__ import annotations

import json
import random
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import mcnemar_exact, percentile  # noqa: E402

BOOTSTRAP = 2000
SEED = 20261028


def _alignment(reference: list[str], hypothesis: list[str]) -> tuple[int, int]:
    """(edits, insertions) of a minimum-edit alignment."""
    # Each cell holds (edits, insertions); ties prefer fewer insertions.
    previous = [(j, j) for j in range(len(hypothesis) + 1)]
    for i, expected in enumerate(reference, start=1):
        current = [(i, 0)]
        for j, heard in enumerate(hypothesis, start=1):
            substitute = (previous[j - 1][0] + (expected != heard), previous[j - 1][1])
            delete = (previous[j][0] + 1, previous[j][1])
            insert = (current[j - 1][0] + 1, current[j - 1][1] + 1)
            current.append(min(substitute, delete, insert))
        previous = current
    return previous[-1]


def main() -> int:
    from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

    normalize = EnglishTextNormalizer(json.load(open(sys.argv[1])))
    clips = {json.loads(line)["id"]: json.loads(line) for line in open(sys.argv[2])}
    runs = []
    for path in sys.argv[3:]:
        rows = {}
        for line in open(path):
            record = json.loads(line)
            if "id" in record:
                rows[record["id"]] = record
        runs.append((Path(path).stem, rows))

    scored: dict[str, dict[str, tuple[int, int, int]]] = {}
    for name, rows in runs:
        scored[name] = {}
        for clip_id, record in rows.items():
            reference = normalize(clips[clip_id]["reference"]).split()
            edits, inserted = _alignment(reference, normalize(record["text"]).split())
            scored[name][clip_id] = (edits, inserted, len(reference))

    base_name = runs[0][0]
    rng = random.Random(SEED)
    for accent in sorted({c["accent"] for c in clips.values()}):
        ids = [i for i, c in clips.items() if c["accent"] == accent and all(i in rows for _, rows in runs)]
        resamples = [[rng.choice(ids) for _ in ids] for _ in range(BOOTSTRAP)]
        for name, rows in runs:
            mine = scored[name]
            words = sum(mine[i][2] for i in ids)
            wer = sum(mine[i][0] for i in ids) / words
            spread = sorted(sum(mine[i][0] for i in s) / max(1, sum(mine[i][2] for i in s)) for s in resamples)
            # Sign test: on each utterance, did this run make fewer errors
            # than the baseline? Ties drop out, as in McNemar.
            base = scored[base_name]
            better = [mine[i][0] < base[i][0] for i in ids if mine[i][0] != base[i][0]]
            worse = [not b for b in better]
            rtf = [rows[i]["rtf"] for i in ids]
            print(json.dumps({
                "run": name, "accent": accent, "clips": len(ids), "ref_words": words,
                "wer": round(wer, 4),
                "wer_ci95": [round(spread[int(0.025 * BOOTSTRAP)], 4), round(spread[int(0.975 * BOOTSTRAP) - 1], 4)],
                "sign_vs_base": mcnemar_exact(worse, better) if name != base_name else None,
                "fewer_errors_than_base": sum(better), "more_errors_than_base": sum(worse),
                "empty_outputs": sum(not rows[i]["text"].strip() for i in ids),
                "runaway_outputs": sum(mine[i][1] > mine[i][2] for i in ids),
                "rtf_p50": round(statistics.median(rtf), 4), "rtf_p95": round(percentile(rtf, 95), 4),
                "median_load1": round(statistics.median(rows[i]["load1"] for i in ids), 1),
            }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
