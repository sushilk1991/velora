"""Audio clip archive: persist session PCM for later reprocessing.

Clips live in ``~/.velora/audio/<session_id>.<ext>`` — FLAC via ``soundfile``
(lossless, roughly 5x smaller than 16-bit WAV for speech, so reprocessing keeps
full fidelity) with a stdlib 16-bit-WAV fallback when libsndfile is missing.

Retention is enforced on engine start and after each save: clips older than
``retention_days`` are deleted, then a total-size cap evicts oldest-first. The
directory is 0700 and clips are 0600 — recorded speech is as private as the
transcripts stored beside it.
"""

from __future__ import annotations

import contextlib
import logging
import os
import re
import time
import uuid
import wave
from pathlib import Path

import numpy as np

log = logging.getLogger("velora.audio_store")

SAMPLE_RATE = 16_000

# A basename we are willing to read/write: our own session ids (uuid4 or the
# client-supplied session string) plus the extension. Anything with a path
# separator or "." traversal is rejected before it touches the filesystem.
_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+\.(flac|wav)$")


def _soundfile():
    """Return the soundfile module, or None if libsndfile is unavailable."""
    try:
        import soundfile as sf  # type: ignore

        return sf
    except Exception:  # noqa: BLE001 — any import/loader failure → WAV fallback
        return None


class AudioStore:
    def __init__(self, audio_dir: Path) -> None:
        self.dir = audio_dir
        self._sf = _soundfile()
        self.ext = "flac" if self._sf is not None else "wav"

    def _ensure_dir(self) -> None:
        self.dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.dir, 0o700)
        except OSError:  # pragma: no cover — best effort
            pass

    def path_for(self, name: str) -> Path | None:
        """Resolve a clip basename to a path, rejecting traversal/odd names."""
        if not name or not _SAFE_NAME_RE.match(name):
            return None
        return self.dir / name

    # ---- write ----

    def name_for(self, session_id: str) -> str:
        """The clip basename `save` will produce for this session — lets the
        caller report the name without waiting for the disk write."""
        stem = re.sub(r"[^A-Za-z0-9_-]", "-", session_id) or "clip"
        return f"{stem}.{self.ext}"

    def save(self, session_id: str, pcm: np.ndarray) -> str | None:
        """Persist one session's PCM (float32, 16kHz mono). Returns the clip
        basename, or None if saving failed or there was nothing to save."""
        if pcm is None or pcm.size == 0:
            return None
        self._ensure_dir()
        name = self.name_for(session_id)
        path = self.dir / name
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            samples = np.asarray(pcm, dtype=np.float32)
            samples = np.clip(np.nan_to_num(samples), -1.0, 1.0)
            if self._sf is not None:
                # PCM_16 subtype: 16-bit is ample for 16kHz speech and halves
                # the FLAC size versus 24-bit.
                self._sf.write(
                    str(temporary),
                    samples,
                    SAMPLE_RATE,
                    subtype="PCM_16",
                    format="FLAC",
                )
            else:
                self._write_wav(temporary, samples)
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
            os.chmod(path, 0o600)
            return name
        except Exception:  # noqa: BLE001 — archiving must never break dictation
            log.exception("failed to save audio clip for session %s", session_id)
            return None
        finally:
            with contextlib.suppress(OSError):
                temporary.unlink()

    @staticmethod
    def _write_wav(path: Path, samples: np.ndarray) -> None:
        pcm16 = (samples * 32767.0).astype("<i2")
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(pcm16.tobytes())

    # ---- read ----

    def load(self, name: str) -> np.ndarray:
        """Read a clip back as float32 mono at 16kHz. Raises on bad name/missing."""
        path = self.path_for(name)
        if path is None:
            raise ValueError(f"unsafe clip name: {name!r}")
        if not path.exists():
            raise FileNotFoundError(str(path))
        if self._sf is not None:
            data, _sr = self._sf.read(str(path), dtype="float32", always_2d=False)
            if data.ndim > 1:
                data = data.mean(axis=1)
            return np.asarray(data, dtype=np.float32)
        return self._read_wav(path)

    @staticmethod
    def _read_wav(path: Path) -> np.ndarray:
        with wave.open(str(path), "rb") as w:
            frames = w.readframes(w.getnframes())
            pcm16 = np.frombuffer(frames, dtype="<i2")
            channels = w.getnchannels() or 1
            if channels > 1:
                pcm16 = pcm16.reshape(-1, channels).mean(axis=1)
        return (pcm16.astype(np.float32) / 32768.0).astype(np.float32)

    # ---- retention ----

    def prune(self, retention_days: float, max_bytes: int | None = None) -> int:
        """Delete clips older than retention_days, then evict oldest-first until
        the archive is under max_bytes. Returns the number of clips deleted."""
        if not self.dir.exists():
            return 0
        try:
            clips = [p for p in self.dir.iterdir() if p.suffix.lstrip(".") in ("flac", "wav")]
        except OSError:
            return 0
        deleted = 0
        now = time.time()
        cutoff = now - retention_days * 86400.0 if retention_days and retention_days > 0 else None

        stats: list[tuple[float, int, Path]] = []
        for p in clips:
            try:
                st = p.stat()
            except OSError:
                continue
            stats.append((st.st_mtime, st.st_size, p))

        survivors: list[tuple[float, int, Path]] = []
        for mtime, size, p in stats:
            if cutoff is not None and mtime < cutoff:
                if self._unlink(p):
                    deleted += 1
                continue
            survivors.append((mtime, size, p))

        if max_bytes is not None and max_bytes > 0:
            total = sum(size for _m, size, _p in survivors)
            if total > max_bytes:
                # Oldest first.
                for mtime, size, p in sorted(survivors, key=lambda t: t[0]):
                    if total <= max_bytes:
                        break
                    if self._unlink(p):
                        deleted += 1
                        total -= size
        if deleted:
            log.info("audio retention: pruned %d clip(s) from %s", deleted, self.dir)
        return deleted

    @staticmethod
    def _unlink(path: Path) -> bool:
        try:
            path.unlink()
            return True
        except OSError:
            return False
