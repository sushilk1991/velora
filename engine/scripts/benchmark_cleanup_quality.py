#!/usr/bin/env python3
"""Reproducible exact-model cleanup quality and latency benchmark.

Run from ``engine/``:

    uv run python scripts/benchmark_cleanup_quality.py
    uv run python scripts/benchmark_cleanup_quality.py --list

The runner fixes the model ID and uses an isolated default config. It prints
one JSON object per case and exits non-zero if punctuation, grammar, entity, or
meaning-preservation checks fail. It never downloads a smaller fallback model.
"""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict, dataclass
import json
import os
import re
import tempfile

from velora_engine.cleanup import CleanupEngine
from velora_engine.config import Config
from velora_engine.formatting import (
    STATIC_SYSTEM_PROMPT,
    postprocess,
    run_gate,
)

MODEL_ID = "mlx-community/Qwen3.5-4B-MLX-8bit"


@dataclass(frozen=True)
class Case:
    name: str
    raw: str
    bundle_id: str = "com.apple.Notes"
    app_name: str = "Notes"
    ending: str = "."
    required: tuple[str, ...] = ()
    numbered_items: int | None = None
    required_lines: tuple[str, ...] = ()
    explicit_mode: str | None = None
    required_intro: str | None = None


CASES = (
    Case(
        "declarative",
        "we should ship this performance fix today because the current app feels too slow",
    ),
    Case(
        "grammar",
        "the performance issues was much worse yesterday and the background animations keeps "
        "running when the window is hidden",
        required=("issues were", "animations keep"),
    ),
    Case(
        "question",
        "why does the speech engine take longer on this mac when both models are already loaded",
        ending="?",
    ),
    Case(
        "terminal_prose",
        "please inspect every performance bottleneck in this branch and preserve the exact models "
        "while fixing punctuation grammar and the live transcript display",
        bundle_id="com.apple.Terminal",
        app_name="Terminal",
        required=("exact models", "live transcript"),
    ),
    Case(
        "names_and_numbers",
        "please schedule Priya Sharma for the Q3 review at three thirty and set the budget to "
        "forty two thousand dollars",
        required=("Priya Sharma", "Q3", "3:30", "42,000"),
    ),
    Case(
        "long_meaning",
        "on this M4 Max keep Whisper and Qwen exactly as configured then remove repeated prompt "
        "prefill cancel stale background work stop hidden animations preserve every dictated "
        "detail and make the final result grammatical and fully punctuated without sending audio "
        "or text away from the device",
        required=("M4 Max", "Whisper", "Qwen", "audio", "device"),
    ),
    Case(
        "implicit_issue_list",
        "there are three issues with Velora the first issue is long dictations take too long "
        "after I release the hotkey the second issue is rambling feedback stays as one paragraph "
        "and the third issue is that correction messages are not structured clearly",
        bundle_id="com.mitchellh.ghostty",
        app_name="Ghostty",
        required=("long dictations", "one paragraph", "correction messages"),
        numbered_items=3,
    ),
    Case(
        "implicit_feedback_list",
        "I have a few pieces of feedback about the settings screen the microphone picker is hard "
        "to scan also the save action gives no confirmation and the error message does not explain "
        "how to recover",
        bundle_id="com.mitchellh.ghostty",
        app_name="Ghostty",
        required=("microphone picker", "save action", "error message"),
        numbered_items=3,
    ),
    Case(
        "natural_launch_plan",
        "for friday's launch sam owns the release maya will send the notes before lunch and i "
        "will check metrics after we ship",
        required=("Sam", "Maya", "before lunch", "metrics"),
        numbered_items=3,
    ),
    Case(
        "three_priorities_counterexample",
        "Just want to test out. So there are three priorities for today. First, I need to "
        "update Velora. Second, I need to post it on Hacker News. And the third important "
        "priority is posting the first comment on Hacker News.",
        bundle_id="com.openai.codex",
        app_name="ChatGPT",
        required=("update Velora", "post it on Hacker News", "first comment on Hacker News"),
        numbered_items=3,
    ),
    Case(
        "explicit_separate_count_lines",
        "Here are the counting and each of them is on a different line. 1, 2, 3, 4.",
        bundle_id="com.openai.codex",
        app_name="ChatGPT",
        ending="",
        required_lines=("1", "2", "3", "4"),
        required_intro="different line",
    ),
    Case(
        "note_ordinal_priorities",
        "For the launch there are three priorities. First update Velora. Second post it "
        "on Hacker News. Third post the first comment.",
        bundle_id="com.apple.Notes",
        app_name="Notes",
        required=("update Velora", "Hacker News", "first comment"),
        numbered_items=3,
        explicit_mode="Note",
    ),
    Case(
        "rambling_multi_problem_request",
        "Velora feels very slow compared with Wispr Flow and longer dictations take too much "
        "time to return the text and I also do not feel it is smart about issue reports because "
        "separate problems stay in one paragraph and the intended structure is lost",
        bundle_id="com.mitchellh.ghostty",
        app_name="Ghostty",
        required=("longer dictations", "issue reports"),
        numbered_items=2,
    ),
    Case(
        "single_issue_stays_prose",
        "the only issue I found is that the settings window opens slowly after the first launch "
        "but everything else behaves correctly and should stay unchanged",
        bundle_id="com.mitchellh.ghostty",
        app_name="Ghostty",
        required=("only issue", "everything else"),
        numbered_items=0,
    ),
)


def validate(case: Case, output: str, applied: bool) -> list[str]:
    failures: list[str] = []
    if not applied:
        failures.append("cleanup_not_applied")
    if not output.endswith(case.ending):
        failures.append(f"missing_ending:{case.ending}")
    lower = output.lower()
    if case.numbered_items is not None:
        numbered = [
            line for line in output.splitlines()
            if re.match(r"^\d+\.\s+", line.strip())
        ]
        all_list_items = [
            line for line in output.splitlines()
            if re.match(r"^(?:\d+[.)]|[-*])\s+", line.strip())
        ]
        if len(numbered) != case.numbered_items:
            failures.append(
                f"numbered_items:{len(numbered)}!=expected:{case.numbered_items}"
            )
        elif any(
            not line.strip().startswith(f"{index}. ")
            for index, line in enumerate(numbered, start=1)
        ):
            failures.append("numbering_not_sequential")
        if case.numbered_items == 0 and all_list_items:
            failures.append("unexpected_list_items")
        elif case.numbered_items > 0 and len(all_list_items) != len(numbered):
            failures.append("unexpected_non_numbered_list_items")
        required_scope = (
            "\n".join(numbered).lower()
            if case.numbered_items > 0
            else lower
        )
    else:
        required_scope = lower
    for required in case.required:
        if required.lower() not in required_scope:
            failures.append(f"missing:{required}")
    if case.required_lines:
        lines = [line.strip() for line in output.splitlines()]
        cursor = 0
        for index, required in enumerate(case.required_lines):
            matched = next(
                (
                    line_index for line_index in range(cursor, len(lines))
                    if lines[line_index] == required
                    or (
                        index == len(case.required_lines) - 1
                        and lines[line_index].rstrip(".!?") == required
                    )
                ),
                None,
            )
            if matched is None:
                failures.append(f"missing_line:{required}")
            else:
                cursor = matched + 1
    if case.required_intro:
        first_line = output.splitlines()[0] if output.splitlines() else ""
        if case.required_intro.lower() not in first_line.lower():
            failures.append(f"missing_intro:{case.required_intro}")
    return failures


async def run(selected: set[str] | None) -> int:
    with tempfile.TemporaryDirectory(prefix="velora-benchmark-") as home:
        os.environ["VELORA_HOME"] = home
        config = Config()
        engine = CleanupEngine(MODEL_ID)
        await engine.load_async(STATIC_SYSTEM_PROMPT)
        failures = 0
        try:
            for case in CASES:
                if selected and case.name not in selected:
                    continue
                gate = run_gate(
                    case.raw,
                    config,
                    bundle_id=case.bundle_id,
                    app_name=case.app_name,
                    explicit_mode=case.explicit_mode,
                )
                if not gate.use_llm:
                    record = {
                        "case": case.name,
                        "model": MODEL_ID,
                        "failures": [f"unexpected_gate:{gate.reason}"],
                    }
                    print(json.dumps(record, ensure_ascii=False))
                    failures += 1
                    continue
                result = await engine.cleanup(
                    case.raw,
                    gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    allowed_terms=config.global_vocabulary,
                )
                output = postprocess(result.text, gate) if result.applied else result.text
                case_failures = validate(case, output, result.applied)
                if not result.cache_hit:
                    case_failures.append("startup_cache_miss")
                failures += bool(case_failures)
                print(json.dumps({
                    "case": case.name,
                    "words": len(case.raw.split()),
                    "model": MODEL_ID,
                    "prefix_tokens": result.prefix_tokens,
                    "cleanup_ms": result.ms,
                    "reason": result.reason,
                    "ttft_ms": result.ttft_ms,
                    "decode_ms": result.decode_ms,
                    "cache_hit": result.cache_hit,
                    "output": output,
                    "failures": case_failures,
                }, ensure_ascii=False))
        finally:
            engine.close()
        return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="print fixtures without loading MLX")
    parser.add_argument("--case", action="append", choices=[case.name for case in CASES])
    args = parser.parse_args()
    if args.list:
        print(json.dumps({
            "model": MODEL_ID,
            "cases": [asdict(case) for case in CASES],
        }, indent=2, ensure_ascii=False))
        return 0
    return asyncio.run(run(set(args.case) if args.case else None))


if __name__ == "__main__":
    raise SystemExit(main())
