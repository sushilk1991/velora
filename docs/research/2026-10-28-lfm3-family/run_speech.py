#!/usr/bin/env python3
"""Ask "does someone speak in this clip?" of every clip in speech_set.jsonl.

    # d1-Omni (mlx-vlm venv): P(yes) per clip, the card's own question
    python run_speech.py d1 MODEL_PATH SPEECH_SET.jsonl OUT.jsonl
    # today's production path (engine venv): gate + Whisper + integrity guard
    python run_speech.py whisper WHISPER_SNAPSHOT SPEECH_SET.jsonl OUT.jsonl

The Whisper arm runs the engine's WhisperBackend exactly as a dictation
does: 100 ms chunks, then finalize(). Its answer is "speech" when the final
transcript has words. Transcript text is kept only for clips with no owner
speech in them (room tone, silence, fabricated takes); for the rest only the
word count is written.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

QUESTION = "Does someone speak in the recording?"  # d1-Omni card's own wording
ALT_QUESTION = "Is a person talking anywhere in this recording?"
KEEP_TEXT = {"room_tone", "real_silence", "real_fabricated"}


def d1_arm(model_path: str):
    import mlx.core as mx
    from mlx_vlm import load

    model, _ = load(model_path)

    def ask(clip: dict) -> dict:
        media = [{"type": "audio", "path": clip["path"]}]
        out = model.system_one(None, {
            "speech": {"type": "noul", "instructions": QUESTION},
            "talking": {"type": "noul", "instructions": ALT_QUESTION},
        }, media=media)
        answers = out["answers"]
        return {"p_speech": round(float(answers["speech"]["noul"]), 6),
                "p_talking": round(float(answers["talking"]["noul"]), 6),
                "tokens": int(out["usage"]["input_tokens"])}

    return ask, mx


def whisper_arm(model_path: str):
    import mlx.core as mx
    import numpy as np
    import soundfile as sf

    engine = Path(__file__).resolve().parents[3] / "engine" / "src"
    sys.path.insert(0, str(engine))
    from velora_engine.stt import WhisperBackend

    backend = WhisperBackend(model_path)
    backend.load()

    def ask(clip: dict) -> dict:
        audio, _ = sf.read(clip["path"], dtype="float32")
        backend.start_session()
        for start in range(0, len(audio), 1600):
            backend.feed_chunk(np.asarray(audio[start:start + 1600], dtype=np.float32))
        text = backend.finalize()
        row = {"words": len(text.split())}
        if clip["kind"] in KEEP_TEXT or clip["kind"] == "real_empty":
            row["text"] = text
        return row

    return ask, mx


def main() -> int:
    arm, model_path, set_path, out_path = sys.argv[1:5]
    clips = [json.loads(line) for line in open(set_path)]
    ask, mx = {"d1": d1_arm, "whisper": whisper_arm}[arm](model_path)
    ask(clips[0])  # warm-up
    with open(out_path, "w") as stream:
        for clip in clips:
            t0 = time.perf_counter()
            row = ask(clip)
            ms = (time.perf_counter() - t0) * 1000
            stream.write(json.dumps({
                "arm": arm, "id": clip["id"], "kind": clip["kind"], "label": clip["label"],
                "seconds": clip["seconds"], "gate_decodes": clip["gate_decodes"], **row,
                "ms": round(ms, 1), "load1": round(os.getloadavg()[0], 2),
                "mlx_active": int(mx.get_active_memory()),
            }) + "\n")
            stream.flush()
        stream.write(json.dumps({"event": "memory", "arm": arm,
                                 "peak_bytes": int(mx.get_peak_memory())}) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
