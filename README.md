# Velora

**Private voice typing for Mac.** Hold a key, speak, and release. Velora turns
your speech into polished text in the app you are already using.

Speech recognition and writing cleanup run on your Mac. Your audio,
transcripts, and history are not sent to a transcription service.

## What Velora does

- **Dictates anywhere.** Use the default Right Option shortcut in messages,
  email, notes, documents, and other text fields.
- **Keeps your meaning.** Velora removes filler, adds punctuation, follows
  spoken line breaks, and preserves the original transcript in History.
- **Adapts to your work.** Formatting changes with the app, and a Personal
  Dictionary teaches Velora names and terms you use often.
- **Edits selected text.** Select text, describe the change, and undo normally
  if the result is not right.
- **Remembers meetings—with permission.** After you confirm, Velora records
  microphone and computer audio, then creates a local transcript and notes.
  It captures audio only, never the screen.

When dictation starts, Velora can pause supported playback in Apple Music or
Spotify and resume only the playback it paused. This avoids the audio-quality
change that can happen when a Bluetooth microphone, including AirPods, becomes
active.

The Mac app is the main Velora product. This repository also includes a focused
[iPhone companion](ios/README.md) that uses on-device speech recognition and
copies the result to the clipboard. The iPhone app is currently available from
source, not the App Store.

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
