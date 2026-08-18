# Velora competitor gauntlet

Checked on 17 August 2026 against:

- [Superwhisper's changelog](https://superwhisper.com/changelog), through macOS 2.17.3 dated 17 August 2026.
- [FluidVoice source](https://github.com/altic-dev/FluidVoice/tree/ac9b3ad3cef4a669bf8a1345f313bbc57e5b1442), pinned at `ac9b3ad3cef4a669bf8a1345f313bbc57e5b1442`.
- [Kivi's product page](https://heykivi.ai/) and [privacy policy](https://heykivi.ai/privacy.html), checked 18 August 2026. Kivi is a new macOS alpha, so its demos and policy are product evidence, not independent reliability or latency proof.
- Velora `main` at `81ebf0e798bad3310beb5ee7e63485809dc0291f`, plus the preserved local worktree. The worktree was already dirty when this audit began, so pre-existing edits remain user-owned.

## What counts

A competitor feature counts only when its changelog, source, tests, or runnable product proves it. A Velora capability counts only when source and a relevant test or installed workflow prove it. Marketing claims do not establish performance, accuracy, privacy, or reliability.

We adopted gaps that improve a real Velora workflow without weakening local-only inference, consent, meaning preservation, or the single privileged execution boundary. Cross-platform reach, cloud providers, accounts, telemetry, subscriptions, and enterprise administration are not automatic product gaps.

## Capability matrix

| Workflow | What the competitors add | Velora before this pass | Decision |
|---|---|---|---|
| Local dictation | Superwhisper exposes a broad model and language catalogue. FluidVoice has several local engines, first-PCM readiness, ordered microphone fallback, and silent-input recovery. | Whisper/Parakeet plus local Qwen cleanup, language detection, Romanization, bounded recovery, and saved-audio benchmarks. Capture was declared ready when the session opened, before audio arrived. | Added first-converted-PCM readiness. Keep ordered mic priority and sustained-silence recovery as a hardware-gated follow-up. Do not add an unbenchmarked model buffet. |
| App-aware writing | Superwhisper has app/site activation, per-mode shortcuts and controls, tone, and auto-paste policies. FluidVoice has per-app prompt routing. | Custom JSON modes worked, but app assignment required typing bundle IDs and the HUD could disagree with the engine. | Added a native application picker, duplicate-owner rejection, browser-override disclosure, case-insensitive engine matching, and a cached custom-mode HUD label. Per-mode shortcuts and policies remain open. |
| File transcription | Superwhisper accepts audio and MOV through Finder. FluidVoice accepts audio/video and can add speaker labels, timestamps, and structured export. | The menu accepted audio only and produced a plain-text sidecar. | Added audio, MOV, and MP4 picker/Finder Open With support with a launch/busy queue. Speaker-labelled arbitrary files and timestamped JSON remain open. |
| Personal vocabulary | Both products have manual vocabulary. Superwhisper adds replacements, CSV and sync; FluidVoice adds Parakeet-specific boosting and voice pronunciation profiles. | Validated vocabulary, replacements, edit learning, CSV import/export, auto-mining, and optional iCloud sync already exist. Whisper consumes the glossary; Parakeet does not. | No duplicate UI. Parakeet final-pass boosting and voice enrollment require accuracy, false-positive, latency, and memory benchmarks. |
| History and recovery | Superwhisper has segments, seek, bulk operations, retention controls, and issue reporting. FluidVoice exports individual audio/transcript pairs and a JSONL corpus. | Search, raw/final text, playback, editing, reprocessing, archived FLAC, retention, and private performance benchmarks already exist. | Corrected Clear All copy so it truthfully says archived audio is permanently deleted. Bulk selection, segment seek, structured export, and full backup/restore remain open. |
| Onboarding | FluidVoice rebuilt setup around a real tryout and visible engine preparation. | Velora already required a successful inserted dictation before Finish, but model setup could leave the user without a clear exit. | Added “Continue in the Background” during model preparation while retaining the real-dictation completion gate. Fresh-profile installed proof is still required. |
| Meetings | Superwhisper has system audio, speaker separation/naming, summaries, retention, and meeting presets. FluidVoice has local speaker-labelled file transcription. | Explicit-consent two-track capture, resumable local processing, diarization, notes, search, playback, export, and deletion already exist. | Preserve Velora's consent and provenance model. Reuse its diarizer for arbitrary files only after graceful fallback and structured-export tests. Do not add automatic speaker identity. |
| Voice editing and actions | Kivi lets the user select text, hold its edit shortcut, and speak a rewrite. Superwhisper integrates coding agents. FluidVoice Command Mode can run arbitrary shell commands. | Safe Voice Edit already captures the exact editable selection, speaks an instruction, and refuses replacement if the range changes. Action Mode uses a closed primitive set and an owner-only Unix-socket broker. | Keep Safe Voice Edit's range identity and local execution. Reject arbitrary shell and unauthenticated loopback HTTP. Do not widen Action authority until execution receipts, postconditions, failure recovery, and ledger privacy are closed. |
| External automation | Superwhisper has start/stop deep links and hooks. FluidVoice exposes local HTTP endpoints. | Velora's CLI/MCP surface uses a peer-checked, owner-only Unix socket and explicit capability grants. | A narrow broker start/stop command is a real convenience gap, but it must enter the normal consent and capture state machine. No URL scheme or TCP listener. |
| Visible partial text | Kivi's demo shows words appearing progressively at the cursor and then resolving into polished text. Superwhisper and FluidVoice also expose live transcription surfaces. | Ordinary Velora dictation used a waveform and waited for the authoritative final. Earlier provisional HUD text was removed after a trust regression because it could disagree with the inserted result. | Added an opt-in Stream Typing shortcut. It replaces only Velora's exact owned draft, stages the final on the clipboard first, abandons the range after any user input, and leaves ordinary dictation on the lower-latency final-only path. |

## Implemented in this pass

### Finder and video input

Velora now registers as an alternate handler for common locally decodable audio formats, QuickTime, and MPEG-4 media. Files opened before engine readiness or during another file job are queued in order. A transient engine-side busy response puts the file back at the head of the queue. The menu picker uses the same type policy. Finder delivery never admits a directory, remote URL, MIDI, DRM media, or an unrelated file type.

Acceptance evidence:

- deterministic queue tests cover cold launch, app-side and engine-side busy states, filtering, retry, and FIFO order;
- `Info.plist` passes `plutil`;
- generated MOV and MP4 fixtures with video and AAC tracks both decode through `velora_engine.media.load_media`;
- the 0.16.2 build 214 release bundle passes strict deep code-signature verification; no installed app was replaced during this pass.

### Predictable app-aware modes

Modes now have a native multi-select app picker with icons and an advanced bundle-ID fallback. Bundle IDs resolve case-insensitively in Swift and Python. One app cannot silently belong to two modes, including the protected-built-in rename case. A browser assignment explicitly warns that it overrides automatic site-aware routing. The listening HUD consults a startup-cached app-to-mode index, so a custom Slack mode named “Banter” is shown as Banter rather than the generic Message category.

Acceptance evidence:

- Swift tests cover picker canonicalisation, duplicate ownership, protected rename semantics, and the custom HUD label index;
- Python tests cover mixed-case hand-edited mode files;
- no JSON read occurs on the hotkey path.

### Honest microphone readiness

Capture startup now completes only after the first non-empty buffer is converted to Velora's 16 kHz mono PCM format. A session that opens but delivers no convertible PCM fails after five seconds and tears down instead of leaving a silent recording state.

Acceptance evidence:

- a fake source proves `session.isRunning` alone cannot complete startup;
- timeout, rapid stop/restart ownership, release-before-readiness, and an 800-frame tail delivered immediately before stop are covered deterministically. Every converted buffer is committed before a main-queue stop transition can overtake it.

### Smaller trust fixes

- Model preparation keeps a visible “Continue in the Background” action; a ready setup still requires a successful inserted dictation before Finish.
- History Clear All now says that every saved transcript and archived audio clip is permanently deleted.
- Parakeet and architecture copy no longer claims that production renders live partial text.

### Kivi-informed Stream Typing

Kivi's useful gap was the feeling of immediate progress at the real cursor. Velora now exposes that as a separate shortcut, `Control-Shift-S`, instead of changing normal dictation. Whisper previews are enabled only when the focused app exposes a settable, readable Accessibility range. Unsupported apps skip the extra preview work and receive the polished final through the existing insertion path.

Each provisional update must prove the same app, Accessibility element, UTF-16 range, current draft, caret, and physical-input generation. Velora types provisional text without touching the clipboard. The final is staged on the clipboard before the last replacement. If focus, cursor, text, secure input, or a real key or click changes, Velora stops rewriting and keeps the final recoverable on the clipboard. Cancellation retains the session until a still-owned original selection has been restored. Stream Typing and Action Mode cannot post keyboard events at the same time.

Kivi also advertises name learning, per-app personas, selected-text voice editing, and mixed Hindi-English speech. Velora already had correction learning with a visible receipt, app-specific modes, exact-range Safe Voice Edit, local Whisper language detection, Romanization, and multilingual quality gates. Those paths were kept rather than duplicated.

Kivi's privacy policy says an account is required and content is processed and stored in India, with possible transfers and Sarvam terms applying to submitted content. Velora keeps speech and cleanup local and does not require an account. Two Reddit threads about Sarvam are mixed: [one user reported good informal Hindi/Hinglish results](https://www.reddit.com/r/IndiaSpeaks/comments/1r82oti/sarvam_ai_launches_madeinindia_foundational_llm/), while [a production developer reported slow REST transcription and unstable websocket language detection](https://www.reddit.com/r/VoiceAIAgent/comments/1t70hoy/anyone_using_speechtotext_for_indian_languages_in/). These are anecdotes about the underlying provider, not evidence about Kivi itself. No independent Kivi-specific Reddit review was found in this pass.

## Prioritised gaps left open

| Priority | Gap | Why it matters | Required gate |
|---:|---|---|---|
| 1 | Sustained-silent-PCM watchdog plus ordered microphone priority and live failover | Bluetooth, clamshell, and route churn can fail after the first buffer. | Physical AirPods/Bluetooth, clamshell, reconnect, default-device churn, and long-session tests; no duplicate chunks or lost tail audio. |
| 2 | Speaker-labelled arbitrary-file transcription with timestamps and JSON | The meeting diarizer exists, but imported interviews still lose speaker and time structure. | Bounded-memory long-file corpus, unknown-speaker fallback, overlapping speech, cancellation/restart, text and versioned JSON export. |
| 3 | History bulk selection, segment seek, and audio/transcript export | Repeated one-row actions make large local archives cumbersome. | Search-scoped selection semantics, destructive confirmation, atomic owner-only export, 100,000-row benchmark, installed UI proof. |
| 4 | Full backup and restore | Current settings transfer omits history, recordings, dictionary, and custom modes. | Versioned schema, conflict rules, rollback after corrupt input, size disclosure, and separately selected audio archive. |
| 5 | Per-mode shortcut, paste, tone, and formatting policies | Power users cannot directly invoke or tune a mode as deeply as in Superwhisper. | Shortcut collision tests, mode-resolution truth in HUD/history, explicit paste safety, migration, and installed workflow proof. |
| 6 | Website rules | A whole-browser assignment is too coarse for users who need different behavior in Gmail, Docs, and other sites. | Stable browser URL/title observation, privacy disclosure, precedence rules, and tests across supported browsers. |
| 7 | Narrow external start/stop | Shortcuts and assistive workflows should not need synthetic key events. | Owner-only broker command reaches the existing state machine; secure input, disabled access, termination, busy capture, and consent cases fail closed. |
| 8 | Parakeet final-pass vocabulary boosting | Current Parakeet paths ignore the learned glossary. | Saved-audio WER/CER, names corpus, Hindi/Hinglish, Romanization, stop latency, peak memory, and unboosted fallback. |
| 9 | Multiple dictation shortcuts, mouse buttons, and paste-last | These are useful ergonomic options in FluidVoice. | Collision resolution, Accessibility behavior, accidental-trigger rate, clipboard recovery, and installed input-device tests. |
| 10 | Voice pronunciation enrollment and custom spoken aliases | They may help difficult names and hands-free formatting, but can create broad false positives. | Three-sample enrollment, deletion/reset, private storage, short-utterance bounds, prose noun guards, and a measured accuracy win. |

Also absent but lower priority: Superwhisper's full explicit language list, microphone favourite/exclusion UI and safe-switch notices, vocabulary sync polish, per-mode word/tone controls, history issue reporting, and optional speaker naming. These should not outrank the reliability and export work above without user evidence.

## Deliberate rejections

- Cloud transcription, cloud cleanup, bring-your-own cloud providers, accounts, subscriptions, telemetry, enterprise administration, and Windows parity. They solve a different product boundary and weaken Velora's simple local trust story.
- FluidVoice's arbitrary voice-controlled `zsh -c` and unauthenticated loopback HTTP. Velora.app remains the only privileged executor; control stays on a peer-checked owner-only Unix socket.
- Automatic speaker identity. Speaker labels may be local and session-scoped, but identity requires a separate consent and biometric-data design.
- A model buffet or model swap based on a competitor claim. Keep `whisper-large-v3-turbo` and `Qwen3.5-4B-MLX-8bit` until a pinned candidate clears the existing quality, latency, memory, Romanization, multilingual, and saved-audio gates.
- Provisional text in ordinary dictation or the HUD. Live text is confined to the separate Stream Typing mode, where exact range ownership and final recovery can be enforced.
- Broader Action authority before postconditions and failure recovery are trustworthy.

## Proof limits and blockers

- Neither competitor publishes a reproducible head-to-head benchmark that proves “fastest” or “best.” FluidVoice has runtime measurements and tests, but no comparative benchmark artifact; Superwhisper's changelog is product evidence, not a benchmark.
- Kivi is an alpha with polished demos but no independent Kivi-specific review corpus found in this pass. Stream Typing is therefore a retention and perceived-latency hypothesis backed by the requested workflow, not a proven growth result.
- Source and deterministic tests do not prove real Bluetooth failover, fresh-profile onboarding, Finder registration, or a visible custom-mode HUD. The signed bundle exists, but those workflows still need an installed-app pass.
- The checkout also includes the Action lifecycle work tested in this aggregate pass: a private `0600` SQLite ledger, durable receipt commits, cancellation and recovery bookkeeping, and bounded 14-day or 200-task retention. The existing Swift action kernel remains the only privileged executor.
- The ledger has no user-facing history or delete control before its automatic retention window expires. That privacy surface remains a blocker for widening Agent Mode beyond the current opt-in, bounded Action authority.

## Progress log

- 17 August 2026: fetched Superwhisper 2.17.3 and pinned FluidVoice at `ac9b3ad`; preserved the existing dirty Velora worktree.
- 17 August 2026: completed separate Superwhisper, FluidVoice, and Velora audits plus yoyo falsification; converted claims into the matrix above.
- 17 August 2026: implemented Finder media input, app-picker/HUD mode identity, first-PCM readiness, onboarding exit, destructive-history copy, and documentation corrections.
- 17 August 2026: fixed hostile-review findings in case-insensitive mode parity, protected-built-in rename ownership, first-buffer quick release, post-migration HUD cache freshness, Finder engine-busy retry, and overly broad audio type registration. Final focused and aggregate gates are recorded in the handoff response.
- 17 August 2026: the final hostile review returned SHIP. Built and verified a signed 0.16.2 build 214 bundle without replacing the installed app.
- 18 August 2026: checked Kivi's product and privacy pages plus indirect Sarvam Reddit reports; added opt-in cursor-owned Stream Typing and retained Velora's local, no-account boundary.
