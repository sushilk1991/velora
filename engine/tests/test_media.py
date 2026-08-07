"""File-transcription media decoding + batch splitting (pure + afconvert)."""

import time
import types
import wave
from pathlib import Path

import numpy as np
import pytest

from velora_engine.media import (
    MAX_DURATION_S,
    MAX_FILE_BYTES,
    SAMPLE_RATE,
    load_media,
    load_meeting_media,
    split_for_batch,
)


def _tone(seconds: float, freq: float = 440.0, rate: int = SAMPLE_RATE) -> np.ndarray:
    t = np.arange(int(seconds * rate)) / rate
    return (0.3 * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _write_wav(path: Path, pcm: np.ndarray, rate: int, channels: int = 1) -> None:
    pcm16 = (pcm * 32767.0).astype("<i2")
    if channels == 2:
        pcm16 = np.column_stack([pcm16, pcm16]).ravel()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16.tobytes())


# ---- split_for_batch ----


def test_short_clip_is_one_chunk():
    pcm = _tone(30.0)
    chunks = split_for_batch(pcm)
    assert len(chunks) == 1
    assert chunks[0] is pcm


def test_long_clip_splits_at_silence_and_concatenates():
    # 3 minutes of tone with a clear 2s silence around 55s and 115s.
    pcm = _tone(180.0)
    for at in (55.0, 115.0):
        lo = int(at * SAMPLE_RATE)
        pcm[lo : lo + 2 * SAMPLE_RATE] = 0.0
    chunks = split_for_batch(pcm, target_s=60.0, search_s=15.0)
    assert len(chunks) >= 2
    # Lossless: chunks concatenate to the exact original.
    assert np.array_equal(np.concatenate(chunks), pcm)
    # The first cut lands inside the silent gap, not mid-tone.
    cut = len(chunks[0])
    assert 55 * SAMPLE_RATE <= cut <= 57.5 * SAMPLE_RATE
    # No chunk is degenerate.
    assert all(len(c) >= 20 * SAMPLE_RATE for c in chunks)


def test_split_handles_constant_audio():
    # No silence anywhere — still splits, still lossless.
    pcm = _tone(200.0)
    chunks = split_for_batch(pcm)
    assert len(chunks) >= 2
    assert np.array_equal(np.concatenate(chunks), pcm)


def test_hour_long_track_chunks_in_linear_time_without_copying(tmp_path):
    # Sparse, file-backed zero audio keeps the fixture cheap while exercising
    # every boundary of a real one-hour meeting track. Chunks must remain views
    # into the decoded buffer, not duplicate hundreds of megabytes.
    samples = 60 * 60 * SAMPLE_RATE
    backing = tmp_path / "hour.f32"
    with backing.open("wb") as output:
        output.truncate(samples * np.dtype(np.float32).itemsize)
    pcm = np.memmap(backing, dtype=np.float32, mode="r", shape=(samples,))
    started = time.perf_counter()
    chunks = split_for_batch(pcm)
    elapsed = time.perf_counter() - started
    assert sum(map(len, chunks)) == samples
    assert 40 <= len(chunks) <= 100
    assert all(np.shares_memory(pcm, chunk) for chunk in chunks)
    assert elapsed < 5, f"one-hour boundary scan took {elapsed:.2f}s"


# ---- load_media ----


def test_load_media_missing_file():
    with pytest.raises(ValueError, match="not found"):
        load_media("/nonexistent/velora-test.m4a")


def test_load_meeting_media_accepts_four_hour_96k_native_capture_above_generic_limit(
    tmp_path, monkeypatch
):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "long-meeting.caf"
    with src.open("wb") as output:
        output.truncate(MAX_FILE_BYTES + 1)
    expected = np.zeros(SAMPLE_RATE, dtype=np.float32)
    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            format="CAF", frames=MAX_DURATION_S * 96_000,
            samplerate=96_000, channels=2, subtype="FLOAT",
        )
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)
    monkeypatch.setattr(media, "_load_via_afconvert", lambda _src: expected)

    with pytest.raises(ValueError, match=r"file too large \(over 2 GB\)"):
        load_media(str(src))
    pcm = load_meeting_media(str(src), meeting_root=meeting_root)

    assert pcm is expected


def test_load_meeting_media_accepts_legacy_m4a_inside_storage(tmp_path, monkeypatch):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "them.m4a"
    src.write_bytes(b"legacy compressed meeting")
    alias = meeting_root / "legacy-link.m4a"
    alias.symlink_to(src)
    expected = np.zeros(SAMPLE_RATE, dtype=np.float32)
    decoded = []

    def fake_load(path):
        decoded.append(Path(path))
        return expected

    monkeypatch.setattr(media, "load_media", fake_load)

    pcm = load_meeting_media(str(alias), meeting_root=meeting_root)

    assert pcm is expected
    assert decoded == [src.resolve()]


def test_load_meeting_media_reads_real_float_caf_metadata(tmp_path, monkeypatch):
    import soundfile as sf

    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "me.caf"
    sf.write(
        str(src), _tone(0.1, rate=48_000), 48_000,
        format="CAF", subtype="FLOAT",
    )
    expected = np.zeros(SAMPLE_RATE, dtype=np.float32)
    decoded = []

    def fake_decode(path):
        decoded.append(path)
        return expected

    monkeypatch.setattr(media, "_load_via_afconvert", fake_decode)

    pcm = load_meeting_media(str(src), meeting_root=meeting_root)

    assert pcm is expected
    assert decoded == [src.resolve()]


def test_load_meeting_media_rejects_long_header_before_decode(tmp_path, monkeypatch):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "too-long.caf"
    src.write_bytes(b"placeholder")
    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            format="CAF", frames=(MAX_DURATION_S + 1) * 48_000,
            samplerate=48_000, channels=2, subtype="FLOAT",
        )
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)
    monkeypatch.setattr(
        media, "_load_via_afconvert",
        lambda _src: pytest.fail("decoder must not run"),
    )

    with pytest.raises(ValueError, match="longer than 4 hours"):
        load_meeting_media(str(src), meeting_root=meeting_root)


def test_load_meeting_media_rejects_implausible_sample_rate_before_decode(
    tmp_path, monkeypatch
):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "invalid-rate.caf"
    src.write_bytes(b"placeholder")
    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            format="CAF", frames=1, samplerate=768_000, channels=2,
            subtype="FLOAT",
        )
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)
    monkeypatch.setattr(
        media, "_load_via_afconvert",
        lambda _src: pytest.fail("decoder must not run"),
    )

    with pytest.raises(ValueError, match="unsupported meeting audio format"):
        load_meeting_media(str(src), meeting_root=meeting_root)


def test_load_meeting_media_never_falls_back_to_full_native_read(
    tmp_path, monkeypatch
):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "unreadable.caf"
    src.write_bytes(b"placeholder")
    read_called = False

    def fail_if_read(*_args, **_kwargs):
        nonlocal read_called
        read_called = True
        raise AssertionError("native payload must not be materialized")

    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            format="CAF", frames=48_000, samplerate=48_000, channels=2,
            subtype="FLOAT",
        ),
        read=fail_if_read,
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)
    monkeypatch.setattr(
        media, "_load_via_afconvert",
        lambda _src: (_ for _ in ()).throw(ValueError("decode failed")),
    )

    with pytest.raises(ValueError, match="unreadable meeting audio"):
        load_meeting_media(str(src), meeting_root=meeting_root)
    assert not read_called


def test_load_meeting_media_rejects_source_outside_app_storage(tmp_path):
    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    outside = tmp_path / "outside.caf"
    outside.write_bytes(b"placeholder")

    with pytest.raises(ValueError, match="outside Velora storage"):
        load_meeting_media(str(outside), meeting_root=meeting_root)


def test_load_meeting_media_rejects_container_larger_than_declared_pcm(
    tmp_path, monkeypatch
):
    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "mismatched.caf"
    src.write_bytes(b"0" * (2 * 1024**2))
    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            format="CAF", frames=1, samplerate=48_000, channels=2,
            subtype="FLOAT",
        )
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)

    with pytest.raises(ValueError, match="size does not match"):
        load_meeting_media(str(src), meeting_root=meeting_root)


def test_load_meeting_media_rejects_source_changed_during_validation(
    tmp_path, monkeypatch
):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "changing.caf"
    src.write_bytes(b"placeholder")

    def changing_info(_path):
        with src.open("ab") as output:
            output.write(b"changed")
        return types.SimpleNamespace(
            format="CAF", frames=48_000, samplerate=48_000, channels=2,
            subtype="FLOAT",
        )

    fake = types.SimpleNamespace(info=changing_info)
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)
    monkeypatch.setattr(
        media, "_load_via_afconvert",
        lambda _src: pytest.fail("decoder must not run"),
    )

    with pytest.raises(ValueError, match="changed during validation"):
        load_meeting_media(str(src), meeting_root=meeting_root)


def test_load_media_wav_resamples_to_16k_mono(tmp_path):
    # 44.1kHz stereo in → 16kHz mono float32 out (via afconvert on macOS,
    # soundfile fallback elsewhere).
    src = tmp_path / "clip.wav"
    _write_wav(src, _tone(2.0, rate=44100), rate=44100, channels=2)
    pcm = load_media(str(src))
    assert pcm.dtype == np.float32
    assert pcm.ndim == 1
    assert abs(len(pcm) - 2 * SAMPLE_RATE) < SAMPLE_RATE // 10
    assert float(np.max(np.abs(pcm))) > 0.1


def test_soundfile_fallback_streams_resampling_without_full_file_read(
    tmp_path, monkeypatch
):
    import soundfile as sf

    from velora_engine import media

    src = tmp_path / "clip.flac"
    mono = _tone(3.0, rate=48_000)
    sf.write(str(src), np.column_stack([mono, mono * 0.5]), 48_000)
    decoded_reference, reference_rate = sf.read(
        str(src), dtype="float32", always_2d=True
    )
    real_sound_file = sf.SoundFile
    read_sizes = []

    class TrackedSoundFile:
        def __init__(self, *args, **kwargs):
            self.source = real_sound_file(*args, **kwargs)

        def __enter__(self):
            self.source.__enter__()
            return self

        def __exit__(self, *args):
            return self.source.__exit__(*args)

        def __getattr__(self, name):
            return getattr(self.source, name)

        def __len__(self):
            return len(self.source)

        def read(self, frames, *args, **kwargs):
            read_sizes.append(frames)
            return self.source.read(frames, *args, **kwargs)

    monkeypatch.setattr(
        media, "_load_via_afconvert",
        lambda _src: (_ for _ in ()).throw(ValueError("force fallback")),
    )
    monkeypatch.setattr(media, "_SOUNDFILE_SOURCE_BLOCK_BYTES", 64 * 1024)
    monkeypatch.setattr(sf, "SoundFile", TrackedSoundFile)
    monkeypatch.setattr(
        sf, "read",
        lambda *_args, **_kwargs: pytest.fail("module-level full read must not run"),
    )

    pcm = load_media(str(src))

    assert pcm.dtype == np.float32
    assert pcm.ndim == 1
    assert abs(len(pcm) - 3 * SAMPLE_RATE) < SAMPLE_RATE // 10
    assert float(np.max(np.abs(pcm))) > 0.1
    assert len(read_sizes) > 1
    assert max(read_sizes) * 2 * np.dtype(np.float32).itemsize <= 64 * 1024
    reference_mono = decoded_reference.mean(axis=1)
    reference_positions = (
        np.arange(len(pcm), dtype=np.float64) * reference_rate / SAMPLE_RATE
    )
    expected = np.interp(
        reference_positions,
        np.arange(len(reference_mono), dtype=np.float64),
        reference_mono,
    ).astype(np.float32)
    np.testing.assert_allclose(pcm, expected, atol=1e-6)


def test_load_media_rejects_garbage(tmp_path):
    src = tmp_path / "notaudio.m4a"
    src.write_bytes(b"this is not audio at all" * 100)
    with pytest.raises(ValueError):
        load_media(str(src))


def test_soundfile_rejects_long_header_before_reading_payload(tmp_path, monkeypatch):
    from velora_engine import media

    src = tmp_path / "long.flac"
    src.write_bytes(b"placeholder")
    read_called = False

    def fail_if_read(*_args, **_kwargs):
        nonlocal read_called
        read_called = True
        raise AssertionError("payload must not be read")

    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            frames=(MAX_DURATION_S + 1) * 48_000,
            samplerate=48_000,
            channels=2,
        ),
        read=fail_if_read,
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)

    with pytest.raises(ValueError, match="longer than 4 hours"):
        media._load_via_soundfile(src)
    assert not read_called


def test_soundfile_rejects_excessive_channel_count_before_opening(
    tmp_path, monkeypatch
):
    from velora_engine import media

    src = tmp_path / "many-channels.flac"
    src.write_bytes(b"placeholder")

    fake = types.SimpleNamespace(
        info=lambda _path: types.SimpleNamespace(
            frames=48_000,
            samplerate=48_000,
            channels=9,
        ),
        SoundFile=lambda *_args, **_kwargs: pytest.fail("decoder must not open"),
    )
    monkeypatch.setitem(__import__("sys").modules, "soundfile", fake)

    with pytest.raises(ValueError, match="unsupported audio channel count"):
        media._load_via_soundfile(src)


def test_read_wav_16k_keeps_decoded_samples_from_truncated_container(tmp_path):
    # A crash mid-write can cut the payload mid-sample. The reader must keep
    # every fully decoded sample instead of raising on the odd trailing byte.
    from velora_engine.media import _read_wav_16k

    src = tmp_path / "whole.wav"
    _write_wav(src, _tone(1.0), rate=SAMPLE_RATE)
    data = src.read_bytes()
    truncated = tmp_path / "truncated.wav"
    truncated.write_bytes(data[: len(data) - 3])  # odd byte count in payload

    pcm = _read_wav_16k(truncated)
    assert pcm.dtype == np.float32
    assert pcm.base is None
    # All but the last (half-cut) sample survive.
    assert len(pcm) >= SAMPLE_RATE - 2
    assert float(np.max(np.abs(pcm))) > 0.1


def test_read_wav_16k_rejects_absurd_declared_length_before_allocating(tmp_path):
    from velora_engine.media import _read_wav_16k

    src = tmp_path / "huge.wav"
    _write_wav(src, _tone(0.1), rate=SAMPLE_RATE)
    data = bytearray(src.read_bytes())
    # Patch the data-chunk size to declare ~5 hours of frames.
    absurd = 5 * 3600 * SAMPLE_RATE * 2
    data[4:8] = (absurd + 36).to_bytes(4, "little")
    data[40:44] = absurd.to_bytes(4, "little")
    src.write_bytes(bytes(data))
    with pytest.raises(ValueError):
        _read_wav_16k(src)
