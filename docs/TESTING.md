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
| Password/secure field | No text is inserted |
| Normal text field with a non-text clipboard item | Text lands once and the original clipboard is restored |
| Quit during dictation or meeting capture | Capture stops, media state is restored, and recoverable meeting audio is finalized or retained |
| Signed release DMG | Signature, notarization, staple, Gatekeeper, bundle identity, and packaged engine/CLI/MCP runtime checks all pass |

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
