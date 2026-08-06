#!/usr/bin/env python3
"""Replay a private audio corpus through the installed Velora runtime safely.

The input manifest contains relative audio references from the local history
benchmark. Every reference is resolved beneath an explicit audio root before
the installed CLI is invoked. Transcript text is held only long enough to
compute its UTF-8 SHA-256 and character count; neither text nor audio paths are
printed or written to the result.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Mapping, Sequence


REQUIRED_STT_MODEL = "mlx-community/whisper-large-v3-turbo"
REQUIRED_CLEANUP_MODEL = "mlx-community/Qwen3.5-4B-MLX-8bit"
INSTALLED_CLI = Path("/Applications/Velora.app/Contents/Resources/bin/velora")
DEFAULT_ENGINE_CONFIG = Path.home() / ".velora" / "config.json"
_CASE_ID_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)


class BenchmarkError(Exception):
    """Expected, privacy-sanitized benchmark failure."""


class ModelRefusalError(BenchmarkError):
    """The live runtime cannot prove the exact required model pair."""


@dataclass(frozen=True)
class ReplayCase:
    """Validated private input plus public-safe case metadata."""

    case_id: str
    audio_path: Path
    mode: str
    duration_ms: int


def _safe_case_id(value: Any, index: int) -> str:
    if not isinstance(value, str):
        raise BenchmarkError(f"manifest case {index} has an invalid case ID")
    if not (1 <= len(value) <= 128) or any(char not in _CASE_ID_CHARS for char in value):
        raise BenchmarkError(f"manifest case {index} has an invalid case ID")
    return value


def _case_error(case_id: str, message: str) -> BenchmarkError:
    # Audio references are deliberately not accepted by this helper. Keeping
    # error construction case-ID-only prevents path disclosure on every branch.
    return BenchmarkError(f"manifest case {case_id}: {message}")


def _resolve_audio(case_id: str, value: Any, root: Path) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise _case_error(case_id, "audio reference is invalid")
    relative = Path(value)
    if relative.is_absolute():
        raise _case_error(case_id, "audio reference must be relative")
    try:
        candidate = (root / relative).resolve(strict=True)
        candidate.relative_to(root)
    except (FileNotFoundError, OSError, RuntimeError, ValueError):
        raise _case_error(case_id, "audio file is missing or outside the audio root") from None
    if not candidate.is_file():
        raise _case_error(case_id, "audio reference is not a regular file")
    return candidate


def _validated_mode(case_id: str, value: Any) -> str:
    if not isinstance(value, str):
        raise _case_error(case_id, "mode is invalid")
    mode = value.strip()
    if (
        not mode
        or len(mode) > 128
        or any(ord(char) < 32 or ord(char) == 127 for char in mode)
    ):
        raise _case_error(case_id, "mode is invalid")
    return mode


def _validated_duration(case_id: str, value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise _case_error(case_id, "duration_ms is invalid")
    return value


def load_manifest(manifest_path: Path, audio_root: Path) -> list[ReplayCase]:
    """Load Task 1's private manifest and confine every file to ``audio_root``."""
    try:
        root = audio_root.expanduser().resolve(strict=True)
    except (FileNotFoundError, OSError, RuntimeError):
        raise BenchmarkError("audio root is missing or inaccessible") from None
    if not root.is_dir():
        raise BenchmarkError("audio root is not a directory")
    try:
        payload = json.loads(manifest_path.expanduser().read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise BenchmarkError("manifest is missing or invalid JSON") from None
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise BenchmarkError("manifest schema_version must be 1")
    raw_cases = payload.get("cases")
    if not isinstance(raw_cases, list) or not raw_cases:
        raise BenchmarkError("manifest must contain at least one case")

    cases: list[ReplayCase] = []
    seen: set[str] = set()
    for index, item in enumerate(raw_cases, start=1):
        if not isinstance(item, dict):
            raise BenchmarkError(f"manifest case {index} is invalid")
        case_id = _safe_case_id(item.get("case_id"), index)
        if case_id in seen:
            raise _case_error(case_id, "case ID is duplicated")
        seen.add(case_id)
        cases.append(
            ReplayCase(
                case_id=case_id,
                audio_path=_resolve_audio(case_id, item.get("audio"), root),
                mode=_validated_mode(case_id, item.get("mode")),
                duration_ms=_validated_duration(case_id, item.get("duration_ms")),
            )
        )
    return cases


def read_installed_model_proof(
    *,
    config_path: Path,
    cli_path: Path,
    timeout_s: float = 5.0,
    command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, Any]:
    """Prove configured model IDs plus live installed-app/engine readiness.

    The engine protocol has one app-owned client, so a second raw socket
    connection is not a safe readiness surface. The public installed CLI status
    command is non-disruptive; model IDs come from the same read-only config
    file the engine loads.
    """
    if not math.isfinite(timeout_s) or timeout_s <= 0:
        raise ValueError("timeout_s must be positive")
    try:
        configured = json.loads(config_path.expanduser().read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ModelRefusalError(
            "installed model configuration is unavailable; model identity was not proven"
        ) from None
    if not isinstance(configured, dict):
        raise ModelRefusalError(
            "installed model configuration is invalid; model identity was not proven"
        )
    command = [str(cli_path), "status", "--json"]
    try:
        completed = command_runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired):
        raise ModelRefusalError(
            "installed runtime status is unavailable; model identity was not proven"
        ) from None
    if completed.returncode != 0:
        raise ModelRefusalError(
            "installed runtime status is unavailable; model identity was not proven"
        )
    try:
        live = json.loads(completed.stdout)
    except (TypeError, UnicodeError, json.JSONDecodeError):
        raise ModelRefusalError(
            "installed runtime returned invalid status; model identity was not proven"
        ) from None
    if not isinstance(live, dict):
        raise ModelRefusalError(
            "installed runtime returned invalid status; model identity was not proven"
        )
    return {
        "source": "installed_status_plus_readonly_config",
        "stt_model": configured.get("stt_model"),
        "cleanup_model": configured.get("cleanup_model"),
        "cleanup_enabled": configured.get("cleanup_enabled"),
        "app_running": live.get("app_running"),
        "engine_ready": live.get("engine_ready"),
        "access_enabled": live.get("access_enabled"),
        "transcribe_capable": (
            isinstance(live.get("capabilities"), list)
            and "transcribe" in live["capabilities"]
        ),
    }


def require_exact_models(status: Mapping[str, Any]) -> None:
    """Refuse unless the installed runtime is ready with the exact model pair."""
    exact = (
        status.get("source") == "installed_status_plus_readonly_config"
        and status.get("stt_model") == REQUIRED_STT_MODEL
        and status.get("cleanup_model") == REQUIRED_CLEANUP_MODEL
        and status.get("cleanup_enabled") is True
        and status.get("app_running") is True
        and status.get("engine_ready") is True
        and status.get("access_enabled") is True
        and status.get("transcribe_capable") is True
    )
    if not exact:
        raise ModelRefusalError(
            "installed engine refused: live runtime is not ready with the required model pair"
        )


def _optional_nonnegative_int(payload: Mapping[str, Any], key: str) -> int | None:
    value = payload.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BenchmarkError("installed CLI returned invalid timing metadata")
    integer = int(value)
    if integer < 0 or not math.isfinite(float(value)):
        raise BenchmarkError("installed CLI returned invalid timing metadata")
    return integer


def run_case(
    case: ReplayCase,
    *,
    repeat: int,
    cli_path: Path,
    timeout_s: float,
    command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    clock: Callable[[], float] = time.perf_counter,
) -> dict[str, Any]:
    """Transcribe once, retaining an allow-list of text-free result metadata."""
    command = [
        str(cli_path),
        "transcribe",
        str(case.audio_path),
        "--mode",
        case.mode,
        "--json",
    ]
    started = clock()
    try:
        completed = command_runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        raise BenchmarkError(f"case {case.case_id} repeat {repeat} timed out") from None
    except (OSError, ValueError):
        raise BenchmarkError(
            f"case {case.case_id} repeat {repeat} could not start the installed CLI"
        ) from None
    wall_ms = max(0, round((clock() - started) * 1_000))
    if completed.returncode != 0:
        raise BenchmarkError(
            f"case {case.case_id} repeat {repeat} failed with CLI exit {completed.returncode}"
        )
    try:
        payload = json.loads(completed.stdout)
    except (TypeError, UnicodeError, json.JSONDecodeError):
        raise BenchmarkError(
            f"case {case.case_id} repeat {repeat} returned invalid JSON"
        ) from None
    if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
        raise BenchmarkError(
            f"case {case.case_id} repeat {repeat} returned invalid JSON metadata"
        )

    # This is the only point where transcript text exists in this process. It is
    # never interpolated into an error, printed, returned, or written.
    text = payload["text"]
    result: dict[str, Any] = {
        "repeat": repeat,
        "wall_ms": wall_ms,
        # Despite its CLI name, current server.py starts this timer before file
        # decoding and stops it after explicit-mode cleanup. Do not call it STT.
        "engine_total_inference_ms": _optional_nonnegative_int(payload, "stt_ms"),
        "character_count": len(text),
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
    }
    # Newer installed CLIs may expose this phase. The current CLI does not, so
    # absence is honest missingness rather than a fabricated zero.
    if "cleanup_ms" in payload:
        result["cleanup_generation_ms"] = _optional_nonnegative_int(
            payload, "cleanup_ms"
        )
    return result


def _quantile(values: Sequence[int | float], probability: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * probability
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _compact(value: float | None) -> int | float | None:
    if value is None:
        return None
    rounded = round(value, 3)
    return int(rounded) if rounded.is_integer() else rounded


def summarize(values: Sequence[int | float | None]) -> dict[str, Any]:
    available = [float(value) for value in values if value is not None]
    if not available:
        return {
            "available": 0,
            "missing": len(values),
            "min": None,
            "p50": None,
            "p95": None,
            "max": None,
            "mean": None,
        }
    return {
        "available": len(available),
        "missing": len(values) - len(available),
        "min": _compact(min(available)),
        "p50": _compact(_quantile(available, 0.50)),
        "p95": _compact(_quantile(available, 0.95)),
        "max": _compact(max(available)),
        "mean": _compact(sum(available) / len(available)),
    }


def _metric_summary(runs: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    keys = ("wall_ms", "engine_total_inference_ms", "cleanup_generation_ms")
    return {
        key: summarize([run.get(key) for run in runs])
        for key in keys
        if key != "cleanup_generation_ms" or any(key in run for run in runs)
    }


def build_report(
    cases: Sequence[ReplayCase],
    runs_by_case: Mapping[str, Sequence[dict[str, Any]]],
    *,
    repeats: int,
    status: Mapping[str, Any],
) -> dict[str, Any]:
    """Project private inputs and in-memory CLI results onto a strict allow-list."""
    report_cases: list[dict[str, Any]] = []
    all_runs: list[dict[str, Any]] = []
    for case in cases:
        runs = list(runs_by_case.get(case.case_id, ()))
        all_runs.extend(runs)
        hashes = {run["text_sha256"] for run in runs}
        report_cases.append(
            {
                "case_id": case.case_id,
                "duration_ms": case.duration_ms,
                "mode": case.mode,
                "runs": runs,
                "metrics": _metric_summary(runs),
                "output_consistency": {
                    "distinct_sha256": len(hashes),
                    "all_repeats_equal": len(hashes) <= 1,
                },
            }
        )
    return {
        "schema_version": 1,
        "privacy": {
            "transcript_text_included": False,
            "audio_paths_included": False,
            "transcript_handling": "sha256_utf8_in_memory_only",
        },
        "model_proof": {
            "source": status["source"],
            "stt_model": status["stt_model"],
            "cleanup_model": status["cleanup_model"],
            "cleanup_enabled": status["cleanup_enabled"],
            "app_running": status["app_running"],
            "engine_ready": status["engine_ready"],
            "access_enabled": status["access_enabled"],
            "transcribe_capable": status["transcribe_capable"],
        },
        "metric_semantics": {
            "wall_ms": "installed CLI subprocess wall time",
            "engine_total_inference_ms": (
                "CLI stt_ms is total file inference through cleanup in the current "
                "server; it is not STT-only"
            ),
            "cleanup_generation_ms": (
                "server cleanup generation time when exposed; unavailable from the "
                "current installed CLI"
            ),
        },
        "repeats": repeats,
        "cases": report_cases,
        "aggregate": _metric_summary(all_runs),
    }


def write_private_json(path: Path, payload: Mapping[str, Any]) -> None:
    """Atomically write JSON with mode 0600, including replacement outputs."""
    destination = path.expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as handle:
            temporary = handle.name
            os.chmod(temporary, 0o600)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        temporary = None
        os.chmod(destination, 0o600)
    finally:
        if temporary is not None:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)


def _output_is_unsafe(output_path: Path, manifest_path: Path, cases: Sequence[ReplayCase]) -> bool:
    output = output_path.expanduser().resolve(strict=False)
    if output == manifest_path.expanduser().resolve(strict=False):
        return True
    return any(output == case.audio_path for case in cases)


def run_benchmark(
    *,
    manifest_path: Path,
    audio_root: Path,
    output_path: Path,
    repeats: int,
    timeout_s: float,
    status_provider: Callable[[], Mapping[str, Any]],
    cli_path: Path = INSTALLED_CLI,
    command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    clock: Callable[[], float] = time.perf_counter,
) -> dict[str, Any]:
    """Validate, prove models, run all controlled repeats, and write once."""
    if isinstance(repeats, bool) or repeats < 1:
        raise BenchmarkError("repeats must be at least one")
    if not math.isfinite(timeout_s) or timeout_s <= 0:
        raise BenchmarkError("timeout must be positive")
    cases = load_manifest(manifest_path, audio_root)
    if _output_is_unsafe(output_path, manifest_path, cases):
        raise BenchmarkError("JSON output must not overwrite an input")
    try:
        status = status_provider()
    except BenchmarkError:
        raise
    except Exception:
        raise ModelRefusalError(
            "live engine status is unavailable; model identity was not proven"
        ) from None
    require_exact_models(status)
    if not cli_path.is_file():
        raise BenchmarkError("installed Velora CLI is unavailable")

    runs_by_case: dict[str, list[dict[str, Any]]] = {
        case.case_id: [] for case in cases
    }
    # Repeat outermost so each corpus pass experiences the same ordering and a
    # single long case is not run back-to-back before every other case warms.
    for repeat in range(1, repeats + 1):
        for case in cases:
            runs_by_case[case.case_id].append(
                run_case(
                    case,
                    repeat=repeat,
                    cli_path=cli_path,
                    timeout_s=timeout_s,
                    command_runner=command_runner,
                    clock=clock,
                )
            )
    report = build_report(cases, runs_by_case, repeats=repeats, status=status)
    write_private_json(output_path, report)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--json", "--output", dest="output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=420.0, help="seconds per CLI replay")
    parser.add_argument(
        "--status-timeout", type=float, default=5.0, help="seconds for installed status/model proof"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = run_benchmark(
            manifest_path=args.manifest,
            audio_root=args.audio_root,
            output_path=args.output,
            repeats=args.repeats,
            timeout_s=args.timeout,
            status_provider=lambda: read_installed_model_proof(
                config_path=DEFAULT_ENGINE_CONFIG,
                cli_path=INSTALLED_CLI,
                timeout_s=args.status_timeout,
            ),
        )
    except BenchmarkError as exc:
        print(f"benchmark refused: {exc}", file=sys.stderr)
        return 1
    print(
        f"benchmark complete: {len(report['cases'])} cases x {report['repeats']} repeats; "
        "owner-only JSON written"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
