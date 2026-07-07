"""velora-engine: asyncio unix-socket server (single client).

Lifecycle:
- STT model warm-loads at startup; `{"event":"ready",...}` is sent to a client
  once the model is loaded. The cleanup LLM warms in the background.
- start → audio frames stream into the STT backend during recording →
  stop → finalize transcript → formatting pipeline → `transcript` then `final`.
- cancel discards. Malformed frames/commands produce an `error` event, never a
  crash.
- Exits on SIGTERM, or when the client has disconnected AND the parent pid
  (--parent-pid) is gone.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import signal
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, TypeVar

import numpy as np

from . import __version__, formatting, models, protocol
from .audio_store import AudioStore
from .cleanup import CleanupEngine
from .config import Config
from .formatting import STATIC_SYSTEM_PROMPT
from .stt import (
    SAMPLE_RATE,
    STTBackend,
    create_backend,
    fake_stt_enabled,
    pcm_from_payload,
    transcribe_clip,
)

T = TypeVar("T")

log = logging.getLogger("velora.server")

PARENT_POLL_S = 2.0

# Bound the per-session audio queue: ~60s of backlog at 100ms chunks. If STT
# falls that far behind realtime, frames are dropped; past MAX_DROPPED_FRAMES
# the session is aborted with an error event (fail loudly instead of OOM).
QUEUE_MAX_FRAMES = 600
MAX_DROPPED_FRAMES = 50


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Session:
    def __init__(self, session_id: str, context: dict[str, Any], owner: asyncio.StreamWriter | None = None) -> None:
        self.id = session_id
        self.context = context or {}
        self.queue: asyncio.Queue[Any] = asyncio.Queue(maxsize=QUEUE_MAX_FRAMES)
        self.feeder: asyncio.Task[None] | None = None
        self.cancelled = False
        self.samples = 0
        self.dropped = 0  # frames dropped because the queue was full
        self.started = time.perf_counter()
        # The connection that started this session. A displaced client's
        # cleanup must only abort a session it still owns (reconnect race).
        self.owner = owner
        # Raw PCM kept for the audio archive (independent of the STT queue, so
        # dropped-for-latency frames are still archived). Bounded by
        # max_recording_s; cleared on finalize/abort.
        self.pcm_chunks: list[np.ndarray] = []


class Engine:
    def __init__(self, config: Config, parent_pid: int | None = None) -> None:
        self.config = config
        self.parent_pid = parent_pid
        self.stt: STTBackend = create_backend(config.stt_model, config.language)
        # A lazily-loaded backend used only for reprocessing history with a
        # DIFFERENT model than the live one; cached so re-transcribing several
        # clips with the same model doesn't reload it each time.
        self._reprocess_backend: STTBackend | None = None
        # Reprocess runs off the dispatch loop; this flag blocks a live session
        # from starting mid-reprocess (they'd race on the shared STT backend).
        self._reprocessing = False
        self.audio = AudioStore(config.audio_dir)
        self.stt_ready = asyncio.Event()
        self.cleanup: CleanupEngine | None = None
        self.session: Session | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.shutdown = asyncio.Event()
        self._server: asyncio.Server | None = None
        self._client_gen = 0
        # MLX streams are thread-affine: all STT model work must run on ONE
        # dedicated thread (the cleanup LLM likewise owns its own thread).
        self._stt_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stt")

    async def _stt_call(self, fn: Callable[..., T], *args: Any) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._stt_executor, fn, *args)

    # ---------------- model loading ----------------

    async def _load_models(self) -> None:
        try:
            t0 = time.perf_counter()
            await self._stt_call(self.stt.load)
            log.info("stt ready (%s) in %.2fs", self.stt.model_id, time.perf_counter() - t0)
        except Exception:
            log.exception("FATAL: STT model failed to load")
            self.shutdown.set()
            return
        self.stt_ready.set()
        # Enforce audio retention once at startup (deletes clips > 6 months and
        # trims the archive under its size cap).
        if self.config.save_audio:
            with contextlib.suppress(Exception):
                await asyncio.to_thread(
                    self.audio.prune, self.config.audio_retention_days, self.config.audio_max_bytes
                )
        if self.config.cleanup_enabled and not fake_stt_enabled():
            engine = CleanupEngine(self.config.cleanup_model)
            try:
                await engine.load_async(STATIC_SYSTEM_PROMPT)
                self.cleanup = engine
            except Exception:
                log.exception("cleanup LLM failed to load; dictations will return raw text")

    # ---------------- serving ----------------

    async def serve(self, socket_path: Path) -> None:
        socket_path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            socket_path.unlink()
        # Pre-set a restrictive umask so the socket is never world-accessible,
        # even for the instant between bind and the explicit chmod below.
        old_umask = os.umask(0o177)
        try:
            self._server = await asyncio.start_unix_server(self._on_client, path=str(socket_path))
        finally:
            os.umask(old_umask)
        os.chmod(socket_path, 0o600)
        log.info("listening on %s (pid %d, parent %s)", socket_path, os.getpid(), self.parent_pid)

        loader = asyncio.create_task(self._load_models())
        watchdog = asyncio.create_task(self._watch_parent())
        try:
            await self.shutdown.wait()
        finally:
            watchdog.cancel()
            loader.cancel()
            self._server.close()
            with contextlib.suppress(asyncio.CancelledError):
                await self._server.wait_closed()
            with contextlib.suppress(FileNotFoundError):
                socket_path.unlink()
            log.info("engine shut down")

    async def _watch_parent(self) -> None:
        if self.parent_pid is None:
            return
        while True:
            await asyncio.sleep(PARENT_POLL_S)
            if not _pid_alive(self.parent_pid):
                if self.writer is None:
                    log.info("parent pid %d gone and no client — exiting", self.parent_pid)
                    self.shutdown.set()
                    return
                log.warning("parent pid %d gone; will exit when client disconnects", self.parent_pid)

    async def _on_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._client_gen += 1
        gen = self._client_gen
        if self.writer is not None:
            log.warning("new client connected; dropping previous client")
            old = self.writer
            self.writer = None
            with contextlib.suppress(Exception):
                old.close()
        self.writer = writer
        log.info("client %d connected", gen)
        try:
            await self.stt_ready.wait()
            await self._send(
                {
                    "event": "ready",
                    "stt_model": self.stt.model_id,
                    "cleanup_model": self.config.cleanup_model if self.config.cleanup_enabled else None,
                    "version": __version__,
                }
            )
            while True:
                try:
                    frame_type, payload = await protocol.read_frame(reader)
                except (asyncio.IncompleteReadError, ConnectionResetError):
                    break
                except protocol.ProtocolError as exc:
                    # Framing desync is unrecoverable on this connection.
                    await self._send({"event": "error", "message": str(exc), "fatal": True})
                    break
                await self._dispatch(frame_type, payload)
        except Exception:
            log.exception("client handler error")
        finally:
            await self._client_cleanup(writer)
            log.info("client %d disconnected", gen)
            if self.parent_pid is not None and not _pid_alive(self.parent_pid):
                log.info("client gone and parent pid dead — exiting")
                self.shutdown.set()

    async def _client_cleanup(self, writer: asyncio.StreamWriter) -> None:
        """Tear down one connection. Only aborts the session it still owns:
        a displaced old handler must never discard a session the new client
        started (reconnect race)."""
        if self.writer is writer:
            self.writer = None
        with contextlib.suppress(Exception):
            writer.close()
        session = self.session
        if session is not None and session.owner is writer:
            await self._abort_session("client disconnected")

    async def _send(self, obj: dict[str, Any]) -> None:
        writer = self.writer
        if writer is None:
            return
        try:
            writer.write(protocol.encode_json(obj))
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            log.warning("client write failed (disconnected)")

    async def _error(self, message: str, session: str | None = None) -> None:
        log.warning("error event: %s", message)
        evt: dict[str, Any] = {"event": "error", "message": message}
        if session:
            evt["session"] = session
        await self._send(evt)

    # ---------------- dispatch ----------------

    async def _dispatch(self, frame_type: int, payload: bytes) -> None:
        if frame_type == protocol.FRAME_AUDIO:
            await self._on_audio(payload)
            return
        if frame_type != protocol.FRAME_JSON:
            await self._error(f"unknown frame type 0x{frame_type:02x}")
            return
        try:
            msg = json.loads(payload.decode("utf-8"))
            if not isinstance(msg, dict):
                raise ValueError("control frame is not a JSON object")
        except (ValueError, UnicodeDecodeError) as exc:
            await self._error(f"malformed control frame: {exc}")
            return
        cmd = msg.get("cmd")
        try:
            if cmd == "start":
                await self._cmd_start(msg)
            elif cmd == "stop":
                await self._cmd_stop(msg)
            elif cmd == "cancel":
                await self._cmd_cancel(msg)
            elif cmd == "ping":
                await self._send({"event": "pong", "ts": time.time()})
            elif cmd == "status":
                await self._cmd_status()
            elif cmd == "reload_config":
                self.config.reload()
                # Whisper reads `language` at transcribe time; propagate the
                # (possibly changed) setting without reloading the backend.
                if hasattr(self.stt, "language"):
                    self.stt.language = self.config.language
                await self._send({"event": "config_reloaded"})
            elif cmd == "set_model":
                await self._cmd_set_model(msg)
            elif cmd == "reprocess":
                await self._cmd_reprocess(msg)
            else:
                await self._error(f"unknown command: {cmd!r}")
        except Exception as exc:  # noqa: BLE001 — commands must never crash the engine
            log.exception("command %r failed", cmd)
            await self._error(f"command {cmd!r} failed: {exc}")

    # ---------------- session state machine ----------------

    async def _cmd_start(self, msg: dict[str, Any]) -> None:
        if self._reprocessing:
            # A background reprocess may be using the live STT backend; starting
            # now would corrupt its stream state. Ask the app to retry.
            await self._error("busy reprocessing a clip — try again in a moment")
            return
        if self.session is not None:
            log.warning("start while session %s active — discarding it", self.session.id)
            await self._abort_session("superseded by new start")
        session_id = str(msg.get("session") or uuid.uuid4())
        context = msg.get("context") or {}
        if not isinstance(context, dict):
            context = {}
        session = Session(session_id, context, owner=self.writer)
        await self._stt_call(self.stt.start_session)
        session.feeder = asyncio.create_task(self._feed_loop(session))
        self.session = session
        log.info(
            "session %s started (bundle_id=%s app=%s mode=%s)",
            session_id,
            context.get("bundle_id"),
            context.get("app_name"),
            context.get("mode"),
        )

    async def _feed_loop(self, session: Session) -> None:
        last_partial = ""
        while True:
            chunk = await session.queue.get()
            if chunk is None:
                return
            if session.cancelled:  # aborted: just drain, don't feed STT
                continue
            try:
                partial = await self._stt_call(self.stt.feed_chunk, chunk)
            except Exception:
                log.exception("feed_chunk failed")
                continue
            if (
                partial
                and partial.strip()
                and partial != last_partial
                and not session.cancelled
                and self.session is session
            ):
                last_partial = partial
                await self._send({"event": "partial", "session": session.id, "text": partial.strip()})

    async def _on_audio(self, payload: bytes) -> None:
        session = self.session
        if session is None or session.cancelled:
            log.debug("audio frame while idle — dropped (%d bytes)", len(payload))
            return
        try:
            chunk = pcm_from_payload(payload)
        except ValueError as exc:
            await self._error(f"bad audio frame: {exc}", session.id)
            return
        # Archive the raw audio before queueing for STT: a frame dropped below
        # for latency reasons must still make it into the saved clip.
        if self.config.save_audio:
            session.pcm_chunks.append(chunk)
        try:
            session.queue.put_nowait(chunk)
        except asyncio.QueueFull:
            session.dropped += 1
            if session.dropped == 1 or session.dropped % 25 == 0:
                log.warning(
                    "session %s: audio queue full — dropping frames (%d dropped)",
                    session.id,
                    session.dropped,
                )
            if session.dropped > MAX_DROPPED_FRAMES:
                await self._error(
                    "audio queue overflow: transcription can't keep up — session aborted",
                    session.id,
                )
                await self._abort_session("audio queue overflow")
            return
        session.samples += len(chunk)
        if session.samples > self.config.max_recording_s * SAMPLE_RATE:
            # Max-duration guard: auto-finalize as if `stop` was received, so a
            # stuck/locked recording can't accumulate audio (and, on the whisper
            # backend, batch-decode latency) without bound.
            log.warning(
                "session %s hit max recording duration (%.0fs) — auto-finalizing",
                session.id,
                self.config.max_recording_s,
            )
            self.session = None
            await self._finalize_session(session, auto_stopped=True)

    async def _drain_feeder(self, session: Session) -> None:
        try:
            session.queue.put_nowait(None)
        except asyncio.QueueFull:
            # Queue jammed (STT stalled). Cancel the feeder instead of blocking
            # the dispatch loop behind a wedged backend.
            if session.feeder is not None:
                session.feeder.cancel()
        if session.feeder is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await session.feeder

    async def _abort_session(self, why: str) -> None:
        session = self.session
        if session is None:
            return
        self.session = None
        session.cancelled = True
        session.pcm_chunks = []  # discard archived audio for a cancelled session
        await self._drain_feeder(session)
        await self._stt_call(self.stt.reset)
        log.info("session %s discarded (%s)", session.id, why)

    async def _cmd_cancel(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            await self._error("cancel: no active session", msg.get("session"))
            return
        await self._abort_session("cancel")
        await self._send({"event": "cancelled", "session": session.id})

    async def _cmd_stop(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            await self._error("stop: no active session", msg.get("session"))
            return
        self.session = None
        await self._finalize_session(session)

    async def _finalize_session(self, session: Session, auto_stopped: bool = False) -> None:
        t_stop = time.perf_counter()
        await self._drain_feeder(session)
        try:
            raw = await self._stt_call(self.stt.finalize)
        except Exception as exc:
            log.exception("finalize failed")
            await self._stt_call(self.stt.reset)
            await self._error(f"transcription failed: {exc}", session.id)
            return
        stt_ms = int((time.perf_counter() - t_stop) * 1000)
        await self._send({"event": "transcript", "session": session.id, "raw": raw, "ms": stt_ms})

        # Stage 2: formatting pipeline.
        ctx = session.context
        text, mode_name, cleanup_ms, cleanup_applied, reason = await self._apply_formatting(
            raw,
            bundle_id=ctx.get("bundle_id"),
            app_name=ctx.get("app_name"),
            explicit_mode=ctx.get("mode"),
        )

        # Stage 3: archive the audio clip (off the event loop) so it can be
        # reprocessed later. Failure never affects the dictation result.
        audio_name = await self._archive_audio(session)

        total_ms = int((time.perf_counter() - t_stop) * 1000)
        final_evt: dict[str, Any] = {
            "event": "final",
            "session": session.id,
            "text": text,
            "raw": raw,
            "mode": mode_name,
            "cleanup_ms": cleanup_ms,
            "cleanup_applied": cleanup_applied,
        }
        if audio_name:
            final_evt["audio"] = audio_name
        if auto_stopped:
            final_evt["auto_stopped"] = True
        await self._send(final_evt)
        log.info(
            "session %s done: stt_ms=%d mode=%s reason=%s cleanup_ms=%d cleanup_applied=%s total_ms=%d samples=%d audio=%s",
            session.id,
            stt_ms,
            mode_name,
            reason,
            cleanup_ms,
            cleanup_applied,
            total_ms,
            session.samples,
            audio_name or "-",
        )

    async def _apply_formatting(
        self,
        raw: str,
        bundle_id: str | None,
        app_name: str | None,
        explicit_mode: str | None,
    ) -> tuple[str, str, int, bool, str]:
        """Run the gate + optional LLM cleanup. Returns
        (text, mode_name, cleanup_ms, cleanup_applied, reason). Shared by live
        finalize and history reprocessing."""
        gate = formatting.run_gate(
            raw,
            self.config,
            bundle_id=bundle_id,
            app_name=app_name,
            explicit_mode=explicit_mode,
        )
        if not raw.strip():
            return "", gate.mode.name, 0, False, "empty_transcript"
        if gate.use_llm and self.cleanup is not None and self.cleanup.loaded:
            if gate.romanize:
                # Transliteration: skip the length-ratio guard and allow longer.
                result = await self.cleanup.cleanup(
                    raw, gate.system_prompt or STATIC_SYSTEM_PROMPT, timeout_ms=4000, check_ratio=False
                )
            else:
                result = await self.cleanup.cleanup(raw, gate.system_prompt or STATIC_SYSTEM_PROMPT)
            if result.applied:
                text = formatting.postprocess(result.text, gate)
            else:
                text = formatting.postprocess(formatting.apply_spoken_commands(raw), gate)
            return text, gate.mode.name, result.ms, result.applied, result.reason or "llm"
        if gate.use_llm:
            text = formatting.postprocess(formatting.apply_spoken_commands(raw), gate)
            return text, gate.mode.name, 0, False, "cleanup_unavailable"
        return gate.text, gate.mode.name, 0, False, gate.reason

    async def _archive_audio(self, session: Session) -> str | None:
        """Persist the session's PCM as a clip and prune the archive. Off-thread;
        never raises into the caller."""
        if not self.config.save_audio or not session.pcm_chunks:
            return None
        chunks = session.pcm_chunks
        session.pcm_chunks = []
        try:
            pcm = np.concatenate(chunks)
        except ValueError:
            return None
        name = await asyncio.to_thread(self.audio.save, session.id, pcm)
        if name:
            # Prune is an O(clips) stat sweep — keep it OFF the stop→final path;
            # fire-and-forget so it never adds latency to the user's result.
            asyncio.create_task(self._prune_audio_bg())
        return name

    async def _prune_audio_bg(self) -> None:
        with contextlib.suppress(Exception):
            await asyncio.to_thread(
                self.audio.prune, self.config.audio_retention_days, self.config.audio_max_bytes
            )

    # ---------------- misc commands ----------------

    async def _cmd_status(self) -> None:
        await self._send(
            {
                "event": "status",
                "state": "recording" if self.session is not None else "idle",
                "stt_model": self.stt.model_id,
                "cleanup_model": self.config.cleanup_model,
                "cleanup_enabled": self.config.cleanup_enabled,
                "cleanup_loaded": bool(self.cleanup and self.cleanup.loaded),
                "save_audio": self.config.save_audio,
                "audio_retention_days": self.config.audio_retention_days,
                "language": self.config.language,
                "romanize_output": self.config.romanize_output,
                "models": models.registry_payload(),
                "version": __version__,
            }
        )

    async def _cmd_set_model(self, msg: dict[str, Any]) -> None:
        model_id = msg.get("model")
        if not model_id or not isinstance(model_id, str):
            await self._error("set_model: missing 'model'")
            return
        if self.session is not None:
            await self._error("set_model: busy (dictation in progress)")
            return
        info = models.lookup(model_id)
        kind = msg.get("kind") or (info.kind if info else "stt")
        if kind not in ("stt", "cleanup"):
            await self._error(f"set_model: unknown kind {kind!r}")
            return
        if not fake_stt_enabled():
            await asyncio.to_thread(models.ensure_downloaded, model_id)
        if kind == "stt":
            backend = create_backend(model_id, self.config.language)
            await self._stt_call(backend.load)
            self.stt = backend
            self.config.data["stt_model"] = model_id
        else:
            engine = CleanupEngine(model_id)
            if not fake_stt_enabled():
                await engine.load_async(STATIC_SYSTEM_PROMPT)
            self.cleanup = engine
            self.config.data["cleanup_model"] = model_id
        self.config.save()
        await self._send({"event": "model_set", "model": model_id, "kind": kind})
        log.info("switched %s model to %s", kind, model_id)

    async def _stt_for_reprocess(self, model_id: str, language: str) -> STTBackend:
        """Return a loaded backend for `model_id`: the live one if it matches,
        else a cached/freshly-loaded reprocessing backend."""
        if model_id == self.stt.model_id:
            if hasattr(self.stt, "language"):
                self.stt.language = language
            return self.stt
        cached = self._reprocess_backend
        if cached is not None and cached.model_id == model_id:
            if hasattr(cached, "language"):
                cached.language = language
            return cached
        if not fake_stt_enabled():
            await asyncio.to_thread(models.ensure_downloaded, model_id)
        backend = create_backend(model_id, language)
        await self._stt_call(backend.load)
        self._reprocess_backend = backend
        return backend

    async def _cmd_reprocess(self, msg: dict[str, Any]) -> None:
        """Re-transcribe a saved audio clip, optionally with a different model,
        mode, or language. Validates synchronously, then runs the (possibly
        slow) transcription off the dispatch loop so live control frames stay
        responsive. Emits a `reprocessed` event echoing the caller's id."""
        if self.session is not None:
            await self._error("reprocess: busy (dictation in progress)")
            return
        if self._reprocessing:
            await self._error("reprocess: busy (another reprocess in progress)")
            return
        name = msg.get("audio")
        if not name or not isinstance(name, str):
            await self._error("reprocess: missing 'audio'")
            return
        self._reprocessing = True
        asyncio.create_task(self._run_reprocess(dict(msg), name))

    async def _run_reprocess(self, msg: dict[str, Any], name: str) -> None:
        model_id = str(msg.get("stt_model") or self.stt.model_id)
        language = str(msg.get("language") or self.config.language)
        # Restore the live backend's language afterwards: _stt_for_reprocess may
        # borrow the live backend and set its language for this call.
        saved_language = getattr(self.stt, "language", None)
        try:
            try:
                pcm = await asyncio.to_thread(self.audio.load, name)
            except (FileNotFoundError, ValueError, OSError) as exc:
                await self._error(f"reprocess: audio unavailable: {exc}")
                return
            t0 = time.perf_counter()
            try:
                backend = await self._stt_for_reprocess(model_id, language)
                raw = await self._stt_call(transcribe_clip, backend, pcm)
            except Exception as exc:  # noqa: BLE001
                log.exception("reprocess transcription failed")
                await self._error(f"reprocess failed: {exc}")
                return
            stt_ms = int((time.perf_counter() - t0) * 1000)
            text, mode_name, cleanup_ms, cleanup_applied, _reason = await self._apply_formatting(
                raw,
                bundle_id=msg.get("bundle_id"),
                app_name=msg.get("app_name"),
                explicit_mode=msg.get("mode"),
            )
            evt: dict[str, Any] = {
                "event": "reprocessed",
                "audio": name,
                "raw": raw,
                "text": text,
                "mode": mode_name,
                "stt_model": model_id,
                "stt_ms": stt_ms,
                "cleanup_ms": cleanup_ms,
                "cleanup_applied": cleanup_applied,
            }
            if msg.get("id") is not None:
                evt["id"] = msg.get("id")
            await self._send(evt)
            log.info("reprocess %s with %s: stt_ms=%d mode=%s", name, model_id, stt_ms, mode_name)
        finally:
            if saved_language is not None and hasattr(self.stt, "language"):
                self.stt.language = saved_language
            self._reprocessing = False


# ---------------- entrypoint ----------------


async def _amain(args: argparse.Namespace) -> None:
    config = Config()
    socket_path = Path(args.socket) if args.socket else config.socket_path
    engine = Engine(config, parent_pid=args.parent_pid)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, engine.shutdown.set)

    await engine.serve(socket_path)


def main() -> None:
    parser = argparse.ArgumentParser(prog="velora-engine", description="Velora inference engine")
    parser.add_argument("--socket", default=None, help="unix socket path (default: $VELORA_HOME/engine.sock)")
    parser.add_argument("--parent-pid", type=int, default=None, help="exit when this pid dies and the client is gone")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args()

    logging.basicConfig(
        stream=sys.stderr,
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname).1s %(name)s %(message)s",
        datefmt="%H:%M:%S",
    )
    try:
        asyncio.run(_amain(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
