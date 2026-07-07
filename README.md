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
- **App-aware smart formatting** — Velora detects the frontmost app and picks a mode automatically:
  - *Slack / Messages / Discord / Telegram / WhatsApp* → terse, casual, no trailing period on a single short sentence
  - *Mail* → professional structure and tone
  - *Notes / Obsidian / Notion / Bear* → markdown allowed, lists when you enumerate
  - *VS Code / Cursor / Terminal / iTerm / Ghostty / Warp / Zed* → **raw mode, no AI rewriting**
  - everything else → clean, well-punctuated default
- **On-device STT + LLM** — streaming transcription with `parakeet-tdt-0.6b-v2` (mlx-whisper `large-v3-turbo` as fallback backend) and cleanup/formatting with `Qwen3-4B-Instruct-2507-4bit`. Cleanup removes fillers, applies self-corrections ("no wait, I meant Tuesday"), punctuates, and honors spoken "new line" / "new paragraph".
- **Custom modes, vocabulary, and replacements** — every mode is a JSON file in `~/.velora/modes/`. Drop in a file to create your own (see [Customization](#customization)).
- **History** — every dictation (raw + final text, app, mode, duration) is stored in a local SQLite database; the menubar menu shows your last three (click to copy).
- **Model picker** — choose your STT model in Settings, with managed downloads.
- **Safe insertion** — clipboard is snapshotted and restored around the synthesized ⌘V, with a keystroke-typing fallback for apps that block paste. Secure input fields (passwords) are detected and insertion is suppressed.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14+
- [uv](https://docs.astral.sh/uv/) (manages the Python engine)
- Swift toolchain — Command Line Tools are enough (`xcode-select --install`); **no Xcode needed**
- ~4.4 GB of disk for the default models (downloaded on first run)

## Install & build

```sh
git clone https://github.com/<you>/velora
cd velora
make app          # builds build/Velora.app (SwiftPM release + hand-rolled bundle, ad-hoc signed)
open build/Velora.app
```

First launch walks you through onboarding: microphone permission, accessibility permission (live-detected as you grant it), hotkey choice, and a try-it playground — you finish with a real dictation. The engine downloads the default models from Hugging Face on first run; after that, everything is offline.

> Run the `.app` bundle, not the bare binary — macOS permission grants (mic, accessibility) attach to the signed bundle identity.

## Performance

Measured on Apple Silicon with the default models (`parakeet-tdt-0.6b-v2` + `Qwen3-4B-Instruct-2507-4bit`):

| Metric | Measured |
|---|---|
| STT throughput | ~184× realtime |
| Key release → final text (11 s utterance, incl. LLM cleanup) | 533 ms |

Transcription streams during speech, so on release only the audio tail needs flushing. If cleanup would blow its budget, Velora inserts the raw transcript immediately instead of making you wait — the cleaned version is never the bottleneck.

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

Velora is at **v1**: the core dictation loop (capture → streaming STT → app-aware cleanup → insertion → history) is complete and tested (41 engine tests plus an end-to-end socket smoke harness).

Known limitations:

- **English-first** — the default `parakeet-tdt-0.6b-v2` model is English; multilingual dictation (Whisper multilingual models, auto language detection) is planned.
- **The `.app` bundle is required for real use** — microphone and accessibility (TCC) grants attach to the signed bundle, so hotkeys and insertion won't work from a bare `swift run` binary.
- History browser window, mode editor GUI, and streaming partial text in the HUD are planned (the storage and protocol support already exist).

## Contributing & license

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, repo layout, and PR guidelines.

Licensed under the [MIT License](LICENSE).
