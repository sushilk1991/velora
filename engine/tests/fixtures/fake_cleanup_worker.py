"""Protocol fixture for CleanupProcess tests; never imported by production."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import signal
import socket
import subprocess
import threading
import time
from collections.abc import Iterable
from pathlib import Path
from typing import NoReturn

from velora_engine.cleanup_ipc import (
    CLEANUP_IPC_STREAM_LIMIT_BYTES,
    encode_cleanup_ipc_message,
)

# Each worker drops a file named by its pid here, so the pytest session can
# SIGKILL any worker a test leaked (tests/conftest.py).
PID_DIR_ENV = "VELORA_FAKE_WORKER_PID_DIR"
# A worker orphaned by a dead pytest notices within this poll.
ORPHAN_POLL_S = 0.2
# A fixture worker leaked by a live pytest exits after this long.
MAX_LIFETIME_S = 120.0
# A cleanup whose raw text holds "__notes__" answers with these meeting notes.
NOTES_JSON = json.dumps({"summary": "Notes.", "decisions": [], "action_items": []})


def wedge_like_native_code(marker_dir: Path | None = None) -> NoReturn:
    """Stop serving the way a native call that never returns does.

    The event loop blocks, so protocol cancels go unread, and SIGTERM is
    ignored, so only SIGKILL ends the worker. It sleeps rather than spins,
    so a worker a test leaks costs no CPU. With `marker_dir`, it touches
    marker_dir/<pid> once only SIGKILL ends it, to tell the test.
    """
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if marker_dir is not None:
        (marker_dir / str(os.getpid())).touch()
    while True:
        time.sleep(3600)


def exit_when_abandoned(parent_pid: int, max_lifetime_s: float) -> None:
    """Exit once the spawning process is gone or the lifetime cap passes.

    Runs on a daemon thread, so it fires while the event loop is wedged:

        pytest dies  ->  worker reparented (getppid changes)  ->  exit
        pytest lives but leaked it  ->  max_lifetime_s passes  ->  exit
    """
    deadline = time.monotonic() + max_lifetime_s
    while os.getppid() == parent_pid and time.monotonic() < deadline:
        time.sleep(ORPHAN_POLL_S)
    os._exit(0)


def register_pid() -> None:
    """Record this worker for the session cleanup, when a session runs one."""
    pid_dir = os.environ.get(PID_DIR_ENV)
    if pid_dir:
        (Path(pid_dir) / str(os.getpid())).touch()


def kill_leaked(pid_dir: Path) -> list[int]:
    """SIGKILL every registered worker still alive; returns their pids."""
    return kill_workers(int(entry.name) for entry in pid_dir.iterdir())


def kill_workers(pids: Iterable[int]) -> list[int]:
    """SIGKILL each of `pids` that is still a fixture worker; returns those.

    A test calls this in `finally`, so a failed check leaves no worker that
    ignores SIGTERM running into later tests.
    """
    killed = []
    for pid in pids:
        if not _is_fixture_worker(pid):
            continue
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGKILL)
            killed.append(pid)
    return killed


def _is_fixture_worker(pid: int) -> bool:
    # A registered pid that exited may since belong to another process; an
    # exited but unreaped worker shows no command line.
    command = subprocess.run(
        ["ps", "-o", "command=", "-p", str(pid)],
        capture_output=True, text=True, check=False,
    ).stdout
    return Path(__file__).name in command


async def main(
    fd: int,
    fail_next_replacement: Path | None = None,
    fail_all_replacements: Path | None = None,
    exit_after_load: bool = False,
    hang_first_load: Path | None = None,
    fail_every_load: bool = False,
    prefix_delay_s: float = 0.0,
    hang_prefix: bool = False,
    load_delay_s: float = 0.0,
    hang_every_load: bool = False,
    wedge_second_load: Path | None = None,
    fail_first_load: Path | None = None,
    model: str = "",
    fail_load_for: str | None = None,
    hang_marker_dir: Path | None = None,
) -> None:
    sock = socket.socket(fileno=fd)
    sock.setblocking(False)
    reader, writer = await asyncio.open_connection(
        sock=sock,
        limit=CLEANUP_IPC_STREAM_LIMIT_BYTES,
    )
    cancelled: set[str] = set()
    tasks: set[asyncio.Task[None]] = set()

    async def respond(request_id: str, **payload) -> None:
        writer.write(encode_cleanup_ipc_message({"id": request_id, **payload}))
        await writer.drain()

    async def handle(message: dict) -> None:
        request_id = message["id"]
        operation = message["op"]
        if operation == "load":
            if fail_every_load or (fail_load_for is not None and model == fail_load_for):
                await respond(request_id, ok=False, error="injected persistent load failure")
                return
            if hang_first_load is not None and not hang_first_load.exists():
                # A load that outlives LOAD_TIMEOUT_S; the next worker loads.
                hang_first_load.touch()
                await asyncio.sleep(3600)
            if fail_first_load is not None and not fail_first_load.exists():
                fail_first_load.touch()
                await respond(request_id, ok=False, error="injected first load failure")
                return
            if hang_every_load:
                # A load that never returns and that only SIGKILL ends. It
                # blocks the loop: an asyncio sleep here left the loop free
                # to read EOF when the parent closed the socket, and exit.
                wedge_like_native_code(hang_marker_dir)
            if wedge_second_load is not None:
                # Loads 1 and 3+ succeed; load 2 wedges like native code:
                # it blocks and ignores SIGTERM, so only SIGKILL ends it.
                if not wedge_second_load.exists():
                    wedge_second_load.write_text("1")
                elif wedge_second_load.read_text() == "1":
                    # Ignore SIGTERM before the marker tells the test it wedged.
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    wedge_second_load.write_text("2")
                    wedge_like_native_code()
            if load_delay_s:
                await asyncio.sleep(load_delay_s)
            if fail_all_replacements is not None:
                if fail_all_replacements.exists():
                    await respond(request_id, ok=False, error="injected persistent load failure")
                    return
                fail_all_replacements.touch()
            if fail_next_replacement is not None:
                if not fail_next_replacement.exists():
                    fail_next_replacement.write_text("armed")
                elif fail_next_replacement.read_text() == "armed":
                    fail_next_replacement.write_text("failed")
                    await respond(request_id, ok=False, error="injected load failure")
                    return
            await respond(request_id, ok=True)
            if exit_after_load:
                # Crash loop: every worker loads, then dies before serving.
                asyncio.get_running_loop().call_later(0.05, os._exit, 17)
            return
        if operation == "prepare_prefix":
            if hang_prefix or message.get("candidates", [[None]])[0][0] == "__hang__":
                wedge_like_native_code()
            if message.get("candidates", [[None]])[0][0] == "__cancel__":
                while request_id not in cancelled:
                    await asyncio.sleep(0.01)
                await respond(
                    request_id,
                    ok=True,
                    result={
                        "applied": False,
                        "tokens": 0,
                        "ms": 12,
                        "reason": "cancelled",
                    },
                )
                return
            if prefix_delay_s:
                # A slow but progressing warm-up that ignores cancellation.
                await asyncio.sleep(prefix_delay_s)
            await respond(
                request_id,
                ok=True,
                result={"applied": True, "tokens": 12, "ms": 3, "reason": None},
            )
            return
        if operation == "decide":
            if message.get("state") == "__hang__":
                wedge_like_native_code()
            if message.get("state") == "__cancel__":
                while request_id not in cancelled:
                    await asyncio.sleep(0.01)
                await respond(request_id, ok=True,
                              result={"status": "cancelled", "ms": 12})
                return
            # Always the first option, with the question count as ms so the
            # parent can see what crossed the pipe.
            answers = {
                question["key"]: {
                    "choice": question["options"][0][0],
                    "probabilities": {question["options"][0][0]: 1.0},
                    "label_mass": 0.9,
                }
                for question in message["questions"]
            }
            await respond(request_id, ok=True, result={
                "status": "ok", "answers": answers,
                "ms": len(message["questions"]),
                "state_tokens": message.get("max_input_tokens") or 0,
            })
            return
        if operation == "memory":
            await respond(
                request_id,
                ok=True,
                result={
                    "active_bytes": 500_000_000,
                    "peak_bytes": 750_000_000,
                    "cache_bytes": 25_000_000,
                },
            )
            return
        if operation in {"release_cache", "release_action_memory"}:
            await respond(request_id, ok=True)
            return
        raw = message["raw"]
        if raw == "__malformed__":
            writer.write(b"not json\n")
            await writer.drain()
            return
        if raw == "__crash__":
            os._exit(17)
        if "__hang__" in raw:
            # Native-style hard wedge: ignore protocol cancellation and
            # SIGTERM, so the parent must SIGKILL.
            wedge_like_native_code(hang_marker_dir)
        if raw == "__cancel__":
            while request_id not in cancelled:
                await asyncio.sleep(0.01)
            result = {
                "text": raw,
                "applied": False,
                "ms": 12,
                "reason": "cancelled",
                "ttft_ms": 0,
                "decode_ms": 0,
                "prefix_tokens": 0,
                "output_tokens": 0,
                "cache_hit": False,
            }
        elif raw in {"__child_timeout__", "__child_timeout_boundary__"}:
            if raw == "__child_timeout_boundary__":
                # The matching test configures a 50ms request + 50ms child
                # hard-wall grace. Serialize 20ms beyond that old parent
                # deadline: only the IPC delivery margin can preserve this
                # authoritative child result.
                await asyncio.sleep(message["timeout_ms"] / 1000.0 + 0.07)
            result = {
                "text": raw,
                "applied": False,
                "ms": 12,
                "reason": "timeout_hard",
                "ttft_ms": 0,
                "decode_ms": 0,
                "prefix_tokens": 0,
                "output_tokens": 0,
                "cache_hit": False,
            }
        else:
            result = {
                "text": (str(message.get("max_input_tokens"))
                         if raw == "__limits__"
                         else str(message.get("copy_draft"))
                         if raw == "__copy_draft__"
                         else NOTES_JSON if "__notes__" in raw
                         else raw.upper()),
                "applied": True,
                "ms": 7,
                "reason": None,
                "ttft_ms": 2,
                "decode_ms": 5,
                "prefix_tokens": 10,
                "output_tokens": 2,
                "cache_hit": True,
            }
        await respond(request_id, ok=True, result=result)

    while line := await reader.readline():
        message = json.loads(line)
        if message.get("op") == "cancel":
            cancelled.add(message["target"])
            continue
        task = asyncio.create_task(handle(message))
        tasks.add(task)
        task.add_done_callback(tasks.discard)
    os._exit(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fd", required=True, type=int)
    parser.add_argument("--model", required=True)
    parser.add_argument("--fail-next-replacement", type=Path)
    parser.add_argument("--fail-all-replacements", type=Path)
    parser.add_argument("--exit-after-load", action="store_true")
    parser.add_argument("--hang-first-load", type=Path)
    parser.add_argument("--fail-every-load", action="store_true")
    parser.add_argument("--prefix-delay", type=float, default=0.0)
    parser.add_argument("--hang-prefix", action="store_true")
    parser.add_argument("--load-delay", type=float, default=0.0)
    parser.add_argument("--hang-every-load", action="store_true")
    # A hung load or __hang__ cleanup touches <dir>/<pid> once it ignores
    # SIGTERM.
    parser.add_argument("--hang-marker-dir", type=Path)
    parser.add_argument("--wedge-second-load", type=Path)
    parser.add_argument("--fail-first-load", type=Path)
    # Every load of this one model fails; other models load.
    parser.add_argument("--fail-load-for")
    parser.add_argument("--max-lifetime", type=float, default=MAX_LIFETIME_S)
    args = parser.parse_args()
    register_pid()
    threading.Thread(
        target=exit_when_abandoned,
        args=(os.getppid(), args.max_lifetime),
        daemon=True,
    ).start()
    asyncio.run(
        main(
            args.fd,
            args.fail_next_replacement,
            args.fail_all_replacements,
            args.exit_after_load,
            args.hang_first_load,
            args.fail_every_load,
            args.prefix_delay,
            args.hang_prefix,
            args.load_delay,
            args.hang_every_load,
            args.wedge_second_load,
            args.fail_first_load,
            args.model,
            args.fail_load_for,
            args.hang_marker_dir,
        )
    )
