"""Decode arbitrary audio files to 16 kHz mono float32 (file transcription).

Prefers macOS's built-in `afconvert` (m4a/mp3/aac/alac/wav/aiff/caf with
proper sample-rate conversion — covers Voice Memos and meeting recordings);
falls back to soundfile (ogg/flac/opus) with linear resampling when afconvert
can't read the file. No third-party ffmpeg dependency.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

log = logging.getLogger("velora.media")

SAMPLE_RATE = 16000
# Keep arbitrary imports tightly bounded. App-owned meeting CAFs have a
# separate trusted-header path because their native PCM rate is device-defined.
MAX_FILE_BYTES = 2 * 1024**3
MAX_DURATION_S = 4 * 3600
_AFCONVERT_TIMEOUT_S = 600
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
# afconvert writes a 16 kHz Int16 WAV to the temp dir before it is read back.
_CONVERTED_BYTES_PER_SECOND = SAMPLE_RATE * 2
# Room kept free beyond that WAV, so conversion never fills the disk.
_CONVERT_FREE_SPACE_MARGIN_BYTES = 256 * 1024**2


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


def load_meeting_media(path: str, *, meeting_root: Path) -> np.ndarray:
    """Decode Velora-owned meeting audio under ``meeting_root``.

    Meeting capture writes device-native PCM, so raw bytes are not a
    stable duration bound (48 vs 96 kHz doubles the same meeting's size).
    Trust only CAF metadata inside Velora's own storage, validate that metadata
    against the file size and four-hour contract, then use the streaming macOS
    converter. There is deliberately no soundfile payload fallback: it would
    materialize multi-gigabyte native PCM in memory. Legacy ``them.m4a`` files
    remain supported through the conservative generic loader.
    """
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
        return load_media(str(src))
    if src.suffix.lower() != ".caf":
        raise ValueError("unsupported meeting audio format")

    # Metadata is read from the same open file whose identity is recorded,
    # so libsndfile never opens a second copy by path. A failed open (the
    # file vanished, too many open files) is the moment, not the file.
    try:
        source = src.open("rb")
    except OSError as exc:
        raise TransientMediaError(f"meeting audio could not be opened ({exc})") from exc
    with source:
        try:
            initial_identity = _source_identity(os.fstat(source.fileno()))
            import soundfile as sf

            info = sf.info(source)
        except OSError as exc:
            raise TransientMediaError(
                f"meeting audio could not be opened ({exc})") from exc
        except Exception as exc:  # noqa: BLE001 — concise user-facing failure
            # A header caught mid-write, or a file replaced or removed while
            # libsndfile read it, fails to parse too. Only a file that stayed
            # put is rejected for good.
            _require_unchanged(src, initial_identity, "validation")
            raise ValueError(f"unsupported or unreadable meeting audio ({exc})") from exc
    # A header read mid-write can describe any format or length, so the
    # file must be known stable before its metadata can reject it.
    validated_stat = _require_unchanged(src, initial_identity, "validation")

    try:
        frames = int(info.frames)
        sample_rate = int(info.samplerate)
        channels = int(info.channels)
    except (TypeError, ValueError, AttributeError) as exc:
        raise ValueError("unsupported or unreadable meeting audio metadata") from exc
    sample_bytes = _MEETING_PCM_SAMPLE_BYTES.get(
        str(getattr(info, "subtype", "")).upper())
    if (
        str(getattr(info, "format", "")).upper() != "CAF"
        or sample_bytes is None
        or frames < 0
        or sample_rate <= 0
        or sample_rate > _MAX_MEETING_SAMPLE_RATE
        or channels not in (1, 2)
    ):
        raise ValueError("unsupported meeting audio format")
    if frames > MAX_DURATION_S * sample_rate:
        raise ValueError("audio longer than 4 hours")
    # Velora writes uncompressed PCM CAF. An oversized container relative
    # to its declared frames is corrupt or not app-owned; reject it before the
    # converter can turn an understated header into unbounded temp-file work.
    declared_pcm_bytes = frames * channels * sample_bytes
    if validated_stat.st_size > declared_pcm_bytes + _MAX_CAF_OVERHEAD_BYTES:
        raise ValueError("meeting audio size does not match its header")

    # afconvert on a full disk exits non-zero just like a decode rejection,
    # which would skip a good track, so check the room for its WAV first.
    # Example: a one-hour track needs ~115 MB plus the margin.
    converted_bytes = (
        frames * _CONVERTED_BYTES_PER_SECOND // sample_rate
        + _CONVERT_FREE_SPACE_MARGIN_BYTES
    )
    try:
        free_bytes = shutil.disk_usage(tempfile.gettempdir()).free
    except OSError as exc:
        raise TransientMediaError(f"free disk space could not be checked ({exc})") from exc
    if free_bytes < converted_bytes:
        raise TransientMediaError("not enough free disk space to convert meeting audio")

    try:
        pcm = _load_via_afconvert(src)
    except subprocess.TimeoutExpired as exc:
        raise TransientMediaError("meeting audio conversion timed out") from exc
    except OSError as exc:
        # The temp file, the spawn or the read-back failed, not the decode.
        raise TransientMediaError(f"meeting audio could not be converted ({exc})") from exc
    except ValueError as exc:
        # afconvert also rejects a file that changed or vanished under it.
        _require_unchanged(src, initial_identity, "conversion")
        raise ValueError(f"unsupported or unreadable meeting audio ({exc})") from exc
    _require_unchanged(src, initial_identity, "conversion")
    return _finish_pcm(pcm)


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
    step = int(target_s * sample_rate)
    tail_min = 30 * sample_rate
    if len(pcm) <= step + tail_min:
        return [pcm]
    search = int(search_s * sample_rate)
    win = int(0.3 * sample_rate)
    chunks: list[np.ndarray] = []
    start = 0
    while len(pcm) - start > step + tail_min:
        end = start + step
        # Quietest 0.3 s window inside the last `search_s` of the chunk.
        seg = pcm[end - search : end].astype(np.float64)
        # Rolling window energy in O(n). `np.convolve` with a 4,800-sample
        # boxcar is O(n*m) and made hour-long meeting tracks spend minutes just
        # finding chunk boundaries before Whisper even started.
        squared = seg * seg
        cumulative = np.empty(len(squared) + 1, dtype=np.float64)
        cumulative[0] = 0
        np.cumsum(squared, out=cumulative[1:])
        energy = cumulative[win:] - cumulative[:-win]
        cut = end - search + int(np.argmin(energy)) + win // 2
        chunks.append(pcm[start:cut])
        start = cut
    chunks.append(pcm[start:])
    return chunks
