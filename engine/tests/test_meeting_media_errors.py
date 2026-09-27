"""Meeting media failures, cancellation and cleanup remain retryable."""

# The shared engine fixture intentionally uses the same name as test arguments.
# ruff: noqa: F811

import asyncio
import contextlib
import errno
import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import types
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from test_server import connect, engine  # noqa: F401
from velora_engine import media, server


def _track(tmp_path, suffix="caf"):
    root = tmp_path / "meetings"
    root.mkdir()
    path = root / f"track.{suffix}"
    if suffix == "caf":
        # A real CAF exercises the physical-data metadata path.
        sf.write(path, np.zeros(16_000, dtype=np.float32), 16_000,
                 format="CAF", subtype="PCM_16")
    else:
        path.write_bytes(b"legacy")
    return path, root, tmp_path / "meeting-plans" / "job.me.failure.json"


@pytest.mark.parametrize("code,detail,permanent", [
    (1, "Error: Couldn't open input file ('dta?')", True),
    (1, "Error: Couldn't open input file ('typ?')", True),
    (1, "Error: Couldn't open input file ('wht?')", False),
    (1, "Error: ExtAudioFileCreateWithURL failed (-54)", False),
    (1, "Error: Couldn't open input file (-36)", False),
    (1, "Error: ExtAudioFileWrite failed (-40)", False),
    (-9, "", False),
    (-9, "Error: Couldn't open input file ('typ?')", False),
    (1, "Error: ExtAudioFileWrite failed (-34)", False),
    (1, "Error: an unexpected converter failure", False),
])
def test_measured_input_strikes(tmp_path, monkeypatch, code, detail, permanent):
    """Output and numeric I/O failures never become a source verdict."""
    path, root, failure_path = _track(tmp_path)
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", code, detail)))
    for index in range(2):
        with pytest.raises(ValueError) as raised:
            media.load_meeting_media(str(path), meeting_root=root,
                                     failure_path=failure_path,
                                     cancel=lambda: False)
        assert isinstance(raised.value, media.TransientMediaError) is not (permanent and index == 1)
    assert not failure_path.exists()


def test_afinfo_checks_identity(tmp_path, monkeypatch):
    """A compressed recording still being written gets another attempt."""
    source, root, _ = _track(tmp_path, suffix="m4a")

    def fail_duration(path, **_kwargs):
        with path.open("ab") as output:
            output.write(b"new audio")
        raise media._CoreAudioFailure("afinfo", 1, "Fail: AudioFileOpenURL failed")

    monkeypatch.setattr(media, "_m4a_duration_s", fail_duration)
    with pytest.raises(media.TransientMediaError, match="changed during"):
        media.load_meeting_media(str(source), meeting_root=root, cancel=lambda: False)


@pytest.mark.skipif(shutil.which("afconvert") is None or shutil.which("afinfo") is None,
                    reason="Core Audio tools missing")
@pytest.mark.parametrize("payload,signature", [
    (b"", b"('wht?')"),
    (random.Random(74).randbytes(256), b"('typ?')"),
])
def test_afinfo_repeat_skips(tmp_path, payload, signature):
    """Two measured input-open failures reject one unchanged legacy track."""
    root = tmp_path / "meetings"
    root.mkdir()
    source = root / "them.m4a"
    source.write_bytes(payload)
    failure_path = tmp_path / "plans" / "them.failure.json"
    probe = subprocess.run(
        ["afconvert", "-f", "caff", "-d", f"LEI16@{media.SAMPLE_RATE}",
         "-c", "1", str(source), os.devnull],
        capture_output=True, timeout=30)
    assert probe.returncode > 0
    assert probe.stderr.strip().endswith(signature)

    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert failure_path.exists()
    with pytest.raises(ValueError) as rejected:
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert not isinstance(rejected.value, media.TransientMediaError)
    assert not failure_path.exists()


def test_no_duration_strikes(tmp_path, monkeypatch):
    """An afinfo success without duration still gets a two-attempt verdict."""
    source, root, failure_path = _track(tmp_path, "m4a")
    monkeypatch.setattr(media, "_run_core_audio", lambda *_a, **_k: (0, b"", b""))
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert failure_path.exists()
    with pytest.raises(ValueError) as rejected:
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert not isinstance(rejected.value, media.TransientMediaError)
    assert not failure_path.exists()


def test_silent_afinfo_retries(tmp_path, monkeypatch):
    """A silent afinfo failure is unmeasured, so it never counts as a strike."""
    source, root, failure_path = _track(tmp_path, "m4a")
    monkeypatch.setattr(media, "_run_core_audio", lambda *_a, **_k: (1, b"", b""))

    for _attempt in range(2):
        with pytest.raises(media.TransientMediaError):
            media.load_meeting_media(str(source), meeting_root=root,
                                     failure_path=failure_path, cancel=lambda: False)
    assert not failure_path.exists()


@pytest.mark.skipif(shutil.which("afconvert") is None or shutil.which("afinfo") is None,
                    reason="Core Audio tools missing")
def test_corrupt_mdat_strikes(tmp_path):
    """A measured AAC payload error skips unchanged bytes on retry."""
    source, root, failure_path = _track(tmp_path, "m4a")
    wav = tmp_path / "source.wav"
    frames = np.arange(8 * 48_000) / 48_000
    sf.write(str(wav), 0.3 * np.sin(2 * np.pi * 440 * frames), 48_000)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(wav), str(source)],
                   check=True, capture_output=True, timeout=30)
    raw = bytearray(source.read_bytes())
    start = raw.index(b"mdat") + 4
    middle = (start + len(raw)) // 2
    raw[middle - 2048:middle + 2048] = random.Random(74).randbytes(4096)
    source.write_bytes(raw)
    original = (source.read_bytes(), source.stat().st_mtime_ns)
    probe = subprocess.run(
        ["afconvert", "-f", "caff", "-d", f"LEI16@{media.SAMPLE_RATE}",
         "-c", "1", str(source), str(tmp_path / "probe.caf")],
        capture_output=True, timeout=30)
    assert probe.returncode == 1
    assert probe.stderr.strip() == b"Error: ExtAudioFileRead failed ('bada')"

    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    with pytest.raises(ValueError) as rejected:
        media.load_meeting_media(str(source), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert not isinstance(rejected.value, media.TransientMediaError)
    assert (source.read_bytes(), source.stat().st_mtime_ns) == original
    assert not failure_path.exists()


async def test_sweep_allows_start(tmp_path, monkeypatch):
    """Temp cleanup is best effort, even if its directory is unavailable."""
    monkeypatch.setenv("VELORA_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(server, "sweep_meeting_temp", lambda: (_ for _ in ()).throw(
        OSError(errno.ENOSPC, "No space left on device")))

    class Config:
        socket_path = tmp_path / "engine.sock"

    class Engine:
        def __init__(self, _config, parent_pid):
            self.shutdown = asyncio.Event()

        async def serve(self, _path):
            pass

    monkeypatch.setattr(server, "Config", Config)
    monkeypatch.setattr(server, "Engine", Engine)
    monkeypatch.setattr(asyncio.get_running_loop(), "add_signal_handler", lambda *_args: None)
    await server._amain(types.SimpleNamespace(socket=None, parent_pid=None))


def test_cancel_reaps_converter(tmp_path, monkeypatch):
    """A cancel interrupts a stalled converter before its duration timeout."""
    source, _root, _ = _track(tmp_path)
    cancelled = threading.Event()
    state = {"waits": 0, "killed": False, "reaped": False}

    class Process:
        returncode = None

        def __init__(self, args, **_kwargs):
            self.args = args
            state["output"] = Path(args[-1])
            state["output"].write_bytes(b"partial")

        def communicate(self, timeout=None):
            state["waits"] += 1
            if state["killed"]:
                state["reaped"] = True
                self.returncode = -9
                return b"", b""
            cancelled.set()
            if state["waits"] > 5:
                raise AssertionError("converter ignored cancellation")
            raise subprocess.TimeoutExpired(self.args, timeout)

        def kill(self):
            state["killed"] = True

    monkeypatch.setattr(media.subprocess, "Popen", Process)
    with pytest.raises(media.TransientMediaError):
        media._convert_meeting(source, 5 * 3600, cancel=cancelled.is_set)
    assert state["reaped"]
    assert state["waits"] < 10
    assert not state["output"].exists()


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
@pytest.mark.parametrize("subtype,channels", [
    ("PCM_16", 1), ("FLOAT", 1), ("FLOAT", 2),
])
def test_wave_caf_parity(
    tmp_path, subtype, channels,
):
    """The new CAF reader preserves base WAV samples and v3 plan seams."""
    rate = 48_000
    seconds = 96
    time = np.arange(seconds * rate, dtype=np.float32) / rate
    pcm = 0.28 * (np.sin(2 * np.pi * 173 * time)
                  + 0.15 * np.sin(2 * np.pi * 311 * time))
    pcm[55 * rate:56 * rate] = 0
    if channels == 2:
        pcm = np.column_stack((pcm, pcm * 0.7))
    source = tmp_path / "source.caf"
    wave = tmp_path / "base.wav"
    caf = tmp_path / "new.caf"
    sf.write(str(source), pcm, rate, format="CAF", subtype=subtype)

    # Run both real Core Audio output formats from the same source bytes.
    for fmt, target in (("WAVE", wave), ("caff", caf)):
        subprocess.run(
            ["afconvert", "-f", fmt, "-d", f"LEI16@{media.SAMPLE_RATE}",
             "-c", "1", str(source), str(target)],
            check=True, capture_output=True, timeout=30,
        )
    base_pcm = media._read_wav_16k(wave)
    track = media.MeetingAudio(caf)
    try:
        blocks = [track.read(a, min(a + 60 * media.SAMPLE_RATE, len(track)), cancel=lambda: False)
                  for a in range(0, len(track), 60 * media.SAMPLE_RATE)]
        new_pcm = np.concatenate(blocks)
        base_cuts = np.cumsum([len(chunk) for chunk in media.split_for_batch(base_pcm)])[:-1]
        new_cuts = [end for _start, end in media.plan_meeting_slices(track, cancel=lambda: False)[:-1]]
    finally:
        track.close()
    assert np.array_equal(base_pcm, new_pcm)
    assert list(base_cuts) == new_cuts


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
def test_truncated_caf_transcribes(tmp_path):
    """A crashed recorder leaves decodable PCM despite a stale data length."""
    root = tmp_path / "meetings"
    root.mkdir()
    source = root / "me.caf"
    samples = 2 * media.SAMPLE_RATE
    tone = 0.2 * np.sin(2 * np.pi * 300 * np.arange(samples) / media.SAMPLE_RATE)
    sf.write(str(source), tone, media.SAMPLE_RATE,
             format="CAF", subtype="PCM_16")
    header_bytes = source.stat().st_size - 2 * samples
    with source.open("r+b") as output:
        output.truncate(header_bytes + samples)

    track = media.load_meeting_media(str(source), meeting_root=root, cancel=lambda: False)
    try:
        assert len(track) == media.SAMPLE_RATE
        assert track.peak(cancel=lambda: False) > 0.1
    finally:
        track.close()


def test_recheck_full_reserve(tmp_path, monkeypatch):
    """A failed conversion cannot spend the margin and become a bad file."""
    path, root, failure_path = _track(tmp_path)
    required = media._required_meeting_bytes(1)
    margin = media._CONVERT_FREE_SPACE_MARGIN_BYTES
    free = iter([required + margin, required, required + margin, required])
    monkeypatch.setattr(media.shutil, "disk_usage",
                        lambda _p: types.SimpleNamespace(free=next(free)))
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")))
    for _ in range(2):
        with pytest.raises(media.TransientMediaError):
            media.load_meeting_media(str(path), meeting_root=root,
                                     failure_path=failure_path, cancel=lambda: False)
        assert not failure_path.exists()


@pytest.mark.parametrize("duration", [120, 10 * 3600])
def test_strike_window_edges(tmp_path, monkeypatch, duration):
    """The load path retains a long sibling's retry evidence long enough."""
    path, root, failure_path = _track(tmp_path)
    parse = media._recover_caf_info

    def long_info(source, size):
        info = parse(source, size)
        info.frames = duration * info.samplerate
        return info

    monkeypatch.setattr(media, "_recover_caf_info", long_info)
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")))
    first = 1000.0
    window = (media._MEETING_LOAD_RETRIES * media._MEETING_LOAD_RETRY_INTERVAL_S
              + media._FAILURE_STRIKE_MARGIN_S
              + 2 * media._convert_timeout(duration))
    if duration == 10 * 3600:
        assert window >= 7200
    times = iter([first, first + window - 0.01, first + window + 0.01])
    monkeypatch.setattr(media, "time", types.SimpleNamespace(time=lambda: next(times)))

    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    previous = failure_path.read_bytes()
    assert json.loads(previous)["expires_at"] == first + window
    with pytest.raises(ValueError) as rejected:
        media.load_meeting_media(str(path), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)
    assert not isinstance(rejected.value, media.TransientMediaError)
    failure_path.write_bytes(previous)
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root,
                                 failure_path=failure_path, cancel=lambda: False)


def test_precheck_breaks_strikes(tmp_path, monkeypatch):
    """A disk failure between decoder errors makes them nonconsecutive."""
    path, root, failure_path = _track(tmp_path)
    needed = media._required_meeting_bytes(1) + 1024
    free = iter([10**12, 10**12, needed - 1, 10**12, 10**12])
    monkeypatch.setattr(media.shutil, "disk_usage",
                        lambda _p: types.SimpleNamespace(free=next(free)))
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")))

    for _ in range(3):
        with pytest.raises(media.TransientMediaError):
            media.load_meeting_media(str(path), meeting_root=root,
                                     failure_path=failure_path, cancel=lambda: False)


@pytest.mark.parametrize("transient", [
    media._CoreAudioFailure("afconvert", -9, "signal"),
    subprocess.TimeoutExpired(["afconvert"], 1),
    OSError("temporary I/O"),
    RuntimeError("decoder busy"),
    media.TransientMediaError("meeting audio cancelled"),
])
def test_transient_breaks_strikes(tmp_path, monkeypatch, transient):
    """A signal, timeout, I/O fault or cancel resets decoder evidence."""
    path, root, failure_path = _track(tmp_path)
    results = iter([media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')"),
                    transient, media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")])

    def convert(*_args, **_kwargs):
        raise next(results)

    monkeypatch.setattr(media, "_convert_meeting", convert)
    for index in range(3):
        with pytest.raises(media.TransientMediaError):
            media.load_meeting_media(str(path), meeting_root=root,
                                     failure_path=failure_path, cancel=lambda: False)
        assert failure_path.exists() is (index != 1)


def test_changed_file_resets(tmp_path, monkeypatch):
    """A rewritten source needs two fresh identical failures."""
    path, root, failure_path = _track(tmp_path)
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: (_ for _ in ()).throw(
        media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")))

    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)
    path.write_bytes(path.read_bytes() + b"\0")
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)


def test_success_clears_strike(tmp_path, monkeypatch):
    """A successful decode breaks the repeated-failure chain."""
    path, root, failure_path = _track(tmp_path)
    result = ["fail", "success", "fail"]
    def convert(*_a, **_k):
        if result.pop(0) == "fail":
            raise media._CoreAudioFailure("afconvert", 1, "Error: Couldn't open input file ('typ?')")
        converted = tmp_path / "converted.caf"
        sf.write(converted, np.zeros(16_000, dtype=np.float32), 16_000,
                 format="CAF", subtype="PCM_16")
        return media.MeetingAudio(converted)
    monkeypatch.setattr(media, "_convert_meeting", convert)
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)
    track = media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)
    track.close()
    assert not failure_path.exists()
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)


def test_afinfo_cancel_reaps(tmp_path, monkeypatch):
    """Metadata cancellation uses the same bounded process poll as conversion."""
    path, _root, _failure_path = _track(tmp_path, "m4a")
    cancelled = threading.Event()
    state = {"killed": False, "reaped": False, "waits": 0}
    class Process:
        args = ["afinfo"]
        returncode = None
        def communicate(self, timeout=None):
            state["waits"] += 1
            if state["killed"]:
                self.returncode = -9
                state["reaped"] = True
                return b"", b""
            cancelled.set()
            raise subprocess.TimeoutExpired(self.args, timeout)
        def kill(self):
            state["killed"] = True
    monkeypatch.setattr(media.subprocess, "Popen", lambda *_a, **_k: Process())
    with pytest.raises(media.TransientMediaError, match="cancel"):
        media._m4a_duration_s(path, cancel=cancelled.is_set)
    assert state == {"killed": True, "reaped": True, "waits": 2}


def test_afinfo_unknown_repeat(tmp_path, monkeypatch):
    """An unmeasured duration failure never becomes an input verdict."""
    path, root, failure_path = _track(tmp_path, "m4a")
    def fail(_path, **_kwargs):
        raise media._CoreAudioFailure("afinfo", 1, "bad metadata")
    monkeypatch.setattr(media, "_m4a_duration_s", fail)

    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)
    with pytest.raises(media.TransientMediaError):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)
    assert not failure_path.exists()


def test_invalid_state_retries(tmp_path, monkeypatch):
    """A damaged cache entry cannot fail the meeting audio load."""
    path, root, failure_path = _track(tmp_path, "m4a")
    failure_path.parent.mkdir()
    failure_path.write_text("[]")
    monkeypatch.setattr(media, "_m4a_duration_s", lambda _path, **_kwargs: 60)
    monkeypatch.setattr(media.shutil, "disk_usage", lambda _p: types.SimpleNamespace(free=0))
    with pytest.raises(media.TransientMediaError, match="disk space"):
        media.load_meeting_media(str(path), meeting_root=root, failure_path=failure_path, cancel=lambda: False)


@pytest.mark.parametrize("fields", [
    {44: 0},
    {32: 1, 36: 2, 48: 16},
])
def test_bad_caf_desc(tmp_path, fields):
    """Invalid channels and float widths reject before duration math."""
    path, _root, _failure_path = _track(tmp_path)
    raw = bytearray(path.read_bytes())
    for offset, value in fields.items():
        raw[offset:offset + 4] = value.to_bytes(4, "big")
    path.write_bytes(raw)
    with path.open("rb") as source:
        with pytest.raises(ValueError, match="unsupported CAF"):
            media._recover_caf_info(source, path.stat().st_size)


def test_sweep_expires_records(tmp_path, monkeypatch, caplog):
    """Startup removes obsolete retry evidence without another plan save."""
    directory = tmp_path / "meeting-plans"
    directory.mkdir()
    expired = directory / "old.me.failure.json"
    fresh = directory / "new.me.failure.json"
    stale_tmp = directory / "old.me.failure.tmp"
    corrupt = directory / "bad.me.failure.json"
    expired.write_text(json.dumps({"expires_at": 1}))
    fresh.write_text(json.dumps({"expires_at": 1100}))
    stale_tmp.write_text("interrupted atomic write")
    corrupt.write_text("{")

    monkeypatch.setattr(media, "time", types.SimpleNamespace(time=lambda: 1001))
    media.sweep_meeting_failures(directory)
    media.sweep_meeting_failures(directory)

    assert not expired.exists()
    assert fresh.exists()
    assert not stale_tmp.exists()
    assert not corrupt.exists()
    assert caplog.text.count("invalid meeting failure state") == 1


def test_retry_window_matches_app():
    """The persisted strike window follows the app's retry cadence."""
    source = (Path(__file__).parents[2] / "Sources/Velora/Meetings/MeetingProcessor.swift").read_text()
    retries = re.search(r"\baudioLoadRetryLimit\s*=\s*(\d+)", source)
    interval = re.search(r"\baudioLoadRetryDelay:\s*TimeInterval\s*=\s*(\d+)", source)
    assert retries is not None and int(retries.group(1)) == media._MEETING_LOAD_RETRIES
    assert interval is not None and int(interval.group(1)) == media._MEETING_LOAD_RETRY_INTERVAL_S


@pytest.mark.parametrize("size", [None, 4, -1])
def test_caf_load_preserves_track(tmp_path, monkeypatch, size):
    """A CAF load never rewrites the user's recording or its mtime."""
    path, root, _failure_path = _track(tmp_path)
    raw = bytearray(path.read_bytes())
    at = raw.index(b"data")
    if size is not None:
        raw[at + 4:at + 12] = size.to_bytes(8, "big", signed=True)
    path.write_bytes(raw)
    before = path.read_bytes()
    mtime = path.stat().st_mtime_ns
    monkeypatch.setattr(media, "_convert_meeting", lambda *_a, **_k: object())

    media.load_meeting_media(str(path), meeting_root=root, cancel=lambda: False)

    assert path.read_bytes() == before
    assert path.stat().st_mtime_ns == mtime


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert missing")
def test_killed_writer_transcribes(tmp_path):
    """Reproduce AVAudioFile's desc/free/data layout and unknown data size."""
    root = tmp_path / "meetings"
    root.mkdir()
    path = root / "them.caf"
    rate = 48_000
    samples = np.full((rate, 2), 0.1, dtype=np.float32)
    sf.write(path, samples, rate, format="CAF", subtype="FLOAT")
    raw = bytearray(path.read_bytes())
    assert raw[8:12] == b"desc"
    # libsndfile adds a peak chunk that AVAudioFile omits. Remove it and
    # expand the free chunk so data remains at the captured offset 4080.
    assert raw[52:56] == b"peak"
    del raw[52:92]
    raw[56:64] = (4016).to_bytes(8, "big", signed=True)
    raw[4040:4040] = b"\0" * 40
    assert raw[52:56] == b"free"
    assert raw[4080:4084] == b"data"
    raw[4084:4092] = (-1).to_bytes(8, "big", signed=True)
    path.write_bytes(raw)
    before = path.read_bytes()
    mtime = path.stat().st_mtime_ns

    with path.open("rb") as source:
        info = media._recover_caf_info(source, path.stat().st_size)
    assert info.frames == rate
    track = media.load_meeting_media(str(path), meeting_root=root, cancel=lambda: False)
    try:
        assert len(track) == media.SAMPLE_RATE
        assert track.peak(cancel=lambda: False) > 0.05
    finally:
        track.close()
    assert path.read_bytes() == before
    assert path.stat().st_mtime_ns == mtime


def test_sweep_keeps_live_owner(tmp_path, monkeypatch):
    """Startup cleanup removes dead output but preserves a live conversion."""
    monkeypatch.setattr(media, "_meeting_temp_root", lambda: tmp_path)
    directory = tmp_path / "velora-meeting-media"
    directory.mkdir(mode=0o700)
    live = directory / f"velora-meeting-{os.getpid()}-live.caf"
    dead = directory / "velora-meeting-99999999-dead.caf"
    live.write_bytes(b"live")
    dead.write_bytes(b"dead")
    media.sweep_meeting_temp()
    assert live.exists()
    assert not dead.exists()


def test_unsafe_temp_uses_fallback(tmp_path, monkeypatch):
    """A symlinked shared conversion directory never receives audio output."""
    monkeypatch.setattr(media, "_meeting_temp_root", lambda: tmp_path)
    target = tmp_path / "other"
    target.mkdir()
    (tmp_path / "velora-meeting-media").symlink_to(target)
    directory = media._meeting_temp_dir()
    assert directory != target
    assert directory != tmp_path / "velora-meeting-media"
    assert directory.stat().st_mode & 0o777 == 0o700
    assert media._meeting_temp_dir() == directory
    orphan_dir = tmp_path / "velora-meeting-media-old"
    orphan_dir.mkdir(mode=0o700)
    orphan = orphan_dir / "velora-meeting-99999999-dead.caf"
    orphan.write_bytes(b"partial")
    media.sweep_meeting_temp()
    assert not orphan.exists()
    assert not orphan_dir.exists()
    assert media._meeting_temp_dir() == directory
    assert directory.exists()


def test_owned_temp_hardened(tmp_path, monkeypatch):
    """An existing directory owned by this uid is reused with private mode."""
    monkeypatch.setattr(media, "_meeting_temp_root", lambda: tmp_path)
    directory = tmp_path / "velora-meeting-media"
    directory.mkdir(mode=0o755)

    assert media._meeting_temp_dir() == directory
    assert directory.stat().st_mode & 0o777 == 0o700


def test_plan_cancel_during_search():
    """A seam search stops before a second read after cancellation."""
    cancelled = threading.Event()
    reads = []
    def read(start, end):
        reads.append((start, end))
        cancelled.set()
        return np.zeros(end - start, dtype=np.float32)
    with pytest.raises(media.TransientMediaError, match="cancel"):
        media._plan_spans(300 * 100, read, 60, 15, 100,
                          cancel=cancelled.is_set)
    assert len(reads) == 1


def test_slice_cancel_during_read(tmp_path, monkeypatch):
    """A slice checks cancellation after each one-second disk block."""
    cancelled = threading.Event()
    reads = []
    class Source:
        samplerate = media.SAMPLE_RATE
        channels = 1
        def __len__(self):
            return 3 * media.SAMPLE_RATE
        def seek(self, _start):
            pass
        def read(self, length, **_kwargs):
            reads.append(length)
            cancelled.set()
            return np.zeros(length, dtype=np.float32)
        def close(self):
            pass
    path = tmp_path / "converted.caf"
    path.write_bytes(b"audio")
    monkeypatch.setitem(sys.modules, "soundfile", types.SimpleNamespace(
        SoundFile=lambda *_a, **_k: Source()))
    track = media.MeetingAudio(path)
    try:
        with pytest.raises(media.TransientMediaError, match="cancel"):
            track.read(0, 3 * media.SAMPLE_RATE, cancel=cancelled.is_set)
    finally:
        track.close()
    assert reads == [media.SAMPLE_RATE]


async def test_close_keeps_loop_alive(engine, tmp_path, monkeypatch):
    """Shutdown awaits close in an executor while a slice holds the file lock."""
    from velora_engine import server
    _eng, sock = engine
    entered = threading.Event()
    release = threading.Event()
    closed = threading.Event()
    class Source:
        samplerate = media.SAMPLE_RATE
        channels = 1
        def __init__(self):
            self.reads = 0
        def __len__(self):
            return 2 * media.SAMPLE_RATE
        def seek(self, _start):
            pass
        def read(self, length, **_kwargs):
            self.reads += 1
            if self.reads == 3:
                entered.set()
                release.wait(5)
            return np.full(length, 0.2, dtype=np.float32)
        def close(self):
            closed.set()
    path = tmp_path / "converted.caf"
    path.write_bytes(b"audio")
    monkeypatch.setitem(sys.modules, "soundfile", types.SimpleNamespace(
        SoundFile=lambda *_a, **_k: Source()))
    track = media.MeetingAudio(path)
    monkeypatch.setattr(server, "load_meeting_media", lambda *_a, **_k: track)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "close-cancel", "meeting_id": "m",
        "speaker": "me", "path": "/synthetic/meeting.caf", "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    assert await asyncio.to_thread(entered.wait, 2)
    task = next(task for task in asyncio.all_tasks()
                if task.get_coro().__qualname__.endswith("Engine._run_meeting_transcribe"))
    progressed = threading.Event()
    observed = []

    def watch_loop():
        observed.append(progressed.wait(2))
        release.set()

    watcher = threading.Thread(target=watch_loop)
    watcher.start()
    asyncio.get_running_loop().call_later(0.01, progressed.set)
    task.cancel()
    await asyncio.to_thread(watcher.join, 3)
    assert observed == [True]
    with contextlib.suppress(asyncio.CancelledError):
        await asyncio.wait_for(task, 2)
    assert closed.is_set()
    client.close()


def test_planner_golden_cuts():
    """Pin the sample cuts from 3cf3fcb's split_for_batch."""
    rate = 100
    x = np.arange(180 * rate, dtype=np.float32)
    pcm = (0.2 * np.sin(2 * np.pi * 7 * x / rate)
           + 0.05 * np.sin(2 * np.pi * 13 * x / rate)).astype(np.float32)
    for second in (52, 103, 152):
        pcm[second * rate:(second + 2) * rate] = 0
    class Reader:
        def __len__(self):
            return len(pcm)
        def read(self, start, end, **_kwargs):
            return pcm[start:end]
    cuts = [end for _start, end in media.plan_meeting_slices(Reader(), rate, cancel=lambda: False)[:-1]]
    assert cuts == [5215, 10315]


def test_m4a_disk_uses_duration(tmp_path, monkeypatch):
    """A long compressed track needs room for its decoded PCM."""
    root = tmp_path / "meetings"
    root.mkdir()
    source = root / "them.m4a"
    source.write_bytes(b"compressed")
    duration = 5 * 3600
    monkeypatch.setattr(media, "_m4a_duration_s", lambda _src, **_kwargs: duration, raising=False)
    required = media._required_meeting_bytes(duration)
    monkeypatch.setattr(media.shutil, "disk_usage", lambda _path: types.SimpleNamespace(free=required - 1))
    monkeypatch.setattr(media, "_convert_meeting", lambda _src, _duration, **_kwargs: pytest.fail("converter must not run"))

    with pytest.raises(media.TransientMediaError, match="disk space"):
        media.load_meeting_media(str(source), meeting_root=root, cancel=lambda: False)


@pytest.mark.skipif(shutil.which("afconvert") is None or shutil.which("afinfo") is None,
                    reason="Core Audio tools missing")
def test_real_m4a_loads(tmp_path):
    """Core Audio duration and conversion work on an actual legacy track."""
    import soundfile as sf

    root = tmp_path / "meetings"
    root.mkdir()
    source = tmp_path / "source.wav"
    target = root / "them.m4a"
    timeline = np.arange(2 * media.SAMPLE_RATE) / media.SAMPLE_RATE
    sf.write(str(source), 0.2 * np.sin(2 * np.pi * 330 * timeline),
             media.SAMPLE_RATE)
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", str(source), str(target)],
        check=True, capture_output=True, timeout=30,
    )

    track = media.load_meeting_media(str(target), meeting_root=root, cancel=lambda: False)
    try:
        assert isinstance(track, media.MeetingAudio)
        assert not track._path.exists()
        assert abs(len(track) - 2 * media.SAMPLE_RATE) < media.SAMPLE_RATE
        assert track.peak(cancel=lambda: False) > 0.1
    finally:
        track.close()


def test_converter_timeout_scales(tmp_path, monkeypatch):
    """A long conversion gets headroom without an hours-long hang budget."""
    source, _root, _ = _track(tmp_path)
    seen = []
    deadline = max(media._AFCONVERT_TIMEOUT_S, 5 * 3600 * media._MEETING_CONVERT_TIMEOUT_RATIO)

    def timeout(args, budget, *, cancel):
        seen.append(budget)
        raise subprocess.TimeoutExpired(args, budget)

    monkeypatch.setattr(media, "_run_core_audio", timeout)
    with pytest.raises(subprocess.TimeoutExpired) as expired:
        media._convert_meeting(source, 5 * 3600, cancel=lambda: False)
    assert expired.value.timeout == deadline
    assert seen == [deadline]
