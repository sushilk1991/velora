"""Tests for the privacy-preserving local history performance report."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from types import ModuleType

import pytest


ENGINE_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ENGINE_ROOT / "scripts" / "benchmark_history_performance.py"


def _load_script() -> ModuleType:
    assert SCRIPT.is_file(), "history benchmark script has not been implemented"
    spec = importlib.util.spec_from_file_location(
        "benchmark_history_performance", SCRIPT
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _create_history(path: Path, *, current: bool = True) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    optional_columns = """
        , audio_path TEXT
        , stt_ms INTEGER
        , cleanup_applied INTEGER
        , finalization_ms INTEGER
        , cleanup_wall_ms INTEGER
        , quality_state INTEGER
    """ if current else ""
    connection.execute(
        f"""
        CREATE TABLE dictations (
            id INTEGER PRIMARY KEY,
            ts REAL NOT NULL,
            raw TEXT NOT NULL,
            final TEXT NOT NULL,
            mode TEXT,
            duration_ms INTEGER NOT NULL,
            cleanup_ms INTEGER
            {optional_columns}
        )
        """
    )
    return connection


def _sample(module: ModuleType, **overrides):
    values = {
        "id": 1,
        "mode": "Default",
        "duration_ms": 5_000,
        "raw_chars": 10,
        "final_chars": 11,
        "final_nonempty": True,
        "cleanup_ms": 100,
        "audio_path": "clip.flac",
        "stt_ms": 500,
        "cleanup_applied": True,
        "finalization_ms": 900,
        "cleanup_wall_ms": 200,
        "quality_state": None,
    }
    values.update(overrides)
    return module.HistorySample(**values)


def _all_keys(value) -> set[str]:
    if isinstance(value, dict):
        keys = set(value)
        for child in value.values():
            keys.update(_all_keys(child))
        return keys
    if isinstance(value, list):
        keys: set[str] = set()
        for child in value:
            keys.update(_all_keys(child))
        return keys
    return set()


def test_history_database_is_opened_with_a_read_only_sqlite_uri(tmp_path):
    module = _load_script()
    database = tmp_path / "history file.sqlite3"
    connection = _create_history(database, current=False)
    connection.commit()
    connection.close()

    uri = module.sqlite_readonly_uri(database)
    assert uri.startswith("file:")
    assert "mode=ro" in uri

    readonly = module.open_history_database(database)
    try:
        with pytest.raises(sqlite3.OperationalError, match="readonly|read-only"):
            readonly.execute("CREATE TABLE forbidden_write (value INTEGER)")
    finally:
        readonly.close()


def test_quantiles_use_linear_interpolation_and_ignore_missing_values():
    module = _load_script()

    assert module.quantile([40, 10, 30, 20], 0.50) == 25
    assert module.quantile([40, 10, 30, 20], 0.95) == pytest.approx(38.5)
    assert module.quantile([], 0.95) is None

    summary = module.summarize_metric([10, None, 20, 30, 40, None])
    assert summary == {
        "available": 4,
        "missing": 2,
        "min": 10,
        "p50": 25.0,
        "p95": 38.5,
        "max": 40,
        "mean": 25.0,
    }


@pytest.mark.parametrize(
    ("duration_ms", "expected"),
    [
        (0, "under_10s"),
        (9_999, "under_10s"),
        (10_000, "10_to_25s"),
        (24_999, "10_to_25s"),
        (25_000, "25_to_60s"),
        (59_999, "25_to_60s"),
        (60_000, "60s_plus"),
    ],
)
def test_duration_buckets_match_streaming_boundaries(duration_ms, expected):
    module = _load_script()

    assert module.duration_bucket(duration_ms) == expected


def test_recovery_wait_is_the_nonnegative_residual_after_stt_and_cleanup():
    module = _load_script()

    assert module.derive_recovery_wait_ms(5_000, 1_200, 1_500) == 2_300
    assert module.derive_recovery_wait_ms(1_000, 800, 500) == 0
    assert module.derive_recovery_wait_ms(None, 800, 500) is None
    assert module.derive_recovery_wait_ms(1_000, None, 500) is None
    assert module.derive_recovery_wait_ms(1_000, 800, None) is None


def test_quality_report_exposes_observation_coverage_without_transcript_text(tmp_path):
    module = _load_script()
    samples = [
        _sample(module, id=1, quality_state=1),
        _sample(module, id=2, quality_state=2),
        _sample(module, id=3, quality_state=None),
        _sample(module, id=4, quality_state=None),
        _sample(module, id=5, final_chars=0, final_nonempty=False, quality_state=None),
    ]

    quality = module.build_report(samples, tmp_path / "audio")["quality"]

    assert quality == {
        "eligible": 4,
        "observed": 2,
        "unobserved": 2,
        "unchanged": 1,
        "edited": 1,
        "observation_coverage": 0.5,
        "zero_edit_rate": 0.5,
    }


def test_quality_eligibility_matches_the_apps_trimmed_final_definition(tmp_path):
    module = _load_script()
    database = tmp_path / "history.sqlite3"
    connection = _create_history(database)
    for row_id, final, quality in (
        (1, "\n\t   \n", 2),
        (2, "a real result", 1),
    ):
        connection.execute(
            """
            INSERT INTO dictations
                (id, ts, raw, final, mode, duration_ms, cleanup_ms, quality_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (row_id, 1.0, "synthetic", final, "Default", 1_000, 10, quality),
        )
    connection.commit()
    connection.close()

    quality = module.build_report(
        module.load_history_samples(database), tmp_path / "audio"
    )["quality"]

    assert quality["eligible"] == 1
    assert quality["observed"] == 1
    assert quality["unchanged"] == 1


def test_legacy_history_without_new_metrics_reports_missing_samples(tmp_path):
    module = _load_script()
    database = tmp_path / "legacy.sqlite3"
    connection = _create_history(database, current=False)
    connection.execute(
        """
        INSERT INTO dictations
            (id, ts, raw, final, mode, duration_ms, cleanup_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (1, 1.0, "synthetic raw", "synthetic final", "Default", 8_000, 120),
    )
    connection.commit()
    connection.close()

    samples = module.load_history_samples(database)
    report = module.build_report(samples, tmp_path / "audio")

    assert report["rows"]["total"] == 1
    assert report["privacy"]["transcript_text_included"] is False
    assert report["privacy"]["only_aggregate_nontext_metadata"] is True
    assert report["metrics"]["stt_ms"]["available"] == 0
    assert report["metrics"]["stt_ms"]["missing"] == 1
    assert report["metrics"]["stt_ms"]["p50"] is None
    assert report["metrics"]["finalization_ms"]["available"] == 0
    assert report["metrics"]["recovery_wait_ms"]["available"] == 0
    assert report["quality"]["observation_coverage"] == 0
    assert samples[0].raw_chars == len("synthetic raw")
    assert samples[0].final_chars == len("synthetic final")


def test_corpus_selection_is_deterministic_and_stratified_by_bucket_and_mode(
    tmp_path,
):
    module = _load_script()
    audio_root = tmp_path / "audio"
    audio_root.mkdir()
    samples = []
    durations = [5_000, 12_000, 30_000, 70_000]
    for bucket_index, duration_ms in enumerate(durations):
        for mode in ("Default", "Note"):
            for candidate_index in range(2):
                sample_id = bucket_index * 100 + candidate_index + (50 if mode == "Note" else 0)
                audio_name = f"clip-{sample_id}.flac"
                (audio_root / audio_name).write_bytes(b"synthetic audio")
                samples.append(
                    _sample(
                        module,
                        id=sample_id,
                        mode=mode,
                        duration_ms=duration_ms,
                        audio_path=audio_name,
                    )
                )

    first = module.select_stratified_corpus(samples, audio_root, per_stratum=1)
    second = module.select_stratified_corpus(
        list(reversed(samples)), audio_root, per_stratum=1
    )

    assert first == second
    assert first["selection"]["eligible"] == 16
    assert first["selection"]["selected"] == 8
    assert {
        (case["duration_bucket"], case["mode"])
        for case in first["cases"]
    } == {
        (bucket, mode)
        for bucket in ("under_10s", "10_to_25s", "25_to_60s", "60s_plus")
        for mode in ("Default", "Note")
    }


def test_cli_writes_only_redacted_report_and_corpus_metadata(tmp_path):
    database = tmp_path / "history.sqlite3"
    audio_root = tmp_path / "audio"
    audio_root.mkdir()
    audio_name = "synthetic.flac"
    (audio_root / audio_name).write_bytes(b"not real audio")
    raw_canary = "RAW-TRANSCRIPT-CANARY-9f821"
    final_canary = "FINAL-TRANSCRIPT-CANARY-4a310"
    connection = _create_history(database)
    connection.execute(
        """
        INSERT INTO dictations
            (id, ts, raw, final, mode, duration_ms, cleanup_ms, audio_path,
             stt_ms, cleanup_applied, finalization_ms, cleanup_wall_ms,
             quality_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            7,
            1.0,
            raw_canary,
            final_canary,
            "Note",
            12_000,
            400,
            audio_name,
            1_000,
            1,
            2_000,
            600,
            2,
        ),
    )
    connection.commit()
    connection.close()
    report_path = tmp_path / "report.json"
    corpus_path = tmp_path / "corpus.json"

    completed = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--db",
            str(database),
            "--audio-root",
            str(audio_root),
            "--json",
            str(report_path),
            "--select-corpus",
            str(corpus_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    emitted = completed.stdout + completed.stderr + report_path.read_text() + corpus_path.read_text()
    assert raw_canary not in emitted
    assert final_canary not in emitted
    report = json.loads(report_path.read_text())
    corpus = json.loads(corpus_path.read_text())
    assert "raw" not in _all_keys(report)
    assert "final" not in _all_keys(report)
    assert "raw" not in _all_keys(corpus)
    assert "final" not in _all_keys(corpus)
    assert report["metrics"]["raw_chars"]["p50"] == len(raw_canary)
    assert report["metrics"]["final_chars"]["p50"] == len(final_canary)
    assert report["quality"]["edited"] == 1
    assert report["quality"]["observation_coverage"] == 1
    assert corpus["cases"] == [
        {
            "case_id": "history-7",
            "audio": audio_name,
            "mode": "Note",
            "duration_ms": 12_000,
            "duration_bucket": "10_to_25s",
        }
    ]


def test_cli_refuses_to_overwrite_the_history_database(tmp_path):
    database = tmp_path / "history.sqlite3"
    connection = _create_history(database, current=False)
    connection.commit()
    connection.close()
    before = database.read_bytes()

    completed = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--db",
            str(database),
            "--audio-root",
            str(tmp_path / "audio"),
            "--json",
            str(database),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode != 0
    assert "must not be the history database" in completed.stderr
    assert database.read_bytes() == before
    readonly = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        assert readonly.execute(
            "SELECT COUNT(*) FROM dictations"
        ).fetchone()[0] == 0
    finally:
        readonly.close()
