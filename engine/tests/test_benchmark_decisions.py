"""The decision benchmark's item set is a fixed yardstick across bakeoffs."""

import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_decisions import (  # noqa: E402
    CATEGORIES,
    build_items,
    parse_worker_output,
    summarize,
)
from velora_engine.decisions import validate_questions  # noqa: E402

# Items as scored on 2026-09-28 and 2026-10-27. Editing them breaks comparison
# with every recorded result: update this only together with a new baseline.
ITEMS_SHA256 = "83d82793855d371f5f2ac9b4c83097c8d035c6412b0c25a77173f80f73fba095"
# Revision 2, first scored 2026-10-28.
ITEMS_V2_SHA256 = "ceebd33c781071fe004a82fae7d44f68a1202f9b611f147bacce6839ed4f1197"


def _digest(items) -> str:
    canonical = json.dumps(
        [{**item, "question": item["question"].to_dict()} for item in items],
        ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()


def test_items_match_the_recorded_baseline_set():
    items = build_items()

    assert _digest(items) == ITEMS_SHA256
    assert [sum(item["cat"] == cat for item in items) for cat in CATEGORIES] == [26, 8, 8, 9, 6, 5]
    assert _digest(build_items(2)) == ITEMS_V2_SHA256


def test_revision_two_selects_only_the_open_conversation_row():
    """The chat list and the conversation pane must agree on which chat is
    open; revision 1 kept Priya selected under Shivangi's open chat."""
    for item in build_items(2):
        state = item["state"]
        if "[41] parent=40" not in state:
            continue
        header = state.split('[41] parent=40 AXButton label="', 1)[1].split('"', 1)[0]
        selected = [line.split('label="', 1)[1].split(",")[0]
                    for line in state.splitlines() if "state=selected" in line
                    and "collection_member=true" in line]
        assert selected in ([header], []), item["id"]


def test_revision_two_keeps_every_question_and_gold():
    """Only the selection moves. Pick options quote whole element lines, so
    a row's option text gains or loses `state=selected` with it."""
    def shape(item):
        question = item["question"]
        return (item["id"], item["gold"], question.instructions,
                [key for key, _ in question.options])

    assert [shape(i) for i in build_items(1)] == [shape(i) for i in build_items(2)]


def test_every_item_is_a_question_the_engine_would_ask():
    items = build_items()

    assert len({item["id"] for item in items}) == len(items)
    for item in items:
        validate_questions(item["state"], [item["question"]])
        assert item["gold"] in {key for key, _ in item["question"].options}


def test_worker_records_survive_text_printed_before_them():
    # transformers prints a trust_remote_code prompt with no newline while a
    # custom-code checkpoint loads; it lands in front of the first item.
    stdout = (
        "The repository /x contains custom code.\n"
        "Do you wish to run the custom code? [y/N] "
        '{"event": "item", "id": "route-1"}\n'
        '{"event": "item", "id": "route-2"}\n'
        "plain log line\n"
    )

    records = parse_worker_output(stdout)

    assert [record["id"] for record in records] == ["route-1", "route-2"]


def test_summary_counts_hits_per_category():
    rows = [
        {"id": "route-1", "cat": "route", "gold": "open", "pred": "open",
         "p_gold": 0.9, "label_mass": 1.0, "ms": 10.0},
        {"id": "route-2", "cat": "route", "gold": "play", "pred": "search",
         "p_gold": 0.2, "label_mass": 0.5, "ms": 30.0},
        {"id": "is_nav-1", "cat": "is_nav", "gold": "true", "pred": "true",
         "p_gold": 0.7, "label_mass": 0.9, "ms": 20.0},
    ]

    summary = summarize("fixture", rows)

    assert summary["correct"] == 2
    assert summary["by_category"]["route"] == "1/2"
    assert summary["by_category"]["is_nav"] == "1/1"
    assert summary["by_category"]["sent_ok"] == "0/0"
    assert summary["misses"] == ["route-2"]
    assert summary["min_label_mass"] == 0.5
    assert summary["accuracy_ci95"] == (0.208, 0.939)
