"""Audio archive + reprocess: AudioStore unit round-trip and the server's
save-on-finalize / reprocess-from-clip flow (fake STT)."""

import asyncio
import shutil
import tempfile
import time
from pathlib import Path

import numpy as np
import pytest

from velora_engine.audio_store import AudioStore
from velora_engine.config import Config
from velora_engine.server import Engine

from test_server import Client, connect  # reuse the socket client helper

AUDIO = (np.sin(np.linspace(0, 100, 1600)) * 0.1).astype(np.float32)  # 100ms chunk


# ---- AudioStore unit ----


def test_audio_store_roundtrip(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = (0.2 * np.sin(np.linspace(0, 300, 16000))).astype(np.float32)
    name = store.save("sess-XYZ_123", pcm)
    assert name and name.endswith((".flac", ".wav"))
    path = store.path_for(name)
    assert path is not None and path.exists()
    assert (path.stat().st_mode & 0o777) == 0o600
    back = store.load(name)
    assert back.shape[0] == pcm.shape[0]
    assert float(np.sqrt(np.mean((back - pcm) ** 2))) < 1e-3  # 16-bit quantization only


def test_interrupted_spool_recovers_until_acknowledged(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = np.array([-0.5, -0.25, 0.0, 0.25, 0.5], dtype=np.float32)

    spool = store.begin_active("session-123")
    assert spool is not None
    assert spool.append(pcm)
    spool.close()

    recovered = store.recover_interrupted()

    assert len(recovered) == 1
    assert recovered[0].session == "session-123"
    assert recovered[0].duration_s == pytest.approx(5 / 16_000)
    assert (store.dir.stat().st_mode & 0o777) == 0o700
    assert (spool.path.stat().st_mode & 0o777) == 0o600
    restored = store.load(recovered[0].audio)
    assert np.allclose(restored, pcm, atol=1e-3)

    store.ack_interrupted("session-123")
    assert not spool.path.exists()


def test_empty_interrupted_spool_is_discarded(tmp_path):
    store = AudioStore(tmp_path / "audio")
    spool = store.begin_active("empty-session")
    assert spool is not None
    spool.close()

    assert store.recover_interrupted() == []
    assert not spool.path.exists()


def test_audio_store_rejects_traversal(tmp_path):
    store = AudioStore(tmp_path / "audio")
    assert store.path_for("../secret.flac") is None
    assert store.path_for("a/b.flac") is None
    assert store.path_for("evil.txt") is None
    with pytest.raises(ValueError):
        store.load("../../etc/passwd")


def test_audio_store_empty_is_noop(tmp_path):
    store = AudioStore(tmp_path / "audio")
    assert store.save("s", np.zeros(0, dtype=np.float32)) is None


def test_audio_store_wav_fallback_roundtrips_and_sanitizes(tmp_path):
    store = AudioStore(tmp_path / "audio")
    store._sf = None
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
    store.ext = "flac"

    assert store.save("session", np.ones(10, dtype=np.float32)) is None
    assert not (audio_dir / "session.flac").exists()
    assert list(audio_dir.glob(".*.tmp")) == []


def test_archive_failure_preserves_active_spool(tmp_path):
    class BrokenSoundFile:
        @staticmethod
        def write(path, *_args, **_kwargs):
            Path(path).write_bytes(b"partial")
            raise OSError("disk unavailable")

    store = AudioStore(tmp_path / "audio")
    store._sf = BrokenSoundFile()
    store.ext = "flac"
    spool = store.begin_active("write-failure")
    assert spool is not None
    assert spool.append(AUDIO)

    assert store.finalize_active(spool) is None
    assert spool.path.is_file()
    assert spool.path.stat().st_size == AUDIO.size * 2


def test_audio_store_prune_missing_directory_is_noop(tmp_path):
    store = AudioStore(tmp_path / "missing")
    assert store.prune(retention_days=180, max_bytes=1024) == 0


def test_audio_store_prune_size_cap_evicts_oldest(tmp_path):
    store = AudioStore(tmp_path / "audio")
    pcm = (0.1 * np.sin(np.linspace(0, 100, 16000))).astype(np.float32)  # ~1s
    import os
    import time

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
    import os

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
