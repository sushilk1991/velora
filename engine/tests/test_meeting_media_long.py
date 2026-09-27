"""Long meetings keep their words while decoded audio stays bounded."""

# The shared socket fixture intentionally uses the same name as test arguments.
# ruff: noqa: F811

import asyncio
import types
import sys

import numpy as np
import soundfile as sf

from test_server import connect, engine  # noqa: F401

from velora_engine import server as server_mod
from velora_engine import media


async def test_long_meeting_resumes(engine, tmp_path, monkeypatch):
    async with asyncio.timeout(60):
        await _run_long(engine, tmp_path, monkeypatch)


async def _run_long(engine, tmp_path, monkeypatch):
    """A five-hour plan keeps a voiced word across the nominal 60 s seam."""
    eng, sock = engine
    rate = 100
    duration_s = 5 * 3600
    samples = duration_s * rate
    monkeypatch.setattr(server_mod, "SAMPLE_RATE", rate)
    monkeypatch.setattr(media, "SAMPLE_RATE", rate)
    monkeypatch.setattr(server_mod, "MEETING_SILENT_TRACK_MAX_PEAK", 0.0)
    marks = {int(second * rate): index for index, second in enumerate(range(30, duration_s, 59), 1)}
    pcm = np.zeros(samples, dtype=np.float32)
    for position, word in marks.items():
        pcm[position] = 0.65 + word / 1000
    # Fill the actual first search window with voiced harmonics, leaving one
    # 0.8 s pause. The computed seam must land between two complete word blocks.
    voice_t = np.arange(15 * rate, dtype=np.float32) / rate
    pcm[45 * rate : 60 * rate] = 0.3 * (
        np.sin(2 * np.pi * 11 * voice_t) + 0.2 * np.sin(2 * np.pi * 23 * voice_t))
    pcm[55 * rate : 558 * rate // 10] = 0
    left_word = (54 * rate, 54 * rate + rate // 4)
    right_word = (56 * rate, 56 * rate + rate // 4)
    pcm[left_word[0]:left_word[1]] = -0.8
    pcm[right_word[0]:right_word[1]] = -0.9
    reads = []

    class TrackingMeetingAudio(media.MeetingAudio):
        def read(self, start, end, *, cancel=None):
            reads.append(end - start)
            return super().read(start, end, cancel=cancel)

    def load_track(*_args, **_kwargs):
        path = tmp_path / "converted.caf"
        sf.write(str(path), pcm, rate, format="CAF", subtype="PCM_16")
        return TrackingMeetingAudio(path)

    def decode(_stt, chunk):
        words = [str(round((value - 0.65) * 1000)) for value in chunk if value > 0.65]
        if np.any((-0.85 < chunk) & (chunk < -0.75)):
            words.append("leftword")
        if np.any(chunk < -0.85):
            words.append("rightword")
        return " ".join(words)

    monkeypatch.setattr(server_mod, "load_meeting_media", load_track)
    monkeypatch.setattr(
        server_mod, "transcribe_clip",
        decode,
    )
    client = await connect(sock)
    await client.recv_event("ready")

    async def run(job, start_chunk):
        await client.send_json({
            "cmd": "meeting_transcribe", "id": job, "meeting_id": "long-meeting",
            "speaker": "me", "path": "/synthetic/long.caf", "start_chunk": start_chunk,
        })
        await client.recv_event("meeting_transcribe_accepted")
        started = await client.recv()
        assert started["event"] == "meeting_transcribe_started", started
        events = []
        while True:
            event = await client.recv()
            if event["event"] == "meeting_segment":
                events.append(event)
            if event["event"] == "meeting_transcribed":
                return started, events

    first, all_segments = await run("first", 0)
    assert first["chunks"] > 250
    words = [word for event in all_segments for word in event["text"].split()]
    assert words.count("leftword") == 1
    assert words.count("rightword") == 1
    assert sorted(int(word) for word in words if word not in ("leftword", "rightword")) == sorted(marks.values())
    resumed, rest = await run("resume", 100)
    assert resumed["start_chunk"] == 100
    assert [event["text"] for event in rest] == [event["text"] for event in all_segments[100:]]
    assert max(reads) <= media.MEETING_SLICE_S * rate
    track = load_track()
    try:
        cuts = [end for _start, end in media.plan_meeting_slices(track, rate, cancel=lambda: False)[:-1]]
    finally:
        track.close()
    assert left_word[1] <= cuts[0] <= right_word[0]
    assert all(not (start < cuts[0] < end) for start, end in (left_word, right_word))
    assert cuts == list(np.cumsum([
        len(chunk) for chunk in media.split_for_batch(pcm, sample_rate=rate)
    ])[:-1])
    client.close()


def test_long_caf_is_accepted(tmp_path, monkeypatch):
    """App-owned duration is not a permanent unsupported-audio reason."""
    root = tmp_path / "meetings"
    root.mkdir()
    source = root / "me.caf"
    duration_s = 5 * 3600
    rate = 48_000
    # A real CAF header and sparse PCM exercise the physical frame count.
    sf.write(str(source), np.zeros(1, dtype=np.float32), rate,
             format="CAF", subtype="FLOAT")
    raw = bytearray(source.read_bytes())
    data = raw.index(b"data")
    raw[data + 4:data + 12] = (-1).to_bytes(8, "big", signed=True)
    source.write_bytes(raw)
    with source.open("r+b") as output:
        output.truncate(data + 16 + duration_s * rate * 4)
    converted = tmp_path / "converted.caf"
    sf.write(str(converted), np.zeros(media.SAMPLE_RATE, dtype=np.float32),
             media.SAMPLE_RATE, format="CAF", subtype="PCM_16")
    expected = media.MeetingAudio(converted)
    durations = []

    def convert(_source, seconds, **_kwargs):
        durations.append(seconds)
        return expected

    monkeypatch.setattr(media, "_convert_meeting", convert)
    assert media.load_meeting_media(str(source), meeting_root=root, cancel=lambda: False) is expected
    assert durations == [duration_s]
    expected.close()


async def test_slice_read_retries(engine, tmp_path, monkeypatch):
    """A SoundFile read error during decode keeps the track eligible for Retry."""
    _eng, sock = engine

    class BrokenSource:
        samplerate = server_mod.SAMPLE_RATE
        channels = 1

        def __init__(self):
            self.reads = 0

        def __len__(self):
            return 2 * server_mod.SAMPLE_RATE

        def seek(self, _position):
            pass

        def read(self, length, **_kwargs):
            self.reads += 1
            if self.reads > 2:
                raise OSError("temporary read fault")
            return np.full(length, 0.1, dtype=np.float32)

        def close(self):
            pass

    converted = tmp_path / "converted.caf"
    converted.write_bytes(b"converted")
    monkeypatch.setitem(sys.modules, "soundfile", types.SimpleNamespace(
        SoundFile=lambda *_args, **_kw: BrokenSource(),
    ))
    track = media.MeetingAudio(converted)
    monkeypatch.setattr(server_mod, "load_meeting_media", lambda *_args, **_kw: track)
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "meeting_transcribe", "id": "read-failed", "meeting_id": "m",
        "speaker": "me", "path": "/synthetic/meeting.caf", "start_chunk": 0,
    })
    await client.recv_event("meeting_transcribe_accepted")
    await client.recv_event("meeting_transcribe_started")
    failed = await client.recv_event("meeting_transcribe_failed")
    assert failed["code"] == server_mod.MEETING_AUDIO_LOAD_FAILED
    client.close()
