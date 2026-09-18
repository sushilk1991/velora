"""Paired, offline-only glossary evaluation against an exported baseline module.

Synthetic corpus only: never capture or persist a user's screen for evaluation.
Run after Swift selftest verifies the same fixture's extracted glossary.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
from pathlib import Path
import re
import statistics
import sys
import time

from velora_engine import formatting
from velora_engine.cleanup_process import CleanupProcess
from velora_engine.config import Config
from scripts.benchmark_cleanup_quality import (
    CASES, MODEL_ID, resolve_benchmark_model, validate,
)

# Fix acceptance before measurement: at least two more exact spellings and
# no added safety/cleanup failures. Bound median and p95 added cleanup latency.
_MIN_IMPROVEMENT = 2
_MAX_ADDED_MS = 150
_MAX_ADDED_RATIO = 0.10


def _contains(text: str, term: str, flags: int = 0) -> bool:
    return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text, flags) is not None


def _score(case: dict, text: str) -> tuple[int, list[str]]:
    # Exact case-sensitive spellings measure usefulness; distractors are checked
    # case-insensitively so a capitalisation change cannot hide an insertion.
    exact = sum(_contains(text, term) for term in case["spoken"])
    failures = [f"unspoken:{term}" for term in case["unspoken"]
                if _contains(text, term, re.IGNORECASE)]
    failures += [f"missing:{term}" for term in case["anchors"]
                 if not _contains(text, term, re.IGNORECASE)]
    return exact, failures


def _verdict(
    baseline: int, candidate: int, failures: list[str],
    baseline_ms: list[float], candidate_ms: list[float],
) -> list[str]:
    errors = list(failures)
    if candidate - baseline < _MIN_IMPROVEMENT:
        errors.append("no_spelling_improvement")
    for fraction in (0.5, 0.95):
        old = sorted(baseline_ms)[int((len(baseline_ms) - 1) * fraction)]
        new = sorted(candidate_ms)[int((len(candidate_ms) - 1) * fraction)]
        if new - old > max(_MAX_ADDED_MS, old * _MAX_ADDED_RATIO):
            errors.append("latency_regression")
            break
    return errors


def _load_baseline(path: Path):
    # Relative package imports still resolve against the unchanged engine.
    name = "velora_engine.context_baseline"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


async def _render(engine, module, config, raw, entities, **kwargs):
    gate = module.run_gate(raw, config, entities=entities, **kwargs)
    if not gate.use_llm:
        return gate.text, False, 0.0
    started = time.perf_counter()
    result = await engine.cleanup(
        module.encode_breaks(gate.text) if not gate.romanize else gate.text,
        gate.system_prompt, check_ratio=not gate.romanize,
    )
    output = module.postprocess(result.text, gate)
    return output, result.applied, (time.perf_counter() - started) * 1000


async def _run(args) -> int:
    baseline = _load_baseline(args.baseline)
    cases = json.loads(args.corpus.read_text())
    config = Config(home=args.home)
    engine = CleanupProcess(resolve_benchmark_model(MODEL_ID))
    totals = {"baseline": 0, "glossary": 0}
    timings = {"baseline": [], "glossary": []}
    failures = []
    records = []
    await engine.load_async(formatting.STATIC_SYSTEM_PROMPT)
    try:
        # Alternate order by case/repeat to avoid crediting a warm-cache order.
        for repeat in range(args.repeats):
            for index, case in enumerate(cases):
                order = ["baseline", "glossary"]
                if (repeat + index) % 2:
                    order.reverse()
                for variant in order:
                    module = baseline if variant == "baseline" else formatting
                    entities = case["baseline_entities"] if variant == "baseline" else [
                        {"type": "glossary", "value": term} for term in case["glossary"]]
                    output, applied, elapsed = await _render(
                        engine, module, config, case["raw"], entities)
                    exact, errors = _score(case, output)
                    totals[variant] += exact
                    timings[variant].append(elapsed)
                    if variant == "glossary":
                        failures += [f"{case['id']}:{error}" for error in errors]
                    record = dict(case=case["id"], variant=variant, repeat=repeat,
                                  output=output, applied=applied, exact=exact,
                                  failures=errors, cleanup_wall_ms=round(elapsed, 1))
                    records.append(record)
                    print(json.dumps(record), flush=True)

        # Run every existing cleanup case through both modules. Compare failures
        # rather than concealing pre-existing limitations of the pinned model.
        for case in CASES:
            config.data["romanize_output"] = case.romanize
            mode = formatting.run_gate(
                case.raw, config, bundle_id=case.bundle_id,
                app_name=case.app_name, explicit_mode=case.explicit_mode).mode
            old_prompt = mode.prompt
            if case.mode_prompt is not None:
                mode.prompt = case.mode_prompt
            errors_by_variant = {}
            try:
                for variant, module in (("baseline", baseline), ("glossary", formatting)):
                    output, applied, elapsed = await _render(
                        engine, module, config, case.raw, [], bundle_id=case.bundle_id,
                        app_name=case.app_name, explicit_mode=case.explicit_mode)
                    errors = validate(case, output, applied)
                    errors_by_variant[variant] = set(errors)
                    print(json.dumps(dict(cleanup_case=case.name, variant=variant,
                                          output=output, failures=errors,
                                          cleanup_wall_ms=round(elapsed, 1))), flush=True)
            finally:
                mode.prompt = old_prompt
            failures += [f"cleanup:{case.name}:{error}" for error in
                         errors_by_variant["glossary"] - errors_by_variant["baseline"]]
    finally:
        await engine.aclose()
    errors = _verdict(totals["baseline"], totals["glossary"], failures,
                      timings["baseline"], timings["glossary"])
    print(json.dumps(dict(event="verdict", model=MODEL_ID, totals=totals,
                          median_ms={key: statistics.median(values)
                                     for key, values in timings.items()},
                          failures=errors, accepted=not errors)), flush=True)
    return int(bool(errors))


def _main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=Path("tests/fixtures/context_glossary.json"))
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(_main())
