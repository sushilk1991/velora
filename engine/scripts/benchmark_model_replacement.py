#!/usr/bin/env python3
"""Public-only replacement study; production worker, raw timings and host gates.

Uses an immutable local snapshot and an isolated VELORA_HOME. Run under Baton.
The model ID preserves production copy-draft/allocator policy independently of
the filesystem path. No installed app, history, or owner corpus is accessed.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
from dataclasses import asdict
import hashlib
from importlib.metadata import version
import json
import math
import os
from pathlib import Path
import re
import resource
import struct
import subprocess
import sys
import tempfile
import threading
import time

import benchmark_cleanup_quality as quality
from benchmark_cleanup_resources import benchmark_lock
from velora_engine.cleanup_process import CleanupProcess
from velora_engine.config import Config


def emit(path: Path, record: dict) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + "\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def runtime_versions() -> dict:
    return {name: version(name) for name in ("mlx", "mlx-lm", "transformers")}


def model_evidence(root: Path) -> dict:
    """Count logical parameters from packed shapes, excluding quant metadata.

    Full artifact includes any unused vision weights. Text parameters exclude
    those weights because MLX-LM sanitizes them out on load. Both are reported.
    """
    config = json.loads((root / "config.json").read_text())
    quantization = config.get("quantization", {})
    group = quantization.get("group_size", 64)
    parameters = text_parameters = tied_duplicate_parameters = 0
    header = {}
    for path in sorted(root.glob("*.safetensors")):
        with path.open("rb") as stream:
            shard = json.loads(stream.read(struct.unpack("<Q", stream.read(8))[0]))
        for name, tensor in shard.items():
            if name == "__metadata__":
                continue
            if name in header:
                raise ValueError(f"duplicate tensor {name}")
            header[name] = tensor
    if not header:
        raise ValueError("no model tensors")
    text_prefix = ("language_model." if any(k.startswith("language_model.model.") for k in header)
                   else "model.language_model." if any(k.startswith("model.language_model.") for k in header)
                   else "model.")
    for name, tensor in header.items():
        if name.endswith((".scales", ".biases")):
            continue
        shape = tensor["shape"]
        module = name.removesuffix(".weight")
        scale = header.get(module + ".scales")
        if tensor["dtype"] == "U32":
            if not scale:
                raise ValueError(f"packed tensor lacks scales: {name}")
            module_group = quantization.get(module, {}).get("group_size", group)
            count = math.prod(scale["shape"]) * module_group
        else:
            count = math.prod(shape)
        parameters += count
        if (name.startswith(text_prefix) or name == "lm_head.weight") and not any(
                part in name for part in ("vision", "visual", "mtp")):
            text = config.get("text_config", config)
            if text.get("tie_word_embeddings", config.get("tie_word_embeddings")) and name.endswith("lm_head.weight"):
                tied_duplicate_parameters += count
            else:
                text_parameters += count
    files = {str(p.relative_to(root)): {"bytes": p.stat().st_size, "sha256": sha256(p)}
             for p in sorted(root.rglob("*")) if p.is_file()}
    return {"path": str(root), "snapshot": root.name, "files": files,
            "artifact_bytes": sum(f["bytes"] for f in files.values()),
            "weight_bytes": sum(f["bytes"] for name, f in files.items()
                                if name.endswith(".safetensors")),
            "logical_parameters_all_tensors": parameters,
            "logical_parameters_text": text_parameters,
            "tied_duplicate_parameters": tied_duplicate_parameters,
            "quantization": config.get("quantization")}


def host_snapshot() -> dict:
    vm = subprocess.check_output(["/usr/bin/vm_stat"], text=True, timeout=3)
    swap = subprocess.check_output(["/usr/sbin/sysctl", "-n", "vm.swapusage"], text=True, timeout=3)
    pressure = subprocess.check_output(
        ["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True, timeout=3)
    return {"time_ns": time.time_ns(), "load1": os.getloadavg()[0],
            "swapouts": int(re.search(r"Swapouts:\s+(\d+)", vm)[1]),
            "swap_used_mb": float(re.search(r"used = ([\d.]+)M", swap)[1]),
            "pressure": int(pressure)}


def percentiles(values: list[float]) -> dict:
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("missing or invalid latency samples")
    return {f"p{p}": quality._percentile(values, p / 100) for p in (50, 95, 99)}


def contamination(samples: list[dict]) -> list[str]:
    if not samples:
        return ["missing_host_telemetry"]
    failures = []
    if max(s["load1"] for s in samples) >= 20:
        failures.append("host_load1_ge_20")
    if max(s["pressure"] for s in samples) >= 2:
        failures.append("host_memory_pressure")
    if max(s["swapouts"] for s in samples) > samples[0]["swapouts"]:
        failures.append("host_swapouts")
    if max(s["swap_used_mb"] for s in samples) > samples[0]["swap_used_mb"]:
        failures.append("host_swap_used_growth")
    return failures


def worker(telemetry: Path, prompt_style: str, cache_limit_mb: int | None,
           copy_draft: bool, remaining: list[str]) -> None:
    from velora_engine import cleanup, cleanup_worker
    old_load = cleanup.CleanupEngine.load
    old_memory = cleanup.CleanupEngine._memory_metrics

    def load(self, *args, **kwargs):
        if cache_limit_mb is not None:
            cleanup.ALLOCATOR_CACHE_LIMITS[self.model_id] = cache_limit_mb * 1024 * 1024
        if copy_draft:
            cleanup.COPY_DRAFT_MODELS = cleanup.COPY_DRAFT_MODELS | {self.model_id}
        result = old_load(self, *args, **kwargs)
        if prompt_style == "muesli":
            # Card requires end-of-turn; config.json declares end-of-text.
            # Override in memory only, leaving the immutable snapshot intact.
            self._tokenizer.add_eos_token("<|im_end|>")
        return result

    def memory(self, reset_peak):
        result = old_memory(self, reset_peak)
        # On Darwin ru_maxrss is bytes and is a kernel lifetime high-water mark.
        emit(telemetry, {"event": "worker_memory", "pid": os.getpid(),
                         "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                         "mlx": asdict(result)})
        return result

    if prompt_style == "muesli":
        # Pinned card explicitly forbids a chat-template engine; this snapshot
        # deliberately has no chat_template. Preserve its exact training bytes.
        def tokens(self, system, text):
            return muesli_tokens(self._tokenizer, system,
                                 cleanup.neutralize_control_tokens(text))
        cleanup.CleanupEngine._prompt_tokens = tokens
    cleanup.CleanupEngine.load = load
    cleanup.CleanupEngine._memory_metrics = memory
    sys.argv = [sys.argv[0], *remaining]
    cleanup_worker.main()


MUESLI_PROMPT = (
    "Clean up speech-to-text transcription. Only make changes when there is a clear error. "
    "If the text is already correct, output it exactly as-is.\n\n"
    "The user input may include an <APP-CONTEXT> section with focused app, document, URL, "
    "selected text, or OCR screen text. Use it only to resolve obvious transcription errors, "
    "names, acronyms, and formatting intent. Never copy app context into the output unless "
    "the user dictated it.\n\n"
    "You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' "
    "deletions, and format numbered or bullet lists when dictated.\n\n"
    "Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any "
    "way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat "
    "the output more than once. Preserve the speaker's original phrasing."
)


def muesli_tokens(tokenizer, system: str, text: str) -> list[int]:
    user = system + "\n\n" + text
    raw = ("<|im_start|>user\n" + user + "<|im_end|>\n"
           "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    return list(tokenizer.encode(raw, add_special_tokens=False))


async def run(args) -> int:
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = args.model_path.expanduser().resolve()
    if root.parent.parent.name.startswith("models--"):
        cached_identity = root.parent.parent.name.removeprefix("models--").replace("--", "/", 1)
        if cached_identity != args.model_id:
            raise ValueError(f"model ID {args.model_id} does not match cache {cached_identity}")
    source_hashes = {p.name: sha256(p) for p in (
        Path(__file__), Path(quality.__file__),
        *(Path(__file__).parents[1] / "src/velora_engine" / name
          for name in ("cleanup.py", "formatting.py", "cleanup_process.py", "cleanup_worker.py")))}
    samples: list[dict] = []
    stopped = threading.Event()
    monitor_errors: list[str] = []

    def sample():
        try:
            snapshot = host_snapshot()
            samples.append(snapshot)
            emit(out / "host.jsonl", snapshot)
        except Exception as exc:
            monitor_errors.append(repr(exc))

    def monitor():
        while not stopped.wait(1):
            sample()

    sample()
    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    try:
        evidence = model_evidence(root)
        (out / "model.json").write_text(json.dumps(evidence, indent=2) + "\n")
    except BaseException:
        stopped.set()
        thread.join(timeout=5)
        raise
    requests: list[dict] = []
    active: set[CleanupProcess] = set()
    old_process = quality.CleanupProcess
    old_resolver = quality.resolve_benchmark_model
    old_evidence = quality.benchmark_model_evidence
    old_home = os.environ.get("VELORA_HOME")
    command = [sys.executable, str(Path(__file__).resolve()), "--worker",
               "--telemetry", str(out / "worker.jsonl"), "--prompt-style", args.prompt_style]
    if args.cache_limit_mb is not None:
        command += ["--cache-limit-mb", str(args.cache_limit_mb)]
    if args.copy_draft:
        command += ["--copy-draft"]

    class MeasuredProcess(CleanupProcess):
        def __init__(self, source):
            super().__init__(args.model_id, local_model_path=source, worker_command=command)
            active.add(self)

        async def load_async(self, warm_system_prompt=None):
            await super().load_async(MUESLI_PROMPT if args.prompt_style == "muesli"
                                     else "Clean up this dictation." if args.prompt_style == "vedu"
                                     else warm_system_prompt)

        async def cleanup(self, text, system_prompt, **kwargs):
            # Production requests copy drafts; the child's model allowlist
            # still decides whether that optimization is qualified for it.
            kwargs.setdefault("copy_draft", kwargs.get("check_ratio", True))
            if args.prompt_style == "muesli":
                # Keep raw workload and production output guards; do not invent
                # unsupported controls for an English-only trained specialist.
                case = quality.CASES[len(requests) // args.repeats]
                system_prompt = MUESLI_PROMPT
                kwargs["prefix_candidates"] = [(MUESLI_PROMPT, "transcript"),
                                                (MUESLI_PROMPT, "dictation")]
            elif args.prompt_style == "vedu":
                case = quality.CASES[len(requests) // args.repeats]
                system_prompt = "Clean up this dictation."
                kind = "email" if "mail" in case.bundle_id.lower() else "notes"
                control = f"[format: {kind}] [tone: formal]\n"
                text = control + text
                kwargs["prefix_candidates"] = [(system_prompt, control + "transcript"),
                                                (system_prompt, control + "dictation")]
            started = time.perf_counter_ns()
            result = await super().cleanup(text, system_prompt, **kwargs)
            record = {"event": "request", "index": len(requests),
                      "case": quality.CASES[len(requests) // args.repeats].name,
                      "duration_ms": (time.perf_counter_ns() - started) / 1e6,
                      "load1": os.getloadavg()[0], "worker_pid": self.pid,
                      "prompt_sha256": hashlib.sha256(system_prompt.encode()).hexdigest(),
                      "input_sha256": hashlib.sha256(text.encode()).hexdigest(),
                      "copy_draft_requested": kwargs["copy_draft"], **asdict(result)}
            requests.append(record)
            emit(out / "requests.jsonl", record)
            return result

    summary = None
    error = None
    try:
        with tempfile.TemporaryDirectory(prefix="velora-replacement-") as home:
            os.environ["VELORA_HOME"] = home
            quality.CleanupProcess = MeasuredProcess
            quality.resolve_benchmark_model = lambda _: str(root)
            def pinned_evidence(identity, source):
                data = old_evidence(identity, source)
                # A local snapshot can share weights with a different Hub
                # revision. Record the actual config/tokenizer revision.
                return {**data, "resolved_revision": root.name}
            quality.benchmark_model_evidence = pinned_evidence
            with (out / "quality.jsonl").open("w") as stream, contextlib.redirect_stdout(stream):
                summary = await quality._run_model(args.model_id, Config(), None, args.repeats)
    except Exception as exc:
        error = repr(exc)
    finally:
        for engine in active:
            try:
                await engine.aclose()
            except Exception as exc:
                error = error or f"worker close failed: {exc!r}"
        from velora_engine.cleanup_process import _retired_workers
        if any(p.returncode is None for p in _retired_workers):
            error = error or "retired worker still alive"
        quality.CleanupProcess = old_process
        quality.resolve_benchmark_model = old_resolver
        quality.benchmark_model_evidence = old_evidence
        if old_home is None:
            os.environ.pop("VELORA_HOME", None)
        else:
            os.environ["VELORA_HOME"] = old_home
        stopped.set()
        thread.join(timeout=10)
        sample()
    rows = [json.loads(line) for line in (out / "worker.jsonl").read_text().splitlines()] \
        if (out / "worker.jsonl").exists() else []
    reasons = contamination(samples)
    if any(str(r.get("reason") or "").startswith(("error", "timeout", "llm_", "worker_"))
           or r.get("reason") in {"unavailable", "cancelled"} for r in requests):
        reasons.append("inference_failure")
    if thread.is_alive():
        monitor_errors.append("host monitor did not stop")
    if any(b["time_ns"] - a["time_ns"] > 5_000_000_000
           for a, b in zip(samples, samples[1:])):
        monitor_errors.append("host telemetry gap exceeded 5 seconds")
    if monitor_errors:
        reasons.append("host_monitor_errors")
    if error or len(requests) != len(quality.CASES) * args.repeats:
        reasons.append("incomplete_run")
    result = {"model_id": args.model_id, "prompt_style": args.prompt_style,
              "model_snapshot": root.name, "command": [sys.executable, *sys.argv],
              "source_sha256": source_hashes,
              "copy_draft_requested": True, "copy_draft_allowlist_override": args.copy_draft,
              "cache_limit_mb_override": args.cache_limit_mb,
              "expected_cases": [c.name for c in quality.CASES],
              "started_ns": samples[0]["time_ns"], "ended_ns": samples[-1]["time_ns"],
              "worker_pids": sorted({r["pid"] for r in rows}),
              "repeats": args.repeats, "requests": len(requests), "error": error,
              "percentiles_wall_ms": percentiles([r["duration_ms"] for r in requests])
              if requests else None,
              "peak_rss_bytes": max((r["peak_rss_bytes"] for r in rows), default=None),
              "summary": summary, "contamination": reasons,
              "host_monitor_errors": monitor_errors,
              "runtime": runtime_versions()}
    (out / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return int(bool(reasons))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--telemetry", type=Path)
    parser.add_argument("--model-id")
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--prompt-style", choices=("production", "muesli", "vedu"), default="production")
    parser.add_argument("--cache-limit-mb", type=int)
    parser.add_argument("--copy-draft", action="store_true")
    args, remaining = parser.parse_known_args()
    if args.worker:
        worker(args.telemetry, args.prompt_style, args.cache_limit_mb, args.copy_draft, remaining)
        return 0
    if remaining or not args.model_id or not args.model_path or not args.output:
        parser.error("require --model-id, --model-path, --output and no unknown arguments")
    if sys.platform != "darwin":
        parser.error("inference measurement requires the Apple Silicon macOS target")
    if args.repeats < 1 or (args.cache_limit_mb is not None and args.cache_limit_mb < 0):
        parser.error("invalid repeats/cache limit")
    with benchmark_lock():
        return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
