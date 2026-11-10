#!/bin/zsh
# Synthesizes Velora's UI sounds per docs/research/design-brief.md §5 and
# converts them to .caf in Resources/.
#
#   start.caf — two ascending sine tones, 660 Hz then 880 Hz (E5→A5),
#               each 70 ms, 8 ms attack / 60 ms exponential decay, peak −18 dBFS.
#   stop.caf  — the reverse (880→660 Hz), −20 dBFS (quieter than start).
#   error.caf — single 330 Hz tone, 120 ms, −18 dBFS.
#
# Uses python3 (ships with CommandLineTools) to write PCM WAVs, then
# afconvert (macOS builtin) to package them as AAC-in-CAF, with a lossless
# LEI16 CAF fallback if the AAC encoder is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="Resources"
VARIANTS_ONLY="${1:-}"
if [[ -n "$VARIANTS_ONLY" && "$VARIANTS_ONLY" != "--variants-only" ]]; then
  echo "Usage: $0 [--variants-only]" >&2
  exit 2
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$TMP_DIR" <<'PY'
import math, struct, sys, wave

tmp = sys.argv[1]
SR = 48000

def tone(freq, dur, peak_db, attack=0.008, decay_tau=0.022):
    """Sine tone with linear attack and exponential decay envelope."""
    peak = 10 ** (peak_db / 20.0)
    n = int(dur * SR)
    samples = []
    for i in range(n):
        t = i / SR
        if t < attack:
            env = t / attack
        else:
            env = math.exp(-(t - attack) / decay_tau)
        samples.append(peak * env * math.sin(2 * math.pi * freq * t))
    return samples

def write_wav(name, samples):
    with wave.open(f"{tmp}/{name}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", max(-32767, min(32767, int(s * 32767))))
            for s in samples
        )
        w.writeframes(frames)

write_wav("start", tone(660, 0.070, -18) + tone(880, 0.070, -18))
write_wav("stop",  tone(880, 0.070, -20) + tone(660, 0.070, -20))
write_wav("error", tone(330, 0.120, -18))

# Each set uses the same peaks as Classic. Soft has a rounder attack and
# lower notes; Chime adds quiet upper partials. No microphone is involved.
write_wav("soft-start", tone(440, .09, -18, .018, .030) + tone(554.365, .09, -18, .018, .030))
write_wav("soft-stop", tone(554.365, .09, -20, .018, .030) + tone(440, .09, -20, .018, .030))
write_wav("soft-error", tone(261.626, .16, -18, .018, .035))

def bell(freq, dur, db):
    fundamental = tone(freq, dur, db, .005, .055)
    overtone = tone(freq * 2, dur, db - 12, .003, .025)
    samples = [a + b for a, b in zip(fundamental, overtone)]
    target = 10 ** (db / 20)
    scale = target / max(abs(s) for s in samples)
    return [s * scale for s in samples]

write_wav("chime-start", bell(783.991, .11, -18) + bell(1046.502, .14, -18))
write_wav("chime-stop", bell(1046.502, .11, -20) + bell(783.991, .14, -20))
write_wav("chime-error", bell(391.995, .20, -18))
print("synthesized Classic, Soft and Chime wavs")
PY

mkdir -p "$OUT_DIR"
for name in start stop error soft-start soft-stop soft-error chime-start chime-stop chime-error; do
  if [[ "$VARIANTS_ONLY" == "--variants-only" && "$name" != *-* ]]; then continue; fi
  # New variants are deterministic lossless PCM, with no encoder dependency.
  if [[ "$name" == *-* ]]; then
    afconvert -f caff -d LEI16 "$TMP_DIR/$name.wav" "$OUT_DIR/$name.caf"
    echo "wrote $OUT_DIR/$name.caf"
    continue
  fi
  if ! afconvert -f caff -d aac -b 64000 "$TMP_DIR/$name.wav" "$OUT_DIR/$name.caf" 2>/dev/null; then
    echo "afconvert aac failed for $name; falling back to LEI16" >&2
    afconvert -f caff -d LEI16 "$TMP_DIR/$name.wav" "$OUT_DIR/$name.caf"
  fi
  echo "wrote $OUT_DIR/$name.caf"
done
