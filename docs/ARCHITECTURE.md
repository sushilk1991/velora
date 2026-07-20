# Velora — Architecture

Two processes, one product:

```
┌──────────────────────────── Velora.app (Swift, SwiftPM) ────────────────────────────┐
│ menubar/hotkeys · mic/HUD/insertion · settings/onboarding · consent alerts          │
│ history/intelligence (SQLite) · meeting detector/capture/store · engine supervisor  │
└────────────────────┬──────────────────────────────────────┬───────────────────────────┘
                     │ ~/.velora/engine.sock                │ ~/.velora/control.sock
                     │ framed JSON + raw PCM                │ owner-only newline JSON
┌────────────────────┴────────── velora-engine ─────────┐   ┌┴─────────────────────────┐
│ STT + conservative cleanup · modes · model lifecycle  │   │ installed CLI / MCP stdio│
│ meeting-track transcription · local notes generation  │   │ narrow, default-off API  │
└───────────────────────────────────────────────────────┘   └──────────────────────────┘
```

## Why this shape

- **MLX is required** → Python is where MLX STT/LLM APIs are mature (`parakeet-mlx`, `mlx-whisper`, `mlx-lm`). Pure-Swift MLX STT is not production-ready (swift-parakeet-mlx archived). Research: docs/research/stack-research.md.
- **Native feel is required** → the user-facing surface (menubar, HUD, hotkeys, insertion, settings) is 100% Swift/AppKit/SwiftUI. Python is an invisible inference server.
- **No Xcode project required** → SwiftPM executable + hand-rolled `.app` bundle. Development uses a stable local identity; release builds require Developer ID signing, hardened runtime, notarization, and stapling. The stable bundle id is `com.sushil.velora`; a one-time migration copies missing `velora.*` preferences from the legacy `com.velora.app` domain.
- **Agents should not become a second trust boundary** → the CLI/MCP process never opens the engine socket directly. It asks the running app through a separate owner-only broker, which enforces the preference gate, response projection, single-use microphone consent, and foreground-work arbitration.
- **Meeting capture must remain visible and recoverable** → detection only proposes a recording; the app owns explicit consent, a persistent recording indicator, disk-spooled tracks, retention/deletion, and resumable post-processing.

## Settings persistence and portability

`~/.velora/settings.json` is the typed source of truth for portable app preferences and every known portable engine setting. It has a format identifier and schema version and is written atomically with mode `0600`. On first launch after this change, `AppConfig` migrates the old portable `UserDefaults` values plus default-mode/cleanup flags, streaming cleanup, recording limit, and audio retention/cap into the file. Machine identity, security gates, onboarding/sidebar state, Calendar opt-in, microphone UID, launch-at-login state, and update timestamps remain in the macOS preferences domain and can never enter the portable document.

The engine still owns `~/.velora/config.json`. The app projects speech/language and portable engine settings into it while preserving the machine-selected cleanup model, dictionary keys, and unknown keys. Swift and Python hold the same `config.json.lock` across each read/mutate/atomic-write transaction; Python model changes patch only their owned key, so the two processes cannot lose one another's changes. App writes fail closed when an existing engine config is unreadable, preserving it for recovery. App launch re-projects the engine subset so an installed settings file takes effect.

Settings → General exports that same versioned, portable-by-construction document. Import validates the complete file and rejects malformed values or newer schema versions before writing; a downgraded app also refuses to import over a preserved newer canonical file. During commit, an owner-only `settings.import-backup.json` remains beside the canonical file until engine projection succeeds. Projection failure restores the prior bytes exactly. The app then applies hotkey, HUD, appearance, meeting, and speech-model effects without replaying dozens of persistence observers or starting an updater download. A changed speech model and tighter dictation/meeting audio limits are disclosed before confirmation. Machine-local state remains on the destination Mac. History, recordings, dictionary state, the cleanup model, macOS permissions, and `modes/*.json` have separate lifecycles and are not settings-transfer payloads.

## Process lifecycle

1. App launch → engine supervisor starts `uv run velora-engine` (working dir `engine/`), waits for the `ready` handshake (engine preloads the STT model, then warms the cleanup model and a generic immutable prompt prefix in the background).
2. Crash/hang → supervisor restarts engine with backoff; HUD shows error state if a dictation was in flight; app remains usable (menubar shows degraded state while restarting).
3. App quit → engine terminated (it also self-exits if socket closes / parent pid dies).
4. Idle unload (optional setting): engine drops LLM weights after N min idle to free memory.

## Foreground audio coexistence

Opening a Bluetooth headset microphone makes macOS switch that headset from
high-quality output to its lower-bandwidth two-way voice route. A microphone
explicitly selected in Settings is opened directly, independently of the
output route; choosing the Mac's built-in microphone avoids that Bluetooth
route change entirely.

For foreground dictation, `MediaPlaybackCoordinator` also pauses playback when
Core Audio reports exactly one unambiguous supported player (Music or Spotify)
actively producing output. It verifies that the same process stopped before it
owns any resume obligation, then restores playback shortly after microphone
capture ends. Already-paused, active browser/call, multi-player, quit, manually
resumed, and permission-denied cases never receive a matching toggle. This uses
the existing Accessibility grant and the system media key, not Apple Events or
private MediaRemote APIs. Meeting capture does not use this policy.

## Wire protocol (unix socket, length-prefixed frames)

The Swift app owns the engine's single active control connection. Additional
local clients receive a fatal protocol error and are closed; they cannot
displace an in-flight app dictation. A reconnect is accepted after the owner
disconnects.

Frame = `u32 length (LE) | u8 type | payload`.

Types:
- `0x01 JSON` — control, newline-free JSON object.
- `0x02 AUDIO` — raw PCM chunk: 16kHz mono Float32 LE.

Startup events are intentionally split: `ready` means the speech model can
accept dictation and carries a `setup_complete` snapshot, while `loading`
carries first-run model download phase/fraction. If the snapshot is false, a
later `setup_complete` event marks both speech and writing model setup done.
The app uses this completion signal only to unlock onboarding's guided first
try; normal dictation remains available at `ready`.

Control flow for one dictation:
```
app → engine  {"cmd":"start","session":"uuid","context":{"bundle_id":"com.tinyspeck.slackmacgap",
               "app_name":"Slack","mode":null,             # mode:null = auto-resolve
               "entities":[{"type":"file","value":"authCheck.ts"},   # screen context (AX)
                           {"type":"person","value":"Priya"},{"type":"site","value":"gmail"}]}}
app → engine  AUDIO frames (streamed live during recording, ~100ms chunks)
app → engine  {"cmd":"stop","session":"uuid"}             # user released hotkey
engine → app  {"event":"partial","session":"...","text":"..."}       # optional, P1 HUD display
engine → app  {"event":"transcript","session":"...","raw":"...","ms":412}
engine → app  {"event":"final","session":"...","text":"...","raw":"...","mode":"chat",
               "cleanup_ms":389,"cleanup_applied":true,"audio":"uuid.flac"}   # audio present when archived
```
Other commands: `cancel`, `ping`, `status`, `reload_config` (modes/vocab changed), `set_model`, `reprocess`.

## Local control protocol (CLI and MCP)

The installed `Resources/bin/velora` executable is a symlink to the app binary. Only that exact bundle-relative `Resources/bin/velora` location (or an explicit `--cli`) selects headless one-shot/MCP mode rather than AppKit; merely renaming a copy of the app binary does not. It connects to `~/.velora/control.sock`; the running app remains the authority for every request.

- AF_UNIX only: no TCP listener and no remote access.
- `~/.velora` is forced to mode `0700`; the socket is `0600`; `getpeereid` must equal the app's effective UID.
- One newline-delimited JSON request (maximum 1 MiB) and one bounded response per connection. The client keeps the connection open until that response; a full disconnect cancels only that request's in-flight action. Eight client workers cap concurrent work without blocking the accept loop.
- App shutdown closes the listener and every accepted client, revokes pending microphone consent, and locally completes active listen/file jobs before engine teardown. An approval response can never reopen capture after the lifecycle gate closes.
- `status` works while access is disabled so clients can explain how to opt in. `recent`, `search`, `stats`, `transcribe`, and `listen` require **Allow local CLI and agents**.
- History/search responses are projected to an explicit schema. They omit raw transcript, bundle id, audio/session paths, screen context, contacts, quality-learning state, and internal identifiers.
- `transcribe` returns cleaned text to that client only: it does not touch clipboard, write a sidecar, display the dictation HUD, or paste into an app.
- `listen` requires a visible approval for each call. It captures no AX screen context and never pastes. Cancellation or failure completes the external request and cannot fall through into the normal insertion path.
- MCP uses protocol version `2025-06-18` over stdin/stdout and exposes the same six allow-listed operations; it does not widen the broker's authority.

The control socket is deliberately separate from `engine.sock`. The engine socket carries PCM and privileged model controls for one app-owned connection; exposing it would bypass the app's policy and lifecycle checks.

## Private Meeting Memory

`MeetingDetector` polls local call-app/window metadata for Zoom, Teams, Slack Huddles, and browser-hosted Google Meet. Calendar matching is independent and opt-in. Detection only emits a candidate; `MeetingCoordinator` must show an explicit consent alert before capture starts, and a compact persistent HUD plus the menu-bar surface stay visibly in the recording state.

Capture preserves provenance instead of inventing diarization:

1. A directly selected `AVCaptureDevice` writes the microphone track (`Me`) as linear PCM in a CAF container. This keeps the chosen microphone independent of an AirPods/default output route. CAF can extend its audio-data chunk to end-of-file, so frames already flushed remain readable after a hard process termination.
2. An audio-only Core Audio process tap writes computer audio (`Them`) as a separate crash-resilient CAF track. It never requests display or window frames. Capture is not declared healthy until both requested tracks deliver frames; if computer audio fails, the persistent HUD says `Mic only` and keeps Stop available.
3. `MeetingStore` writes a recording row before capture begins, then keeps metadata/transcripts/notes in a separate owner-only `~/.velora/meetings` tree and SQLite/FTS database. Audio paths are validated as private-root-relative before use. Graceful app quit revokes pending consent and finalizes active capture; after a crash, audio that reached disk is preserved as a recoverable failed meeting while empty preparations are removed. Interrupted processing resumes automatically, but a permanently failed recording requires an explicit retry and repeated engine restarts are capped.
4. `MeetingProcessor` transcribes each speaker track in bounded time chunks, checkpoints completed chunks, and resumes interrupted work. It then runs a chunked map/reduce notes pass for summary, decisions, and action items.
5. Foreground dictation preempts meeting post-processing. Capture itself is disk-spooled; post-processing decodes one source track at a time.

The UI fetches meeting metadata in pages and loads a full transcript only for the selected meeting. Users can search, retry processing, play/export local tracks, or delete a meeting and its audio.

**Smart context (hybrid).** At session start the app reads the frontmost app's focused-window title via the Accessibility API (already-granted; no Screen Recording, ~5ms, capped at 0.25s) and extracts `entities` — current file (editors), person/channel (chat), subject (mail), site (browser: Gmail/Docs/Notion/Linear…). The engine (`formatting.py`) uses them to: (1) feed exact names/spellings into the cleanup prompt; (2) turn spoken **@-tags** into tokens ("tag authCheck" → `@authCheck.ts`, "mention Priya" → `@Priya`, conservative to avoid tagging ordinary prose); (3) refine a browser's mode by site. A small on-device VLM screen-read for thin-AX Electron editors is the planned second half of the hybrid.

**Audio archive + reprocess.** When `save_audio` is on (default), each session's
raw PCM is written to `~/.velora/audio/<session>.flac` (FLAC via libsndfile,
~5× smaller than 16-bit WAV; 0600). The `final` event then carries `audio` (the
clip basename), which the app stores in history. Retention runs on engine start
and after each save: clips older than `audio_retention_days` (default 180) are
deleted, then a total-size cap (`audio_max_mb`, default 4096) evicts oldest-first.
Reprocessing re-transcribes a saved clip, optionally with a different model:
```
app → engine  {"cmd":"reprocess","audio":"uuid.flac","id":42,
               "stt_model":"mlx-community/whisper-large-v3-mlx","mode":null,"language":"hi"}
engine → app  {"event":"reprocessed","id":42,"audio":"uuid.flac","raw":"...","text":"...",
               "mode":"Default","stt_model":"...","stt_ms":1830,"cleanup_ms":0,"cleanup_applied":false}
```
A model different from the live one is loaded once and cached across reprocess calls.

**STT models.** Default is `whisper-large-v3-turbo` (multilingual — Hindi, Indian
English, and the top world languages; batch decode on stop). The picker also
offers full `whisper-large-v3` (highest accuracy), a Hindi/Hinglish specialist,
and the parakeet models (English/European, live streaming partials). Non-Latin
transcripts (Devanagari, CJK, Arabic) skip the English-tuned cleanup LLM and take
the deterministic path — see the formatting gate. Opt-in `romanize_output` instead
routes non-Latin text through the multilingual LLM to transliterate it into the Latin
alphabet (Hindi → natural Hinglish; the words are kept, not translated). The length-ratio
divergence guard is disabled for that pass since transliteration changes length.

**Latency budget:** the default Whisper model emits non-committing preview decodes after a pause or bounded interval so the HUD can show readable partial text before release. On `stop`, its authoritative final decode still covers every audio sample. Cleanup prepares the exact stable prompt prefix during recording, snapshots that immutable cache, and forks it for preview/chunk/final generation. The adaptive soft deadline begins at the first output token; a separate outer watchdog bounds stalled prefill or generation. If cleanup exceeds its budget, is cancelled, or fails, the engine emits `final` with `cleanup_applied:false` carrying the raw transcript. Raw is always retained in history.

**Streaming segment pipeline (whisper, smartness-v2):** preview-only decoding begins at 4s after ≥0.4s silence (or at an 8s hard preview interval) and requires ≥3s of new audio before another preview. Preview decoding never advances committed sample offsets or mutates final segment state. The backend commits a segment when ≥10s of un-decoded audio meets a ≥0.7s pause (energy VAD; hard cap 25s), and the server starts that segment's LLM cleanup while the user is speaking. Superseded chunk work receives cooperative cancellation. On `stop`, dictations ≤45s re-decode the whole clip and clean once; longer ones stitch committed segments and decode/clean the tail. Any failure falls back to the whole-text path, so the fast path cannot lose transcript content. Config: `streaming_cleanup` (default true).

## Smart formatting policy (the "smart as Wispr Flow" part)

Two stages, both local:

1. **Deterministic gate (no LLM):** decides *if* and *how much* AI touches the text.
   - mode resolution: explicit user mode > per-app rule from mode files > default.
   - Raw stays formatting-off. Terminal input below 12 words stays model-free and command-safe (explicit new-line controls still work).
   - very short utterances (< ~6 words) → punctuation-only, never restructured.
2. **LLM pass (Qwen3.5-4B MLX 8-bit on quality-tier Macs):** one prompt assembled from mode instructions, formatting strength, vocabulary hints, and app context. Code mode uses a conservative technical prompt; longer Terminal prose uses its terminal-aware prompt. Stable instructions and vocabulary precede volatile entities so the engine can prefill and snapshot the shared prefix. Strict rules are baked in: *transcribe-don't-answer*, preserve meaning, add no content, fix clear agreement/tense/speech artifacts, punctuate complete thoughts, apply self-corrections, and structure lists only when speech enumerates. Output is text only.
   - Anti-over-editing guard: if LLM output diverges too far from raw (length-ratio/similarity heuristic), fall back to raw. Principle #4 of the spec.

Mode files: `~/.velora/modes/*.json` — `{name, prompt, formatting: off|light|full, apps: [bundle ids], vocabulary: [...], replacements: {...}}`. Built-ins copied on first run; user-editable.

## Swift app modules (Sources/Velora/)

| Module | Responsibility |
|---|---|
| `App/` | main, AppDelegate, activation policy, engine supervisor |
| `Capture/` | Direct AVCapture microphone source, 16kHz mono Float32 conversion, RMS levels for HUD |
| `Hotkey/` | CGEventTap (hold + double-tap detection), Esc-cancel monitor, secure-input detection (`IsSecureEventInputEnabled`) |
| `Context/` | NSWorkspace frontmost app tracking, AX focused-element probe (secure field check) |
| `HUD/` | NSPanel host + SwiftUI capsule (state machine per design brief), Canvas waveform |
| `Insert/` | pasteboard snapshot → ⌘V → restore; CGEvent unicode typing fallback; per-app overrides |
| `EngineClient/` | socket client, framing, request/event routing |
| `Settings/` | SwiftUI settings tabs + onboarding flow, permission checks |
| `History/` | SQLite (raw SQL, no deps) store + menubar recents |
| `Control/` | owner-only local broker, CLI, MCP stdio server, response projection |
| `Meetings/` | candidate detection, explicit-consent orchestration, two-track capture, private store, resumable processing |
| `Config/` | app config + mode file loading/watching |

Concurrency: Swift 5 language mode (`.swiftLanguageMode(.v5)`) to avoid strict-concurrency friction with AVAudio/CGEventTap (spike finding); audio tap → lock-free level publishing to main actor.

## Engine modules (engine/src/velora_engine/)

| Module | Responsibility |
|---|---|
| `server.py` | asyncio unix-socket server, framing, session state machine |
| `stt.py` | parakeet-mlx streaming wrapper; mlx-whisper fallback backend behind one interface |
| `cleanup.py` | mlx-lm load/generate, immutable prefix snapshot/fork, cancellation, TTFT-aware deadline, divergence guard |
| `formatting.py` | deterministic gate, mode resolution, prompt assembly, replacements |
| `models.py` | HF download/verify, model registry (user-selectable) |
| `config.py` | modes/vocab loading shared with app via ~/.velora/ |
| `media.py` | audio decode and exact-coverage meeting chunk planning |
| `meeting_notes.py` | schema-checked chunk/map-reduce meeting summaries, decisions, and actions |

## Permissions (TCC)

| Permission | Needed for | When requested |
|---|---|---|
| Microphone | capture | onboarding step 2 (NSMicrophoneUsageDescription in bundle Info.plist) |
| Accessibility | CGEventTap hotkeys + ⌘V posting + AX context | onboarding step 3, live-polled |
| Input Monitoring | reliable global hotkey event delivery | onboarding alongside Accessibility |
| System Audio Recording | remote meeting track via an audio-only Core Audio process tap | first explicitly confirmed meeting recording |
| Calendar Full Access (optional) | match nearby events to call-app candidates | only when the Calendar meeting toggle is enabled |

Spike finding: grants must be earned by the signed .app bundle (stable ad-hoc identity), not the bare binary; bare-binary tests mislead due to responsible-process attribution.

## Repo layout

```
Velora/
├── Package.swift            # SwiftPM app
├── Sources/Velora/...
├── engine/                  # uv project (pyproject.toml)
│   ├── src/velora_engine/...
│   └── tests/               # engine pytest + protocol/meeting integration tests
├── Resources/               # Info.plist, sounds, icon
├── scripts/                 # make-app.sh, make-sounds.sh, engine-smoke.py
├── docs/                    # SPEC, ARCHITECTURE, research/
├── Makefile                 # build / run / test / app / sounds
```

## Testing strategy

- Engine unit/integration tests (`make test`): formatting, protocol framing, cancellation and shutdown terminal events, STT/cleanup fallbacks, media chunk coverage, meeting-note schemas, and real socket flows.
- App: the executable's `--selftest` path covers config/migrations, history/Intelligence SQL and privacy invariants, control protocol projection/limits/socket ownership, MCP framing/tools, meeting detection/store/recovery, and state-machine regressions without requiring TCC.
- Performance: `make perf-test` seeds 100,000 history rows and times the production `HistoryStore.insights()` plus first-page query. Meeting media tests include a sparse one-hour track and exact chunk coverage.
- Package: both debug and release binaries run self-tests; the built `.app` is exercised through its installed CLI, live app broker, file transcription, and MCP stdio path.
- Release: Developer ID identity/team, hardened runtime, timestamp, embedded provisioning entitlements, notarization ticket, DMG signature, and Gatekeeper acceptance are verified before install/smoke testing.
- Manual TCC/UI gates: real hotkey insertion, per-request agent consent, meeting system-audio capture, and Settings/Intelligence/Meetings visual inspection run from the signed app in an unlocked console session.
