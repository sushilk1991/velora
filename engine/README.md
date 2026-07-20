# velora-engine

On-device inference engine for [Velora](../README.md): streaming speech-to-text
plus LLM cleanup/formatting, served over a unix domain socket to the Swift app.
Python 3.12 + MLX, managed with [uv](https://docs.astral.sh/uv/). No network
access at dictation time — models are downloaded once from Hugging Face.

## Dev setup

```sh
cd engine
uv sync                 # creates .venv with python 3.12 + all deps
uv run pytest -q        # fast tests, no models needed (fake STT backend)
uv run velora-engine    # start the engine (warm-loads models from HF cache)
```

First run downloads the default models (~4.4 GB total) into the Hugging Face
cache and writes `~/.velora/config.json` plus the built-in mode files to
`~/.velora/modes/*.json`.

CLI:

```sh
uv run velora-engine [--socket PATH] [--parent-pid PID] [--log-level INFO]
```

- `--socket` — unix socket path (default `$VELORA_HOME/engine.sock`, i.e. `~/.velora/engine.sock`).
- `--parent-pid` — supervisor pid; the engine exits when this pid dies and no
  client is connected. Plain SIGTERM also shuts it down cleanly.
- `VELORA_HOME` env var relocates `~/.velora` (used by tests).

End-to-end smoke test against a running engine (from repo root):

```sh
uv --project engine run velora-engine --socket /tmp/velora-test.sock &
uv --project engine run python scripts/engine-smoke.py \
    --socket /tmp/velora-test.sock \
    --wav spikes/engine/samples/jfk.wav \
    --bundle-id com.apple.Notes --app-name Notes
```

## Models

| Model | Role | Backend |
|---|---|---|
| `mlx-community/whisper-large-v3-turbo` | STT default — multilingual, hallucination guard | mlx-whisper |
| `handy-computer/whisper-large-v3-turbo-gguf` | Experimental faster Whisper Q8; automatically falls back on load failure | transcribe.cpp |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | cleanup/formatting LLM | mlx-lm |

Note: `transformers` is pinned `>=5.0,<5.4` — mlx-lm 0.31.3 crashes on import
with transformers 5.13 (see `spikes/engine/FINDINGS.md`).

### STT backend bakeoff

The transcribe.cpp Q8 model remains experimental until it clears Velora's
real-voice acceptance gate. Create a private local manifest (audio and
transcripts are never printed or uploaded):

```json
{
  "cases": [
    {
      "name": "indian-english-01",
      "audio": "clips/indian-english-01.flac",
      "reference": "The exact words that were spoken.",
      "cohort": "indian_english",
      "glossary": ["Velora", "SwiftUI"]
    }
  ]
}
```

Run from `engine/`:

```sh
uv run python scripts/benchmark_stt_backends.py /path/to/private-manifest.json
```

The full gate requires at least 18 clips spanning `indian_english`, `hindi`,
and `hinglish`, plus silence/noise and a ≥45-second dictation. It passes only
when both p50 and p95 stop-to-transcript latency improve by at least 10%, no
cohort has more word errors, glossary recall does not fall, and there are no
new empty/repetition failures. The slowest candidate ingestion real-time factor
must also stay at or below 0.9, leaving at least 10% headroom before live audio
can outpace decoding. Results identify the immutable GGUF revision and digest,
native provider/commit, macOS version, architecture, and Mac model. `--smoke`
bypasses corpus coverage only; it does not relax the speed or quality rules.

## Wire protocol (summary — normative spec in docs/ARCHITECTURE.md)

Unix socket `~/.velora/engine.sock`, length-prefixed frames:

```
frame  = u32 length (LE) | u8 type | payload
length = 1 + len(payload)          # counts the type byte plus the payload
type   = 0x01 JSON control | 0x02 raw PCM audio (16kHz mono Float32 LE)
```

The engine accepts a single client. On connect it sends
`{"event":"ready","stt_model":...,"version":...,"setup_complete":true|false}`
once the STT model is loaded.
First-run model work is reported as `{"event":"loading","phase":...,"fraction":...}`;
when the ready snapshot was false, `{"event":"setup_complete"}` follows after
both speech and writing model setup.

One dictation:

```
→ {"cmd":"start","session":"uuid","context":{"bundle_id":"...","app_name":"...","mode":null}}
→ AUDIO frames (~100ms chunks, streamed live; STT runs during recording)
→ {"cmd":"stop","session":"uuid"}
← {"event":"partial","session":"...","text":"..."}                        (0..n, during recording)
← {"event":"transcript","session":"...","raw":"...","ms":<stop→transcript ms>}
← {"event":"final","session":"...","text":"...","raw":"...","mode":"Note",
   "cleanup_ms":..,"cleanup_applied":true}
```

Other commands: `cancel` (discards the session → `cancelled`), `ping` → `pong`,
`status` → `status` (state + model registry), `reload_config` →
`config_reloaded`, `set_model {"model":id,"kind":"stt"|"cleanup"}` →
`model_set` (downloads if needed). Malformed frames or commands produce
`{"event":"error","message":...}` — the engine never crashes on bad input.

## Module map

| File | Responsibility |
|---|---|
| `server.py` | asyncio socket server, session state machine, lifecycle/exit |
| `protocol.py` | framing codec |
| `stt.py` | `ParakeetBackend` (streaming), `WhisperBackend` (batch + hallucination guard), `FakeBackend` (tests, `VELORA_FAKE_STT=1`) |
| `cleanup.py` | mlx-lm wrapper: prompt cache, token cap, temp 0, divergence guard, 1500ms hard timeout |
| `formatting.py` | deterministic gate, mode resolution, app-category mapping, prompt assembly, replacements |
| `models.py` | model registry + `snapshot_download` |
| `config.py` | `~/.velora/config.json` + `~/.velora/modes/*.json` (built-ins installed on first run) |

## Formatting policy (docs/SPEC.md P0)

1. Deterministic gate first: explicit mode > per-app bundle-id match > default;
   `formatting: off` modes (Raw/Code) get regex-level tidy only; utterances
   under 6 words get punctuation only — never the LLM.
2. LLM pass (temperature 0) with anti-over-editing rules baked into the system
   prompt: transcribe-don't-answer, no added content, apply self-corrections,
   lists only when enumerating, chat mode drops the trailing period on a single
   short sentence. If the output diverges too far from the raw transcript
   (length ratio outside [0.55, 1.6]) or the 1500ms budget is exceeded, the raw
   transcript is returned with `cleanup_applied: false`.
