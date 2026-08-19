#!/usr/bin/env python3
"""Reproducible cleanup-model quality, latency, and memory benchmark.

Run from ``engine/``:

    uv run python scripts/benchmark_cleanup_quality.py
    uv run python scripts/benchmark_cleanup_quality.py \
      --model mlx-community/Qwen3.5-4B-MLX-8bit \
      --model mlx-community/Qwen3.5-4B-MLX-4bit --repeats 3
    uv run python scripts/benchmark_cleanup_quality.py --list

Models run sequentially in separate worker processes so their allocator and
physical-footprint measurements do not contaminate each other. The first model
is the baseline. A candidate is accepted only when it adds no quality failures
and meets the requested latency and memory reductions.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass
from typing import Any

from velora_engine.cleanup_process import CleanupProcess
from velora_engine.config import Config
from velora_engine.formatting import (
    STATIC_SYSTEM_PROMPT,
    build_prefill_prompt_candidates,
    encode_breaks,
    is_mostly_non_latin,
    postprocess,
    run_gate,
)

MODEL_ID = "mlx-community/Qwen3.5-4B-MLX-8bit"
MODEL_REVISION = "5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d"
S1_MINI_MODEL_ID = "superwhisper/s1-mini"
S1_MINI_REVISION = "65f84bcda1d13df582c4a8443c1c5aa53c0c66db"
PINNED_MODEL_REVISIONS = {
    MODEL_ID: MODEL_REVISION,
    S1_MINI_MODEL_ID: S1_MINI_REVISION,
}
PINNED_MODEL_WEIGHT_SHA256 = {
    MODEL_ID: {
        "model.safetensors":
            "87c362fdb36bdee8e32ff5961bdceca58d26c2d9b00738543cc0e17e985b46ce",
    },
    S1_MINI_MODEL_ID: {
        "model.safetensors":
            "69d2057077ab4dc738aaaab75d2a8ffa141e3a09fb9d956198cfce46f381131a",
    },
}
S1_MINI_SYSTEM_PROMPT = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)


@dataclass(frozen=True)
class Case:
    name: str
    raw: str
    bundle_id: str = "com.apple.Notes"
    app_name: str = "Notes"
    ending: str = "."
    required: tuple[str, ...] = ()
    forbidden: tuple[str, ...] = ()
    numbered_items: int | None = None
    required_lines: tuple[str, ...] = ()
    explicit_mode: str | None = None
    required_intro: str | None = None
    required_outside: tuple[str, ...] = ()
    romanize: bool = False
    mode_prompt: str | None = None
    required_prompt: str | None = None


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
        "terminal_meta_edit_correction",
        "I am just checking whether streaming content works or not. Yeah, it is working. "
        "No, no, it is not working. But again, it feels like typing. So it's good. "
        "I am confused that why this didn't work. in case of terminal. Also, let's meet "
        "at 3pm. No, no, no, 6pm. 6pm not 3pm. Can you change the previous line and "
        "make it 6pm?",
        bundle_id="com.apple.Terminal",
        app_name="Terminal",
        required=("streaming content", "case of terminal", "let's meet at 6"),
        forbidden=("3pm", "3 p.m.", "6pm not 3pm", "change the previous line"),
    ),
    Case(
        "names_and_numbers",
        "please schedule Priya Sharma for the Q3 review at three thirty and set the budget to "
        "forty two thousand dollars",
        required=("Priya Sharma", "Q3", "3:30", "42,000"),
    ),
    Case(
        "custom_mode_prompt",
        "please keep this Velora update concise while preserving the package name and every "
        "technical detail that I dictated here",
        required=("Velora", "package name", "technical detail"),
        mode_prompt="Keep the output as one concise paragraph.",
        required_prompt="Mode instructions: Keep the output as one concise paragraph.",
    ),
    Case(
        "romanize_hindi_custom_mode",
        "नमस्ते Velora आज मौसम अच्छा है और मैं काम कर रहा हूँ",
        ending="",
        required=("Namaste", "Velora", "aaj"),
        romanize=True,
        mode_prompt="Keep this as one short, casual message.",
        required_prompt="Keep this as one short, casual message.",
    ),
    Case(
        "romanize_hindi_note_mode",
        "मुझे आज तीन काम करने हैं पहला रिपोर्ट भेजना दूसरा मीटिंग तय करना तीसरा कोड जांचना",
        ending="",
        required=("Mujhe", "aaj", "teen kaam", "bhejna", "tay karna", "code"),
        forbidden=("Maine", "Send report", "Schedule meeting", "Check code"),
        explicit_mode="Note",
        romanize=True,
        required_prompt="Mode formatting preferences",
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
        "implicit_counted_todo_list",
        "So today the priority is three items. First is I need to buy books. Second is I "
        "need to buy apples. Third is I need to buy eggs. Basically a dozen of eggs.",
        bundle_id="com.sublimetext.4",
        app_name="Sublime Text",
        required=("buy books", "buy apples", "buy eggs", "dozen of eggs"),
        numbered_items=3,
        required_intro="three items",
    ),
    Case(
        "mismatched_ordinal_counted_list",
        "Okay, so I need to buy three items today. First is the books, second is three "
        "apples, and fourth is one dozen of eggs.",
        bundle_id="com.sublimetext.4",
        app_name="Sublime Text",
        required=("books", "three apples", "one dozen of eggs"),
        numbered_items=3,
        required_intro="three items",
    ),
    Case(
        "hindi_counted_list",
        "मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे।",
        ending="",
        required=("किताबें", "तीन सेब", "एक दर्जन अंडे"),
        numbered_items=3,
        required_intro="तीन चीज़ें",
    ),
    Case(
        "chinese_counted_list",
        "我今天需要买三样东西。第一是书，第二是三个苹果，第四是一打鸡蛋。",
        ending="。",
        required=("书", "三个苹果", "一打鸡蛋"),
        numbered_items=3,
        required_intro="三样东西",
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
    Case(
        "temporal_narrative_stays_prose",
        "First I woke up early and made coffee. Second I walked to the station. Third I "
        "remembered that I had left my notebook at home, so I went back for it.",
        required=("woke up", "station", "notebook"),
        numbered_items=0,
    ),
    Case(
        "ordinal_nouns_stay_prose",
        "This is my first time visiting the office on the second floor, and the third room "
        "on the left is where the design team works.",
        required=("first time", "second floor", "third room"),
        numbered_items=0,
    ),
    Case(
        "counted_narrative_becomes_list",
        "Three things happened today. First I overslept. Second I missed the standup. Third "
        "my badge stopped working, so I had to wait for security.",
        required=("overslept", "standup", "badge"),
        numbered_items=3,
        required_intro="three things happened today",
    ),
    Case(
        "ordinary_counting_stays_prose",
        "During practice he counted one two three four five and then jumped into the pool "
        "while everyone watched from the side.",
        required=("counted", "jumped", "pool"),
        numbered_items=0,
    ),
    Case(
        "new_topic_follows_implicit_list",
        "Today's shopping list has three items. First I need to buy books. Second I need to "
        "buy apples. Third I need to buy eggs. Anyway, I will head out at noon.",
        required=("buy books", "buy apples", "buy eggs"),
        numbered_items=3,
        required_intro="three items",
        required_outside=("head out at noon",),
    ),
)


def s1_mini_prompt(case: Case) -> tuple[str, str]:
    """Return S1-mini's documented input using production-observable context.

    Velora has no explicit S1 prose/list preference today. The benchmark must
    therefore use prose instead of leaking each fixture's expected list count
    into the model request.
    """
    chat_bundles = {
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
    }
    email_bundles = {
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.SparkDesktop",
        "com.readdle.smartemail-Mac",
    }
    styling = "semi-casual" if case.bundle_id in chat_bundles else "semi-formal"
    structure = "prose"
    context = "email" if case.bundle_id in email_bundles else "general"
    control = (
        f"[Styling: {styling}] [Structure: {structure}] [Context: {context}]"
    )
    return S1_MINI_SYSTEM_PROMPT, f"{control}\n{case.raw}"


def resolve_benchmark_model(model_id: str) -> str:
    """Resolve every repository model to an immutable local snapshot."""
    local_path = Path(model_id).expanduser()
    if local_path.exists():
        return str(local_path.resolve())
    revision = PINNED_MODEL_REVISIONS.get(model_id)
    if revision is None:
        raise ValueError(
            f"benchmark model {model_id!r} has no immutable revision; "
            "use a local snapshot or add a reviewed pin"
        )
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    try:
        return snapshot_download(
            repo_id=model_id,
            revision=revision,
            local_files_only=True,
        )
    except LocalEntryNotFoundError:
        return snapshot_download(
            repo_id=model_id,
            revision=revision,
        )


def _file_sha256(path: Path) -> str:
    resolved = path.resolve()
    # Hugging Face stores LFS blobs under their SHA-256 object name. Using that
    # content address avoids rereading multi-gigabyte weights on every run.
    if (
        resolved.parent.name == "blobs"
        and re.fullmatch(r"[0-9a-f]{64}", resolved.name)
    ):
        return resolved.name
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def benchmark_model_evidence(
    model_id: str, resolved_path: str
) -> dict[str, Any]:
    root = Path(resolved_path)
    hashes = {
        str(path.relative_to(root)): _file_sha256(path)
        for path in sorted(root.rglob("*.safetensors"))
    }
    expected = PINNED_MODEL_WEIGHT_SHA256.get(model_id)
    if expected is not None and hashes != expected:
        raise RuntimeError(
            f"weight hash mismatch for pinned benchmark model {model_id}: "
            f"expected {expected}, got {hashes}"
        )
    return {
        "resolved_revision": PINNED_MODEL_REVISIONS.get(model_id),
        "weight_sha256": hashes,
    }


def validate(case: Case, output: str, applied: bool) -> list[str]:
    failures: list[str] = []
    if not applied:
        failures.append("cleanup_not_applied")
    if case.romanize and is_mostly_non_latin(output):
        failures.append("romanization_kept_native_script")
    if not output.endswith(case.ending):
        failures.append(f"missing_ending:{case.ending}")
    lower = output.lower()
    outside_scope = lower
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
        outside_scope = "\n".join(
            line for line in output.splitlines()
            if not re.match(r"^(?:\d+[.)]|[-*])\s+", line.strip())
        ).lower()
    else:
        required_scope = lower
    for required in case.required:
        if required.lower() not in required_scope:
            failures.append(f"missing:{required}")
        elif case.numbered_items and required.lower() in outside_scope:
            failures.append(f"duplicate_outside_list:{required}")
    for forbidden in case.forbidden:
        if forbidden.lower() in lower:
            failures.append(f"forbidden:{forbidden}")
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
    for required in case.required_outside:
        if required.lower() not in outside_scope:
            failures.append(f"missing_outside:{required}")
        if required.lower() in required_scope:
            failures.append(f"unexpected_inside_list:{required}")
    return failures


def _percentile(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * percentile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _reduction_pct(baseline: float, candidate: float) -> float:
    if baseline <= 0:
        return 0.0
    return (baseline - candidate) / baseline * 100.0


def _physical_footprint(pid: int | None) -> dict[str, int | str]:
    """Read macOS physical footprint; RSS omits most MLX/Metal allocations."""
    if pid is None:
        return {"error": "worker_not_running"}
    try:
        completed = subprocess.run(
            ["/usr/bin/footprint", "-p", str(pid), "-f", "bytes", "--noCategories"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"error": str(exc)}
    current = re.search(r"phys_footprint:\s+(\d+)\s+B", completed.stdout)
    peak = re.search(r"phys_footprint_peak:\s+(\d+)\s+B", completed.stdout)
    if current is None or peak is None:
        return {"error": "unrecognized_footprint_output"}
    return {
        "current_bytes": int(current.group(1)),
        "peak_bytes": int(peak.group(1)),
    }


def evaluate_candidate(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    *,
    min_speedup_pct: float,
    min_memory_reduction_pct: float,
) -> dict[str, Any]:
    """Compare one sequential candidate with the first-model baseline."""
    failures: list[str] = []
    baseline_failed = set(baseline["failed_cases"])
    candidate_failed = set(candidate["failed_cases"])
    new_failures = sorted(candidate_failed - baseline_failed)
    if candidate_failed:
        failures.append("candidate_quality_failures:" + ",".join(sorted(candidate_failed)))
    if new_failures:
        failures.append("new_quality_failures:" + ",".join(new_failures))

    p50_speedup = _reduction_pct(
        float(baseline["p50_wall_ms"]), float(candidate["p50_wall_ms"])
    )
    p95_speedup = _reduction_pct(
        float(baseline["p95_wall_ms"]), float(candidate["p95_wall_ms"])
    )
    if p50_speedup < min_speedup_pct:
        failures.append(f"p50_speedup:{p50_speedup:.1f}<{min_speedup_pct:.1f}")
    if p95_speedup < min_speedup_pct:
        failures.append(f"p95_speedup:{p95_speedup:.1f}<{min_speedup_pct:.1f}")

    memory_reduction = _reduction_pct(
        float(baseline["mlx_inference"]["active_bytes"]),
        float(candidate["mlx_inference"]["active_bytes"]),
    )
    if memory_reduction < min_memory_reduction_pct:
        failures.append(
            f"active_memory_reduction:{memory_reduction:.1f}"
            f"<{min_memory_reduction_pct:.1f}"
        )
    return {
        "event": "comparison",
        "baseline": baseline["model"],
        "candidate": candidate["model"],
        "accepted": not failures,
        "p50_speedup_pct": round(p50_speedup, 1),
        "p95_speedup_pct": round(p95_speedup, 1),
        "active_memory_reduction_pct": round(memory_reduction, 1),
        "failures": failures,
    }


async def _run_model(
    model_id: str,
    config: Config,
    selected: set[str] | None,
    repeats: int,
) -> dict[str, Any]:
    resolved_model = resolve_benchmark_model(model_id)
    model_evidence = benchmark_model_evidence(model_id, resolved_model)
    engine = CleanupProcess(resolved_model)
    started = time.perf_counter()
    warm_prompt = (
        S1_MINI_SYSTEM_PROMPT
        if model_id == S1_MINI_MODEL_ID
        else STATIC_SYSTEM_PROMPT
    )
    await engine.load_async(warm_prompt)
    load_ms = int((time.perf_counter() - started) * 1000)
    after_load = await engine.memory_metrics(reset_peak=True)
    footprint_after_load = _physical_footprint(engine.pid)
    case_records: list[dict[str, Any]] = []
    try:
        for case in CASES:
            if selected and case.name not in selected:
                continue
            old_romanize = bool(config.data.get("romanize_output", False))
            config.data["romanize_output"] = case.romanize
            provisional = run_gate(
                case.raw,
                config,
                bundle_id=case.bundle_id,
                app_name=case.app_name,
                explicit_mode=case.explicit_mode,
            )
            mode_key = provisional.mode.name.lower()
            old_mode_prompt = config.modes[mode_key].prompt
            if case.mode_prompt is not None:
                config.modes[mode_key].prompt = case.mode_prompt
            try:
                gate = run_gate(
                    case.raw,
                    config,
                    bundle_id=case.bundle_id,
                    app_name=case.app_name,
                    explicit_mode=case.explicit_mode,
                )
                case_failures: set[str] = set()
                if not gate.use_llm:
                    case_failures.add(f"unexpected_gate:{gate.reason}")
                    outputs: list[str] = []
                    results = []
                else:
                    if (
                        case.required_prompt
                        and case.required_prompt not in (gate.system_prompt or "")
                    ):
                        case_failures.add(f"missing_prompt:{case.required_prompt}")
                    if model_id == S1_MINI_MODEL_ID:
                        request_prompt, request_text = s1_mini_prompt(case)
                        control = request_text.split("\n", 1)[0]
                        candidates = [
                            (request_prompt, control + "\ntranscript"),
                            (request_prompt, control + "\ndictation"),
                        ]
                    else:
                        request_prompt = gate.system_prompt or STATIC_SYSTEM_PROMPT
                        request_text = (
                            gate.text
                            if gate.romanize
                            else encode_breaks(gate.text)
                        )
                        candidates = build_prefill_prompt_candidates(
                            config,
                            bundle_id=case.bundle_id,
                            app_name=case.app_name,
                            explicit_mode=case.explicit_mode,
                            romanize=gate.romanize,
                        )
                    results = []
                    outputs = []
                    for _ in range(repeats):
                        result = await engine.cleanup(
                            request_text,
                            request_prompt,
                            timeout_ms=4000 if gate.romanize else None,
                            check_ratio=not gate.romanize,
                            allowed_terms=list(
                                dict.fromkeys(
                                    config.global_vocabulary + gate.mode.vocabulary
                                )
                            ),
                            prefix_candidates=candidates,
                        )
                        output = (
                            postprocess(result.text, gate)
                            if result.applied
                            else result.text
                        )
                        results.append(result)
                        outputs.append(output)
                        case_failures.update(validate(case, output, result.applied))
                        if not result.cache_hit and not gate.romanize:
                            case_failures.add("startup_cache_miss")
                record = {
                    "event": "case",
                    "case": case.name,
                    "words": len(case.raw.split()),
                    "model": model_id,
                    "repeats": repeats,
                    "prefix_tokens": max(
                        (result.prefix_tokens for result in results), default=0
                    ),
                    "cleanup_ms": round(
                        statistics.median(
                            [result.ms for result in results]
                        ) if results else 0,
                        1,
                    ),
                    "cleanup_wall_ms": round(
                        statistics.median(
                            [result.wall_ms for result in results]
                        ) if results else 0,
                        1,
                    ),
                    "ttft_ms": round(
                        statistics.median(
                            [result.ttft_ms for result in results]
                        ) if results else 0,
                        1,
                    ),
                    "decode_ms": round(
                        statistics.median(
                            [result.decode_ms for result in results]
                        ) if results else 0,
                        1,
                    ),
                    "cache_hit": bool(results) and all(
                        result.cache_hit for result in results
                    ),
                    "applied": bool(results) and all(
                        result.applied for result in results
                    ),
                    "cleanup_result_text": results[0].text if results else "",
                    "cleanup_reason": results[0].reason if results else None,
                    "unique_outputs": len(set(outputs)),
                    "output": outputs[0] if outputs else "",
                    "failures": sorted(case_failures),
                }
                case_records.append(record)
                print(json.dumps(record, ensure_ascii=False))
            finally:
                config.modes[mode_key].prompt = old_mode_prompt
                config.data["romanize_output"] = old_romanize
        inference_memory = await engine.memory_metrics()
        footprint_after_inference = _physical_footprint(engine.pid)
    finally:
        await engine.aclose()

    wall_times = [
        float(record["cleanup_wall_ms"])
        for record in case_records
        if not record["failures"] or record["cleanup_wall_ms"]
    ]
    ttft_times = [
        float(record["ttft_ms"])
        for record in case_records
        if not record["failures"] or record["ttft_ms"]
    ]
    summary = {
        "event": "summary",
        "model": model_id,
        **model_evidence,
        "cases": len(case_records),
        "failed_cases": [
            record["case"] for record in case_records if record["failures"]
        ],
        "load_ms": load_ms,
        "p50_wall_ms": round(statistics.median(wall_times), 1) if wall_times else 0.0,
        "p95_wall_ms": round(_percentile(wall_times, 0.95), 1),
        "p50_ttft_ms": round(statistics.median(ttft_times), 1) if ttft_times else 0.0,
        "p95_ttft_ms": round(_percentile(ttft_times, 0.95), 1),
        "mlx_after_load": asdict(after_load),
        "mlx_inference": asdict(inference_memory),
        "footprint_after_load": footprint_after_load,
        "footprint_after_inference": footprint_after_inference,
    }
    print(json.dumps(summary, ensure_ascii=False))
    return summary


async def run(
    model_ids: list[str],
    selected: set[str] | None,
    *,
    repeats: int,
    min_speedup_pct: float,
    min_memory_reduction_pct: float,
) -> int:
    with tempfile.TemporaryDirectory(prefix="velora-benchmark-") as home:
        os.environ["VELORA_HOME"] = home
        config = Config()
        summaries = [
            await _run_model(model_id, config, selected, repeats)
            for model_id in model_ids
        ]
    comparisons = [
        evaluate_candidate(
            summaries[0],
            candidate,
            min_speedup_pct=min_speedup_pct,
            min_memory_reduction_pct=min_memory_reduction_pct,
        )
        for candidate in summaries[1:]
    ]
    for comparison in comparisons:
        print(json.dumps(comparison, ensure_ascii=False))
    baseline_passed = not summaries[0]["failed_cases"]
    return 0 if baseline_passed and all(item["accepted"] for item in comparisons) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="print fixtures without loading MLX")
    parser.add_argument("--case", action="append", choices=[case.name for case in CASES])
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        help="repeat for candidates; the first model is the baseline",
    )
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--min-speedup-pct", type=float, default=10.0)
    parser.add_argument("--min-memory-reduction-pct", type=float, default=10.0)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    model_ids = args.models or [MODEL_ID]
    if args.list:
        print(json.dumps({
            "default_model": MODEL_ID,
            "models": model_ids,
            "cases": [asdict(case) for case in CASES],
        }, indent=2, ensure_ascii=False))
        return 0
    return asyncio.run(
        run(
            model_ids,
            set(args.case) if args.case else None,
            repeats=args.repeats,
            min_speedup_pct=args.min_speedup_pct,
            min_memory_reduction_pct=args.min_memory_reduction_pct,
        )
    )


if __name__ == "__main__":
    raise SystemExit(main())
