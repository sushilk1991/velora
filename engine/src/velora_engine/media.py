"""Decode arbitrary audio files to 16 kHz mono float32 (file transcription).

Prefers macOS's built-in `afconvert` (m4a/mp3/aac/alac/wav/aiff/caf with
proper sample-rate conversion — covers Voice Memos and meeting recordings);
falls back to soundfile (ogg/flac/opus) with linear resampling when afconvert
can't read the file. No third-party ffmpeg dependency.
"""

from __future__ import annotations

import logging
import math
import os
import errno
import json
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path
from types import SimpleNamespace
from typing import BinaryIO, Callable, NoReturn

import numpy as np

log = logging.getLogger("velora.media")

SAMPLE_RATE = 16000
# Keep arbitrary imports tightly bounded. App-owned meeting CAFs have a
# separate trusted-header path because their native PCM rate is device-defined.
MAX_FILE_BYTES = 2 * 1024**3
MAX_DURATION_S = 4 * 3600
_AFCONVERT_TIMEOUT_S = 600
_M4A_PROBE_TIMEOUT_S = 10
_MAX_CAF_OVERHEAD_BYTES = 1024**2
_MAX_MEETING_SAMPLE_RATE = 384_000
# Uncompressed PCM subtypes meeting capture may write, with bytes per sample.
# The microphone track keeps the input device's native format: a USB mic
# delivers Int16, the built-in mic Float32. MeetingTrackFormat in
# MeetingStore.swift mirrors this set so Retry never offers a track that
# this loader would reject.
_MEETING_PCM_SAMPLE_BYTES = {
    "PCM_16": 2,
    "PCM_24": 3,
    "PCM_32": 4,
    "FLOAT": 4,
    "DOUBLE": 8,
}
_MAX_GENERIC_SAMPLE_RATE = 384_000
_MAX_GENERIC_CHANNELS = 8
_SOUNDFILE_SOURCE_BLOCK_BYTES = 64 * 1024**2
_SOUNDFILE_OUTPUT_BLOCK_S = 60
# afconvert writes 16 kHz Int16 output to the temp dir before slice reads.
_CONVERTED_BYTES_PER_SECOND = SAMPLE_RATE * 2
# afconvert's CAF container adds a 4,096-byte header to the PCM payload.
_CONVERTED_CAF_HEADER_BYTES = 4096
# Keep recording and spool writes viable while converted PCM stays open.
_CONVERT_FREE_SPACE_MARGIN_BYTES = 256 * 1024**2
MEETING_SLICE_S = 90
_MEETING_PEAK_BLOCK_S = 60
_MEETING_TARGET_S = 60
_MEETING_SEARCH_S = 15
_MEETING_TAIL_S = 30
_MEETING_ENERGY_WINDOW_S = 0.3
# A 120 s 48 kHz stereo CAF converted in 0.040 s locally; 0.1x audio
# duration leaves over 300x that measured runtime, plus the 600 s floor.
_MEETING_CONVERT_TIMEOUT_RATIO = 0.1
_MEETING_TEMP_DIR = "velora-meeting-media"
_MEETING_TEMP_PREFIX = "velora-meeting-"
_MEETING_FALLBACK_PREFIX = _MEETING_TEMP_DIR + "-"
_meeting_fallback: tuple[int, Path] | None = None
_meeting_temp_lock = threading.Lock()
_MEETING_CONVERT_POLL_S = 0.25
_MEETING_CONVERT_REAP_S = 5
_MEETING_READ_BLOCK_S = 1
# MeetingProcessor.swift allows three automatic load retries 30 s apart.
# One extra interval covers scheduling delay; later Retry starts fresh.
_MEETING_LOAD_RETRIES = 3
_MEETING_LOAD_RETRY_INTERVAL_S = 30
_FAILURE_STRIKE_MARGIN_S = 30
MEETING_FAILURE_SUFFIX = ".failure.json"
_AFINFO_DURATION = re.compile(rb"estimated duration:\s*(\S+)\s+sec")
# afinfo alone reports the same error for truncated, random and empty M4As.
# A bounded afconvert input-open probe distinguishes them from output errors.
_AFINFO_OPEN_ERROR = "Fail: AudioFileOpenURL failed"
_AFINFO_NO_DURATION = "missing duration"
# Exact measured input-side errors only; output and generic I/O faults retry.
_INPUT_ERRORS = {
    "afconvert": frozenset({
        "Error: Couldn't open input file ('dta?')",
        "Error: Couldn't open input file ('typ?')",
        "Error: ExtAudioFileRead failed ('bada')",
    }),
    "afinfo": frozenset({
        f"{_AFINFO_OPEN_ERROR} | Error: Couldn't open input file ('dta?')",
        f"{_AFINFO_OPEN_ERROR} | Error: Couldn't open input file ('typ?')",
        f"{_AFINFO_OPEN_ERROR} | Error: Couldn't open input file ('wht?')",
    }),
}
_CAF_DESC_BYTES = 32
_CAF_DESC_FORMAT = ">d4sIIIII"
_CAF_FLOAT_FLAG = 1
_CAF_LINEAR_PCM = b"lpcm"
_CAF_FLOAT_BITS = 32
_CAF_DOUBLE_BITS = 64


class TransientMediaError(ValueError):
    """A meeting file that could not be read this time but may read later:
    the converter timed out or could not run, the disk is too full for its
    output, or the file changed while it was being read. A plain ValueError
    means the file itself is rejected.

        converter timeout / OSError / low disk / file changed
                    -> TransientMediaError  (app retries the track)
        bad format / header / decode rejected
                    -> ValueError           (app skips the track)
    """


class MeetingTrackTooShort(ValueError):
    """A valid legacy container has no audio packets to transcribe."""


class _CoreAudioFailure(ValueError):
    """Preserve a process failure for two-attempt classification."""

    def __init__(self, step: str, returncode: int, output: str) -> None:
        self.step = step
        self.returncode = returncode
        self.output = output
        super().__init__(f"{step} failed: {output or returncode}")


class MeetingAudio:
    """Owner of a converted 16 kHz Int16 CAF, read only in bounded windows."""

    def __init__(self, path: Path) -> None:
        import soundfile as sf

        self._path = path
        self._lock = threading.Lock()
        self._closed = False
        self._source = sf.SoundFile(str(path), mode="r")
        if self._source.samplerate != SAMPLE_RATE or self._source.channels != 1:
            self.close()
            raise ValueError("unexpected converted meeting format")
        self.samples = len(self._source)
        # Keep the descriptor, not its directory entry, during an hours-long
        # decode. A killed engine then releases the bytes with the descriptor.
        try:
            self._path.unlink(missing_ok=True)
        except OSError:
            self._source.close()
            raise

    def __len__(self) -> int:
        return self.samples

    def read(
        self, start: int, end: int, *, cancel: Callable[[], bool],
    ) -> np.ndarray:
        """Decode one slice; the caller keeps it within MEETING_SLICE_S."""
        if not 0 <= start <= end <= self.samples:
            raise ValueError("meeting slice outside converted track")
        if end - start > MEETING_SLICE_S * SAMPLE_RATE:
            raise ValueError("meeting slice exceeds bounded window")
        blocks = []
        block = _MEETING_READ_BLOCK_S * SAMPLE_RATE
        with self._lock:
            if self._closed:
                raise TransientMediaError("converted meeting audio is closed")
            try:
                self._source.seek(start)
                for position in range(start, end, block):
                    _check_cancel(cancel)
                    blocks.append(self._source.read(min(block, end - position), dtype="float32"))
                _check_cancel(cancel)
            except (OSError, RuntimeError) as exc:
                raise TransientMediaError(f"converted meeting audio could not be read ({exc})") from exc
        pcm = np.concatenate(blocks) if blocks else np.empty(0, dtype=np.float32)
        if len(pcm) != end - start:
            raise TransientMediaError("converted meeting audio ended early")
        return pcm

    def peak(self, *, cancel: Callable[[], bool]) -> float:
        """Scan the track without allocating a whole-track absolute array."""
        peak = 0.0
        block = _MEETING_PEAK_BLOCK_S * SAMPLE_RATE
        for start in range(0, self.samples, block):
            _check_cancel(cancel)
            pcm = self.read(start, min(start + block, self.samples), cancel=cancel)
            if len(pcm):
                peak = max(peak, float(pcm.max()), -float(pcm.min()))
        return peak

    def close(self) -> None:
        # A shutdown close waits for any worker's seek/read before sf_close.
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._source.close()


def _meeting_temp_root() -> Path:
    """Use the current process temp root for private conversion files."""
    return Path(tempfile.gettempdir())


def _meeting_temp_dir() -> Path:
    """Keep unfinished conversions in one private, sweepable directory."""
    root = _meeting_temp_root()
    directory = root / _MEETING_TEMP_DIR
    try:
        directory.mkdir(mode=0o700, exist_ok=True)
        stat = directory.lstat()
        if not directory.is_symlink() and stat.st_uid == os.getuid():
            directory.chmod(0o700)
            return directory
    except OSError:
        pass
    # Keep one private fallback for this process so startup can sweep it.
    global _meeting_fallback
    with _meeting_temp_lock:
        if _meeting_fallback is not None and _meeting_fallback[0] == os.getpid():
            cached = _meeting_fallback[1]
            try:
                if (not cached.is_symlink() and cached.is_dir() and
                        cached.lstat().st_uid == os.getuid()):
                    cached.chmod(0o700)
                    return cached
            except OSError:
                pass
        directory = Path(tempfile.mkdtemp(prefix=_MEETING_FALLBACK_PREFIX, dir=root))
        _meeting_fallback = (os.getpid(), directory)
        return directory


def sweep_meeting_temp() -> None:
    """Remove converter outputs orphaned by a prior engine crash."""
    root = _meeting_temp_root()
    fixed = root / _MEETING_TEMP_DIR
    directories = [fixed, *root.glob(_MEETING_FALLBACK_PREFIX + "*")]
    for directory in directories:
        try:
            stat = directory.lstat()
            if directory.is_symlink() or not directory.is_dir() or stat.st_uid != os.getuid():
                continue
            directory.chmod(0o700)
            _sweep_meeting_dir(directory)
            if (directory != fixed and
                    (_meeting_fallback is None or directory != _meeting_fallback[1])):
                directory.rmdir()
        except FileNotFoundError:
            continue
        except OSError:
            log.warning("could not sweep meeting temp directory %s", directory)


def _sweep_meeting_dir(directory: Path) -> None:
    """Unlink named partial outputs only after their engine pid is gone."""
    for entry in os.scandir(directory):
        if not entry.name.startswith(_MEETING_TEMP_PREFIX) or not entry.is_file(follow_symlinks=False):
            continue
        owner = entry.name.removeprefix(_MEETING_TEMP_PREFIX).split("-", 1)[0]
        if not owner.isdecimal():
            continue
        try:
            os.kill(int(owner), 0)
        except OSError as exc:
            if exc.errno != errno.ESRCH:
                continue
        else:
            continue
        try:
            os.unlink(entry.path)
        except OSError:
            log.warning("could not remove orphaned meeting conversion %s", entry.path)


def _required_meeting_bytes(duration_s: float) -> int:
    """Reserve the computed converted PCM and its CAF header."""
    return math.ceil(duration_s * _CONVERTED_BYTES_PER_SECOND) + _CONVERTED_CAF_HEADER_BYTES


def _caf_chunks(source: BinaryIO, size: int):
    """Walk CAF headers without treating PCM bytes as a chunk-header guess."""
    source.seek(0)
    if source.read(4) != b"caff":
        return
    offset = 8
    while offset + 12 <= min(size, _MAX_CAF_OVERHEAD_BYTES):
        source.seek(offset)
        header = source.read(12)
        if len(header) != 12:
            return
        kind = header[:4]
        chunk_size = int.from_bytes(header[4:], "big", signed=True)
        data_start = offset + 12
        next_offset = data_start + chunk_size
        last = chunk_size < 0 or next_offset + 12 > size
        yield kind, chunk_size, data_start, last
        if last or chunk_size < 0 or next_offset > size:
            return
        offset = next_offset


def _recover_caf_info(source: BinaryIO, size: int) -> SimpleNamespace:
    """Validate PCM CAF metadata when a stale data length defeats libsndfile."""
    descriptor = None
    for kind, chunk_size, data_start, last in _caf_chunks(source, size):
        if kind == b"desc" and chunk_size == _CAF_DESC_BYTES:
            source.seek(data_start)
            raw = source.read(_CAF_DESC_BYTES)
            if len(raw) != _CAF_DESC_BYTES:
                break
            descriptor = struct.unpack(_CAF_DESC_FORMAT, raw)
        if kind == b"data" and descriptor is not None:
            rate, fmt, flags, packet_bytes, packet_frames, channels, bits = descriptor
            sample_bytes = bits // 8
            float_pcm = bool(flags & _CAF_FLOAT_FLAG)
            # Accept only CAF float widths the device capture can produce.
            if float_pcm:
                if bits == _CAF_FLOAT_BITS:
                    subtype = "FLOAT"
                elif bits == _CAF_DOUBLE_BITS:
                    subtype = "DOUBLE"
                else:
                    subtype = ""
            else:
                subtype = f"PCM_{bits}"
            if (fmt != _CAF_LINEAR_PCM or bits % 8 or
                    subtype not in _MEETING_PCM_SAMPLE_BYTES or
                    not math.isfinite(rate) or rate <= 0 or int(rate) != rate or
                    packet_frames != 1 or channels < 1 or
                    packet_bytes != channels * sample_bytes):
                raise ValueError("unsupported CAF description")
            physical_bytes = max(0, size - data_start - 4)
            declared_bytes = max(0, chunk_size - 4)
            if last and declared_bytes != physical_bytes:
                log.warning("CAF data size mismatch: declared=%d physical=%d", declared_bytes, physical_bytes)
            frames = (physical_bytes if last else min(physical_bytes, declared_bytes)) // packet_bytes
            return SimpleNamespace(
                format="CAF", frames=frames, samplerate=int(rate),
                channels=channels, subtype=subtype,
            )
    raise ValueError("incomplete CAF header")


def _check_meeting_space(required: int) -> None:
    """A shortfall is temporary; it does not prove audio is unsupported."""
    try:
        free = shutil.disk_usage(_meeting_temp_dir()).free
    except OSError as exc:
        raise TransientMediaError(f"free disk space could not be checked ({exc})") from exc
    if free < required:
        raise TransientMediaError("not enough free disk space to convert meeting audio")


def _check_cancel(cancel: Callable[[], bool]) -> None:
    """Stop each bounded step before it can read or write more audio."""
    if cancel():
        raise TransientMediaError("meeting audio cancelled")


def _run_core_audio(
    args: list[str], timeout: float, *,
    cancel: Callable[[], bool],
) -> tuple[int, bytes, bytes]:
    """Poll Core Audio so cancel takes at most one poll plus process reap."""
    # After engine SIGKILL an afconvert child can keep writing to its
    # unlinked output inode until that child exits.
    process = subprocess.Popen(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    try:
        while True:
            _check_cancel(cancel)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(args, timeout)
            try:
                stdout, stderr = process.communicate(timeout=min(
                    remaining, _MEETING_CONVERT_POLL_S))
                return process.returncode, stdout, stderr
            except subprocess.TimeoutExpired:
                continue
    finally:
        if process.returncode is None:
            process.kill()
            process.communicate(timeout=_MEETING_CONVERT_REAP_S)


def _m4a_duration_s(
    src: Path, *, cancel: Callable[[], bool],
) -> float:
    """Read Core Audio's duration before reserving converted PCM space."""
    try:
        returncode, stdout, stderr = _run_core_audio(
            ["afinfo", "-r", str(src)], _AFCONVERT_TIMEOUT_S,
            cancel=cancel,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise TransientMediaError(f"meeting audio duration could not be read ({exc})") from exc
    if returncode < 0:
        raise TransientMediaError(f"meeting audio duration process exited on signal {-returncode}")
    match = _AFINFO_DURATION.search(stdout)
    if returncode != 0 or match is None:
        detail = (_AFINFO_NO_DURATION if returncode == 0 else
                  (stderr or stdout or b"").decode("utf-8", "replace").strip())
        if returncode > 0 and detail == _AFINFO_OPEN_ERROR:
            # afinfo has one generic error; the bounded input-open probe
            # identifies measured bad bytes without accepting output faults.
            try:
                probe_code, probe_out, probe_err = _run_core_audio(
                    ["afconvert", "-f", "caff", "-d", f"LEI16@{SAMPLE_RATE}",
                     "-c", "1", str(src), os.devnull],
                    _M4A_PROBE_TIMEOUT_S, cancel=cancel)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise TransientMediaError(f"meeting audio probe failed ({exc})") from exc
            probe = (probe_err or probe_out or b"").decode("utf-8", "replace").strip()
            combined = f"{detail} | {probe}"
            if probe_code > 0 and combined in _INPUT_ERRORS["afinfo"]:
                detail = combined
        raise _CoreAudioFailure("afinfo", returncode, detail)
    try:
        duration = float(match.group(1))
    except ValueError as exc:
        raise _CoreAudioFailure("afinfo", returncode, "invalid duration") from exc
    if not math.isfinite(duration) or duration < 0:
        raise _CoreAudioFailure("afinfo", returncode, "invalid duration")
    return duration


def _take_failure(path: Path | None) -> dict | None:
    """Consume the prior strike before work; any other outcome breaks it."""
    if path is None:
        return None
    try:
        previous = json.loads(path.read_text())
    except (OSError, ValueError):
        previous = None
    try:
        path.unlink(missing_ok=True)
    except OSError as exc:
        raise TransientMediaError(f"meeting failure state could not be cleared ({exc})") from exc
    return previous if isinstance(previous, dict) else None


def sweep_meeting_failures(directory: Path) -> None:
    """Retire strikes left by deleted meetings or interrupted retries."""
    if not directory.exists():
        return
    now = time.time()
    paths = [*directory.glob(f"*{MEETING_FAILURE_SUFFIX}"),
             *directory.glob("*.failure.tmp")]
    for path in paths:
        try:
            if path.name.endswith(".failure.tmp"):
                path.unlink(missing_ok=True)
                continue
            data = json.loads(path.read_text())
            expires = data.get("expires_at") if isinstance(data, dict) else None
            if not isinstance(expires, (int, float)) or not now <= expires:
                path.unlink(missing_ok=True)
        except (ValueError, UnicodeDecodeError):
            log.warning("invalid meeting failure state %s", path)
            try:
                path.unlink(missing_ok=True)
            except OSError:
                log.warning("could not remove meeting failure state %s", path)
        except OSError:
            log.warning("could not sweep meeting failure state %s", path)


def _convert_timeout(duration_s: float | None) -> float:
    """Use the same duration-scaled bound for conversion and retry history."""
    return _AFCONVERT_TIMEOUT_S if duration_s is None else max(
        _AFCONVERT_TIMEOUT_S, duration_s * _MEETING_CONVERT_TIMEOUT_RATIO)


def _repeat_failure(
    path: Path | None, identity: tuple[int, int, int, int],
    error: _CoreAudioFailure, previous: dict | None,
    duration_s: float | None,
) -> bool:
    """Persist one failure atomically beside the cached meeting plan."""
    if path is None:
        return False
    signature = " ".join(error.output.split())
    current = {
        "identity": identity, "step": error.step,
        "returncode": error.returncode, "signature": signature,
    }
    now = time.time()
    if (isinstance(previous, dict)
            and all(previous.get(key) == value for key, value in
                    {**current, "identity": list(identity)}.items())
            and isinstance(previous.get("expires_at"), (int, float))
            and now <= previous["expires_at"]):
        return True
    # afinfo-open failures use the 1,320 s floor: measured 10 h conversion
    # took about 12 s, leaving roughly 100x headroom for sibling reloads.
    current["expires_at"] = now + (
        _MEETING_LOAD_RETRIES * _MEETING_LOAD_RETRY_INTERVAL_S
        + _FAILURE_STRIKE_MARGIN_S
        + 2 * _convert_timeout(duration_s)
    )
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(current))
        tmp.replace(path)
    except OSError as exc:
        raise TransientMediaError(f"meeting failure state could not be saved ({exc})") from exc
    return False


def _reject_conversion(
    src: Path, identity: tuple[int, int, int, int], required: int,
    error: ValueError, failure_path: Path | None,
    previous: dict | None,
    duration_s: float | None,
) -> NoReturn:
    """Skip only a repeated deterministic failure on unchanged bytes."""
    _require_unchanged(src, identity, "conversion")
    _check_meeting_space(required)
    if isinstance(error, _CoreAudioFailure):
        # Only observed input-open rejections can count as decode evidence.
        # Numeric I/O failures on either side remain retryable.
        no_duration = (error.step == "afinfo" and error.returncode == 0 and
                       error.output == _AFINFO_NO_DURATION)
        input_error = (error.returncode > 0 and
                       error.output in _INPUT_ERRORS.get(error.step, ()))
        if (no_duration or input_error) and _repeat_failure(
                failure_path, identity, error, previous, duration_s):
            raise ValueError(f"unsupported or unreadable meeting audio ({error})") from error
    raise TransientMediaError(f"meeting audio could not be converted ({error})") from error


def _convert_meeting(
    src: Path, duration_s: float | None,
    *, cancel: Callable[[], bool],
) -> MeetingAudio:
    """Convert one app-owned track on disk; the returned reader owns cleanup."""
    fd, tmp_name = tempfile.mkstemp(
        suffix=".caf", prefix=f"{_MEETING_TEMP_PREFIX}{os.getpid()}-",
        dir=_meeting_temp_dir())
    os.close(fd)
    tmp = Path(tmp_name)
    timeout = _convert_timeout(duration_s)
    try:
        returncode, stdout, stderr = _run_core_audio(
            ["afconvert", "-f", "caff", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1",
             str(src), str(tmp)], timeout,
            cancel=cancel,
        )
        if returncode != 0:
            detail = (stderr or stdout or b"").decode("utf-8", "replace").strip()
            raise _CoreAudioFailure("afconvert", returncode,
                                    detail.splitlines()[-1] if detail else "")
        return MeetingAudio(tmp)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def _load_converted(
    src: Path, identity: tuple[int, int, int, int], duration_s: float,
    failure_path: Path | None, previous: dict | None,
    *, cancel: Callable[[], bool],
) -> MeetingAudio:
    """Reserve decoded space and give CAF and M4A the same conversion verdict."""
    reserved = _required_meeting_bytes(duration_s) + _CONVERT_FREE_SPACE_MARGIN_BYTES
    _check_meeting_space(reserved)
    try:
        track = _convert_meeting(src, duration_s, cancel=cancel)
    except subprocess.TimeoutExpired as exc:
        raise TransientMediaError("meeting audio conversion timed out") from exc
    except (OSError, RuntimeError) as exc:
        # Spawn, output and read-back faults say nothing about source bytes.
        raise TransientMediaError(f"meeting audio could not be converted ({exc})") from exc
    except ValueError as exc:
        _reject_conversion(src, identity, reserved, exc, failure_path,
                           previous, duration_s)
    try:
        _require_unchanged(src, identity, "conversion")
    except TransientMediaError:
        track.close()
        raise
    return track


def _read_wav_16k(path: Path) -> np.ndarray:
    """Stream-decode the converter's WAV into one float32 buffer.

    An hour of audio is ~115 MB of int16; reading it whole and then
    converting held ~3× the track in transient copies on every meeting.
    Block reads bound the overhead to one block."""
    with wave.open(str(path), "rb") as w:
        if (w.getframerate() != SAMPLE_RATE or w.getsampwidth() != 2
                or w.getnchannels() != 1):
            raise ValueError(f"unexpected wav format from converter: {w.getframerate()}Hz")
        total = w.getnframes()
        # The frame count is header-declared, untrusted data — check the
        # duration cap BEFORE allocating a buffer sized from it.
        if total > MAX_DURATION_S * SAMPLE_RATE:
            raise ValueError("audio longer than 4 hours")
        pcm = np.empty(total, dtype=np.float32)
        filled = 0
        block = 10 * 60 * SAMPLE_RATE  # ~18 MB of int16 per read
        while filled < total:
            frames = w.readframes(min(block, total - filled))
            # Truncated container: a cut mid-sample yields an odd byte count
            # that frombuffer would reject — drop the half sample and keep
            # every fully decoded one.
            usable = len(frames) - (len(frames) % 2)
            if not usable:
                break
            chunk = np.frombuffer(frames[:usable], dtype="<i2")
            pcm[filled : filled + len(chunk)] = chunk
            filled += len(chunk)
    # A short read means the slice would otherwise retain the full allocation
    # declared by a corrupt/truncated header.
    if filled < total:
        pcm = pcm[:filled].copy()
    pcm /= 32768.0
    return pcm


def _load_via_afconvert(src: Path) -> np.ndarray:
    fd, tmp_name = tempfile.mkstemp(suffix=".wav", prefix="velora-media-")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        proc = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1",
             str(src), str(tmp)],
            capture_output=True,
            timeout=_AFCONVERT_TIMEOUT_S,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or b"").decode("utf-8", "replace").strip()
            raise ValueError(f"afconvert failed: {detail.splitlines()[-1] if detail else proc.returncode}")
        return _read_wav_16k(tmp)
    finally:
        tmp.unlink(missing_ok=True)


def _load_via_soundfile(src: Path) -> np.ndarray:
    try:
        import soundfile as sf
    except ImportError as exc:  # pragma: no cover — soundfile ships with the engine
        raise ValueError("no decoder available for this format") from exc
    info = sf.info(str(src))
    try:
        frames = int(info.frames)
        sample_rate = int(info.samplerate)
        channels = int(info.channels)
    except (TypeError, ValueError, AttributeError) as exc:
        raise ValueError("unsupported audio metadata") from exc
    if frames < 0 or sample_rate <= 0 or channels <= 0:
        raise ValueError("unsupported audio metadata")
    if sample_rate > _MAX_GENERIC_SAMPLE_RATE:
        raise ValueError("unsupported audio sample rate")
    if channels > _MAX_GENERIC_CHANNELS:
        raise ValueError("unsupported audio channel count")
    if frames > MAX_DURATION_S * sample_rate:
        raise ValueError("audio longer than 4 hours")
    output_frames = int(round(frames * SAMPLE_RATE / sample_rate))
    if output_frames == 0:
        return np.empty(0, dtype=np.float32)

    # Decode and linearly resample bounded windows. The former whole-file path
    # could pass the 2 GiB float32 check and then allocate several additional
    # float64 coordinate/interpolation arrays. Keep source blocks under 64 MiB
    # and output-coordinate blocks under one minute while retaining one-sample
    # overlap through global source positions.
    source_frames_per_block = max(
        2,
        _SOUNDFILE_SOURCE_BLOCK_BYTES
        // (channels * np.dtype(np.float32).itemsize),
    )
    output_block = min(
        _SOUNDFILE_OUTPUT_BLOCK_S * SAMPLE_RATE,
        max(
            1,
            (source_frames_per_block - 2) * SAMPLE_RATE // sample_rate,
        ),
    )
    output = np.empty(output_frames, dtype=np.float32)
    with sf.SoundFile(str(src), mode="r") as source:
        if (
            int(source.samplerate) != sample_rate
            or int(source.channels) != channels
            or len(source) != frames
        ):
            raise ValueError("audio changed during decode")
        ratio = sample_rate / SAMPLE_RATE
        for output_start in range(0, output_frames, output_block):
            output_end = min(output_start + output_block, output_frames)
            source_positions = np.arange(
                output_start, output_end, dtype=np.float64
            )
            source_positions *= ratio
            source_indexes = source_positions.astype(np.int64)
            np.minimum(source_indexes, frames - 1, out=source_indexes)
            fractions = (source_positions - source_indexes).astype(np.float32)
            next_indexes = np.minimum(source_indexes + 1, frames - 1)
            source_start = int(source_indexes[0])
            source_end = int(next_indexes[-1]) + 1
            source.seek(source_start)
            decoded = source.read(
                source_end - source_start,
                dtype="float32",
                always_2d=True,
            )
            if len(decoded) != source_end - source_start:
                raise ValueError("audio changed or truncated during decode")
            mono = (
                decoded[:, 0]
                if channels == 1
                else np.mean(decoded, axis=1, dtype=np.float32)
            )
            local_indexes = source_indexes - source_start
            local_next = next_indexes - source_start
            left = mono[local_indexes]
            output[output_start:output_end] = left + (
                mono[local_next] - left
            ) * fractions
    return output


def _finish_pcm(pcm: np.ndarray) -> np.ndarray:
    if len(pcm) > MAX_DURATION_S * SAMPLE_RATE:
        raise ValueError("audio longer than 4 hours")
    # Check in bounded windows. np.isfinite over a four-hour canonical track
    # otherwise creates a second ~230 MB boolean allocation just to validate
    # the converter output.
    block = 10 * 60 * SAMPLE_RATE
    for start in range(0, len(pcm), block):
        chunk = pcm[start : start + block]
        if np.all(np.isfinite(chunk)):
            continue
        if not pcm.flags.writeable:
            pcm = pcm.copy()
            chunk = pcm[start : start + block]
        np.nan_to_num(chunk, copy=False)
    return pcm


def load_media(path: str) -> np.ndarray:
    """Decode `path` to float32 mono 16 kHz. Raises ValueError with a concise,
    user-showable message on anything unreadable.

    Arbitrary imports use the conservative default. App-owned meeting capture
    uses load_meeting_media(), which validates its CAF metadata before decode.
    """
    src = Path(path)
    if not src.is_file():
        raise ValueError("file not found")
    if src.stat().st_size > MAX_FILE_BYTES:
        raise ValueError("file too large (over 2 GB)")
    try:
        pcm = _load_via_afconvert(src)
    except (ValueError, subprocess.TimeoutExpired, OSError) as exc:
        log.info("afconvert path failed (%s); trying soundfile", exc)
        try:
            pcm = _load_via_soundfile(src)
        except Exception as sf_exc:  # noqa: BLE001 — collapse to one user-facing error
            # A converter that timed out or could not run never judged
            # the file (soundfile cannot read AAC, so it fails anyway).
            if not isinstance(exc, ValueError):
                raise TransientMediaError(
                    f"audio could not be converted ({exc})") from exc
            raise ValueError(f"unsupported or unreadable audio file ({sf_exc})") from sf_exc
    return _finish_pcm(pcm)


def load_meeting_media(
    path: str, *, meeting_root: Path,
    cancel: Callable[[], bool],
    failure_path: Path | None = None,
) -> MeetingAudio:
    """Decode Velora-owned meeting audio under ``meeting_root``.

    Meeting capture writes device-native PCM, so raw bytes are not a
    stable duration bound (48 vs 96 kHz doubles the same meeting's size).
    Trust only CAF metadata inside Velora's own storage, validate that metadata
    against the file size, then convert once on disk. Slices of the converted
    track are decoded on demand, including for legacy ``them.m4a`` files.
    """
    # Consume the prior record first. Any attempt that does not reproduce its
    # deterministic failure leaves no strike behind, including cancellation.
    previous_failure = _take_failure(failure_path)
    try:
        src = Path(path).resolve(strict=True)
        root = meeting_root.resolve(strict=True)
    except FileNotFoundError as exc:
        raise ValueError("file not found") from exc
    except OSError as exc:
        raise TransientMediaError(f"meeting audio could not be opened ({exc})") from exc
    if not src.is_file():
        raise ValueError("file not found")
    try:
        src.relative_to(root)
    except ValueError as exc:
        raise ValueError("meeting audio is outside Velora storage") from exc

    if src.suffix.lower() == ".m4a":
        # Legacy compressed captures use Core Audio duration metadata. The
        # decoded PCM size, not compressed input bytes, sets disk demand.
        try:
            identity = _source_identity(src.stat())
        except OSError as exc:
            raise TransientMediaError(f"meeting audio could not be opened ({exc})") from exc
        try:
            duration_s = _m4a_duration_s(src, cancel=cancel)
        except _CoreAudioFailure as exc:
            _reject_conversion(src, identity, _CONVERT_FREE_SPACE_MARGIN_BYTES,
                               exc, failure_path, previous_failure,
                               None)
        if duration_s == 0:
            # An empty finalized container has no speech and needs no output.
            _require_unchanged(src, identity, "validation")
            raise MeetingTrackTooShort("audio is too short to transcribe")
        return _load_converted(src, identity, duration_s, failure_path,
                               previous_failure, cancel=cancel)
    if src.suffix.lower() != ".caf":
        raise ValueError("unsupported meeting audio format")

    # Parse CAF once from the open source; physical data bytes determine the
    # usable frames even when a killed writer left an unfinished size field.
    try:
        source = src.open("rb")
    except OSError as exc:
        raise TransientMediaError(f"meeting audio could not be opened ({exc})") from exc
    with source:
        try:
            initial_identity = _source_identity(os.fstat(source.fileno()))
            info = _recover_caf_info(source, initial_identity[2])
        except OSError as exc:
            raise TransientMediaError(
                f"meeting audio could not be opened ({exc})") from exc
        except ValueError as exc:
            # A writer may replace or extend the header during validation.
            _require_unchanged(src, initial_identity, "validation")
            raise ValueError(f"unsupported or unreadable meeting audio ({exc})") from exc
    # A header read mid-write can describe any format or length, so the
    # file must be known stable before its metadata can reject it.
    _require_unchanged(src, initial_identity, "validation")

    if (info.samplerate > _MAX_MEETING_SAMPLE_RATE or
            info.channels not in (1, 2) or info.frames < 0):
        raise ValueError("unsupported meeting audio format")
    duration_s = info.frames / info.samplerate
    return _load_converted(src, initial_identity, duration_s, failure_path,
                           previous_failure, cancel=cancel)


def _source_identity(stat: os.stat_result) -> tuple[int, int, int, int]:
    """The fields that change when a file is replaced, grows or is rewritten."""
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)


def _require_unchanged(
    src: Path, identity: tuple[int, int, int, int], stage: str
) -> os.stat_result:
    """Return `src`'s stat, or raise TransientMediaError unless it is still
    the file `identity` describes: gone, unreadable or changed all mean
    "read it again later"."""
    try:
        current = src.stat()
    except OSError as exc:
        raise TransientMediaError(f"meeting audio could not be opened ({exc})") from exc
    if _source_identity(current) != identity:
        raise TransientMediaError(f"meeting audio changed during {stage}")
    return current


def plan_meeting_slices(
    track: MeetingAudio, sample_rate: int = SAMPLE_RATE,
    *, cancel: Callable[[], bool],
) -> list[tuple[int, int]]:
    """Plan the same quiet seams as batch split using only search windows."""
    return _plan_spans(
        len(track), lambda a, b: track.read(a, b, cancel=cancel),
        _MEETING_TARGET_S, _MEETING_SEARCH_S, sample_rate, cancel=cancel)


def batch_ranges(
    sample_count: int,
    read_span: Callable[[int, int], np.ndarray],
    target_s: float = 60.0,
    search_s: float = 15.0,
    sample_rate: int = SAMPLE_RATE,
) -> list[tuple[int, int]]:
    """Plan quiet-boundary windows using only a short span around each seam."""
    # Short clips stay whole, matching split_for_batch's identity contract.
    if sample_count <= int(target_s * sample_rate) + _MEETING_TAIL_S * sample_rate:
        return [(0, sample_count)]
    return _plan_spans(
        sample_count, read_span, target_s, search_s, sample_rate,
        cancel=lambda: False)


def _plan_spans(
    total: int, read: Callable[[int, int], np.ndarray],
    target_s: float, search_s: float, sample_rate: int,
    *, cancel: Callable[[], bool],
) -> list[tuple[int, int]]:
    """Choose each quiet cut once for in-memory and file-backed audio."""
    step = int(target_s * sample_rate)
    tail = _MEETING_TAIL_S * sample_rate
    spans = []
    start = 0
    _check_cancel(cancel)
    while total - start > step + tail:
        _check_cancel(cancel)
        end = start + step
        cut = quietest_cut(end, read, search_s, sample_rate)
        spans.append((start, cut))
        start = cut
    spans.append((start, total))
    return spans


def quietest_cut(
    end: int, read_span: Callable[[int, int], np.ndarray],
    search_s: float, sample_rate: int,
) -> int:
    """Pick the lowest-energy 0.3 s seam in the search window before `end`."""
    search = int(search_s * sample_rate)
    win = int(_MEETING_ENERGY_WINDOW_S * sample_rate)
    segment = read_span(end - search, end).astype(np.float64)
    # Preserve base's float64 rolling-energy arithmetic and tie order.
    squared = segment * segment
    cumulative = np.empty(len(squared) + 1, dtype=np.float64)
    cumulative[0] = 0
    np.cumsum(squared, out=cumulative[1:])
    energy = cumulative[win:] - cumulative[:-win]
    return end - search + int(np.argmin(energy)) + win // 2


def split_for_batch(
    pcm: np.ndarray,
    target_s: float = 60.0,
    search_s: float = 15.0,
    sample_rate: int = SAMPLE_RATE,
) -> list[np.ndarray]:
    """Split a long clip into ~target_s chunks cut at the quietest moment near
    each boundary, so batch decodes don't slice through words. Short clips
    (≤ target + 30 s) come back whole. Chunks concatenate to the original.
    """
    if len(pcm) <= int(target_s * sample_rate) + _MEETING_TAIL_S * sample_rate:
        return [pcm]
    # A shared plan keeps v3 cursor seams and dictation windows identical.
    return [pcm[start:end] for start, end in batch_ranges(
        len(pcm), lambda a, b: pcm[a:b], target_s, search_s, sample_rate)]
