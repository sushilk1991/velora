#!/usr/bin/env python3
"""A public, human-referenced WER set from EdAcc (CC BY-SA 4.0).

    hf download edinburghcstr/edacc --repo-type dataset --include "data/test-*" --local-dir EDACC
    python edacc_set.py EDACC OUT_DIR      # mlx-vlm venv (pyarrow, soundfile)

The owner-term set scores against references mined from Velora's own
Whisper history, which favours Whisper. EdAcc's references are human
transcripts of conversational English, so a WER there has no home side.
Two groups: Indian English (the owner's accent) and Mainstream US English
as a control. Utterances of 2-30 s whose reference carries no overlap,
foreign-speech or keypad marker (those have no single right answer), up to
PER_ACCENT each, picked with a fixed seed. Writes 16 kHz mono WAVs and
OUT_DIR/edacc_set.jsonl (id, path, seconds, accent, speaker, reference).
"""

from __future__ import annotations

import glob
import io
import json
import random
import re
import sys
from pathlib import Path

ACCENTS = ("Indian English", "Mainstream US English")
PER_ACCENT = 120
SEED = 20261028
MIN_S, MAX_S = 2.0, 30.0
SAMPLE_RATE = 16_000

# Markers that make the reference ambiguous: two people at once, speech in
# another language, keypad tones.
SKIP_MARKERS = ("<OVERLAP>", "<FOREIGN>", "<DTMF>")
# Non-speech events; dropped from the reference, since no ASR writes them.
EVENT = re.compile(r"<[A-Z-]+>")


def main() -> int:
    import numpy as np
    import pyarrow.parquet as pq
    import soundfile as sf
    from scipy.signal import resample_poly

    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    pool: dict[str, list[dict]] = {accent: [] for accent in ACCENTS}
    for shard in sorted(glob.glob(str(source / "data" / "test-*.parquet"))):
        for index, row in enumerate(pq.read_table(shard).to_pylist()):
            if row["accent"] not in pool or any(m in row["text"] for m in SKIP_MARKERS):
                continue
            reference = " ".join(EVENT.sub(" ", row["text"]).split())
            if not reference:
                continue
            pool[row["accent"]].append({"shard": Path(shard).name, "index": index, "row": row,
                                        "reference": reference})

    rows = []
    rng = random.Random(SEED)
    for accent, candidates in pool.items():
        rng.shuffle(candidates)
        kept = 0
        for item in candidates:
            if kept == PER_ACCENT:
                break
            audio, rate = sf.read(io.BytesIO(item["row"]["audio"]["bytes"]), dtype="float32", always_2d=True)
            audio = audio.mean(axis=1)
            if rate != SAMPLE_RATE:
                audio = resample_poly(audio, SAMPLE_RATE, rate).astype(np.float32)
            seconds = len(audio) / SAMPLE_RATE
            if not MIN_S <= seconds <= MAX_S:
                continue
            clip_id = f"edacc-{item['shard'][:10]}-{item['index']}"
            path = out / f"{clip_id}.wav"
            sf.write(path, audio, SAMPLE_RATE)
            rows.append({"id": clip_id, "path": str(path), "seconds": round(seconds, 2),
                         "accent": accent, "speaker": item["row"]["speaker"],
                         "reference": item["reference"]})
            kept += 1

    with open(out / "edacc_set.jsonl", "w") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    for accent in ACCENTS:
        mine = [r for r in rows if r["accent"] == accent]
        print(accent, len(mine), "clips", round(sum(r["seconds"] for r in mine)), "s",
              len({r["speaker"] for r in mine}), "speakers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
