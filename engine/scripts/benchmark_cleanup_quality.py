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
import tempfile

from velora_engine.cleanup import CleanupEngine
from velora_engine.config import Config
from velora_engine.formatting import (
    STATIC_SYSTEM_PROMPT,
    build_prefill_prompt_candidates,
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
)


def validate(case: Case, output: str, applied: bool) -> list[str]:
    failures: list[str] = []
    if not applied:
        failures.append("cleanup_not_applied")
    if not output.endswith(case.ending):
        failures.append(f"missing_ending:{case.ending}")
    lower = output.lower()
    for required in case.required:
        if required.lower() not in lower:
            failures.append(f"missing:{required}")
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
                candidates = build_prefill_prompt_candidates(
                    config,
                    bundle_id=case.bundle_id,
                    app_name=case.app_name,
                    explicit_mode=None,
                    entities=None,
                )
                prepared = await engine.prepare_prefix(candidates)
                result = await engine.cleanup(
                    case.raw,
                    gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    allowed_terms=config.global_vocabulary,
                )
                output = postprocess(result.text, gate) if result.applied else result.text
                case_failures = validate(case, output, result.applied)
                if not prepared.applied:
                    case_failures.append(f"prefix_not_prepared:{prepared.reason}")
                if not result.cache_hit:
                    case_failures.append("prepared_cache_miss")
                failures += bool(case_failures)
                print(json.dumps({
                    "case": case.name,
                    "words": len(case.raw.split()),
                    "model": MODEL_ID,
                    "prepared_ms": prepared.ms,
                    "prepared_tokens": prepared.tokens,
                    "cleanup_ms": result.ms,
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
