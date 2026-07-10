# Contributing to Velora

Thanks for helping build local-first dictation. This document covers dev setup, repo layout, style, and what we expect in a PR.

## Dev setup

Prerequisites: Apple Silicon Mac, macOS 14+, Command Line Tools (`xcode-select --install` — no Xcode needed), and [uv](https://docs.astral.sh/uv/).

### Swift app

```sh
swift build            # debug build (or: make build)
make run               # build + run the bare binary (menubar only; no TCC-gated features)
make app               # release build + hand-rolled, locally signed build/Velora.app
make release           # release binary only
make sounds            # regenerate UI sounds (start/stop/error.caf)
make clean             # remove .build/ and build/
```

Anything touching microphone, hotkeys, or text insertion must be exercised through `build/Velora.app` — macOS TCC grants attach to the signed bundle identity, not the bare binary.

### Distribution build

`make dmg` requires a Developer ID Application certificate and a one-time
notarytool keychain profile. Store the credentials without putting the
app-specific password in shell history:

```sh
xcrun notarytool store-credentials velora-notary \
  --apple-id <apple-id> --team-id JZFVKGDPU4
make dmg
make verify-dmg DMG=build/Velora-<version>.dmg
```

The DMG build fails closed if Developer ID signing or notarization is missing
and only moves the image to its public filename after all verification passes.
Set `VELORA_NOTARY_PROFILE` only when using a differently named keychain
profile.

### Python engine

```sh
cd engine
uv sync                # creates .venv with Python 3.12 + all deps
uv run pytest -q       # fast tests, no models needed (fake STT backend)
uv run velora-engine   # start the engine standalone (downloads/warm-loads models)
```

### End-to-end smoke test

Streams a real WAV over the socket to a running engine and prints transcript/final events with latencies (uses real models, so first run downloads ~4.4 GB):

```sh
uv --project engine run velora-engine --socket /tmp/velora-test.sock &
uv --project engine run python scripts/engine-smoke.py \
    --socket /tmp/velora-test.sock \
    --wav spikes/engine/samples/jfk.wav \
    --bundle-id com.apple.Notes --app-name Notes
```

The WAV must be 16 kHz mono (`ffmpeg -i in.wav -ar 16000 -ac 1 out.wav`). Use `--mode` to force a mode, `--bundle-id` to test app-aware resolution, `--speed` to stream faster than real time.

## Repo layout

```
Velora/
├── Package.swift             # SwiftPM app (Swift 5 language mode, no dependencies)
├── Sources/Velora/           # Swift modules: App, Capture, Hotkey, Context, HUD,
│                             #   Insert, EngineClient, Settings, History, Config
├── engine/                   # uv project — the Python inference engine
│   ├── src/velora_engine/    # server, protocol, stt, cleanup, formatting, models, config
│   └── tests/                # pytest suite (framing, formatting, divergence, server)
├── Resources/                # Info.plist, UI sounds
├── scripts/                  # make-app.sh, make-sounds.sh, engine-smoke.py
├── docs/                     # SPEC.md, ARCHITECTURE.md, research/
├── spikes/                   # exploratory prototypes + findings (reference only)
└── Makefile
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing the wire protocol or process lifecycle — it is the normative spec.

## Code style

**Swift**
- Swift 5 language mode (`.swiftLanguageMode(.v5)`) — deliberate; AVAudioEngine taps and the CGEventTap C callback fight Swift 6 strict concurrency. Don't flip it.
- **Zero package dependencies.** History is raw SQLite via the system library; keep it that way unless a dependency is clearly justified in the PR.
- Match the existing module boundaries (one responsibility per `Sources/Velora/<Module>/`). Doc comments on types explaining their role, as in the existing files.

**Python**
- Python 3.12, ruff-style: type hints on public functions, `from __future__ import annotations`, f-strings, no unused imports, ~100-col lines.
- Engine must never crash on bad input — malformed frames/commands produce an `error` event. Preserve that invariant.
- Keep the engine dependency list minimal; note any pin with a comment explaining why (see the `transformers` pin in `engine/pyproject.toml`).

## Tests

- `cd engine && uv run pytest -q` must pass. The suite (41 tests) runs in seconds with no model downloads, using the fake STT backend (`VELORA_FAKE_STT=1`).
- New engine behavior needs tests: formatting/gating logic in `test_formatting.py`, protocol changes in `test_framing.py` / `test_server.py`, cleanup guards in `test_divergence.py`.
- Swift: XCTest is unavailable without Xcode; UI/permission paths are verified manually through the `.app` bundle and the onboarding try-it step. Describe your manual verification in the PR.
- Latency-sensitive changes (STT, cleanup, protocol): include smoke-script output showing stop→transcript and stop→final numbers before/after.

## Pull requests

- Keep PRs focused — one logical change. Separate refactors from behavior changes.
- Describe *what* and *why*; include reproduction steps for bug fixes.
- Product principles from [docs/SPEC.md](docs/SPEC.md) are non-negotiable, especially: **no network calls at dictation time**, never lose the user's words (raw transcript always recoverable), and don't over-edit (conservative cleanup by default).
- Update `docs/ARCHITECTURE.md` and `engine/README.md` when you change the protocol, models, or module responsibilities.
- No telemetry, analytics, or cloud-inference features — these are explicit non-goals and will be declined.

## Reporting issues

Use the issue templates. For dictation quality problems, include the raw transcript and the final text from history plus the active mode — they make the difference between a guess and a fix.
