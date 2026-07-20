#!/usr/bin/env python3
"""Compare Velora's MLX baseline with transcribe.cpp Q8.

The command-line runner is intentionally strict: its default gate needs at
least 18 referenced, local clips spanning Indian English, Hindi, Hinglish,
silence, and a long dictation. It prints metrics, never transcript text.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import time
import unicodedata

import numpy as np

from velora_engine.config import DEFAULT_STT_MODEL
from velora_engine.models import (
    TRANSCRIBE_CPP_Q8_MODEL,
    TRANSCRIBE_CPP_Q8_REVISION,
    TRANSCRIBE_CPP_Q8_SHA256,
)
from velora_engine.stt import (
    SAMPLE_RATE,
    TranscribeCppWhisperBackend,
    WhisperBackend,
    _trim_repeated_tail,
    build_glossary_prompt,
)


@dataclass(frozen=True)
class BenchmarkCase:
    name: str
    path: Path
    reference: str
    cohort: str
    glossary: tuple[str, ...]


@dataclass(frozen=True)
class CaseResult:
    name: str
    cohort: str
    reference_words: int
    baseline_errors: int
    candidate_errors: int
    baseline_glossary: tuple[int, int]
    candidate_glossary: tuple[int, int]
    baseline_ms: float
    candidate_ms: float
    baseline_failure: bool
    candidate_failure: bool
    baseline_ingest_rtf: float = 0.0
    candidate_ingest_rtf: float = 0.0


@dataclass(frozen=True)
class Verdict:
    accepted: bool
    failures: tuple[str, ...]
    p50_speedup_pct: float
    p95_speedup_pct: float


def validate_coverage(
    cases: list[BenchmarkCase],
    durations_s: list[float],
    *,
    min_cases: int = 18,
) -> list[str]:
    failures: list[str] = []
    if len(cases) < min_cases:
        failures.append(f"insufficient_cases:{len(cases)}<{min_cases}")
    required = {"indian_english", "hindi", "hinglish"}
    missing = sorted(required - {case.cohort for case in cases})
    if missing:
        failures.append("missing_cohorts:" + ",".join(missing))
    if not any(not case.reference.strip() for case in cases):
        failures.append("missing_silence_or_noise_case")
    if not any(duration >= 45.0 for duration in durations_s):
        failures.append("missing_long_case:need_at_least_45s")
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


def _speedup(baseline_ms: float, candidate_ms: float) -> float:
    if baseline_ms <= 0:
        return 0.0
    return (baseline_ms - candidate_ms) / baseline_ms * 100.0


def evaluate(
    results: list[CaseResult], *, min_speedup_pct: float = 10.0
) -> Verdict:
    """Apply the adoption gate to already-measured per-case results."""
    if not results:
        return Verdict(False, ("no_cases",), 0.0, 0.0)

    baseline = [result.baseline_ms for result in results]
    candidate = [result.candidate_ms for result in results]
    p50_speedup = _speedup(statistics.median(baseline), statistics.median(candidate))
    p95_speedup = _speedup(_percentile(baseline, 0.95), _percentile(candidate, 0.95))
    failures: list[str] = []
    if p50_speedup < min_speedup_pct:
        failures.append(f"p50_speedup:{p50_speedup:.1f}<{min_speedup_pct:.1f}")
    if p95_speedup < min_speedup_pct:
        failures.append(f"p95_speedup:{p95_speedup:.1f}<{min_speedup_pct:.1f}")
    candidate_ingest_rtf = max(result.candidate_ingest_rtf for result in results)
    if candidate_ingest_rtf > 0.9:
        failures.append(f"candidate_ingest_rtf:{candidate_ingest_rtf:.3f}>0.900")

    cohorts = sorted({result.cohort for result in results})
    for cohort in cohorts:
        rows = [result for result in results if result.cohort == cohort]
        baseline_errors = sum(result.baseline_errors for result in rows)
        candidate_errors = sum(result.candidate_errors for result in rows)
        if candidate_errors > baseline_errors:
            failures.append(
                f"quality_regression:{cohort}:{candidate_errors}>{baseline_errors}"
            )

    baseline_hits = sum(result.baseline_glossary[0] for result in results)
    baseline_terms = sum(result.baseline_glossary[1] for result in results)
    candidate_hits = sum(result.candidate_glossary[0] for result in results)
    candidate_terms = sum(result.candidate_glossary[1] for result in results)
    baseline_recall = baseline_hits / baseline_terms if baseline_terms else 1.0
    candidate_recall = candidate_hits / candidate_terms if candidate_terms else 1.0
    if candidate_recall < baseline_recall:
        failures.append(
            f"glossary_regression:{candidate_recall:.3f}<{baseline_recall:.3f}"
        )

    new_failures = sum(
        result.candidate_failure and not result.baseline_failure for result in results
    )
    if new_failures:
        failures.append(f"new_guard_or_stitch_failures:{new_failures}")
    return Verdict(not failures, tuple(failures), p50_speedup, p95_speedup)


def _words(text: str) -> list[str]:
    normalized: list[str] = []
    for char in unicodedata.normalize("NFKC", text).casefold():
        category = unicodedata.category(char)
        normalized.append(char if category[0] in {"L", "M", "N"} else " ")
    return "".join(normalized).split()


def _edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, start=1):
        current = [row]
        for column, actual in enumerate(hypothesis, start=1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (expected != actual),
            ))
        previous = current
    return previous[-1]


def _glossary_score(text: str, glossary: tuple[str, ...]) -> tuple[int, int]:
    transcript = _words(text)
    hits = 0
    for term in glossary:
        term_words = _words(term)
        if term_words and any(
            transcript[index : index + len(term_words)] == term_words
            for index in range(len(transcript) - len(term_words) + 1)
        ):
            hits += 1
    return hits, len(glossary)


def _transcript_failure(reference: str, transcript: str) -> bool:
    reference_has_words = bool(_words(reference))
    transcript_has_words = bool(_words(transcript))
    if reference_has_words != transcript_has_words:
        return True
    return _trim_repeated_tail(transcript) != transcript


def _load_manifest(path: Path) -> list[BenchmarkCase]:
    payload = json.loads(path.read_text())
    rows = payload.get("cases") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("manifest must be a list or an object with a 'cases' list")
    cases: list[BenchmarkCase] = []
    seen: set[str] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"case {index} is not an object")
        name = str(row.get("name") or f"case-{index + 1}").strip()
        if name in seen:
            raise ValueError(f"duplicate case name: {name}")
        seen.add(name)
        audio_value = row.get("audio")
        reference = row.get("reference")
        cohort = str(row.get("cohort") or "").strip()
        if not isinstance(audio_value, str) or not isinstance(reference, str) or not cohort:
            raise ValueError(f"case {name}: audio, reference, and cohort are required")
        audio_path = (path.parent / audio_value).resolve()
        if not audio_path.is_file():
            raise ValueError(f"case {name}: audio file not found: {audio_path}")
        glossary = row.get("glossary") or []
        if (
            not isinstance(glossary, list)
            or not all(isinstance(term, str) and term.strip() for term in glossary)
        ):
            raise ValueError(f"case {name}: glossary must be a string list")
        cases.append(BenchmarkCase(name, audio_path, reference, cohort, tuple(glossary)))
    return cases


def _load_audio(path: Path) -> np.ndarray:
    import soundfile as sf

    audio, sample_rate = sf.read(str(path), dtype="float32", always_2d=False)
    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"{path}: expected {SAMPLE_RATE} Hz, got {sample_rate}")
    if audio.ndim == 2:
        audio = audio.mean(axis=1)
    if audio.ndim != 1:
        raise ValueError(f"{path}: expected mono audio")
    return np.ascontiguousarray(audio, dtype=np.float32)


def _decode_live(
    backend, audio: np.ndarray, glossary: tuple[str, ...]
) -> tuple[str, float, float]:
    backend.initial_prompt = build_glossary_prompt(list(glossary), [], [], [])
    backend.start_session()
    ingest_started = time.perf_counter()
    for offset in range(0, len(audio), SAMPLE_RATE // 10):
        backend.feed_chunk(audio[offset : offset + SAMPLE_RATE // 10])
    ingest_s = time.perf_counter() - ingest_started
    started = time.perf_counter()
    transcript = backend.finalize()
    duration_s = len(audio) / SAMPLE_RATE
    ingest_rtf = ingest_s / duration_s if duration_s else 0.0
    return transcript, (time.perf_counter() - started) * 1000.0, ingest_rtf


def _load_backend(backend) -> float:
    started = time.perf_counter()
    backend.load()
    return (time.perf_counter() - started) * 1000.0


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as model_file:
        for chunk in iter(lambda: model_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sysctl(name: str) -> str:
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", name],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def _candidate_identity(candidate: TranscribeCppWhisperBackend) -> dict[str, str]:
    import transcribe_cpp

    actual_sha256 = _sha256(Path(candidate._model_path))
    if actual_sha256 != TRANSCRIBE_CPP_Q8_SHA256:
        raise ValueError(
            "candidate GGUF digest mismatch: "
            f"{actual_sha256} != {TRANSCRIBE_CPP_Q8_SHA256}"
        )
    return {
        "model_revision": TRANSCRIBE_CPP_Q8_REVISION,
        "model_sha256": actual_sha256,
        "transcribe_cpp_version": transcribe_cpp.__version__,
        "native_version": transcribe_cpp.native_version(),
        "native_commit": transcribe_cpp.native_commit(),
        "native_provider": transcribe_cpp.native_provider() or "unpackaged",
        "macos": platform.mac_ver()[0] or "unknown",
        "machine": platform.machine() or "unknown",
        "hardware_model": _sysctl("hw.model"),
    }


def run_benchmark(
    cases: list[BenchmarkCase], *, repeats: int, smoke: bool, min_speedup_pct: float
) -> tuple[Verdict, list[CaseResult], list[str]]:
    audio = [(case, _load_audio(case.path)) for case in cases]
    coverage_failures = [] if smoke else validate_coverage(
        cases, [len(pcm) / SAMPLE_RATE for _case, pcm in audio]
    )
    baseline = WhisperBackend(DEFAULT_STT_MODEL)
    candidate = TranscribeCppWhisperBackend(TRANSCRIBE_CPP_Q8_MODEL)
    baseline_load_ms = _load_backend(baseline)
    candidate_load_ms = _load_backend(candidate)
    print(json.dumps({
        "event": "models_loaded",
        "baseline": DEFAULT_STT_MODEL,
        "candidate": TRANSCRIBE_CPP_Q8_MODEL,
        "baseline_load_ms": round(baseline_load_ms, 1),
        "candidate_load_ms": round(candidate_load_ms, 1),
        **_candidate_identity(candidate),
    }))

    if audio:
        warm_case, warm_audio = min(audio, key=lambda pair: len(pair[1]))
        _decode_live(baseline, warm_audio, warm_case.glossary)
        _decode_live(candidate, warm_audio, warm_case.glossary)

    results: list[CaseResult] = []
    for case, pcm in audio:
        baseline_times: list[float] = []
        candidate_times: list[float] = []
        baseline_ingest_rtfs: list[float] = []
        candidate_ingest_rtfs: list[float] = []
        baseline_texts: list[str] = []
        candidate_texts: list[str] = []
        for _ in range(repeats):
            baseline_text, elapsed, ingest_rtf = _decode_live(
                baseline, pcm, case.glossary
            )
            baseline_texts.append(baseline_text)
            baseline_times.append(elapsed)
            baseline_ingest_rtfs.append(ingest_rtf)
            candidate_text, elapsed, ingest_rtf = _decode_live(
                candidate, pcm, case.glossary
            )
            candidate_texts.append(candidate_text)
            candidate_times.append(elapsed)
            candidate_ingest_rtfs.append(ingest_rtf)
        reference_words = _words(case.reference)
        baseline_error_counts = [
            _edit_distance(reference_words, _words(text)) for text in baseline_texts
        ]
        candidate_error_counts = [
            _edit_distance(reference_words, _words(text)) for text in candidate_texts
        ]
        baseline_glossary_scores = [
            _glossary_score(text, case.glossary) for text in baseline_texts
        ]
        candidate_glossary_scores = [
            _glossary_score(text, case.glossary) for text in candidate_texts
        ]
        result = CaseResult(
            name=case.name,
            cohort=case.cohort,
            reference_words=len(reference_words),
            # Quality is worst-of-repeat so a flaky native decode cannot hide
            # behind a good final iteration while latency uses robust medians.
            baseline_errors=max(baseline_error_counts),
            candidate_errors=max(candidate_error_counts),
            baseline_glossary=min(baseline_glossary_scores),
            candidate_glossary=min(candidate_glossary_scores),
            baseline_ms=statistics.median(baseline_times),
            candidate_ms=statistics.median(candidate_times),
            baseline_failure=any(
                _transcript_failure(case.reference, text) for text in baseline_texts
            ),
            candidate_failure=any(
                _transcript_failure(case.reference, text) for text in candidate_texts
            ),
            baseline_ingest_rtf=max(baseline_ingest_rtfs),
            candidate_ingest_rtf=max(candidate_ingest_rtfs),
        )
        results.append(result)
        print(json.dumps({
            "event": "case",
            "name": case.name,
            "cohort": case.cohort,
            "duration_s": round(len(pcm) / SAMPLE_RATE, 1),
            "baseline_ms": round(result.baseline_ms, 1),
            "candidate_ms": round(result.candidate_ms, 1),
            "speedup_pct": round(_speedup(result.baseline_ms, result.candidate_ms), 1),
            "baseline_ingest_rtf": round(result.baseline_ingest_rtf, 3),
            "candidate_ingest_rtf": round(result.candidate_ingest_rtf, 3),
            "baseline_errors": result.baseline_errors,
            "candidate_errors": result.candidate_errors,
            "baseline_glossary": list(result.baseline_glossary),
            "candidate_glossary": list(result.candidate_glossary),
            "baseline_failure": result.baseline_failure,
            "candidate_failure": result.candidate_failure,
        }, ensure_ascii=False))

    verdict = evaluate(results, min_speedup_pct=min_speedup_pct)
    all_failures = coverage_failures + list(verdict.failures)
    if coverage_failures:
        verdict = Verdict(
            False,
            tuple(all_failures),
            verdict.p50_speedup_pct,
            verdict.p95_speedup_pct,
        )
    return verdict, results, coverage_failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="local JSON manifest; transcript text is never printed")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--min-speedup-pct", type=float, default=10.0)
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="skip the 18-case/language/silence/long coverage requirement",
    )
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    try:
        cases = _load_manifest(args.manifest.resolve())
        verdict, _results, _coverage = run_benchmark(
            cases,
            repeats=args.repeats,
            smoke=args.smoke,
            min_speedup_pct=args.min_speedup_pct,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps({
        "event": "verdict",
        "accepted": verdict.accepted,
        "p50_speedup_pct": round(verdict.p50_speedup_pct, 1),
        "p95_speedup_pct": round(verdict.p95_speedup_pct, 1),
        "failures": list(verdict.failures),
    }))
    return 0 if verdict.accepted else 1


if __name__ == "__main__":
    raise SystemExit(main())
