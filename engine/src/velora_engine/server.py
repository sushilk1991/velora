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
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, TypeVar

import numpy as np

from . import __version__, diarization, editing, formatting, models, protocol
from .audio_store import AudioStore
from .cleanup import _RETRACTION_RE, CleanupEngine
from .config import Config
from .formatting import STATIC_SYSTEM_PROMPT
from .media import load_media, split_for_batch
from .meeting_notes import chunk_transcript, fallback_notes, merge_notes, parse_notes_json
from .stt import (
    SAMPLE_RATE,
    STTBackend,
    build_glossary_prompt,
    create_backend,
    fake_stt_enabled,
    pcm_from_payload,
    transcribe_clip,
)
from .vocab_miner import VocabMiner

T = TypeVar("T")

log = logging.getLogger("velora.server")

PARENT_POLL_S = 2.0

# Bound the per-session audio queue: ~60s of backlog at 100ms chunks. If STT
# falls that far behind realtime, frames are dropped; past MAX_DROPPED_FRAMES
# the session is aborted with an error event (fail loudly instead of OOM).
QUEUE_MAX_FRAMES = 600
MAX_DROPPED_FRAMES = 50

# Streaming-cleanup finalize: chunk cleanups run DURING recording and are
# nearly always done at stop; this bound only catches a wedged task (each has
# its own internal timeouts) before we give up and fall back to the whole-text
# pipeline.
STREAM_GATHER_TIMEOUT_S = 15.0

# Idle gap before (and between) vocab-mining steps — mining must only ever use
# compute nobody is waiting on, and yields the moment a session starts.
MINE_IDLE_S = 20.0
MINE_STARTUP_DELAY_S = 60.0

# Seam context for per-segment cleanup: the tail of the previous cleaned chunk
# rides along in the system prompt so seams punctuate/capitalize correctly.
CHUNK_CONTEXT_WORDS = 15
# A retraction marker within a segment's first few words refers back across
# the segment boundary — merge with the previous segment and re-clean.
RETRACTION_HEAD_WORDS = 4


@dataclass
class _ChunkResult:
    """Cleaned text for one raw segment (ms = LLM time, 0 for deterministic;
    applied = the LLM actually cleaned it, False for deterministic fallback)."""

    text: str
    ms: int
    applied: bool = False


def _join_chunks(parts: list[str]) -> str:
    """Join cleaned chunks with a single space — unless a chunk already ends
    with a line/paragraph break (spoken 'new paragraph'), which is kept as the
    separator instead of gluing a space after it."""
    out = ""
    for part in parts:
        cleaned = part.strip("\r ")
        if not cleaned.strip():
            continue
        if not out:
            out = cleaned
        elif out.endswith("\n"):
            out += cleaned.lstrip("\n")
        else:
            out += " " + cleaned
    return out.strip()


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
        self.preview_task: asyncio.Task[None] | None = None
        self.last_partial = ""
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
        # Streaming-cleanup state (smartness-v2 §2): raw segment texts taken
        # from the backend during recording, and the cleanup task per chunk
        # (chunk_tasks[i] cleans chunk_raws[i]).
        self.chunk_raws: list[str] = []
        self.chunk_tasks: list[asyncio.Task[_ChunkResult]] = []
        self.chunk_cancel_events: dict[asyncio.Task[_ChunkResult], threading.Event] = {}
        # Sticky: once any streaming gate fails (config off, no LLM, non-Latin
        # segment) the segments stay preview-only and finalize takes the
        # classic whole-text path.
        self.streaming_disabled = False
        # ONE system prompt for every chunk of this session, computed from the
        # first segment's gate. Per-chunk run_gate applied end-of-utterance
        # transforms (short-utterance period, per-chunk replacements/tag/strip)
        # at every seam — one gate, one final postprocess matches the
        # whole-text semantics (review finding).
        self.stream_prompt: str | None = None
        # Divergence allow-list paired with the sticky prompt: global personal
        # dictionary plus this session's active mode vocabulary, never terms
        # from inactive modes.
        self.stream_allowed_terms: list[str] = []
        # Entities snapshotted at start: during-speech chunks must use these —
        # `stop` merges richer entities into `context` later, and a chunk task
        # reading context lazily must not see them (they belong to the final
        # whole-text postprocess only).
        self.start_entities: list[dict[str, Any]] = [
            e for e in (self.context.get("entities") or []) if isinstance(e, dict)
        ]
        # Session prompt preparation runs on the cleanup model's owner thread
        # while audio is captured. The event reaches that thread even when the
        # asyncio wrapper is cancelled.
        self.prefix_task: asyncio.Task[Any] | None = None
        self.prefix_cancel = threading.Event()


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
        # File transcription (background job). Unlike reprocess it does NOT
        # block dictation: the job yields between chunks whenever a live
        # session is active, so the hotkey always wins.
        self._transcribing = False
        self._transcribe_cancel = False
        self._transcribe_preempt = threading.Event()
        self._file_transcribe_job_id: Any = None
        self._meeting_transcribe_cancel = False
        self._meeting_transcribe_job_id: Any = None
        # Meeting notes share the cleanup model but are chunked and
        # cooperatively preempted whenever live dictation starts.
        self._meeting_notes_running = False
        self._meeting_notes_cancel = False
        self._meeting_notes_preempt = threading.Event()
        self._meeting_notes_job_id: Any = None
        # True while a session's finalize is reading accumulated backend state.
        # `self.session` is already None then — the transcribe-file job must
        # ALSO wait on this, or its transcribe_clip() could reset the backend
        # between session-clear and finalize (transcript loss).
        self._finalizing = False
        # Mirror-image guard for START: `self.session` is published only after
        # the (possibly queued) start_session call returns, and a transcribe
        # chunk submitted in that window would destroy the fresh live stream
        # (review P0). Set synchronously at the top of _cmd_start.
        self._starting = False
        self.audio = AudioStore(config.audio_dir)
        self.stt_ready = asyncio.Event()
        # First-run setup progress ({"phase": str, "fraction": float|None}),
        # broadcast to the app so model downloads have visible UI. None when
        # nothing is loading.
        self.loading: dict[str, Any] | None = None
        # Onboarding waits for both the speech and writing model setup. This is
        # deliberately stricter than stt_ready, which unlocks raw dictation as
        # soon as the speech model is usable.
        self.setup_complete = False
        self.cleanup: CleanupEngine | None = None
        self.session: Session | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.shutdown = asyncio.Event()
        self._server: asyncio.Server | None = None
        self._client_gen = 0
        self._ready_client_gen: int | None = None
        self._setup_complete_sent_gen: int | None = None
        # MLX streams are thread-affine: all STT model work must run on ONE
        # dedicated thread (the cleanup LLM likewise owns its own thread).
        self._stt_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stt")
        # Idle vocabulary miner (created lazily; runs only when nothing else
        # is using the machine — see _mine_when_idle). The event preempts an
        # in-flight mining GENERATION the moment a session starts: cancelling
        # the asyncio task alone leaves the executor thread generating, and a
        # dictation's cleanup would queue behind it on the model lock.
        self._miner: VocabMiner | None = None
        self._miner_task: asyncio.Task[None] | None = None
        self._mine_cancel = threading.Event()

    async def _stt_call(self, fn: Callable[..., T], *args: Any) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._stt_executor, fn, *args)

    def _restart_if_cleanup_unhealthy(self) -> bool:
        """Restart the sidecar after its unkillable cleanup worker wedges.

        The caller must first send the user's raw fallback/result. Reusing the
        model from a replacement Python thread would violate MLX thread
        ownership while the old worker may still be inside native code, so a
        clean process restart is the only safe recovery boundary.
        """
        cleanup = self.cleanup
        if cleanup is None or not getattr(cleanup, "unhealthy", False):
            return False
        log.error("cleanup worker is unhealthy — restarting engine after fallback")
        self.shutdown.set()
        return True

    # ---------------- model loading ----------------

    async def _set_loading(self, phase: str | None, fraction: float | None = None) -> None:
        """Update + broadcast first-run progress. Phase None clears it (the
        cleared event is sent too — the app must drop a stale phase after the
        post-`ready` writing-model download finishes)."""
        self.loading = None if phase is None else {"phase": phase, "fraction": fraction}
        await self._send({"event": "loading", "phase": phase, "fraction": fraction})

    async def _send_setup_complete_if_ready(self, gen: int | None = None) -> None:
        """Send setup completion once per client, and never before `ready`."""
        gen = self._client_gen if gen is None else gen
        if (
            not self.setup_complete
            or gen != self._client_gen
            or self._ready_client_gen != gen
            or self._setup_complete_sent_gen == gen
        ):
            return
        self._setup_complete_sent_gen = gen
        await self._send({"event": "setup_complete"})

    async def _download_with_progress(self, model_id: str, what: str) -> None:
        """Run ensure_downloaded off-loop while broadcasting cache-growth
        progress every second ("Downloading speech model (1.6 GB) — 42%")."""
        info = models.lookup(model_id)
        size_note = f" ({info.size})" if info and info.size else ""
        phase = f"Downloading the {what} model{size_note}"
        expected = models.expected_bytes(model_id)
        task = asyncio.create_task(asyncio.to_thread(models.ensure_downloaded, model_id))
        best = 0.0  # hub renames finished blobs, so raw cache size can dip —
        while not task.done():  # a progress bar must never move backwards
            fraction = None
            if expected:
                done = await asyncio.to_thread(models.cached_bytes, model_id)
                best = max(best, min(0.999, done / expected))
                fraction = best
            await self._set_loading(phase, fraction)
            await asyncio.wait([task], timeout=1.0)
        await task  # propagate download errors

    async def _load_models(self) -> None:
        try:
            t0 = time.perf_counter()
            if not fake_stt_enabled() and not await asyncio.to_thread(
                models.is_cached, self.stt.model_id
            ):
                await self._download_with_progress(self.stt.model_id, "speech")
            await self._set_loading("Loading the speech model…")
            await self._stt_call(self.stt.load)
            await self._set_loading(None)
            log.info("stt ready (%s) in %.2fs", self.stt.model_id, time.perf_counter() - t0)
        except Exception:
            log.exception("FATAL: STT model failed to load")
            with contextlib.suppress(Exception):
                await self._set_loading(None)  # never strand a stale phase
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
                # Dictation is already available (raw text) — but the first-run
                # download of the cleanup LLM is multi-GB, so keep the progress
                # UI alive for it too.
                if not await asyncio.to_thread(models.is_cached, self.config.cleanup_model):
                    await self._download_with_progress(self.config.cleanup_model, "writing")
                    await self._set_loading("Preparing the writing model…")
                await engine.load_async(STATIC_SYSTEM_PROMPT)
                await self._set_loading(None)
                # A set_model during this warm-up may already have installed a
                # newer cleanup engine; don't clobber it (that would leak the new
                # one and silently run the old model). Only adopt this engine if
                # nothing newer took its place.
                if self.cleanup is None and self.config.cleanup_model == engine.model_id:
                    self.cleanup = engine
                else:
                    engine.close()
            except Exception:
                log.exception("cleanup LLM failed to load; dictations will return raw text")
                with contextlib.suppress(Exception):
                    await self._set_loading(None)  # never leave a stale phase up
        # Completion means no startup work remains. The writing model is an
        # optional enhancement: its terminal failure falls back to raw text
        # and must not strand onboarding forever after the download stops.
        self.setup_complete = True
        await self._send_setup_complete_if_ready()
        # First mining pass a while after startup — the loop itself re-checks
        # every skip condition (busy, LLM missing, disabled) before doing work.
        self._schedule_mining(delay=MINE_STARTUP_DELAY_S)

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
            if self._miner_task is not None:
                self._miner_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await self._miner_task
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
        # The Swift app owns the single control connection. A diagnostic or
        # stray same-user client must never evict it mid-dictation: reject the
        # newcomer and leave the active session untouched. Once the owner
        # disconnects, its handler clears `self.writer` and normal reconnects
        # are accepted by the next call.
        if self.writer is not None:
            log.warning("additional client rejected; active client retained")
            try:
                writer.write(protocol.encode_json({
                    "event": "error",
                    "message": "Engine already has an active client",
                    "fatal": True,
                }))
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                pass
            finally:
                writer.close()
                with contextlib.suppress(Exception):
                    await writer.wait_closed()
            return

        self._client_gen += 1
        gen = self._client_gen
        self.writer = writer
        log.info("client %d connected", gen)
        try:
            await self.stt_ready.wait()
            # A newer client can replace this one while both handlers are
            # waiting for the speech model. A superseded handler must not send
            # its ready frame through the new client's writer or overwrite the
            # generation that owns the later setup-complete event.
            if gen != self._client_gen or self.writer is not writer:
                return
            setup_complete_at_ready = self.setup_complete
            await self._send(
                {
                    "event": "ready",
                    "stt_model": self.stt.model_id,
                    "cleanup_model": self.config.cleanup_model if self.config.cleanup_enabled else None,
                    "version": __version__,
                    "setup_complete": setup_complete_at_ready,
                }
            )
            self._ready_client_gen = gen
            if setup_complete_at_ready:
                # The ready frame already carried the completion snapshot; do
                # not leave a redundant event queued behind it.
                self._setup_complete_sent_gen = gen
            # Current setup phase AFTER ready: the app clears its status on
            # `ready`, so sending before would erase a post-ready writing-model
            # phase for a client that connects mid-download (review finding).
            # Pre-ready download phases tick every second anyway.
            if self.loading is not None:
                await self._send({"event": "loading", **self.loading})
            await self._send_setup_complete_if_ready(gen)
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
            if self._ready_client_gen == gen:
                self._ready_client_gen = None
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

    async def _reprocess_failed(
        self, msg: dict[str, Any], error: str, code: str = "failed"
    ) -> None:
        evt: dict[str, Any] = {
            "event": "reprocess_failed", "error": error, "code": code,
        }
        if msg.get("id") is not None:
            evt["id"] = msg.get("id")
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
            elif cmd == "transcribe_file":
                await self._cmd_transcribe_file(msg)
            elif cmd == "transcribe_cancel":
                requested = msg.get("id")
                if self._file_transcribe_job_id is not None and (
                    requested is None or requested == self._file_transcribe_job_id
                ):
                    self._transcribe_cancel = True
                    self._transcribe_preempt.set()
            elif cmd == "meeting_transcribe":
                await self._cmd_meeting_transcribe(msg)
            elif cmd == "meeting_transcribe_cancel":
                requested = msg.get("id")
                if self._meeting_transcribe_job_id is not None and (
                    requested is None or requested == self._meeting_transcribe_job_id
                ):
                    self._meeting_transcribe_cancel = True
            elif cmd == "edit_text":
                await self._cmd_edit_text(msg)
            elif cmd == "meeting_notes":
                await self._cmd_meeting_notes(msg)
            elif cmd == "meeting_notes_cancel":
                requested = msg.get("id")
                if self._meeting_notes_job_id is not None and (
                    requested is None or requested == self._meeting_notes_job_id
                ):
                    self._meeting_notes_cancel = True
                    self._meeting_notes_preempt.set()
            else:
                await self._error(f"unknown command: {cmd!r}")
        except Exception as exc:  # noqa: BLE001 — commands must never crash the engine
            log.exception("command %r failed", cmd)
            await self._error(f"command {cmd!r} failed: {exc}")

    # ---------------- session state machine ----------------

    async def _cmd_start(self, msg: dict[str, Any]) -> None:
        # Explicit-mode file cleanup uses the same writing model as foreground
        # dictation. Stop it between tokens and retry the exact chunk later.
        self._transcribe_preempt.set()
        if self._reprocessing:
            # A background reprocess may be using the live STT backend; starting
            # now would corrupt its stream state. Ask the app to retry.
            await self._error("busy reprocessing a clip — try again in a moment")
            return
        # Fence the transcribe-file job out for the WHOLE start sequence:
        # start_session below queues behind any in-flight file chunk on the
        # single STT executor, and self.session isn't published until it
        # returns — without this flag the job would slip its next chunk in
        # between and wipe the just-started live stream (review P0).
        self._starting = True
        # Background note generation yields immediately; its cleanup worker
        # sees this event between output tokens, then the note job retries the
        # same chunk after dictation releases the model.
        self._meeting_notes_preempt.set()
        try:
            if self.session is not None:
                log.warning("start while session %s active — discarding it", self.session.id)
                await self._abort_session("superseded by new start")
            # A dictation owns the machine: stop any pending idle mining right now,
            # AND preempt an in-flight mining generation on the cleanup thread
            # (task cancellation alone can't reach the executor).
            if self._miner_task is not None:
                self._miner_task.cancel()
            self._mine_cancel.set()
            session_id = str(msg.get("session") or uuid.uuid4())
            context = msg.get("context") or {}
            if not isinstance(context, dict):
                context = {}
            session = Session(session_id, context, owner=self.writer)
            # STT contextual biasing: bias whisper toward the user's vocabulary and
            # the NAMES on screen right now (person/file/channel/subject entities
            # only — nearby free text is cleanup-prompt material, not glossary).
            self.stt.initial_prompt = self._glossary(session.start_entities)
            await self._stt_call(self.stt.start_session)
            session.feeder = asyncio.create_task(self._feed_loop(session))
            self.session = session
            self._start_prefix_preparation(session)
            # Let the preparation coroutine submit its executor job before a
            # very short dictation can enqueue final cleanup. This never waits
            # for model work, so audio acceptance remains immediate.
            await asyncio.sleep(0)
        finally:
            self._starting = False
        log.info(
            "session %s started (bundle_id=%s app=%s mode=%s)",
            session_id,
            context.get("bundle_id"),
            context.get("app_name"),
            context.get("mode"),
        )

    def _start_prefix_preparation(self, session: Session) -> None:
        cleanup = self.cleanup
        prepare = getattr(cleanup, "prepare_prefix", None)
        if (
            cleanup is None
            or not cleanup.loaded
            or getattr(cleanup, "unhealthy", False)
            or not callable(prepare)
        ):
            return
        ctx = session.context
        candidates = formatting.build_prefill_prompt_candidates(
            self.config,
            bundle_id=ctx.get("bundle_id"),
            app_name=ctx.get("app_name"),
            explicit_mode=ctx.get("mode"),
            entities=session.start_entities,
        )
        if not candidates:
            return

        async def run() -> None:
            try:
                await prepare(candidates, cancel_event=session.prefix_cancel)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 — prefill is an optimization
                log.exception("session %s cleanup prefix preparation failed", session.id)

        session.prefix_task = asyncio.create_task(run())

    @staticmethod
    def _cancel_prefix_preparation(session: Session) -> None:
        session.prefix_cancel.set()
        if session.prefix_task is not None and not session.prefix_task.done():
            session.prefix_task.cancel()

    async def _emit_partial(self, session: Session, partial: str | None) -> None:
        """Send one current-session partial, shared by stream and preview lanes."""
        text = (partial or "").strip()
        if (
            not text
            or text == session.last_partial
            or session.cancelled
            or self.session is not session
        ):
            return
        # Record before awaiting socket backpressure so two ready producers
        # cannot emit the same transcript while the first send is suspended.
        session.last_partial = text
        await self._send({"event": "partial", "session": session.id, "text": text})

    async def _feed_one(self, session: Session, chunk: np.ndarray) -> None:
        if session.cancelled:  # aborted: drain frames without touching STT
            return
        try:
            partial = await self._stt_call(self.stt.feed_chunk, chunk)
        except Exception:
            log.exception("feed_chunk failed")
            return
        await self._emit_partial(session, partial)
        # Segment streaming: clean freshly-decoded segments WHILE the user
        # speaks. Any failure only costs the streaming fast path; finalization
        # falls back to whole-text cleanup.
        try:
            for seg in self.stt.take_new_segments():
                self._on_new_segment(session, seg)
        except Exception:
            log.exception("segment scheduling failed")
            session.streaming_disabled = True

    async def _feed_loop(self, session: Session) -> None:
        while True:
            chunk = await session.queue.get()
            if chunk is None:
                return
            await self._feed_one(session, chunk)

            # A preview can hold the model thread briefly. Once it releases,
            # catch the backend up to the newest accepted PCM before asking it
            # for another display snapshot. This prevents an obsolete-preview
            # queue on slower devices while socket ingestion remains immediate.
            stop = False
            while True:
                try:
                    queued = session.queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                if queued is None:
                    stop = True
                    break
                await self._feed_one(session, queued)
            if stop:
                return
            await self._start_preview_if_ready(session)

    async def _start_preview_if_ready(self, session: Session) -> None:
        if session.cancelled or self.session is not session:
            return
        task = session.preview_task
        if task is not None and not task.done():
            return
        take = getattr(self.stt, "take_preview_request", None)
        decode = getattr(self.stt, "decode_preview", None)
        if not callable(take) or not callable(decode):
            return
        try:
            request = await self._stt_call(take)
        except Exception:  # optional preview surface must not affect recording
            log.exception("taking preview request failed")
            return
        if request is None or session.cancelled or self.session is not session:
            return
        session.preview_task = asyncio.create_task(
            self._run_preview(session, decode, request)
        )

    async def _run_preview(
        self,
        session: Session,
        decode: Callable[[Any], str | None],
        request: Any,
    ) -> None:
        current = asyncio.current_task()
        try:
            partial = await self._stt_call(decode, request)
            await self._emit_partial(session, partial)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — optional preview never kills STT
            log.exception("preview task failed — final transcription remains available")
        finally:
            if session.preview_task is current:
                session.preview_task = None
            # A feed queued behind this decode may have coalesced a newer
            # request. Start it only after the old task fully emitted and only
            # while the same live session still owns the backend.
            if (
                not session.cancelled
                and self.session is session
                and session.queue.empty()
            ):
                await self._start_preview_if_ready(session)

    async def _drain_preview(self, session: Session) -> None:
        task = session.preview_task
        if task is not None:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        session.preview_task = None
        discard = getattr(self.stt, "discard_preview_request", None)
        if callable(discard):
            with contextlib.suppress(Exception):
                await self._stt_call(discard)

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
        self._cancel_prefix_preparation(session)
        self._cancel_chunk_tasks(session)
        await self._drain_feeder(session)
        await self._drain_preview(session)
        await self._stt_call(self.stt.reset)
        log.info("session %s discarded (%s)", session.id, why)
        # The engine is idle again after an abort too — without this, a
        # cancelled dictation left mining dead until the next FINALIZED one
        # (review finding).
        self._schedule_mining()

    @staticmethod
    def _cancel_chunk_tasks(session: Session) -> None:
        for task in session.chunk_tasks:
            Engine._cancel_chunk_task(session, task)

    @staticmethod
    def _cancel_chunk_task(session: Session, task: asyncio.Task[_ChunkResult]) -> None:
        event = session.chunk_cancel_events.get(task)
        if event is not None:
            event.set()
        task.cancel()

    async def _cmd_cancel(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            await self._error("cancel: no active session", msg.get("session"))
            return
        await self._abort_session("cancel")
        await self._send({"event": "cancelled", "session": session.id})
        # Chunk cleanup may have hit the hard watchdog before the user
        # cancelled. Confirm cancellation first, then restart instead of
        # leaving the poisoned single-worker executor for the next dictation.
        self._restart_if_cleanup_unhealthy()

    async def _cmd_stop(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            await self._error("stop: no active session", msg.get("session"))
            return
        # The app attaches richer screen-context entities (nearby AX text,
        # gathered in the background while speaking) to `stop`; merge them so
        # cleanup sees on-screen names it couldn't get from the title alone.
        stop_entities = msg.get("entities")
        if isinstance(stop_entities, list):
            # Keep only well-formed dict items so a malformed client frame can't
            # crash finalize (which would drop the transcript).
            clean = [e for e in stop_entities if isinstance(e, dict)]
            if clean:
                session.context["entities"] = clean
        self.session = None
        await self._finalize_session(session)

    async def _finalize_session(self, session: Session, auto_stopped: bool = False) -> None:
        # Set synchronously (no await since the caller cleared self.session):
        # closes the window where a background transcribe-file chunk could
        # grab the backend before our finalize() drains it.
        self._finalizing = True
        # Prefix preparation is optional recording-time work on the same
        # single-worker cleanup executor as the authoritative final pass. Set
        # its cooperative cancellation signal before any finalization awaits
        # so it can release the model thread while Whisper drains.
        self._cancel_prefix_preparation(session)
        try:
            await self._finalize_session_inner(session, auto_stopped)
        finally:
            self._finalizing = False

    async def _finalize_session_inner(self, session: Session, auto_stopped: bool = False) -> None:
        t_stop = time.perf_counter()
        await self._drain_feeder(session)
        await self._drain_preview(session)
        try:
            raw = await self._stt_call(self.stt.finalize)
        except Exception as exc:
            log.exception("finalize failed")
            self._cancel_chunk_tasks(session)
            await self._stt_call(self.stt.reset)
            await self._error(f"transcription failed: {exc}", session.id)
            return
        stt_ms = int((time.perf_counter() - t_stop) * 1000)
        await self._send({"event": "transcript", "session": session.id, "raw": raw, "ms": stt_ms})

        # Stage 2: formatting pipeline. Long whisper dictations whose segments
        # were already cleaned during recording assemble from those chunks
        # (only the tail is cleaned now → flat stop→final latency); anything
        # else — and ANY streaming failure — runs the classic whole-text path,
        # so a transcript is never lost to the new pipeline.
        ctx = session.context
        result: tuple[str, str, int, bool, str] | None = None
        if session.chunk_tasks:
            try:
                result = await self._streaming_result(session, raw)
            except Exception:  # noqa: BLE001 — the fallback below always runs
                log.exception("streaming finalize failed — falling back to whole-text cleanup")
                result = None
        if result is None:
            self._cancel_chunk_tasks(session)
            result = await self._apply_formatting(
                raw,
                bundle_id=ctx.get("bundle_id"),
                app_name=ctx.get("app_name"),
                explicit_mode=ctx.get("mode"),
                entities=ctx.get("entities"),
            )
        text, mode_name, cleanup_ms, cleanup_applied, reason = result

        # Stage 3: archive the audio clip in the BACKGROUND — the clip name is
        # deterministic, so `final` never waits on FLAC encode + disk I/O
        # (review finding: archive writes sat on the stop→final path).
        audio_name = self._archive_audio_bg(session)

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
        self._restart_if_cleanup_unhealthy()
        # The engine is idle again — (re)arm the idle vocabulary miner.
        self._schedule_mining()

    # ---------------- streaming segment cleanup (smartness-v2 §2) ----------------

    def _on_new_segment(self, session: Session, seg_raw: str) -> None:
        """Schedule cleanup for one freshly-decoded raw segment (or merge it
        into the previous chunk when it opens with a retraction)."""
        seg_raw = seg_raw.strip()
        if not seg_raw or session.cancelled or session.streaming_disabled:
            return
        # Session-level gates: if any fails, segments stay preview-only (HUD
        # partials) and finalize runs the whole-text pipeline unchanged.
        if not (
            self.config.streaming_cleanup
            and self.cleanup is not None
            and self.cleanup.loaded
            and not self.config.romanize_output
            and not formatting.is_mostly_non_latin(seg_raw)
        ):
            session.streaming_disabled = True
            self._cancel_chunk_tasks(session)
            return
        # One gate per SESSION, from the first segment: streaming cleanup is
        # for the LLM path only. A non-LLM gate (Raw mode, formatting off with
        # short text) keeps segments preview-only — running deterministic
        # gates per chunk applied end-of-utterance transforms mid-text at
        # every seam (review finding), so those sessions take the classic
        # whole-text path at stop instead.
        if session.stream_prompt is None:
            ctx = session.context
            gate = formatting.run_gate(
                seg_raw,
                self.config,
                bundle_id=ctx.get("bundle_id"),
                app_name=ctx.get("app_name"),
                explicit_mode=ctx.get("mode"),
                entities=session.start_entities,
            )
            if not gate.use_llm and gate.reason in {"short_utterance", "formatting_off"}:
                # This is a segment of an already-long recording, not a short
                # standalone utterance. Probe the session mode's long-text path
                # so a short first segment does not disable streaming for the
                # remaining dictation. `formatting_off` matters for the built-in
                # Terminal mode: its <12-word command-safe path becomes smart
                # cleanup once the complete utterance reaches 12 words. Raw and
                # custom formatting-off modes remain off when probed.
                long_gate = formatting.run_gate(
                    formatting.LLM_PATH_PROBE,
                    self.config,
                    bundle_id=ctx.get("bundle_id"),
                    app_name=ctx.get("app_name"),
                    explicit_mode=ctx.get("mode"),
                    entities=session.start_entities,
                )
                if long_gate.use_llm:
                    gate = long_gate
            if not gate.use_llm:
                session.streaming_disabled = True
                self._cancel_chunk_tasks(session)
                return
            session.stream_prompt = gate.system_prompt or STATIC_SYSTEM_PROMPT
            session.stream_allowed_terms = self._allowed_terms(gate.mode)
        # A committed segment cleanup can become part of the authoritative
        # final for a long dictation. Optional prefix preparation must never
        # sit ahead of that work on the cleanup engine's single executor.
        self._cancel_prefix_preparation(session)
        # Cross-boundary self-correction: a segment that BEGINS with a
        # retraction marker ("no wait…", "scratch that…") refers back across
        # the boundary — never clean it alone. Merge with the previous raw
        # segment and re-clean the pair as ONE chunk, replacing the previous
        # result. The marker decides SCOPE only; the LLM does the edit.
        head = " ".join(seg_raw.split()[:RETRACTION_HEAD_WORDS])
        if session.chunk_raws and _RETRACTION_RE.search(head):
            self._cancel_chunk_task(session, session.chunk_tasks[-1])
            merged = session.chunk_raws[-1] + " " + seg_raw
            session.chunk_raws[-1] = merged
            prev = session.chunk_tasks[-2] if len(session.chunk_tasks) >= 2 else None
            session.chunk_tasks[-1] = self._new_chunk_task(session, merged, prev)
            return
        prev = session.chunk_tasks[-1] if session.chunk_tasks else None
        session.chunk_raws.append(seg_raw)
        session.chunk_tasks.append(self._new_chunk_task(session, seg_raw, prev))

    def _new_chunk_task(
        self,
        session: Session,
        seg_raw: str,
        prev_task: asyncio.Task[_ChunkResult] | None,
    ) -> asyncio.Task[_ChunkResult]:
        cancel_event = threading.Event()
        task = asyncio.create_task(
            self._clean_chunk_task(session, seg_raw, prev_task, cancel_event)
        )
        session.chunk_cancel_events[task] = cancel_event
        return task

    async def _clean_chunk_task(
        self,
        session: Session,
        seg_raw: str,
        prev_task: asyncio.Task[_ChunkResult] | None,
        cancel_event: threading.Event,
    ) -> _ChunkResult:
        """Chunk cleanup that first waits for its predecessor (for the seam
        context). Waits via asyncio.wait so a cancelled/failed predecessor only
        costs us the context line, while OUR own cancellation still propagates."""
        prev_text: str | None = None
        if prev_task is not None:
            await asyncio.wait([prev_task])
            if not prev_task.cancelled() and prev_task.exception() is None:
                prev_text = prev_task.result().text
        return await self._clean_chunk_text(session, seg_raw, prev_text, cancel_event)

    async def _clean_chunk_text(
        self,
        session: Session,
        seg_raw: str,
        prev_text: str | None,
        cancel_event: threading.Event | None = None,
    ) -> _ChunkResult:
        """Clean ONE raw chunk (segment or tail) under the session's single
        stream prompt. Never raises: any failure degrades to the deterministic
        cleanup for this chunk only. Replacements/tags/category rules run ONCE
        over the assembled text in `_streaming_result`'s postprocess — never
        per chunk (mid-text chunks are not utterances)."""
        try:
            system_prompt = session.stream_prompt
            cleanup = self.cleanup
            if system_prompt is None or cleanup is None:
                return _ChunkResult(self._deterministic_cleanup(seg_raw), 0)
            if prev_text:
                # Seam context: previous cleaned tail, fenced as context-only.
                # Appended AFTER the static prompt so the KV prefix still hits.
                tail_words = " ".join(prev_text.split()[-CHUNK_CONTEXT_WORDS:])
                system_prompt += (
                    "\n\nPrevious text (context only, do NOT repeat it): «" + tail_words + "»"
                )
            result = await cleanup.cleanup(
                seg_raw,
                system_prompt,
                cancel_event=cancel_event,
                allowed_terms=session.stream_allowed_terms,
            )
            if result.applied:
                return _ChunkResult(result.text, result.ms, applied=True)
            return _ChunkResult(self._deterministic_cleanup(seg_raw), result.ms)
        except Exception:  # noqa: BLE001 — one bad chunk must not sink the session
            log.exception("chunk cleanup failed — deterministic fallback for this chunk")
            return _ChunkResult(self._deterministic_cleanup(seg_raw), 0)

    async def _streaming_result(self, session: Session, raw: str) -> tuple[str, str, int, bool, str] | None:
        """Assemble the final text from the per-segment cleanups. Returns the
        `_apply_formatting`-shaped tuple, or None → caller falls back to the
        whole-text pipeline (never lose a transcript to the fast path)."""
        backend = self.stt
        if not getattr(backend, "segments_used_for_final", False):
            return None  # finalize re-decoded the whole clip; chunks were preview-only
        if session.streaming_disabled or not session.chunk_tasks:
            return None
        if len(session.chunk_tasks) != len(session.chunk_raws):
            return None
        tail = str(getattr(backend, "final_tail", "") or "").strip()
        # Integrity check: the chunks we cleaned plus the tail must reconstruct
        # the stitched raw exactly, or the assembly would drop/duplicate words.
        expected = " ".join(session.chunk_raws + ([tail] if tail else []))
        if expected != raw.strip():
            log.warning("streaming stitch mismatch — falling back to whole-text cleanup")
            return None
        # The chunk cleanups ran during recording; this is normally instant.
        # return_exceptions: a cancelled/failed task must surface as a value
        # (→ fallback below), not raise CancelledError through finalize.
        results = await asyncio.wait_for(
            asyncio.gather(*session.chunk_tasks, return_exceptions=True),
            timeout=STREAM_GATHER_TIMEOUT_S,
        )
        if any(not isinstance(r, _ChunkResult) for r in results):
            log.warning("streaming chunk task did not complete — falling back")
            return None
        cleaned = [r.text for r in results]
        applied_any = any(r.applied for r in results)
        tail_ms = 0
        if tail:
            tail_head = " ".join(tail.split()[:RETRACTION_HEAD_WORDS])
            if session.chunk_raws and _RETRACTION_RE.search(tail_head):
                # A retraction spoken in the final seconds refers back across
                # the LAST seam — the most common place for corrections
                # (review finding). Same merge rule the live segments use:
                # re-clean (last raw chunk + tail) as ONE chunk now, replacing
                # the last cleaned chunk. Costs one generation at stop; the
                # LLM does the edit, the marker only picked the scope.
                merged = session.chunk_raws[-1] + " " + tail
                prev_text = cleaned[-2] if len(cleaned) >= 2 else None
                merged_result = await self._clean_chunk_text(session, merged, prev_text)
                cleaned[-1] = merged_result.text
                tail_ms = merged_result.ms
                applied_any = applied_any or merged_result.applied
            else:
                tail_result = await self._clean_chunk_text(session, tail, cleaned[-1] if cleaned else None)
                cleaned.append(tail_result.text)
                tail_ms = tail_result.ms
                applied_any = applied_any or tail_result.applied
        assembled = _join_chunks(cleaned)
        if not assembled.strip():
            return None
        ctx = session.context
        # Gate over the FULL raw text — for its GateResult fields only
        # (replacements/tags/category/chat rules, now with stop-time entities).
        # Its use_llm is deliberately ignored: no second LLM pass here.
        gate = formatting.run_gate(
            raw,
            self.config,
            bundle_id=ctx.get("bundle_id"),
            app_name=ctx.get("app_name"),
            explicit_mode=ctx.get("mode"),
            entities=ctx.get("entities"),
        )
        text = formatting.postprocess(assembled, gate)
        # applied reflects whether the LLM actually cleaned ANY chunk — a
        # session where every chunk fell back deterministic must not report
        # itself as LLM-cleaned to the app/history (review finding).
        return text, gate.mode.name, tail_ms, applied_any, "streaming"

    async def _apply_formatting(
        self,
        raw: str,
        bundle_id: str | None,
        app_name: str | None,
        explicit_mode: str | None,
        entities: list[dict[str, str]] | None = None,
        cancel_event: threading.Event | None = None,
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
            entities=entities,
        )
        if not raw.strip():
            return "", gate.mode.name, 0, False, "empty_transcript"
        if gate.use_llm and self.cleanup is not None and self.cleanup.loaded:
            if gate.romanize:
                # Transliteration: skip the length-ratio guard and allow longer.
                result = await self.cleanup.cleanup(
                    raw, gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    timeout_ms=4000, check_ratio=False, cancel_event=cancel_event,
                )
            else:
                result = await self.cleanup.cleanup(
                    raw, gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    cancel_event=cancel_event,
                    allowed_terms=self._allowed_terms(gate.mode),
                )
            if result.applied:
                text = formatting.postprocess(result.text, gate)
            else:
                text = formatting.postprocess(self._deterministic_cleanup(raw), gate)
            return text, gate.mode.name, result.ms, result.applied, result.reason or "llm"
        if gate.use_llm:
            # Cleanup LLM not ready (still warming after launch) or disabled: run
            # the same deterministic fallback so spoken punctuation ("full stop")
            # never leaks as literal text while the model loads.
            text = formatting.postprocess(self._deterministic_cleanup(raw), gate)
            return text, gate.mode.name, 0, False, "cleanup_unavailable"
        return gate.text, gate.mode.name, 0, False, gate.reason

    @staticmethod
    def _deterministic_cleanup(raw: str) -> str:
        """Best-effort no-LLM cleanup shared by every fallback path: scrub
        fillers, apply spoken newline commands, and normalize dictated
        punctuation (guarded against noun usage)."""
        return formatting.normalize_spoken_punctuation(
            formatting.apply_spoken_commands(formatting.scrub_fillers(raw)))

    def _allowed_terms(self, mode: Any) -> list[str]:
        """Exact spellings the active cleanup prompt is allowed to introduce.

        Keep this aligned with formatting.build_system_prompt: global personal
        vocabulary first, then only the resolved mode's vocabulary.
        """
        return list(dict.fromkeys(self.config.global_vocabulary + list(mode.vocabulary)))

    # ---------------- STT glossary + idle vocab mining (smartness-v2 §4) ----------------

    def _glossary(self, entities: list[dict[str, Any]] | None = None) -> str | None:
        """The whisper initial_prompt for the current config + screen context.
        Only NAME-like entity types feed it — nearby free text stays out."""
        entity_names = [
            str(e.get("value", "")).strip()
            for e in (entities or [])
            if isinstance(e, dict)
            and e.get("type") in ("person", "file", "channel", "subject")
            and str(e.get("value", "")).strip()
        ]
        return build_glossary_prompt(
            self.config.user_vocabulary,
            self.config.learned_vocabulary,
            self.config.auto_vocabulary,
            entity_names,
        )

    def _schedule_mining(self, delay: float = MINE_IDLE_S) -> None:
        """(Re)arm the idle miner: cancel any pending run and wait again from
        now. Called after every final and once after startup model load."""
        if self.shutdown.is_set():
            return
        if self._miner_task is not None and not self._miner_task.done():
            self._miner_task.cancel()
        self._miner_task = asyncio.create_task(self._mine_when_idle(delay))

    async def _mine_when_idle(self, delay: float) -> None:
        """Run mining steps across idle windows. Every iteration re-checks that
        the engine is truly idle; a starting session cancels this task outright
        (see _cmd_start). Failures are logged and dropped — background work
        must never affect dictation."""
        try:
            while True:
                await asyncio.sleep(delay)
                delay = MINE_IDLE_S
                if (
                    self.session is not None
                    or self._reprocessing
                    or self._transcribing
                    or self._meeting_notes_running
                    or not (self.cleanup is not None and self.cleanup.loaded)
                    or not self.config.vocab_mining
                ):
                    return
                if self._miner is None:
                    self._miner = VocabMiner(self.config.home, self._mine_generate)
                more = await self._miner.step()
                if self._miner.last_step_new_terms:
                    # Make the new terms live (cleanup vocab + next glossary).
                    # Counts only — never term values — in the log.
                    self.config.reload()
                    log.info("vocab mining added %d terms", self._miner.last_step_new_terms)
                    await self._send({
                        "event": "vocabulary_promoted",
                        "count": self._miner.last_step_new_terms,
                    })
                if not more:
                    return
        except Exception:  # noqa: BLE001 — idle work must never break the engine
            log.exception("vocab mining failed")

    async def _mine_generate(self, system_prompt: str, user_text: str) -> str:
        """Generation hook for the miner: reuse the cleanup engine with a short
        budget. check_ratio=False because extraction is not a cleanup (the
        miner validates every line deterministically anyway); a not-applied
        result returns "" so echoed input is never parsed as terms.

        Preemption: `_cmd_start` sets `_mine_cancel`, and the generation loop
        yields within one token — a dictation's cleanup never waits multiple
        seconds behind background mining (review finding)."""
        engine = self.cleanup
        if engine is None or not engine.loaded:
            return ""
        self._mine_cancel.clear()
        result = await engine.cleanup(
            user_text, system_prompt, timeout_ms=4000, check_ratio=False,
            cancel_event=self._mine_cancel,
        )
        self._restart_if_cleanup_unhealthy()
        return result.text if result.applied else ""

    def _archive_audio_bg(self, session: Session) -> str | None:
        """Kick off archiving the session's PCM without blocking the caller.
        Returns the deterministic clip name the write will produce (None when
        archiving is off/empty). A failed write leaves a dangling name in
        history — rare (disk full), and the app treats missing clips as
        expired anyway."""
        if not self.config.save_audio or not session.pcm_chunks:
            return None
        chunks = session.pcm_chunks
        session.pcm_chunks = []

        async def _write() -> None:
            try:
                pcm = np.concatenate(chunks)
            except ValueError:
                return
            saved = await asyncio.to_thread(self.audio.save, session.id, pcm)
            if saved:
                # Prune is an O(clips) stat sweep — also off the hot path.
                await self._prune_audio_bg()

        asyncio.create_task(_write())
        return self.audio.name_for(session.id)

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
                "recommended_cleanup_model": models.recommended_cleanup_model(),
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
        if (self.session is not None or self._reprocessing or self._transcribing
                or self._meeting_notes_running):
            await self._error("set_model: busy (dictation, reprocess, or file transcription in progress)")
            return
        info = models.lookup(model_id)
        kind = msg.get("kind") or (info.kind if info else "stt")
        if kind not in ("stt", "cleanup"):
            await self._error(f"set_model: unknown kind {kind!r}")
            return
        if not fake_stt_enabled():
            await asyncio.to_thread(models.ensure_downloaded, model_id)
        # The download/load above can take minutes; the app may have rewritten
        # config.json (language, save_audio, …) meanwhile. Re-read before the
        # mutate+save below so we never clobber newer settings with stale
        # in-memory state (review finding).
        self.config.reload()
        if kind == "stt":
            backend = create_backend(model_id, self.config.language)
            await self._stt_call(backend.load)
            self.stt = backend
            self.config.data["stt_model"] = model_id
        else:
            # Load-then-swap: build and fully load the replacement FIRST, then
            # retire the old one. A failed load (bad download, OOM) therefore
            # leaves the working engine intact instead of leaving no cleanup at
            # all. Peak memory holds both only for the load window (rare,
            # user-initiated); close() frees the old thread + model right after.
            engine = CleanupEngine(model_id)
            if not fake_stt_enabled():
                try:
                    await engine.load_async(STATIC_SYSTEM_PROMPT)
                except Exception:
                    engine.close()
                    raise  # keep self.cleanup pointing at the old, working engine
            old = self.cleanup
            self.cleanup = engine
            self.config.data["cleanup_model"] = model_id
            if old is not None:
                old.close()
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

    # ---------------- safe voice edit ----------------

    async def _cmd_edit_text(self, msg: dict[str, Any]) -> None:
        """Transform selected text per a spoken instruction (Safe Voice Edit).

        Interactive — the user is waiting on the paste — so it refuses
        rather than queues when the model is owned by something else. Scope
        safety is structural (the app can only replace the selection it
        sent); content safety is the benchmarked prompt contract plus the
        deterministic instruction-echo backstop, and `applied: false` always
        returns the original text so a failed edit pastes nothing new.
        """
        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "edit_failed", "id": msg.get("id"),
                "code": code, "error": error,
            })

        if self.session is not None or self._starting or self._finalizing:
            await fail("edit: busy (dictation in progress)", "busy")
            return
        if self._reprocessing or self._transcribing or self._meeting_notes_running:
            await fail("edit: busy (another job in progress)", "busy")
            return
        text = msg.get("text")
        instruction = msg.get("instruction")
        if not isinstance(text, str) or not text.strip():
            await fail("edit: missing 'text'", "invalid_arguments")
            return
        if not isinstance(instruction, str) or not instruction.strip():
            await fail("edit: missing 'instruction'", "invalid_arguments")
            return
        if len(text) > editing.MAX_TEXT_CHARS:
            await fail(f"edit: selection over {editing.MAX_TEXT_CHARS} characters",
                       "too_large")
            return
        if len(instruction) > editing.MAX_INSTRUCTION_CHARS:
            await fail("edit: instruction too long", "too_large")
            return
        if self.cleanup is None:
            await fail("edit: writing model unavailable", "cleanup_unavailable")
            return
        self._reprocessing = True  # same single-job mutex the other jobs honor
        asyncio.create_task(self._run_edit_text(dict(msg), text, instruction))

    async def _run_edit_text(self, msg: dict[str, Any], text: str, instruction: str) -> None:
        try:
            t0 = time.perf_counter()
            result = await self.cleanup.cleanup(
                text, editing.build_edit_prompt(instruction), check_ratio=False)
            out = result.text.strip()
            applied = bool(result.applied)
            reason = result.reason or ""
            if applied and not out:
                applied, out, reason = False, text, "empty_output"
            elif applied and editing.instruction_echoed(text, instruction, out):
                # The one benchmarked failure mode (out-of-scope command
                # echoed into the document) — keep the selection unchanged.
                applied, out, reason = False, text, "instruction_echo"
            elif applied and len(out) > max(4 * len(text), len(text) + 2_000):
                applied, out, reason = False, text, "runaway_growth"
            evt: dict[str, Any] = {
                "event": "edited",
                "text": out if applied else text,
                "applied": applied,
                "ms": int((time.perf_counter() - t0) * 1000),
            }
            if reason:
                evt["reason"] = reason
            if msg.get("id") is not None:
                evt["id"] = msg.get("id")
            await self._send(evt)
            self._restart_if_cleanup_unhealthy()
            log.info("edit_text: %d chars, applied=%s reason=%s ms=%d",
                     len(text), applied, reason or "-", evt["ms"])
        except Exception as exc:  # noqa: BLE001 — the app is waiting on an answer
            log.exception("edit_text failed")
            await self._send({
                "event": "edit_failed", "id": msg.get("id"),
                "code": "failed", "error": f"edit failed: {exc}",
            })
        finally:
            self._reprocessing = False
            self._schedule_mining()

    async def _cmd_reprocess(self, msg: dict[str, Any]) -> None:
        """Re-transcribe a saved audio clip, optionally with a different model,
        mode, or language. Validates synchronously, then runs the (possibly
        slow) transcription off the dispatch loop so live control frames stay
        responsive. Emits a `reprocessed` event echoing the caller's id."""
        if self.session is not None:
            await self._reprocess_failed(
                msg, "reprocess: busy (dictation in progress)", "busy")
            return
        if self._reprocessing or self._transcribing or self._meeting_notes_running:
            await self._reprocess_failed(
                msg, "reprocess: busy (another job in progress)", "busy")
            return
        name = msg.get("audio")
        if not name or not isinstance(name, str):
            await self._reprocess_failed(msg, "reprocess: missing 'audio'", "invalid_arguments")
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
                await self._reprocess_failed(
                    msg, f"reprocess: audio unavailable: {exc}", "invalid_file")
                return
            t0 = time.perf_counter()
            try:
                backend = await self._stt_for_reprocess(model_id, language)
                # Reprocess biases from the LIVE config vocab, same as a fresh
                # session (there is no screen context for an archived clip).
                backend.initial_prompt = self._glossary()
                raw = await self._stt_call(transcribe_clip, backend, pcm)
            except Exception as exc:  # noqa: BLE001
                log.exception("reprocess transcription failed")
                await self._reprocess_failed(msg, f"reprocess failed: {exc}")
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
            self._restart_if_cleanup_unhealthy()
            log.info("reprocess %s with %s: stt_ms=%d mode=%s", name, model_id, stt_ms, mode_name)
        except Exception as exc:  # noqa: BLE001 — always complete the row request
            log.exception("reprocess failed")
            await self._reprocess_failed(msg, f"reprocess failed: {exc}")
        finally:
            if saved_language is not None and hasattr(self.stt, "language"):
                self.stt.language = saved_language
            self._reprocessing = False
            # Idle again — without this, a reprocess that landed during the
            # mining delay window left mining dead until the next dictation
            # (review finding).
            self._schedule_mining()

    # ---------------- file transcription ----------------

    async def _cmd_transcribe_file(self, msg: dict[str, Any]) -> None:
        """Transcribe an audio file (voice memo, meeting recording) in the
        background. Decodes in ~60s silence-aligned chunks with progress
        events; a live dictation always wins — the job pauses between chunks
        whenever a session is active."""
        path = msg.get("path")
        if not path or not isinstance(path, str):
            await self._error("transcribe_file: missing 'path'")
            return
        requested_mode = msg.get("mode")
        if requested_mode is not None and (
            not isinstance(requested_mode, str)
            or not requested_mode.strip()
            or len(requested_mode) > 128
        ):
            await self._send({"event": "transcribe_failed", "id": msg.get("id"),
                              "error": "invalid formatting mode"})
            return
        if self._reprocessing or self._transcribing or self._meeting_notes_running:
            await self._send({"event": "transcribe_failed", "id": msg.get("id"),
                              "error": "another transcription is already running"})
            return
        self._transcribing = True
        self._transcribe_cancel = False
        self._transcribe_preempt.clear()
        self._file_transcribe_job_id = msg.get("id")
        asyncio.create_task(self._run_transcribe_file(dict(msg)))
        # Immediate ack so the app can distinguish "job accepted, decoding"
        # from "command was dropped" (engine restarting) and un-stick its UI.
        await self._send({"event": "transcribe_accepted", "id": msg.get("id")})

    async def _run_transcribe_file(self, msg: dict[str, Any]) -> None:
        path = str(msg.get("path"))
        job_id = msg.get("id")

        async def fail(error: str) -> None:
            await self._send({"event": "transcribe_failed", "id": job_id, "error": error})

        try:
            try:
                pcm = await asyncio.to_thread(load_media, path)
            except ValueError as exc:
                await fail(str(exc))
                return
            if self.shutdown.is_set():
                await fail("engine shutting down")
                return
            if self._transcribe_cancel:  # cancelled during a slow decode
                await fail("cancelled")
                return
            duration_s = len(pcm) / SAMPLE_RATE
            if duration_s < 0.2:
                await fail("no audio in file")
                return
            chunks = split_for_batch(pcm)
            await self._send({
                "event": "transcribe_started", "id": job_id,
                "duration_s": round(duration_s, 1), "chunks": len(chunks),
            })
            t0 = time.perf_counter()
            texts: list[str] = []
            for i, chunk in enumerate(chunks):
                # Dictation priority: never touch the shared STT backend while
                # a live session owns it. (Within a chunk, _stt_call serializes
                # on the one executor thread, so a decode already in flight
                # just delays the session's first decode by a few seconds.)
                while (
                    self.session is not None or self._finalizing or self._starting
                ) and not self._transcribe_cancel:
                    if self.shutdown.is_set():
                        await fail("engine shutting down")
                        return
                    await asyncio.sleep(0.5)
                if self._transcribe_cancel:
                    await fail("cancelled")
                    return
                # Re-set per chunk: a dictation in between overwrites the prompt.
                self.stt.initial_prompt = self._glossary()
                piece = await self._stt_call(transcribe_clip, self.stt, chunk)
                if self.shutdown.is_set():
                    await fail("engine shutting down")
                    return
                # A cancel that landed while the chunk was decoding must win:
                # the user said stop — never emit a result after that (review
                # finding; the decode itself is seconds, not worth preempting).
                if self._transcribe_cancel:
                    await fail("cancelled")
                    return
                if piece and piece.strip():
                    texts.append(piece.strip())
                await self._send({
                    "event": "transcribe_progress", "id": job_id,
                    "fraction": round((i + 1) / len(chunks), 3),
                })
            raw = " ".join(texts).strip()
            mode_name: str | None = None
            cleanup_ms = 0
            cleanup_applied = False
            text = raw
            if isinstance(msg.get("mode"), str):
                formatted: list[str] = []
                for raw_piece in chunk_transcript(raw, max_chars=12_000):
                    while True:
                        while (
                            self.session is not None or self._finalizing or self._starting
                        ) and not self._transcribe_cancel:
                            if self.shutdown.is_set():
                                await fail("engine shutting down")
                                return
                            await asyncio.sleep(0.25)
                        if self._transcribe_cancel:
                            await fail("cancelled")
                            return
                        self._transcribe_preempt.clear()
                        part, part_mode, part_ms, part_applied, _reason = (
                            await self._apply_formatting(
                                raw_piece,
                                bundle_id=None,
                                app_name="Local file",
                                explicit_mode=msg["mode"],
                                cancel_event=self._transcribe_preempt,
                            )
                        )
                        if self.shutdown.is_set():
                            await fail("engine shutting down")
                            return
                        if self._transcribe_cancel:
                            await fail("cancelled")
                            return
                        if self._transcribe_preempt.is_set():
                            # Foreground dictation interrupted generation. The
                            # partial result is not authoritative; retry this
                            # same bounded piece after the foreground releases.
                            await asyncio.sleep(0.25)
                            continue
                        formatted.append(part)
                        mode_name = part_mode
                        cleanup_ms += part_ms
                        cleanup_applied = cleanup_applied or part_applied
                        break
                text = _join_chunks(formatted)
            if self.shutdown.is_set():
                await fail("engine shutting down")
                return
            if self._transcribe_cancel:
                await fail("cancelled")
                return
            await self._send({
                "event": "transcribed", "id": job_id, "path": path, "text": text,
                "mode": mode_name,
                "duration_s": round(duration_s, 1),
                "stt_ms": int((time.perf_counter() - t0) * 1000),
                "stt_model": self.stt.model_id,
                "cleanup_ms": cleanup_ms,
                "cleanup_applied": cleanup_applied,
            })
            log.info(
                "transcribe_file done: %.0fs audio, %d chunks, %dms",
                duration_s, len(chunks), int((time.perf_counter() - t0) * 1000),
            )
        except Exception as exc:  # noqa: BLE001 — job must never crash the engine
            log.exception("transcribe_file failed")
            await fail(f"transcription failed: {exc}")
        finally:
            self._transcribing = False
            self._transcribe_cancel = False
            self._transcribe_preempt.clear()
            self._file_transcribe_job_id = None
            self._schedule_mining()

    # ---------------- resumable meeting transcription + notes ----------------

    async def _cmd_meeting_transcribe(self, msg: dict[str, Any]) -> None:
        path = msg.get("path")
        meeting_id = msg.get("meeting_id")
        speaker = msg.get("speaker")
        start_chunk = msg.get("start_chunk", 0)
        if not isinstance(path, str) or not path:
            await self._error("meeting_transcribe: missing 'path'")
            return
        if not isinstance(meeting_id, str) or not meeting_id or len(meeting_id) > 128:
            await self._error("meeting_transcribe: invalid 'meeting_id'")
            return
        if speaker not in ("me", "them"):
            await self._error("meeting_transcribe: speaker must be 'me' or 'them'")
            return
        if not isinstance(start_chunk, int) or isinstance(start_chunk, bool) or start_chunk < 0:
            await self._error("meeting_transcribe: invalid 'start_chunk'")
            return
        if self._reprocessing or self._transcribing or self._meeting_notes_running:
            await self._send({
                "event": "meeting_transcribe_failed", "id": msg.get("id"),
                "meeting_id": meeting_id, "speaker": speaker,
                "code": "busy",
                "error": "another background job is already running",
            })
            return
        self._transcribing = True
        self._meeting_transcribe_cancel = False
        self._meeting_transcribe_job_id = msg.get("id")
        asyncio.create_task(self._run_meeting_transcribe(dict(msg)))
        await self._send({
            "event": "meeting_transcribe_accepted", "id": msg.get("id"),
            "meeting_id": meeting_id, "speaker": speaker,
        })

    async def _diarize_spans(
        self, pcm: Any, meeting_id: str
    ) -> list[tuple[int, int, str]] | None:
        """Diarized transcription plan for a system-audio track, or None.

        None means "use the classic single-speaker path" — backend missing,
        model download failed, diarization errored, or only one voice found
        (a 1:1 call reads better as plain "Them" than as "Speaker 1"). The
        plan must be deterministic per track: chunk indexes are the resume
        cursor across engine restarts.
        """
        try:
            if not diarization.available():
                log.info("diarization: sherpa-onnx not importable — skipping")
                return None
            if not diarization.models_ready():
                await asyncio.to_thread(diarization.ensure_models)
            turns = await asyncio.to_thread(diarization.diarize, pcm)
            speakers = {t.speaker for t in turns}
            if len(speakers) < 2:
                log.info("diarization: %d speaker(s) on %s — using plain labels",
                         len(speakers), meeting_id)
                return None
            spans = diarization.plan_chunks(turns, total_samples=len(pcm))
            if not spans:
                return None
            log.info("diarization: %s → %d speakers, %d chunks",
                     meeting_id, len(speakers), len(spans))
            return spans
        except Exception:  # noqa: BLE001 — diarization must never sink a meeting
            log.exception("diarization failed — falling back to single speaker")
            return None

    async def _run_meeting_transcribe(self, msg: dict[str, Any]) -> None:
        path = str(msg["path"])
        meeting_id = str(msg["meeting_id"])
        speaker = str(msg["speaker"])
        job_id = msg.get("id")
        start_chunk = int(msg.get("start_chunk", 0))

        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "meeting_transcribe_failed", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "code": code, "error": error,
            })

        try:
            try:
                pcm = await asyncio.to_thread(load_media, path)
            except ValueError as exc:
                await fail(str(exc))
                return
            if self.shutdown.is_set():
                await fail("engine shutting down", "engine_shutdown")
                return
            if self._meeting_transcribe_cancel:
                await fail("cancelled", "cancelled")
                return
            duration_s = len(pcm) / SAMPLE_RATE
            if duration_s < 0.2:
                await fail("no audio in file")
                return
            # The remote/system track may carry several people. Diarize it
            # into per-speaker turns and transcribe turn-by-turn ("s1"/"s2"
            # labels); anything short of a confident multi-speaker result
            # falls back to the classic single-"them" silence chunking. The
            # mic track is one person by construction — never diarized.
            spans: list[tuple[int, int, str]] | None = None
            if speaker == "them" and self.config.meeting_diarization:
                spans = await self._diarize_spans(pcm, meeting_id)
            if spans is None:
                chunks = split_for_batch(pcm)
                spans = []
                cursor = 0
                for chunk in chunks:
                    spans.append((cursor, cursor + len(chunk), speaker))
                    cursor += len(chunk)
            await self._send({
                "event": "meeting_transcribe_started", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "duration_s": round(duration_s, 1), "chunks": len(spans),
                "start_chunk": min(start_chunk, len(spans)),
            })
            for index in range(start_chunk, len(spans)):
                while (
                    self.session is not None or self._finalizing or self._starting
                ) and not self._meeting_transcribe_cancel:
                    if self.shutdown.is_set():
                        await fail("engine shutting down", "engine_shutdown")
                        return
                    await asyncio.sleep(0.25)
                if self._meeting_transcribe_cancel:
                    await fail("cancelled", "cancelled")
                    return
                sample_a, sample_b, chunk_speaker = spans[index]
                self.stt.initial_prompt = self._glossary()
                text = await self._stt_call(
                    transcribe_clip, self.stt, pcm[sample_a:sample_b])
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_transcribe_cancel:
                    await fail("cancelled", "cancelled")
                    return
                await self._send({
                    "event": "meeting_segment", "id": job_id,
                    "meeting_id": meeting_id, "speaker": chunk_speaker,
                    "chunk_index": index,
                    "start_ms": int(sample_a * 1000 / SAMPLE_RATE),
                    "end_ms": int(sample_b * 1000 / SAMPLE_RATE),
                    "text": (text or "").strip(),
                })
                await self._send({
                    "event": "meeting_transcribe_progress", "id": job_id,
                    "meeting_id": meeting_id, "speaker": speaker,
                    "fraction": round((index + 1) / len(spans), 3),
                })
            if self.shutdown.is_set():
                await fail("engine shutting down", "engine_shutdown")
                return
            await self._send({
                "event": "meeting_transcribed", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "duration_s": round(duration_s, 1), "chunks": len(spans),
            })
        except Exception as exc:  # noqa: BLE001
            log.exception("meeting transcription failed")
            await fail(f"transcription failed: {exc}")
        finally:
            self._transcribing = False
            self._meeting_transcribe_cancel = False
            self._meeting_transcribe_job_id = None
            self._schedule_mining()

    async def _cmd_meeting_notes(self, msg: dict[str, Any]) -> None:
        meeting_id = msg.get("meeting_id")
        transcript = msg.get("transcript")
        if not isinstance(meeting_id, str) or not meeting_id or len(meeting_id) > 128:
            await self._error("meeting_notes: invalid 'meeting_id'")
            return
        if not isinstance(transcript, str) or not transcript.strip():
            await self._error("meeting_notes: missing 'transcript'")
            return
        if len(transcript) > 2_000_000:
            await self._send({
                "event": "meeting_notes_failed", "id": msg.get("id"),
                "meeting_id": meeting_id, "code": "invalid_arguments",
                "error": "transcript is too large",
            })
            return
        if self._reprocessing or self._transcribing or self._meeting_notes_running:
            await self._send({
                "event": "meeting_notes_failed", "id": msg.get("id"),
                "meeting_id": meeting_id, "code": "busy",
                "error": "another background job is already running",
            })
            return
        self._meeting_notes_running = True
        self._meeting_notes_cancel = False
        self._meeting_notes_preempt.clear()
        self._meeting_notes_job_id = msg.get("id")
        asyncio.create_task(self._run_meeting_notes(dict(msg)))
        await self._send({
            "event": "meeting_notes_accepted", "id": msg.get("id"),
            "meeting_id": meeting_id,
        })

    async def _run_meeting_notes(self, msg: dict[str, Any]) -> None:
        meeting_id = str(msg["meeting_id"])
        transcript = str(msg["transcript"])
        job_id = msg.get("id")
        map_prompt = (
            "Create faithful meeting notes from this transcript chunk. Return JSON only with "
            "exact keys summary (string), decisions (array of strings), and action_items "
            "(array of strings). Do not invent owners, deadlines, decisions, or facts. "
            "The labels Me, Them, and Speaker 1/2/… are audio channels, not "
            "identities — never guess who a speaker is."
        )
        reduce_prompt = (
            "Merge these partial meeting notes without inventing facts or duplicates. Return "
            "JSON only with exact keys summary, decisions, and action_items."
        )

        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "meeting_notes_failed", "id": job_id,
                "meeting_id": meeting_id, "code": code, "error": error,
            })

        async def generate(user_text: str, prompt: str) -> dict[str, Any] | None:
            while not self._meeting_notes_cancel:
                if self.shutdown.is_set():
                    return None
                while self.session is not None or self._starting or self._finalizing:
                    await asyncio.sleep(0.25)
                    if self._meeting_notes_cancel or self.shutdown.is_set():
                        return None
                self._meeting_notes_preempt.clear()
                cleanup = self.cleanup
                if cleanup is None or not cleanup.loaded:
                    return None
                result = await cleanup.cleanup(
                    user_text, prompt, timeout_ms=20_000, check_ratio=False,
                    cancel_event=self._meeting_notes_preempt,
                )
                if self._meeting_notes_cancel or self.shutdown.is_set():
                    return None
                if self._meeting_notes_preempt.is_set():
                    # A dictation interrupted generation. Retry this exact map
                    # chunk once the foreground session has finished.
                    await asyncio.sleep(0.25)
                    continue
                if not result.applied:
                    return None
                return parse_notes_json(result.text)
            return None

        try:
            chunks = chunk_transcript(transcript)
            partials: list[dict[str, Any]] = []
            for index, chunk in enumerate(chunks):
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_notes_cancel:
                    await fail("cancelled", "cancelled")
                    return
                notes = await generate(chunk, map_prompt)
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                notes = notes or fallback_notes(chunk)
                partials.append(notes)
                await self._send({
                    "event": "meeting_notes_progress", "id": job_id,
                    "meeting_id": meeting_id,
                    "fraction": round((index + 1) / max(1, len(chunks) + 1), 3),
                })
            merged = merge_notes(partials)
            if len(partials) > 1:
                reduced = await generate(json.dumps(partials, ensure_ascii=False), reduce_prompt)
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if reduced is not None:
                    merged = reduced
            if self._meeting_notes_cancel:
                await fail("cancelled", "cancelled")
                return
            await self._send({
                "event": "meeting_notes_ready", "id": job_id,
                "meeting_id": meeting_id, **merged,
            })
            self._restart_if_cleanup_unhealthy()
        except Exception as exc:  # noqa: BLE001
            log.exception("meeting note generation failed")
            await fail(f"note generation failed: {exc}")
        finally:
            self._meeting_notes_running = False
            self._meeting_notes_cancel = False
            self._meeting_notes_preempt.clear()
            self._meeting_notes_job_id = None
            self._schedule_mining()


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
