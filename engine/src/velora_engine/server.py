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
import ctypes
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
from enum import Enum
from pathlib import Path
from typing import Any, Callable, TypeVar

import numpy as np

from . import (
    __version__, actions, batch_priority, diarization, editing, formatting,
    models, protocol,
)
from .audio_store import ActiveAudioSpool, AudioStore
from .cleanup import (
    HARD_TIMEOUT_GRACE_S,
    QUEUE_TIMEOUT_S,
    _RETRACTION_RE,
    adaptive_timeout_ms,
)
from .cleanup_process import CleanupProcess
from .config import Config, velora_home
from .formatting import STATIC_SYSTEM_PROMPT
from .media import load_media, load_meeting_media, split_for_batch
from .meeting_notes import chunk_transcript, merge_notes, parse_notes_json
from .stt import (
    SAMPLE_RATE,
    STTBackend,
    build_glossary_prompt,
    create_backend,
    fake_stt_enabled,
    pcm_from_payload,
    speech_window_fraction,
    transcribe_clip,
)
from .vocab_miner import VocabMiner

T = TypeVar("T")

log = logging.getLogger("velora.server")


class _ActionModelUnavailable(Exception):
    """A chained Action model call failed before returning a verdict."""


class _ActionContextTooLarge(Exception):
    """The bounded screen still exceeds Action Mode's local prefill ceiling."""


class SpoolDisposition(Enum):
    preserve = "preserve"
    discard = "discard"


def _memory_pressure_level() -> int:
    """Return Darwin's current memory-pressure flag, or normal/unknown as 0.

    The kernel uses the dispatch memory-pressure flag values: normal=1,
    warning=2, critical=4. Failure is intentionally fail-open for latency: a
    missing signal keeps the warm model rather than unloading on a guess.
    """
    if sys.platform != "darwin":
        return 0
    try:
        value = ctypes.c_int(0)
        size = ctypes.c_size_t(ctypes.sizeof(value))
        libc = ctypes.CDLL(None, use_errno=True)
        sysctlbyname = libc.sysctlbyname
        sysctlbyname.argtypes = [
            ctypes.c_char_p, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
        ]
        sysctlbyname.restype = ctypes.c_int
        if sysctlbyname(
            b"kern.memorystatus_vm_pressure_level",
            ctypes.byref(value), ctypes.byref(size), None, 0,
        ) != 0:
            return 0
        return int(value.value)
    except (AttributeError, OSError, TypeError, ValueError):
        return 0


CLEANUP_RESTART_EXIT_CODE = os.EX_TEMPFAIL
CLEANUP_RESTART_GRACE_S = 0.1
CLEANUP_RESTART_ARCHIVE_GRACE_S = 1.0

PARENT_POLL_S = 2.0

# Full CPU diarization costs roughly two seconds per audio-minute, while the
# measured Whisper path costs about 3.5 seconds per minute. It can repay that
# pass only below ~43% active windows. Long meetings skip it regardless: the
# silence fast-path already avoids empty Whisper chunks, while serial CPU
# planning delays the first transcript segment by minutes. Both fallbacks keep
# the same honest "Them" label.
_DIARIZATION_DENSE_ACTIVITY_FRACTION = 0.43
_DIARIZATION_MAX_TRACK_S = 30 * 60

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
# Cleanup replacement stays deferred for the complete foreground session.
# Failed-worker formatting uses the lossless deterministic fallback; recovery
# resumes only after the user-facing final event has been sent.

# Idle gap before (and between) vocab-mining steps — mining must only ever use
# compute nobody is waiting on, and yields the moment a session starts.
MINE_IDLE_S = 20.0
MINE_STARTUP_DELAY_S = 60.0

# Resume cursors are indexes into this exact cached plan. Bump whenever plan
# semantics change so an upgraded app restarts the track instead of mixing old
# fragmented labels with the corrected plan.
MEETING_PLAN_VERSION = 3

# Meeting notes are a bounded transformation, but they are materially larger
# than dictation cleanup. Keep each map context small enough that Qwen3.5-4B
# cannot grow a multi-GB working cache from one long transcript slice. Partial
# notes need less output than the final reducer; separate ceilings prevent a
# verbose map from consuming the whole hard deadline.
MEETING_NOTES_TIMEOUT_MS = 20_000
MEETING_NOTES_CHUNK_CHARS = 4_000
MEETING_NOTES_RETRY_CHUNK_CHARS = 2_000
MEETING_NOTES_MAP_MAX_TOKENS = 384
MEETING_NOTES_REDUCE_MAX_TOKENS = 512
# The server advertises STT readiness before the cleanup worker finishes its
# background warm-up. Relaunch recovery can therefore submit durable notes a
# few seconds before Qwen is usable. Wait only for an existing, healthy worker;
# an absent or unhealthy model still fails honestly instead of hanging.
MEETING_NOTES_MODEL_READY_WAIT_S = 15.0

# CleanupProcess replaces a wedged model child asynchronously. Action Mode is
# already inside a 150-second app-side turn backstop, so wait for that bounded
# replacement once instead of burning repair/rejection budgets against the
# brief `loaded = false` interval. The observed replacement takes ~6 seconds.
ACTION_MODEL_RECOVERY_WAIT_S = 12.0
# Avoid unload/reload churn when the user chains actions. Under pressure the
# weight-owning writing-model child is reaped only after the whole engine has
# remained idle for this grace period.
ACTION_HIBERNATE_IDLE_S = 8.0

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


def _project_partial(
    raw_partial: str,
    raw_chunks: list[str],
    cleaned_chunks: list[str],
) -> str:
    """Replace only an exact, contiguous stable raw prefix with its cleanup.

    The unconfirmed Whisper tail remains visible and revisable. If the current
    hypothesis no longer begins with the committed segment text, keep it raw:
    publishing a guessed splice would be worse than a briefly unpolished one.
    """
    raw_partial = raw_partial.strip()
    count = min(len(raw_chunks), len(cleaned_chunks))
    if not raw_partial or count == 0:
        return raw_partial
    raw_prefix = " ".join(raw_chunks[:count]).strip()
    if raw_partial == raw_prefix:
        tail = ""
    elif raw_partial.startswith(raw_prefix + " "):
        tail = raw_partial[len(raw_prefix) + 1 :]
    else:
        return raw_partial
    return _join_chunks(cleaned_chunks[:count] + ([tail] if tail else []))


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
        self.last_raw_partial = ""
        self.cancelled = False
        self.samples = 0
        self.dropped = 0  # frames dropped because the queue was full
        self.started = time.perf_counter()
        # The connection that started this session. A displaced client's
        # cleanup must only abort a session it still owns (reconnect race).
        self.owner = owner
        # Crash-readable audio archive source. Appended before the bounded STT
        # queue so frames dropped for decode latency remain recoverable.
        self.spool: ActiveAudioSpool | None = None
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
        # Finalization runs beside the socket reader so an explicit cancel can
        # preempt cleanup before any final or audio archive becomes durable.
        self.finalize_cancel = threading.Event()
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
        # Reprocess runs off the dispatch loop. Crash recoveries queue behind
        # one another, while a live start waits only for the recovery already
        # holding the thread-affine STT backend and pauses the remaining queue.
        self._reprocessing = False
        self._reprocess_task: asyncio.Task[None] | None = None
        self._reprocess_recovery = False
        self._reprocess_audio: str | None = None
        self._recovery_queue: list[tuple[dict[str, Any], str]] = []
        self._recovery_paused = False
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
        # A terminal reply keeps the session identity until the app confirms
        # it has finished presenting/handling that result with action_end.
        # Dropping the id at failure time made the matching release unable to
        # clear this session's planner KV prefix.
        self._action_terminal = False
        # Post-action KV release and pressure hibernation run outside the
        # command dispatcher. A new foreground job cancels this task so stale
        # action_end traffic cannot reap the model underneath new work.
        self._action_cleanup_task: asyncio.Task[None] | None = None
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
        self._finalizing_session: Session | None = None
        self._finalize_task: asyncio.Task[None] | None = None
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
        # The writing worker exists before it is ready. Keep that cold-start
        # identity visible so durable meeting notes restored as soon as STT is
        # ready can wait for the same worker instead of failing in the brief
        # self.cleanup == nil publication window.
        self._cleanup_loading: CleanupProcess | None = None
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
        self._archive_tasks: set[asyncio.Task[Any]] = set()
        # A completed final keeps its active spool until Swift confirms the
        # History row is durable. A crash between those events is recoverable.
        self._final_archives: dict[str, asyncio.Task[bool]] = {}
        self._pending_final_sessions: set[str] = set()
        self._interrupted_task: asyncio.Task[None] | None = None
        self._recoverable_sessions: set[str] = set()
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

    def _begin_batch_job(self, *, lower_priority: bool) -> None:
        """Track work that is safe to put in Darwin background.

        User-visible meeting processing is deliberately *not* counted. Darwin
        background lowers CPU and disk priority enough to turn a one-minute
        Whisper chunk into tens of seconds under ordinary desktop load. Live
        dictation still preempts meeting work through the existing busy gates.
        """
        if lower_priority:
            self._batch_jobs += 1
            self._refresh_batch_priority()

    def _end_batch_job(self, *, lower_priority: bool) -> None:
        if lower_priority:
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

    def _restart_if_cleanup_unhealthy(
        self, *, include_recovering: bool = False
    ) -> bool:
        """Restart after cleanup wedges or misses a durable-job deadline.

        The caller must first send the user's raw fallback/result or leave its
        durable job active for reconnect recovery. Reusing the model from a
        replacement Python thread would violate MLX thread ownership while the
        old worker may still be inside native code, so a clean process restart
        is the only safe recovery boundary.
        """
        cleanup = self.cleanup
        cleanup_failed = cleanup is not None and (
            getattr(cleanup, "unhealthy", False)
            or (
                include_recovering
                and getattr(cleanup, "recovering", False)
            )
        )
        if not cleanup_failed:
            return False
        if self._cleanup_restart_scheduled:
            return True
        self._cleanup_restart_scheduled = True
        log.error("cleanup worker is unavailable — restarting engine after fallback")
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
        startup_cleanup: CleanupProcess | None = None
        if self.config.cleanup_enabled and not fake_stt_enabled():
            startup_cleanup = self._new_cleanup_process(self.config.cleanup_model)
            self._cleanup_loading = startup_cleanup
        self.stt_ready.set()
        # Enforce audio retention once at startup (deletes clips > 6 months and
        # trims the archive under its size cap).
        if self.config.save_audio:
            with contextlib.suppress(Exception):
                await asyncio.to_thread(
                    self.audio.prune, self.config.audio_retention_days, self.config.audio_max_bytes
                )
        if startup_cleanup is not None:
            engine = startup_cleanup
            close_task: asyncio.Task[None] | None = None

            async def close_startup_engine_once() -> None:
                nonlocal close_task
                if close_task is None:
                    close_task = asyncio.create_task(engine.aclose())
                # Keep the one close operation alive if serve() cancels this
                # loader while a superseded startup worker is being reaped.
                await asyncio.shield(close_task)

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
                    await close_startup_engine_once()
            except asyncio.CancelledError:
                if self.cleanup is engine:
                    self.cleanup = None
                await close_startup_engine_once()
                raise
            except Exception:
                log.exception("cleanup LLM failed to load; dictations will return raw text")
                if self.cleanup is engine:
                    self.cleanup = None
                with contextlib.suppress(Exception):
                    await close_startup_engine_once()
                with contextlib.suppress(Exception):
                    await self._set_loading(None)  # never leave a stale phase up
            finally:
                if self._cleanup_loading is engine:
                    self._cleanup_loading = None
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
            # Cancellation owns cleanup too: wait until _load_models has
            # reaped any cold-start sidecar before serve() can return. A bare
            # cancel left that child alive during app replacement.
            await asyncio.gather(watchdog, loader, return_exceptions=True)
            if self._miner_task is not None:
                self._miner_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await self._miner_task
            if self._action_cleanup_task is not None:
                self._action_cleanup_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await self._action_cleanup_task
            if self._finalize_task is not None:
                self._finalize_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await self._finalize_task
            self._server.close()
            with contextlib.suppress(asyncio.CancelledError):
                await self._server.wait_closed()
            with contextlib.suppress(FileNotFoundError):
                socket_path.unlink()
            # Normally loader completion leaves only self.cleanup. Keep the
            # identity-deduplicated sweep so an exceptional loader cannot
            # strand a separately published _cleanup_loading instance.
            cleanup_candidates = (self.cleanup, self._cleanup_loading)
            self.cleanup = None
            self._cleanup_loading = None
            closed_cleanup_ids: set[int] = set()
            for cleanup in cleanup_candidates:
                if cleanup is None or id(cleanup) in closed_cleanup_ids:
                    continue
                closed_cleanup_ids.add(id(cleanup))
                close_cleanup_async = getattr(cleanup, "aclose", None)
                if callable(close_cleanup_async):
                    await close_cleanup_async()
                else:
                    close_cleanup = getattr(cleanup, "close", None)
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
            pending = self.audio.pending_interrupted() if self.config.save_audio else ()
            if pending:
                self._interrupted_task = asyncio.create_task(
                    self._emit_interrupted(pending, gen, writer))
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

    async def _emit_interrupted(
        self, sessions: tuple[str, ...], gen: int, writer: asyncio.StreamWriter,
    ) -> None:
        recovered = await asyncio.to_thread(self.audio.recover_interrupted, sessions)
        if gen != self._client_gen or self.writer is not writer:
            return
        for item in recovered:
            self._recoverable_sessions.add(item.session)
            await self._send({
                "event": "interrupted_dictation",
                "session": item.session,
                "audio": item.audio,
                "duration_s": item.duration_s,
            })

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
            elif cmd == "interrupt":
                await self._cmd_interrupt(msg)
            elif cmd == "ack_interrupted":
                await self._cmd_ack_interrupted(msg)
            elif cmd == "ack_final":
                await self._cmd_ack_final(msg)
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
                requested = msg.get("id")
                if (isinstance(requested, str) and requested
                        and requested == self._action_id
                        and self._drop_action_session(requested)):
                    self._schedule_action_cleanup()
            elif cmd == "action_cancel":
                requested = msg.get("id")
                matches = (
                    self._action_session is None
                    or requested is None
                    or requested == self._action_id
                )
                if matches:
                    if self._planning:
                        self._action_cancel.set()
                    if self._drop_action_session(requested):
                        self._schedule_action_cleanup()
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
        if self._finalizing:
            await self._error(
                "busy finalizing the previous dictation", msg.get("session"))
            return
        if self._reprocessing and self._reprocess_recovery:
            self._recovery_paused = True
            task = self._reprocess_task
            if task is not None:
                await task
        self._cancel_action_cleanup()
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
            # A manual History reprocess has no recovery-priority contract. Its
            # refusal must still carry the attempted live session so Swift stops
            # the microphone instead of ignoring an unscoped error.
            await self._error(
                "busy reprocessing a clip — try again in a moment",
                msg.get("session"),
            )
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
            if self.config.save_audio:
                session.spool = self.audio.begin_active(session_id)
            # STT contextual biasing: bias whisper toward the user's vocabulary and
            # the NAMES on screen right now (person/file/channel/subject entities
            # only — nearby free text is cleanup-prompt material, not glossary).
            self.stt.initial_prompt = self._glossary(session.start_entities)
            # Whisper's extra preview decodes are opt-in because they consume
            # model time. Ordinary dictation keeps the existing final-first
            # latency; Stream Typing alone asks for progressive cursor text.
            if hasattr(self.stt, "preview_enabled"):
                self.stt.preview_enabled = context.get("stream_typing") is True
            await self._stt_call(self.stt.start_session)
            session.feeder = asyncio.create_task(self._feed_loop(session))
            self.session = session
        finally:
            self._starting = False
            if self.session is None:
                self._resume_cleanup_recovery()
                self._recovery_paused = False
                self._start_next_recovery()
        log.info(
            "session %s started (bundle_id=%s app=%s mode=%s)",
            session_id,
            context.get("bundle_id"),
            context.get("app_name"),
            context.get("mode"),
        )

    async def _emit_partial(self, session: Session, partial: str | None) -> None:
        """Send one current-session partial, shared by stream and preview lanes."""
        raw = (partial or "").strip()
        if raw:
            session.last_raw_partial = raw
        await self._emit_projected_partial(session)

    async def _emit_projected_partial(self, session: Session) -> None:
        """Publish cleaned stable chunks plus the latest unconfirmed ASR tail."""
        cleaned: list[str] = []
        for task in session.chunk_tasks:
            if (
                not task.done()
                or task.cancelled()
                or task.exception() is not None
                or not isinstance(task.result(), _ChunkResult)
            ):
                break
            cleaned.append(task.result().text)
        text = _project_partial(
            session.last_raw_partial,
            session.chunk_raws,
            cleaned,
        )
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
        # Archive before queueing for STT: a frame dropped below for latency
        # reasons must still make it into the saved or interrupted clip.
        if session.spool is not None and not session.spool.append(chunk):
            session.spool.close()
            session.spool = None
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
        self._begin_finalize(session, auto_stopped=True)

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

    async def _abort_session(
        self, why: str, disposition: SpoolDisposition = SpoolDisposition.preserve,
    ) -> None:
        session = self.session
        if session is None:
            return
        self.session = None
        session.cancelled = True
        spool = session.spool
        session.spool = None
        if spool is not None:
            if disposition is SpoolDisposition.discard:
                self.audio.discard_active(spool)
            else:
                spool.close()
        await self._cancel_chunk_tasks_and_wait(session)
        await self._drain_feeder(session)
        await self._drain_preview(session)
        await self._stt_call(self.stt.reset)
        if hasattr(self.stt, "preview_enabled"):
            self.stt.preview_enabled = False
        outcome = "discarded" if disposition is SpoolDisposition.discard else "interrupted"
        log.info("session %s %s (%s)", session.id, outcome, why)
        self._resume_cleanup_recovery()
        # The engine is idle again after an abort too — without this, a
        # cancelled dictation left mining dead until the next FINALIZED one
        # (review finding).
        self._recovery_paused = False
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
                finalizing = self._finalizing_session
                if finalizing is None:
                    await self._error("cancel: finalizing session is unavailable")
                    return
                await self._cancel_finalizing(finalizing)
                await self._send({"event": "cancelled", "session": finalizing.id})
                return
            requested = msg.get("session")
            if requested in self._pending_final_sessions:
                await self._discard_final_audio(str(requested))
                await self._send({"event": "cancelled", "session": requested})
                return
            await self._error("cancel: no active session", msg.get("session"))
            return
        self._cancelling_session = True
        try:
            await self._abort_session("cancel", SpoolDisposition.discard)
            await self._send({"event": "cancelled", "session": session.id})
        finally:
            self._cancelling_session = False
        # Chunk cleanup may have hit the hard watchdog before the user
        # cancelled. Confirm cancellation first, then restart instead of
        # leaving the poisoned single-worker executor for the next dictation.
        self._restart_if_cleanup_unhealthy()

    async def _cancel_finalizing(self, session: Session) -> None:
        """Cancel one exact finalization and delete every audio representation."""
        session.cancelled = True
        session.finalize_cancel.set()
        self._cancel_chunk_tasks(session)
        spool = session.spool
        session.spool = None
        if spool is not None:
            self.audio.discard_active(spool)

        await self._discard_final_audio(session.id)

    async def _discard_final_audio(self, session: str) -> None:
        """Delete a cancelled final's active spool and completed archive."""
        archive = self._final_archives.get(session)
        if archive is not None:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await archive
        await asyncio.to_thread(self.audio.ack_interrupted, session)
        archived = self.audio.path_for(self.audio.name_for(session))
        if archived is not None:
            with contextlib.suppress(OSError):
                archived.unlink()
        self._pending_final_sessions.discard(session)
        self._final_archives.pop(session, None)

    async def _cmd_interrupt(self, msg: dict[str, Any]) -> None:
        """Preserve drained audio for a graceful app termination, then ack."""
        session = self.session
        requested = msg.get("session")
        if session is None:
            await self._error("interrupt: no active session", requested)
            return
        if requested != session.id:
            await self._error("interrupt: session does not match active recording", requested)
            return
        await self._abort_session("app termination")
        await self._send({
            "event": "interrupted",
            "session": session.id,
            "duration_s": session.samples / SAMPLE_RATE,
        })

    async def _cmd_ack_interrupted(self, msg: dict[str, Any]) -> None:
        """Delete only recovery evidence this engine offered to the app."""
        session = msg.get("session")
        if not isinstance(session, str) or not session:
            await self._error("ack_interrupted: missing 'session'")
            return
        if session not in self._recoverable_sessions:
            await self._error("ack_interrupted: session is not recoverable", session)
            return
        removed = await asyncio.to_thread(self.audio.ack_interrupted, session)
        if not removed:
            await self._error("ack_interrupted: spool could not be removed", session)
            return
        self._recoverable_sessions.discard(session)
        self._pending_final_sessions.discard(session)
        self._final_archives.pop(session, None)
        await self._send({"event": "interrupted_ack", "session": session})

    async def _cmd_ack_final(self, msg: dict[str, Any]) -> None:
        """Delete a final's recovery spool only after History is durable."""
        session = msg.get("session")
        if not isinstance(session, str) or not session:
            await self._error("ack_final: missing 'session'")
            return
        if session not in self._pending_final_sessions:
            log.info("duplicate or stale final acknowledgement for %s", session)
            return
        archive = self._final_archives.get(session)
        if archive is None or not await archive:
            log.warning(
                "final archive not durable; retaining recovery spool for %s",
                session,
            )
            return
        if not await asyncio.to_thread(self.audio.ack_interrupted, session):
            log.warning("could not remove acknowledged final spool %s", session)
            return
        self._pending_final_sessions.discard(session)
        self._final_archives.pop(session, None)

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
        self._begin_finalize(session)

    def _begin_finalize(self, session: Session, auto_stopped: bool = False) -> None:
        """Publish finalizing state before returning control to the socket reader."""
        self._finalizing = True
        self._finalizing_session_id = session.id
        self._finalizing_session = session
        task = asyncio.create_task(self._finalize_session(session, auto_stopped))
        self._finalize_task = task

        def consume_result(done: asyncio.Task[None]) -> None:
            if self._finalize_task is done:
                self._finalize_task = None
            with contextlib.suppress(asyncio.CancelledError):
                done.exception()

        task.add_done_callback(consume_result)

    async def _finalize_session(self, session: Session, auto_stopped: bool = False) -> None:
        try:
            await self._finalize_session_inner(session, auto_stopped)
        finally:
            if session.spool is not None:
                if session.cancelled:
                    self.audio.discard_active(session.spool)
                else:
                    session.spool.close()
                session.spool = None
            if hasattr(self.stt, "preview_enabled"):
                self.stt.preview_enabled = False
            if self._finalizing_session is session:
                self._finalizing = False
                self._finalizing_session_id = None
                self._finalizing_session = None
            self._resume_cleanup_recovery()
            self._recovery_paused = False
            self._schedule_mining()
            if session.cancelled:
                self._restart_if_cleanup_unhealthy()

    async def _finalize_session_inner(self, session: Session, auto_stopped: bool = False) -> None:
        t_stop = time.perf_counter()
        await self._drain_feeder(session)
        await self._drain_preview(session)
        if session.cancelled:
            await self._stt_call(self.stt.reset)
            return
        try:
            raw = await self._stt_call(self.stt.finalize)
        except Exception as exc:
            log.exception("finalize failed")
            await self._cancel_chunk_tasks_and_wait(session)
            await self._stt_call(self.stt.reset)
            await self._error(f"transcription failed: {exc}", session.id)
            return
        if session.cancelled:
            return
        stt_ms = int((time.perf_counter() - t_stop) * 1000)
        await self._send({"event": "transcript", "session": session.id, "raw": raw, "ms": stt_ms})
        # A worker that failed during recording stays deferred until after
        # `final` is sent. Replacement warm-up takes seconds on real hardware;
        # waiting for it here created 7–10 s stop-to-final tails. The formatting
        # pipeline below already preserves every word through its deterministic
        # fallback when cleanup is unavailable.

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
                cancel_event=session.finalize_cancel,
            )
        text, mode_name, cleanup_ms, cleanup_applied, reason = result
        cleanup_wall_ms = int((time.perf_counter() - format_started) * 1000)
        if session.cancelled:
            return

        # Stage 3: archive the audio clip in the BACKGROUND — the clip name is
        # deterministic, so `final` never waits on FLAC encode + disk I/O
        # (review finding: archive writes sat on the stop→final path).
        audio_name = self._archive_audio_bg(session)
        if session.cancelled:
            await self._cancel_finalizing(session)
            return

        # Sample after formatting: a worker can be healthy after STT and then
        # hard-timeout in the authoritative whole-text or final-tail request.
        cleanup_recovery_pending = bool(
            self.cleanup is not None and not self.cleanup.loaded
        )
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
            "cleanup_recovery_pending": cleanup_recovery_pending,
            # Failed-worker finalization never waits for model warm-up. This
            # engine-wire/log metric is intentionally not persisted by Swift;
            # history continues to verify the contract through its residual.
            "cleanup_recovery_wait_ms": 0,
            "total_ms": total_ms,
        }
        if audio_name:
            final_evt["audio"] = audio_name
        if auto_stopped:
            final_evt["auto_stopped"] = True
        await self._send(final_evt)
        log.info(
            "session %s done: stt_ms=%d mode=%s reason=%s cleanup_ms=%d "
            "cleanup_wall_ms=%d cleanup_applied=%s recovery_pending=%s "
            "recovery_wait_ms=0 total_ms=%d samples=%d audio=%s",
            session.id,
            stt_ms,
            mode_name,
            reason,
            cleanup_ms,
            cleanup_wall_ms,
            cleanup_applied,
            cleanup_recovery_pending,
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
        task.add_done_callback(
            lambda completed: self._chunk_cleanup_completed(session, completed)
        )
        return task

    def _chunk_cleanup_completed(
        self,
        session: Session,
        task: asyncio.Task[_ChunkResult],
    ) -> None:
        if task.cancelled() or task.exception() is not None:
            return
        # The callback runs on the engine event loop. Re-projecting uses only
        # tasks still present in the session's contiguous chunk list, so a
        # cancelled task replaced by a cross-boundary correction cannot leak
        # stale text back into the draft.
        asyncio.create_task(self._emit_projected_partial(session))

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
        cleanup_ready = (
            await self._ensure_cleanup_loaded() if gate.use_llm else False)
        if gate.use_llm and self.cleanup is not None and cleanup_ready:
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
        self._start_next_recovery()
        if self._miner_task is not None and not self._miner_task.done():
            self._miner_task.cancel()
        self._miner_task = asyncio.create_task(self._mine_when_idle(delay))

    async def _cancel_idle_mining(self) -> None:
        """Preempt mining and wait until its Darwin demotion is restored.

        Cancelling the task without awaiting it leaves a small race where a
        user-visible meeting starts while the miner's `_batch_jobs` lease is
        still active. The meeting would then inherit background scheduling —
        exactly the latency regression this boundary is meant to prevent.
        """
        task = self._miner_task
        if task is None:
            return
        self._mine_cancel.set()
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        if self._miner_task is task:
            self._miner_task = None

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
                    or self._planning
                    or self._action_session is not None
                    or not (self.cleanup is not None and self.cleanup.loaded)
                    or not self.config.vocab_mining
                ):
                    return
                if self._miner is None:
                    self._miner = VocabMiner(self.config.home, self._mine_generate)
                # Idle mining is the definition of interruptible batch work —
                # run it demoted so an "idle" machine stays cool and quiet.
                self._begin_batch_job(lower_priority=True)
                try:
                    more = await self._miner.step()
                finally:
                    self._end_batch_job(lower_priority=True)
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
        archiving is off/empty). The active spool remains until the app acks
        its durable History row, so a failed write or app crash is recoverable."""
        spool = session.spool
        session.spool = None
        if spool is None:
            return None
        spool.close()

        async def _write() -> bool:
            recovered = await asyncio.to_thread(
                self.audio.recover_interrupted, (session.id,)
            )
            saved = any(item.session == session.id for item in recovered)
            if saved:
                # Prune is an O(clips) stat sweep — also off the hot path.
                await self._prune_audio_bg()
            return saved

        task = asyncio.create_task(_write())
        self._pending_final_sessions.add(session.id)
        self._final_archives[session.id] = task
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
                or self._meeting_notes_running or self._editing or self._planning
                or self._action_session is not None):
            await self._error(
                "set_model: busy (dictation, transcription, edit, or action in progress)")
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
        # Idle vocab mining shares the single-thread cleanup executor and can
        # hold it for seconds. Without preempting it (as _cmd_start does), an
        # edit queues behind a mining step, blows its own from-submission
        # deadline, and would falsely mark the engine unhealthy → needless
        # restart. Cancel mining now; the miner reschedules after the edit.
        if self._miner_task is not None:
            self._miner_task.cancel()
        self._mine_cancel.set()
        self._cancel_action_cleanup()
        self._editing = True
        self._edit_cancel.clear()
        asyncio.create_task(self._run_edit_text(dict(msg), text, instruction))

    async def _run_edit_text(self, msg: dict[str, Any], text: str, instruction: str) -> None:
        try:
            # A pressure-hibernated model may take seconds to restore. Keep
            # that wait in this worker task so ping/edit_cancel stay live on
            # the socket dispatcher, and make the load itself cancellable.
            if self.cleanup is None or not await self._ensure_cleanup_loaded(
                    self._edit_cancel):
                code = "cancelled" if self._edit_cancel.is_set() else "cleanup_unavailable"
                error = ("edit: cancelled" if code == "cancelled"
                         else "edit: writing model unavailable")
                await self._send({
                    "event": "edit_failed", "id": msg.get("id"),
                    "code": code, "error": error,
                })
                return
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

    def _drop_action_session(self, requested: Any) -> bool:
        """Forget the live action session (loop finished, cancelled, or the
        app gave up). A mismatched id is ignored so a stale `action_end` from
        a previous action cannot kill its successor's session. The return value
        also prevents that stale request from clearing the successor's KV
        prefix."""
        if self._action_session is None:
            return True
        if requested is not None and requested != self._action_id:
            return False
        self._action_session = None
        self._action_id = None
        self._action_terminal = False
        return True

    def _mark_action_terminal(self, requested: Any) -> bool:
        """Retain an ended loop until its exact owner sends action_end."""
        if self._action_session is None or requested != self._action_id:
            return False
        self._action_terminal = True
        return True

    async def _release_action_memory(self) -> None:
        """Best-effort removal of session-only planner KV state.

        The cleanup worker's model weights and dictation prefix remain warm.
        A busy worker means cancellation is still unwinding; the app always
        follows with `action_end`, which retries after the loop has stopped.
        """
        release = getattr(self.cleanup, "release_action_memory", None)
        if not callable(release):
            return
        try:
            await release()
        except Exception:  # noqa: BLE001 — hygiene must never fail a task
            log.debug("action memory release failed", exc_info=True)

    def _cancel_action_cleanup(self) -> None:
        task = self._action_cleanup_task
        self._action_cleanup_task = None
        if (task is not None and task is not asyncio.current_task()
                and not task.done()):
            task.cancel()

    def _cleanup_model_is_idle(self) -> bool:
        return not (
            self.shutdown.is_set()
            or self.session is not None
            or self._starting
            or self._finalizing
            or self._reprocessing
            or self._transcribing
            or self._meeting_notes_running
            or self._editing
            or self._planning
            or self._action_session is not None
        )

    def _schedule_action_cleanup(self) -> None:
        """Release Action KV now, then hibernate only after verified idle.

        The task is deliberately detached from command dispatch. Both worker
        methods are best-effort, and every new foreground cleanup-model user
        cancels the task before starting.
        """
        self._cancel_action_cleanup()

        async def clean_when_idle() -> None:
            try:
                await self._release_action_memory()
                await asyncio.sleep(ACTION_HIBERNATE_IDLE_S)
                if self._cleanup_model_is_idle():
                    await self._hibernate_cleanup_if_pressured()
            except asyncio.CancelledError:
                raise
            finally:
                if self._action_cleanup_task is asyncio.current_task():
                    self._action_cleanup_task = None

        self._action_cleanup_task = asyncio.create_task(clean_when_idle())

    async def _ensure_cleanup_loaded(
        self,
        cancel_event: threading.Event | None = None,
    ) -> bool:
        self._cancel_action_cleanup()
        cleanup = self.cleanup
        if cleanup is None:
            return False
        if getattr(cleanup, "loaded", True):
            return True
        ensure = getattr(cleanup, "ensure_loaded", None)
        if not callable(ensure):
            return False
        try:
            return bool(await ensure(cancel_event=cancel_event))
        except Exception:  # noqa: BLE001 — callers retain their normal fallback
            log.exception("writing model failed to leave hibernation")
            return False

    async def _hibernate_cleanup_if_pressured(self) -> None:
        cleanup = self.cleanup
        hibernate = getattr(cleanup, "hibernate", None)
        if not callable(hibernate):
            return
        pressure = await asyncio.to_thread(_memory_pressure_level)
        if pressure < 2:
            return
        try:
            if await hibernate():
                log.info(
                    "writing model hibernated after action memory_pressure=%d",
                    pressure,
                )
        except Exception:  # noqa: BLE001 — memory hygiene cannot fail the action
            log.debug("writing model hibernation skipped", exc_info=True)

    async def _action_busy_reason(self) -> tuple[str, str] | None:
        if self.session is not None or self._starting or self._finalizing:
            return ("action: busy (dictation in progress)", "busy")
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing or self._planning):
            return ("action: busy (another job in progress)", "busy")
        if self.cleanup is None:
            return ("action: writing model unavailable", "cleanup_unavailable")
        return None

    async def _wait_for_action_model_recovery(self) -> bool:
        """Wait once for CleanupProcess's bounded child replacement.

        Model infrastructure failure is not a bad action plan. Keeping this
        wait inside the current planning turn prevents the app from issuing a
        burst of fresh observations that exhausts the session's rejection cap
        while the same worker is still warming.
        """
        deadline = (
            asyncio.get_running_loop().time() + ACTION_MODEL_RECOVERY_WAIT_S)
        while not self._action_cancel.is_set() and not self.shutdown.is_set():
            cleanup = self.cleanup
            if cleanup is None:
                return False
            if getattr(cleanup, "loaded", True):
                return True
            if getattr(cleanup, "unhealthy", False):
                return False
            if asyncio.get_running_loop().time() >= deadline:
                return False
            await asyncio.sleep(0.05)
        return False

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
        self._cancel_action_cleanup()
        # A new action unconditionally replaces any live session: the only way
        # a session is still here is that the app abandoned it (crash, kill
        # mid-loop), and wedging Action Mode until an engine restart would be
        # a worse failure than dropping a loop nobody is driving.
        if self._action_session is not None:
            log.info("action_start: replacing an abandoned session %s", self._action_id)
            self._drop_action_session(self._action_id)
            await self._release_action_memory()
        context = actions.ActionContext.from_dict(msg.get("context"))
        context.transcript = transcript
        session = actions.ActionSession(
            transcript, context, require_target_verifier=True)
        self._action_session = session
        self._action_id = msg.get("id")
        self._action_terminal = False
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
        if self._action_terminal or session.finished:
            await fail("action: session already finished", "no_session")
            return
        if session.turns_used >= actions.MAX_TURNS:
            self._mark_action_terminal(self._action_id)
            await fail(f"action: ran out of turns (max {actions.MAX_TURNS})",
                       "turn_limit")
            return
        self._cancel_action_cleanup()
        observation = msg.get("observation")
        if not isinstance(observation, dict):
            await fail("action: missing 'observation'", "invalid_arguments")
            return
        # The app may spend tens of seconds carrying out a batch. Prevent the
        # idle miner from owning the one cleanup worker when the next
        # interactive planning turn arrives.
        if self._miner_task is not None:
            self._miner_task.cancel()
        self._mine_cancel.set()
        self._planning = True
        self._action_cancel.clear()
        asyncio.create_task(self._run_action_turn(
            dict(msg), session, session.observation_message(observation)))

    async def _run_action_turn(self, msg: dict[str, Any],
                               session: actions.ActionSession,
                               message: str) -> None:
        """One model call → one validated turn. Shared by start and observe;
        `message` is the user-role text (command or observation)."""
        planning_released = False
        recovery_wait_attempted = False

        async def send_after_planning(payload: dict[str, Any]) -> None:
            """Publish only after a next turn is allowed through the busy gate.

            The socket write can yield. Marking planning idle first prevents a
            fast action_observe from being rejected, while the local flag keeps
            this turn's finally block from clearing a successor's planning bit.
            """
            nonlocal planning_released
            self._planning = False
            planning_released = True
            await self._send(payload)

        async def wait_for_model_recovery_once() -> bool:
            nonlocal recovery_wait_attempted
            if recovery_wait_attempted:
                return False
            recovery_wait_attempted = True
            return await self._wait_for_action_model_recovery()

        try:
            t0 = time.perf_counter()
            turn: dict[str, Any] | None = None
            last_error = ""
            model_unavailable_error = ""
            had_plan_error = False
            if (not self._action_cancel.is_set()
                    and actions.needs_app_presentation(session)):
                parsed = {"sends": False, "steps": [], "done": True}
                turn = session.accept_reply(json.dumps(
                    parsed, ensure_ascii=False, separators=(",", ":")))
            # Deliberate pressure hibernation is restored inside this task, not
            # in the socket-command dispatcher. Model loading takes seconds;
            # ping/cancel/status frames must remain responsive throughout.
            if turn is None and getattr(self.cleanup, "hibernated", False):
                loaded = await self._ensure_cleanup_loaded(self._action_cancel)
                if self._action_cancel.is_set():
                    self._drop_action_session(msg.get("id"))
                    self._schedule_action_cleanup()
                    await send_after_planning({
                        "event": "action_failed", "id": msg.get("id"),
                        "code": "cancelled", "error": "action: cancelled",
                    })
                    return
                if not loaded:
                    self._mark_action_terminal(msg.get("id"))
                    await send_after_planning({
                        "event": "action_failed", "id": msg.get("id"),
                        "code": "planner_unavailable",
                        "error": "the local action model could not leave hibernation",
                    })
                    return
            if self._action_cancel.is_set():
                self._drop_action_session(msg.get("id"))
                self._schedule_action_cleanup()
                await send_after_planning({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "cancelled", "error": "action: cancelled",
                })
                return
            # An accepted exact press on a repeated collection member is
            # already proven navigation by deterministic capability checks.
            # On its fresh post-click observation, ask the independent
            # completion model directly whether unique active content proves
            # the spoken goal. A refusal or malformed verdict is only an
            # optimization miss: fall back to the normal controller below.
            direct_goal_check = session.direct_goal_check_pending
            session.direct_goal_check_pending = False
            if (turn is None and direct_goal_check
                    and actions.goal_snapshot_is_native(
                        session.current_ui_snapshot)):
                verifier_prompt = actions.build_goal_verifier_prompt(
                    session.current_ui_snapshot)
                verifier_message = actions.goal_verifier_message(
                    session.transcript, session.goal)
                completion = await self.cleanup.cleanup(
                    verifier_message, verifier_prompt,
                    timeout_ms=actions.VERIFIER_TIMEOUT_MS,
                    check_ratio=False,
                    cancel_event=self._action_cancel,
                    max_tokens=180,
                    # This tree changes after every UI action, so retaining its
                    # verifier prefix only pins a large stale KV snapshot and
                    # evicts the ordinary dictation prefix. Generate it once
                    # and let the working cache die with the call.
                    cache_scope=None,
                    max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                )
                if completion.reason == "context_limit":
                    raise _ActionContextTooLarge(
                        "screen context needs "
                        f"{completion.input_tokens} tokens; the safe local limit is "
                        f"{actions.ACTION_MAX_INPUT_TOKENS}")
                if self._action_cancel.is_set():
                    self._drop_action_session(msg.get("id"))
                    self._schedule_action_cleanup()
                    await send_after_planning({
                        "event": "action_failed", "id": msg.get("id"),
                        "code": "cancelled", "error": "action: cancelled",
                    })
                    return
                if completion.applied:
                    try:
                        goal_verdict = actions.parse_goal_verdict(
                            completion.text, session.current_ui_snapshot,
                            session.transcript)
                        if goal_verdict.get("safe") is True:
                            token = uuid.uuid4().hex
                            session.state.allowed_ui_attestation = token
                            parsed = actions.attach_verified_goal(
                                {"done": True}, goal_verdict,
                                session.current_ui_snapshot, token,
                                sends=bool(session.sends))
                            turn = session.accept_reply(json.dumps(
                                parsed, ensure_ascii=False,
                                separators=(",", ":")))
                        else:
                            log.info(
                                "direct action completion check fell back: %s",
                                goal_verdict.get("reason")
                                or "current UI did not prove completion")
                    except actions.PlanError as exc:
                        session.state.allowed_ui_attestation = None
                        log.info(
                            "direct action completion check fell back: %s", exc)
                else:
                    log.info(
                        "direct action completion check unavailable; "
                        "falling back to controller: %s",
                        completion.reason or "no output")
                    await wait_for_model_recovery_once()

            controller_attempts = range(2) if turn is None else range(0)
            for attempt in controller_attempts:
                authoritative_ui_refusal = False
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
                    cache_scope="action",
                    max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                )
                if self._action_cancel.is_set():
                    self._drop_action_session(msg.get("id"))
                    # action_cancel/action_end may have arrived while the
                    # cleanup process lock was held. It is free after the await
                    # above, so this is the authoritative retry.
                    self._schedule_action_cleanup()
                    await send_after_planning({
                        "event": "action_failed", "id": msg.get("id"),
                        "code": "cancelled", "error": "action: cancelled",
                    })
                    return
                if not result.applied:
                    if result.reason == "context_limit":
                        raise _ActionContextTooLarge(
                            "screen context needs "
                            f"{result.input_tokens} tokens; the safe local limit is "
                            f"{actions.ACTION_MAX_INPUT_TOKENS}")
                    last_error = f"model unavailable ({result.reason or 'no output'})"
                    model_unavailable_error = last_error
                    if attempt == 0:
                        await wait_for_model_recovery_once()
                    continue
                try:
                    reply_text = result.text
                    parsed = actions.parse_turn(reply_text)
                    review_refusal_reason = ""
                    if actions.turn_requires_ui_action_review(parsed, session):
                        review_prompt = actions.build_ui_action_review_prompt(
                            session.current_ui_snapshot)
                        review_message = actions.ui_action_review_message(
                            session.transcript,
                            str(parsed.get("goal") or session.goal),
                            parsed.get("steps") or [])
                        review_result = await self.cleanup.cleanup(
                            review_message, review_prompt,
                            timeout_ms=actions.VERIFIER_TIMEOUT_MS,
                            check_ratio=False,
                            cancel_event=self._action_cancel,
                            max_tokens=180,
                            cache_scope=None,
                            max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                        )
                        if self._action_cancel.is_set():
                            self._drop_action_session(msg.get("id"))
                            self._schedule_action_cleanup()
                            await send_after_planning({
                                "event": "action_failed", "id": msg.get("id"),
                                "code": "cancelled", "error": "action: cancelled",
                            })
                            return
                        if not review_result.applied:
                            if review_result.reason == "context_limit":
                                raise _ActionContextTooLarge(
                                    "screen context needs "
                                    f"{review_result.input_tokens} tokens; "
                                    "the safe local limit is "
                                    f"{actions.ACTION_MAX_INPUT_TOKENS}")
                            raise _ActionModelUnavailable(
                                "UI action reviewer unavailable ("
                                + str(review_result.reason or "no output") + ")")
                        review = actions.parse_ui_action_review(
                            review_result.text, session.current_ui_snapshot,
                            session.transcript)
                        if review.get("goal_met") is True:
                            declared_sends = session.sends
                            if declared_sends is None:
                                declared_sends = parsed.get("sends")
                            token = uuid.uuid4().hex
                            session.state.allowed_ui_attestation = token
                            parsed = actions.attach_verified_goal(
                                parsed, review, session.current_ui_snapshot, token,
                                sends=bool(declared_sends))
                            reply_text = json.dumps(
                                parsed, ensure_ascii=False, separators=(",", ":"))
                        elif review.get("safe") is not True:
                            declared_sends = session.sends
                            if declared_sends is None:
                                declared_sends = parsed.get("sends")
                            reason = str(review.get("reason") or
                                         "the selected control is not navigation")
                            if declared_sends is False and session.turns_used > 0:
                                # Do not execute the refused press. Give the
                                # independent completion verifier the current
                                # tree; it can replace the press only with
                                # exact, runtime-rechecked proof that the
                                # command is already complete.
                                review_refusal_reason = reason
                                parsed = {"done": True}
                                reply_text = '{"done":true}'
                            else:
                                raise actions.PlanError(
                                    "UI action reviewer refused: " + reason)
                    if (review_refusal_reason
                            or actions.turn_requires_goal_verifier(parsed, session)):
                        if not session.current_ui_snapshot.get("complete"):
                            authoritative_ui_refusal = bool(
                                review_refusal_reason)
                            raise actions.PlanError(
                                "goal verifier: structured UI is incomplete")
                        if not actions.goal_snapshot_is_native(
                                session.current_ui_snapshot):
                            authoritative_ui_refusal = bool(
                                review_refusal_reason)
                            raise actions.PlanError(
                                "goal verifier: native UI is required")
                        verifier_prompt = actions.build_goal_verifier_prompt(
                            session.current_ui_snapshot)
                        verifier_message = actions.goal_verifier_message(
                            session.transcript,
                            str(parsed.get("goal") or session.goal))
                        completion = await self.cleanup.cleanup(
                            verifier_message, verifier_prompt,
                            timeout_ms=actions.VERIFIER_TIMEOUT_MS,
                            check_ratio=False,
                            cancel_event=self._action_cancel,
                            max_tokens=180,
                            cache_scope=None,
                            max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                        )
                        if self._action_cancel.is_set():
                            self._drop_action_session(msg.get("id"))
                            self._schedule_action_cleanup()
                            await send_after_planning({
                                "event": "action_failed", "id": msg.get("id"),
                                "code": "cancelled", "error": "action: cancelled",
                            })
                            return
                        if not completion.applied:
                            if completion.reason == "context_limit":
                                raise _ActionContextTooLarge(
                                    "screen context needs "
                                    f"{completion.input_tokens} tokens; "
                                    "the safe local limit is "
                                    f"{actions.ACTION_MAX_INPUT_TOKENS}")
                            raise _ActionModelUnavailable(
                                "goal verifier unavailable ("
                                + str(completion.reason or "no output") + ")")
                        goal_verdict = actions.parse_goal_verdict(
                            completion.text, session.current_ui_snapshot,
                            session.transcript)
                        if goal_verdict.get("safe") is True:
                            declared_sends = session.sends
                            if declared_sends is None:
                                declared_sends = parsed.get("sends")
                            token = uuid.uuid4().hex
                            session.state.allowed_ui_attestation = token
                            parsed = actions.attach_verified_goal(
                                parsed, goal_verdict,
                                session.current_ui_snapshot, token,
                                sends=bool(declared_sends))
                            reply_text = json.dumps(
                                parsed, ensure_ascii=False, separators=(",", ":"))
                        elif review_refusal_reason:
                            raise actions.PlanError(
                                "UI action reviewer refused: "
                                + review_refusal_reason)
                        else:
                            reason = str(
                                goal_verdict.get("reason")
                                or "current UI did not prove completion")
                            raise actions.PlanError(
                                "goal verifier refused: " + reason)
                    if actions.turn_requires_target_verifier(parsed, session):
                        authoritative_ui_refusal = True
                        verifier_prompt = actions.build_target_verifier_prompt(
                            session.current_ui_snapshot)
                        verifier_message = actions.target_verifier_message(
                            session.transcript,
                            str(parsed.get("goal") or session.goal),
                            parsed.get("steps") or [])
                        verdict = await self.cleanup.cleanup(
                            verifier_message, verifier_prompt,
                            timeout_ms=actions.VERIFIER_TIMEOUT_MS,
                            check_ratio=False,
                            cancel_event=self._action_cancel,
                            max_tokens=180,
                            cache_scope=None,
                            max_input_tokens=actions.ACTION_MAX_INPUT_TOKENS,
                        )
                        if self._action_cancel.is_set():
                            self._drop_action_session(msg.get("id"))
                            self._schedule_action_cleanup()
                            await send_after_planning({
                                "event": "action_failed", "id": msg.get("id"),
                                "code": "cancelled", "error": "action: cancelled",
                            })
                            return
                        if not verdict.applied:
                            if verdict.reason == "context_limit":
                                raise _ActionContextTooLarge(
                                    "screen context needs "
                                    f"{verdict.input_tokens} tokens; "
                                    "the safe local limit is "
                                    f"{actions.ACTION_MAX_INPUT_TOKENS}")
                            raise _ActionModelUnavailable(
                                "target verifier unavailable ("
                                + str(verdict.reason or "no output") + ")")
                        evidence = actions.parse_target_verdict(
                            verdict.text, session.current_ui_snapshot,
                            session.transcript)
                        token = uuid.uuid4().hex
                        session.state.allowed_ui_attestation = token
                        parsed = actions.attach_target_attestation(
                            parsed, evidence, token)
                        reply_text = json.dumps(
                            parsed, ensure_ascii=False, separators=(",", ":"))
                    turn = session.accept_reply(reply_text)
                    break
                except _ActionModelUnavailable as exc:
                    session.state.allowed_ui_attestation = None
                    session.state.allow_ui_presentation = False
                    last_error = str(exc)
                    model_unavailable_error = last_error
                    if attempt == 0:
                        await wait_for_model_recovery_once()
                except actions.PlanError as exc:
                    session.state.allowed_ui_attestation = None
                    session.state.allow_ui_presentation = False
                    had_plan_error = True
                    last_error = str(exc)
                    repeats = session.note_rejected_reply(result.text)
                    if repeats >= 2:
                        last_error = (
                            f"{exc}; model repeated an unchanged rejected plan; "
                            "inspect the fresh UI and choose a different action")
                    # The reply excerpt is the difference between diagnosing a
                    # systematic model spelling and guessing at it. Local log,
                    # same sensitivity as the goal lines already logged.
                    log.warning("action turn attempt %d rejected: %s — reply: %s",
                                attempt + 1, exc,
                                " ".join(result.text.split())[:220])
                    if authoritative_ui_refusal or repeats >= 2:
                        break

            ms = int((time.perf_counter() - t0) * 1000)
            if turn is None:
                if model_unavailable_error and not had_plan_error:
                    self._mark_action_terminal(msg.get("id"))
                    await send_after_planning({
                        "event": "action_failed", "id": msg.get("id"),
                        "code": "planner_unavailable",
                        "error": "the local action model did not recover: "
                                 + model_unavailable_error,
                        "ms": ms,
                    })
                    return
                # The session survives a rejected turn: no turn was consumed
                # (accept_reply raises before counting), and the app may ask
                # again with a fresh observation — which beats the inline
                # repair when the model is stuck on a shape. Bounded by its
                # own cap so a stuck model cannot be asked forever.
                session.rejections += 1
                if session.rejections >= 2:
                    self._mark_action_terminal(msg.get("id"))
                await send_after_planning({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "plan_invalid",
                    "error": f"could not plan that action: {last_error}",
                    "ms": ms,
                })
                return
            if "fail" in turn:
                self._mark_action_terminal(msg.get("id"))
                await send_after_planning({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "unsupported", "error": turn["fail"], "ms": ms,
                })
                return
            evt: dict[str, Any] = {
                "event": "action_turn", "turn": session.turns_used,
                "sends": bool(session.sends), "goal": session.goal,
                "steps": turn["steps"], "done": turn["done"], "ms": ms,
            }
            if msg.get("id") is not None:
                evt["id"] = msg.get("id")
            self._restart_if_cleanup_unhealthy()
            log.info("action turn %d: %d steps sends=%s done=%s ms=%d",
                     session.turns_used, len(turn["steps"]), session.sends,
                     turn["done"], ms)
            await send_after_planning(evt)
        except _ActionContextTooLarge as exc:
            self._mark_action_terminal(msg.get("id"))
            self._schedule_action_cleanup()
            if not planning_released:
                await send_after_planning({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "context_limit", "error": str(exc),
                })
        except Exception as exc:  # noqa: BLE001 — the app is waiting on an answer
            log.exception("action turn failed")
            self._mark_action_terminal(msg.get("id"))
            if not planning_released:
                await send_after_planning({
                    "event": "action_failed", "id": msg.get("id"),
                    "code": "failed", "error": f"action planning failed: {exc}",
                })
        finally:
            if not planning_released:
                self._planning = False
            self._schedule_mining()

    async def _cmd_reprocess(self, msg: dict[str, Any]) -> None:
        """Re-transcribe a saved audio clip, optionally with a different model,
        mode, or language. Validates synchronously, then runs the (possibly
        slow) transcription off the dispatch loop so live control frames stay
        responsive. Emits a `reprocessed` event echoing the caller's id."""
        name = msg.get("audio")
        if not name or not isinstance(name, str):
            await self._reprocess_failed(
                msg, "reprocess: missing 'audio'", "invalid_arguments")
            return
        recovery = msg.get("recovery") is True
        if recovery and (
            self.session is not None
            or self._starting
            or self._finalizing
            or self._reprocessing
            or self._transcribing
            or self._meeting_notes_running
            or self._editing
        ):
            self._enqueue_recovery(msg, name)
            return
        if self.session is not None:
            await self._reprocess_failed(
                msg, "reprocess: busy (dictation in progress)", "busy")
            return
        if (self._reprocessing or self._transcribing
                or self._meeting_notes_running or self._editing):
            await self._reprocess_failed(
                msg, "reprocess: busy (another job in progress)", "busy")
            return
        self._start_reprocess(msg, name, recovery=recovery)

    def _enqueue_recovery(self, msg: dict[str, Any], name: str) -> None:
        """Retain one queued request per crash spool until its History result."""
        if self._reprocess_recovery and self._reprocess_audio == name:
            return
        if any(audio == name for _queued, audio in self._recovery_queue):
            return
        self._recovery_queue.append((dict(msg), name))

    def _start_reprocess(
        self, msg: dict[str, Any], name: str, *, recovery: bool,
    ) -> None:
        self._reprocessing = True
        self._reprocess_recovery = recovery
        self._reprocess_audio = name
        task = asyncio.create_task(self._run_reprocess(dict(msg), name))
        self._reprocess_task = task

    def _start_next_recovery(self) -> None:
        if (
            self._recovery_paused
            or self._reprocessing
            or self.session is not None
            or self._starting
            or self._finalizing
            or self._transcribing
            or self._meeting_notes_running
            or self._editing
            or not self._recovery_queue
        ):
            return
        msg, name = self._recovery_queue.pop(0)
        self._start_reprocess(msg, name, recovery=True)

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
            current = asyncio.current_task()
            if self._reprocess_task is current:
                self._reprocess_task = None
            self._reprocessing = False
            self._reprocess_recovery = False
            self._reprocess_audio = None
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
        await self._cancel_idle_mining()
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
            duration_s = len(pcm) / SAMPLE_RATE
            if duration_s > _DIARIZATION_MAX_TRACK_S:
                log.info(
                    "diarization: %s skipping CPU plan for %.0fs long track",
                    meeting_id,
                    duration_s,
                )
                return None
            active_fraction = await asyncio.to_thread(
                speech_window_fraction, pcm
            )
            if (
                active_fraction == 0
                or active_fraction >= _DIARIZATION_DENSE_ACTIVITY_FRACTION
            ):
                log.info(
                    "diarization: %s skipping CPU plan for %.0f%% active track",
                    meeting_id,
                    active_fraction * 100,
                )
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
            if self._meeting_transcribe_cancel:
                return None
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
        track_started = time.perf_counter()

        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "meeting_transcribe_failed", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "code": code, "error": error,
            })

        # The user explicitly asked for notes and is waiting for the result.
        # Foreground dictation still preempts between chunks, but Darwin
        # background priority made this 2.5-6.5x slower in an exact replay.
        self._begin_batch_job(lower_priority=False)
        try:
            try:
                load_started = time.perf_counter()
                pcm = await asyncio.to_thread(
                    load_meeting_media, path,
                    meeting_root=velora_home() / "meetings",
                )
                load_ms = int((time.perf_counter() - load_started) * 1000)
            except ValueError as exc:
                log.warning(
                    "meeting transcription rejected %s/%s: %s",
                    meeting_id, speaker, exc,
                )
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
            plan_started = time.perf_counter()
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
            plan_ms = int((time.perf_counter() - plan_started) * 1000)
            await self._send({
                "event": "meeting_transcribe_started", "id": job_id,
                "meeting_id": meeting_id, "speaker": speaker,
                "duration_s": round(duration_s, 1), "chunks": len(spans),
                "start_chunk": min(start_chunk, len(spans)),
                "restarted": restarted,
            })
            decode_ms = 0
            nonempty_chunks = 0
            processed_chunks = 0
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
                decode_started = time.perf_counter()
                text = await self._stt_call(
                    transcribe_clip, self.stt, pcm[sample_a:sample_b])
                decode_ms += int((time.perf_counter() - decode_started) * 1000)
                cleaned_text = (text or "").strip()
                nonempty_chunks += bool(cleaned_text)
                processed_chunks += 1
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
                    "text": cleaned_text,
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
            log.info(
                "meeting transcription done %s/%s: %.0fs audio, "
                "%d/%d chunks processed this attempt, %d nonempty this attempt, "
                "load=%dms plan=%dms decode=%dms wall=%dms",
                meeting_id, speaker, duration_s, processed_chunks, len(spans),
                nonempty_chunks, load_ms, plan_ms, decode_ms,
                int((time.perf_counter() - track_started) * 1000),
            )
        except Exception as exc:  # noqa: BLE001
            log.exception("meeting transcription failed")
            await fail(f"transcription failed: {exc}")
        finally:
            self._transcribing = False
            self._meeting_transcribe_cancel = False
            self._meeting_transcribe_job_id = None
            self._end_batch_job(lower_priority=False)
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
        await self._cancel_idle_mining()
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
            "strings), and action_items (array of strings). Use an empty array when "
            "the transcript contains no explicit decision or action item."
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
        map_prompt = (
            f"{guidance} Keep this partial summary to 1-2 concise sentences and each "
            f"array to at most 4 concise items.\n\n{schema_clause}"
        )
        reduce_prompt = (
            "Merge these partial meeting notes without inventing facts or duplicates. "
            + (
                f"Follow these notes instructions where they apply: {custom_guidance}\n\n"
                if custom_guidance
                else ""
            )
            + "Keep the summary to 3-6 concise sentences and each array to at most 8 "
            + f"concise items. {schema_clause}"
        )

        async def fail(error: str, code: str = "failed") -> None:
            await self._send({
                "event": "meeting_notes_failed", "id": job_id,
                "meeting_id": meeting_id, "code": code, "error": error,
            })

        async def generate(
            user_text: str, prompt: str, max_tokens: int
        ) -> tuple[dict[str, Any] | None, str | None, bool]:
            while not self._meeting_notes_cancel:
                if self.shutdown.is_set():
                    return None, "engine shutting down", False
                while self.session is not None or self._starting or self._finalizing:
                    await asyncio.sleep(0.25)
                    if self._meeting_notes_cancel or self.shutdown.is_set():
                        return None, "cancelled", False
                self._meeting_notes_preempt.clear()
                # Dictation just released the machine (wait loop above), or a
                # cleanup child respawned — recompute who gets demoted.
                self._refresh_batch_priority()
                model_ready_deadline = (
                    asyncio.get_running_loop().time()
                    + MEETING_NOTES_MODEL_READY_WAIT_S
                )
                cleanup = self.cleanup or self._cleanup_loading
                if cleanup is None:
                    return None, "the local notes model is unavailable", False
                if cleanup is self.cleanup:
                    await self._ensure_cleanup_loaded()
                while not cleanup.loaded:
                    if (
                        self._meeting_notes_cancel
                        or self.shutdown.is_set()
                    ):
                        return None, "cancelled", False
                    if cleanup.unhealthy or (
                        asyncio.get_running_loop().time() >= model_ready_deadline
                    ):
                        return None, "the local notes model is unavailable", False
                    if self.session is not None or self._starting or self._finalizing:
                        break
                    await asyncio.sleep(0.1)
                    replacement = self.cleanup or self._cleanup_loading
                    if replacement is None:
                        return None, "the local notes model is unavailable", False
                    cleanup = replacement
                if self.session is not None or self._starting or self._finalizing:
                    continue
                result = await cleanup.cleanup(
                    user_text, prompt,
                    timeout_ms=MEETING_NOTES_TIMEOUT_MS,
                    max_tokens=max_tokens,
                    check_ratio=False,
                    cancel_event=self._meeting_notes_preempt,
                )
                if self._meeting_notes_cancel or self.shutdown.is_set():
                    return None, "cancelled", False
                if self._meeting_notes_preempt.is_set():
                    # A dictation interrupted generation. Retry this exact map
                    # chunk once the foreground session has finished.
                    await asyncio.sleep(0.25)
                    continue
                if not result.applied:
                    reason = str(getattr(result, "reason", None) or "no output")
                    retryable = reason in {
                        "length", "timeout", "timeout_hard", "timeout_queue",
                    }
                    return (
                        None,
                        f"local notes generation failed ({reason})",
                        retryable,
                    )
                parsed = parse_notes_json(result.text)
                if parsed is None:
                    return (
                        None,
                        "the local notes model returned malformed notes",
                        True,
                    )
                return parsed, None, False
            return None, "cancelled", False

        self._begin_batch_job(lower_priority=False)
        try:
            chunks = chunk_transcript(
                transcript, max_chars=MEETING_NOTES_CHUNK_CHARS)
            partials: list[dict[str, Any]] = []
            for index, chunk in enumerate(chunks):
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_notes_cancel:
                    await fail("cancelled", "cancelled")
                    return
                notes, generation_error, retryable = await generate(
                    chunk, map_prompt, MEETING_NOTES_MAP_MAX_TOKENS)
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_notes_cancel:
                    await fail("cancelled", "cancelled")
                    return
                recovered: list[dict[str, Any]] = []
                if notes is None and retryable:
                    retry_chunks = chunk_transcript(
                        chunk, max_chars=MEETING_NOTES_RETRY_CHUNK_CHARS)
                    if len(retry_chunks) == 1:
                        # A short tail cannot be split further, but one bounded
                        # retry still recovers transient timeout/parse failures.
                        retry_chunks = [chunk]
                    if retry_chunks:
                        log.warning(
                            "meeting notes retrying chunk %d/%d as %d bounded piece(s)",
                            index + 1, len(chunks), len(retry_chunks),
                        )
                        for retry_chunk in retry_chunks:
                            retry_notes, retry_error, _ = await generate(
                                retry_chunk,
                                map_prompt,
                                MEETING_NOTES_MAP_MAX_TOKENS,
                            )
                            if retry_notes is None:
                                generation_error = retry_error or generation_error
                                recovered = []
                                break
                            recovered.append(retry_notes)
                # A cancellation or app shutdown can arrive while a retry is
                # waiting for the replacement model. Do not reinterpret that
                # explicit stop as another recovery failure.
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_notes_cancel:
                    await fail("cancelled", "cancelled")
                    return
                if notes is None and not recovered:
                    # An unkillable Metal call cannot be repaired inside this
                    # process. Keep the app's durable notes-only job active and
                    # restart the sidecar; MeetingProcessor requeues that exact
                    # transcript on reconnect. Sending meeting_notes_failed
                    # first would turn the row back to ready+attention and lose
                    # the automatic resume that the restart is meant to provide.
                    if self._restart_if_cleanup_unhealthy(
                        include_recovering=True
                    ):
                        log.warning(
                            "meeting notes retaining %s for engine-restart recovery",
                            meeting_id,
                        )
                        return
                    error = generation_error or "local notes generation failed"
                    log.warning("meeting notes failed for %s: %s", meeting_id, error)
                    await fail(error + "; retry to generate notes", "generation_failed")
                    return
                if recovered:
                    partials.extend(recovered)
                elif notes is not None:
                    partials.append(notes)
                await self._send({
                    "event": "meeting_notes_progress", "id": job_id,
                    "meeting_id": meeting_id,
                    "fraction": round((index + 1) / max(1, len(chunks) + 1), 3),
                })
            merged = merge_notes(partials)
            if len(partials) > 1:
                reduced, reduce_error, _ = await generate(
                    # merge_notes applies global size/item bounds before this
                    # model call. Passing every per-chunk response directly
                    # made a maximum-size transcript create an unbounded
                    # reducer context despite the per-call output-token cap.
                    json.dumps(merged, ensure_ascii=False),
                    reduce_prompt,
                    MEETING_NOTES_REDUCE_MAX_TOKENS,
                )
                if self.shutdown.is_set():
                    await fail("engine shutting down", "engine_shutdown")
                    return
                if self._meeting_notes_cancel:
                    await fail("cancelled", "cancelled")
                    return
                if reduced is None:
                    error = reduce_error or "local notes merge failed"
                    log.warning("meeting notes merge failed for %s: %s", meeting_id, error)
                    # Every map result already passed the strict schema. A
                    # deterministic merge is less polished but remains real
                    # generated notes, unlike the old raw-transcript fallback.
                else:
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
            self._end_batch_job(lower_priority=False)
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
