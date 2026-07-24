"""Private cleanup-model worker process.

This is launched only by :mod:`velora_engine.cleanup_process`.  Protocol
traffic uses an inherited socket descriptor, leaving stdout/stderr available
for the normal engine log and third-party model diagnostics.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import socket
import threading
from dataclasses import asdict
from typing import Any

from .cleanup import CleanupEngine

log = logging.getLogger("velora.cleanup_worker")


class Worker:
    def __init__(
        self,
        model_id: str,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        self.engine = CleanupEngine(model_id)
        self.reader = reader
        self.writer = writer
        self._write_lock = asyncio.Lock()
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._cancel_events: dict[str, threading.Event] = {}

    async def serve(self) -> None:
        while line := await self.reader.readline():
            try:
                message = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                log.error("ignoring malformed parent message")
                continue
            operation = message.get("op")
            if operation == "cancel":
                target = message.get("target")
                if isinstance(target, str):
                    event = self._cancel_events.get(target)
                    if event is not None:
                        event.set()
                continue
            request_id = message.get("id")
            if not isinstance(request_id, str) or not isinstance(operation, str):
                continue
            task = asyncio.create_task(self._run(request_id, operation, message))
            self._tasks[request_id] = task
            task.add_done_callback(lambda _task, key=request_id: self._tasks.pop(key, None))
        # Parent disappeared. Do not let a wedged non-daemon MLX executor keep
        # this orphan alive indefinitely.
        os._exit(0)

    async def _run(
        self,
        request_id: str,
        operation: str,
        message: dict[str, Any],
    ) -> None:
        cancel_event = threading.Event()
        self._cancel_events[request_id] = cancel_event
        try:
            if operation == "ping":
                await self._respond(request_id, ok=True)
                return
            if operation == "load":
                await self.engine.load_async(message.get("warm_system_prompt"))
                await self._respond(request_id, ok=True)
                return
            if operation == "cleanup":
                raw = str(message.get("raw") or "")
                prompt = str(message.get("system_prompt") or "")
                result = await self.engine.cleanup(
                    raw,
                    prompt,
                    timeout_ms=int(message["timeout_ms"]),
                    check_ratio=bool(message.get("check_ratio", True)),
                    cancel_event=cancel_event,
                    allowed_terms=message.get("allowed_terms"),
                )
                await self._respond(request_id, ok=True, result=asdict(result))
                return
            if operation == "prepare_prefix":
                raw_candidates = message.get("candidates")
                candidates = [
                    (str(item[0]), str(item[1]))
                    for item in (raw_candidates or [])
                    if isinstance(item, (list, tuple)) and len(item) == 2
                ]
                result = await self.engine.prepare_prefix(candidates, cancel_event)
                await self._respond(request_id, ok=True, result=asdict(result))
                return
            await self._respond(request_id, ok=False, error=f"unknown operation {operation!r}")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.exception("cleanup worker operation failed")
            await self._respond(request_id, ok=False, error=str(exc))
        finally:
            self._cancel_events.pop(request_id, None)

    async def _respond(self, request_id: str, **payload: Any) -> None:
        async with self._write_lock:
            self.writer.write(
                (json.dumps({"id": request_id, **payload}, ensure_ascii=False) + "\n").encode()
            )
            await self.writer.drain()


async def _amain(args: argparse.Namespace) -> None:
    sock = socket.socket(fileno=args.fd)
    sock.setblocking(False)
    reader, writer = await asyncio.open_connection(sock=sock)
    worker = Worker(args.model, reader, writer)
    try:
        await worker.serve()
    finally:
        worker.engine.close()
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--fd", required=True, type=int)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname).1s %(name)s %(message)s",
        datefmt="%H:%M:%S",
    )
    asyncio.run(_amain(args))


if __name__ == "__main__":
    main()
