# Velora

macOS menubar dictation. SwiftPM app (`Package.swift`; Command Line Tools, no Xcode) plus a Python 3.12 `uv` engine on `~/.velora/engine.sock`.

## Build, test, run

```
swift build
.build/debug/Velora --selftest
make test
./scripts/make-app.sh release none
```

No lint or format target exists. `make test` is the gate: exit 0, Swift prints `selftest OK —`, pytest prints `passed`, plus `site checks OK`, `signing config tests OK`, and `publish-release checks OK`.

Mic, Accessibility, and Input Monitoring attach to `build/Velora.app`, not `.build/debug/Velora`.

## Guardrails

- Keep TCC grants across rebuilds: sign with this team's Developer ID, or the `Velora Dev Signing` identity from `scripts/make-signing-cert.sh`, and run `build/Velora.app`. Ad-hoc codesign reties Mic / Accessibility / Input Monitoring to a new cdhash every binary.
- Package without shipping a version: `./scripts/make-app.sh release none`. `make app` bumps `VERSION` (patch default). Never reuse a shipped version; bump levels are in `scripts/bump-version.sh`.
- Ship a built-in mode change to existing installs: add the old parsed JSON to `_BUILTIN_MODE_SUPERSEDED` and bump `_BUILTIN_MODES_REV` in `engine/src/velora_engine/config.py`. Files under `engine/src/velora_engine/modes_builtin/` do not overwrite `~/.velora/modes/`.
- Keep dictation STT/cleanup on-device (`docs/SPEC.md`). Engine tests that construct STT set `VELORA_FAKE_STT=1` (`engine/tests/conftest.py`).
- Put Mac logic tests in `Sources/Velora/Selftest/Selftest.swift` and run them with `--selftest`.
- Land finished work on `main` of `sushilk1991/velora` in the same round. Unmerged branches have sat on shipped features.

## Pointers

- Wire protocol and process lifecycle: `docs/ARCHITECTURE.md`
- Permission-gated capture, hotkey, and insert checks: `docs/TESTING.md`
- Model registry and RAM cleanup tiers: `engine/src/velora_engine/models.py`
- Signed-app engine copy (`~/Library/Application Support/Velora/engine`, `.velora-build`): `Sources/Velora/Config/ResourceLocator.swift`
- GitHub `/releases/latest` plus Homebrew tap (both): `docs/RELEASING.md`

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
