# Velora test matrix

This matrix keeps coverage tied to user-visible behavior. A green unit suite
does not replace real permission, audio-route, insertion, or signed-app checks.

## Automated gates

| Surface | Command | What it proves |
|---|---|---|
| Mac app | `make test-swift` | Deterministic state, storage, privacy, protocol, HUD, media-control, capture-policy, and update behavior |
| Engine | `make test-engine` | Speech, cleanup, formatting, meetings, audio storage, model fallback, and socket behavior with fake model backends |
| Engine coverage | `make test-coverage` | At least 80% branch coverage; review low-coverage risk areas instead of chasing a headline percentage |
| Public site | `make test-site` | Local assets resolve; navigation targets are valid; scripts and styles remain self-hosted; common trackers are absent |
| Release scripts | `make test-release-scripts` | Distribution credentials fail closed and the DMG verifier requires a complete bundled engine, CLI, and `uv` runtime |
| iPhone | `make test-ios` | Formatting, clipboard delivery, history durability, finalization policy, preferences, and shortcut handoff |
| Performance | `make perf-test` | Mac self-tests plus the 100,000-row history benchmark |

`make test` runs the first-line Mac, engine, site, and release-script gates
without requiring Xcode or macOS privacy grants.

## Hardware and permission gates

Run these when capture, permissions, hotkeys, insertion, meetings, packaging,
or updates change:

| Scenario | Expected result |
|---|---|
| `make test-live-audio` | The selected microphone, converted microphone stream, computer-audio tap, and combined meeting capture all deliver frames |
| AirPods with Apple Music or Spotify playing | Dictation pauses supported playback before opening the microphone and resumes only playback Velora paused |
| Hold, release, and cancel while an AirPods route is still opening | The request finishes or cancels without a stuck HUD, orphaned capture, or unwanted media resume |
| Meeting with microphone and remote audio | Recording starts only after confirmation; the compact indicator remains visible; both audio-only tracks are saved and processed |
| Computer-audio permission denied | Velora explains that no screen is captured, continues as mic-only when possible, and keeps Stop visible |
| Microphone fails during a meeting | Recording stops visibly and already-captured audio remains recoverable |
| Microphone, input-monitoring, or accessibility denied | The app gives the correct recovery action and does not claim to be listening or inserted |
| Password/secure field | No text is inserted, and no action plan runs |
| Voice action against a real app (`velora action "…" --execute`) | The named app comes forward and the plan runs; a plan that cannot confirm the target window stops without typing |
| Voice action with the screen locked | The plan fails with "the screen is locked" and opens nothing |
| Voice action while the target conversation is wrong | Only the switcher query is typed; the message body is never sent |
| Normal text field with a non-text clipboard item | Text lands once and the original clipboard is restored |
| Quit during dictation or meeting capture | Capture stops, media state is restored, and recoverable meeting audio is finalized or retained |
| Signed release DMG | Signature, notarization, staple, Gatekeeper, bundle identity, and packaged engine/CLI/MCP runtime checks all pass |
| Software update window | Full release-note structure is readable; closing a manual changelog changes nothing; closing an automatic prompt defers only that version; one Install click downloads, verifies, replaces a disposable app copy, and relaunches that copy; a local-feed E2E leaves the real Skip/Later/check preferences unchanged |

## Local history performance baseline

Run the history benchmark locally from `engine/` with every input and output
path explicit:

```bash
.venv/bin/python scripts/benchmark_history_performance.py \
  --db "$HOME/.velora/history.sqlite3" \
  --audio-root "$HOME/.velora/audio" \
  --json /tmp/velora-history-performance.json
```

The tool opens SQLite with URI `mode=ro` plus `query_only`, never migrates or
updates history, and writes the JSON output owner-only (`0600`). It does not
load `raw` or `final` transcript bodies into Python: SQLite returns only their
character counts. The report contains aggregate counts, p50/p95 timing and
length metadata, duration buckets, and a derived recovery-wait residual. That
residual is `max(0, finalization_ms - stt_ms - cleanup_wall_ms)` and is an upper
bound because it can include small orchestration costs. Legacy rows report
missing metric counts rather than being treated as zero.

For a private replay manifest stratified by the 10/25/60-second duration
buckets and mode, add:

```bash
  --select-corpus /tmp/velora-history-corpus.json
```

The deterministic manifest contains only local audio references, mode names,
and durations—never transcript text. It still points at private archived audio,
so keep it under `/tmp`, do not upload it, and do not commit it or the report.

## Coverage rules

- Every production bug gets a regression at the lowest layer that reproduces
  the failure. Use a real-device gate as well when macOS or iOS owns the failing
  behavior.
- New engine branches must keep `make test-coverage` above the checked-in gate.
- New deterministic Swift behavior belongs in the Mac self-test or iPhone
  XCTest target. Do not leave pure policy hidden inside an untestable UI type.
- Audio, Accessibility, App Intents, and permission dialogs require hardware or
  simulator evidence. Their line coverage is not a substitute for the scenario
  matrix above.
- A timed-out, skipped, or unavailable gate is not a pass. Record it explicitly
  in the pull request or release notes.
