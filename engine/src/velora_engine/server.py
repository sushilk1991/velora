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

from . import __version__, formatting, models, protocol
from .cleanup import CleanupEngine
from .config import Config
from .formatting import STATIC_SYSTEM_PROMPT
from .stt import STTBackend, create_backend, fake_stt_enabled, pcm_from_payload

T = TypeVar("T")

log = logging.getLogger("velora.server")

PARENT_POLL_S = 2.0


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Session:
    def __init__(self, session_id: str, context: dict[str, Any]) -> None:
        self.id = session_id
        self.context = context or {}
        self.queue: asyncio.Queue[Any] = asyncio.Queue()
        self.feeder: asyncio.Task[None] | None = None
        self.cancelled = False
        self.samples = 0
        self.started = time.perf_counter()


class Engine:
    def __init__(self, config: Config, parent_pid: int | None = None) -> None:
        self.config = config
        self.parent_pid = parent_pid
        self.stt: STTBackend = create_backend(config.stt_model)
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
        self._server = await asyncio.start_unix_server(self._on_client, path=str(socket_path))
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
            if self.writer is writer:
                self.writer = None
            with contextlib.suppress(Exception):
                writer.close()
            await self._abort_session("client disconnected")
            log.info("client %d disconnected", gen)
            if self.parent_pid is not None and not _pid_alive(self.parent_pid):
                log.info("client gone and parent pid dead — exiting")
                self.shutdown.set()

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
                await self._send({"event": "config_reloaded"})
            elif cmd == "set_model":
                await self._cmd_set_model(msg)
            else:
                await self._error(f"unknown command: {cmd!r}")
        except Exception as exc:  # noqa: BLE001 — commands must never crash the engine
            log.exception("command %r failed", cmd)
            await self._error(f"command {cmd!r} failed: {exc}")

    # ---------------- session state machine ----------------

    async def _cmd_start(self, msg: dict[str, Any]) -> None:
        if self.session is not None:
            log.warning("start while session %s active — discarding it", self.session.id)
            await self._abort_session("superseded by new start")
        session_id = str(msg.get("session") or uuid.uuid4())
        context = msg.get("context") or {}
        if not isinstance(context, dict):
            context = {}
        session = Session(session_id, context)
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
        session.samples += len(chunk)
        session.queue.put_nowait(chunk)

    async def _drain_feeder(self, session: Session) -> None:
        session.queue.put_nowait(None)
        if session.feeder is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await session.feeder

    async def _abort_session(self, why: str) -> None:
        session = self.session
        if session is None:
            return
        self.session = None
        session.cancelled = True
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
        gate = formatting.run_gate(
            raw,
            self.config,
            bundle_id=ctx.get("bundle_id"),
            app_name=ctx.get("app_name"),
            explicit_mode=ctx.get("mode"),
        )
        cleanup_ms = 0
        cleanup_applied = False
        if not raw.strip():
            text, reason = "", "empty_transcript"
        elif gate.use_llm and self.cleanup is not None and self.cleanup.loaded:
            result = await self.cleanup.cleanup(raw, gate.system_prompt or STATIC_SYSTEM_PROMPT)
            cleanup_ms = result.ms
            cleanup_applied = result.applied
            reason = result.reason or "llm"
            if result.applied:
                text = formatting.postprocess(result.text, gate)
            else:  # fall back to raw, still honoring spoken newline commands
                text = formatting.postprocess(formatting.apply_spoken_commands(raw), gate)
        elif gate.use_llm:
            text = formatting.postprocess(formatting.apply_spoken_commands(raw), gate)
            reason = "cleanup_unavailable"
        else:
            text, reason = gate.text, gate.reason

        total_ms = int((time.perf_counter() - t_stop) * 1000)
        await self._send(
            {
                "event": "final",
                "session": session.id,
                "text": text,
                "raw": raw,
                "mode": gate.mode.name,
                "cleanup_ms": cleanup_ms,
                "cleanup_applied": cleanup_applied,
            }
        )
        log.info(
            "session %s done: stt_ms=%d gate=%s cleanup_ms=%d cleanup_applied=%s total_ms=%d samples=%d",
            session.id,
            stt_ms,
            gate.reason if not gate.use_llm else f"llm({reason})",
            cleanup_ms,
            cleanup_applied,
            total_ms,
            session.samples,
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
            backend = create_backend(model_id)
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
