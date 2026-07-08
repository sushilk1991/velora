# Velora — project guide

Local-first, on-device macOS dictation app (Superwhisper/Wispr Flow alternative).
STT via whisper-large-v3-turbo, cleanup via an on-device Qwen LLM. Swift menubar
app (SwiftPM, **no Xcode**) + a Python 3.12 `uv` engine talking over a unix
socket at `~/.velora/engine.sock`.

## Versioning (read before cutting a build)

The app version lives in **one place: the repo-root `VERSION` file** (semver
`MAJOR.MINOR.PATCH`). It is the source of truth; `make-app.sh` stamps it into the
bundle's `CFBundleShortVersionString`, and the About screen + DMG name read from
there. **A new build must never ship the same version twice.**

Every `make-app.sh` run bumps the version automatically. Pass the level as the
2nd argument:

| Command | Bump | When |
|---|---|---|
| `./scripts/make-app.sh release` | **patch** (0.1.0 → 0.1.1) | default — bug fixes, small tweaks, rebuilds |
| `./scripts/make-app.sh release minor` | **minor** (0.1.4 → 0.2.0) | a notable batch of new features |
| `./scripts/make-app.sh release major` | **major** (0.9.x → 1.0.0) | a big or breaking release / "much better build" |
| `./scripts/make-app.sh release none` | **none** | throwaway dev rebuild — leave VERSION alone |

You can also bump without building: `./scripts/bump-version.sh [major|minor|patch]`
(prints the new version). `CFBundleVersion` is set to the git commit count, so it
increases monotonically on every build independently of the marketing version.

Rule of thumb the owner asked for: **patch** for little changes, **minor** for
somewhat-bigger feature rounds, **major** for a genuinely better/rewritten build.

## Build & install cycle

```bash
swift build -c release                       # compile (fast iteration)
./scripts/make-app.sh release [level]        # package build/Velora.app (bumps VERSION)
cp -R build/Velora.app /Applications/         # install (quit the running app first)
./scripts/make-dmg.sh                         # optional: build/Velora-<version>.dmg
```

The bundled engine re-syncs to `~/Library/Application Support/Velora/engine` on
relaunch when the `.velora-build` stamp changes (preserves the `.venv`).

Signing: a self-signed "Velora Dev Signing" identity keeps TCC grants (Mic,
Accessibility, Input Monitoring) alive across rebuilds. Ad-hoc signing silently
resets them. See `scripts/make-signing-cert.sh`.

## Engine

- `engine/` — run tests with `engine/.venv/bin/python -m pytest -q` (from `engine/`).
- Models: `engine/src/velora_engine/models.py` (registry + RAM-based cleanup tiers).
  STT keeps both parakeet models (v3 = higher-quality streaming, v2 = cheaper
  English-only) alongside the whisper default.
- Modes: `engine/src/velora_engine/modes_builtin/*.json` are installed to
  `~/.velora/modes/` on first run and never overwritten (except the one-time
  Code/Terminal migration). Editing a built-in in the repo does NOT change an
  existing install — migrate explicitly.

## Conventions

- Push is per-round to `main` of the **private** repo `sushilk1991/velora`.
- Adversarial review before "done": `yoyo ask codex,claude --role review
  --read-only --background "…"` — it has repeatedly caught shipping blockers.
- Deeper project state/history lives in the assistant's memory
  (`velora-project-state.md`), not here.
