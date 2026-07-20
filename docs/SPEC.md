# Velora — Product Specification

Velora is an open-source, local-first dictation app for macOS. Hold a hotkey, speak, release — polished text appears in whatever app you're using. All inference (speech-to-text and LLM cleanup) runs on-device via MLX on Apple Silicon. No audio or text ever leaves the machine.

**Positioning:** the open-source answer to Superwhisper and Wispr Flow, with Wispr Flow's feel (invisible, fast, smart) and Superwhisper's customizability (modes, prompts, vocabulary) — minus the cloud, the subscription, and the trust problem. Wispr Flow transcribes in the cloud; Velora never makes a network request after models are downloaded.

## Product principles

1. **Local-first is the product.** Zero network calls at dictation time. Privacy is architectural, not a toggle.
2. **Invisible until needed.** A capsule HUD that never steals focus; a menubar item; nothing else.
3. **Never lose the user's words.** Raw transcript is always recoverable from history, even when AI cleanup mangles it. Esc always cancels cleanly.
4. **Don't over-edit.** The #1 Superwhisper complaint is AI polish changing intent (answers instead of transcription, hallucinated rewrites). Cleanup is conservative by default; formatting strength is user-controllable per mode.
5. **Fast enough to trust.** Text lands < 1.5s after release for typical utterances. If cleanup would be slow, insert raw text fast rather than making the user wait.
6. **Detection is not consent.** A call app or calendar event may justify a suggestion, never silent recording. Meeting capture and agent-requested microphone use require an explicit, visible approval every time.
7. **Useful local data should stay legible.** Stats, meeting memory, and agent workflows may derive value from private data, but must expose narrow results, honest coverage, deletion controls, and no hidden network boundary.

## P0 — v1 must-have

### Capture & flow
- Menubar app (LSUIElement, no dock icon), SwiftPM-built, hand-rolled `.app` bundle; stable local signing for development and Developer ID signing/notarization for distribution.
- **Hold-to-talk** (default: hold Right-Option) and **toggle mode** (default: double-tap Right-Option or menubar click). Hotkey configurable.
- Floating capsule HUD per design spec (docs/research/design-brief.md): listening → transcribing → inserted/error state morphs, live 24-bar waveform from mic RMS, never takes focus.
- Esc cancels recording; nothing is inserted.
- Start/stop sounds (synthesized, per design spec), toggleable.

### Transcription & intelligence
- On-device STT via MLX (model per ARCHITECTURE.md; user-selectable in settings with size/speed table and download manager).
- On-device LLM cleanup via mlx-lm (quality-tier Qwen model):
  - remove filler words (um, uh, "you know") — conservative,
  - apply self-corrections ("no wait, I meant Tuesday" → "Tuesday"),
  - punctuation, capitalization, paragraph breaks,
  - honor spoken commands: "new line", "new paragraph".
- **Smart formatting (app-aware):** frontmost app bundle id + focused-field context select the active mode automatically:
  - chat apps (Slack, Messages, Discord) → casual, no trailing period on single sentences, keep it terse,
  - email (Mail, Gmail in browser) → greeting/paragraph structure, professional tone,
  - notes/docs (Notes, Obsidian, Notion) → markdown allowed, lists when speech enumerates,
  - code editors → conservative technical cleanup that preserves identifiers, flags, paths, and command punctuation; terminals keep short commands (< 12 words) model-free and command-safe, while longer dictated prose gets conservative punctuation and grammar cleanup without changing meaning,
  - everything else → default mode.
- Formatting decides *whether* to format, not just how: short fragments and commands pass through nearly untouched; long multi-sentence speech gets structure (lists when the user enumerates, paragraphs on topic shifts).
- Secure-input fields (passwords): detected → insertion suppressed with error HUD state.

### Modes (Superwhisper-style, config-file-first)
- Built-in: **Raw** (no AI), **Default**, **Message**, **Email**, **Note**, **Code**, **Terminal**.
- Every mode = a JSON file in `~/.velora/modes/`: system prompt, formatting strength (off/light/full), vocabulary hints, app-activation rules (bundle ids). Custom modes = drop in a file. GUI editing is P1; the format is the API.
- Global vocabulary list (proper nouns, jargon) injected into STT prompt + cleanup prompt. Text replacements (e.g. "vs code" → "VS Code") applied post-cleanup.

### Insertion
- Pasteboard save → set → synthesized ⌘V → restore, with CGEvent-typing fallback for apps that block paste. Per-app override list.
- Clipboard contents always restored.

### History & Voice Intelligence
- Local SQLite history: timestamp, app, raw/final transcript, duration, mode, STT/cleanup latency, cleanup outcome, archived audio reference, and optional edit-quality observation. Menubar shows last 3; the History tab supports search, copy, paste-again, playback, and reprocessing.
- Intelligence windows: today / 7 days / 30 days / all time, with words, dictations, speaking time, estimated typing time saved, current/longest streak, 30-day activity, app and mode breakdowns, STT/cleanup latency, and cleanup rate.
- Zero-edit rate includes only sessions the Accessibility observer could judge. The UI must show observation coverage separately; unknown legacy/unobservable rows are never counted as successful.
- Estimated time saved uses a user-configurable typing speed (default 40 WPM) and measured speaking duration, frozen when recording stops.
- Share cards are aggregate-only by construction: fixed labels, selected period, and numeric totals. Transcript, app, mode, contact, calendar, and path strings have no renderer input.

### Private Meeting Memory
- Detect active Zoom, Teams, Slack Huddle, and browser Google Meet surfaces from local metadata; optionally match nearby Calendar events after a separate permission grant.
- Detection can only show a recording suggestion. Manual and detected meetings both require explicit confirmation before microphone/system-audio capture begins, plus a persistent compact HUD and menu-bar recording indicator with a clear stop/discard path.
- Preserve microphone as `Me` and computer audio as `Them` in separate local tracks. Do not infer or claim individual remote-speaker identity. Use audio-only capture for the system track; never request screen frames. Do not claim recording is healthy until requested tracks deliver frames. If system audio fails, show `Mic only` persistently with Stop available.
- Store meeting metadata, audio, transcripts, notes, actions, and decisions under a separate owner-only `~/.velora/meetings` root. Support local retention, search, playback, export, retry, and complete deletion.
- Capture is disk-spooled. Transcription and notes are checkpointed by speaker/chunk, resumable after interruption, and yield priority to live dictation.

### Local CLI & MCP
- Ship an installed CLI with `status`, `recent`, `search`, `stats`, `transcribe`, `listen`, and `mcp` commands plus JSON output.
- The app exposes an owner-only AF_UNIX control broker; no TCP/network endpoint. History/stats/actions are off by default and require an explicit Settings toggle. `status` remains available while disabled.
- Project history/search through an allow-list that omits raw transcript, bundle ids, audio/session paths, screen context, contacts, and learning state.
- File transcription returns only to the requester and cannot paste, mutate the clipboard, or write an implicit sidecar.
- Every live `listen` request requires visible one-time approval, captures no screen context, and cannot paste into the foreground app.
- MCP is a stdio adapter over the same broker capabilities and policy, not a privileged second API.

### Settings & onboarding (world-class bar, per design brief)
- Settings: General / Dictation / Dictionary / Model / Modes / History / Intelligence / Meetings / Shortcuts / About tabs, grouped forms, 580pt content width.
- Persist typed portable app preferences in an owner-only, versioned `~/.velora/settings.json`. General provides export/import with whole-file validation, overwrite confirmation, atomic apply/rollback, and live runtime refresh. Keep the hardware-selected cleanup model and machine/security state outside that document; never import permissions, device identifiers, onboarding state, Calendar/local-agent grants, history, recordings, dictionary entries, or custom modes as settings.
- Onboarding: 5-step premium flow (welcome → mic permission → accessibility permission with live-polling grant detection → hotkey → try-it playground). Finish gated on one successful dictation.
- Permissions degrade gracefully: degraded state shows menubar error icon + "Check Permissions…".

### Performance targets (M-series, measured in CI-able bench script)
- End of speech → text inserted: **< 1.5s** for ≤ 15s utterances (STT streaming/chunked so most transcription happens during speech).
- Cleanup adds **< 1.5s** for a typical utterance or is skipped (raw inserted, cleanup result available in history). Its adaptive generation deadline starts at the first output token, with a separate hard watchdog for stalled prefill or generation.
- Idle: < 400MB RSS for app + engine with models unloaded-after-idle option; < 1% CPU idle.
- Cold start to ready: < 4s with default models cached.

## P1
- Per-mode hotkeys.
- Browser URL awareness (Gmail vs Docs in Chrome) via Accessibility.
- Selected-text context ("rewrite this") — transformation mode.
- Launch-at-login, Sparkle-style updates (or brew cask).

## P2
- Voice commands ("send it", "delete last sentence").
- Additional explicit scripting hooks beyond the narrow CLI/MCP surface.
- iOS companion.

## Non-goals
- No cloud inference of any kind. No accounts, telemetry, or analytics.
- No screen-content context (screenshots/OCR) — trust-destroying; explicit opt-in someday at most.
- No silent or autonomous meeting recording. Detection never implies consent.
- No claimed individual-speaker diarization from the remote/system track; `Me` and `Them` are audio-channel labels only.
- No remotely reachable agent API and no direct third-party access to the privileged engine socket.
- No Windows/Linux.

## Current release success criteria
1. E2E on real audio: speech in any focused app → correct, well-formatted text inserted, within targets.
2. App-aware behavior verified across at least: TextEdit (default), a chat-style target, a code-style target.
3. Full pipeline verified with sample audio from the internet (JFK clip + long-form sample).
4. Buildable from clean checkout with `make build` (SwiftPM + uv, no Xcode), open-source ready (README, LICENSE, CONTRIBUTING).
5. Intelligence migrations, privacy invariants, and production SQL remain responsive with a 100,000-row history.
6. A signed app can capture a confirmed meeting's microphone and computer-audio tracks, process/resume them into searchable notes, and fully delete the test record and audio.
7. Disabled/default and enabled CLI/MCP behavior are both verified through the packaged app; live listening is denied without per-request visible consent.
8. Distribution is Developer ID-signed with hardened runtime, notarized and stapled, accepted by Gatekeeper, installed from the final DMG, and smoke-tested from `/Applications`.
