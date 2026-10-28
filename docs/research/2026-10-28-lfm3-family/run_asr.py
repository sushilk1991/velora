#!/usr/bin/env python3
"""Transcribe a clip manifest with one ASR arm; one JSON line per clip.

    # engine venv: the production Whisper path
    python run_asr.py whisper          WHISPER_SNAPSHOT MANIFEST.jsonl OUT.jsonl
    python run_asr.py whisper-noprompt WHISPER_SNAPSHOT MANIFEST.jsonl OUT.jsonl
    # mlx-vlm venv: LFM3-Audio / LFM3-Omni, the card's ASR system prompt
    python run_asr.py lfm3             MODEL_SNAPSHOT   MANIFEST.jsonl OUT.jsonl
    python run_asr.py lfm3-hint        MODEL_SNAPSHOT   MANIFEST.jsonl OUT.jsonl

Arms:

    whisper           WhisperBackend fed 100 ms chunks, then finalize(): the
                      engine's gates, segmenting, integrity guard, and the
                      glossary the server builds from the owner's dictionary
                      (user, learned, auto-mined; no on-screen names here)
    whisper-noprompt  the same with no glossary
    lfm3              "Perform ASR in English." (the card's ASR prompt), greedy
    lfm3-hint         the same plus the same glossary terms as a user-turn line
                      before the audio (not a documented LFM3 feature)

Hypothesis text is written to OUT (the scratchpad) for scoring; the scored
summary that goes into the repo carries no transcript text.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

SYSTEM = "Perform ASR in English."


def owner_glossary_terms() -> tuple[list[str], list[str], list[str]]:
    """User, learned and auto-mined vocabulary, read from ~/.velora as the
    server's Config would (read-only: Config(home=…) rewrites modes)."""
    home = Path.home() / ".velora"
    config = json.loads((home / "config.json").read_text())
    learned = json.loads((home / "learned.json").read_text())
    auto = json.loads((home / "auto_learned.json").read_text())
    return (list(config.get("vocabulary") or []), list(learned.get("vocabulary") or []),
            [t for t in auto.get("terms") or [] if isinstance(t, str)])


def whisper_arm(model_path: str, glossary: bool):
    import mlx.core as mx
    import numpy as np
    import soundfile as sf

    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "engine" / "src"))
    from velora_engine.stt import WhisperBackend, build_glossary_prompt

    backend = WhisperBackend(model_path)
    backend.load()
    prompt = build_glossary_prompt(*owner_glossary_terms(), []) if glossary else None

    def transcribe(path: str) -> str:
        audio, _ = sf.read(path, dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        backend.start_session()
        backend.initial_prompt = prompt
        for start in range(0, len(audio), 1600):
            backend.feed_chunk(np.ascontiguousarray(audio[start:start + 1600]))
        return backend.finalize()

    return transcribe, mx


def lfm3_arm(model_path: str, hint: bool):
    import mlx.core as mx
    from mlx_vlm import generate, load

    model, processor = load(model_path)
    tokenizer = processor.tokenizer
    terms = [t for source in owner_glossary_terms() for t in source]
    hint_line = "Names and terms that may appear: " + ", ".join(dict.fromkeys(terms[-24:]))

    def transcribe(path: str) -> str:
        import soundfile as sf

        seconds = sf.info(path).duration
        content = ([{"type": "text", "text": hint_line}] if hint else []) + \
            [{"type": "audio", "audio": path}]
        messages = [{"role": "system", "content": SYSTEM},
                    {"role": "user", "content": content}]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                               tokenize=False)
        # ~3 words/s of speech at ~1.4 tokens/word, with headroom.
        out = generate(model, processor, prompt, audio=[path],
                       max_tokens=int(16 + seconds * 6), temperature=0.0, verbose=False)
        return out.text.strip()

    return transcribe, mx


def main() -> int:
    arm, model_path, manifest, out_path = sys.argv[1:5]
    clips = [json.loads(line) for line in open(manifest)]
    if arm.startswith("whisper"):
        transcribe, mx = whisper_arm(model_path, glossary=(arm == "whisper"))
    else:
        transcribe, mx = lfm3_arm(model_path, hint=(arm == "lfm3-hint"))
    transcribe(clips[0]["path"])  # warm-up
    with open(out_path, "w") as stream:
        for clip in clips:
            t0 = time.perf_counter()
            text = transcribe(clip["path"])
            ms = (time.perf_counter() - t0) * 1000
            stream.write(json.dumps({
                "arm": arm, "model": model_path, "id": clip["id"], "seconds": clip["seconds"],
                "text": text, "ms": round(ms, 1), "rtf": round(ms / 1000 / clip["seconds"], 4),
                "load1": round(os.getloadavg()[0], 2), "mlx_active": int(mx.get_active_memory()),
            }, ensure_ascii=False) + "\n")
            stream.flush()
        stream.write(json.dumps({"event": "memory", "arm": arm,
                                 "peak_bytes": int(mx.get_peak_memory())}) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
