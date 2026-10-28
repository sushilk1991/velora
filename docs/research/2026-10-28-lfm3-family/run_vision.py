#!/usr/bin/env python3
"""Ask d1 the screen-state question of every screenshot in vision_set.jsonl.

    python run_vision.py MODEL_PATH VISION_SET.jsonl OUT.jsonl   # mlx-vlm venv

One `noul` per screenshot, the screenshot as the whole state (d1's own
"pictures are the state" form, `state=None`).
"""

from __future__ import annotations

import json
import os
import sys
import time

QUESTIONS = {
    "modal": "Is a dialog or alert open on top of the app, covering its content?",
    "loaded": "Has the page finished loading its content?",
}


def main() -> int:
    import mlx.core as mx
    from mlx_vlm import load

    model_path, set_path, out_path = sys.argv[1:4]
    model, _ = load(model_path)
    shots = [json.loads(line) for line in open(set_path)]

    def ask(shot: dict) -> dict:
        out = model.system_one(None, {"q": {"type": "noul", "instructions": QUESTIONS[shot["q"]]}},
                               media=[{"type": "image", "path": shot["path"]}])
        return {"p_yes": float(out["answers"]["q"]["noul"]), "tokens": int(out["usage"]["input_tokens"])}

    ask(shots[0])  # warm-up
    with open(out_path, "w") as stream:
        for shot in shots:
            t0 = time.perf_counter()
            row = ask(shot)
            stream.write(json.dumps({
                **shot, **row, "ms": round((time.perf_counter() - t0) * 1000, 1),
                "load1": round(os.getloadavg()[0], 2), "mlx_active": int(mx.get_active_memory()),
            }) + "\n")
            stream.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
