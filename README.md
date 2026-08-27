# Velora

<div align="center">

**Private voice typing for Mac — free, open source, and fully on-device.**

[![GitHub stars](https://img.shields.io/github/stars/sushilk1991/velora)](https://github.com/sushilk1991/velora/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14+-brightgreen)]()
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-lightgrey)]()
[![Offline](https://img.shields.io/badge/100%25-offline-informational)]()
[![Platform](https://img.shields.io/badge/Mac-app-brightgreen)]()

</div>

Hold a key, speak, and release. Velora turns your speech into polished text in
the app you are already using — then can carry out spoken commands for you.

**The pitch:** a **free, MIT, on-device** alternative to paid dictation tools
like Superwhisper and Wispr Flow. No subscription, no account, no cloud. Your
audio and transcripts never leave your Mac.

Speech recognition and writing cleanup run on your Mac. Your audio,
transcripts, and history are not sent to a transcription service.

> ⭐ **Like Velora?** Star the repo — it tells me this matters and helps others
> find a private, offline dictation option. Thanks!

## Why Velora

| | Velora | Superwhisper / Wispr Flow |
|---|---|---|
| **Price** | Free (MIT) | Paid subscription |
| **On-device** | ✅ fully offline | Mostly cloud or hybrid |
| **Agentic actions** | ✅ "message Priya on Slack I'm late" | ❌ dictation only |
| **Account / telemetry** | None | Often required |
| **Audio leaves Mac** | Never | Sometimes |

Most dictation apps just type what you say. Velora can also **do things**: select
text and describe a change, or hold ⌃⇧A and ask Velora to open an app and carry
out a task. It works a few steps at a time, reads what's actually on screen, and
adjusts — then stops rather than guess when the window it expects isn't there.

## What Velora does

- **Dictates anywhere.** Use the default Right Option shortcut in messages,
  email, notes, documents, and other text fields.
- **Keeps your meaning.** Velora removes filler, adds punctuation, follows
  spoken line breaks, and preserves the original transcript in History.
- **Keeps every result pasteable.** Each final dictation stays on the clipboard,
  even if the current app ignores the automatic paste.
- **Adapts to your work.** Formatting changes with the app, and a Personal
  Dictionary teaches Velora names and terms you use often.
- **Edits selected text.** Select text, describe the change, and undo normally
  if the result is not right.
- **Carries out spoken actions.** Hold ⌃⇧A and say what you want done — "search
  YouTube for the match highlights", "message Priya on Slack that I'm running
  late" — and Velora opens the app and does it, working like an agent: it acts
  a few steps at a time, reads what the screen actually says, and adjusts —
  pressing the right person's chat when a shortcut didn't land, correcting a
  misheard name to the spelling it can see. Say "draft" instead and it stops
  with the message written but unsent. All of it happens on your Mac, like
  everything else, and Velora stops rather than guess whenever the window it
  expects is not the one in front.
- **Remembers meetings—with permission.** After you confirm, Velora records
  microphone and computer audio, then creates a local transcript and notes.
  It captures audio only, never the screen.

When dictation starts, Velora can pause supported playback in Apple Music or
Spotify and resume only the playback it paused. This avoids the audio-quality
change that can happen when a Bluetooth microphone, including AirPods, becomes
active.

## The iPhone app is alpha — do not rely on it

The Mac app is the Velora product. This repository also contains an
[iPhone companion](ios/README.md) that uses on-device speech recognition and
copies the result to the clipboard.

> **The iPhone app is alpha and is not stable at all.** Expect crashes, broken
> or half-finished behaviour, and changes that break without warning between
> commits. It is not on the App Store, there is no TestFlight build, and it
> receives far less testing than the Mac app. Build it only if you are
> comfortable running unfinished software from source, and do not depend on it
> for anything that matters.

## Install on Mac

Velora requires an Apple Silicon Mac running macOS 14 or later.

With Homebrew:

```sh
brew install --cask sushilk1991/tap/velora
```

Or download the signed Mac app from
[GitHub Releases](https://github.com/sushilk1991/velora/releases/latest).

On first launch, Velora asks for microphone, input-monitoring, and accessibility
permissions, then downloads the files needed for on-device transcription. The
first setup can take several minutes and requires an internet connection.
Dictation works locally after setup.

## Build from source

You need the macOS Command Line Tools and
[uv](https://docs.astral.sh/uv/). Xcode is not required for the Mac app.

```sh
git clone https://github.com/sushilk1991/velora.git
cd velora
make app
open build/Velora.app
```

Run the app bundle rather than the bare executable. macOS attaches microphone,
input-monitoring, and accessibility permissions to the app identity.

## Privacy

- Dictation, cleanup, meeting processing, and history stay on the device.
- Velora has no account, telemetry, advertising, or cloud transcription.
- Meeting recording always requires confirmation and shows a persistent
  recording indicator.
- Model downloads and app updates use the internet. Update checks can be
  disabled.
- Personal Dictionary sync is optional and uses your iCloud Drive; it syncs
  confirmed terms, not audio or transcripts.
- Local automation is off by default and does not open a network port.

## Development and tests

```sh
make test             # Mac, engine, site, and release-script checks
make test-coverage    # Python branch coverage gate
make perf-test        # 100,000-row local-history performance check
make test-live-audio  # real mic and computer-audio checks; needs permissions
make test-ios         # iPhone unit tests; needs Xcode and a simulator
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture
notes, and the manual checks required for permission-gated macOS behavior.

Velora is actively developed and pre-1.0. Bug reports and focused pull requests
are welcome.

## License

[MIT](LICENSE)
