#!/usr/bin/env python3
"""Build the "does someone speak in this clip?" set and run today's gate on it.

Run from ``engine/`` with the engine venv (CPU only; no model loads)::

    python ../docs/research/2026-10-28-lfm3-family/speech_set.py OUT_DIR

Everything stays on this Mac: clips are written as 16 kHz PCM16 WAV under
OUT_DIR/clips, labels and gate verdicts to OUT_DIR/speech_set.jsonl. No
transcript text is written.

Kinds (label = is there speech):

    real_silence     archived takes that are digital silence (peak 0)       no
    real_fabricated  archived takes whose only text is a known Whisper      no
                     fabrication ("Closed Captioning by…", "You") at a
                     loudest 100 ms below 0.02 RMS
    real_empty       archived takes with an empty transcript, not silent    unknown
    real_speech      archived takes with words, loudest 100 ms ≥ 0.05 RMS   yes
    room_tone        each source take's quietest 20 ms frames, 3 s           no
    quiet_speech     a source take scaled so its p90 frame RMS is           yes
                     0.002 / 0.004 / 0.008 / 0.016 (a far or muted mic)

"Today's gate" is the production WhisperBackend, unloaded, fed 100 ms
chunks as the app sends them, with `_transcribe` replaced by a probe: the
gate passed iff finalize() asked for a decode.

    chunks ─► SilenceTracker ─► finalize ─┬─ skip  → "" (gate: no speech)
                                          └─ _transcribe called (gate: speech)
"""

from __future__ import annotations

import json
import random
import sqlite3
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ENGINE = Path(__file__).resolve().parents[3] / "engine"
sys.path.insert(0, str(ENGINE / "src"))

from velora_engine.stt import SAMPLE_RATE, WhisperBackend  # noqa: E402

CHUNK = 1600  # the app's capture chunk: 100 ms at 16 kHz (AudioCapture.swift)
FRAME = SAMPLE_RATE // 50  # 20 ms, the engine's speech frame
FABRICATIONS = ("closed captioning by", "you", "thank you", "thanks for watching")
QUIET_TARGETS = (0.002, 0.004, 0.008, 0.016)
SOURCES = 24
SEED = 20261028


def gate_passes(audio: np.ndarray) -> bool:
    """Whether production's pre-decode gates would hand this clip to Whisper."""
    backend = WhisperBackend("probe")
    called = []

    def probe(_audio, _prompt, **_kw):
        called.append(True)
        return {"text": "", "segments": [], "language": "en"}

    backend._transcribe = probe  # type: ignore[method-assign]
    backend.start_session()
    for start in range(0, len(audio), CHUNK):
        backend.feed_chunk(audio[start:start + CHUNK].astype(np.float32))
    backend.finalize()
    return bool(called)


def frame_rms(audio: np.ndarray) -> np.ndarray:
    n = len(audio) // FRAME
    if n == 0:
        return np.zeros(1)
    framed = audio[: n * FRAME].reshape(n, FRAME).astype(np.float64)
    return np.sqrt((framed ** 2).mean(axis=1))


def load(path: Path) -> np.ndarray:
    audio, rate = sf.read(str(path), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if rate != SAMPLE_RATE:
        raise ValueError(f"{path.name}: {rate} Hz, expected {SAMPLE_RATE}")
    return audio


def main() -> int:
    out = Path(sys.argv[1])
    clips = out / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(Path.home() / ".velora/history.sqlite3")
    rows = db.execute("select id, raw, audio_path from dictations order by id").fetchall()
    records = []

    def emit(cid: str, kind: str, label: str, audio: np.ndarray, **extra) -> None:
        path = clips / f"{cid}.wav"
        sf.write(str(path), np.clip(audio, -1, 1), SAMPLE_RATE, subtype="PCM_16")
        # Gate on the written PCM16, as d1 and Whisper will read it.
        written = load(path)
        rms = frame_rms(written)
        records.append({
            "id": cid, "kind": kind, "label": label, "path": str(path),
            "seconds": round(len(written) / SAMPLE_RATE, 2),
            "peak_lsb": int(np.abs(written).max() * 32768) if len(written) else 0,
            "loudest_frame_rms": round(float(rms.max()), 5),
            "p90_frame_rms": round(float(np.percentile(rms, 90)), 5),
            "gate_decodes": gate_passes(written), **extra,
        })

    speech_sources = []
    for take_id, raw, audio_path in rows:
        path = Path.home() / ".velora/audio" / (audio_path or "")
        if not audio_path or not path.exists():
            continue
        audio = load(path)
        if len(audio) < CHUNK * 2:
            continue
        rms100 = np.sqrt(np.mean(audio[: len(audio) // CHUNK * CHUNK]
                                 .reshape(-1, CHUNK).astype(np.float64) ** 2, axis=1))
        loudest = float(rms100.max())
        text = raw.strip().lower().rstrip(".!")
        if not raw.strip():
            if np.abs(audio).max() == 0:
                emit(f"take{take_id}", "real_silence", "no", audio, take=take_id)
            else:
                emit(f"take{take_id}", "real_empty", "unknown", audio, take=take_id)
        elif loudest < 0.02 and any(text.startswith(f) for f in FABRICATIONS):
            emit(f"take{take_id}", "real_fabricated", "no", audio, take=take_id)
        elif loudest >= 0.05 and 3 <= len(audio) / SAMPLE_RATE <= 15:
            speech_sources.append((take_id, audio))

    rng = random.Random(SEED)
    chosen = rng.sample(speech_sources, SOURCES * 2)
    for take_id, audio in chosen[:SOURCES]:
        emit(f"take{take_id}", "real_speech", "yes", audio, take=take_id)

    # Synthetic clips from a disjoint set of sources.
    for take_id, audio in chosen[SOURCES:]:
        rms = frame_rms(audio)
        quiet = audio[: len(rms) * FRAME].reshape(len(rms), FRAME)[rms <= np.percentile(rms, 20)]
        tone = np.tile(quiet.reshape(-1), 1 + 3 * SAMPLE_RATE // max(1, quiet.size))
        emit(f"tone{take_id}", "room_tone", "no", tone[: 3 * SAMPLE_RATE], source=take_id)
        p90 = float(np.percentile(rms, 90))
        for target in QUIET_TARGETS:
            emit(f"quiet{take_id}_{target}", "quiet_speech", "yes", audio * (target / p90),
                 source=take_id, target_p90=target)

    with open(out / "speech_set.jsonl", "w") as stream:
        for record in records:
            stream.write(json.dumps(record) + "\n")
    summary: dict[str, list[int]] = {}
    for record in records:
        row = summary.setdefault(record["kind"], [0, 0])
        row[0] += 1
        row[1] += record["gate_decodes"]
    print(json.dumps({kind: {"n": n, "gate_decodes": d} for kind, (n, d) in summary.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
