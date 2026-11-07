from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import stat

import pytest

from velora_engine import trial_diagnostics as diagnostics


def record(home, session="one"):
    diagnostics.record_trial_run(home, session, "hello\n世界", "Hello\n世界", backend="native_lfm3_g",
        attempted_backend="native_lfm3_g", model_identity="a" * 64, applied=True,
        reason="llm", cleanup_ms=42, cleanup_wall_ms=43, recorded_at=123.0)


def test_trial_metadata_is_private_and_does_not_duplicate_dictation(tmp_path):
    record(tmp_path)
    path = tmp_path / "native-trial-runs.jsonl"
    data = path.read_text()
    value = json.loads(data)
    assert value["raw_sha256"] == hashlib.sha256("hello\n世界".encode()).hexdigest()
    assert value["final_sha256"] == hashlib.sha256("Hello\n世界".encode()).hexdigest()
    assert value["backend"] == "native_lfm3_g" and value["session_id"] == "one"
    assert "raw" not in value and "final" not in value and "世界" not in data
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_concurrent_trial_records_remain_whole_json_lines(tmp_path):
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda i: record(tmp_path, str(i)), range(20)))
    rows = [json.loads(line) for line in (tmp_path / "native-trial-runs.jsonl").read_text().splitlines()]
    assert len(rows) == 20 and len({row["session_id"] for row in rows}) == 20


def test_rotation_keeps_current_metadata_within_reader_bound(tmp_path, monkeypatch):
    monkeypatch.setattr(diagnostics, "MAX_METADATA_BYTES", 1100)
    record(tmp_path)
    record(tmp_path, "two")
    record(tmp_path, "three")
    path = tmp_path / "native-trial-runs.jsonl"
    assert path.stat().st_size <= 1100
    assert json.loads(path.read_text())["session_id"] == "three"
    assert (tmp_path / "native-trial-runs.previous.jsonl").exists()


def test_metadata_does_not_follow_output_symlinks(tmp_path):
    target = tmp_path / "unrelated"
    target.write_text("keep")
    (tmp_path / "native-trial-runs.jsonl").symlink_to(target)
    with pytest.raises((ValueError, OSError)):
        record(tmp_path)
    assert target.read_text() == "keep"
