# Velora

**Local-first dictation for macOS.** Hold a key, speak, release — polished text appears in whatever app you're using. Every dictation step, from speech-to-text to AI cleanup, runs on-device via [MLX](https://github.com/ml-explore/mlx) on Apple Silicon. Audio, transcripts, and history never leave your Mac; confirmed Personal Dictionary terms can sync privately through your iCloud Drive.

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
- **Voice Intelligence** — an on-device dashboard turns local history into useful trends: words and dictations over time, estimated time saved, streaks, app and mode breakdowns, STT/cleanup latency, cleanup rate, and an honest zero-edit rate with observation coverage. Share cards contain aggregate numbers only — never transcript, app, or contact text.
- **Private Meeting Memory** — Velora can suggest recording when Zoom, Google Meet, Teams, or a Slack Huddle is active, with optional Calendar matching. Capture starts only after an explicit confirmation, keeps microphone ("Me") and computer audio ("Them") as separate local tracks, and produces a searchable transcript, summary, decisions, and action items in the background. Processing is resumable and live dictation takes priority.
- **Speaker diarization** — when more than one person is on the other side of a call, the transcript splits them into *Speaker 1 / Speaker 2 / …* using on-device diarization (sherpa-onnx: pyannote segmentation + titanet embeddings, ~46 MB downloaded on the first meeting, sha256-pinned). One-on-one calls stay plain "Them"; any diarization failure falls back cleanly. Toggle in Settings → Meetings.
- **Safe Voice Edit** — select text in any app, press ⌥⇧E (configurable), and speak an edit: "make this more formal", "fix the grammar", "turn this into bullet points". Only the selection is touched, the result replaces it in place, and ⌘Z undoes it. The edit prompt is benchmarked (94% on a 50-command suite, `spikes/engine/bench_voice_edit.py`) and guarded — an unusable result keeps your text unchanged, and the edited text is always on the clipboard as backup.
- **"As Heard" escape hatch** — when cleanup gets something wrong, paste the untouched raw transcript from the menubar (*Reformat Last as → As Heard*) or view it in History. No re-processing, works even after the audio clip has been pruned.
- **Local CLI + MCP** — scripts and local agents can inspect allow-listed history/stats, transcribe an audio file, or request one visibly approved live dictation. Access is off by default, runs through an owner-only Unix socket instead of a network server, and never exposes raw audio, screen context, contacts, or learning data.
- **Personal Dictionary** — teach Velora exact names, product terms, and optional “heard as → write as” corrections. Edit-learned and auto-learned words stay visible and reversible, and only confirmed dictionary entries sync through your app-specific iCloud Drive folder when iCloud is available.
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

Prefer not to build? Install with Homebrew:

```sh
brew install --cask sushilk1991/tap/velora
```

Or grab `Velora-x.y.z.dmg` from [Releases](https://github.com/sushilk1991/velora/releases), drag Velora to Applications, and open it. Releases from v0.4.3 onward are Developer ID-signed and notarized by Apple, so they open normally through Gatekeeper. The older v0.4.1 image predates notarization and should be replaced rather than bypassed.

> Run the `.app` bundle, not the bare binary — macOS permission grants (mic, accessibility) attach to the signed bundle identity.
>
> **Tests:** `make test` runs the Python engine suite. The app also has an embedded Swift self-test (`swift run Velora --selftest`), and `make perf-test` checks Intelligence against a 100,000-row history.

## CLI and local agents

The installed app includes a CLI at:

```sh
/Applications/Velora.app/Contents/Resources/bin/velora --help
```

Enable **Allow local CLI and agents** in Settings → General, then use `status`, `recent`, `search`, `stats`, `transcribe`, or `listen`. Add `--json` for machine-readable output. `listen` always displays an approval prompt before the microphone starts.

Velora also exposes the same narrow surface as a local MCP stdio server:

```sh
/Applications/Velora.app/Contents/Resources/bin/velora mcp
```

The app must be running. Nothing listens on the network, and disabling the setting immediately removes history, stats, and action access; `status` remains available so tools can explain what is missing.

## Performance

The cleanup model is picked by RAM tier at first launch (Qwen3-1.7B-8bit on ≤14 GB Macs, Qwen3-4B-4bit up to 24 GB, Qwen3.5-4B-8bit above) and can be changed in Settings → Models. Measured on Apple Silicon M-series:

| Metric | Measured |
|---|---|
| Streaming STT throughput (`parakeet-tdt-0.6b-v2`) | ~184× realtime |
| Multilingual transcription (`whisper-large-v3-turbo`, default) | ~0.3 s per clip |
| LLM cleanup, warm | ~0.5–0.8 s per paragraph |
| Voice edit (selection + spoken instruction) | ~0.4 s per sentence, ~1 s per paragraph |
| Meeting diarization | ~2 s per audio-minute, ~0.5 GB peak |

The default multilingual model is batch (transcribes on release rather than streaming), a deliberate quality tradeoff for accurate Hindi/Indian-English. For streaming English with live HUD partials, pick `parakeet-tdt-0.6b-v2` in Settings. If cleanup would blow its budget, Velora inserts the raw transcript immediately instead of making you wait — the cleaned version is never the bottleneck.

## Architecture

Two processes, one product:

```
┌────────────── Velora.app (Swift, SwiftPM) ──────────────┐
│ menubar · hotkeys · mic/HUD · insertion · settings       │
│ history/intelligence · meeting capture/store · consent   │
└────────────┬───────────────────────────────┬──────────────┘
             │ engine.sock                   │ control.sock
             │ framed JSON + PCM             │ owner-only JSON
┌────────────┴────────────────────┐    ┌─────┴─────────────┐
│ velora-engine (Python + MLX)    │    │ local CLI / MCP  │
│ STT · cleanup · meeting notes   │    │ default-off      │
└─────────────────────────────────┘    └───────────────────┘
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

- Models are downloaded **once** from Hugging Face. Model downloads, Personal Dictionary iCloud Drive sync, and an optional update check are the only network-backed features; Velora has no backend service.
- The update check is one anonymous HTTPS GET to the public GitHub releases feed, at most once a day, carrying nothing about you or your dictations. Turn it off in Settings → General and Velora never touches the network at all after model download.
- At dictation time there are **zero network calls** — audio, transcripts, and cleaned text never leave the machine.
- History is a local SQLite file under `~/.velora/`. Delete it whenever you like.
- Meeting audio, transcripts, and notes live separately under `~/.velora/meetings/`. Meeting detection uses local app/window metadata and, only if enabled, nearby Calendar events. Detection can suggest a recording but can never start one; every recording requires an explicit confirmation and shows a persistent menu-bar indicator.
- Intelligence share cards are rendered locally from fixed labels and numeric aggregates. They cannot include transcript, app, contact, or calendar text.
- Local agent access is off by default. When enabled, only processes running as your macOS user can reach the owner-only `~/.velora/control.sock`; there is no TCP listener. Live microphone use still requires approval for each request.
- Personal Dictionary sync uses your standard iCloud Drive protection and contains only confirmed terms and corrections — never audio, transcripts, history, screen context, or model data. It remains fully usable offline and does not use a Velora server.
- No accounts, no telemetry, no analytics. This is enforced by architecture, not by a settings checkbox.

## Project status

Velora is actively developed and pre-1.0. The complete local dictation loop now sits alongside Voice Intelligence, consent-first Meeting Memory, and the default-off CLI/MCP surface. The release gate combines the Python engine suite, hundreds of embedded Swift checks, a 100,000-row Intelligence benchmark, packaged-app CLI/MCP smoke tests, and Apple signing/notarization verification.

Known limitations:

- **The `.app` bundle is required for real use** — microphone and accessibility (TCC) grants attach to the signed bundle, so hotkeys and insertion won't work from a bare `swift run` binary.
- **Batch default** — the multilingual default model transcribes on release, not live; switch to `parakeet-tdt-0.6b-v2` for streaming HUD partials (English only).
- **Speaker labels are acoustic, not identities** — "Me" is the microphone track; remote voices are clustered into "Speaker 1/2/…" by how they sound. Velora never claims to know *who* a speaker is.
- **Voice-edit casing quirks** — capitalization-specific instructions ("fix the weird capitalization") are the 4B model's weakest edit category; grammar, tone, shortening, and list edits are reliable.

## Contributing & license

Developer ID release builds that include Personal Dictionary sync need the explicit `com.sushil.velora` App ID with iCloud Documents enabled, the existing `iCloud.com.velora.app` ubiquity container, and an Apple-issued Developer ID provisioning profile. Keep that expiring profile outside Git and pass its path at release time:

```sh
VELORA_DISTRIBUTION=1 \
VELORA_PROVISIONING_PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/velora.provisionprofile" \
./scripts/make-dmg.sh release minor
```

The packaging scripts decode the profile before version stamping, require the exact Team ID, bundle ID, iCloud container, and `CloudDocuments` service, embed it at `Contents/embedded.provisionprofile`, and re-check the signed app during DMG verification. Ordinary local `make app` builds do not require a profile.

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, repo layout, and PR guidelines.

Licensed under the [MIT License](LICENSE).
