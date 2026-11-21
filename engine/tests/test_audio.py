"""Audio archive + reprocess: AudioStore unit round-trip and the server's
save-on-finalize / reprocess-from-clip flow (fake STT)."""

import asyncio
import os
import shutil
import tempfile
import time
import wave
from pathlib import Path

import numpy as np
import pytest

from velora_engine import audio_store
from velora_engine.audio_store import SAMPLE_RATE, AudioStore
from velora_engine.config import Config
from velora_engine.server import Engine

from test_server import Client, connect  # reuse the socket client helper

AUDIO = (np.sin(np.linspace(0, 100, 1600)) * 0.1).astype(np.float32)  # 100ms chunk


# ---- AudioStore unit ----


def _libsndfile_has_opus() -> bool:
    try:
        import soundfile as sf  # type: ignore

        return "OPUS" in sf.available_subtypes("OGG")
    except Exception:  # noqa: BLE001 — no libsndfile at all
        return False


requires_opus = pytest.mark.skipif(
    not _libsndfile_has_opus(), reason="libsndfile has no Ogg Opus encoder")


def _speechlike(seconds: float = 4.0, seed: int = 7) -> np.ndarray:
    """Amplitude-modulated formant stack plus shaped noise: broadband and
    non-stationary, so neither codec gets a pure tone's easy win."""
    samples = int(seconds * SAMPLE_RATE)
    t = np.arange(samples) / SAMPLE_RATE
    envelope = 0.5 * (1 + np.sin(2 * np.pi * 2.5 * t)) * np.exp(-((t % 1.0) - 0.3) ** 2 / 0.02)
    voice = sum(
        amplitude * np.sin(2 * np.pi * frequency * t + phase)
        for frequency, amplitude, phase in (
            (120, 0.5, 0), (240, 0.3, 1), (700, 0.15, 2), (1_200, 0.1, 3), (2_400, 0.05, 4))
    )
    noise = np.random.default_rng(seed).standard_normal(samples) * 0.05
    return np.clip(voice * envelope * 0.5 + noise * envelope, -1.0, 1.0).astype(np.float32)


def _snr_db(reference: np.ndarray, estimate: np.ndarray) -> float:
    noise = float(np.sum((reference - estimate) ** 2))
    return float("inf") if noise == 0.0 else float(10 * np.log10(np.sum(reference ** 2) / noise))


def _correlation(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.corrcoef(a, b)[0, 1])


def _write_wav(path: Path, pcm: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes((pcm * 32767.0).astype("<i2").tobytes())


def test_audio_store_roundtrip(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = _speechlike(1.0)
    name = store.save("sess-XYZ_123", pcm)
    assert name == f"sess-XYZ_123.{store.ext}"
    assert store.ext in ("ogg", "flac", "wav")
    path = store.path_for(name)
    assert path is not None and path.exists()
    assert (path.stat().st_mode & 0o777) == 0o600
    back = store.load(name)
    assert back.shape == pcm.shape
    if store.ext == "ogg":
        # Opus is lossy: the archive keeps the recording recognizable for the
        # speech model and for playback, not bit-identical.
        assert _correlation(back, pcm) > 0.95
        assert _snr_db(pcm, back) > 10.0
    else:
        assert float(np.sqrt(np.mean((back - pcm) ** 2))) < 1e-3  # 16-bit quantization only


@requires_opus
def test_audio_store_archives_ogg_opus_with_sample_exact_seeks(tmp_path):
    store = AudioStore(tmp_path / "audio")
    assert store.ext == "ogg"
    pcm = _speechlike(2.0)
    name = store.save("seek-clip", pcm)
    assert name == "seek-clip.ogg"

    back = store.load(name)
    # No priming or tail padding: the decoded clip is exactly as long as the PCM
    # that went in, so archived sample offsets stay meaningful.
    assert back.shape == pcm.shape
    assert _correlation(back, pcm) > 0.95
    assert _snr_db(pcm, back) > 10.0
    assert np.max(np.abs(back - pcm)) < 0.2

    with store.open_clip(name) as clip:
        assert clip.sample_count == pcm.shape[0]
        assert np.allclose(clip.read_span(0, clip.sample_count), back, atol=1e-6)
        # Spans are decoded from the same granule position as a full read: the
        # reprocess planner splits clips on seams and must not see a shifted or
        # truncated window.
        for start, end in ((0, 1), (1, 320), (17, 400), (5_000, 8_000),
                           (clip.sample_count - 1, clip.sample_count)):
            span = clip.read_span(start, end)
            assert span.shape == (end - start,)
            assert np.allclose(span, back[start:end], atol=1e-6), (start, end)
        with pytest.raises(ValueError):
            clip.read_span(0, clip.sample_count + 1)
        with pytest.raises(ValueError):
            clip.read_span(-1, 10)


@requires_opus
def test_audio_store_opus_clip_is_much_smaller_than_flac_and_wav(tmp_path):
    sf = pytest.importorskip("soundfile")
    store = AudioStore(tmp_path / "audio")
    pcm = _speechlike(4.0)
    name = store.save("size-compare", pcm)
    assert name == "size-compare.ogg"
    flac = store.dir / "compare.flac"
    wav = store.dir / "compare.wav"
    sf.write(str(flac), pcm, SAMPLE_RATE, subtype="PCM_16", format="FLAC")
    sf.write(str(wav), pcm, SAMPLE_RATE, subtype="PCM_16", format="WAV")

    ogg_bytes = store.path_for(name).stat().st_size
    flac_bytes, wav_bytes = flac.stat().st_size, wav.stat().st_size
    # Measured on speech-like material: 0.29x FLAC and 0.11x WAV. The bounds are
    # loose enough for another libsndfile to pick its own Opus bitrate.
    assert ogg_bytes < flac_bytes * 0.5, (ogg_bytes, flac_bytes)
    assert ogg_bytes < wav_bytes * 0.2, (ogg_bytes, wav_bytes)


def test_audio_store_reads_and_prunes_legacy_flac_and_wav(tmp_path):
    sf = pytest.importorskip("soundfile")
    store = AudioStore(tmp_path / "audio")
    store._ensure_dir()
    pcm = _speechlike(1.0)
    legacy_flac = store.dir / "legacy.flac"
    legacy_wav = store.dir / "legacy.wav"
    sf.write(str(legacy_flac), pcm, SAMPLE_RATE, subtype="PCM_16", format="FLAC")
    _write_wav(legacy_wav, pcm)

    # Clips archived by an earlier release stay addressable by basename.
    assert store.path_for("legacy.flac") == legacy_flac
    assert store.path_for("legacy.wav") == legacy_wav

    for name in ("legacy.flac", "legacy.wav"):
        back = store.load(name)
        assert back.shape == pcm.shape
        assert np.max(np.abs(back - pcm)) < 1e-3
        with store.open_clip(name) as clip:
            assert clip.sample_count == pcm.shape[0]
            assert np.allclose(clip.read_span(100, 900), pcm[100:900], atol=1e-3)

    stale = time.time() - 400 * 86400
    for path in (legacy_flac, legacy_wav):
        os.utime(path, (stale, stale))
    assert store.prune(retention_days=180, max_bytes=None) == 2
    assert not legacy_flac.exists() and not legacy_wav.exists()


def test_audio_store_falls_back_to_flac_without_an_opus_encoder(tmp_path, monkeypatch):
    sf = pytest.importorskip("soundfile")

    class NoOpusEncoder:
        """A libsndfile that lists Vorbis but no Opus writer."""

        def __getattr__(self, name):
            return getattr(sf, name)

        @staticmethod
        def available_subtypes(fmt):
            return {k: v for k, v in sf.available_subtypes(fmt).items() if k != "OPUS"}

    monkeypatch.setattr(audio_store, "_soundfile", lambda: NoOpusEncoder())
    store = AudioStore(tmp_path / "audio")
    assert store.ext == "flac"
    pcm = _speechlike(0.5)
    name = store.save("no-opus", pcm)
    assert name == "no-opus.flac"
    back = store.load(name)
    assert back.shape == pcm.shape
    assert float(np.max(np.abs(back - pcm))) < 1e-3
    with store.open_clip(name) as clip:
        assert clip.sample_count == pcm.shape[0]


def test_audio_store_falls_back_to_flac_when_the_subtype_probe_fails(tmp_path, monkeypatch):
    sf = pytest.importorskip("soundfile")

    class BrokenProbe:
        def __getattr__(self, name):
            return getattr(sf, name)

        @staticmethod
        def available_subtypes(_fmt):
            raise RuntimeError("libsndfile cannot enumerate codecs")

    monkeypatch.setattr(audio_store, "_soundfile", lambda: BrokenProbe())
    assert AudioStore(tmp_path / "audio").ext == "flac"


def test_audio_store_without_libsndfile_says_why_an_ogg_cannot_be_opened(tmp_path):
    store = AudioStore(tmp_path / "audio")
    store._sf, store._codec, store.ext = None, None, "wav"
    store._ensure_dir()
    (store.dir / "orphan.ogg").write_bytes(b"OggS")
    with pytest.raises(ValueError, match="needs libsndfile"):
        store.open_clip("orphan.ogg")


def test_interrupted_spool_recovers_until_acknowledged(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = np.array([-0.5, -0.25, 0.0, 0.25, 0.5], dtype=np.float32)

    spool = store.begin_active("session-123")
    assert spool is not None
    assert spool.path.name == "session-123.pcm16.part"  # raw PCM while live
    assert spool.append(pcm)
    spool.close()

    recovered = store.recover_interrupted()

    assert len(recovered) == 1
    assert recovered[0].session == "session-123"
    assert recovered[0].audio == f"session-123.{store.ext}"
    assert recovered[0].duration_s == pytest.approx(5 / 16_000)
    assert (store.dir.stat().st_mode & 0o777) == 0o700
    assert (spool.path.stat().st_mode & 0o777) == 0o600
    restored = store.load(recovered[0].audio)
    assert restored.shape == pcm.shape
    # Five samples in: an Opus frame cannot represent them exactly, but the
    # recovered clip must still hold the same audio, in order.
    assert np.max(np.abs(restored - pcm)) < 0.05

    store.ack_interrupted("session-123")
    assert not spool.path.exists()


@requires_opus
def test_interrupted_spool_archives_as_ogg(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = _speechlike(0.5)
    spool = store.begin_active("crash-session")
    assert spool is not None and spool.append(pcm)
    spool.close()

    recovered = store.recover_interrupted()

    assert recovered and recovered[0].audio == "crash-session.ogg"
    assert recovered[0].duration_s == pytest.approx(pcm.shape[0] / SAMPLE_RATE)
    back = store.load(recovered[0].audio)
    assert back.shape == pcm.shape
    assert _correlation(back, pcm) > 0.95
    assert store.ack_interrupted("crash-session")


def test_empty_interrupted_spool_is_discarded(tmp_path):
    store = AudioStore(tmp_path / "audio")
    spool = store.begin_active("empty-session")
    assert spool is not None
    spool.close()

    assert store.recover_interrupted() == []
    assert not spool.path.exists()


def test_audio_store_rejects_traversal(tmp_path):
    store = AudioStore(tmp_path / "audio")
    assert store.path_for("../secret.ogg") is None
    assert store.path_for("a/b.ogg") is None
    assert store.path_for("../secret.flac") is None
    assert store.path_for("a/b.flac") is None
    assert store.path_for("evil.txt") is None
    assert store.path_for("evil.ogg.pcm16.part") is None
    assert store.path_for("clip.ogg") is not None
    with pytest.raises(ValueError):
        store.load("../../etc/passwd")


def test_audio_store_empty_is_noop(tmp_path):
    store = AudioStore(tmp_path / "audio")
    assert store.save("s", np.zeros(0, dtype=np.float32)) is None


def test_audio_store_wav_fallback_roundtrips_and_sanitizes(tmp_path):
    store = AudioStore(tmp_path / "audio")
    store._sf = None
    store._codec = None
    store.ext = "wav"
    pcm = np.array([np.nan, np.inf, -np.inf, -0.25, 0.25], dtype=np.float32)

    name = store.save("unsafe/session id", pcm)

    assert name == "unsafe-session-id.wav"
    restored = store.load(name)
    assert restored.shape == pcm.shape
    assert np.isfinite(restored).all()
    assert np.max(np.abs(restored)) <= 1.0


def test_audio_store_write_failure_does_not_break_dictation(tmp_path):
    class BrokenSoundFile:
        @staticmethod
        def write(path, *_args, **_kwargs):
            Path(path).write_bytes(b"partial")
            raise OSError("disk unavailable")

    audio_dir = tmp_path / "audio"
    store = AudioStore(audio_dir)
    store._sf = BrokenSoundFile()

    assert store.save("session", np.ones(10, dtype=np.float32)) is None
    assert not (audio_dir / f"session.{store.ext}").exists()
    assert list(audio_dir.glob(".*.tmp")) == []


def test_audio_store_prune_missing_directory_is_noop(tmp_path):
    store = AudioStore(tmp_path / "missing")
    assert store.prune(retention_days=180, max_bytes=1024) == 0


def test_audio_store_prune_size_cap_evicts_oldest(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = (0.1 * np.sin(np.linspace(0, 100, 16000))).astype(np.float32)  # ~1s
    now = time.time()
    names = []
    for i in range(4):
        n = store.save(f"clip-{i}", pcm)
        names.append(n)
        # Recent, staggered mtimes so retention keeps them all (clip-0 oldest);
        # only the size cap should evict.
        p = store.path_for(n)
        os.utime(p, (now - (10 - i), now - (10 - i)))
    sizes = [store.path_for(n).stat().st_size for n in names]
    # Cap that fits ~2 clips → the 2 oldest are evicted.
    cap = sizes[-1] * 2 + 1
    deleted = store.prune(retention_days=3650, max_bytes=cap)
    assert deleted >= 1
    assert not store.path_for(names[0]).exists()  # oldest gone
    assert store.path_for(names[-1]).exists()  # newest kept
    total = sum(store.path_for(n).stat().st_size for n in names if store.path_for(n).exists())
    assert total <= cap


def test_audio_store_prune_retention_and_cap(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = (0.1 * np.sin(np.linspace(0, 100, 8000))).astype(np.float32)
    old = store.save("old-clip", pcm)
    store.save("new-clip", pcm)
    # Age the first clip past retention.
    old_path = store.path_for(old)
    stale = time.time() - 400 * 86400

    os.utime(old_path, (stale, stale))
    deleted = store.prune(retention_days=180, max_bytes=None)
    assert deleted == 1
    assert not old_path.exists()


# ---- server integration (fake STT) ----


@pytest.fixture
async def engine(home, fake_stt):
    config = Config()
    eng = Engine(config, parent_pid=None)
    sock_dir = Path(tempfile.mkdtemp(prefix="velora-a-"))
    sock = sock_dir / "e.sock"
    task = asyncio.create_task(eng.serve(sock))
    for _ in range(100):
        if sock.exists():
            break
        await asyncio.sleep(0.01)
    yield eng, sock, config
    eng.shutdown.set()
    await asyncio.wait_for(task, 5)
    shutil.rmtree(sock_dir, ignore_errors=True)


async def _dictate(client: Client, session: str) -> dict:
    await client.send_json({"cmd": "start", "session": session, "context": {}})
    for _ in range(10):
        await client.send_audio(AUDIO)
    await client.send_json({"cmd": "stop", "session": session})
    await client.recv_event("transcript")
    return await client.recv_event("final")


async def _wait_for_clip(path) -> None:
    """The archive write is intentionally backgrounded (final must not wait on
    disk I/O) — poll briefly for the file."""
    for _ in range(100):
        if path.exists():
            return
        await asyncio.sleep(0.02)
    raise AssertionError(f"clip never appeared: {path}")


async def test_final_includes_saved_audio(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "s1")
    assert "audio" in final, "final event should carry the archived clip name"
    await _wait_for_clip(config.audio_dir / final["audio"])
    client.close()


async def test_normal_stop_removes_spool_after_history_ack(engine):
    _eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "normal-stop", "context": {}})
    await client.send_audio(AUDIO)
    spool = config.audio_dir / ".active" / "normal-stop.pcm16.part"
    for _ in range(100):
        if spool.exists() and spool.stat().st_size == AUDIO.size * 2:
            break
        await asyncio.sleep(0.01)
    assert spool.exists()

    await client.send_json({"cmd": "stop", "session": "normal-stop"})
    final = await client.recv_event("final")
    await _wait_for_clip(config.audio_dir / final["audio"])
    assert spool.exists()

    await client.send_json({"cmd": "ack_final", "session": "normal-stop"})
    await client.send_json({"cmd": "ping"})
    assert (await client.recv_event("pong"))["event"] == "pong"
    for _ in range(100):
        if not spool.exists():
            break
        await asyncio.sleep(0.01)
    assert not spool.exists()
    client.close()


async def test_disconnect_emits_recoverable_audio_until_ack(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "lost-client", "context": {}})
    await client.send_audio(AUDIO)
    client.close()
    for _ in range(100):
        if eng.session is None and eng.writer is None:
            break
        await asyncio.sleep(0.01)
    assert eng.session is None

    replacement = await connect(sock)
    await replacement.recv_event("ready")
    recovered = await replacement.recv_event("interrupted_dictation")

    assert recovered["session"] == "lost-client"
    assert recovered["duration_s"] == pytest.approx(0.1)
    assert "text" not in recovered
    assert "raw" not in recovered
    assert (config.audio_dir / recovered["audio"]).is_file()
    spool = config.audio_dir / ".active" / "lost-client.pcm16.part"
    assert spool.is_file()

    await replacement.send_json({"cmd": "ack_interrupted", "session": "lost-client"})
    ack = await replacement.recv_event("interrupted_ack")
    assert ack == {"event": "interrupted_ack", "session": "lost-client"}
    assert not spool.exists()
    replacement.close()


async def test_interrupt_preserves_spool_and_acknowledges(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "graceful-quit", "context": {}})
    await client.send_audio(AUDIO)

    await client.send_json({"cmd": "ack_interrupted", "session": "graceful-quit"})
    error = await client.recv_event("error")
    assert error["message"] == "ack_interrupted: session is not recoverable"

    await client.send_json({"cmd": "interrupt", "session": "graceful-quit"})
    interrupted = await client.recv_event("interrupted")

    assert interrupted == {
        "event": "interrupted",
        "session": "graceful-quit",
        "duration_s": pytest.approx(0.1),
    }
    assert eng.session is None
    spool = config.audio_dir / ".active" / "graceful-quit.pcm16.part"
    assert spool.is_file()
    assert spool.stat().st_size == AUDIO.size * 2
    client.close()


async def test_explicit_cancel_deletes_active_spool(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "cancelled", "context": {}})
    await client.send_audio(AUDIO)

    await client.send_json({"cmd": "cancel", "session": "cancelled"})
    await client.recv_event("cancelled")

    assert eng.session is None
    spool = config.audio_dir / ".active" / "cancelled.pcm16.part"
    assert not spool.exists()
    assert "cancelled" not in eng.audio.pending_interrupted()
    client.close()


async def test_reprocess_roundtrip(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "s2")
    name = final["audio"]
    await _wait_for_clip(config.audio_dir / name)

    await client.send_json({"cmd": "reprocess", "audio": name, "id": 42})
    evt = await client.recv_event("reprocessed")
    assert evt["audio"] == name
    assert evt["id"] == 42
    assert evt["raw"] == "hello world this is a fake transcript"
    assert isinstance(evt["stt_ms"], int)
    client.close()


async def test_reprocess_lease_is_correlated_and_outlives_ui_and_decoder_release(engine):
    import uuid
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "lease-source")
    await _wait_for_clip(config.audio_dir / final["audio"])
    first, second = str(uuid.uuid4()), str(uuid.uuid4())
    decoding, allow_decode = asyncio.Event(), asyncio.Event()
    releasing, allow_release = asyncio.Event(), asyncio.Event()
    original_call = eng._stt_call
    original_send = eng._send
    activities = []

    async def controlled(function, *arguments):
        if function.__name__ == "transcribe_clip":
            decoding.set()
            await allow_decode.wait()
        if function.__name__ == "_release_stt_memory":
            releasing.set()
            await allow_release.wait()
        return await original_call(function, *arguments)

    async def capture(event):
        if event.get("event") == "reprocess_activity":
            activities.append(event)
        await original_send(event)

    eng._stt_call, eng._send = controlled, capture
    try:
        await client.send_json({"cmd": "reprocess", "audio": final["audio"], "id": 42, "request_id": first})
        await asyncio.wait_for(decoding.wait(), 2)
        assert any(e["request_id"] == first and e["active"] for e in activities)
        await client.send_json({"cmd": "reprocess", "audio": final["audio"], "id": 42, "request_id": second})
        await client.recv_event("reprocess_failed")
        for _ in range(100):
            if any(e["request_id"] == second and not e["active"] for e in activities):
                break
            await asyncio.sleep(.01)
        assert any(e["request_id"] == second and not e["active"] for e in activities)
        assert not any(e["request_id"] == first and not e["active"] for e in activities)
        allow_decode.set()
        await client.recv_event("reprocessed")
        await asyncio.wait_for(releasing.wait(), 2)
        assert not any(e["request_id"] == first and not e["active"] for e in activities)
        allow_release.set()
        for _ in range(100):
            if any(e["request_id"] == first and not e["active"] for e in activities):
                break
            await asyncio.sleep(.01)
        assert any(e["request_id"] == first and not e["active"] for e in activities)
    finally:
        allow_decode.set(); allow_release.set()
        client.close()


async def test_ready_replays_reprocessing_lease_across_socket_reconnect(engine):
    import uuid
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "lease-reconnect")
    await _wait_for_clip(config.audio_dir / final["audio"])
    request = str(uuid.uuid4())
    entered, release = asyncio.Event(), asyncio.Event()
    original = eng._stt_call

    async def controlled(function, *arguments):
        if getattr(function, "__name__", "") == "transcribe_clip":
            entered.set()
            await release.wait()
        return await original(function, *arguments)

    eng._stt_call = controlled
    replacement = None
    try:
        await client.send_json({"cmd": "reprocess", "audio": final["audio"], "id": 81, "request_id": request})
        await asyncio.wait_for(entered.wait(), 2)
        client.close()
        await client.writer.wait_closed()
        for _ in range(100):
            if eng.writer is None:
                break
            await asyncio.sleep(.01)
        replacement = await connect(sock)
        ready = await replacement.recv_event("ready")
        assert ready["reprocess_jobs"] == [{"request_id": request, "audio": final["audio"]}]
        release.set()
        await replacement.recv_event("reprocessed")
        event = await replacement.recv_event("reprocess_activity")
        assert event["request_id"] == request and event["active"] is False
        assert eng._reprocess_leases == {}
    finally:
        release.set()
        client.close()
        if replacement:
            replacement.close()


async def test_adoption_rejection_settles_preprotected_reprocess_request(engine):
    import uuid
    eng, sock, _ = engine
    client = await connect(sock)
    await client.recv_event("ready")
    request = str(uuid.uuid4())
    eng._adopting = True
    try:
        await client.send_json({"cmd": "reprocess", "audio": "not-admitted.wav", "request_id": request})
        failure = await client.recv_event("reprocess_failed")
        assert failure["code"] == "busy"
        event = await client.recv_event("reprocess_activity")
        assert event["request_id"] == request and event["active"] is False
        assert not eng._reprocess_leases
    finally:
        eng._adopting = False
        client.close()


async def test_reprocess_restores_live_language(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "s-lang")
    await _wait_for_clip(config.audio_dir / final["audio"])
    original = eng.stt.language  # "auto"
    # Reprocess with a language override that borrows the live backend.
    await client.send_json({"cmd": "reprocess", "audio": final["audio"], "language": "hi"})
    await client.recv_event("reprocessed")
    assert eng.stt.language == original, "live backend language must be restored after reprocess"
    client.close()


async def test_reprocess_missing_clip_errors(engine):
    eng, sock, config = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "reprocess", "audio": "does-not-exist.flac"})
    evt = await client.recv_event("reprocess_failed")
    assert "audio unavailable" in evt["error"]
    assert evt["code"] == "invalid_file"
    client.close()


async def test_save_audio_disabled(engine):
    eng, sock, config = engine
    config.data["save_audio"] = False
    client = await connect(sock)
    await client.recv_event("ready")
    final = await _dictate(client, "s3")
    assert "audio" not in final
    assert not (config.audio_dir / ".active" / "s3.pcm16.part").exists()
    client.close()
