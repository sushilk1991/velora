#!/usr/bin/env python3
"""Score "does someone speak?" against today's gates and Whisper's output.

Run from ``engine/`` with the engine venv (reads clips, loads no model)::

    python ../docs/research/2026-10-28-lfm3-family/score_speech.py \
        SPEECH_SET.jsonl WHISPER_RUN.jsonl D1_RUN.jsonl [D1_RUN.jsonl ...]

Clips labelled "unknown" (real takes with an empty transcript that are not
silent) are left out of every rate below.

    auc              P(speech) and each signal the engine has today, over
                     speech vs no-speech clips
    insertions       no-speech clips where production Whisper wrote words:
                     the failure a speech check would prevent
    veto at t        decode only when today's gate decodes AND P >= t.
                     left = insertions that still get through, lost =
                     speech clips Whisper transcribed that the veto drops,
                     precision = share of vetoed clips that were insertions,
                     mcnemar = exact test of per-clip outcomes (right = words
                     on a speech clip, none on a no-speech clip) vs today
    modulation       _has_speech_like_modulation (today's retry-only check)
                     used the same way, as a first-pass veto
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path.cwd() / "src"))

from stats import mcnemar_exact, roc_auc  # noqa: E402

THRESHOLDS = (0.2, 0.35, 0.5, 0.65)


def _veto(clips: list[dict], whisper: dict, keep) -> dict:
    """Outcome of decoding only the clips `keep` passes (on top of the gate)."""
    inserted = [c for c in clips if c["label"] == "no" and whisper[c["id"]]["words"] > 0]
    heard = [c for c in clips if c["label"] == "yes" and whisper[c["id"]]["words"] > 0]
    left = [c["id"] for c in inserted if keep(c)]
    lost = [c["id"] for c in heard if not keep(c)]
    vetoed = (len(inserted) - len(left)) + len(lost)
    today = [(whisper[c["id"]]["words"] > 0) == (c["label"] == "yes") for c in clips]
    vetoed_ok = [((whisper[c["id"]]["words"] > 0) and keep(c)) == (c["label"] == "yes") for c in clips]
    return {"insertions": len(inserted), "left": len(left), "lost": len(lost),
            "lost_ids": lost, "left_ids": left,
            "precision": round((len(inserted) - len(left)) / vetoed, 3) if vetoed else None,
            "mcnemar": mcnemar_exact(today, vetoed_ok)}


def main() -> int:
    import soundfile as sf
    from velora_engine.stt import _has_speech_like_modulation

    clips = [json.loads(line) for line in open(sys.argv[1])]
    known = [c for c in clips if c["label"] in ("yes", "no")]
    whisper = {r["id"]: r for r in map(json.loads, open(sys.argv[2])) if "id" in r}
    positives = [c["label"] == "yes" for c in known]

    def modulated(clip: dict) -> bool:
        audio, _ = sf.read(clip["path"], dtype="float32")
        return bool(_has_speech_like_modulation(audio))

    modulation = {c["id"]: modulated(c) for c in known}
    print(json.dumps({
        "signal": "today", "clips": len(known), "speech": sum(positives),
        "auc_gate_decodes": round(roc_auc([float(c["gate_decodes"]) for c in known], positives), 4),
        "auc_loudest_rms": round(roc_auc([c["loudest_frame_rms"] for c in known], positives), 4),
        "auc_p90_rms": round(roc_auc([c["p90_frame_rms"] for c in known], positives), 4),
        "inserted_by_kind": {k: sum(1 for c in known if c["kind"] == k and c["label"] == "no"
                                    and whisper[c["id"]]["words"] > 0)
                             for k in sorted({c["kind"] for c in known})},
        "modulation_veto": _veto(known, whisper, lambda c: modulation[c["id"]]),
    }))

    for path in sys.argv[3:]:
        d1 = {r["id"]: r for r in map(json.loads, open(path)) if "id" in r}
        p = [d1[c["id"]]["p_speech"] for c in known]
        natural = [d1[c["id"]]["p_speech"] for c in known if c["kind"] == "real_speech"]
        print(json.dumps({
            "signal": Path(path).stem,
            "auc_p_speech": round(roc_auc(p, positives), 4),
            "auc_p_talking": round(roc_auc([d1[c["id"]]["p_talking"] for c in known], positives), 4),
            "min_p_real_speech": round(min(natural), 3),
            "veto": {str(t): _veto(known, whisper, lambda c, t=t: d1[c["id"]]["p_speech"] >= t)
                     for t in THRESHOLDS},
            "ms_p50": sorted(r["ms"] for r in d1.values())[len(d1) // 2],
            "mlx_active_gb": round(max(r["mlx_active"] for r in d1.values()) / 1e9, 2),
        }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
