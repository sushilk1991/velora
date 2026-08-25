"""Killable process boundary around the MLX cleanup model.

The speech engine must remain responsive even when Metal/MLX wedges inside a
native call.  A Python thread cannot enforce that boundary, so the long-lived
cleanup model lives in a child process and communicates over a private socket.
Normal cooperative cancellation keeps the warm model; a hard deadline kills
only the cleanup worker and warms a replacement in the background.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import socket
import sys
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from typing import Any

from .cleanup import (
    HARD_TIMEOUT_GRACE_S,
    QUEUE_TIMEOUT_S,
    CleanupMemory,
    CleanupResult,
    PrefixPreparation,
    adaptive_timeout_ms,
)
from .cleanup_ipc import (
    CLEANUP_IPC_STREAM_LIMIT_BYTES,
    encode_cleanup_ipc_message,
    pack_prefix_candidates,
)

# The worker owns the native-generation watchdog and then must serialize its
# timeout result over IPC. Give that response a small delivery margin so the
# parent does not kill a worker at the exact instant it is reporting its own
# bounded fallback (observed as a 23.001s notes timeout at a 20s + 3s wall).
WORKER_RESPONSE_GRACE_S = 0.2
LOAD_TIMEOUT_S = 20.0

log = logging.getLogger("velora.cleanup_process")

CANCEL_GRACE_S = 1.0
PREFIX_TIMEOUT_S = 6.0
RECOVERY_ATTEMPTS = 3
RECOVERY_BACKOFF_S = 0.25
MAX_RECOVERY_DEFERRALS = 3
WORKER_MODULE = "velora_engine.cleanup_worker"


class _WorkerExited(RuntimeError):
    pass


class _LoadCancelled(RuntimeError):
    pass


class CleanupProcess:
    """Async proxy with the public surface used by :class:`CleanupEngine`."""

    def __init__(
        self,
        model_id: str,
        *,
        worker_command: Sequence[str] | None = None,
        hard_timeout_grace_s: float = HARD_TIMEOUT_GRACE_S,
        queue_timeout_s: float = QUEUE_TIMEOUT_S,
        cancel_grace_s: float = CANCEL_GRACE_S,
        on_unhealthy: Callable[[], None] | None = None,
    ) -> None:
        self.model_id = model_id
        self.loaded = False
        # Compatibility with the server's legacy whole-engine recovery hook.
        # This proxy recovers its own killable child, so it never asks the
        # speech engine to restart.
        self.unhealthy = False
        self.recovering = False
        self._worker_command = tuple(worker_command) if worker_command else None
        self._hard_timeout_grace_s = hard_timeout_grace_s
        self._queue_timeout_s = queue_timeout_s
        self._cancel_grace_s = cancel_grace_s
        self._process: asyncio.subprocess.Process | None = None
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._recovery_task: asyncio.Task[None] | None = None
        self._replacement_task: asyncio.Task[None] | None = None
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._operation_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._load_lock = asyncio.Lock()
        self._warm_system_prompt: str | None = None
        self._closed = False
        self._hibernated = False
        self._generation = 0
        self._recovery_deferred = False
        self._deferred_recovery_reason: str | None = None
        self._recovery_deferrals = 0
        self._on_unhealthy = on_unhealthy

    async def load_async(self, warm_system_prompt: str | None = None) -> None:
        self._warm_system_prompt = warm_system_prompt
        await self._start_and_load()

    async def probe_async(self) -> None:
        """Spawn the packaged child and verify IPC without loading a model."""
        # A packaging probe is intentionally one-shot. Mark it closed before
        # spawning so an unexpected child exit cannot schedule model recovery.
        self._closed = True
        try:
            await self._spawn()
            # Exercise the production worker above asyncio's 64 KiB default
            # without loading MLX. Packaging verification therefore covers the
            # same large request path Action Mode uses.
            response = await asyncio.wait_for(
                self._request("ping", padding="x" * 80_000),
                timeout=5.0,
            )
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup probe failed"))
        finally:
            await self._stop_worker()

    async def _start_and_load(
        self,
        cancel_event: threading.Event | None = None,
    ) -> None:
        if self._closed:
            raise RuntimeError("cleanup process is closed")
        self.recovering = True
        self.loaded = False
        request_task: asyncio.Task[dict[str, Any]] | None = None
        cancel_task: asyncio.Task[None] | None = None
        try:
            await self._spawn()
            if self._closed:
                raise _LoadCancelled("cleanup process closed during load")
            request_task = asyncio.create_task(self._request(
                "load", warm_system_prompt=self._warm_system_prompt))
            if cancel_event is not None:
                async def wait_cancelled() -> None:
                    while not cancel_event.is_set():
                        await asyncio.sleep(0.02)

                cancel_task = asyncio.create_task(wait_cancelled())
                done, _ = await asyncio.wait(
                    {request_task, cancel_task},
                    timeout=LOAD_TIMEOUT_S,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if not done:
                    raise TimeoutError("cleanup model load timed out")
                if cancel_task in done:
                    raise _LoadCancelled("cleanup model load cancelled")
                response = request_task.result()
            else:
                response = await asyncio.wait_for(
                    request_task, timeout=LOAD_TIMEOUT_S)
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup load failed"))
            if self._closed:
                raise _LoadCancelled("cleanup process closed during load")
            self.loaded = True
            self._hibernated = False
            self.unhealthy = False
            self._recovery_deferrals = 0
            log.info("cleanup worker ready model=%s pid=%s", self.model_id, self.pid)
        except BaseException:
            if request_task is not None and not request_task.done():
                request_task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await request_task
            await self._stop_worker()
            raise
        finally:
            if cancel_task is not None:
                cancel_task.cancel()
            self.recovering = False

    @property
    def pid(self) -> int | None:
        return self._process.pid if self._process is not None else None

    @property
    def hibernated(self) -> bool:
        return self._hibernated

    async def _spawn(self) -> None:
        await self._stop_worker()
        parent_sock, child_sock = socket.socketpair()
        parent_sock.setblocking(False)
        child_fd = child_sock.fileno()
        command = list(self._worker_command or (sys.executable, "-m", WORKER_MODULE))
        command.extend(["--fd", str(child_fd), "--model", self.model_id])
        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                pass_fds=(child_fd,),
            )
        except BaseException:
            parent_sock.close()
            child_sock.close()
            raise
        child_sock.close()
        try:
            reader, writer = await asyncio.open_connection(
                sock=parent_sock,
                limit=CLEANUP_IPC_STREAM_LIMIT_BYTES,
            )
        except BaseException:
            process.terminate()
            parent_sock.close()
            raise
        self._generation += 1
        generation = self._generation
        self._process = process
        self._reader = reader
        self._writer = writer
        self._reader_task = asyncio.create_task(self._read_responses(generation, process))

    async def _read_responses(
        self,
        generation: int,
        process: asyncio.subprocess.Process,
    ) -> None:
        reader = self._reader
        if reader is None:
            return
        error: BaseException | None = None
        try:
            while generation == self._generation:
                line = await reader.readline()
                if not line:
                    break
                try:
                    response = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    raise RuntimeError("invalid cleanup worker response") from exc
                request_id = response.get("id")
                if not isinstance(request_id, str):
                    continue
                future = self._pending.pop(request_id, None)
                if future is not None and not future.done():
                    future.set_result(response)
        except asyncio.CancelledError:
            return
        except BaseException as exc:  # noqa: BLE001 - fan out to waiting calls
            error = exc
        finally:
            if generation == self._generation:
                # A malformed or oversized response can leave an otherwise
                # live child behind. Retire it on a bounded wall instead of
                # waiting forever before the pending request learns it failed.
                if error is not None and process.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        process.terminate()
                    try:
                        await asyncio.wait_for(process.wait(), timeout=0.5)
                    except TimeoutError:
                        with contextlib.suppress(ProcessLookupError):
                            process.kill()
                        with contextlib.suppress(Exception):
                            await asyncio.wait_for(process.wait(), timeout=0.5)
                else:
                    with contextlib.suppress(Exception):
                        await process.wait()
                failure = error or _WorkerExited(
                    f"cleanup worker exited with status {process.returncode}"
                )
                for request_id, future in list(self._pending.items()):
                    if not future.done():
                        future.set_exception(failure)
                    self._pending.pop(request_id, None)
                self.loaded = False
                if not self._closed and not self.recovering:
                    self._schedule_recovery("worker_exit")

    async def _request(
        self,
        operation: str,
        *,
        request_id: str | None = None,
        **payload: Any,
    ) -> dict[str, Any]:
        writer = self._writer
        if writer is None or writer.is_closing():
            raise _WorkerExited("cleanup worker is not connected")
        request_id = request_id or uuid.uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        message = {"id": request_id, "op": operation, **payload}
        try:
            async with self._write_lock:
                writer.write(encode_cleanup_ipc_message(message))
                await writer.drain()
            return await future
        except BaseException:
            self._pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            raise

    async def _send_cancel(self, request_id: str) -> None:
        writer = self._writer
        if writer is None or writer.is_closing():
            return
        try:
            async with self._write_lock:
                writer.write(encode_cleanup_ipc_message(
                    {"op": "cancel", "target": request_id}
                ))
                await writer.drain()
        except (ConnectionError, BrokenPipeError):
            pass

    async def _watch_cancel(
        self,
        cancel_event: threading.Event,
        request_id: str,
    ) -> None:
        while not cancel_event.is_set():
            await asyncio.sleep(0.02)
        await self._send_cancel(request_id)

    async def cleanup(
        self,
        raw: str,
        system_prompt: str,
        timeout_ms: int | None = None,
        check_ratio: bool = True,
        cancel_event: threading.Event | None = None,
        allowed_terms: list[str] | None = None,
        prefix_candidates: list[tuple[str, str]] | None = None,
        max_tokens: int | None = None,
        cache_scope: str | None = None,
        max_input_tokens: int | None = None,
    ) -> CleanupResult:
        if cancel_event is not None and cancel_event.is_set():
            return CleanupResult(raw, False, 0, "cancelled")
        if timeout_ms is None:
            timeout_ms = adaptive_timeout_ms(raw)
        if not self.loaded and self._hibernated:
            await self.ensure_loaded(cancel_event=cancel_event)
        if not self.loaded:
            if cancel_event is not None and cancel_event.is_set():
                return CleanupResult(raw, False, 0, "cancelled")
            reason = "llm_recovering" if self.recovering else "llm_not_loaded"
            return CleanupResult(raw, False, 0, reason)

        call_started = time.perf_counter()
        admitted_generation = self._generation
        try:
            await asyncio.wait_for(
                self._operation_lock.acquire(),
                timeout=self._queue_timeout_s,
            )
        except TimeoutError:
            elapsed = int((time.perf_counter() - call_started) * 1000)
            log.error("cleanup worker unavailable after %dms in queue", elapsed)
            self._schedule_replacement("timeout_queue")
            return CleanupResult(
                raw,
                False,
                int(self._queue_timeout_s * 1000),
                "timeout_queue",
                wall_ms=elapsed,
            )

        if not self.loaded or self._generation != admitted_generation:
            self._operation_lock.release()
            reason = "llm_recovering" if self.recovering else "llm_not_loaded"
            return CleanupResult(
                raw,
                False,
                int((time.perf_counter() - call_started) * 1000),
                reason,
            )

        request_id = uuid.uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        cancel_task: asyncio.Task[None] | None = None
        try:
            writer = self._writer
            if writer is None or writer.is_closing():
                raise _WorkerExited("cleanup worker is not connected")
            wire_candidates, shared_prompt_prefixes = pack_prefix_candidates(
                system_prompt,
                prefix_candidates,
            )
            message = {
                "id": request_id,
                "op": "cleanup",
                "raw": raw,
                "system_prompt": system_prompt,
                "timeout_ms": timeout_ms,
                "check_ratio": check_ratio,
                "allowed_terms": allowed_terms,
                "prefix_candidates": wire_candidates,
                "shared_prompt_prefixes": shared_prompt_prefixes,
                "max_tokens": max_tokens,
                "cache_scope": cache_scope,
                "max_input_tokens": max_input_tokens,
            }
            async with self._write_lock:
                writer.write(encode_cleanup_ipc_message(message))
                await writer.drain()
            if cancel_event is not None:
                cancel_task = asyncio.create_task(
                    self._watch_cancel(cancel_event, request_id)
                )
            response = await asyncio.wait_for(
                asyncio.shield(future),
                timeout=(
                    timeout_ms / 1000.0
                    + self._hard_timeout_grace_s
                    + WORKER_RESPONSE_GRACE_S
                ),
            )
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup failed"))
            payload = dict(response["result"])
            payload["wall_ms"] = int((time.perf_counter() - call_started) * 1000)
            result = CleanupResult(**payload)
            if result.reason in {"timeout_hard", "timeout_queue", "llm_unhealthy"}:
                # The child owns a thread watchdog as a second line of defence.
                # If it wins the deadline race, its MLX thread is retired even
                # though the protocol response itself arrived normally.
                self._schedule_replacement(f"child_{result.reason}")
            return result
        except TimeoutError:
            elapsed = int((time.perf_counter() - call_started) * 1000)
            log.error("cleanup process exceeded hard wall deadline after %dms", elapsed)
            future.cancel()
            # The fallback text is already selected. Block new calls
            # synchronously, then reap and warm a replacement off the caller's
            # critical path. `loaded=False` is the ordering barrier: no request
            # can reach the old writer after this method returns.
            self._schedule_replacement("timeout_hard")
            return CleanupResult(
                raw,
                False,
                timeout_ms,
                "timeout_hard",
                wall_ms=elapsed,
            )
        except asyncio.CancelledError:
            async def finish_cancellation() -> None:
                await self._send_cancel(request_id)
                try:
                    await asyncio.wait_for(
                        asyncio.shield(future),
                        timeout=self._cancel_grace_s,
                    )
                except Exception:  # noqa: BLE001 - unresponsive cancellation replaces the child
                    future.cancel()
                    await self._replace_worker("cancel_unresponsive")

            # A wrapper task can itself be cancelled while waiting for this
            # cancellation handshake. Repeated Task.cancel() calls must not
            # interrupt the bounded cancel/reap and release the operation lock
            # while native generation is still running.
            completion = asyncio.create_task(finish_cancellation())
            while not completion.done():
                try:
                    await asyncio.shield(completion)
                except asyncio.CancelledError:
                    continue
            with contextlib.suppress(asyncio.CancelledError, Exception):
                completion.result()
            raise
        except Exception as exc:
            elapsed = int((time.perf_counter() - call_started) * 1000)
            log.exception("cleanup process call failed")
            self._schedule_recovery("call_failed")
            return CleanupResult(raw, False, 0, f"error:{exc}", wall_ms=elapsed)
        finally:
            if cancel_task is not None:
                cancel_task.cancel()
            self._pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            self._operation_lock.release()

    async def prepare_prefix(
        self,
        candidates: list[tuple[str, str]],
        cancel_event: threading.Event | None = None,
    ) -> PrefixPreparation:
        if cancel_event is not None and cancel_event.is_set():
            return PrefixPreparation(False, 0, 0, "cancelled")
        if not self.loaded and self._hibernated:
            await self.ensure_loaded(cancel_event=cancel_event)
        if not self.loaded:
            reason = "llm_recovering" if self.recovering else "llm_not_loaded"
            return PrefixPreparation(False, 0, 0, reason)
        if len(candidates) < 2:
            return PrefixPreparation(False, 0, 0, "insufficient_candidates")
        # Prefix preparation is an optimization. It uses the same bounded
        # process request path but a ceiling-sized budget so it cannot wedge
        # the authoritative dictation path indefinitely.
        started = time.perf_counter()
        try:
            await asyncio.wait_for(
                self._operation_lock.acquire(),
                timeout=self._queue_timeout_s,
            )
        except TimeoutError:
            return PrefixPreparation(
                False,
                0,
                int((time.perf_counter() - started) * 1000),
                "timeout_queue",
            )
        request_id = uuid.uuid4().hex
        request_task: asyncio.Task[dict[str, Any]] | None = None
        cancel_task: asyncio.Task[None] | None = None
        try:
            request_task = asyncio.create_task(
                self._request(
                    "prepare_prefix",
                    request_id=request_id,
                    candidates=candidates,
                )
            )
            if cancel_event is not None:
                cancel_task = asyncio.create_task(
                    self._watch_cancel(cancel_event, request_id)
                )
            response = await asyncio.wait_for(
                asyncio.shield(request_task),
                timeout=PREFIX_TIMEOUT_S + self._hard_timeout_grace_s,
            )
            if not response.get("ok"):
                return PrefixPreparation(False, 0, 0, str(response.get("error")))
            return PrefixPreparation(**response["result"])
        except TimeoutError:
            elapsed = int((time.perf_counter() - started) * 1000)
            if request_task is not None:
                request_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await request_task
            await self._replace_worker("prefix_timeout")
            return PrefixPreparation(False, 0, elapsed, "timeout_hard")
        except asyncio.CancelledError:
            await self._send_cancel(request_id)
            if request_task is not None:
                try:
                    await asyncio.wait_for(
                        asyncio.shield(request_task),
                        timeout=self._cancel_grace_s,
                    )
                except TimeoutError:
                    request_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await request_task
                    await self._replace_worker("prefix_cancel_unresponsive")
                except (_WorkerExited, ConnectionError, RuntimeError) as exc:
                    # A spontaneous child failure schedules its own recovery.
                    log.debug("prefix cancellation ended with worker failure: %s", exc)
            raise
        except Exception as exc:  # noqa: BLE001 - this path is optional
            return PrefixPreparation(False, 0, 0, f"error:{exc}")
        finally:
            if cancel_task is not None:
                cancel_task.cancel()
            self._operation_lock.release()

    async def memory_metrics(self, reset_peak: bool = False) -> CleanupMemory:
        """Read MLX memory from the child that actually owns the model."""
        if not self.loaded:
            raise RuntimeError("cleanup worker is not loaded")
        try:
            await asyncio.wait_for(
                self._operation_lock.acquire(),
                timeout=self._queue_timeout_s,
            )
        except TimeoutError as exc:
            raise RuntimeError("cleanup worker memory query timed out in queue") from exc
        try:
            response = await asyncio.wait_for(
                self._request("memory", reset_peak=reset_peak),
                timeout=5.0,
            )
            if not response.get("ok"):
                raise RuntimeError(
                    str(response.get("error") or "cleanup memory query failed")
                )
            return CleanupMemory(**response["result"])
        finally:
            self._operation_lock.release()

    async def release_cache(self) -> None:
        """Ask the child to return its MLX buffer cache to the OS.

        Best-effort memory hygiene after batch note generation: a busy or
        replacing worker simply skips the release rather than queueing behind
        interactive work.
        """
        if not self.loaded:
            return
        if not self._operation_lock.locked():
            await self._operation_lock.acquire()
        else:
            return
        try:
            response = await asyncio.wait_for(
                self._request("release_cache"), timeout=5.0)
            if not response.get("ok"):
                log.debug(
                    "cleanup cache release failed: %s",
                    response.get("error") or "unknown")
        except (TimeoutError, OSError, RuntimeError):
            log.debug("cleanup cache release skipped", exc_info=True)
        finally:
            self._operation_lock.release()

    async def release_action_memory(self) -> None:
        """Drop only Agent Mode's KV snapshot; retain model + dictation cache.

        Best effort by design: if generation is still unwinding after a
        cancellation, the later `action_end` request retries this cleanup.
        """
        if not self.loaded or self._operation_lock.locked():
            return
        await self._operation_lock.acquire()
        try:
            response = await asyncio.wait_for(
                self._request("release_action_memory"), timeout=5.0)
            if not response.get("ok"):
                log.debug(
                    "action memory release failed: %s",
                    response.get("error") or "unknown")
        except (TimeoutError, OSError, RuntimeError):
            log.debug("action memory release skipped", exc_info=True)
        finally:
            self._operation_lock.release()

    async def hibernate(self) -> bool:
        """Reap the weight-owning child without disabling future cleanup.

        This is used only after foreground work has ended and macOS reports
        memory pressure. The next explicit cleanup request reloads the same
        model and warm dictation prefix; no smaller or lower-quality model is
        substituted.
        """
        if self._closed or self.unhealthy or not self.loaded:
            return False
        if self._operation_lock.locked():
            return False
        await self._operation_lock.acquire()
        try:
            # Reload and hibernate are two sides of one lifecycle transition.
            # Holding the load lock prevents a new Action from spawning while
            # this task is still reaping the old child.
            async with self._load_lock:
                if self._closed or not self.loaded:
                    return False
                self._hibernated = True
                # Publish the transition before yielding. New callers must
                # wait on _load_lock; they cannot mistake the retiring child
                # for a usable loaded worker.
                self.loaded = False
                stop_task = asyncio.create_task(self._stop_worker())
                cancellation_requested = False
                while not stop_task.done():
                    try:
                        await asyncio.shield(stop_task)
                    except asyncio.CancelledError:
                        # A new foreground job cancels delayed hygiene. Once
                        # reaping has started, finish it so the next reload
                        # cannot overlap or strand this child.
                        cancellation_requested = True
                        continue
                if cancellation_requested:
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        stop_task.result()
                    raise asyncio.CancelledError
                stop_task.result()
                log.info("cleanup worker hibernated under memory pressure")
                return True
        finally:
            self._operation_lock.release()

    async def ensure_loaded(
        self,
        cancel_event: threading.Event | None = None,
    ) -> bool:
        """Lazily restore a deliberately hibernated worker with bounded retry."""
        if cancel_event is not None and cancel_event.is_set():
            return False
        if self.loaded:
            return True
        if self._closed or self.unhealthy or not self._hibernated:
            return False
        async with self._load_lock:
            if self.loaded:
                return True
            if self._closed or self.unhealthy or not self._hibernated:
                return False
            for attempt in range(1, RECOVERY_ATTEMPTS + 1):
                if (self._closed or self.unhealthy or not self._hibernated
                        or (cancel_event is not None and cancel_event.is_set())):
                    return False
                try:
                    await self._start_and_load(cancel_event=cancel_event)
                    return self.loaded
                except _LoadCancelled:
                    return False
                except Exception:
                    if self._closed:
                        return False
                    if attempt == RECOVERY_ATTEMPTS:
                        log.exception(
                            "hibernated cleanup worker failed to reload after %d attempts",
                            attempt,
                        )
                        self._mark_unhealthy()
                        return False
                    log.warning(
                        "hibernated cleanup worker reload failed attempt=%d/%d",
                        attempt, RECOVERY_ATTEMPTS, exc_info=True)
                    await asyncio.sleep(RECOVERY_BACKOFF_S * attempt)
            return False

    async def _replace_worker(self, reason: str) -> None:
        self._schedule_replacement(reason)
        task = self._replacement_task
        if task is not None and task is not asyncio.current_task():
            await asyncio.shield(task)

    def _schedule_replacement(self, reason: str) -> None:
        """Retire the current worker now and reap it in a tracked task."""
        self.loaded = False
        self.recovering = True
        current = self._replacement_task
        if current is not None and not current.done():
            return

        async def replace() -> None:
            log.warning("replacing cleanup worker asynchronously reason=%s", reason)
            try:
                await self._stop_worker()
            finally:
                self.recovering = False
            if not self.unhealthy:
                self._schedule_recovery(reason)

        self._replacement_task = asyncio.create_task(replace())

    def _schedule_recovery(self, reason: str) -> None:
        if self._closed or self.unhealthy:
            return
        if self._recovery_deferred:
            self._deferred_recovery_reason = reason
            return
        if self.recovering:
            return
        if self._recovery_task is not None and not self._recovery_task.done():
            return

        async def recover() -> None:
            log.info("warming replacement cleanup worker reason=%s", reason)
            for attempt in range(1, RECOVERY_ATTEMPTS + 1):
                try:
                    await self._start_and_load()
                    return
                except asyncio.CancelledError:
                    raise
                except Exception:
                    if attempt == RECOVERY_ATTEMPTS:
                        self._mark_unhealthy()
                        log.exception(
                            "replacement cleanup worker failed after %d attempts",
                            attempt,
                        )
                        return
                    log.warning(
                        "replacement cleanup worker load failed attempt=%d/%d; retrying",
                        attempt,
                        RECOVERY_ATTEMPTS,
                        exc_info=True,
                    )
                    await asyncio.sleep(RECOVERY_BACKOFF_S * attempt)

        self._recovery_task = asyncio.create_task(recover())

    async def defer_recovery(self) -> None:
        """Prevent replacement model warm-up while live dictation owns Metal."""
        if self._hibernated:
            return
        self._recovery_deferred = True
        recovery_task = self._recovery_task
        if recovery_task is None or recovery_task.done():
            return
        self._recovery_task = None
        self._deferred_recovery_reason = "dictation_active"
        recovery_task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await recovery_task
        if not self.loaded:
            self._recovery_deferrals += 1
            log.warning(
                "cleanup recovery interrupted by dictation count=%d/%d",
                self._recovery_deferrals,
                MAX_RECOVERY_DEFERRALS,
            )
            if self._recovery_deferrals >= MAX_RECOVERY_DEFERRALS:
                # Repeated hotkey presses can otherwise cancel every multi-second
                # model warm-up forever. Escalate through the server's existing
                # after-final restart path rather than contending with live STT.
                self._mark_unhealthy()

    def resume_recovery(self) -> None:
        """Resume a deferred replacement only after dictation is fully idle."""
        self._recovery_deferred = False
        reason = self._deferred_recovery_reason
        self._deferred_recovery_reason = None
        if (not self.loaded and not self._closed and not self.unhealthy
                and not self._hibernated):
            self._schedule_recovery(reason or "dictation_idle")

    def _mark_unhealthy(self) -> None:
        if self.unhealthy:
            return
        self.unhealthy = True
        callback = self._on_unhealthy
        if callback is not None:
            try:
                callback()
            except Exception:  # noqa: BLE001 — health escalation must not strand reap
                log.exception("cleanup unhealthy callback failed")

    async def _stop_worker(self) -> None:
        self.loaded = False
        self._generation += 1
        reader_task = self._reader_task
        self._reader_task = None
        if reader_task is not None:
            reader_task.cancel()
        writer = self._writer
        self._writer = None
        if writer is not None:
            writer.close()
        process = self._process
        self._process = None
        if process is not None and process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=0.5)
            except TimeoutError:
                with contextlib.suppress(ProcessLookupError):
                    process.kill()
                try:
                    await asyncio.wait_for(process.wait(), timeout=0.5)
                except TimeoutError:
                    self._mark_unhealthy()
                    log.critical("cleanup worker pid=%d could not be reaped", process.pid)
        failure = _WorkerExited("cleanup worker replaced")
        for request_id, future in list(self._pending.items()):
            if not future.done():
                future.set_exception(failure)
            self._pending.pop(request_id, None)

    def close(self) -> None:
        self._closed = True
        self.loaded = False
        if self._recovery_task is not None:
            self._recovery_task.cancel()
        process = self._process
        if process is not None and process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return

        async def finish_close() -> None:
            replacement_task = self._replacement_task
            if replacement_task is not None:
                with contextlib.suppress(asyncio.CancelledError):
                    await replacement_task
            await self._stop_worker()

        loop.create_task(finish_close())

    async def aclose(self) -> None:
        """Close and reap the child before the parent event loop exits."""
        self._closed = True
        self.loaded = False
        replacement_task = self._replacement_task
        self._replacement_task = None
        if replacement_task is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await replacement_task
        recovery_task = self._recovery_task
        self._recovery_task = None
        if recovery_task is not None:
            recovery_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await recovery_task
        async with self._load_lock:
            await self._stop_worker()
