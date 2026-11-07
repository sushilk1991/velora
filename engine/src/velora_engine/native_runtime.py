"""Pinned local native cleanup package and bounded asynchronous process owner.

Only the small worker and supervisor are hashed here. The pinned worker hashes
the model from its open descriptor on every load. No research code is imported.
"""

from __future__ import annotations

import asyncio
import contextlib
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
from .config import velora_home
import signal
import stat
import subprocess
import sys
import time
from typing import Any


MODEL_SHA256 = "ec3710cf3bc12c0fbdfcf24587e5f87a2bf197f4c3129d390052af67e3d1a666"
BINARY_SHA256 = "6b5ab148f586b881d27577f5a61a5dafa551d1a24edb140213c29321ec044a3c"
SUPERVISOR_SHA256 = "fd06b212cff24db00b855265dfae20b403623a15a379ef1e72eec39e106e0b02"
LLAMA_COMMIT = "4b77dee0524c64b8471869232e2958bd9589607d"
CONTEXT_TOKENS = 4096
DRAFT_TOKENS = 8
MAX_OUTPUT_TOKENS = 512
MAX_FRAME = 1024 * 1024
MAX_MANIFEST_BYTES = 64 * 1024
LOAD_TIMEOUT_S = 120.0
WRITE_TIMEOUT_S = 1.0
SPAWN_TIMEOUT_S = 5.0
HARD_GRACE_S = 2.0
RESPONSE_GRACE_S = .5
CANCEL_GRACE_S = 2.0
SHUTDOWN_GRACE_S = 3.5
TERMINATE_GRACE_S = 1.0
KILL_GRACE_S = 1.0
POLL_S = .025


def _json_object(data: bytes) -> dict[str, Any]:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    def invalid_constant(_value):
        raise ValueError("nonfinite JSON number")

    value = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid_constant)
    if not isinstance(value, dict):
        raise ValueError("JSON object required")
    return value


def _regular(path: Path, maximum: int) -> os.stat_result:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
        raise ValueError("invalid native package file: " + path.name)
    return info


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 64 * 1024 * 1024:
            raise ValueError("invalid native executable size")
        for block in iter(lambda: stream.read(64 * 1024), b""):
            digest.update(block)
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ValueError("native executable changed during verification")
    return digest.hexdigest()


@dataclass(frozen=True)
class NativePackage:
    root: Path

    @property
    def model_path(self) -> Path:
        return self.root / "model.gguf"

    @property
    def binary_path(self) -> Path:
        return self.root / "velora-cleanup-native"

    @property
    def supervisor_path(self) -> Path:
        return self.root / "supervise.py"

    def _validate(self) -> None:
        try:
            if self.root.is_symlink() or self.root.parent.is_symlink() or not self.root.is_dir():
                raise ValueError("native package directory must be local and fixed")
            manifest_path = self.root / "manifest.json"
            _regular(manifest_path, MAX_MANIFEST_BYTES)
            descriptor = os.open(manifest_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError("native manifest must be a regular file")
                data = stream.read(MAX_MANIFEST_BYTES + 1)
            if len(data) > MAX_MANIFEST_BYTES:
                raise ValueError("native manifest exceeds size bound")
            manifest = _json_object(data)
            expected = {
                "schema": 1, "checkpoint": "G", "model_sha256": MODEL_SHA256,
                "binary_sha256": BINARY_SHA256, "supervisor_sha256": SUPERVISOR_SHA256,
            }
            for key, value in expected.items():
                if type(manifest.get(key)) is not type(value) or manifest[key] != value:
                    raise ValueError("native manifest identity mismatch: " + key)
            model = _regular(self.model_path, 8 * 1024**3)
            size = manifest.get("model_bytes")
            if type(size) is not int or size != model.st_size:
                raise ValueError("native model size mismatch")
            _regular(self.binary_path, 64 * 1024 * 1024)
            _regular(self.supervisor_path, 256 * 1024)
            if not os.access(self.binary_path, os.X_OK):
                raise ValueError("native worker is not executable")
        except (OSError, UnicodeError, RecursionError) as exc:
            raise ValueError("invalid native package") from exc

    def verify(self) -> None:
        self._validate()
        for path, expected in (
            (self.binary_path, BINARY_SHA256), (self.supervisor_path, SUPERVISOR_SHA256),
        ):
            if _sha256(path) != expected:
                raise ValueError("native package SHA256 mismatch: " + path.name)


def discover_package(home: Path | str | None = None) -> NativePackage | None:
    base = Path(home) if home is not None else velora_home()
    package = NativePackage(base / "experimental" / "lfm3-native-v1")
    try:
        package._validate()
    except (OSError, ValueError):
        return None
    return package


def _process_table() -> dict[int, tuple[int, int, str]]:
    """Inspect ownership without importing platform/process dependencies."""
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat="],
        capture_output=True, timeout=.5, check=True,
    )
    if len(result.stdout) > MAX_FRAME:
        raise RuntimeError("native process inventory exceeded bound")
    table = {}
    for line in result.stdout.splitlines():
        pid, parent, group, state = line.split(maxsplit=3)
        table[int(pid)] = (int(parent), int(group), state.decode("ascii"))
    return table


class NativeRuntime:
    """One in-flight operation, with close able to interrupt that operation.

    The supervisor is our child; its independently grouped GPU worker is its
    child. Normal shutdown lets the supervisor reap it. Escalation kills the
    worker group before killing the supervisor and verifies neither can run.
    A failed reap keeps ownership and prevents a new lifetime from starting.
    """

    def __init__(self, package: NativePackage):
        self.package = package
        self.ready: dict[str, Any] = {}
        self.unhealthy = False
        self.pid: int | None = None
        self._loaded = False
        self._process: asyncio.subprocess.Process | None = None
        self._spawn_task: asyncio.Task | None = None
        self._workers: set[int] = set()
        self._messages: asyncio.Queue | None = None
        self._reader_task: asyncio.Task | None = None
        self._stop_task: asyncio.Task | None = None
        self._background_stop: asyncio.Task | None = None
        self._lock = asyncio.Lock()
        self._epoch = 0
        self._counter = 0
        self._cancelled_ids: set[str] = set()

    @property
    def loaded(self) -> bool:
        return self._loaded and self._process is not None and self._process.returncode is None

    @staticmethod
    def _notify(queue: asyncio.Queue, value: Any) -> None:
        # Terminal failure replaces queued data; no stale EOS can escape.
        while not queue.empty():
            queue.get_nowait()
        queue.put_nowait(value)

    async def _read_output(self, process, queue) -> None:
        try:
            while True:
                line = await process.stdout.readline()
                if not line or not line.endswith(b"\n"):
                    raise RuntimeError("native supervisor output EOF")
                if len(line) > MAX_FRAME + 1:
                    raise RuntimeError("native response frame exceeded 1 MiB")
                value = _json_object(line)
                if not isinstance(value.get("event"), str):
                    raise ValueError("native response event must be a string")
                if "id" in value and (not isinstance(value["id"], str) or not 1 <= len(value["id"]) <= 128):
                    raise ValueError("native response id must be a bounded string")
                if value.get("event") in {"fatal", "supervisor_failure"}:
                    raise RuntimeError("native process reported failure")
                queue.put_nowait(value)
        except asyncio.CancelledError:
            raise
        except (OSError, ValueError, RuntimeError, RecursionError, asyncio.QueueFull) as exc:
            self._notify(queue, RuntimeError("native transport failed: " + type(exc).__name__))
            if self._process is process and not (self._stop_task and not self._stop_task.done()):
                self.unhealthy = True
                self._background_stop = asyncio.create_task(self._retire_background(process))

    async def _retire_background(self, process) -> None:
        if self._process is process:
            with contextlib.suppress(RuntimeError):
                await self._retire()

    async def _receive(self, deadline: float, cancel_event=None) -> dict:
        while True:
            if cancel_event is not None and cancel_event.is_set():
                raise asyncio.CancelledError
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("native receive deadline")
            try:
                value = await asyncio.wait_for(self._messages.get(), min(POLL_S, remaining))
            except TimeoutError:
                continue
            if isinstance(value, Exception):
                # Other waiters must observe the same terminal failure.
                self._notify(self._messages, value)
                raise value
            return value

    async def _write(self, process, value: dict, deadline: float) -> None:
        data = (json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
        if len(data) > MAX_FRAME + 1:
            raise ValueError("native request frame exceeded 1 MiB")
        remaining = min(WRITE_TIMEOUT_S, deadline - time.monotonic())
        if remaining <= 0:
            raise TimeoutError("native write deadline")
        process.stdin.write(data)
        await asyncio.wait_for(process.stdin.drain(), remaining)

    async def _remember_workers(self, process) -> dict[int, tuple[int, int, str]]:
        table = await asyncio.to_thread(_process_table)
        descendants = {process.pid}
        for _ in range(4):
            descendants.update(pid for pid, (parent, _group, _state) in table.items() if parent in descendants)
        self._workers.update(
            pid for pid in descendants - {process.pid}
            if table[pid][1] == pid
        )
        return table

    async def _check_ready(self, value: dict, process) -> None:
        expected = {
            "event": "ready", "protocol": 1, "model_sha256": MODEL_SHA256,
            "llama_commit": LLAMA_COMMIT, "architecture": "lfm3",
            "context_tokens": CONTEXT_TOKENS, "copy_draft": True,
            "copy_draft_max": DRAFT_TOKENS, "prefix_reuse": True,
            "prefill_batch_tokens": 128, "max_output_tokens": MAX_OUTPUT_TOKENS,
            "batch_tokens": 128, "ubatch_tokens": 128, "swa_full": True,
            "max_rss_mb": 8192,
            "student_prefix_cache": False, "research_long_context": False,
            "recurrent_rollback": False, "recurrent_snapshots": 0,
            "bounded_swa": False, "backend_token_only": False,
            "sampling": "upstream_cpu_greedy", "trace_runtime": False,
        }
        for key, expected_value in expected.items():
            if type(value.get(key)) is not type(expected_value) or value[key] != expected_value:
                raise RuntimeError("native ready mismatch: " + key)
        pid = value.get("pid")
        if type(pid) is not int or pid <= 1 or pid in {os.getpid(), process.pid}:
            raise RuntimeError("native ready mismatch: pid")
        table = await self._remember_workers(process)
        if pid not in self._workers or table[pid][0] != process.pid or table[pid][2].startswith("Z"):
            raise RuntimeError("native ready worker ownership mismatch")
        self.pid = pid

    async def load(self, cancel_event=None) -> dict:
        async with self._lock:
            return await self._load_locked(cancel_event)

    async def _load_locked(self, cancel_event=None) -> dict:
        if self._stop_task is not None:
            await self._wait_stop(self._stop_task)
        if self.loaded:
            return self.ready
        if cancel_event is not None and cancel_event.is_set():
            raise asyncio.CancelledError
        if self._process is not None:
            await self._retire()
        epoch = self._epoch
        try:
            await asyncio.to_thread(self.package.verify)
            if epoch != self._epoch or (cancel_event is not None and cancel_event.is_set()):
                raise asyncio.CancelledError
            command = [
                sys.executable, str(self.package.supervisor_path),
                str(self.package.binary_path), str(self.package.model_path), MODEL_SHA256,
                "--context", str(CONTEXT_TOKENS), "--max-rss-mb", "8192",
                "--copy-draft", "--draft-max", str(DRAFT_TOKENS), "--prefix-cache",
                "--prefill-batch", "128", "--max-output-tokens", str(MAX_OUTPUT_TOKENS),
                "--startup-deadline-ms", str(max(1, min(120000, int(LOAD_TIMEOUT_S * 1000)))),
                "--hard-grace-ms", str(max(0, min(10000, int(HARD_GRACE_S * 1000)))),
            ]
            # Shield spawn so cancellation cannot lose a child between fork and
            # receiving its Process handle. Finish acquiring it before teardown.
            self._spawn_task = asyncio.create_task(asyncio.create_subprocess_exec(
                *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, start_new_session=True, limit=MAX_FRAME + 1,
            ))
            process = await asyncio.wait_for(asyncio.shield(self._spawn_task), SPAWN_TIMEOUT_S)
            self._process = process
            if epoch != self._epoch:
                raise RuntimeError("native load was closed")
            self._messages = asyncio.Queue(maxsize=4)
            self._reader_task = asyncio.create_task(self._read_output(process, self._messages))
            ready = await self._receive(time.monotonic() + LOAD_TIMEOUT_S + RESPONSE_GRACE_S, cancel_event)
            await self._check_ready(ready, process)
            if epoch != self._epoch:
                raise RuntimeError("native load was closed")
            self.ready = ready
            self._loaded = True
            self.unhealthy = False
            return ready
        except BaseException as exc:
            self.unhealthy = not isinstance(exc, asyncio.CancelledError)
            await self._retire()
            raise

    @staticmethod
    def _validate_request(system, user, max_tokens, deadline_ms, draft_text) -> None:
        for key, value, limit, empty in (
            ("system", system, 16384, False), ("user", user, 65536, False),
            ("draft_text", draft_text, 65536, True),
        ):
            if not isinstance(value, str) or (not empty and not value) or len(value.encode("utf-8")) > limit:
                raise ValueError("invalid native request field: " + key)
        if type(max_tokens) is not int or not 1 <= max_tokens <= MAX_OUTPUT_TOKENS:
            raise ValueError("invalid native max_tokens")
        if type(deadline_ms) is not int or not 1 <= deadline_ms <= 120000:
            raise ValueError("invalid native deadline_ms")

    async def generate(self, system, user, *, max_tokens, deadline_ms, draft_text="", cancel_event=None) -> dict:
        self._validate_request(system, user, max_tokens, deadline_ms, draft_text)
        if cancel_event is not None and cancel_event.is_set():
            return {"event": "result", "status": "cancelled", "text": "", "partial_text": ""}
        async with self._lock:
            self._counter += 1
            identity = "native-" + str(self._counter)
            try:
                if self.unhealthy:
                    return {"event": "error", "status": "native_unhealthy", "text": "", "partial_text": ""}
                await self._load_locked(cancel_event)
                process = self._process
                end = time.monotonic() + deadline_ms / 1000 + HARD_GRACE_S + RESPONSE_GRACE_S
                await self._write(process, {
                    "op": "generate", "id": identity, "system": system, "user": user,
                    "max_tokens": max_tokens, "deadline_ms": deadline_ms, "draft_text": draft_text,
                }, end)
                cancelled = False
                while True:
                    if cancel_event is not None and cancel_event.is_set() and not cancelled:
                        cancelled = True
                        end = min(end, time.monotonic() + CANCEL_GRACE_S + RESPONSE_GRACE_S)
                        if len(self._cancelled_ids) >= 8:
                            raise RuntimeError("native cancellation acknowledgements missing")
                        self._cancelled_ids.add(identity)
                        await self._write(process, {"op": "cancel", "id": identity}, end)
                    try:
                        response = await self._receive(min(end, time.monotonic() + POLL_S))
                    except TimeoutError:
                        if time.monotonic() < end:
                            continue
                        raise
                    event = response.get("event")
                    if event == "cancel_ack" and response.get("id") in self._cancelled_ids:
                        self._cancelled_ids.discard(response["id"])
                        continue
                    if response.get("id") != identity:
                        raise RuntimeError("native response identity mismatch")
                    if event not in {"result", "error"}:
                        raise RuntimeError("unexpected native response event")
                    if event == "result" and not isinstance(response.get("status"), str):
                        raise RuntimeError("native result status missing")
                    if event == "error":
                        response.setdefault("status", "native_request_error")
                    if cancelled or (cancel_event is not None and cancel_event.is_set()):
                        response["status"] = "cancelled"
                    if response.get("status") != "eos" or event != "result":
                        response["text"] = ""
                    elif not isinstance(response.get("text"), str):
                        raise RuntimeError("native result text missing")
                    response["partial_text"] = ""
                    return response
            except asyncio.CancelledError:
                await self._retire()
                raise
            except (OSError, ValueError, RuntimeError, TimeoutError) as exc:
                self.unhealthy = True
                await self._retire()
                return {"event": "error", "id": identity, "status": "native_transport_failure",
                        "error_type": type(exc).__name__, "text": "", "partial_text": ""}

    async def _wait_stop(self, task) -> None:
        cancelled = False
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                cancelled = True
        task.result()
        if cancelled:
            raise asyncio.CancelledError

    async def _retire(self) -> None:
        if self._stop_task is None or self._stop_task.done():
            self._epoch += 1
            self._loaded = False
            self.ready = {}
            if self._messages is not None:
                self._notify(self._messages, RuntimeError("native runtime closed"))
            self._stop_task = asyncio.create_task(self._stop(self._process))
        await self._wait_stop(self._stop_task)

    async def aclose(self) -> None:
        await self._retire()

    async def _stop(self, process) -> None:
        if process is None and self._spawn_task is not None:
            try:
                process = await asyncio.wait_for(asyncio.shield(self._spawn_task), SPAWN_TIMEOUT_S)
                self._process = process
            except TimeoutError as exc:
                self.unhealthy = True
                raise RuntimeError("native spawn did not settle; ownership retained") from exc
            except Exception:
                # A failed create_subprocess_exec owns no child handle.
                self._spawn_task = None
                return
        if process is None:
            return
        if self._reader_task is not None:
            self._reader_task.cancel()
            await asyncio.gather(self._reader_task, return_exceptions=True)

        async def drain():
            while await process.stdout.read(65536):
                pass

        draining = asyncio.create_task(drain())

        async def wait_for_exit(seconds):
            end = time.monotonic() + seconds
            while True:
                table = await self._remember_workers(process)
                running = [pid for pid in self._workers if pid in table and not table[pid][2].startswith("Z")]
                if process.returncode is not None and not running:
                    await asyncio.wait_for(process.wait(), max(.01, end - time.monotonic()))
                    return True
                if time.monotonic() >= end:
                    return False
                await asyncio.sleep(POLL_S)

        async def send_group(pid, signum):
            table = await asyncio.to_thread(_process_table)
            entry = table.get(pid)
            if entry is None or entry[2].startswith("Z"):
                return
            if entry[1] != pid:
                raise RuntimeError("native process group identity changed; ownership retained")
            with contextlib.suppress(ProcessLookupError):
                os.killpg(pid, signum)

        try:
            await self._remember_workers(process)
            if process.returncode is None:
                with contextlib.suppress(OSError, RuntimeError, TimeoutError):
                    await self._write(process, {"op": "shutdown"}, time.monotonic() + WRITE_TIMEOUT_S)
            done = await wait_for_exit(SHUTDOWN_GRACE_S)
            if not done:
                await send_group(process.pid, signal.SIGTERM)
                for pid in self._workers:
                    await send_group(pid, signal.SIGTERM)
                done = await wait_for_exit(TERMINATE_GRACE_S)
            if not done:
                # Give the owner a chance to reap its child before its own KILL.
                for pid in self._workers:
                    await send_group(pid, signal.SIGKILL)
                done = await wait_for_exit(KILL_GRACE_S)
            if not done:
                await send_group(process.pid, signal.SIGKILL)
                done = await wait_for_exit(KILL_GRACE_S)
            if not done:
                self.unhealthy = True
                raise RuntimeError("native processes did not exit; ownership retained")
            self._process = None
            self._spawn_task = None
            self._workers.clear()
            self._cancelled_ids.clear()
            self.pid = None
            self._reader_task = None
        except (OSError, subprocess.SubprocessError) as exc:
            self.unhealthy = True
            raise RuntimeError("could not verify native process exit; ownership retained") from exc
        finally:
            if process.stdin is not None:
                process.stdin.close()
            draining.cancel()
            await asyncio.gather(draining, return_exceptions=True)
