## What & why

Brief description of the change and its motivation. Link related issues.

## How it was tested

- [ ] `cd engine && uv run pytest -q` passes
- [ ] `swift build` passes
- [ ] TCC-gated changes (mic/hotkeys/insertion) verified via `make app` + `build/Velora.app`
- [ ] Latency-sensitive changes: `scripts/engine-smoke.py` numbers included below

## Checklist

- [ ] No network calls at dictation time introduced
- [ ] Raw transcript is still always recoverable (history / `cleanup_applied:false` path)
- [ ] Docs updated if the protocol, models, or module responsibilities changed
