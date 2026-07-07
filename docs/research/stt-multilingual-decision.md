# STT model decision: multilingual quality (Hindi / Indian English)

_2026-07-08. Triggered by user report: "quality of dictation is bad" for Indian
English + Hindi + top languages._

## Root cause

The default STT was `mlx-community/parakeet-tdt-0.6b-v2` — **English-only**. It
cannot transcribe Hindi and mangles code-switched speech. Verified with a
controlled bake-off (macOS `say` voices → 16 kHz WAV → each backend):

| Clip | whisper-large-v3-turbo | parakeet-tdt-0.6b-v2 |
| --- | --- | --- |
| en_IN "…meeting for tomorrow at 3 PM…" | `…3 p.m. and send the report to the team.` | `…3pm and send the report…` |
| Hindi (Devanagari) | `नमस्ते, आज मौसम बहुत आच्छा है, क्या आप मेरे साथ बाजार चलेंगे?` | `Namaste, Ajmosam Bahut Achahe, Kia Hak Miri Sat Bazar Chalenge.` |
| Hinglish | `यार कल का प्लान कैंसल का दू, …ओफिस में` | `Yar kal ka plan cancel kadu, …office me.` |

Turbo produces near-perfect Devanagari; parakeet produces garbage. Latency on
this M-series: ~0.3 s per short clip for turbo (cached, 1.6 GB).

## Decision

**Default → `mlx-community/whisper-large-v3-turbo`** (multilingual, 99 languages,
fast, already cached). Picker offers, in order:

1. `whisper-large-v3-turbo` — default, fast + multilingual.
2. `whisper-large-v3-mlx` — full large-v3, highest accuracy (3.1 GB, slower).
3. `knownsense/whisper-hindi-apex-mlx` — Hindi/Hinglish specialist, **Romanized**
   output (700h Hindi/English fine-tune); best when the user wants Roman Hinglish
   rather than Devanagari.
4. `parakeet-tdt-0.6b-v3` — fastest, **live streaming** preview; English + 24
   European languages (no Hindi/Mandarin/Arabic).
5. `parakeet-tdt-0.6b-v2` — English-only streaming, lowest latency.
6. `whisper-large-v3-turbo-q4` — smallest (0.5 GB), roughest.

Tradeoff accepted: the whisper default is **batch** (transcribes on stop), so the
HUD's live partial-transcript preview only appears when a parakeet model is
selected. Quality was the user's explicit priority. Users who want the live
preview and speak English/European can pick parakeet-v3.

## Rejected / deferred

- **parakeet-tdt-0.6b-v3 as default** — streams, but 25 European languages only
  (no Hindi/Arabic/Mandarin). Kept as the streaming option, not default.
- **AI4Bharat / IndicWhisper** (IndicWhisper ~13.6 WER Hindi, Vaani-Hindi FLEURS
  11.2) — stronger on Hindi than base Whisper but **no official MLX build**;
  would need conversion. Deferred.
- **Qwen3-ASR-1.7B / Voxtral-Mini-Realtime** — promising multilingual + streaming
  but require `mlx-audio` and backend work; unverified on Hindi locally. Deferred.
- **distil-whisper-large-v3** — English-only; removed from the picker as a
  multilingual option.

Research: `yoyo research` (codex+claude+pi, 5 lenses), 2026-07-08.
Open follow-up: bake off full large-v3 vs turbo on the user's own voice with
cleanup disabled; consider Devanagari-vs-Romanized as a per-mode preference.
