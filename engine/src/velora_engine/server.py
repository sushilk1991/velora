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
import re
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

from . import (
    __version__, actions, batch_priority, diarization, editing, formatting,
    models, protocol,
)
from .audio_store import AudioStore
from .cleanup import (
    HARD_TIMEOUT_GRACE_S,
    QUEUE_TIMEOUT_S,
    _RETRACTION_RE,
    adaptive_timeout_ms,
)
from .cleanup_process import CleanupProcess
from .config import Config, velora_home
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

CLEANUP_RESTART_EXIT_CODE = os.EX_TEMPFAIL
CLEANUP_RESTART_GRACE_S = 0.1
CLEANUP_RESTART_ARCHIVE_GRACE_S = 1.0

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
# Streaming cleanup happens while the user speaks. Stop should wait only for a
# nearly-finished chunk; otherwise cancel it and use the whole-text path. A
# long wait here is pure post-hotkey latency and previously reached 15 seconds.
STREAM_GATHER_TIMEOUT_S = 1.5
# A replacement that was deliberately held during live STT gets one bounded
# chance to become ready once transcription is complete. This protects final
# output quality after a rare mid-session cleanup-worker failure.
CLEANUP_FINAL_RECOVERY_TIMEOUT_S = 10.0

# Idle gap before (and between) vocab-mining steps — mining must only ever use
# compute nobody is waiting on, and yields the moment a session starts.
MINE_IDLE_S = 20.0
MINE_STARTUP_DELAY_S = 60.0

# Resume cursors are indexes into this exact cached plan. Bump whenever plan
# semantics change so an upgraded app restarts the track instead of mixing old
# fragmented labels with the corrected plan.
MEETING_PLAN_VERSION = 3

# Seam context for per-segment cleanup: the tail of the previous cleaned chunk
# rides along in the system prompt so seams punctuate/capitalize correctly.
CHUNK_CONTEXT_WORDS = 15
# A retraction marker within a segment's first few words refers back across
# the segment boundary — merge with the previous segment and re-clean.
RETRACTION_HEAD_WORDS = 4

_LIST_ITEM_START_RE = re.compile(r"^(?:\d+[.)]|[-*])\s+")
_NUMBERED_ITEM_RE = re.compile(r"(?m)^\s*(\d+)[.)]\s+")


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
            # A chunk that was ONLY a spoken break command cleans to bare
            # newline(s) — contribute the break (line vs paragraph) instead
            # of vanishing.
            if "\n" in cleaned and out:
                wanted = min(2, cleaned.count("\n"))
                have = len(out) - len(out.rstrip("\n"))
                out += "\n" * max(0, wanted - have)
            continue
        if not out:
            out = cleaned
        elif out.endswith("\n"):
            out += cleaned.lstrip("\n")
        elif _LIST_ITEM_START_RE.match(cleaned.lstrip("\n")):
            # A list item generated in the next segment must remain a new
            # line. Gluing it with a space produces "2. Previous 3. Next".
            out += "\n" + cleaned.lstrip("\n")
        else:
            out += " " + cleaned
    # Trailing breaks are dictated content ("… new paragraph" at the end) —
    # strip everything else, keep up to one blank line.
    trailing = len(out) - len(out.rstrip("\n"))
    return out.strip() + "\n" * min(2, trailing)


def _numbering_restarts(parts: list[str]) -> bool:
    """Return True when independently cleaned chunks produce invalid numbering.

    Streaming chunks are generated separately. A restart, backward step,
    skipped number, or list that does not begin at 1 would publish a corrupt
    list. This is a validity check over model output, not a rewrite: the caller
    falls back to the existing whole-text cleanup path.
    """
    expected = 1
    for part in parts:
        for match in _NUMBERED_ITEM_RE.finditer(part):
            number = int(match.group(1))
            if number != expected:
                return True
            expected += 1
    return False


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
        # Exact stable mode/strength prompt probes. The first real cleanup
        # extends the static cache while doing prompt work it already needed;
        # no separate prefill job runs at session start or during recording.
        self.stream_prefix_candidates: list[tuple[str, str]] = []
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


class Engine:
    def __init__(
        self,
        config: Config,
        parent_pid: int | None = None,
        hard_exit: Callable[[int], Any] = os._exit,
    ) -> None:
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
        # Safe Voice Edit: sub-second cleanup-model job. A dictation start
        # PREEMPTS it (cancel event → cleanup returns between tokens) rather
        # than being refused — the hotkey always wins.
        self._editing = False
        self._edit_cancel = threading.Event()
        # Action Mode planning: same model, same preemption contract as an edit
        # — the user is waiting on it, and a dictation hotkey outranks it.
        self._planning = False
        self._action_cancel = threading.Event()
        # The one live observe→decide→act session (None between actions). One
        # at a time by design: it holds budgets the app must not be able to
        # reset by opening a second loop.
        self._action_session: actions.ActionSession | None = None
        self._action_id: Any = None
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
        self._finalizing_session_id: str | None = None
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
        self.cleanup: CleanupProcess | None = None
        self.session: Session | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.shutdown = asyncio.Event()
        self._hard_exit = hard_exit
        self._cleanup_restart_scheduled = False
        self._cleanup_restart_task: asyncio.Task[None] | None = None
        self._cleanup_restart_timer: threading.Timer | None = None
        self._cleanup_recovery_deferred = False
        self._cleanup_unhealthy_watch_task: asyncio.Task[None] | None = None
        self._cancelling_session = False
        self._archive_tasks: set[asyncio.Task[None]] = set()
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
        # Batch scheduling: while these jobs run with no dictation active, the
        # engine + cleanup sidecar are demoted to Darwin background so they
        # never fight the user's foreground apps (see batch_priority module).
        self._batch_jobs = 0
        self._backgrounded_pids: set[int] = set()

    async def _stt_call(self, fn: Callable[..., T], *args: Any) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._stt_executor, fn, *args)

    # ---------------- batch scheduling + memory ----------------

    def _begin_batch_job(self) -> None:
        self._batch_jobs += 1
        self._refresh_batch_priority()

    def _end_batch_job(self) -> None:
        self._batch_jobs = max(0, self._batch_jobs - 1)
        self._refresh_batch_priority()

    def _refresh_batch_priority(self) -> None:
        """Apply the demote-while-batching policy to self + cleanup child.

        Recomputed from live state on every call (cheap syscalls, only on
        change) because the cleanup child can respawn mid-job and a restored
        pid set must track it, not the pid we demoted originally.
        """
        want_background = (
            self._batch_jobs > 0
            and self.session is None
            and not self._starting
            and not self._finalizing
        )
        cleanup_pid = getattr(self.cleanup, "pid", None)
        live = {os.getpid()} | ({cleanup_pid} if cleanup_pid else set())
        pids: set[int] = live if want_background else set()
        # Restore everything we demoted PLUS every live pid: a cleanup child
        # spawned while the parent was demoted inherits Darwin background
        # without ever being tracked (review P1), and a transiently failed
        # restore must be retried on the next refresh, not recorded as done.
        for pid in (self._backgrounded_pids | live) - pids:
            batch_priority.set_background(pid, False)
        for pid in pids - self._backgrounded_pids:
            batch_priority.set_background(pid, True)
        if pids != self._backgrounded_pids:
            log.info(
                "batch priority: %s",
                f"background pids={sorted(pids)}" if pids else "normal")
        self._backgrounded_pids = pids

    def _release_stt_memory(self) -> None:
        """Return MLX's Metal buffer cache to the OS after a batch job.

        The cache grows to the largest decode working set and is otherwise
        retained for the life of the process — after an hour-long meeting the
        engine's footprint stayed hundreds of MB high. Runs on the STT
        executor via _stt_call; never between chunks (reallocation churn).
        """
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:  # noqa: BLE001 — memory hygiene must never fail a job
            log.debug("mlx cache clear failed", exc_info=True)

    async def _close_stt_backend(self, backend: STTBackend) -> None:
        close = getattr(backend, "close", None)
        if callable(close):
            try:
                await self._stt_call(close)
            except Exception:  # noqa: BLE001 — replacement is already usable
                log.exception("failed to close retired STT backend %s", backend.model_id)

    async def _defer_cleanup_recovery(self) -> None:
        defer = getattr(self.cleanup, "defer_recovery", None)
        if callable(defer):
            self._cleanup_recovery_deferred = True
            await defer()

    def _resume_cleanup_recovery(self) -> None:
        if not self._cleanup_recovery_deferred:
            return
        self._cleanup_recovery_deferred = False
        resume = getattr(self.cleanup, "resume_recovery", None)
        if callable(resume):
            resume()

    async def _wait_for_cleanup_recovery(self) -> None:
        cleanup = self.cleanup
        if cleanup is None or cleanup.loaded:
            return
        wait_until_ready = getattr(cleanup, "wait_until_ready", None)
        if callable(wait_until_ready):
            ready = await wait_until_ready(CLEANUP_FINAL_RECOVERY_TIMEOUT_S)
            if not ready:
                log.warning("cleanup recovery was not ready for final formatting")

    def _new_cleanup_process(self, model_id: str) -> CleanupProcess:
        return CleanupProcess(
            model_id,
            on_unhealthy=self._queue_cleanup_unhealthy_restart,
        )

    def _queue_cleanup_unhealthy_restart(self) -> None:
        """Restart only after any user-facing fallback/result is delivered."""
        current = self._cleanup_unhealthy_watch_task
        if current is not None and not current.done():
            return

        async def restart_when_safe() -> None:
            while (
                self.session is not None
                or self._starting
                or self._finalizing
                or self._cancelling_session
                or self._editing
                or self._reprocessing
                or self._transcribing
                or self._meeting_notes_running
            ):
                if self.shutdown.is_set():
                    return
                await asyncio.sleep(0.02)
            self._restart_if_cleanup_unhealthy()

        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            # The loop is already gone; the parent process is shutting down.
            log.warning("cleanup became unhealthy after the event loop closed")
            return
        self._cleanup_unhealthy_watch_task = loop.create_task(
            restart_when_safe()
        )

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
        if self._cleanup_restart_scheduled:
            return True
        self._cleanup_restart_scheduled = True
        log.error("cleanup worker is unhealthy — restarting engine after fallback")
        self.shutdown.set()
        # `shutdown` normally lets `serve()` unwind cleanly. A wedged native
        # MLX call can also strand asyncio/executor teardown, which previously
        # left the process alive and every later dictation on `llm_unhealthy`.
        # The final/raw fallback has already been drained to the client before
        # every caller reaches here, so use a short hard-exit backstop and let
        # the Swift supervisor replace the sidecar from a clean process.
        # Keep a loop-independent daemon timer as the actual backstop. If
        # `serve()` unwinds and `asyncio.run()` cancels pending tasks, a wedged
        # non-daemon MLX executor thread would otherwise keep Python alive
        # forever. The async task normally exits earlier after archive writes.
        timer = threading.Timer(
            CLEANUP_RESTART_ARCHIVE_GRACE_S + CLEANUP_RESTART_GRACE_S,
            self._hard_exit,
            args=(CLEANUP_RESTART_EXIT_CODE,),
        )
        timer.daemon = True
        timer.start()
        self._cleanup_restart_timer = timer
        self._cleanup_restart_task = asyncio.create_task(self._hard_exit_after_archives())
        return True

    async def _hard_exit_after_archives(self) -> None:
        """Preserve the just-finished dictation's optional audio, then exit.

        Audio encoding normally stays off the final-result path. A cleanup
        recovery is rare and process-destructive, so give already-started
        archive writes one bounded second before replacing the sidecar.
        """
        pending = tuple(self._archive_tasks)
        if pending:
            _done, unfinished = await asyncio.wait(
                pending, timeout=CLEANUP_RESTART_ARCHIVE_GRACE_S
            )
            if unfinished:
                log.warning(
                    "engine restart timed out waiting for %d audio archive write(s)",
                    len(unfinished),
                )
        await asyncio.sleep(CLEANUP_RESTART_GRACE_S)
        if self._cleanup_restart_timer is not None:
            self._cleanup_restart_timer.cancel()
        self._hard_exit(CLEANUP_RESTART_EXIT_CODE)

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

    async def _prune_superseded_models(self) -> None:
        """Reclaim disk from writing models an upgrade replaced.

        Called ONLY after the replacement has loaded and been adopted, so a
        user whose download failed keeps a working model. Skips whatever is
        currently configured, and `models.remove_from_cache` independently
        refuses anything outside the superseded map — deleting multi-GB
        weights deserves two locks, not one.
        """
        current = self.config.cleanup_model
        for old_id in models.SUPERSEDED_CLEANUP_MODELS:
            if old_id == current:
                continue
            try:
                freed = await asyncio.to_thread(models.remove_from_cache, old_id)
            except Exception:  # noqa: BLE001 — reclaiming disk is best-effort
                log.exception("could not remove superseded writing model %s", old_id)
                continue
            if freed:
                log.info("removed superseded writing model %s (reclaimed %.1f GB)",
                         old_id, freed / 1024**3)

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
            fallback_id = getattr(self.stt, "fallback_model_id", None)
            if not isinstance(fallback_id, str) or not fallback_id:
                log.exception("FATAL: STT model failed to load")
                with contextlib.suppress(Exception):
                    await self._set_loading(None)  # never strand a stale phase
                self.shutdown.set()
                return
            log.exception(
                "experimental STT backend failed to load; falling back to %s",
                fallback_id,
            )
            try:
                await self._close_stt_backend(self.stt)
                fallback = create_backend(fallback_id, self.config.language)
                if not fake_stt_enabled() and not await asyncio.to_thread(
                    models.is_cached, fallback.model_id
                ):
                    await self._download_with_progress(fallback.model_id, "fallback speech")
                await self._set_loading("Loading the fallback speech model…")
                await self._stt_call(fallback.load)
                # Persist the proven backend so a broken experimental install
                # cannot put every subsequent launch into the same failure loop.
                # Setup can take minutes and the app writes this file directly;
                # preserve any newer, unrelated settings before the full save.
                self.config.reload()
                fallback.language = self.config.language
                self.stt = fallback
                self.config.data["stt_model"] = fallback.model_id
                self.config.save(keys={"stt_model"})
                await self._set_loading(None)
                log.info("fallback stt ready (%s)", fallback.model_id)
            except Exception:
                log.exception("FATAL: fallback STT model failed to load")
                with contextlib.suppress(Exception):
                    await self._set_loading(None)
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
            engine = self._new_cleanup_process(self.config.cleanup_model)
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
                    # Only now — with a loaded, adopted replacement — is it safe
                    # to reclaim the old weights.
                    await self._prune_superseded_models()
                else:
                    await engine.aclose()
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
            close_cleanup_async = getattr(self.cleanup, "aclose", None)
            if callable(close_cleanup_async):
                await close_cleanup_async()
            else:
                close_cleanup = getattr(self.cleanup, "close", None)
                if callable(close_cleanup):
                    close_cleanup()
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
            if self.shutdown.is_set():
                return
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
        if self.shutdown.is_set():
            await self._error("engine shutting down", msg.get("session"))
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
            elif cmd == "edit_cancel":
                if self._editing:
                    self._edit_cancel.set()
            elif cmd == "action_start":
                await self._cmd_action_start(msg)
            elif cmd == "action_observe":
                await self._cmd_action_observe(msg)
            elif cmd == "action_end":
                self._drop_action_session(msg.get("id"))
            elif cmd == "action_cancel":
                if self._planning:
                    self._action_cancel.set()
                self._drop_action_session(msg.get("id"))
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
        if self._editing:
            # An in-flight voice edit is sub-second and preemptible: cancel it
            # (the cleanup loop checks the event between tokens) and wait
            # briefly instead of refusing — the dictation hotkey always wins.
            self._edit_cancel.set()
            for _ in range(20):
                if not self._editing:
                    break
                await asyncio.sleep(0.1)
            if self._editing:
                # The wedge-restart backstop will catch a truly stuck worker;
                # log so the rare fall-through is visible rather than silent.
                log.warning("edit did not yield within 2s of a dictation start")
        if self._planning:
            # Same contract as an edit: an action plan is a short foreground
            # model job, and pressing the dictation hotkey abandons it.
            self._action_cancel.set()
            for _ in range(20):
                if not self._planning:
                    break
                await asyncio.sleep(0.1)
            if self._planning:
                log.warning("action plan did not yield within 2s of a dictation start")
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
        # A dictation owns the machine: lift the batch-job Darwin-background
        # demotion right now, before any model work queues behind it.
        self._refresh_batch_priority()
        # Background note generation yields immediately; its cleanup worker
        # sees this event between output tokens, then the note job retries the
        # same chunk after dictation releases the model.
        self._meeting_notes_preempt.set()
        try:
            if self.session is not None:
                log.warning("start while session %s active — discarding it", self.session.id)
                await self._abort_session("superseded by new start")
            # A timed-out cleanup may be reaping or warming a replacement.
            # Finish/cancel that optional recovery before live STT starts, then
            # hold future warm-up until finalize/abort releases the machine.
            await self._defer_cleanup_recovery()
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
        finally:
            self._starting = False
            if self.session is None:
                self._resume_cleanup_recovery()
        log.info(
            "session %s started (bundle_id=%s app=%s mode=%s)",
            session_id,
            context.get("bundle_id"),
            context.get("app_name"),
            context.get("mode"),
        )

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
        # Count every received frame, including one dropped from the bounded
        # STT queue below. Duration enforcement is about microphone capture,
        # not only what the decoder managed to ingest under pressure.
        session.samples += len(chunk)
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
            if session.samples > self.config.max_recording_s * SAMPLE_RATE:
                await self._auto_finalize_at_limit(session)
            return
        if session.samples > self.config.max_recording_s * SAMPLE_RATE:
            await self._auto_finalize_at_limit(session)

    async def _auto_finalize_at_limit(self, session: Session) -> None:
        if self.session is not session:
            return
        limit_s = self.config.max_recording_s
        # Max-duration guard: auto-finalize as if `stop` was received, so a
        # stuck/locked recording can't accumulate audio without bound. Tell the
        # app BEFORE model work so it can stop the microphone and freeze the
        # timer instead of streaming frames the engine must discard.
        log.warning(
            "session %s hit max recording duration (%.0fs) — auto-finalizing",
            session.id,
            limit_s,
        )
        self.session = None
        await self._send({
            "event": "recording_auto_stopped",
            "session": session.id,
            "duration_s": session.samples / SAMPLE_RATE,
            "limit_s": limit_s,
        })
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
        await self._cancel_chunk_tasks_and_wait(session)
        await self._drain_feeder(session)
        await self._drain_preview(session)
        await self._stt_call(self.stt.reset)
        log.info("session %s discarded (%s)", session.id, why)
        self._resume_cleanup_recovery()
        # The engine is idle again after an abort too — without this, a
        # cancelled dictation left mining dead until the next FINALIZED one
        # (review finding).
        self._schedule_mining()

    @staticmethod
    def _cancel_chunk_tasks(session: Session) -> None:
        for task in session.chunk_tasks:
            Engine._cancel_chunk_task(session, task)

    @staticmethod
    async def _cancel_chunk_tasks_and_wait(session: Session) -> None:
        """Cooperatively cancel chunks before any authoritative fallback.

        CleanupProcess keeps its operation lock until the child acknowledges
        cancellation (or is replaced). Starting whole-text cleanup before that
        handoff can otherwise time out in the queue and discard LLM quality.
        """
        tasks = list(session.chunk_tasks)
        Engine._cancel_chunk_tasks(session)
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    @staticmethod
    def _cancel_chunk_task(session: Session, task: asyncio.Task[_ChunkResult]) -> None:
        event = session.chunk_cancel_events.get(task)
        if event is not None:
            event.set()
        task.cancel()

    async def _cmd_cancel(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            if msg.get("session") == self._finalizing_session_id:
                log.info(
                    "cancel ignored for already-finalizing session %s",
                    self._finalizing_session_id,
                )
                return
            await self._error("cancel: no active session", msg.get("session"))
            return
        self._cancelling_session = True
        try:
            await self._abort_session("cancel")
            await self._send({"event": "cancelled", "session": session.id})
        finally:
            self._cancelling_session = False
        # Chunk cleanup may have hit the hard watchdog before the user
        # cancelled. Confirm cancellation first, then restart instead of
        # leaving the poisoned single-worker executor for the next dictation.
        self._restart_if_cleanup_unhealthy()

    async def _cmd_stop(self, msg: dict[str, Any]) -> None:
        session = self.session
        if session is None:
            if msg.get("session") == self._finalizing_session_id:
                log.info(
                    "stop ignored for already-finalizing session %s",
                    self._finalizing_session_id,
                )
                return
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
        self._finalizing_session_id = session.id
        try:
            await self._finalize_session_inner(session, auto_stopped)
        finally:
            self._finalizing = False
            self._finalizing_session_id = None
            self._resume_cleanup_recovery()

    async def _finalize_session_inner(self, session: Session, auto_stopped: bool = False) -> None:
        t_stop = time.perf_counter()
        await self._drain_feeder(session)
        await self._drain_preview(session)
        try:
            raw = await self._stt_call(self.stt.finalize)
        except Exception as exc:
            log.exception("finalize failed")
            await self._cancel_chunk_tasks_and_wait(session)
            await self._stt_call(self.stt.reset)
            await self._error(f"transcription failed: {exc}", session.id)
            return
        stt_ms = int((time.perf_counter() - t_stop) * 1000)
        await self._send({"event": "transcript", "session": session.id, "raw": raw, "ms": stt_ms})
        # Live STT no longer owns Metal. If cleanup recovery was deferred after
        # a mid-session failure, start it now and give it a bounded chance to
        # preserve final-output quality before the formatting stage.
        self._resume_cleanup_recovery()
        await self._wait_for_cleanup_recovery()

        # Stage 2: formatting pipeline. Long whisper dictations whose segments
        # were already cleaned during recording assemble from those chunks
        # (only the tail is cleaned now → flat stop→final latency); anything
        # else — and ANY streaming failure — runs the classic whole-text path,
        # so a transcript is never lost to the new pipeline.
        format_started = time.perf_counter()
        ctx = session.context
        result: tuple[str, str, int, bool, str] | None = None
        if session.chunk_tasks:
            try:
                result = await self._streaming_result(session, raw)
            except Exception:  # noqa: BLE001 — the fallback below always runs
                log.exception("streaming finalize failed — falling back to whole-text cleanup")
                result = None
        if result is None:
            await self._cancel_chunk_tasks_and_wait(session)
            result = await self._apply_formatting(
                raw,
                bundle_id=ctx.get("bundle_id"),
                app_name=ctx.get("app_name"),
                explicit_mode=ctx.get("mode"),
                entities=ctx.get("entities"),
            )
        text, mode_name, cleanup_ms, cleanup_applied, reason = result
        cleanup_wall_ms = int((time.perf_counter() - format_started) * 1000)

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
            "cleanup_wall_ms": cleanup_wall_ms,
            "cleanup_applied": cleanup_applied,
            "total_ms": total_ms,
        }
        if audio_name:
            final_evt["audio"] = audio_name
        if auto_stopped:
            final_evt["auto_stopped"] = True
        await self._send(final_evt)
        log.info(
            "session %s done: stt_ms=%d mode=%s reason=%s cleanup_ms=%d "
            "cleanup_wall_ms=%d cleanup_applied=%s total_ms=%d samples=%d audio=%s",
            session.id,
            stt_ms,
            mode_name,
            reason,
            cleanup_ms,
            cleanup_wall_ms,
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
            session.stream_prefix_candidates = (
                formatting.build_prefill_prompt_candidates(
                    self.config,
                    bundle_id=ctx.get("bundle_id"),
                    app_name=ctx.get("app_name"),
                    explicit_mode=ctx.get("mode"),
                    entities=session.start_entities,
                )
            )
        # Cross-boundary self-correction: a segment that BEGINS with a
        # retraction marker ("no wait…", "scratch that…") refers back across
        # the boundary — never clean it alone. Merge with the previous raw
        # segment and re-clean the pair as ONE chunk, replacing the previous
        # result. The marker decides SCOPE only; the LLM does the edit.
        head = " ".join(seg_raw.split()[:RETRACTION_HEAD_WORDS])
        if session.chunk_raws and _RETRACTION_RE.search(head):
            replaced_task = session.chunk_tasks[-1]
            self._cancel_chunk_task(session, replaced_task)
            merged = session.chunk_raws[-1] + " " + seg_raw
            session.chunk_raws[-1] = merged
            prev = session.chunk_tasks[-2] if len(session.chunk_tasks) >= 2 else None
            session.chunk_tasks[-1] = self._new_chunk_task(
                session,
                merged,
                prev,
                replaced_task=replaced_task,
            )
            return
        prev = session.chunk_tasks[-1] if session.chunk_tasks else None
        session.chunk_raws.append(seg_raw)
        session.chunk_tasks.append(self._new_chunk_task(session, seg_raw, prev))

    def _new_chunk_task(
        self,
        session: Session,
        seg_raw: str,
        prev_task: asyncio.Task[_ChunkResult] | None,
        *,
        replaced_task: asyncio.Task[_ChunkResult] | None = None,
    ) -> asyncio.Task[_ChunkResult]:
        cancel_event = threading.Event()
        task = asyncio.create_task(
            self._clean_chunk_task(
                session,
                seg_raw,
                prev_task,
                cancel_event,
                replaced_task=replaced_task,
            )
        )
        session.chunk_cancel_events[task] = cancel_event
        return task

    async def _clean_chunk_task(
        self,
        session: Session,
        seg_raw: str,
        prev_task: asyncio.Task[_ChunkResult] | None,
        cancel_event: threading.Event,
        *,
        replaced_task: asyncio.Task[_ChunkResult] | None = None,
    ) -> _ChunkResult:
        """Chunk cleanup that first waits for its predecessor (for the seam
        context). Waits via asyncio.wait so a cancelled/failed predecessor only
        costs us the context line, while OUR own cancellation still propagates."""
        if replaced_task is not None:
            # Do not admit a merged retraction while the request it replaces
            # still owns CleanupProcess's single operation lock.
            await asyncio.gather(replaced_task, return_exceptions=True)
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
                    "\n\nPrevious text (context only, do NOT repeat it): «" + tail_words + "». "
                    "If it ends in a numbered list, continue with the next number; "
                    "never restart at 1."
                )
            # Same deterministic prep the whole-text gate gives the model
            # (formatting.run_gate): spoken break commands become real line
            # breaks before the LLM ever sees the chunk.
            seg_input = formatting.apply_spoken_commands(formatting.scrub_fillers(seg_raw))
            if not seg_input.strip():
                # A chunk that was ONLY a break command must keep its break.
                return _ChunkResult(seg_input, 0)
            result = await cleanup.cleanup(
                formatting.encode_breaks(seg_input),
                system_prompt,
                cancel_event=cancel_event,
                allowed_terms=session.stream_allowed_terms,
                prefix_candidates=session.stream_prefix_candidates,
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
        ctx = session.context
        # The final tail is not visible to `_on_new_segment`. A Latin opening
        # can therefore start streaming cleanup even when a long non-Latin tail
        # makes the COMPLETE utterance a romanization/native-script case. Use
        # one whole-text multilingual pass so language and list cues cannot be
        # split across two writing systems at the final seam.
        gate = formatting.run_gate(
            raw,
            self.config,
            bundle_id=ctx.get("bundle_id"),
            app_name=ctx.get("app_name"),
            explicit_mode=ctx.get("mode"),
            entities=ctx.get("entities"),
        )
        if gate.romanize or formatting.is_mostly_non_latin(raw):
            log.info("full transcript requires non-Latin handling — falling back to whole-text cleanup")
            return None
        tail_head = " ".join(tail.split()[:RETRACTION_HEAD_WORDS])
        tail_retracts = bool(
            tail
            and session.chunk_raws
            and _RETRACTION_RE.search(tail_head)
        )

        # If only the last chunk is unfinished at stop, replace that pending
        # cleanup plus the tail with one authoritative merged cleanup. This
        # removes a serial generation while preserving every raw word and gives
        # the model the full final seam (including a possible retraction).
        # Earlier chunks must already be valid; otherwise retain the normal
        # bounded wait and whole-text fallback.
        priority_last: asyncio.Task[_ChunkResult] | None = None
        earlier_tasks = session.chunk_tasks[:-1]
        earlier_ready = all(
            task.done()
            and not task.cancelled()
            and task.exception() is None
            and isinstance(task.result(), _ChunkResult)
            for task in earlier_tasks
        )
        last_task = session.chunk_tasks[-1]
        if tail and not last_task.done() and earlier_ready:
            priority_last = last_task
            self._cancel_chunk_task(session, last_task)
            # Cancellation owns the operation lock until the worker
            # acknowledges or is retired. Complete that handoff before the
            # merged request is admitted.
            await asyncio.gather(last_task, return_exceptions=True)
            if not last_task.cancelled():
                log.warning("priority final-tail cancellation was suppressed — falling back")
                return None
            prev_text = (
                earlier_tasks[-1].result().text
                if earlier_tasks
                else None
            )
            merged = session.chunk_raws[-1] + " " + tail
            priority_cancel = threading.Event()
            priority_task = asyncio.create_task(
                self._clean_chunk_text(
                    session,
                    merged,
                    prev_text,
                    priority_cancel,
                )
            )
            log.info("final tail replaced one unfinished chunk cleanup")
            # The old 1.5-second gather limit is for a nearly-finished chunk,
            # not this brand-new authoritative generation. Give the merged
            # request its own production queue + hard-watchdog budget.
            priority_timeout_s = (
                adaptive_timeout_ms(merged) / 1000.0
                + HARD_TIMEOUT_GRACE_S
                + QUEUE_TIMEOUT_S
                + 0.25
            )
            try:
                _done, priority_pending = await asyncio.wait(
                    [priority_task],
                    timeout=priority_timeout_s,
                )
                if priority_pending:
                    priority_cancel.set()
                    priority_task.cancel()
                    await asyncio.gather(priority_task, return_exceptions=True)
                    log.warning("priority final-tail cleanup timed out — falling back")
                    return None
                if priority_task.cancelled() or priority_task.exception() is not None:
                    log.warning("priority final-tail cleanup failed — falling back")
                    return None
                merged_result = priority_task.result()
                if not isinstance(merged_result, _ChunkResult) or not merged_result.applied:
                    log.warning("priority final-tail cleanup was not applied — falling back")
                    return None
                earlier_results = [task.result() for task in earlier_tasks]
                cleaned = [result.text for result in earlier_results]
                cleaned.append(merged_result.text)
                applied_any = True
                tail_ms = merged_result.ms
                tail = ""
            finally:
                # A server cancellation/disconnect must not orphan the local
                # priority task outside the session's normal bookkeeping.
                if not priority_task.done():
                    priority_cancel.set()
                    priority_task.cancel()
                    await asyncio.gather(priority_task, return_exceptions=True)
        else:
            # A timeout must cooperatively cancel unfinished worker requests
            # before whole-text fallback. Bare wait_for(gather()) left native
            # generation alive and made the fallback miss its queue deadline.
            _done, pending = await asyncio.wait(
                list(session.chunk_tasks),
                timeout=STREAM_GATHER_TIMEOUT_S,
            )
            if pending:
                for task in pending:
                    self._cancel_chunk_task(session, task)
                await asyncio.gather(*pending, return_exceptions=True)
                log.warning("streaming chunk task did not complete — falling back")
                return None
            if any(
                task.cancelled() or task.exception() is not None
                for task in session.chunk_tasks
            ):
                log.warning("streaming chunk task failed — falling back")
                return None
            results = [task.result() for task in session.chunk_tasks]
            if any(not isinstance(result, _ChunkResult) for result in results):
                log.warning("streaming chunk task did not complete — falling back")
                return None
            cleaned = [result.text for result in results]
            applied_any = any(result.applied for result in results)
            tail_ms = 0

        if priority_last is not None and not priority_last.cancelled():
            # Defensive: the task was synchronously cancelled above. Never
            # assemble both its output and the merged replacement.
            log.warning("streaming chunk task did not complete — falling back")
            return None

        if tail:
            if tail_retracts:
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
        if _numbering_restarts(cleaned):
            log.warning("streaming list numbering was invalid — falling back to whole-text cleanup")
            return None
        assembled = _join_chunks(cleaned)
        if not assembled.strip():
            return None
        # Gate over the FULL raw text — for its GateResult fields only
        # (replacements/tags/category/chat rules, now with stop-time entities).
        # Its use_llm is deliberately ignored: no second LLM pass here.
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
            prefix_candidates = formatting.build_prefill_prompt_candidates(
                self.config,
                bundle_id=bundle_id,
                app_name=app_name,
                explicit_mode=explicit_mode,
                entities=entities,
                romanize=gate.romanize,
            )
            # The model gets gate.text, NOT raw: the gate already converted
            # spoken break commands ("now a new line") into real line breaks
            # and scrubbed fillers. Passing raw here (the original bug) showed
            # the model the literal words, which it dutifully kept as content.
            if gate.romanize:
                # Transliteration: skip the length-ratio guard and allow longer.
                result = await self.cleanup.cleanup(
                    gate.text, gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    timeout_ms=4000, check_ratio=False, cancel_event=cancel_event,
                    prefix_candidates=prefix_candidates,
                )
            else:
                result = await self.cleanup.cleanup(
                    formatting.encode_breaks(gate.text),
                    gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    cancel_event=cancel_event,
                    allowed_terms=self._allowed_terms(gate.mode),
                    prefix_candidates=prefix_candidates,
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

    def _meeting_glossary(self) -> str | None:
        """Conservative prompt for long-form meeting transcription.

        Explicit vocabulary and corrections are durable user signals.
        Auto-mined terms are guesses derived from prior STT output; repeating
        them across hundreds of meeting chunks amplified bad spellings and
        triggered costly prompt-free retries in real runs.
        """
        return build_glossary_prompt(
            self.config.user_vocabulary,
            self.config.learned_vocabulary,
            [],
            [],
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
                    or self._editing
                    or self._transcribing
                    or self._meeting_notes_running
                    or not (self.cleanup is not None and self.cleanup.loaded)
                    or not self.config.vocab_mining
                ):
                    return
                if self._miner is None:
                    self._miner = VocabMiner(self.config.home, self._mine_generate)
                # Idle mining is the definition of interruptible batch work —
                # run it demoted so an "idle" machine stays cool and quiet.
                self._begin_batch_job()
                try:
                    more = await self._miner.step()
                finally:
                    self._end_batch_job()
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

        task = asyncio.create_task(_write())
        self._archive_tasks.add(task)
        task.add_done_callback(self._archive_tasks.discard)
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
                or self._meeting_notes_running or self._editing):
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
            old = self.stt
            self.stt = backend
            self.config.data["stt_model"] = model_id
            await self._close_stt_backend(old)
        else:
            # Load-then-swap: build and fully load the replacement FIRST, then
            # retire the old one. A failed load (bad download, OOM) therefore
            # leaves the working engine intact instead of leaving no cleanup at
            # all. Peak memory holds both only for the load window (rare,
            # user-initiated); aclose() reaps the old model process before ack.
            engine = self._new_cleanup_process(model_id)
            if not fake_stt_enabled():
                try:
                    await engine.load_async(STATIC_SYSTEM_PROMPT)
                except Exception:
                    await engine.aclose()
                    raise  # keep self.cleanup pointing at the old, working engine
            old = self.cleanup
            self.cleanup = engine
            self.config.data["cleanup_model"] = model_id
            if old is not None:
                await old.aclose()
        self.config.save(keys={f"{kind}_model"})
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
        old = self._reprocess_backend
        self._reprocess_backend = backend
        if old is not None:
            await self._close_stt_backend(old)
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
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
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
        # Idle vocab mining shares the single-thread cleanup executor and can
        # hold it for seconds. Without preempting it (as _cmd_start does), an
        # edit queues behind a mining step, blows its own from-submission
        # deadline, and would falsely mark the engine unhealthy → needless
        # restart. Cancel mining now; the miner reschedules after the edit.
        if self._miner_task is not None:
            self._miner_task.cancel()
        self._mine_cancel.set()
        self._editing = True
        self._edit_cancel.clear()
        asyncio.create_task(self._run_edit_text(dict(msg), text, instruction))

    async def _run_edit_text(self, msg: dict[str, Any], text: str, instruction: str) -> None:
        try:
            t0 = time.perf_counter()
            # A dedicated budget scaled to selection size — the default
            # adaptive timeout tops out at 6 s (tuned for dictation cleanup),
            # so a long selection would always "time out" mid-rewrite.
            timeout_ms = min(20_000, max(6_000, len(text) * 8))
            result = await self.cleanup.cleanup(
                text, editing.build_edit_prompt(instruction), timeout_ms=timeout_ms,
                check_ratio=False, cancel_event=self._edit_cancel)
            edited_core = result.text.strip()
            out = editing.restore_boundary_whitespace(text, edited_core)
            applied = bool(result.applied)
            reason = result.reason or ""
            if applied and not edited_core:
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
            self._editing = False
            self._schedule_mining()

    def _drop_action_session(self, requested: Any) -> None:
        """Forget the live action session (loop finished, cancelled, or the
        app gave up). A mismatched id is ignored so a stale `action_end` from
        a previous action cannot kill its successor's session."""
        if self._action_session is None:
            return
        if requested is not None and requested != self._action_id:
            return
        self._action_session = None
        self._action_id = None

    async def _action_busy_reason(self) -> tuple[str, str] | None:
        if self.session is not None or self._starting or self._finalizing:
            return ("action: busy (dictation in progress)", "busy")
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing or self._planning):
            return ("action: busy (another job in progress)", "busy")
        if self.cleanup is None:
            return ("action: writing model unavailable", "cleanup_unavailable")
        return None

    async def _cmd_action_start(self, msg: dict[str, Any]) -> None:
        """Action Mode, turn 1: open an observe→decide→act session.

        The transcript arrives RAW — cleanup would rewrite the very words that
        identify a person or an app. Safety lives in `actions.ActionSession`
        (budgets that span turns, the locked `sends` bit) plus the same
        `validate_plan` gate per batch, all re-checked independently by the
        app before anything touches the machine.
        """
        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "action_failed", "id": msg.get("id"),
                "code": code, "error": error,
            })

        transcript = msg.get("transcript")
        if not isinstance(transcript, str) or not transcript.strip():
            await fail("action: missing 'transcript'", "invalid_arguments")
            return
        if len(transcript) > actions.MAX_TRANSCRIPT_CHARS:
            await fail(
                f"action: command over {actions.MAX_TRANSCRIPT_CHARS} characters",
                "too_large")
            return
        busy = await self._action_busy_reason()
        if busy is not None:
            await fail(*busy)
            return
        # A new action unconditionally replaces any live session: the only way
        # a session is still here is that the app abandoned it (crash, kill
        # mid-loop), and wedging Action Mode until an engine restart would be
        # a worse failure than dropping a loop nobody is driving.
        if self._action_session is not None:
            log.info("action_start: replacing an abandoned session %s", self._action_id)
        context = actions.ActionContext.from_dict(msg.get("context"))
        context.transcript = transcript
        session = actions.ActionSession(transcript, context)
        self._action_session = session
        self._action_id = msg.get("id")
        if self._miner_task is not None:
            self._miner_task.cancel()
        self._mine_cancel.set()
        self._planning = True
        self._action_cancel.clear()
        asyncio.create_task(self._run_action_turn(dict(msg), session,
                                                  session.first_message()))

    async def _cmd_action_observe(self, msg: dict[str, Any]) -> None:
        """Action Mode, turns 2+: the app reports what actually happened and
        what the screen says now; the session decides the next steps."""
        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "action_failed", "id": msg.get("id"),
                "code": code, "error": error,
            })

        session = self._action_session
        if session is None or msg.get("id") != self._action_id:
            await fail("action: no session with that id", "no_session")
            return
        busy = await self._action_busy_reason()
        if busy is not None:
            await fail(*busy)
            return
        if session.finished:
            self._drop_action_session(self._action_id)
            await fail("action: session already finished", "no_session")
            return
        if session.turns_used >= actions.MAX_TURNS:
            self._drop_action_session(self._action_id)
            await fail(f"action: ran out of turns (max {actions.MAX_TURNS})",
                       "turn_limit")
            return
        observation = msg.get("observation")
        if not isinstance(observation, dict):
            await fail("action: missing 'observation'", "invalid_arguments")
            return
        self._planning = True
        self._action_cancel.clear()
        asyncio.create_task(self._run_action_turn(
            dict(msg), session, session.observation_message(observation)))

    async def _run_action_turn(self, msg: dict[str, Any],
                               session: actions.ActionSession,
                               message: str) -> None:
        """One model call → one validated turn. Shared by start and observe;
        `message` is the user-role text (command or observation)."""
        try:
            t0 = time.perf_counter()
            turn: dict[str, Any] | None = None
            last_error = ""
            for attempt in range(2):
                # The repair carries the actual rejection: "not valid JSON"
                # teaches nothing when the JSON was fine and a rule was broken.
                prompt = (session.system_prompt() if attempt == 0
                          else session.system_prompt() + "\n"
                               + actions.turn_repair_note(last_error))
                result = await self.cleanup.cleanup(
                    message, prompt,
                    # The cold-start budget covers the FIRST attempt only; the
                    # repair rides the now-warm prefix. Without this the worst
                    # case (2×35s) outran the app's backstop and a healthy
                    # engine got cancelled mid-answer (review finding).
                    timeout_ms=(actions.FIRST_TURN_TIMEOUT_MS
                                if session.turns_used == 0 and attempt == 0
                                else actions.PLAN_TIMEOUT_MS),
                    check_ratio=False,
                    cancel_event=self._action_cancel,
                    max_tokens=actions.PLAN_MAX_TOKENS,
                    # Every turn of a session shares the same system prompt;
                    # two synthetic user messages make their common token
                    # prefix exactly that prompt, so turn 2+ skips its ~2k
                    # tokens of prefill (~1.5s per turn on a 4B).
                    prefix_candidates=[(prompt, "a"), (prompt, "b")],
                )
                if self._action_cancel.is_set():
                    self._drop_action_session(self._action_id)
                    await self._send({"event": "action_failed", "id": msg.get("id"),
                                      "code": "cancelled", "error": "action: cancelled"})
                    return
                if not result.applied:
                    last_error = f"model unavailable ({result.reason or 'no output'})"
                    continue
                try:
                    turn = session.accept_reply(result.text)
                    break
                except actions.PlanError as exc:
                    last_error = str(exc)
                    # The reply excerpt is the difference between diagnosing a
                    # systematic model spelling and guessing at it. Local log,
                    # same sensitivity as the goal lines already logged.
                    log.warning("action turn attempt %d rejected: %s — reply: %s",
                                attempt + 1, exc,
                                " ".join(result.text.split())[:220])

            ms = int((time.perf_counter() - t0) * 1000)
            if turn is None:
                # The session survives a rejected turn: no turn was consumed
                # (accept_reply raises before counting), and the app may ask
                # again with a fresh observation — which beats the inline
                # repair when the model is stuck on a shape. Bounded by its
                # own cap so a stuck model cannot be asked forever.
                session.rejections += 1
                if session.rejections >= 4:
                    self._drop_action_session(self._action_id)
                await self._send({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "plan_invalid",
                    "error": f"could not plan that action: {last_error}",
                    "ms": ms,
                })
                return
            if "fail" in turn:
                self._drop_action_session(self._action_id)
                await self._send({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "unsupported", "error": turn["fail"], "ms": ms,
                })
                return
            if turn["done"]:
                self._drop_action_session(self._action_id)
            evt: dict[str, Any] = {
                "event": "action_turn", "turn": session.turns_used,
                "sends": bool(session.sends), "goal": session.goal,
                "steps": turn["steps"], "done": turn["done"], "ms": ms,
            }
            if msg.get("id") is not None:
                evt["id"] = msg.get("id")
            await self._send(evt)
            self._restart_if_cleanup_unhealthy()
            log.info("action turn %d: %d steps sends=%s done=%s ms=%d",
                     session.turns_used, len(turn["steps"]), session.sends,
                     turn["done"], ms)
        except Exception as exc:  # noqa: BLE001 — the app is waiting on an answer
            log.exception("action turn failed")
            self._drop_action_session(self._action_id)
            await self._send({
                "event": "action_failed", "id": msg.get("id"),
                "code": "failed", "error": f"action planning failed: {exc}",
            })
        finally:
            self._planning = False
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
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
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
            format_started = time.perf_counter()
            text, mode_name, cleanup_ms, cleanup_applied, _reason = await self._apply_formatting(
                raw,
                bundle_id=msg.get("bundle_id"),
                app_name=msg.get("app_name"),
                explicit_mode=msg.get("mode"),
            )
            cleanup_wall_ms = int((time.perf_counter() - format_started) * 1000)
            evt: dict[str, Any] = {
                "event": "reprocessed",
                "audio": name,
                "raw": raw,
                "text": text,
                "mode": mode_name,
                "stt_model": model_id,
                "stt_ms": stt_ms,
                "cleanup_ms": cleanup_ms,
                "cleanup_wall_ms": cleanup_wall_ms,
                "cleanup_applied": cleanup_applied,
            }
            if msg.get("id") is not None:
                evt["id"] = msg.get("id")
            await self._send(evt)
            self._restart_if_cleanup_unhealthy()
            log.info(
                "reprocess %s with %s: stt_ms=%d cleanup_ms=%d cleanup_wall_ms=%d mode=%s",
                name,
                model_id,
                stt_ms,
                cleanup_ms,
                cleanup_wall_ms,
                mode_name,
            )
        except Exception as exc:  # noqa: BLE001 — always complete the row request
            log.exception("reprocess failed")
            await self._reprocess_failed(msg, f"reprocess failed: {exc}")
        finally:
            if saved_language is not None and hasattr(self.stt, "language"):
                self.stt.language = saved_language
            self._reprocessing = False
            with contextlib.suppress(RuntimeError):  # executor gone at shutdown
                await self._stt_call(self._release_stt_memory)
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
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
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
            with contextlib.suppress(RuntimeError):  # executor gone at shutdown
                await self._stt_call(self._release_stt_memory)
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
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
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

    def _meeting_plan_path(self, meeting_id: str, speaker: str) -> Path:
        safe = "".join(c for c in f"{meeting_id}.{speaker}" if c.isalnum() or c in "._-")
        return velora_home() / "cache" / "meeting-plans" / f"{safe}.json"

    @staticmethod
    def _load_meeting_plan(path: Path, total_samples: int) -> list[tuple[int, int, str]] | None:
        """The chunk plan committed by this track's FIRST run, or None.

        Chunk indexes are the crash-resume cursor, so a resume must transcribe
        the exact plan the committed segments came from — recomputing could
        differ (diarization toggled, model download now failing) and silently
        skip or duplicate audio. The cache also makes resume independent of
        the diarization backend entirely: spans are just sample ranges.
        """
        try:
            data = json.loads(path.read_text())
            if data.get("version") != MEETING_PLAN_VERSION:
                return None
            spans = [
                (int(a), int(b), str(label))
                for a, b, label in data["spans"]
            ]
        except (OSError, ValueError, KeyError, TypeError):
            return None
        if not spans:
            return None
        ok = all(
            0 <= a < b <= total_samples and label
            for a, b, label in spans
        )
        return spans if ok else None

    @staticmethod
    def _save_meeting_plan(path: Path, spans: list[tuple[int, int, str]]) -> None:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({
                "version": MEETING_PLAN_VERSION,
                "spans": spans,
            }))
            tmp.replace(path)
            # Opportunistic prune: plans are tiny, but deleted meetings leave
            # orphans behind — drop anything older than a week.
            cutoff = time.time() - 7 * 86_400
            for old in path.parent.glob("*.json"):
                try:
                    if old.stat().st_mtime < cutoff:
                        old.unlink()
                except OSError:
                    continue
        except OSError:
            log.warning("meeting plan cache write failed", exc_info=True)

    async def _diarize_spans(
        self, pcm: Any, meeting_id: str
    ) -> list[tuple[int, int, str]] | None:
        """Diarized transcription plan for a system-audio track, or None.

        None means "use the classic single-speaker path" — backend missing,
        model download failed, or diarization errored. Audio-only clustering
        has no participant identity to validate against, so every result uses
        its useful speech regions but keeps the honest, stable "Them" label.
        """
        try:
            if not diarization.available():
                log.info("diarization: sherpa-onnx not importable — skipping")
                return None
            if self._meeting_transcribe_cancel:
                return None
            # Always runs the pinned-hash verification: existence alone must
            # not bless a file truncated by a mid-download kill. The download
            # and the diarize() call are each seconds+; check cancel around
            # them so cancelling a long meeting bites promptly.
            await asyncio.to_thread(diarization.ensure_models)
            if self._meeting_transcribe_cancel:
                return None
            turns = await asyncio.to_thread(diarization.diarize, pcm)
            speakers = {t.speaker for t in turns}
            speaker_count = len(speakers)
            if speaker_count == 0:
                return None
            spans = diarization.plain_speaker_plan(
                turns, total_samples=len(pcm))
            log.info(
                "diarization: %s detected %d audio cluster(s); using %d "
                "speech-region chunks with stable Them labels",
                meeting_id, speaker_count, len(spans))
            return spans or None
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

        self._begin_batch_job()
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
            # The remote/system track may carry several people. Audio-only
            # clustering supplies speech regions, but without participant
            # metadata it cannot assign trustworthy identities. Keep every
            # remote chunk labeled "them"; the mic track is "me" by
            # construction and is never diarized.
            #
            # The chunk plan is committed to a cache file on first computation
            # and a resume (start_chunk > 0) must run the CACHED plan: the
            # committed chunk indexes came from it, and recomputing under a
            # flipped diarization toggle or a failing model download would
            # silently skip or duplicate audio. No cached plan on resume →
            # restart from zero and tell the app to drop its stale rows.
            plan_path = self._meeting_plan_path(meeting_id, speaker)
            restarted = False
            spans: list[tuple[int, int, str]] | None = None
            if start_chunk > 0:
                spans = self._load_meeting_plan(plan_path, len(pcm))
                if spans is None:
                    log.warning(
                        "meeting %s/%s: resume at chunk %d without a cached "
                        "plan — restarting the track", meeting_id, speaker,
                        start_chunk)
                    restarted = True
                    start_chunk = 0
            if spans is None:
                if speaker == "them" and self.config.meeting_diarization:
                    spans = await self._diarize_spans(pcm, meeting_id)
                if spans is None:
                    chunks = split_for_batch(pcm)
                    spans = []
                    cursor = 0
                    for chunk in chunks:
                        spans.append((cursor, cursor + len(chunk), speaker))
                        cursor += len(chunk)
                self._save_meeting_plan(plan_path, spans)
            await self._send({
                "event": "meeting_transcribe_started", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "duration_s": round(duration_s, 1), "chunks": len(spans),
                "start_chunk": min(start_chunk, len(spans)),
                "restarted": restarted,
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
                # Re-demote after a dictation released the machine (the wait
                # loop above), and pick up a respawned cleanup child.
                self._refresh_batch_priority()
                sample_a, sample_b, chunk_speaker = spans[index]
                self.stt.initial_prompt = self._meeting_glossary()
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
            # The plan file deliberately OUTLIVES completion: a crash between
            # transcribe-done and notes-done re-enqueues this track with
            # start_chunk == len(spans), and only the cached plan proves that
            # cursor means "already finished" rather than "plan changed".
            # The 7-day prune in _save_meeting_plan retires it.
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
            self._end_batch_job()
            with contextlib.suppress(RuntimeError):  # executor gone at shutdown
                await self._stt_call(self._release_stt_memory)
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
        prompt = msg.get("prompt")
        if prompt is not None and not isinstance(prompt, str):
            await self._send({
                "event": "meeting_notes_failed", "id": msg.get("id"),
                "meeting_id": meeting_id, "code": "invalid_arguments",
                "error": "custom notes prompt must be a string",
            })
            return
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
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
        # The schema clause is appended outside the editable guidance so a
        # custom prompt can change tone and focus but never break the JSON
        # contract parse_notes_json() enforces.
        schema_clause = (
            "Return JSON only with exact keys summary (string), decisions (array of "
            "strings), and action_items (array of strings)."
        )
        default_guidance = (
            "Create faithful meeting notes from this transcript chunk. "
            "Do not invent owners, deadlines, decisions, or facts. "
            "Me and Them are audio channels, not verified identities. If a legacy "
            "transcript contains Speaker-number labels, treat those the same way. "
            "Never guess who a speaker is."
        )
        # Truncate rather than reject: Swift counts the same Unicode scalars,
        # but a completed meeting must never fail over prompt length skew.
        custom_guidance = str(msg.get("prompt") or "").strip()[:8_000]
        guidance = custom_guidance or default_guidance
        map_prompt = f"{guidance}\n\n{schema_clause}"
        reduce_prompt = (
            "Merge these partial meeting notes without inventing facts or duplicates. "
            + (
                f"Follow these notes instructions where they apply: {custom_guidance}\n\n"
                if custom_guidance
                else ""
            )
            + schema_clause
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
                # Dictation just released the machine (wait loop above), or a
                # cleanup child respawned — recompute who gets demoted.
                self._refresh_batch_priority()
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

        self._begin_batch_job()
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
            self._end_batch_job()
            # Notes generate inside the cleanup child — the parent-side cache
            # clear cannot reach that allocator, so ask the child directly.
            release = getattr(self.cleanup, "release_cache", None)
            if callable(release):
                try:
                    await release()
                except Exception:  # noqa: BLE001 — hygiene must never fail the job
                    log.debug("cleanup cache release failed", exc_info=True)
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
