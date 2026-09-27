"""File-transcription media decoding + batch splitting (pure + afconvert)."""

import time
import types
import wave
import shutil
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from velora_engine.media import (
    MAX_DURATION_S,
    MeetingAudio,
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


def _expected_track(tmp_path: Path) -> MeetingAudio:
    """Use the production converted-file owner in loader success tests."""
    path = tmp_path / "expected-converted.caf"
    sf.write(str(path), np.zeros(SAMPLE_RATE, dtype=np.float32), SAMPLE_RATE,
             format="CAF", subtype="PCM_16")
    return MeetingAudio(path)


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


def test_native_four_hours(tmp_path, monkeypatch):
    """A sparse four-hour CAF passes the meeting path's duration gate."""
    import soundfile as sf
    from velora_engine import media

    root = tmp_path / "meetings"
    root.mkdir()
    src = root / "long-meeting.caf"
    sf.write(str(src), np.zeros((1, 2), dtype=np.float32), 96_000,
             format="CAF", subtype="FLOAT")
    raw = bytearray(src.read_bytes())
    data = raw.index(b"data")
    raw[data + 4:data + 12] = (-1).to_bytes(8, "big", signed=True)
    src.write_bytes(raw)
    with src.open("r+b") as output:
        output.truncate(data + 16 + MAX_DURATION_S * 96_000 * 2 * 4)
    expected = _expected_track(tmp_path)
    monkeypatch.setattr(media, "_convert_meeting", lambda _src, _duration, **_kw: expected)

    with pytest.raises(ValueError, match=r"file too large \(over 2 GB\)"):
        load_media(str(src))
    track = load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)
    assert track is expected
    track.close()



def test_load_meeting_media_accepts_legacy_m4a_inside_storage(tmp_path, monkeypatch):
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "them.m4a"
    src.write_bytes(b"legacy compressed meeting")
    alias = meeting_root / "legacy-link.m4a"
    alias.symlink_to(src)
    expected = _expected_track(tmp_path)
    decoded = []

    def fake_load(path, duration, **_kwargs):
        decoded.append((Path(path), duration))
        return expected

    monkeypatch.setattr(media, "_convert_meeting", fake_load)
    monkeypatch.setattr(media, "_m4a_duration_s", lambda _src, **_kwargs: 60)

    pcm = load_meeting_media(str(alias), meeting_root=meeting_root, cancel=lambda: False)

    assert pcm is expected
    assert decoded == [(src.resolve(), 60)]
    pcm.close()


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
@pytest.mark.parametrize("subtype", ["PCM_16", "PCM_24", "PCM_32", "DOUBLE"])
def test_load_meeting_media_decodes_device_native_pcm_caf(tmp_path, subtype):
    """Mic capture writes the input device's native PCM. A USB mic delivers
    Int16, so the 2026-09-14 meeting failed on "unsupported meeting audio
    format" although afconvert decodes every one of these subtypes."""
    import soundfile as sf

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "me.caf"
    sf.write(
        str(src), _tone(0.5, rate=48_000), 48_000,
        format="CAF", subtype=subtype,
    )

    pcm = load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)
    try:
        assert len(pcm) == SAMPLE_RATE // 2
        assert pcm.peak(cancel=lambda: False) > 0.25
    finally:
        pcm.close()


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
def test_caf_metadata_parsed_once(tmp_path, monkeypatch):
    """The one CAF parse uses the already-open recording handle."""
    import soundfile as sf
    from velora_engine import media

    root = tmp_path / "meetings"
    root.mkdir()
    src = root / "them.caf"
    sf.write(str(src), _tone(0.5, rate=48_000), 48_000,
             format="CAF", subtype="FLOAT")
    original = media._recover_caf_info
    sources = []

    def parse(source, size):
        sources.append(source)
        return original(source, size)

    monkeypatch.setattr(media, "_recover_caf_info", parse)
    track = load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)
    try:
        assert len(sources) == 1 and sources[0].closed
        assert len(track) == SAMPLE_RATE // 2
        assert track.peak(cancel=lambda: False) > 0.25
    finally:
        track.close()







def test_caf_rate_guard(tmp_path, monkeypatch):
    """An implausible CAF rate is rejected before conversion."""
    import soundfile as sf
    from velora_engine import media

    root = tmp_path / "meetings"
    root.mkdir()
    src = root / "invalid-rate.caf"
    sf.write(str(src), np.zeros(1, dtype=np.float32), 48_000,
             format="CAF", subtype="FLOAT")
    raw = bytearray(src.read_bytes())
    raw[20:28] = __import__("struct").pack(">d", 768_000.0)
    src.write_bytes(raw)
    monkeypatch.setattr(media, "_convert_meeting",
                        lambda *_a, **_kw: pytest.fail("converter ran"))

    with pytest.raises(ValueError, match="unsupported meeting audio format"):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def test_no_full_native_read(tmp_path, monkeypatch):
    """A converter failure never materializes the entire source."""
    import soundfile as sf
    from velora_engine import media

    root = tmp_path / "meetings"
    root.mkdir()
    src = root / "unreadable.caf"
    sf.write(str(src), np.zeros(48_000, dtype=np.float32), 48_000,
             format="CAF", subtype="FLOAT")
    monkeypatch.setattr(sf, "read", lambda *_a, **_kw: pytest.fail("native read"))
    monkeypatch.setattr(media, "_convert_meeting",
                        lambda *_a, **_kw: _raise(ValueError("decode failed")))

    with pytest.raises(media.TransientMediaError, match="could not be converted"):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def test_load_meeting_media_rejects_source_outside_app_storage(tmp_path):
    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    outside = tmp_path / "outside.caf"
    outside.write_bytes(b"placeholder")

    with pytest.raises(ValueError, match="outside Velora storage"):
        load_meeting_media(str(outside), meeting_root=meeting_root, cancel=lambda: False)




def test_caf_changed_during_parse(tmp_path, monkeypatch):
    """A growing source is retried after its metadata was read."""
    import soundfile as sf
    from velora_engine import media

    root = tmp_path / "meetings"
    root.mkdir()
    src = root / "changing.caf"
    sf.write(str(src), np.zeros(48_000, dtype=np.float32), 48_000,
             format="CAF", subtype="FLOAT")
    original = media._recover_caf_info

    def parse(source, size):
        info = original(source, size)
        _append_to(src)
        return info

    monkeypatch.setattr(media, "_recover_caf_info", parse)
    with pytest.raises(media.TransientMediaError, match="changed during validation"):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def _valid_meeting_caf(tmp_path, monkeypatch):
    """A one-second stereo Float32 CAF whose metadata passes validation."""
    import soundfile as sf

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "them.caf"
    sf.write(str(src), np.zeros((48_000, 2), dtype=np.float32),
             48_000, format="CAF", subtype="FLOAT")
    return src, meeting_root


def _raise(exc):
    raise exc


@pytest.mark.parametrize("failure", [
    __import__("subprocess").TimeoutExpired("afconvert", 600),
    OSError(28, "No space left on device"),
    FileNotFoundError(2, "No such file or directory: 'afconvert'"),
])
def test_load_meeting_media_reports_a_converter_that_could_not_run_as_transient(
    tmp_path, monkeypatch, failure
):
    """A timeout, a spawn failure or a full temp disk says nothing about
    the file. Reporting it as unsupported made the app skip a good track
    for good; a transient error makes it retry."""
    from velora_engine import media

    src, meeting_root = _valid_meeting_caf(tmp_path, monkeypatch)
    monkeypatch.setattr(media, "_convert_meeting", lambda _src, _duration, **_kwargs: _raise(failure))

    with pytest.raises(media.TransientMediaError):
        load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)


def test_load_meeting_media_reports_a_file_changed_during_conversion_as_transient(
    tmp_path, monkeypatch
):
    from velora_engine import media

    expected = _expected_track(tmp_path)
    src, meeting_root = _valid_meeting_caf(tmp_path, monkeypatch)

    def appending_convert(path, _duration, **_kwargs):
        with path.open("ab") as output:
            output.write(b"more")
        return expected

    monkeypatch.setattr(media, "_convert_meeting", appending_convert)

    with pytest.raises(media.TransientMediaError, match="changed during conversion"):
        load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)
    assert expected._source.closed


def test_load_meeting_media_checks_free_disk_before_converting(tmp_path, monkeypatch):
    """afconvert on a full disk exits non-zero exactly like a decode
    rejection, so the room for its WAV is checked first."""
    from velora_engine import media

    src, meeting_root = _valid_meeting_caf(tmp_path, monkeypatch)
    monkeypatch.setattr(
        media.shutil, "disk_usage",
        lambda _path: types.SimpleNamespace(total=1, used=1, free=0))
    monkeypatch.setattr(
        media, "_convert_meeting",
        lambda _src, _duration, **_kwargs: pytest.fail("decoder must not run"),
    )

    with pytest.raises(media.TransientMediaError, match="disk space"):
        load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)


def _append_to(path):
    with path.open("ab") as output:
        output.write(b"still recording")


@pytest.mark.parametrize("mutate", [_append_to, lambda path: path.unlink()])
def test_caf_parse_change_retries(tmp_path, monkeypatch, mutate):
    """A malformed header caught mid-write is a transient read."""
    from velora_engine import media

    src, root = _valid_meeting_caf(tmp_path, monkeypatch)

    def parse(_source, _size):
        mutate(src)
        raise ValueError("incomplete CAF header")

    monkeypatch.setattr(media, "_recover_caf_info", parse)
    with pytest.raises(media.TransientMediaError):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def test_caf_bad_metadata_retries(tmp_path, monkeypatch):
    """Changed bytes take precedence over an invalid parsed header."""
    from velora_engine import media

    src, root = _valid_meeting_caf(tmp_path, monkeypatch)
    original = media._recover_caf_info

    def parse(source, size):
        info = original(source, size)
        _append_to(src)
        info.samplerate = 0
        return info

    monkeypatch.setattr(media, "_recover_caf_info", parse)
    with pytest.raises(media.TransientMediaError):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def test_caf_read_error_retries(tmp_path, monkeypatch):
    """EMFILE during an open-handle CAF parse is transient."""
    from velora_engine import media

    src, root = _valid_meeting_caf(tmp_path, monkeypatch)
    monkeypatch.setattr(media, "_recover_caf_info",
                        lambda *_a: _raise(OSError(24, "Too many open files")))
    with pytest.raises(media.TransientMediaError):
        load_meeting_media(str(src), meeting_root=root, cancel=lambda: False)



def test_load_meeting_media_keeps_a_stable_unparseable_file_permanent(tmp_path):
    """Only a file that stays put and that libsndfile cannot parse is
    unsupported."""
    from velora_engine import media

    meeting_root = tmp_path / "meetings"
    meeting_root.mkdir()
    src = meeting_root / "them.caf"
    src.write_bytes(b"not a caf file" * 64)

    with pytest.raises(ValueError, match="unreadable meeting audio") as rejected:
        load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)
    assert not isinstance(rejected.value, media.TransientMediaError)


@pytest.mark.parametrize("mutate", [_append_to, lambda path: path.unlink()])
def test_load_meeting_media_reports_a_conversion_failure_on_a_changing_file_as_transient(
    tmp_path, monkeypatch, mutate
):
    from velora_engine import media

    src, meeting_root = _valid_meeting_caf(tmp_path, monkeypatch)

    def failing_convert(path, _duration, **_kwargs):
        mutate(path)
        raise ValueError("afconvert failed: 'typ?'")

    monkeypatch.setattr(media, "_convert_meeting", failing_convert)

    with pytest.raises(media.TransientMediaError):
        load_meeting_media(str(src), meeting_root=meeting_root, cancel=lambda: False)


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
