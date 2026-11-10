"""Real timing contracts; synthetic recognizer output never invents word offsets."""
import math
from pathlib import Path
import pytest
from velora_engine.meeting_subtitles import (
    SubtitleError, build_cues, validate_words, validate_track, source_fingerprint,
)


def result(words):
    return {"segments": [{"text": "".join(w[0] for w in words), "avg_logprob": -0.15,
        "compression_ratio": 1.1, "no_speech_prob": 0.01,
        "words": [{"word": t, "start": a, "end": b, "probability": .95} for t, a, b in words]}]}


def test_cues_keep_observed_offsets_and_break_at_pause():
    words = validate_words(result([(" Hello", 1., 1.4), (" everyone.", 1.4, 2.),
        (" Next", 4., 4.5), (" topic.", 4.5, 5.)]), duration_s=6., offset_s=20.)
    cues = build_cues(words, speaker="them")
    assert [(c["start_ms"], c["end_ms"], c["text"]) for c in cues] == [
        (21000, 22000, "Hello everyone."), (24000, 25000, "Next topic.")]


@pytest.mark.parametrize("words", [
    [(" hi", math.nan, 1.)], [(" hi", 1., 1.)], [(" hi", 2., 1.)],
    [(" hi", -.1, 1.)], [(" hi", 1., 7.)],
    [(" hi", 1., 2.), (" there", 1.5, 2.5)],
    [(" hi", 2., 3.), (" there", 1., 2.)],
    [(" supercalifragilisticexpialidocious" * 2, 0., .1)],
])
def test_bad_alignment_is_rejected(words):
    with pytest.raises(SubtitleError):
        validate_words(result(words), duration_s=6.)


def test_missing_word_alignment_is_not_evenly_split():
    with pytest.raises(SubtitleError, match="word timing"):
        validate_words({"segments": [{"text": "One two three", "start": 0, "end": 6}]}, duration_s=6.)


def test_missing_recognized_words_cannot_pass_as_aligned_transcript():
    data = result([(" hello", 1., 2.)])
    data["segments"][0]["text"] = "hello this text has no observed timing"
    with pytest.raises(SubtitleError, match="match"):
        validate_words(data, duration_s=6.)


def test_pathological_repetition_and_low_confidence_are_rejected():
    with pytest.raises(SubtitleError):
        validate_words(result([(" thank you", i*.5, i*.5+.4) for i in range(12)]), duration_s=8.)
    data = result([(" hello", 1., 2.)]); data["segments"][0]["avg_logprob"] = -1.6
    with pytest.raises(SubtitleError): validate_words(data, duration_s=6.)


def test_readable_cues_have_at_most_two_short_lines():
    data = result([(" " + w, i*.35, i*.35+.3) for i, w in enumerate(
        "Here is a deliberately long sentence with enough words to check that subtitles remain readable on an ordinary screen without filling the whole page with text".split())])
    cues = build_cues(validate_words(data, duration_s=12.), speaker="me")
    assert len(cues) >= 2
    assert all(len(c["text"].splitlines()) <= 2 and max(map(len, c["text"].splitlines())) <= 42 for c in cues)
    assert all(0 < c["end_ms"] - c["start_ms"] <= 7000 for c in cues)
    assert " ".join(c["text"].replace("\n", " ") for c in cues) == data["segments"][0]["text"].strip()


def test_track_cannot_escape_its_owned_uuid_directory(tmp_path):
    ident = "2c6695c4-264d-4ecb-96b3-476408a68053"
    directory = tmp_path / ident; directory.mkdir(); clip = directory / "me.caf"; clip.write_bytes(b"audio")
    assert validate_track(str(clip), meeting_id=ident, root=tmp_path) == clip
    first = source_fingerprint(clip)
    clip.write_bytes(b"other")
    assert source_fingerprint(clip) != first
    with pytest.raises(SubtitleError): validate_track(str(clip), meeting_id="wrong", root=tmp_path)
    clip.unlink(); clip.symlink_to(tmp_path / "outside.caf")
    (tmp_path / "outside.caf").write_bytes(b"audio")
    with pytest.raises(SubtitleError): validate_track(str(clip), meeting_id=ident, root=tmp_path)

# Reuse the local CAF converter and fake engine fixture; no model or mic access.
import asyncio
import json
import threading
import uuid
import numpy as np
from test_server import engine, connect  # noqa: F401
from test_meetings import convert_protocol_caf  # noqa: F401
from velora_engine import protocol


def request(tmp_path, eng):
    import os
    import soundfile as sf
    meeting = str(uuid.uuid4())
    directory = Path(os.environ["VELORA_HOME"]) / "meetings" / meeting
    directory.mkdir(parents=True)
    path = directory / "me.caf"
    sf.write(str(path), np.sin(np.arange(48000) * .1) * .2, 16000, format="CAF", subtype="PCM_16")
    eng.stt.model_id = "mlx-community/whisper-large-v3-turbo"
    eng.stt.transcribe_timed = lambda *_: result([(" Hello", .5, .9), (" everyone.", .9, 1.5)])
    return {"cmd": "meeting_subtitles", "id": str(uuid.uuid4()), "meeting_id": meeting,
        "revision": 3, "tracks": [{"speaker": "me", "path": str(path)}]}


async def test_subtitle_wire_result_and_lease_completion(engine, tmp_path):
    eng, sock = engine
    client = await connect(sock); await client.recv_event("ready")
    msg = request(tmp_path, eng)
    await client.send_json(msg)
    active = await client.recv_event("reprocess_activity")
    assert active["active"] is True and msg["id"] in eng._reprocess_leases
    ready = await client.recv_event("meeting_subtitles_ready")
    assert ready["revision"] == 3 and ready["cues"][0]["start_ms"] == 500
    assert ready["cues"][0]["text"] == "Hello everyone."
    assert msg["id"] not in eng._reprocess_leases and not eng._transcribing
    assert ready["fingerprints"][0]["value"].split(":")[0]
    client.close()


@pytest.mark.parametrize("condition", ["adopting", "busy", "unsupported", "invalid_path"])
async def test_admission_rejections_settle_preregistered_retention(engine, tmp_path, condition):
    eng, sock = engine
    client = await connect(sock); await client.recv_event("ready")
    msg = request(tmp_path, eng)
    if condition == "adopting": eng._adopting = True
    if condition == "busy": eng._reprocessing = True
    if condition == "unsupported": eng.stt.model_id = "another/model"
    if condition == "invalid_path": msg["tracks"][0]["path"] = "/tmp/not-owned.caf"
    await client.send_json(msg)
    failed = await client.recv_event("meeting_subtitles_failed")
    released = await client.recv_event("reprocess_activity")
    assert failed["id"] == msg["id"] and released == {"event": "reprocess_activity", "request_id": msg["id"], "active": False}
    assert not eng._transcribing and msg["id"] not in eng._reprocess_leases
    eng._adopting = False; eng._reprocessing = False
    client.close()


async def test_cancel_keeps_retention_until_native_decode_returns_and_reconnect_replays_it(engine, tmp_path):
    eng, sock = engine
    client = await connect(sock); await client.recv_event("ready")
    msg = request(tmp_path, eng)
    entered, release = threading.Event(), threading.Event()
    def decode(*_):
        entered.set(); release.wait(3)
        return result([(" hello", .5, 1.)])
    eng.stt.transcribe_timed = decode
    await client.send_json(msg)
    for _ in range(100):
        if entered.is_set(): break
        await asyncio.sleep(.01)
    assert entered.is_set()
    await client.send_json({"cmd": "meeting_subtitles_cancel", "id": msg["id"]})
    await asyncio.sleep(.03)
    assert msg["id"] in eng._reprocess_leases and eng._transcribing
    client.close()
    for _ in range(100):
        if eng.writer is None: break
        await asyncio.sleep(.01)
    reconnected = await connect(sock)
    snapshot = await reconnected.recv_event("ready")
    assert any(j["request_id"] == msg["id"] for j in snapshot["reprocess_jobs"])
    release.set()
    failed = await reconnected.recv_event("meeting_subtitles_failed")
    assert failed["code"] == "cancelled" and msg["id"] not in eng._reprocess_leases
    reconnected.close()


async def test_foreground_ownership_defers_subtitle_decoder(engine, tmp_path):
    eng, sock = engine
    client = await connect(sock); await client.recv_event("ready")
    msg = request(tmp_path, eng)
    called = threading.Event()
    eng.stt.transcribe_timed = lambda *_: called.set() or result([(" hello", .5, 1.)])
    # _starting is the admission fence also checked on the owning STT thread.
    eng._starting = True
    await client.send_json(msg)
    await client.recv_event("reprocess_activity")
    await asyncio.sleep(.05)
    assert not called.is_set()
    eng._starting = False
    await client.recv_event("meeting_subtitles_ready")
    assert called.is_set()
    client.close()


async def test_audio_replacement_during_decode_cannot_publish(engine, tmp_path):
    eng, sock = engine
    client = await connect(sock); await client.recv_event("ready")
    msg = request(tmp_path, eng)
    def decode(*_):
        Path(msg["tracks"][0]["path"]).write_bytes(b"changed audio")
        return result([(" hello", .5, 1.)])
    eng.stt.transcribe_timed = decode
    await client.send_json(msg)
    failed = await client.recv_event("meeting_subtitles_failed")
    assert "changed" in failed["error"] and not eng._reprocess_leases
    client.close()


def test_timed_backend_never_downloads_or_switches_model(tmp_path, monkeypatch):
    from velora_engine.stt import WhisperBackend
    from velora_engine import models
    backend = WhisperBackend("another/model")
    monkeypatch.setattr(models, "ensure_downloaded", lambda *_: pytest.fail("subtitle attempted model acquisition"))
    with pytest.raises(SubtitleError): backend.transcribe_timed(np.zeros(16000, dtype=np.float32))
    backend.model_id = "mlx-community/whisper-large-v3-turbo"
    backend._loaded = True; backend._model_path = "/nonexistent/model"
    with pytest.raises(SubtitleError, match="locally"): backend.transcribe_timed(np.zeros(16000, dtype=np.float32))
