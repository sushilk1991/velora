# Velora — Product Specification v1.0

Velora is an open-source, local-first dictation app for macOS. Hold a hotkey, speak, release — polished text appears in whatever app you're using. All inference (speech-to-text and LLM cleanup) runs on-device via MLX on Apple Silicon. No audio or text ever leaves the machine.

**Positioning:** the open-source answer to Superwhisper and Wispr Flow, with Wispr Flow's feel (invisible, fast, smart) and Superwhisper's customizability (modes, prompts, vocabulary) — minus the cloud, the subscription, and the trust problem. Wispr Flow transcribes in the cloud; Velora never makes a network request after models are downloaded.

## Product principles

1. **Local-first is the product.** Zero network calls at dictation time. Privacy is architectural, not a toggle.
2. **Invisible until needed.** A capsule HUD that never steals focus; a menubar item; nothing else.
3. **Never lose the user's words.** Raw transcript is always recoverable from history, even when AI cleanup mangles it. Esc always cancels cleanly.
4. **Don't over-edit.** The #1 Superwhisper complaint is AI polish changing intent (answers instead of transcription, hallucinated rewrites). Cleanup is conservative by default; formatting strength is user-controllable per mode.
5. **Fast enough to trust.** Text lands < 1.5s after release for typical utterances. If cleanup would be slow, insert raw text fast rather than making the user wait.

## P0 — v1 must-have

### Capture & flow
- Menubar app (LSUIElement, no dock icon), SwiftPM-built, hand-rolled .app bundle, ad-hoc signed.
- **Hold-to-talk** (default: hold Right-Option) and **toggle mode** (default: double-tap Right-Option or menubar click). Hotkey configurable.
- Floating capsule HUD per design spec (docs/research/design-brief.md): listening → transcribing → inserted/error state morphs, live 24-bar waveform from mic RMS, never takes focus.
- Esc cancels recording; nothing is inserted.
- Start/stop sounds (synthesized, per design spec), toggleable.

### Transcription & intelligence
- On-device STT via MLX (model per ARCHITECTURE.md; user-selectable in settings with size/speed table and download manager).
- On-device LLM cleanup via mlx-lm (small instruct model, 4-bit):
  - remove filler words (um, uh, "you know") — conservative,
  - apply self-corrections ("no wait, I meant Tuesday" → "Tuesday"),
  - punctuation, capitalization, paragraph breaks,
  - honor spoken commands: "new line", "new paragraph".
- **Smart formatting (app-aware):** frontmost app bundle id + focused-field context select the active mode automatically:
  - chat apps (Slack, Messages, Discord) → casual, no trailing period on single sentences, keep it terse,
  - email (Mail, Gmail in browser) → greeting/paragraph structure, professional tone,
  - notes/docs (Notes, Obsidian, Notion) → markdown allowed, lists when speech enumerates,
  - code editors/terminals (VS Code, Cursor, Terminal, Ghostty) → **raw mode, no AI rewriting**, technical vocabulary bias,
  - everything else → default mode.
- Formatting decides *whether* to format, not just how: short fragments and commands pass through nearly untouched; long multi-sentence speech gets structure (lists when the user enumerates, paragraphs on topic shifts).
- Secure-input fields (passwords): detected → insertion suppressed with error HUD state.

### Modes (Superwhisper-style, config-file-first)
- Built-in: **Raw** (no AI), **Default**, **Message**, **Email**, **Note**, **Code**.
- Every mode = a JSON file in `~/.velora/modes/`: system prompt, formatting strength (off/light/full), vocabulary hints, app-activation rules (bundle ids). Custom modes = drop in a file. GUI editing is P1; the format is the API.
- Global vocabulary list (proper nouns, jargon) injected into STT prompt + cleanup prompt. Text replacements (e.g. "vs code" → "VS Code") applied post-cleanup.

### Insertion
- Pasteboard save → set → synthesized ⌘V → restore, with CGEvent-typing fallback for apps that block paste. Per-app override list.
- Clipboard contents always restored.

### History
- Local SQLite history: timestamp, app, raw transcript, final text, duration, mode. Menubar shows last 3 (click = copy). Full history window is P1; storage from day one.

### Settings & onboarding (world-class bar, per design brief)
- Settings: General / Dictation / Model / Shortcuts / About tabs, grouped forms, 580pt.
- Onboarding: 5-step premium flow (welcome → mic permission → accessibility permission with live-polling grant detection → hotkey → try-it playground). Finish gated on one successful dictation.
- Permissions degrade gracefully: degraded state shows menubar error icon + "Check Permissions…".

### Performance targets (M-series, measured in CI-able bench script)
- End of speech → text inserted: **< 1.5s** for ≤ 15s utterances (STT streaming/chunked so most transcription happens during speech).
- Cleanup adds **< 1.5s** (hard timeout) or is skipped (raw inserted, cleanup result available in history).
- Idle: < 400MB RSS for app + engine with models unloaded-after-idle option; < 1% CPU idle.
- Cold start to ready: < 4s with default models cached.

## P1
- History browser window with search, re-copy, re-process.
- Mode editor GUI; per-mode hotkeys.
- Streaming partial-transcript display in HUD.
- Browser URL awareness (Gmail vs Docs in Chrome) via Accessibility.
- Selected-text context ("rewrite this") — transformation mode.
- Multilingual dictation (Whisper multilingual models; auto language detect).
- Launch-at-login, Sparkle-style updates (or brew cask).

## P2
- Meeting transcription (system audio capture).
- Voice commands ("send it", "delete last sentence").
- Plugin/scripting hooks (shell command per mode output).
- iOS companion.

## Non-goals (v1)
- No cloud inference of any kind. No accounts, telemetry, or analytics.
- No screen-content context (screenshots/OCR) — trust-destroying; explicit opt-in someday at most.
- No Windows/Linux.

## Success criteria for v1 "done"
1. E2E on real audio: speech in any focused app → correct, well-formatted text inserted, within targets.
2. App-aware behavior verified across at least: TextEdit (default), a chat-style target, a code-style target.
3. Full pipeline verified with sample audio from the internet (JFK clip + long-form sample).
4. Buildable from clean checkout with `make build` (SwiftPM + uv, no Xcode), open-source ready (README, LICENSE, CONTRIBUTING).
