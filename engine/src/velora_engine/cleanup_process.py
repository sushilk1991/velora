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
from collections.abc import Sequence
from typing import Any

from .cleanup import (
    HARD_TIMEOUT_GRACE_S,
    QUEUE_TIMEOUT_S,
    CleanupResult,
    PrefixPreparation,
    adaptive_timeout_ms,
)

log = logging.getLogger("velora.cleanup_process")

CANCEL_GRACE_S = 1.0
PREFIX_TIMEOUT_S = 6.0
RECOVERY_ATTEMPTS = 3
RECOVERY_BACKOFF_S = 0.25
WORKER_MODULE = "velora_engine.cleanup_worker"


class _WorkerExited(RuntimeError):
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
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._operation_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._warm_system_prompt: str | None = None
        self._closed = False
        self._generation = 0

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
            response = await asyncio.wait_for(self._request("ping"), timeout=5.0)
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup probe failed"))
        finally:
            await self._stop_worker()

    async def _start_and_load(self) -> None:
        if self._closed:
            raise RuntimeError("cleanup process is closed")
        self.recovering = True
        self.loaded = False
        try:
            await self._spawn()
            response = await self._request(
                "load",
                warm_system_prompt=self._warm_system_prompt,
            )
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup load failed"))
            self.loaded = True
            self.unhealthy = False
            log.info("cleanup worker ready model=%s pid=%s", self.model_id, self.pid)
        except BaseException:
            await self._stop_worker()
            raise
        finally:
            self.recovering = False

    @property
    def pid(self) -> int | None:
        return self._process.pid if self._process is not None else None

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
            reader, writer = await asyncio.open_connection(sock=parent_sock)
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
                writer.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
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
                writer.write(
                    (json.dumps({"op": "cancel", "target": request_id}) + "\n").encode()
                )
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
    ) -> CleanupResult:
        if timeout_ms is None:
            timeout_ms = adaptive_timeout_ms(raw)
        if not self.loaded:
            reason = "llm_recovering" if self.recovering else "llm_not_loaded"
            return CleanupResult(raw, False, 0, reason)

        call_started = time.perf_counter()
        try:
            await asyncio.wait_for(
                self._operation_lock.acquire(),
                timeout=self._queue_timeout_s,
            )
        except TimeoutError:
            elapsed = int((time.perf_counter() - call_started) * 1000)
            log.error("cleanup worker unavailable after %dms in queue", elapsed)
            await self._replace_worker("timeout_queue")
            return CleanupResult(
                raw,
                False,
                int(self._queue_timeout_s * 1000),
                "timeout_queue",
                wall_ms=elapsed,
            )

        request_id = uuid.uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        cancel_task: asyncio.Task[None] | None = None
        try:
            writer = self._writer
            if writer is None or writer.is_closing():
                raise _WorkerExited("cleanup worker is not connected")
            message = {
                "id": request_id,
                "op": "cleanup",
                "raw": raw,
                "system_prompt": system_prompt,
                "timeout_ms": timeout_ms,
                "check_ratio": check_ratio,
                "allowed_terms": allowed_terms,
            }
            async with self._write_lock:
                writer.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
                await writer.drain()
            if cancel_event is not None:
                cancel_task = asyncio.create_task(
                    self._watch_cancel(cancel_event, request_id)
                )
            response = await asyncio.wait_for(
                asyncio.shield(future),
                timeout=timeout_ms / 1000.0 + self._hard_timeout_grace_s,
            )
            if not response.get("ok"):
                raise RuntimeError(str(response.get("error") or "cleanup failed"))
            payload = dict(response["result"])
            payload["wall_ms"] = int((time.perf_counter() - call_started) * 1000)
            return CleanupResult(**payload)
        except TimeoutError:
            elapsed = int((time.perf_counter() - call_started) * 1000)
            log.error("cleanup process exceeded hard wall deadline after %dms", elapsed)
            future.cancel()
            await self._replace_worker("timeout_hard")
            return CleanupResult(
                raw,
                False,
                timeout_ms,
                "timeout_hard",
                wall_ms=elapsed,
            )
        except asyncio.CancelledError:
            await self._send_cancel(request_id)
            try:
                await asyncio.wait_for(
                    asyncio.shield(future),
                    timeout=self._cancel_grace_s,
                )
            except Exception:  # noqa: BLE001 - unresponsive cancellation replaces the child
                future.cancel()
                await self._replace_worker("cancel_unresponsive")
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
        if not self.loaded:
            reason = "llm_recovering" if self.recovering else "llm_not_loaded"
            return PrefixPreparation(False, 0, 0, reason)
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

    async def _replace_worker(self, reason: str) -> None:
        log.warning("replacing cleanup worker reason=%s", reason)
        await self._stop_worker()
        if not self.unhealthy:
            self._schedule_recovery(reason)

    def _schedule_recovery(self, reason: str) -> None:
        if self._closed or self.recovering or self.unhealthy:
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
                        self.unhealthy = True
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
                    self.unhealthy = True
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
        loop.create_task(self._stop_worker())

    async def aclose(self) -> None:
        """Close and reap the child before the parent event loop exits."""
        self._closed = True
        self.loaded = False
        recovery_task = self._recovery_task
        self._recovery_task = None
        if recovery_task is not None:
            recovery_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await recovery_task
        await self._stop_worker()
