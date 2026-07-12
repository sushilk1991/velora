# Velora — Architecture v1.0

Two processes, one product:

```
┌─────────────────────────── Velora.app (Swift, SwiftPM) ───────────────────────────┐
│ NSStatusItem (menubar) · Hotkey (CGEventTap/NSEvent) · AVAudioEngine mic capture   │
│ HUD (NSPanel + SwiftUI Canvas waveform) · App-context tracker (NSWorkspace + AX)   │
│ Text inserter (pasteboard+⌘V / CGEvent typing) · Settings/Onboarding (SwiftUI)     │
│ Engine supervisor (spawn, health, restart) · History (SQLite)                      │
└───────────────┬────────────────────────────────────────────────────────────────────┘
                │ Unix domain socket  ~/.velora/engine.sock
                │ Framed protocol: JSON control + raw PCM audio frames
┌───────────────┴──────────────── velora-engine (Python 3.12, uv) ───────────────────┐
│ STT: mlx-community/whisper-large-v3-turbo (preview + final decode)                 │
│ Cleanup: mlx-community/Qwen3.5-4B-MLX-8bit with prepared prefix snapshots          │
│ Smart-format policy: mode resolution (app bundle id → mode file) + prompt builder  │
│ Model manager: HuggingFace download, warm/unload lifecycle                         │
└────────────────────────────────────────────────────────────────────────────────────┘
```

## Why this shape

- **MLX is required** → Python is where MLX STT/LLM APIs are mature (`parakeet-mlx`, `mlx-whisper`, `mlx-lm`). Pure-Swift MLX STT is not production-ready (swift-parakeet-mlx archived). Research: docs/research/stack-research.md.
- **Native feel is required** → the user-facing surface (menubar, HUD, hotkeys, insertion, settings) is 100% Swift/AppKit/SwiftUI. Python is an invisible inference server.
- **No Xcode project required** → SwiftPM executable + hand-rolled `.app` bundle. Development uses a stable local identity; release builds require Developer ID signing, hardened runtime, notarization, and stapling. The stable bundle id is `com.sushil.velora`; a one-time migration copies missing `velora.*` preferences from the legacy `com.velora.app` domain.

## Process lifecycle

1. App launch → engine supervisor starts `uv run velora-engine` (working dir `engine/`), waits for the `ready` handshake (engine preloads the STT model, then warms the cleanup model and a generic immutable prompt prefix in the background).
2. Crash/hang → supervisor restarts engine with backoff; HUD shows error state if a dictation was in flight; app remains usable (menubar shows degraded state while restarting).
3. App quit → engine terminated (it also self-exits if socket closes / parent pid dies).
4. Idle unload (optional setting): engine drops LLM weights after N min idle to free memory.

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
| `Capture/` | AVAudioEngine 16kHz mono Float32 tap, RMS levels for HUD |
| `Hotkey/` | CGEventTap (hold + double-tap detection), Esc-cancel monitor, secure-input detection (`IsSecureEventInputEnabled`) |
| `Context/` | NSWorkspace frontmost app tracking, AX focused-element probe (secure field check) |
| `HUD/` | NSPanel host + SwiftUI capsule (state machine per design brief), Canvas waveform |
| `Insert/` | pasteboard snapshot → ⌘V → restore; CGEvent unicode typing fallback; per-app overrides |
| `EngineClient/` | socket client, framing, request/event routing |
| `Settings/` | SwiftUI settings tabs + onboarding flow, permission checks |
| `History/` | SQLite (raw SQL, no deps) store + menubar recents |
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

## Permissions (TCC)

| Permission | Needed for | When requested |
|---|---|---|
| Microphone | capture | onboarding step 2 (NSMicrophoneUsageDescription in bundle Info.plist) |
| Accessibility | CGEventTap hotkeys + ⌘V posting + AX context | onboarding step 3, live-polled |

Spike finding: grants must be earned by the signed .app bundle (stable ad-hoc identity), not the bare binary; bare-binary tests mislead due to responsible-process attribution.

## Repo layout

```
Velora/
├── Package.swift            # SwiftPM app
├── Sources/Velora/...
├── engine/                  # uv project (pyproject.toml)
│   ├── src/velora_engine/...
│   └── tests/               # engine pytest + protocol integration tests
├── Resources/               # Info.plist, sounds, icon
├── scripts/                 # make-app.sh, make-sounds.sh, engine-smoke.py
├── docs/                    # SPEC, ARCHITECTURE, research/
├── Makefile                 # build / run / test / app / sounds
```

## Testing strategy

- Engine unit tests (pytest): formatting gate, protocol framing, divergence guard, mode resolution.
- Integration: scripted client feeds real WAV PCM over the socket → asserts transcript + formatted output + latency budgets (this is the E2E harness; runs headless, no TCC needed).
- App: XCTest is unavailable without Xcode → swift-testing via SwiftPM where possible; UI/permission paths verified manually + via the try-it onboarding step.
- Bench: `scripts/engine-smoke.py` reports stop→transcript / stop→final latencies per run.
