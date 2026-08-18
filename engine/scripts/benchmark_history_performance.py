#!/usr/bin/env python3
"""Create a transcript-free performance report from Velora history.

The database is opened through SQLite's read-only URI mode. Transcript bodies
never cross the SQL boundary: only their SQLite-computed character counts are
loaded. JSON outputs contain aggregate timing/length metadata, and an optional
private corpus manifest contains only audio references, modes, and durations.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from typing import Any, Iterable, Sequence


DURATION_BUCKETS: tuple[tuple[str, int, int | None], ...] = (
    ("under_10s", 0, 10_000),
    ("10_to_25s", 10_000, 25_000),
    ("25_to_60s", 25_000, 60_000),
    ("60s_plus", 60_000, None),
)
_BUCKET_ORDER = {name: index for index, (name, _, _) in enumerate(DURATION_BUCKETS)}


@dataclass(frozen=True)
class HistorySample:
    """Performance metadata for one row; deliberately contains no transcript."""

    id: int
    mode: str
    duration_ms: int
    raw_chars: int | None
    final_chars: int | None
    final_nonempty: bool
    cleanup_ms: int | None
    audio_path: str | None
    stt_ms: int | None
    cleanup_applied: bool | None
    finalization_ms: int | None
    cleanup_wall_ms: int | None
    quality_state: int | None

    @property
    def recovery_wait_ms(self) -> int | None:
        return derive_recovery_wait_ms(
            self.finalization_ms, self.stt_ms, self.cleanup_wall_ms
        )


def sqlite_readonly_uri(database: Path) -> str:
    """Return a properly escaped SQLite URI that refuses database writes."""
    return f"{database.expanduser().resolve().as_uri()}?mode=ro"


def open_history_database(database: Path) -> sqlite3.Connection:
    """Open an existing history database read-only, without creating files."""
    path = database.expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"history database not found: {path}")
    connection = sqlite3.connect(sqlite_readonly_uri(path), uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def quantile(values: Sequence[int | float], probability: float) -> float | None:
    """Return a linearly interpolated quantile, or ``None`` for no samples."""
    if not 0.0 <= probability <= 1.0:
        raise ValueError("probability must be between zero and one")
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * probability
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _compact_number(value: float | None) -> int | float | None:
    if value is None:
        return None
    rounded = round(value, 3)
    return int(rounded) if rounded.is_integer() else rounded


def summarize_metric(values: Iterable[int | float | None]) -> dict[str, Any]:
    """Summarize available values while making legacy missingness explicit."""
    materialized = list(values)
    available = [float(value) for value in materialized if value is not None]
    if not available:
        return {
            "available": 0,
            "missing": len(materialized),
            "min": None,
            "p50": None,
            "p95": None,
            "max": None,
            "mean": None,
        }
    return {
        "available": len(available),
        "missing": len(materialized) - len(available),
        "min": _compact_number(min(available)),
        "p50": _compact_number(quantile(available, 0.50)),
        "p95": _compact_number(quantile(available, 0.95)),
        "max": _compact_number(max(available)),
        "mean": _compact_number(sum(available) / len(available)),
    }


def duration_bucket(duration_ms: int) -> str:
    """Bucket duration around Velora's 10/25-second streaming boundaries."""
    duration = max(0, int(duration_ms))
    for name, lower, upper in DURATION_BUCKETS:
        if duration >= lower and (upper is None or duration < upper):
            return name
    raise AssertionError("duration bucket definitions are incomplete")


def derive_recovery_wait_ms(
    finalization_ms: int | None,
    stt_ms: int | None,
    cleanup_wall_ms: int | None,
) -> int | None:
    """Derive the historical stop-to-final residual outside STT and cleanup.

    Old rows do not have a directly measured recovery phase. The nonnegative
    residual is therefore an upper bound: it can include small orchestration
    overhead in addition to an actual cleanup-worker recovery wait.
    """
    if finalization_ms is None or stt_ms is None or cleanup_wall_ms is None:
        return None
    return max(0, int(finalization_ms) - int(stt_ms) - int(cleanup_wall_ms))


def _optional_expression(columns: set[str], column: str, expression: str | None = None) -> str:
    if column not in columns:
        return f"NULL AS {column}"
    return f"{expression or column} AS {column}"


def load_history_samples(database: Path) -> list[HistorySample]:
    """Load only timing, length, mode, and audio-reference metadata."""
    connection = open_history_database(database)
    try:
        columns = {
            str(row[1])
            for row in connection.execute("PRAGMA table_info(dictations)")
        }
        required = {"id", "duration_ms"}
        missing = sorted(required - columns)
        if missing:
            raise ValueError(
                "dictations table is missing required columns: " + ", ".join(missing)
            )
        expressions = [
            "id",
            _optional_expression(columns, "mode"),
            "duration_ms",
            "LENGTH(raw) AS raw_chars" if "raw" in columns else "NULL AS raw_chars",
            "LENGTH(final) AS final_chars"
            if "final" in columns
            else "NULL AS final_chars",
            (
                "TRIM(REPLACE(REPLACE(final, char(10), ' '), char(9), ' ')) != '' "
                "AS final_nonempty"
                if "final" in columns
                else "0 AS final_nonempty"
            ),
            _optional_expression(columns, "cleanup_ms"),
            _optional_expression(columns, "audio_path"),
            _optional_expression(columns, "stt_ms"),
            _optional_expression(columns, "cleanup_applied"),
            _optional_expression(columns, "finalization_ms"),
            _optional_expression(columns, "cleanup_wall_ms"),
            _optional_expression(columns, "quality_state"),
        ]
        rows = connection.execute(
            "SELECT " + ", ".join(expressions) + " FROM dictations ORDER BY id"
        )
        samples: list[HistorySample] = []
        for row in rows:
            mode = row["mode"] if row["mode"] is not None else "Default"
            mode = str(mode).strip() or "Default"
            cleanup_applied = row["cleanup_applied"]
            samples.append(
                HistorySample(
                    id=int(row["id"]),
                    mode=mode,
                    duration_ms=max(0, int(row["duration_ms"])),
                    raw_chars=_optional_int(row["raw_chars"]),
                    final_chars=_optional_int(row["final_chars"]),
                    final_nonempty=bool(row["final_nonempty"]),
                    cleanup_ms=_optional_int(row["cleanup_ms"]),
                    audio_path=(
                        str(row["audio_path"])
                        if row["audio_path"] is not None
                        else None
                    ),
                    stt_ms=_optional_int(row["stt_ms"]),
                    cleanup_applied=(
                        bool(cleanup_applied) if cleanup_applied is not None else None
                    ),
                    finalization_ms=_optional_int(row["finalization_ms"]),
                    cleanup_wall_ms=_optional_int(row["cleanup_wall_ms"]),
                    quality_state=_optional_int(row["quality_state"]),
                )
            )
        return samples
    finally:
        connection.close()


def _optional_int(value: Any) -> int | None:
    return int(value) if value is not None else None


def _safe_audio_relative_path(audio_path: str | None, audio_root: Path) -> str | None:
    """Return a present in-root audio path, excluding absolute/traversal paths."""
    if not audio_path:
        return None
    relative = Path(audio_path)
    if relative.is_absolute():
        return None
    root = audio_root.expanduser().resolve()
    candidate = (root / relative).resolve()
    try:
        safe_relative = candidate.relative_to(root)
    except ValueError:
        return None
    if not candidate.is_file():
        return None
    return safe_relative.as_posix()


def _metric_values(samples: Sequence[HistorySample]) -> dict[str, list[int | None]]:
    return {
        "duration_ms": [sample.duration_ms for sample in samples],
        "raw_chars": [sample.raw_chars for sample in samples],
        "final_chars": [sample.final_chars for sample in samples],
        "stt_ms": [sample.stt_ms for sample in samples],
        "cleanup_ms": [sample.cleanup_ms for sample in samples],
        "cleanup_wall_ms": [sample.cleanup_wall_ms for sample in samples],
        "finalization_ms": [sample.finalization_ms for sample in samples],
        "recovery_wait_ms": [sample.recovery_wait_ms for sample in samples],
    }


def summarize_quality(samples: Sequence[HistorySample]) -> dict[str, Any]:
    """Summarize explicit quality observations without reading transcript text."""
    # Match the app's Insights denominator: failed/empty final outputs are not
    # editable dictation results and cannot honestly count as unobserved edits.
    eligible = [sample for sample in samples if sample.final_nonempty]
    unchanged = sum(sample.quality_state == 1 for sample in eligible)
    edited = sum(sample.quality_state == 2 for sample in eligible)
    observed = unchanged + edited
    total = len(eligible)
    return {
        "eligible": total,
        "observed": observed,
        "unobserved": total - observed,
        "unchanged": unchanged,
        "edited": edited,
        "observation_coverage": _compact_number(observed / total) if total else None,
        "zero_edit_rate": _compact_number(unchanged / observed) if observed else None,
    }


def build_report(samples: Sequence[HistorySample], audio_root: Path) -> dict[str, Any]:
    """Build aggregate JSON-safe timing and length metadata."""
    audio_referenced = sum(sample.audio_path is not None for sample in samples)
    audio_available = sum(
        _safe_audio_relative_path(sample.audio_path, audio_root) is not None
        for sample in samples
    )
    buckets: list[dict[str, Any]] = []
    for name, lower, upper in DURATION_BUCKETS:
        bucket_samples = [
            sample for sample in samples if duration_bucket(sample.duration_ms) == name
        ]
        buckets.append(
            {
                "bucket": name,
                "min_ms": lower,
                "max_ms_exclusive": upper,
                "rows": len(bucket_samples),
                "audio_files_available": sum(
                    _safe_audio_relative_path(sample.audio_path, audio_root) is not None
                    for sample in bucket_samples
                ),
                "metrics": {
                    metric: summarize_metric(values)
                    for metric, values in _metric_values(bucket_samples).items()
                },
            }
        )

    cleanup_known = [
        sample.cleanup_applied
        for sample in samples
        if sample.cleanup_applied is not None
    ]
    return {
        "schema_version": 1,
        "privacy": {
            "database_access": "sqlite_uri_mode_ro",
            "transcript_text_included": False,
            "only_aggregate_nontext_metadata": True,
        },
        "rows": {
            "total": len(samples),
            "audio_referenced": audio_referenced,
            "audio_files_available": audio_available,
            "audio_files_unavailable_or_unsafe": audio_referenced - audio_available,
        },
        "cleanup": {
            "known": len(cleanup_known),
            "missing": len(samples) - len(cleanup_known),
            "applied": sum(cleanup_known),
        },
        "quality": summarize_quality(samples),
        "metrics": {
            metric: summarize_metric(values)
            for metric, values in _metric_values(samples).items()
        },
        "duration_buckets": buckets,
        "recovery_wait_derivation": (
            "max(0, finalization_ms - stt_ms - cleanup_wall_ms); "
            "upper bound that may include orchestration overhead"
        ),
    }


def _selection_rank(sample: HistorySample, audio: str) -> str:
    payload = json.dumps(
        [sample.id, audio, sample.mode, sample.duration_ms],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def select_stratified_corpus(
    samples: Sequence[HistorySample],
    audio_root: Path,
    *,
    per_stratum: int = 1,
) -> dict[str, Any]:
    """Select stable audio cases from every available duration/mode stratum."""
    if per_stratum < 1:
        raise ValueError("per_stratum must be at least one")
    strata: dict[tuple[str, str], list[tuple[str, HistorySample, str]]] = {}
    for sample in samples:
        audio = _safe_audio_relative_path(sample.audio_path, audio_root)
        if audio is None:
            continue
        key = (duration_bucket(sample.duration_ms), sample.mode)
        strata.setdefault(key, []).append((_selection_rank(sample, audio), sample, audio))

    cases: list[dict[str, Any]] = []
    ordered_strata = sorted(
        strata,
        key=lambda key: (_BUCKET_ORDER[key[0]], key[1].casefold(), key[1]),
    )
    for key in ordered_strata:
        candidates = sorted(
            strata[key], key=lambda value: (value[0], value[1].id, value[2])
        )
        for _, sample, audio in candidates[:per_stratum]:
            cases.append(
                {
                    "case_id": f"history-{sample.id}",
                    "audio": audio,
                    "mode": sample.mode,
                    "duration_ms": sample.duration_ms,
                    "duration_bucket": key[0],
                }
            )

    return {
        "schema_version": 1,
        "privacy": {
            "transcript_text_included": False,
            "contains_private_local_audio_references": True,
        },
        "selection": {
            "strategy": "sha256_rank_per_duration_bucket_and_mode",
            "per_stratum": per_stratum,
            "eligible": sum(len(candidates) for candidates in strata.values()),
            "strata": len(strata),
            "selected": len(cases),
        },
        "cases": cases,
    }


def _write_private_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomically write private output without a world-readable creation window."""
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
    finally:
        if temporary is not None:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--db", type=Path, required=True, help="existing Velora history SQLite path"
    )
    parser.add_argument(
        "--audio-root", type=Path, required=True, help="local archived-audio directory"
    )
    parser.add_argument(
        "--json", type=Path, required=True, help="aggregate report output path"
    )
    parser.add_argument(
        "--select-corpus",
        type=Path,
        help="optional private transcript-free corpus manifest output path",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    database = args.db.expanduser().resolve()
    outputs = [("--json", args.json)]
    if args.select_corpus is not None:
        outputs.append(("--select-corpus", args.select_corpus))
    for flag, output in outputs:
        if output.expanduser().resolve() == database:
            parser.error(f"{flag} must not be the history database")
    if (
        args.select_corpus is not None
        and args.json.expanduser().resolve()
        == args.select_corpus.expanduser().resolve()
    ):
        parser.error("--json and --select-corpus must be different paths")

    samples = load_history_samples(args.db)
    _write_private_json(args.json, build_report(samples, args.audio_root))
    if args.select_corpus is not None:
        _write_private_json(
            args.select_corpus,
            select_stratified_corpus(samples, args.audio_root),
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
