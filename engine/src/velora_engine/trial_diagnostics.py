"""Local, text-free provenance for the opt-in native dictation trial."""
from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import time

MAX_METADATA_BYTES = 8 * 1024 * 1024


def record_trial_run(home: Path, session_id: str, raw: str, final: str, *,
                     backend: str, attempted_backend: str, model_identity: str,
                     applied: bool, reason: str | None, cleanup_ms: int,
                     cleanup_wall_ms: int, recorded_at: float | None = None) -> None:
    if backend not in {"native_lfm3_g", "standard", "raw"}:
        raise ValueError("unknown trial backend")
    if attempted_backend not in {"native_lfm3_g", "standard", "bypass"}:
        raise ValueError("unknown attempted trial backend")
    if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128:
        raise ValueError("invalid trial session")
    stamp = time.time() if recorded_at is None else recorded_at
    if not math.isfinite(stamp):
        raise ValueError("invalid trial timestamp")
    value = {
        "schema": 1, "session_id": session_id,
        "raw_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "final_sha256": hashlib.sha256(final.encode()).hexdigest(),
        "backend": backend, "attempted_backend": attempted_backend,
        "model_identity": str(model_identity)[:256], "applied": bool(applied),
        "reason": str(reason)[:128] if reason is not None else None,
        "cleanup_ms": max(0, int(cleanup_ms)),
        "cleanup_wall_ms": max(0, int(cleanup_wall_ms)), "recorded_at": stamp,
    }
    line = (json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n").encode()
    if len(line) > MAX_METADATA_BYTES:
        raise ValueError("trial record exceeds metadata limit")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = home / "native-trial-runs.jsonl"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
    lock_fd = os.open(str(path) + ".lock", flags, 0o600)
    with os.fdopen(lock_fd, "ab") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("trial metadata lock must be a regular file")
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("trial metadata must be a regular file")
            if info.st_size + len(line) > MAX_METADATA_BYTES:
                os.replace(path, home / "native-trial-runs.previous.jsonl")
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "ab") as output:
            if not stat.S_ISREG(os.fstat(output.fileno()).st_mode):
                raise ValueError("trial metadata must be a regular file")
            os.fchmod(output.fileno(), 0o600)
            output.write(line)
            output.flush()
