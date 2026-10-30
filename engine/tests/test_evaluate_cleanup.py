"""Protect aggregate scoring from formatting, ordering, and privacy errors."""

import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "evaluate_cleanup.py"
SPEC = importlib.util.spec_from_file_location("evaluate_cleanup", SCRIPT)
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)


def test_quote_tokens_align():
    # Quote-only spans are punctuation and must not shift casing alignment.
    text = "' ' RIVER, runs."
    assert len(METRICS._forms(text)) == len(METRICS._words(text))
    measured = METRICS._measure(text, text, "river flows!", "")
    assert measured["case_token_errors"] == 1
    assert measured["punct_token_errors"] == 1


def test_bootstrap_order_stable():
    # The same seed must reproduce intervals despite input dictionary order.
    rows = {str(i): METRICS._measure("red " * 30, "red " * i, "red " * 30, "") for i in range(24)}
    first = METRICS._totals(rows)
    second = METRICS._totals(dict(reversed(list(rows.items()))))
    assert first["wwer_ci95"] == second["wwer_ci95"]
    assert first["delta_raw_ci95"] == second["delta_raw_ci95"]


def test_speaker_keys_distinct():
    # Unknown takes and a speaker named "0" must remain independent clusters.
    rows = [{"speaker": "", "wwer": 0}, {"speaker": "0", "wwer": 1}]
    assert METRICS._interval(rows, "wwer", METRICS._IntervalKind.VALUE) == [0, 1]


def test_repetition_adds_an_error():
    # Added copies are errors even when every word type existed in the input.
    row = METRICS._measure("river flows", "river river flows", "river flows", "")
    assert row["insertions"] == 1
    assert row["novel_added"] == 0


def test_word_error_budget():
    # Independent reference alignments count lost and recovered matches.
    row = METRICS._measure("river runs blue", "river red", "river runs red", "")
    assert row["alignment_lost_ref_matches"] == 1
    assert row["alignment_lost_content_matches"] == 1
    assert row["alignment_recovered_ref_matches"] == 1
    assert row["alignment_unmatched_ref_positions_both"] == 0
    assert row["raw_ref_word_errors"] == 1
    assert row["output_ref_word_errors"] == 1


def test_reference_span_reassigns():
    # Repeated words can reassign reference matches without deleting raw words.
    row = METRICS._measure("red", "red blue", "red red", "")
    assert row["alignment_lost_ref_matches"] == 1
    assert row["alignment_recovered_ref_matches"] == 1
    assert row["cleanup_content_dropped"] == 0
    assert row["cleanup_insertions"] == 1


def test_term_reference_spans():
    # A known phrase counts only when its reference positions are repaired.
    row = METRICS._measure("river band", "river bend", "river bend", "", (("river", "bend"),))
    assert row["term_all"] == 1
    assert row["term_hit"] == 1
    raw = METRICS._measure("river band", "river band", "river bend", "", (("river", "bend"),))
    assert raw["term_all"] == 1
    assert raw["term_hit"] == 0


def test_term_stays_contiguous():
    # Inserting another word breaks a Dictionary phrase despite token matches.
    row = METRICS._measure("river band", "river wide bend", "river bend", "", (("river", "bend"),))
    assert row["term_all"] == 1
    assert row["term_hit"] == 0
    repaired = METRICS._measure("river wide bend", "river bend", "river bend", "", (("river", "bend"),))
    assert repaired["term_all"] == 1
    assert repaired["term_hit"] == 1


def test_layout_and_pair():
    # Indentation and ordinal changes are layout changes; harm direction matters.
    assert METRICS._layout("1. red\n2. blue") != METRICS._layout("1. red\n  3. blue")
    assert math.isclose(METRICS._binomial(0, 6), 0.03125)
    pair = METRICS._paired({"a": {"wwer": 0, "worse": False}}, {"a": {"wwer": 1, "worse": True}})
    assert pair["removed_harm"] == 1
    assert pair["new_harm"] == 0


def test_cli_redacts_failures(tmp_path):
    # Parser exceptions can contain source text; only the exception type escapes.
    secret = "PRIVATE_SENTINEL_FOR_REDACTION_TEST"
    gold = tmp_path / "gold.jsonl"
    gold.write_text(json.dumps({secret: secret}) + "\n")
    result = subprocess.run([sys.executable, str(SCRIPT), "--gold", str(gold), "--inputs", str(tmp_path)], capture_output=True, text=True)
    assert result.returncode != 0
    assert secret not in result.stdout + result.stderr
    assert json.loads(result.stdout)["status"] == "failed"


def test_term_logs_stay_private(tmp_path):
    # Config warnings must not expose private mode names during successful scoring.
    secret = "PRIVATE_SYNTHETIC_MODE_SENTINEL"
    terms = tmp_path / "terms"
    (terms / "modes").mkdir(parents=True)
    (terms / "modes" / f"{secret}.json").write_text("not valid json")
    (terms / "config.json").write_text(json.dumps({
        "cleanup_model": "mlx-community/Qwen3.5-4B-MLX-8bit",
    }))
    gold = tmp_path / "gold.jsonl"
    gold.write_text(json.dumps({"id": "synthetic", "gold": "red", "set": "public"}) + "\n")
    inputs = tmp_path / "inputs"
    inputs.mkdir()
    (inputs / "inputs.jsonl").write_text(json.dumps({"id": "synthetic", "input": "red"}) + "\n")

    result = subprocess.run([
        sys.executable, str(SCRIPT), "--gold", str(gold), "--inputs", str(inputs),
        "--term-home", str(terms),
    ], capture_output=True, text=True)

    assert result.returncode == 0
    assert secret not in result.stdout + result.stderr
    assert json.loads(result.stdout)["protocol"]["eligible"] == 1


def _score_cli(home, gold_rows, input_files, arms=(), pinned=None, baseline=None):
    # Every fixture is synthetic; separate files exercise exported-row overlap.
    home.mkdir(parents=True, exist_ok=True)
    gold = home / "gold.jsonl"
    gold.write_text("".join(json.dumps(row) + "\n" for row in gold_rows))
    inputs = home / "inputs"
    inputs.mkdir()
    for name, rows in input_files.items():
        (inputs / name).write_text("".join(json.dumps(row) + "\n" for row in rows))
    command = [sys.executable, str(SCRIPT), "--gold", str(gold), "--inputs", str(inputs)]
    if arms:
        command.append("--arms")
        for name, rows in arms:
            path = home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            command.append(str(path))
    if pinned is not None:
        pin = home / "pinned.jsonl"
        pin.write_text("".join(json.dumps({"name": name, "set": "dev"}) + "\n" for name in pinned))
        command.extend(["--pin-dev", str(pin)])
    if baseline is not None:
        command.extend(["--baseline", baseline])
    return subprocess.run(command, capture_output=True, text=True)


def test_missing_requested_rows(tmp_path):
    # Requested takes must not disappear through the gold/input intersection.
    gold = [{"id": str(index), "gold": "red", "set": "dev"} for index in range(2)]
    raw = [{"id": str(index), "input": "red"} for index in range(2)]
    cases = ((gold, raw[:1], ["0", "1"]), (gold[:1], raw, ["0", "1"]),
             (gold, raw[:1], None))
    for index, (references, inputs, pins) in enumerate(cases):
        result = _score_cli(tmp_path / str(index), references, {"rows.jsonl": inputs}, pinned=pins)
        assert result.returncode != 0
        assert json.loads(result.stdout)["status"] == "failed"


def test_empty_universe_fails(tmp_path):
    # Empty coverage is a failed score, including disjoint nonempty inputs.
    cases = (([], []), ([{"id": "gold", "gold": "red"}], [{"id": "raw", "input": "red"}]))
    for index, (gold, raw) in enumerate(cases):
        result = _score_cli(tmp_path / str(index), gold, {"rows.jsonl": raw})
        assert result.returncode != 0
        assert json.loads(result.stdout)["status"] == "failed"


def test_conflicting_rows_fail(tmp_path):
    # Conflicting reference/input duplicates must fail without echoing content.
    secret = "PRIVATE_SYNTHETIC_DUPLICATE_SENTINEL"
    gold = [{"id": "synthetic", "gold": "red"}]
    raw = [{"id": "synthetic", "input": "red"}]
    cases = ((gold + [{"id": "synthetic", "gold": secret}], {"rows.jsonl": raw}),
             (gold, {"first.jsonl": raw, "second.jsonl": [{"id": "synthetic", "input": secret}]}))
    for index, (references, inputs) in enumerate(cases):
        result = _score_cli(tmp_path / str(index), references, inputs)
        assert result.returncode != 0
        assert json.loads(result.stdout)["status"] == "failed"
        assert secret not in result.stdout + result.stderr


def test_same_input_rows_count(tmp_path):
    # Identical export overlap is allowed, deduplicated, and counted explicitly.
    row = {"id": "synthetic", "input": "red"}
    result = _score_cli(tmp_path, [{"id": "synthetic", "gold": "red"}],
                        {"first.jsonl": [row], "second.jsonl": [row]})
    assert result.returncode == 0
    report = json.loads(result.stdout)
    assert report["protocol"]["eligible"] == 1
    assert report["protocol"]["duplicate_input_rows"] == 1
    assert report["results"]["raw"]["all"]["complete"] is True


def test_reserved_arm_labels_fail(tmp_path):
    # Arm filenames cannot replace the raw floor or reserved history output.
    gold = [{"id": "synthetic", "gold": "red"}]
    raw = {"rows.jsonl": [{"id": "synthetic", "input": "blue"}]}
    output = [{"name": "synthetic", "set": "dev", "output": "red"}]
    for label in ("raw", "history-final"):
        result = _score_cli(tmp_path / label, gold, raw, arms=((label + ".jsonl", output),))
        assert result.returncode != 0
        assert json.loads(result.stdout)["status"] == "failed"


def test_reused_arm_stems_fail(tmp_path):
    # Different directories do not make the same report label unique.
    output = [{"name": "synthetic", "set": "dev", "output": "red"}]
    result = _score_cli(tmp_path, [{"id": "synthetic", "gold": "red"}],
                        {"rows.jsonl": [{"id": "synthetic", "input": "blue"}]},
                        arms=(("first/arm.jsonl", output), ("second/arm.jsonl", output)))
    assert result.returncode != 0
    assert json.loads(result.stdout)["status"] == "failed"


def test_partial_pair_incomplete(tmp_path):
    # A complete candidate cannot give a partial baseline a complete paired test.
    gold = [{"id": str(index), "gold": "red"} for index in range(2)]
    raw = {"rows.jsonl": [{"id": str(index), "input": "blue"} for index in range(2)]}
    candidate = [{"name": str(index), "set": "dev", "output": "red"} for index in range(2)]
    baseline = [{"name": "0", "set": "dev", "output": "green orange"}]
    result = _score_cli(tmp_path, gold, raw,
                        arms=(("candidate.jsonl", candidate), ("baseline.jsonl", baseline)), baseline="baseline")
    assert result.returncode == 0
    stats = json.loads(result.stdout)["results"]["candidate"]["all"]
    assert stats["complete"] is True
    assert stats["vs_4b"]["paired_n"] == 1
    assert stats["vs_4b"]["comparison_complete"] is False


def test_complete_accent_pairs(tmp_path):
    # Complete accent subsets must not fail because the baseline has other accents.
    gold = [{"id": str(index), "gold": "red", "accent": accent}
            for index, accent in enumerate(("first", "second"))]
    raw = {"rows.jsonl": [{"id": str(index), "input": "blue"} for index in range(2)]}
    output = [{"name": str(index), "set": "public", "output": "red"} for index in range(2)]
    result = _score_cli(tmp_path, gold, raw,
                        arms=(("candidate.jsonl", output), ("baseline.jsonl", output)), baseline="baseline")
    assert result.returncode == 0
    groups = json.loads(result.stdout)["results"]["candidate"]
    for accent in ("first", "second"):
        assert groups["accent:" + accent]["vs_raw"]["comparison_complete"] is True
        assert groups["accent:" + accent]["vs_4b"]["comparison_complete"] is True
