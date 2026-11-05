#!/usr/bin/env python3
"""Compare Phonon's pinned native refiner with Velora's public cleanup fixtures.

Run from engine/: uv run python scripts/benchmark_phonon_refiner.py \
    --engine /path/to/pe --model-dir /path/to/exact/local/snapshot

This is an isolated benchmark, not a production backend. It independently
implements the documented JSON-lines engine protocol; no Phonon Python code is
imported. Nothing is downloaded. Latencies measure one-shot cleanup, not the
post-key-release tail of Phonon's streaming pipeline. Unsupported Velora features
remain in the summary as failures. Physical footprint and RSS are separate OS
measurements: mmap-backed weights can be reclaimable and absent from footprint;
RSS includes shared/file-backed pages and is not a total memory requirement.
Summary percentiles use per-case median samples, matching the cleanup baseline,
and cover only the explicitly listed supported cases. Inherited PE_* tuning
variables are removed; only the explicit shader directory is supplied. The
summary fingerprints the executable and both shader sources. Exit 1 means
quality or coverage failures.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_cleanup_quality import (
    CASES, Case, _percentile, _physical_footprint, validate,
)

MODEL_ID = "Infatoshi/phonon-refiner-1.7b"
MODEL_REVISION = "2b0ab74bee7ab7cf364695bbe44f64ce4c47439e"
WEIGHT_SHA256 = {
    "phonon-refiner-1.7b-Q4_K_S-e4.gguf":
        "059e6e503c6c2ec50cb61a39bd0d556fb6d946bb58e965fb9ddb8b0176dfc6cd",
    "phonon-refiner-1.7b-dflash2-drafter.gguf":
        "56eccf7c9cb760231aee8bd6744e2144b4219987222fef770fe3970d143f5fd7",
}
METADATA_SHA256 = {
    "phonon_refiner.json": "42c7febd360d3d3a2d13179f382aa2872777e6af7f7e21ae61122d7181a24db3",
    "phonon_engine.json": "5aff5a55a6734846c61e4ce3966b2078c549419b01a6f395d08dca670058067e",
    "chat_template.jinja": "f45005c50cd2a97329722bf3a2dee9f16c04cdf825a589b280fb7e99e6827818",
    "tokenizer.json": "41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44",
    "tokenizer_config.json": "236f21425c08d31bfa5062767da6a3f1354ca0b89ac4138cfa9bdbb47a6700b2",
    "config.json": "82959de49f43ef3a185a82fa093caf4f91c2b62ad19a11d6043df7987af4bf38",
}
SYSTEM_PROMPT = (
    "Rewrite the raw dictation transcript into the exact text the speaker intended. "
    "Fix recognition errors and technical terms, keep the speaker's wording and casing style, "
    "do not add or drop content."
)
_CODE_APPS = {
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    "com.sublimetext.4", "com.microsoft.VSCode", "dev.zed.Zed",
    "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop",
}
_CASUAL_APPS = {
    "com.apple.MobileSMS", "com.hnc.Discord", "ru.keepcoder.Telegram",
    "net.whatsapp.WhatsApp",
}
_FORMAL_APPS = {
    "com.apple.mail", "com.microsoft.Outlook", "com.tinyspeck.slackmacgap",
    "com.microsoft.teams2", "com.readdle.SparkDesktop",
}


def writing_mode(case: Case) -> str:
    """Choose from observable app/mode context, never expected fixture output."""
    if case.explicit_mode:
        modes = {
            "default": "minimal", "note": "minimal", "email": "formal",
            "message": "casual", "code": "prompt", "terminal": "prompt",
        }
        return modes.get(case.explicit_mode.lower(), "unsupported")
    if case.bundle_id in _CODE_APPS:
        return "prompt"
    if case.bundle_id in _CASUAL_APPS:
        return "casual"
    if case.bundle_id in _FORMAL_APPS:
        return "formal"
    return "minimal"


def unsupported_reasons(case: Case) -> list[str]:
    reasons = []
    if case.mode_prompt:
        reasons.append("unsupported_custom_mode_prompt")
    if case.romanize:
        reasons.append("unsupported_romanization")
    if re.search(r"[\u0900-\u097f\u3400-\u9fff]", case.raw):
        reasons.append("unsupported_language_english_only")
    if writing_mode(case) == "unsupported":
        reasons.append("unsupported_explicit_mode")
    return reasons


def render_prompt(tokenizer: Any, case: Case, mode_lines: dict[str, str]) -> tuple[str, str]:
    mode = writing_mode(case)
    if mode not in mode_lines:
        raise ValueError(f"model has no writing mode {mode!r}")
    system = SYSTEM_PROMPT + "\n" + mode_lines[mode]
    messages = [{"role": "system", "content": system}, {"role": "user", "content": case.raw}]
    prompt = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True, enable_thinking=False,
    )
    # A second transcript identifies the exact stable prefix without relying on
    # model-specific separators or passing fixture expectations into inference.
    probe = tokenizer.apply_chat_template(
        [messages[0], {"role": "user", "content": "\x00VELORA_PREFIX_PROBE\x00"}],
        tokenize=False, add_generation_prompt=True, enable_thinking=False,
    )
    common = os.path.commonprefix([prompt, probe])
    return prompt, common


def model_file(model_dir: Path, name: str) -> Path:
    """Resolve declared files, including Hugging Face snapshot blob symlinks."""
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("model file must be relative to its snapshot")
    result = model_dir / path
    if not result.is_file():
        raise FileNotFoundError(result)
    return result


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def verify_weights(paths: list[Path]) -> dict[str, str]:
    hashes = {}
    for path in paths:
        actual = sha256(path)
        if WEIGHT_SHA256.get(path.name) != actual:
            raise ValueError(f"pinned weight checksum mismatch: {path.name}")
        hashes[path.name] = actual
    return hashes


def verify_metadata(model_dir: Path) -> dict[str, str]:
    """Pin mode lines, native file selection and the thinking-off template."""
    hashes = {}
    for name, expected in METADATA_SHA256.items():
        actual = sha256(model_file(model_dir, name))
        if actual != expected:
            raise ValueError(f"pinned metadata checksum mismatch: {name}")
        hashes[name] = actual
    return hashes


def native_environment(engine_path: Path) -> dict[str, str]:
    """Use the default kernel tuning with shaders beside the supplied binary."""
    inherited = {key: value for key, value in os.environ.items() if not key.startswith("PE_")}
    return {**inherited, "PE_DIR": str(engine_path.parent)}


def shader_evidence(engine_path: Path) -> dict[str, str]:
    """Fingerprint precisely the two sources selected by native_environment."""
    return {
        name: sha256(model_file(engine_path.parent, name))
        for name in ("mk.metal", "df.metal")
    }


def resident_memory(pid: int) -> dict[str, int | str]:
    """Read RSS in bytes; ps reports KiB, including reclaimable mapped pages."""
    try:
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            capture_output=True, text=True, check=True, timeout=5,
        )
        return {"current_bytes": int(result.stdout.strip()) * 1024}
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return {"error": str(exc)}


def timing_summary(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Weight each timed fixture equally, including its quality failures."""
    by_case: dict[str, list[float]] = {}
    for record in records:
        if record.get("supported") and "wall_ms" in record:
            by_case.setdefault(record["case"], []).append(record["wall_ms"])
    medians = {name: statistics.median(samples) for name, samples in by_case.items()}
    timings = list(medians.values())
    return {
        "timing_aggregation": "percentiles of per-case median wall_ms; supported cases only",
        "sampled_cases": len(medians), "sampled_case_names": list(medians),
        "case_median_wall_ms": medians,
        "p50_wall_ms": statistics.median(timings) if timings else None,
        "p95_wall_ms": _percentile(timings, 0.95) if timings else None,
    }


class NativeEngine:
    """Bounded, synchronous client for pe's public one-shot protocol."""

    def __init__(
        self, command: list[str], *, timeout: float = 120,
        env: dict[str, str] | None = None,
    ):
        self._replies: queue.Queue[str | None] = queue.Queue()
        self._stderr = tempfile.TemporaryFile(mode="w+t")
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self._stderr, text=True, bufsize=1, env=env,
        )
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        try:
            self.ready = self._reply(timeout)
            if self.ready.get("ready") is not True:
                raise RuntimeError(self._diagnostic("native engine did not report ready"))
        except BaseException:
            self.close()
            raise

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self._replies.put(line)
        self._replies.put(None)

    def _diagnostic(self, message: str) -> str:
        # pread leaves the child writer's shared file offset untouched. Limit
        # error output even if an engine dumps a large shader/compiler log.
        size = os.fstat(self._stderr.fileno()).st_size
        tail = os.pread(self._stderr.fileno(), min(size, 4096), max(0, size - 4096))
        return message + ("\nstderr tail:\n" + tail.decode("utf-8", errors="replace") if tail else "")

    def _reply(self, timeout: float) -> dict[str, Any]:
        try:
            line = self._replies.get(timeout=timeout)
        except queue.Empty as exc:
            raise TimeoutError(self._diagnostic("native engine reply timed out")) from exc
        if line is None:
            code = self.process.wait(timeout=3)
            raise RuntimeError(self._diagnostic(f"native engine exited: {code}"))
        try:
            reply = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(self._diagnostic("native engine returned invalid JSON")) from exc
        if not isinstance(reply, dict) or reply.get("ok") is False:
            raise RuntimeError(self._diagnostic(f"native engine rejected request: {str(reply)[:512]}"))
        return reply

    def call(self, request: dict[str, Any], *, timeout: float = 30) -> dict[str, Any]:
        assert self.process.stdin is not None
        try:
            self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            self.process.stdin.flush()
        except BrokenPipeError as exc:
            raise RuntimeError(self._diagnostic("native engine closed its input")) from exc
        return self._reply(timeout)

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self._reader.join(timeout=1)
        if self.process.stdin:
            self.process.stdin.close()
        if self.process.stdout:
            self.process.stdout.close()
        self._stderr.close()


def output_result(case: Case, reply: dict[str, Any], budget: int) -> tuple[str, list[str]]:
    text = reply.get("text")
    if not isinstance(text, str):
        raise ValueError("native engine returned no text")
    output = text.strip()
    failures: list[str] = []
    raw_words, out_words = len(case.raw.split()), len(output.split())
    if out_words > raw_words * 2 or (raw_words > 8 and out_words < raw_words * 0.4):
        output = case.raw
        failures.append("word_ratio_guard_fired")
    if int(reply.get("tokens", 0)) >= budget:
        failures.append("output_token_limit")
    if re.search(r"<\|[^>]+\|>|</?think>", output):
        failures.append("leaked_control_token")
    failures.extend(validate(case, output, applied=not failures))
    return output, failures


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, ensure_ascii=False), flush=True)


def run(engine_path: Path, model_dir: Path, cases: list[Case], repeats: int) -> int:
    from transformers import AutoTokenizer

    metadata_hashes = verify_metadata(model_dir)
    marker = json.loads((model_dir / "phonon_refiner.json").read_text())
    manifest = json.loads((model_dir / "phonon_engine.json").read_text())
    target = model_file(model_dir, manifest["target"])
    draft = model_file(model_dir, manifest["draft"])
    weight_hashes = verify_weights([target, draft])
    tokenizer_started = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(
        str(model_dir), local_files_only=True, trust_remote_code=False,
    )
    tokenizer_load_ms = (time.perf_counter() - tokenizer_started) * 1000
    command = [str(engine_path), str(target), "serve", "--draft", manifest["draft_kind"], str(draft)]
    environment = native_environment(engine_path)
    shader_hashes = shader_evidence(engine_path)
    started = time.perf_counter()
    # pe's implicit source path is above the executable; the standalone build
    # puts shaders beside it. Set this explicitly, as its app sidecar does.
    engine = NativeEngine(command, env=environment)
    load_ms = (time.perf_counter() - started) * 1000
    records: list[dict[str, Any]] = []
    failed: set[str] = set()
    footprint_load = _physical_footprint(engine.process.pid)
    rss_load = resident_memory(engine.process.pid)
    try:
        # Generic warm-up is excluded from latency/quality and carries no
        # reference answers. The first fixture does not bear cold shader work.
        warm = Case("warmup", "please send the report tomorrow")
        prompt, prefix = render_prompt(tokenizer, warm, marker["writing_modes"])
        engine.call({"prefix": prefix})
        engine.call({"prompt": prompt, "max_tokens": 48})
        for case in cases:
            unsupported = unsupported_reasons(case)
            if unsupported:
                failed.add(case.name)
                record = {"event": "case", "case": case.name, "supported": False,
                          "failures": unsupported, "mode": writing_mode(case)}
                records.append(record)
                emit(record)
                continue
            prompt, prefix = render_prompt(tokenizer, case, marker["writing_modes"])
            budget = max(8, min(2048, int(len(tokenizer.encode(case.raw, add_special_tokens=False)) * 1.5) + 32))
            engine.call({"prefix": prefix})
            for repeat in range(repeats):
                t0 = time.perf_counter()
                reply = engine.call({"prompt": prompt, "max_tokens": budget})
                wall_ms = (time.perf_counter() - t0) * 1000
                output, failures = output_result(case, reply, budget)
                if failures:
                    failed.add(case.name)
                record = {
                    "event": "case", "case": case.name, "repeat": repeat,
                    "supported": True, "mode": writing_mode(case), "output": output,
                    "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
                    "wall_ms": wall_ms, "engine_ms": reply.get("ms"),
                    "prompt_tokens": reply.get("prompt_tokens"), "output_tokens": reply.get("tokens"),
                    "drafted": reply.get("drafted"), "accepted": reply.get("accepted"),
                    "prefix_hit": reply.get("prefix_hit"), "failures": failures,
                }
                records.append(record)
                emit(record)
        footprint_final = _physical_footprint(engine.process.pid)
        rss_final = resident_memory(engine.process.pid)
    finally:
        engine.close()
    emit({
        "event": "summary", "model": MODEL_ID, "model_revision": MODEL_REVISION,
        "model_dir": str(model_dir), "engine": str(engine_path),
        "workload": "warm one-shot cleanup; no audio, streaming, or insertion",
        "thinking": False, "repeats": repeats, "cases": len(cases),
        "supported_cases": sum(not unsupported_reasons(case) for case in cases),
        "failed_cases": sorted(failed), "load_wall_ms": load_ms,
        "tokenizer_load_wall_ms": tokenizer_load_ms,
        "native_init_s": engine.ready.get("init_s"),
        **timing_summary(records),
        "footprint_after_load": footprint_load, "footprint_after_inference": footprint_final,
        "rss_after_load": rss_load, "rss_after_inference": rss_final,
        "revision_verified": model_dir.name == MODEL_REVISION,
        "weight_sha256": weight_hashes, "engine_sha256": sha256(engine_path),
        "metadata_sha256": metadata_hashes,
        "shader_sha256": shader_hashes,
        "engine_environment": {"PE_DIR": environment["PE_DIR"]},
        "inherited_PE_environment_removed": True,
        "native_weights_bytes": target.stat().st_size + draft.stat().st_size,
    })
    return int(bool(failed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--case", action="append", choices=[case.name for case in CASES])
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    if not args.engine.is_file():
        parser.error("--engine must be an existing pe binary")
    if not args.model_dir.is_dir():
        parser.error("--model-dir must be an existing local model snapshot")
    if args.model_dir.name != MODEL_REVISION:
        parser.error(f"--model-dir must name the pinned snapshot {MODEL_REVISION}")
    selected = [case for case in CASES if not args.case or case.name in args.case]
    with open("/tmp/velora-bench.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return run(args.engine.absolute(), args.model_dir.absolute(), selected, args.repeats)


if __name__ == "__main__":
    raise SystemExit(main())
