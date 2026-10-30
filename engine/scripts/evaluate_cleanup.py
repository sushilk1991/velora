#!/usr/bin/env python3
"""Score external cleanup runs; stdout and saved reports contain totals only.

Private rows stay outside the repository. Inputs -> alignment -> aggregates;
no example, take identifier, vocabulary item, or transcript is emitted.
"""

from __future__ import annotations

import argparse
from collections import Counter
import contextlib
from enum import Enum
import io
import json
import logging
import math
from pathlib import Path
import random
import re
import sqlite3
import shutil
import sys
import tempfile

EPSILON = 1e-9
BOOTSTRAP_REPEATS = 2000
SEED = 1029
WORD = re.compile(r"[\w']+", re.UNICODE)
LIST = re.compile(r"^\s*(?:\d+[.)]|[-*•])\s+", re.MULTILINE)
# Function words are excluded only from the deletion diagnostic, not WER.
FUNCTION_WORDS = frozenset("a an the and or but if then as at by for from in into of on to with is am are was were be been being do does did have has had i me my we us our you your he him his she her it its they them their this that these those um uh er ah hmm".split())


class _IntervalKind(Enum):
    VALUE = "value"
    DELTA_RAW = "delta_raw"


def _words(text):
    return [w.strip("'") for w in WORD.findall(LIST.sub("", text).lower()) if w.strip("'")]


def _forms(text):
    text = LIST.sub("", text)
    tokens = [token for token in WORD.finditer(text) if token.group().strip("'")]
    return [(token.group().strip("'"), "".join(text[token.end():tokens[index + 1].start() if index + 1 < len(tokens) else len(text)].split())) for index, token in enumerate(tokens)]


def _layout(text):
    # Marker positions distinguish a real list from the same markers in prose.
    count, markers = 0, []
    for line in text.splitlines():
        marker = LIST.match(line)
        if marker:
            prefix = line[:marker.end()]
            markers.append((count, len(line) - len(line.lstrip()), prefix.strip()))
        count += len(_words(line))
    return markers


def _align(hyp, ref, hyp_forms=None, ref_forms=None, matched=None):
    """Minimum edits with deterministic ties: match, substitute, delete, add."""
    # Each cell retains distance only; traceback counts without exposing text.
    matrix = [list(range(len(hyp) + 1))]
    for i, target in enumerate(ref, 1):
        row = [i]
        for j, token in enumerate(hyp, 1):
            row.append(min(matrix[-1][j - 1] + (token != target), matrix[-1][j] + 1, row[-1] + 1))
        matrix.append(row)

    i, j = len(ref), len(hyp)
    counts = Counter()
    while i or j:
        if i and j and matrix[i][j] == matrix[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            counts["substitutions" if ref[i - 1] != hyp[j - 1] else "matches"] += 1
            if matched is not None and ref[i - 1] == hyp[j - 1]:
                matched[i - 1] = j - 1
            if ref[i - 1] == hyp[j - 1] and hyp_forms is not None:
                counts["case_token_errors"] += hyp_forms[j - 1][0] != ref_forms[i - 1][0]
                counts["punct_token_errors"] += hyp_forms[j - 1][1] != ref_forms[i - 1][1]
            i, j = i - 1, j - 1
            continue
        if i and matrix[i][j] == matrix[i - 1][j] + 1:
            counts["deletions"] += 1
            counts["content_dropped"] += ref[i - 1] not in FUNCTION_WORDS
            i -= 1
            continue
        counts["insertions"] += 1
        j -= 1
    return matrix[-1][-1], counts


def _binomial(better, worse):
    n = better + worse
    if not n:
        return 1.0
    # lgamma avoids overflow for public sets larger than 1,024 clips.
    probability = sum(math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) - n * math.log(2)) for i in range(min(better, worse) + 1))
    return min(1.0, 2 * probability)


def _paired(rows, base, expected=None):
    common = sorted(rows.keys() & base.keys())
    better = sum(rows[k]["wwer"] < base[k]["wwer"] - EPSILON for k in common)
    worse = sum(rows[k]["wwer"] > base[k]["wwer"] + EPSILON for k in common)
    new_harm = sum(rows[k]["worse"] and not base[k]["worse"] for k in common)
    removed_harm = sum(base[k]["worse"] and not rows[k]["worse"] for k in common)
    universe = set(expected) if expected is not None else rows.keys() | base.keys()
    return {"paired_n": len(common), "comparison_complete": bool(common) and set(common) == universe, "wins": better, "losses": worse, "sign_p": _binomial(better, worse), "new_harm": new_harm, "removed_harm": removed_harm, "mcnemar_p": _binomial(new_harm, removed_harm)}


def _term_matches(start, length, matched):
    # Aligned term tokens must remain adjacent; "river wide bend" fails.
    positions = [matched.get(index) for index in range(start, start + length)]
    return None not in positions and positions == list(range(positions[0], positions[0] + length))


def _measure(raw, output, gold, speaker, terms=()):
    rw, ow, gw = _words(raw), _words(output), _words(gold)
    out_matches, raw_matches = {}, {}
    edits, alignment = _align(ow, gw, _forms(output), _forms(gold), out_matches)
    raw_edits, raw_alignment = _align(rw, gw, matched=raw_matches)
    _, cleanup_alignment = _align(ow, rw)
    formatted, _ = _align(output.split(), gold.split())
    # Independent alignments diagnose changed reference matches, not causality.
    # Duplicate words can reassign matches even for insertion-only cleanup.
    lost = raw_matches.keys() - out_matches.keys()
    attribution = {
        "alignment_lost_ref_matches": len(lost),
        "alignment_lost_content_matches": sum(gw[index] not in FUNCTION_WORDS for index in lost),
        "alignment_recovered_ref_matches": len(out_matches.keys() - raw_matches.keys()),
        "alignment_unmatched_ref_positions_both": len(gw) - len(raw_matches.keys() | out_matches.keys()),
        "raw_ref_word_errors": len(gw) - len(raw_matches),
        "output_ref_word_errors": len(gw) - len(out_matches),
    }
    fixes = set(gw) - set(rw)
    # A term opportunity must occur in the reference at aligned positions.
    term_all, term_hit = 0, 0
    for term in terms:
        for start in range(len(gw) - len(term) + 1):
            if tuple(gw[start:start + len(term)]) != term:
                continue
            if _term_matches(start, len(term), raw_matches):
                continue
            term_all += 1
            term_hit += _term_matches(start, len(term), out_matches)
    return {"wwer": edits / max(1, len(gw)), "fwer": formatted / max(1, len(gold.split())), "edits": edits, "raw_edits": raw_edits, "cleanup_net_edits": edits - raw_edits, "raw_content_dropped": raw_alignment["content_dropped"], "cleanup_content_dropped": cleanup_alignment["content_dropped"], "cleanup_insertions": cleanup_alignment["insertions"], "cleanup_substitutions": cleanup_alignment["substitutions"], "ref_words": len(gw), "raw_wwer": raw_edits / max(1, len(gw)), "worse": edits > raw_edits, "exact": output.strip() == gold.strip(), "novel_added": len(set(ow) - set(rw) - set(gw)), "fix_hit": len(fixes & set(ow)), "fix_all": len(fixes), "term_hit": term_hit, "term_all": term_all, "format_only": ow == gw and output.strip() != gold.strip(), "case_mismatch": ow == gw and [w for w in WORD.findall(LIST.sub("", output))] != [w for w in WORD.findall(LIST.sub("", gold))], "list_mismatch": _layout(output) != _layout(gold), "speaker": speaker, **alignment, **attribution}


def _interval(rows, key, kind):
    # Resample speakers when known; owner samples are paired take bootstraps.
    clusters = {}
    for index, row in enumerate(rows):
        cluster = ("speaker", str(row["speaker"])) if row["speaker"] not in ("", None) else ("take", index)
        clusters.setdefault(cluster, []).append(row[key] - row["raw_wwer"] if kind is _IntervalKind.DELTA_RAW else row[key])
    groups = [clusters[key] for key in sorted(clusters)]
    rng = random.Random(SEED)
    samples = []
    for _ in range(BOOTSTRAP_REPEATS):
        picked = [groups[rng.randrange(len(groups))] for _ in groups]
        samples.append(sum(map(sum, picked)) / sum(map(len, picked)))
    samples.sort()
    return [samples[int(BOOTSTRAP_REPEATS * 0.025)], samples[int(BOOTSTRAP_REPEATS * 0.975)]]


def _totals(takes):
    rows = [takes[key] for key in sorted(takes)]
    n = len(rows)
    if not n:
        return {"n": 0}
    sums = {key: sum(row.get(key, 0) for row in rows) for key in ("alignment_lost_ref_matches", "alignment_lost_content_matches", "alignment_recovered_ref_matches", "alignment_unmatched_ref_positions_both", "raw_ref_word_errors", "output_ref_word_errors", "exact", "worse", "novel_added", "fix_hit", "fix_all", "term_hit", "term_all", "deletions", "content_dropped", "raw_content_dropped", "cleanup_content_dropped", "cleanup_insertions", "cleanup_substitutions", "case_token_errors", "punct_token_errors", "insertions", "substitutions", "format_only", "case_mismatch", "list_mismatch", "edits", "raw_edits", "cleanup_net_edits", "ref_words")}
    return {"n": n, "fwer": sum(row["fwer"] for row in rows) / n, "wwer": sum(row["wwer"] for row in rows) / n, "micro_wwer": sums["edits"] / max(1, sums["ref_words"]), "worse_rate": sums["worse"] / n, "added_takes": sum(row["novel_added"] > 0 for row in rows), "fix_rate": sums["fix_hit"] / sums["fix_all"] if sums["fix_all"] else None, "term_rate": sums["term_hit"] / sums["term_all"] if sums["term_all"] else None, "wwer_ci95": _interval(rows, "wwer", _IntervalKind.VALUE), "delta_raw_ci95": _interval(rows, "wwer", _IntervalKind.DELTA_RAW), "clusters": len({str(row["speaker"]) for row in rows if row["speaker"] not in ("", None)}), **sums}


def _load_terms(home):
    if not home:
        return ()
    # Config can migrate files; read the frozen vocabulary through a temp copy.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
    with tempfile.TemporaryDirectory(prefix="velora-score-terms-") as copied:
        shutil.copytree(home, copied, dirs_exist_ok=True)
        # Config warnings may contain private mode names or malformed text.
        # Suppress library output while extracting aggregate-only vocabulary.
        previous = logging.root.manager.disable
        try:
            logging.disable(logging.CRITICAL)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                from velora_engine.config import Config
                config = Config(home=Path(copied))
                terms = config.global_vocabulary + [term for mode in config.modes.values() for term in mode.vocabulary]
                return tuple(sorted({tuple(_words(term)) for term in terms if _words(term)}))
        finally:
            logging.disable(previous)


def _read_rows(path):
    with Path(path).open() as stream:
        return [json.loads(line) for line in stream if line.strip()]


def _add_unique(values, key, value):
    # Identical exported rows may repeat; conflicting source text must fail.
    if key not in values:
        values[key] = value
        return 0
    if values[key] != value:
        raise ValueError("conflicting_duplicate")
    return 1


def _run(args):
    # An arm cannot replace the raw floor or another arm through its filename.
    labels = [Path(path).stem for path in args.arms]
    if len(set(labels)) != len(labels) or set(labels) & {"raw", "history-final"}:
        raise ValueError("reserved_or_duplicate_arm_label")
    terms = _load_terms(args.term_home)
    gold_rows = _read_rows(args.gold)
    gold, raw = {}, {}
    gold_duplicates, input_duplicates = 0, 0
    for row in gold_rows:
        gold_duplicates += _add_unique(gold, row["id"], row)
    for path in Path(args.inputs).glob("*.jsonl"):
        for row in _read_rows(path):
            input_duplicates += _add_unique(raw, row["id"], row["input"])
    pinned = {row["name"] for row in _read_rows(args.pin_dev) if row["set"] == "dev"} if args.pin_dev else None
    pinned_sw = {row["name"] for row in _read_rows(args.pin_sw) if row["set"] == "sw"} if args.pin_sw else None

    # Freeze the requested universe before checking input availability.
    eligible = set(gold) if pinned is None else pinned | {name for name in gold if name.startswith("sw-")}
    if pinned_sw is not None:
        eligible = {name for name in eligible if not name.startswith("sw-")} | pinned_sw
    if not eligible or not eligible <= gold.keys() or not eligible <= raw.keys():
        raise ValueError("empty_or_incomplete_reference_inputs")
    sets = {name: (gold[name].get("set") or ("sw" if name.startswith("sw-") else "dev")) for name in eligible}
    outputs = {"raw": {name: raw[name] for name in eligible}}
    duplicates = {"raw": 0}
    for path in args.arms:
        label = Path(path).stem
        rows = [row for row in _read_rows(path) if row.get("name") in eligible and row.get("set") not in {"train", "synth", "bench"}]
        outputs[label] = {row["name"]: row["output"] for row in rows}
        duplicates[label] = len(rows) - len(outputs[label])
    if args.history:
        connection = sqlite3.connect(f"file:{Path(args.history).resolve()}?mode=ro", uri=True)
        outputs["history-final"] = {f"take-{row_id}": final for row_id, final in connection.execute("SELECT id, final FROM dictations") if f"take-{row_id}" in eligible and final is not None}
        connection.close()

    measured = {label: {name: _measure(raw[name], text, gold[name]["gold"], gold[name].get("speaker", ""), terms) for name, text in values.items()} for label, values in outputs.items()}
    report = {"protocol": {"seed": SEED, "bootstrap_repeats": BOOTSTRAP_REPEATS, "eligible": len(eligible), "pinned_dev": len(pinned) if pinned is not None else None, "duplicate_gold_rows": gold_duplicates, "duplicate_input_rows": input_duplicates, "alignment_diagnostic": "Independent reference alignments may reassign repeated words; changed matches are not causal speech loss or repair"}, "results": {}}
    groups = {"all": eligible}
    groups.update({f"set:{value}": {name for name in eligible if sets[name] == value} for value in sorted(set(sets.values()))})
    groups.update({f"accent:{value}": {name for name in eligible if gold[name].get("accent") == value} for value in sorted({row.get("accent", "") for row in gold.values()} - {""})})
    for label, values in measured.items():
        report["results"][label] = {}
        for group, names in groups.items():
            takes = {name: values[name] for name in values.keys() & names}
            stats = _totals(takes)
            stats["missing"] = len(names - values.keys())
            stats["duplicate_rows"] = duplicates.get(label, 0)
            stats["complete"] = stats["missing"] == 0 and stats["duplicate_rows"] == 0
            stats["vs_raw"] = _paired(takes, measured["raw"], names)
            stats["vs_raw"]["comparison_complete"] &= stats["complete"]
            if args.baseline in measured:
                stats["vs_4b"] = _paired(takes, measured[args.baseline], names)
                stats["vs_4b"]["comparison_complete"] &= stats["complete"] and duplicates.get(args.baseline, 0) == 0
            report["results"][label][group] = stats
    serialized = json.dumps(report, indent=2, sort_keys=True)
    if args.out:
        Path(args.out).write_text(serialized + "\n")
    print(serialized)


def _main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gold", required=True)
    parser.add_argument("--inputs", required=True)
    parser.add_argument("--arms", nargs="*", default=[])
    parser.add_argument("--pin-dev")
    parser.add_argument("--pin-sw")
    parser.add_argument("--history")
    parser.add_argument("--term-home")
    parser.add_argument("--baseline", default="oc-qwen4b")
    parser.add_argument("--out")
    args = parser.parse_args()
    try:
        _run(args)
    except Exception as error:
        # Parsers can include offending private text in exception messages.
        print(json.dumps({"error_type": type(error).__name__, "status": "failed"}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    _main()
