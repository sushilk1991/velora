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
from collections.abc import Collection
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import numpy as np

log = logging.getLogger("velora.audio_store")

SAMPLE_RATE = 16_000

# A basename we are willing to read/write: our own session ids (uuid4 or the
# client-supplied session string) plus the extension. Anything with a path
# separator or "." traversal is rejected before it touches the filesystem.
_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+\.(flac|wav)$")
_ACTIVE_NAME_RE = re.compile(r"^([A-Za-z0-9_-]+)\.pcm16\.part$")


@dataclass(frozen=True)
class InterruptedAudio:
    session: str
    audio: str
    duration_s: float


class ActiveAudioSpool:
    """Append-only, crash-readable PCM16 for one live dictation."""

    def __init__(self, path: Path, handle: BinaryIO) -> None:
        self.path = path
        self._handle = handle

    def append(self, pcm: np.ndarray) -> bool:
        if self._handle.closed:
            return False
        try:
            samples = np.asarray(pcm, dtype=np.float32)
            samples = np.clip(np.nan_to_num(samples), -1.0, 1.0)
            payload = (samples * 32767.0).astype("<i2").tobytes()
            return self._handle.write(payload) == len(payload)
        except OSError:
            log.exception("failed to append active audio spool %s", self.path.name)
            return False

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self._handle.close()


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

    @property
    def active_dir(self) -> Path:
        return self.dir / ".active"

    @staticmethod
    def _stem(session_id: str) -> str:
        return re.sub(r"[^A-Za-z0-9_-]", "-", session_id) or "clip"

    def _active_path(self, session_id: str) -> Path:
        return self.active_dir / f"{self._stem(session_id)}.pcm16.part"

    def begin_active(self, session_id: str) -> ActiveAudioSpool | None:
        """Create one owner-only spool without replacing prior crash evidence."""
        self._ensure_dir()
        self.active_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with contextlib.suppress(OSError):
            os.chmod(self.active_dir, 0o700)
        path = self._active_path(session_id)
        descriptor: int | None = None
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND
            descriptor = os.open(path, flags, 0o600)
            handle = os.fdopen(descriptor, "wb", buffering=0)
            descriptor = None
            return ActiveAudioSpool(path, handle)
        except OSError:
            log.exception("failed to create active audio spool %s", path.name)
            return None
        finally:
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)

    def pending_interrupted(self) -> tuple[str, ...]:
        """Snapshot safe stale-session names before a new live session starts."""
        try:
            paths = sorted(self.active_dir.glob("*.pcm16.part"))
        except OSError:
            return ()
        sessions: list[str] = []
        for path in paths:
            match = _ACTIVE_NAME_RE.match(path.name)
            if match is not None and not path.is_symlink():
                sessions.append(match.group(1))
        return tuple(sessions)

    def recover_interrupted(
        self, sessions: Collection[str] | None = None,
    ) -> list[InterruptedAudio]:
        """Archive readable stale spools but retain them until the app acks."""
        wanted = set(sessions) if sessions is not None else set(self.pending_interrupted())
        recovered: list[InterruptedAudio] = []
        for session in sorted(wanted):
            path = self._active_path(session)
            match = _ACTIVE_NAME_RE.match(path.name)
            if match is None or path.is_symlink():
                continue
            try:
                byte_count = path.stat().st_size
                if byte_count == 0:
                    self._unlink(path)
                    continue
                pcm16 = np.fromfile(path, dtype="<i2", count=byte_count // 2)
            except OSError:
                continue
            if pcm16.size == 0:
                continue
            session = match.group(1)
            audio = self.name_for(session)
            archived = self.path_for(audio)
            if archived is None or not archived.is_file():
                pcm = (pcm16.astype(np.float32) / 32768.0).astype(np.float32)
                audio = self.save(session, pcm) or ""
            if not audio:
                continue
            recovered.append(InterruptedAudio(
                session=session,
                audio=audio,
                duration_s=float(pcm16.size) / SAMPLE_RATE,
            ))
        return recovered

    def finalize_active(self, spool: ActiveAudioSpool) -> str | None:
        """Atomically archive a normal stop, then remove its active spool."""
        spool.close()
        try:
            pcm16 = np.fromfile(spool.path, dtype="<i2")
        except OSError:
            return None
        if pcm16.size == 0:
            self._unlink(spool.path)
            return None
        pcm = (pcm16.astype(np.float32) / 32768.0).astype(np.float32)
        saved = self.save(spool.path.name.removesuffix(".pcm16.part"), pcm)
        if saved:
            self._unlink(spool.path)
        return saved

    def ack_interrupted(self, session_id: str) -> bool:
        """Remove only the acknowledged session's retained crash spool."""
        return self._unlink(self._active_path(session_id))

    def discard_active(self, spool: ActiveAudioSpool) -> bool:
        """Close and delete audio after an explicit user cancellation."""
        spool.close()
        return self._unlink(spool.path)

    def path_for(self, name: str) -> Path | None:
        """Resolve a clip basename to a path, rejecting traversal/odd names."""
        if not name or not _SAFE_NAME_RE.match(name):
            return None
        return self.dir / name

    # ---- write ----

    def name_for(self, session_id: str) -> str:
        """The clip basename `save` will produce for this session — lets the
        caller report the name without waiting for the disk write."""
        return f"{self._stem(session_id)}.{self.ext}"

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
