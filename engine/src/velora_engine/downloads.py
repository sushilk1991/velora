"""Engine-owned recovery state and cancellable transfer processes.

Server -> coordinator -> child worker -> owned cache
                         terminate/kill -> wait -> retry
Ready is set only by the server after live model adoption, never by cache reuse.
"""
from __future__ import annotations

import asyncio
import copy
import json
import os
import signal
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from .download_cache import _cache_root

_BYTE_STALL_S = 60
_METADATA_S = 60
_VERIFY_S = 300
_BACKOFF_S = (2, 5, 15)
_REAP_S = 2
_SCHEMA = 1
_RECOVERY_STATES = {"retry_wait", "failed"}
_RESUME_ORDER = {"none": 0, "completed_files": 1, "partial": 2, "file_restarted": 3}


@dataclass(frozen=True)
class DownloadResult:
    path: str
    revision: str | None
    attempt: str


class DownloadError(Exception):
    def __init__(self, error: dict, snapshot: dict | None = None):
        super().__init__(error["message"])
        self.error = error
        self.code = error["code"]
        self.snapshot = snapshot


@dataclass
class _Entry:
    item: dict
    task: asyncio.Task | None = None
    process: asyncio.subprocess.Process | None = None
    reaping: asyncio.Task | None = None
    result: DownloadResult | None = None
    error: DownloadError | None = None


def _error(category, code, message, retryable=False):
    return DownloadError({"category": category, "code": code,
                          "message": message, "retryable": retryable})


class DownloadCoordinator:
    def __init__(self, *, cache_root: Path | None = None):
        self._root = Path(cache_root) if cache_root is not None else _cache_root()
        self._engine_id = uuid.uuid4().hex
        self._sequence = 0
        self._entries: dict[tuple[str, str], _Entry] = {}
        self._active: dict[str, str] = {}
        self._control = asyncio.Lock()
        self._closed = False

    def snapshot(self) -> dict:
        # Full detached snapshots make reconnects authoritative; callers cannot
        # mutate coordinator state and polling never synthesizes byte progress.
        return {"schema": _SCHEMA, "engine_id": self._engine_id,
                "sequence": self._sequence, "snapshot": True,
                "downloads": [copy.deepcopy(entry.item) for entry in self._entries.values()]}

    def _update(self, entry, **values):
        entry.item.update(values)
        state = entry.item["state"]
        entry.item["retry_allowed"] = state in _RECOVERY_STATES
        entry.item["restart_allowed"] = state in _RECOVERY_STATES
        self._sequence += 1

    def _new_entry(self, model, kind):
        if self._closed:
            raise _error("cancelled", "coordinator_closed", "Download coordinator is closed.")
        if kind not in ("stt", "cleanup") or not model:
            raise ValueError("invalid model download key")
        from .models import lookup
        from huggingface_hub.utils import validate_repo_id

        # Reject URLs/tokens before publishing or persisting a model key. Explicit
        # local paths keep the compatibility behavior of ensure_downloaded.
        if not Path(model).expanduser().exists():
            validate_repo_id(model)
        # A model has one kind/owner even if a malformed client submits both keys.
        info = lookup(model)
        conflicting = any(key[0] == model and key[1] != kind for key in self._entries)
        if conflicting or (info is not None and info.kind != kind):
            raise _error("command", "invalid_download_kind", "Model kind does not match this download.")
        entry = _Entry({"model": model, "kind": kind, "revision": None,
                        "attempt": uuid.uuid4().hex, "state": "queued",
                        "bytes_received": 0, "bytes_total": None, "retry_index": 0,
                        "retry_at": None, "error": None, "resume": "none",
                        "retry_allowed": False, "restart_allowed": False,
                        "active_model": self._active.get(kind)})
        self._entries[(model, kind)] = entry
        self._sequence += 1
        return entry

    async def ensure(self, model_id: str, kind: str) -> DownloadResult:
        if self._closed:
            raise _error("cancelled", "coordinator_closed", "Download coordinator is closed.")
        entry = self._entries.get((model_id, kind))
        if entry is None:
            entry = self._new_entry(model_id, kind)
            entry.task = asyncio.create_task(self._execute(entry))
            entry.task.add_done_callback(self._observe)
        if entry.error:
            raise entry.error
        if entry.result:
            return entry.result
        # A caller's cancellation must not cancel the shared transfer for others.
        return await asyncio.shield(entry.task)

    def _matching(self, model, kind, attempt):
        entry = self._entries.get((model, kind))
        if entry is None or entry.item["attempt"] != attempt:
            error = _error("command", "stale_download_attempt", "Download attempt changed. Refresh download status.")
            error.snapshot = self.snapshot()
            raise error
        return entry

    async def retry(self, model_id: str, kind: str, attempt: str, *, restart: bool = False) -> dict:
        # Serialize recovery decisions across awaits. No replacement worker starts
        # until cancellation has reaped the previous process and released its lock.
        async with self._control:
            old = self._matching(model_id, kind, attempt)
            if self._closed:
                raise _error("cancelled", "coordinator_closed", "Download coordinator is closed.")
            if old.item["state"] not in _RECOVERY_STATES:
                return self.snapshot()
            await self._stop_entry(old)
            entry = self._new_entry(model_id, kind)
            entry.task = asyncio.create_task(self._execute(entry, restart=restart))
            # retry accepts immediately; observe detached failures to avoid task warnings.
            entry.task.add_done_callback(self._observe)
            return self.snapshot()

    @staticmethod
    def _observe(task):
        if not task.cancelled():
            task.exception()

    async def mark_loading(self, model_id: str, kind: str, attempt: str) -> None:
        entry = self._matching(model_id, kind, attempt)
        if entry.result is None:
            raise _error("command", "transfer_not_verified", "Model transfer is not verified.")
        self._update(entry, state="loading", error=None)

    async def mark_ready(self, model_id: str, kind: str, attempt: str) -> None:
        entry = self._matching(model_id, kind, attempt)
        if entry.result is None or entry.item["state"] != "loading":
            raise _error("command", "model_not_loading", "Model has not entered live loading.")
        self._active[kind] = model_id
        for candidate in self._entries.values():
            if candidate.item["kind"] == kind:
                self._update(candidate, active_model=model_id)
        self._update(entry, state="ready", error=None, retry_at=None)

    async def mark_failed(self, model_id: str, kind: str, attempt: str, error: dict) -> None:
        entry = self._matching(model_id, kind, attempt)
        await self._stop_entry(entry)
        entry.error = DownloadError(dict(error))
        self._update(entry, state="failed", error=dict(error), retry_at=None)

    def _command(self, entry, restart):
        return [sys.executable, "-u", "-m", "velora_engine.download_worker",
                entry.item["model"], str(self._root), "restart" if restart else "keep"]

    async def _reap(self, entry):
        # Timeout cleanup and explicit stops join the same shielded task:
        # timeout --+--> TERM -> grace -> KILL -> wait -> release handle
        # close ----+    caller cancellation never cancels this cleanup
        if entry.reaping is None:
            if entry.process is None:
                return
            entry.reaping = asyncio.create_task(self._finish_reap(entry, entry.process))
        reaping = entry.reaping
        cancelled = False
        try:
            while True:
                try:
                    await asyncio.shield(reaping)
                    break
                except asyncio.CancelledError:
                    if reaping.cancelled():
                        raise
                    cancelled = True
        finally:
            if reaping.done() and entry.reaping is reaping:
                entry.reaping = None
        if cancelled:
            raise asyncio.CancelledError

    async def _finish_reap(self, entry, process):
        # Retain ownership until wait proves exit, including SIGTERM-ignoring
        # children. A failed cleanup retains the handle for a later stop request.
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(process.wait(), _REAP_S)
            except asyncio.TimeoutError:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        await process.wait()
        if entry.process is process:
            entry.process = None

    async def _stop_entry(self, entry):
        task = entry.task
        if task and not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await self._reap(entry)

    async def close(self) -> None:
        async with self._control:
            self._closed = True
            for entry in self._entries.values():
                await self._stop_entry(entry)
                if entry.item["state"] in ("queued", "downloading", "verifying", "retry_wait"):
                    error = _error("cancelled", "download_cancelled", "Download stopped. Retry to resume.")
                    entry.error = error
                    self._update(entry, state="failed", retry_at=None, error=error.error)

    async def _execute(self, entry, *, restart=False):
        # One initial transfer and exactly three network retries. Disk/auth/integrity
        # failures stop immediately; manual retry starts a fresh bounded budget.
        for retry_index in range(len(_BACKOFF_S) + 1):
            self._update(entry, state="downloading", retry_index=retry_index, retry_at=None, error=None)
            try:
                result = await self._once(entry, restart if retry_index == 0 else False)
                entry.result = result
                self._update(entry, state="verifying", error=None)
                return result
            except DownloadError as error:
                if not error.error["retryable"] or retry_index == len(_BACKOFF_S):
                    entry.error = error
                    self._update(entry, state="failed", retry_at=None, error=error.error)
                    raise
                delay = _BACKOFF_S[retry_index]
                self._update(entry, state="retry_wait", retry_at=time.time() + delay, error=error.error)
                await asyncio.sleep(delay)

    async def _once(self, entry, restart):
        # Shield process creation: cancellation can arrive after the OS spawned
        # a child but before asyncio returns its handle. Recover that handle first.
        spawning = asyncio.create_task(asyncio.create_subprocess_exec(
            *self._command(entry, restart), stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True))
        try:
            process = await asyncio.shield(spawning)
        except asyncio.CancelledError:
            entry.process = await spawning
            await self._reap(entry)
            raise
        except OSError:
            raise _error("worker", "worker_start_failed", "Cannot start the download worker. Check engine installation.") from None
        entry.process = process
        phase, since = "metadata", time.monotonic()
        last_bytes = entry.item["bytes_received"]
        result, failure = None, None
        try:
            while True:
                deadline = {"metadata": _METADATA_S, "downloading": _BYTE_STALL_S, "verifying": _VERIFY_S}[phase]
                remaining = deadline - (time.monotonic() - since)
                try:
                    if remaining <= 0:
                        raise asyncio.TimeoutError
                    line = await asyncio.wait_for(process.stdout.readline(), remaining)
                except asyncio.TimeoutError:
                    code = {"metadata": "metadata_timeout", "downloading": "byte_stall", "verifying": "verification_timeout"}[phase]
                    category = "verification" if phase == "verifying" else "network"
                    raise _error(category, code, "Model transfer stopped making progress. Retry to resume.", phase != "verifying")
                if not line:
                    break
                event = json.loads(line)
                event_type = event.get("event")
                if event_type == "phase":
                    new_phase = event["state"]
                    if new_phase != phase:
                        phase, since = new_phase, time.monotonic()
                    continue
                if event_type == "progress":
                    new_phase = event["state"]
                    received = event["bytes_received"]
                    if new_phase != phase or received > last_bytes:
                        since = time.monotonic()
                    phase, last_bytes = new_phase, received
                    # Keep the attempt's strongest recovery fact after later file
                    # verification: a restarted file must not revert to "none".
                    resume = max((entry.item["resume"], event["resume"]), key=_RESUME_ORDER.__getitem__)
                    self._update(entry, state=new_phase, bytes_received=received,
                                 bytes_total=event["bytes_total"], revision=event["revision"], resume=resume)
                    continue
                if event_type == "result":
                    result = DownloadResult(event["path"], event["revision"], entry.item["attempt"])
                    continue
                if event_type == "error":
                    failure = DownloadError(event["error"])
            # EOF is not success: the worker must exit cleanly and provide its result.
            await asyncio.wait_for(process.wait(), _REAP_S)
            if failure:
                raise failure
            if result is None or process.returncode != 0:
                raise _error("network", "worker_exited", "Download worker exited before verification. Retry to resume.", True)
            return result
        except (ValueError, KeyError, asyncio.TimeoutError):
            raise _error("worker", "worker_protocol", "Download worker failed. Retry the download.") from None
        finally:
            await self._reap(entry)
