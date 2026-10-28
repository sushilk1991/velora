#!/usr/bin/env python3
"""Cold and warm latency of production-shaped decision calls, one model per process.

    python latency.py letters MODEL_PATH ITEMS.jsonl OUT.jsonl   # Qwen, engine venv
    python latency.py native  MODEL_PATH ITEMS.jsonl OUT.jsonl   # d1, mlx-vlm venv

Three call shapes, each the way production asks it:

    turn1   the `delivers` question over the turn-1 STATE      ~100 tokens
    press   the navigate-vs-answer press check                 ~150 tokens
    screen  a WhatsApp element pick (bench62 chat_pick)        ~550 tokens

Each call is one question with its whole STATE. Production asks turn 1's
two questions over one shared state (the 4B forks a prefilled snapshot, d1
packs both into one set-attention pass), so the second costs much less
than the first; per-question latency is the comparable unit.

"cold" is the first call after the weights load (kernels compile there);
"warm" is 15 repeats after it. The Qwen arm runs each question as its own
full forward pass, so it pays the system prompt the engine would serve from
its prefix cache (77 tokens): an upper bound on the engine's number. Every
call records load1, so run arms A-B-B-A and compare pairs at equal load.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

WARM = 15
SHAPES = {"turn1": "delivers-1", "press": "press-1", "screen": "chat_pick-1"}


def main() -> int:
    arm, model_path, items_path, out_path = sys.argv[1:5]
    items = {json.loads(line)["id"]: json.loads(line) for line in open(items_path)}
    from run_decisions import ARMS

    t0 = time.perf_counter()
    score, mx = ARMS[arm](model_path)
    load_ms = (time.perf_counter() - t0) * 1000

    def call(shape: str) -> float:
        item = items[SHAPES[shape]]
        started = time.perf_counter()
        score(item)
        return (time.perf_counter() - started) * 1000

    with open(out_path, "a") as stream:
        for index, shape in enumerate(SHAPES):
            cold = call(shape)
            warm = [call(shape) for _ in range(WARM)]
            stream.write(json.dumps({
                "arm": arm, "model": model_path, "shape": shape,
                "cold_ms": round(cold, 1), "warm_ms": [round(w, 1) for w in warm],
                "first_shape_after_load": index == 0, "load_ms": round(load_ms),
                "load1": round(os.getloadavg()[0], 2),
                "mlx_active": int(mx.get_active_memory()), "mlx_peak": int(mx.get_peak_memory()),
            }) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
