# Velora

**Local-first dictation for macOS.** Hold a key, speak, release — polished text appears in whatever app you're using. Every step, from speech-to-text to AI cleanup, runs on-device via [MLX](https://github.com/ml-explore/mlx) on Apple Silicon. Nothing you say ever leaves your Mac.

<!-- demo GIF placeholder: hold hotkey → capsule HUD with live waveform → text lands in Slack -->

## Why Velora

Dictation tools like Superwhisper and Wispr Flow proved the product: invisible, fast, smart voice input everywhere. But Wispr Flow transcribes in the cloud, and both are closed-source subscriptions. Velora is the open-source answer:

- **Private by architecture, not by toggle.** Zero network calls at dictation time. Models are downloaded once from Hugging Face; after that the engine never touches the network. No accounts, no telemetry, no analytics.
- **Free and open.** MIT-licensed. Modes, prompts, and vocabulary are plain JSON files you own.
- **Fast enough to trust.** Speech-to-text streams *while you talk*, so text lands moments after you release the key — AI cleanup included.
- **Doesn't rewrite you.** Cleanup is deliberately conservative: transcribe-don't-answer, no added content, and a divergence guard that falls back to your raw words if the LLM drifts. The raw transcript is always kept in history.

## Features

- **Hold-to-talk and toggle dictation** — hold Right-Option (default) to record, release to insert; or double-tap / click the menubar icon to toggle. Esc always cancels cleanly. Hotkey behavior is configurable.
- **Capsule HUD** — a small floating capsule with a live 24-bar waveform from your mic. It never steals focus, and morphs through listening → transcribing → inserted/error states. Start/stop sounds included (toggleable).
- **Multilingual** — the default `whisper-large-v3-turbo` model handles English, Indian English, Hindi, and dozens more languages with automatic language detection. Non-Latin transcripts (Devanagari, CJK, Arabic) skip the English-tuned cleanup so they stay faithful.
- **Optional romanized output** — a Dictation-settings toggle transliterates non-Latin speech into Latin letters (Hindi → natural Hinglish, e.g. "नमस्ते आज मौसम" → "Namaste aaj mausam"), keeping English words English. Off by default.
- **App-aware smart formatting** — Velora detects the frontmost app and picks a mode automatically:
  - *Slack / Messages / Discord / Telegram / WhatsApp* → terse, casual, no trailing period on a single short sentence
  - *Mail* → professional structure and tone
  - *Notes / Obsidian / Notion / Bear* → markdown allowed, lists when you enumerate
  - *VS Code / Cursor / Terminal / iTerm / Ghostty / Warp / Zed* → **raw mode, no AI rewriting**
  - everything else → clean, well-punctuated default
- **On-device STT + LLM** — transcription with `whisper-large-v3-turbo` (multilingual; `parakeet-tdt-0.6b-v2` available for streaming English, plus a Hindi/Hinglish specialist) and cleanup/formatting with `Qwen3-4B-Instruct-2507-4bit`. Cleanup removes fillers, applies self-corrections ("no wait, I meant Tuesday"), punctuates, and honors spoken "new line" / "new paragraph".
- **History browser** — every dictation (raw + final text, app, mode, duration) is stored in a local SQLite database. Browse, search, copy, or paste-again from the History tab; the menubar menu shows your last three (click to copy).
- **Audio archive + reprocess** — clips are saved as compact FLAC under `~/.velora/audio` (configurable retention, default 6 months / 4 GB cap) so you can re-transcribe any past dictation with a better model straight from the History tab.
- **Custom modes editor** — every mode is a JSON file in `~/.velora/modes/`, editable from the Modes tab: per-mode LLM prompt (the Superwhisper-style feature), formatting level, app bindings, vocabulary, and replacements. Drop in a file to create your own (see [Customization](#customization)).
- **Model picker** — choose your STT model in Settings from the engine's registry, with managed downloads.
- **Live spectrum waveform** — the HUD's 24-bar waveform is driven by a real FFT of your mic, so bars react to both loudness and pitch.
- **Safe insertion** — clipboard is snapshotted and restored around the synthesized ⌘V, with a keystroke-typing fallback for apps that block paste. Secure input fields (passwords) are detected and insertion is suppressed.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14+
- [uv](https://docs.astral.sh/uv/) (manages the Python engine)
- Swift toolchain — Command Line Tools are enough (`xcode-select --install`); **no Xcode needed**
- ~4.4 GB of disk for the default models (downloaded on first run)

## Install & build

```sh
# 1. Prerequisites (one-time)
xcode-select --install                    # Swift toolchain (Command Line Tools)
curl -LsSf https://astral.sh/uv/install.sh | sh   # uv, for the Python engine

# 2. Build & run
git clone https://github.com/sushilk1991/velora
cd velora
make app          # builds build/Velora.app (SwiftPM release + hand-rolled dev bundle)
open build/Velora.app
```

`make app` compiles the Swift app and bundles the Python engine; the engine's dependencies are fetched by `uv` on first launch. First launch then walks you through onboarding: microphone permission, accessibility permission (live-detected as you grant it), hotkey choice, and a try-it playground — you finish with a real dictation. The engine downloads the default models from Hugging Face on first run (~6 GB; live progress shows in the onboarding window, the menubar menu, and the HUD if you try dictating early — speech recognition unlocks first, AI cleanup a few minutes later). After that, everything is offline.

Prefer not to build? Grab `Velora-x.y.z.dmg` from [Releases](https://github.com/sushilk1991/velora/releases), drag Velora to Applications, and open it. Releases from v0.4.3 onward are Developer ID-signed and notarized by Apple, so they open normally through Gatekeeper. The older v0.4.1 image predates notarization and should be replaced rather than bypassed.

> Run the `.app` bundle, not the bare binary — macOS permission grants (mic, accessibility) attach to the signed bundle identity.
>
> **Engine tests:** `make test` runs the Python engine suite (`cd engine && uv run pytest -q`).

## Performance

Measured on Apple Silicon M-series with `Qwen3-4B-Instruct-2507-4bit` cleanup:

| Metric | Measured |
|---|---|
| Streaming STT throughput (`parakeet-tdt-0.6b-v2`) | ~184× realtime |
| Multilingual transcription (`whisper-large-v3-turbo`, default) | ~0.3 s per clip |
| LLM cleanup, warm | ~0.8 s per paragraph |

The default multilingual model is batch (transcribes on release rather than streaming), a deliberate quality tradeoff for accurate Hindi/Indian-English. For streaming English with live HUD partials, pick `parakeet-tdt-0.6b-v2` in Settings. If cleanup would blow its budget, Velora inserts the raw transcript immediately instead of making you wait — the cleaned version is never the bottleneck.

## Architecture

Two processes, one product:

```
┌────────────── Velora.app (Swift, SwiftPM) ──────────────┐
│  menubar · hotkeys · mic capture · HUD · app context    │
│  text insertion · settings/onboarding · history         │
└────────────────────────┬─────────────────────────────────┘
                         │ unix socket (~/.velora/engine.sock)
                         │ framed JSON control + raw PCM audio
┌────────────────────────┴─────────────────────────────────┐
│           velora-engine (Python 3.12 + MLX, uv)          │
│  streaming STT · LLM cleanup · mode/format policy        │
│  model download & lifecycle                              │
└──────────────────────────────────────────────────────────┘
```

The Swift app owns everything user-facing; the Python engine is an invisible inference server, supervised (spawned, health-checked, restarted) by the app. Full details, wire protocol, and module map: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Customization

Modes live in `~/.velora/modes/*.json` (built-ins are copied there on first run — edit away). The file format **is** the API:

```json
{
  "name": "Standup",
  "prompt": "The user is dictating a daily standup update. Keep it to short bullet points grouped under 'Yesterday', 'Today', and 'Blockers' when the speech covers them.",
  "formatting": "full",
  "apps": ["com.tinyspeck.slackmacgap"],
  "vocabulary": ["Velora", "MLX", "parakeet", "Kubernetes"],
  "replacements": { "vs code": "VS Code", "k eight s": "k8s" }
}
```

- `prompt` — mode-specific instructions merged into the cleanup system prompt.
- `formatting` — `"off"` (regex-level tidy only, no LLM), `"light"`, or `"full"`.
- `apps` — bundle ids that auto-activate this mode when frontmost. An explicit mode selection always wins over app matching.
- `vocabulary` — proper nouns and jargon hinted to transcription and cleanup.
- `replacements` — literal text substitutions applied after cleanup.

Edits are picked up via the engine's config reload — no restart dance required.

## Privacy

- Models are downloaded **once** from Hugging Face. That is the only network activity Velora ever performs.
- At dictation time there are **zero network calls** — audio, transcripts, and cleaned text never leave the machine.
- History is a local SQLite file under `~/.velora/`. Delete it whenever you like.
- No accounts, no telemetry, no analytics. This is enforced by architecture, not by a settings checkbox.

## Project status

Velora is at **v1**: the full dictation loop (capture → multilingual STT → app-aware cleanup → insertion → searchable history → audio archive → reprocess) is complete and tested (70 engine tests plus an end-to-end socket harness).

Known limitations:

- **The `.app` bundle is required for real use** — microphone and accessibility (TCC) grants attach to the signed bundle, so hotkeys and insertion won't work from a bare `swift run` binary.
- **Batch default** — the multilingual default model transcribes on release, not live; switch to `parakeet-tdt-0.6b-v2` for streaming HUD partials (English only).

## Contributing & license

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, repo layout, and PR guidelines.

Licensed under the [MIT License](LICENSE).
