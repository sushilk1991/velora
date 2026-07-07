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
| `mlx-community/parakeet-tdt-0.6b-v2` | STT default — streams during recording | parakeet-mlx |
| `mlx-community/whisper-large-v3-turbo` | STT fallback — batch, hallucination guard | mlx-whisper |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | cleanup/formatting LLM | mlx-lm |

Note: `transformers` is pinned `>=5.0,<5.4` — mlx-lm 0.31.3 crashes on import
with transformers 5.13 (see `spikes/engine/FINDINGS.md`).

## Wire protocol (summary — normative spec in docs/ARCHITECTURE.md)

Unix socket `~/.velora/engine.sock`, length-prefixed frames:

```
frame  = u32 length (LE) | u8 type | payload
length = 1 + len(payload)          # counts the type byte plus the payload
type   = 0x01 JSON control | 0x02 raw PCM audio (16kHz mono Float32 LE)
```

The engine accepts a single client. On connect it sends
`{"event":"ready","stt_model":...,"version":...}` once the STT model is loaded.

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
