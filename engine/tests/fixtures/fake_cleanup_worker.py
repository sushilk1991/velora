"""Protocol fixture for CleanupProcess tests; never imported by production."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import socket
from pathlib import Path


async def main(
    fd: int,
    fail_next_replacement: Path | None = None,
    fail_all_replacements: Path | None = None,
) -> None:
    sock = socket.socket(fileno=fd)
    sock.setblocking(False)
    reader, writer = await asyncio.open_connection(sock=sock)
    cancelled: set[str] = set()
    tasks: set[asyncio.Task[None]] = set()

    async def respond(request_id: str, **payload) -> None:
        writer.write((json.dumps({"id": request_id, **payload}) + "\n").encode())
        await writer.drain()

    async def handle(message: dict) -> None:
        request_id = message["id"]
        operation = message["op"]
        if operation == "load":
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
            return
        if operation == "prepare_prefix":
            if message.get("candidates", [[None]])[0][0] == "__hang__":
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True:
                    pass
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
            await respond(
                request_id,
                ok=True,
                result={"applied": True, "tokens": 12, "ms": 3, "reason": None},
            )
            return
        raw = message["raw"]
        if raw == "__crash__":
            os._exit(17)
        if "__hang__" in raw:
            # Native-style hard wedge: retain the child GIL, ignore protocol
            # cancellation, and ignore SIGTERM so the parent must SIGKILL.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                pass
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
        else:
            result = {
                "text": raw.upper(),
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
    args = parser.parse_args()
    asyncio.run(
        main(
            args.fd,
            args.fail_next_replacement,
            args.fail_all_replacements,
        )
    )
