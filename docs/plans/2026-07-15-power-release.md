# Velora Power Release — implementation and verification plan

Date: 2026-07-15

## Goal

Ship one verified release containing three cohesive capabilities without weakening
Velora's local-first trust boundary or regressing the existing dictation loop:

1. Voice Intelligence & Learning
2. Agent-native Voice Workflows
3. Consent-first Private Meeting Memory

The release is done only when the installed, signed app proves the real user flows.
A passing unit suite or a successful DMG build alone is not the done signal.

## Release boundary

### 1. Voice Intelligence & Learning

Ship a dedicated Intelligence tab backed entirely by the local history database:

- today/week/month/all-time words, dictations, speaking time, and calibrated time saved
- current/longest streak, daily activity series, app and mode breakdowns
- latency and cleanup-quality summaries when the underlying rows contain the data
- honest zero-edit rate with a separately displayed observation-coverage percentage
- learned-term count and correction trend
- a privacy-safe share card rendered locally, with user-selected aggregate metrics and
  no transcript, app, contact, or meeting content

The existing History header remains a compact summary. The Intelligence tab becomes
the deep surface. Existing rows continue to load after additive migrations.

### 2. Agent-native Voice Workflows

Ship a small local control plane and a bundled `velora` CLI:

- `velora status`
- `velora listen [--mode NAME] [--json]`
- `velora recent [--limit N] [--json]`
- `velora search QUERY [--limit N] [--json]`
- `velora transcribe FILE [--mode NAME] [--json]`
- `velora mcp`, exposing the safe read/request tools over stdio

The CLI talks to an owner-only Unix socket created by the running app. A remote client
can request dictation, but it can never start an invisible recording: local-agent
access is off by default, every remote recording request requires an in-app approval,
the normal HUD and sound run, the user explicitly stops/cancels, and only one request
may be pending. Read-only history and stats calls never synthesize input. No arbitrary
shell execution ships in this release.

Modes remain the workflow format. An explicit mode supplied by the CLI is passed to
the existing engine context rather than creating a second prompt system.

### 3. Consent-first Private Meeting Memory

Ship a Meetings tab and menubar entry with this complete first-version journey:

- optional Calendar permission and upcoming-event matching
- local meeting-app detection using running apps and bounded Accessibility metadata
- an explicit prompt/suggestion; capture never silently starts by default
- a clear, persistent recording indicator and start/stop/cancel controls
- microphone plus system-audio capture through ScreenCaptureKit, with an explicit
  mic-only fallback when the OS, source, or permission cannot provide system audio
- local transcription and structured notes: summary, decisions, action items
- searchable meeting history with transcript and timestamp/source context
- local recall across saved meetings with cited source snippets
- export/copy, audio-retention control, and complete deletion

For the first release, microphone and system audio are retained as separate source
files and transcribed separately after stop. `Me` versus remote audio is therefore
known by channel without degrading recognition through an overlapped mix. Multi-remote-
speaker diarization is not required for this release and must not be faked.

## Explicit non-goals

- silent automatic meeting recording
- team workspaces, cloud accounts, hosted sharing, or transcript upload
- direct CRM/Slack/Notion OAuth integrations
- arbitrary shell hooks or actions that mutate external state without confirmation
- multi-remote-speaker diarization presented as reliable before it is measured
- vanity leaderboards or public profiles

## Architecture

```text
                           Velora.app
 ┌───────────────────────────────────────────────────────────────────┐
 │ DictationController ───────┐                                     │
 │ MeetingCoordinator ────────┼─ EngineSupervisor ─ unix socket ─┐  │
 │ LocalControlServer ────────┘                                  │  │
 │       │                                                       │  │
 │       ├─ HistoryStore ─ dictations + quality                  │  │
 │       ├─ MeetingStore ─ meetings + segments + FTS             │  │
 │       ├─ MeetingDetector ─ EventKit + NSWorkspace + AX        │  │
 │       ├─ MeetingAudioCapture ─ AVAudioEngine + ScreenCaptureKit│  │
 │       └─ Settings tabs ─ Intelligence + Meetings              │  │
 └───────────────────────────────────────────────────────────────┼──┘
                                                                 │
                              velora-engine                      │
 ┌───────────────────────────────────────────────────────────────▼──┐
 │ existing STT/cleanup + meeting transcription/mix/note commands  │
 └──────────────────────────────────────────────────────────────────┘

 Bundled `velora` CLI ─ owner-only control socket ─ Velora.app
         └─ `velora mcp` (stdio JSON-RPC; no network listener)
```

## Data and privacy invariants

- Every new database/file is created owner-only (`0600` files, `0700` directories).
- Meeting audio uses `~/.velora/meetings/` and an independent retention budget; it
  never competes with or silently evicts the dictation audio archive.
- Calendar access is optional and requested only from the Meetings surface.
- ScreenCaptureKit capture is user-visible and consent-first.
- Share cards contain aggregates only.
- MCP and CLI never receive transcript history unless the user invokes a read tool.
- Search answers cite stored local sources; generated claims never appear uncited.
- Cancelling meeting capture removes temporary audio and creates no meeting row.
- A failed post-meeting transcription preserves recoverable local audio and an explicit
  failed state instead of losing the meeting.
- Meeting transcription is resumable and disk-spooled; it never reuses the bounded
  live-dictation session or sends whole recordings through a control frame.
- Post-meeting notes are produced by a chunked, preemptible idle job so live dictation
  always retains priority over long-transcript generation.

## Work sequence

1. Add Swift test infrastructure and additive data-model migrations.
2. Implement quality observation and the Intelligence data/query layer.
3. Build the Intelligence UI and share-card renderer.
4. Add the local control socket, CLI, and MCP adapter using existing modes/history.
5. Add meeting store, detector, capture, coordinator, and UI.
6. Add engine resumable meeting-transcription and preemptible note commands.
7. Integrate menus, permissions, packaging, docs, and self-tests.
8. Run automated, real-model, app-bundle, permission, capture, and release QA.

## Verification matrix

### Automated

- Existing Python engine suite remains green.
- New engine tests cover meeting input validation, audio mixing, cancellation, note
  formatting, long transcript chunking, and failure recovery.
- Swift unit tests cover migrations, aggregate windows, streaks, zero-edit coverage,
  share-card privacy, meeting state transitions, detection scoring, control-protocol
  parsing, CLI output, and owner-only socket/file creation.
- `swift build` and release build pass from a clean derived-data state.
- Existing engine smoke and self-test commands pass.

### Local integration

- Dictation works in TextEdit, Messages/Slack-like input, Notes, and Terminal.
- A CLI-requested dictation visibly starts, can be cancelled, returns the exact result,
  and cannot overlap another session.
- CLI history/search JSON is valid and never leaks unrelated fields.
- MCP initialize, tools/list, and tools/call work from a clean stdio client.
- Agent access defaults off; remote recording approval, denial, timeout, and overlap
  rejection are all exercised.
- A generated share card is visually inspected and its rendered strings contain no
  transcript/app/contact data.
- Meeting detection is checked for Calendar-only, Zoom, Slack Huddle, and browser Meet
  signals, including false-positive suppression.
- A real system-audio + microphone recording is captured, stopped, transcribed, turned
  into notes, searched, replayed/exported, and deleted.
- Denied Calendar or Screen Recording permission leaves normal dictation fully usable.
- Engine/app restart during meeting processing yields a visible recoverable failure.

### Performance and longevity

- 60-minute synthetic meeting path does not grow memory without bound.
- Meeting capture does not starve the main thread or hotkey event tap.
- Intelligence queries over 100,000 synthetic dictations complete without loading all
  rows into Swift memory.
- Idle CPU remains below the existing product target when meeting detection is enabled.

### Release

- build the app and DMG with a new version
- verify Developer ID signature, hardened runtime, entitlements, Team ID, embedded
  provisioning profile, Gatekeeper assessment, notarization, and stapling
- install into `/Applications`, restart the real app/engine, and repeat critical smoke
- publish the GitHub release only after the installed artifact passes

## Stop-ship conditions

- any existing dictation regression
- invisible or ambiguous recording state
- world-readable transcript/audio/socket files
- uncited meeting-memory answers
- unbounded memory growth on long capture
- CLI/MCP ability to start hidden capture or execute arbitrary commands
- unsigned, unnotarized, unstapled, or locally unverified release artifact
