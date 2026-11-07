"""Real, independently grouped processes for native client tests; no GPU/model."""

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


def record(**value):
    path = os.environ.get("VELORA_FAKE_NATIVE_TRACE")
    if path:
        with open(path, "a") as stream:
            stream.write(json.dumps(value) + "\n")


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    if "--child" in sys.argv:
        if os.environ.get("VELORA_FAKE_NATIVE_MODE") in {"stubborn", "startup_stubborn"}:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        # Exit even if a failed assertion abandons this fixture.
        time.sleep(30)
        return
    child = subprocess.Popen(
        [sys.executable, __file__, "--child"], start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    )
    record(supervisor=os.getpid(), worker=child.pid, args=sys.argv[1:])
    mode = os.environ.get("VELORA_FAKE_NATIVE_MODE", "")

    def terminate(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, signal.SIG_IGN if mode in {"stubborn", "startup_stubborn"} else terminate)
    try:
        if mode in {"startup_hang", "startup_stubborn"}:
            time.sleep(30)
            return
        ready = {
            "event": "ready", "pid": child.pid, "protocol": 1,
            "model_sha256": sys.argv[3],
            "llama_commit": "4b77dee0524c64b8471869232e2958bd9589607d",
            "architecture": "lfm3", "context_tokens": 4096,
            "batch_tokens": 128, "ubatch_tokens": 128, "swa_full": True,
            "max_rss_mb": 8192,
            "prefill_batch_tokens": 128, "max_output_tokens": 512,
            "copy_draft": True, "copy_draft_max": 8, "prefix_reuse": True,
            "student_prefix_cache": False, "research_long_context": False,
            "recurrent_rollback": False, "recurrent_snapshots": 0,
            "bounded_swa": False, "backend_token_only": False,
            "trace_runtime": False, "sampling": "upstream_cpu_greedy",
        }
        ready.update(json.loads(os.environ.get("VELORA_FAKE_NATIVE_READY", "{}")))
        emit(ready)
        pending = None
        started = time.monotonic()
        while time.monotonic() - started < 25:
            if not select.select([sys.stdin], [], [], .05)[0]:
                continue
            line = sys.stdin.readline()
            if not line:
                break
            request = json.loads(line)
            operation = request["op"]
            record(op=operation)
            if operation == "shutdown":
                if mode == "stubborn":
                    continue
                break
            if operation == "cancel":
                if mode == "cancel_result_first":
                    emit({"event": "result", "id": request["id"], "status": "eos", "text": "unsafe"})
                    emit({"event": "cancel_ack", "id": request["id"], "matched": False})
                    mode = ""
                    continue
                emit({"event": "cancel_ack", "id": request["id"], "matched": True})
                if mode != "ignore_cancel":
                    emit({"event": "result", "id": request["id"],
                          "status": "eos" if mode == "cancel_race" else "cancelled",
                          "text": "unsafe cancelled text", "partial_text": "private partial"})
                continue
            if operation != "generate":
                continue
            pending = request["id"]
            if mode == "eof":
                os.close(sys.stdout.fileno())
                time.sleep(30)
            elif mode == "malformed":
                print("not JSON", flush=True)
            elif mode == "oversize":
                print("x" * (1024 * 1024 + 1), flush=True)
            elif mode == "truncated":
                sys.stdout.write('{"event":"result"}')
                sys.stdout.flush()
                os.close(sys.stdout.fileno())
                time.sleep(30)
            elif mode in {"hang", "ignore_cancel", "cancel_race", "cancel_result_first", "stubborn"}:
                continue
            elif mode == "wrong_id":
                emit({"event": "result", "id": "other", "status": "eos", "text": "wrong"})
            elif mode == "invalid_id":
                emit({"event": "cancel_ack", "id": {"bad": True}})
            elif mode == "invalid_event":
                emit({"event": [], "id": pending})
            elif mode == "error":
                emit({"event": "error", "id": pending, "error": "context_limit",
                      "text": "unsafe", "partial_text": "unsafe"})
            else:
                status = request["user"] if request["user"] in {"length", "deadline", "context_limit"} else "eos"
                emit({"event": "result", "id": pending, "status": status,
                      "text": "Ready." if status == "eos" else "unsafe failed text",
                      "partial_text": "private partial", "prompt_tokens": [1, 2],
                      "output_tokens": [3], "elapsed_ms": 2.5})
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == "__main__":
    main()
