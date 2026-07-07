The spike confirms the architecture the spec must fit: AppKit `NSApplication` menubar app, overlay pill HUD, 16 kHz mono Float32 mic capture with RMS, and pasteboard-based text insertion. Full deliverable below.

---

## Verdict

Deliverable is produced, with one material caveat: **the task's "use web search" clause could not be satisfied** — this session has no web-search tool. Competitor descriptions (Wispr Flow, Superwhisper) are from training knowledge (cutoff Jan 2026) and are labeled UNVERIFIED where they assert current live UI. Everything prescriptive for Velora is exact and directly implementable, and is consistent with the existing spike (`spikes/menubar/Sources/velora-spike/main.swift:37` — RMS levels at 16 kHz are already available, which the waveform section builds on).

## Reasons

- No `WebSearch`/`WebFetch` tool exists in this toolset; per evidence discipline, I did not fabricate "researched" pixel measurements of third-party apps. Their designs are described at the fidelity training data supports.
- The Velora spec itself needs no external verification — dimensions, timings, and symbol names are design decisions, and every SF Symbol/API named below existed as of my cutoff (flagged where macOS-26-specific).
- Repo inspection confirmed no existing UI to contradict (only spikes), so the spec is greenfield-safe.

## Risks

- Wispr Flow/Superwhisper may have shipped redesigns after Jan 2026; the "reference dissection" section could be stale. This does not affect Velora's spec validity, only its competitive framing.
- macOS 26 (Tahoe) introduced Liquid Glass; exact SwiftUI API surface for glass effects (`glassEffect(_:in:)`) is per my cutoff — verify against current SDK headers before relying on it, with the `Material` fallbacks given below.
- SF Symbol availability should be confirmed in the SF Symbols 7 app; every symbol below existed in SF Symbols 6, so risk is low.

## Recommendation

Adopt the spec below as-is for v1. The single smallest step that would upgrade the UNVERIFIED sections to verified: re-run this task with web access (or 10 minutes of manual screenshots of Wispr Flow + Superwhisper on your Mac, measured with CleanShot X's ruler) and diff against §1.1.

---

# Velora — UI/UX Design Specification v1.0

Scope: recording HUD, live waveform, menubar, settings + onboarding, sound design. Target: macOS 26 (Tahoe), SwiftUI-first with AppKit window hosting. Design language: Liquid Glass era — translucent materials, capsule geometry, spring physics, restraint.

---

## 1. Recording HUD

### 1.1 Reference dissection — UNVERIFIED (training knowledge, pre-Jan-2026; verify with live screenshots)

**Wispr Flow:** a small dark capsule anchored bottom-center of the screen, just above the Dock. Collapsed idle state is a thin bar (~40×6 pt hint); on activation it expands to a pill roughly 120–160 pt wide × 36–44 pt tall containing a live bar waveform. States: hidden → listening (waveform reacts to voice) → processing (waveform freezes/shimmers) → dismiss on insertion. Dark translucent fill regardless of system appearance; entrance/exit are quick springy scale+fade. Interaction is near-zero: it's a status surface, not a control surface (escape cancels, hotkey release stops).

**Superwhisper:** a larger floating card (roughly 200–280 pt wide), user-repositionable, showing waveform + active mode name; also offers a minimal recording indicator option. More informative, less minimal than Flow. Processing state shows an explicit spinner/progress.

**Takeaway:** Flow wins on feel because the HUD (a) never asks for attention, (b) lives at a fixed, predictable position, (c) uses one geometric primitive (capsule) that morphs between states rather than swapping views. Velora copies that philosophy, not the pixels.

### 1.2 Velora HUD — prescriptive spec

**Window (AppKit host):**
- `NSPanel`, `styleMask: [.borderless, .nonactivatingPanel]`
- `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` (shadow drawn in SwiftUI so it animates with the shape)
- `ignoresMouseEvents = true` while listening; `false` only in the `error` state (which shows a button)
- Position: horizontally centered on the screen containing the frontmost window; bottom edge **20 pt above** `screen.visibleFrame.minY` (i.e., above the Dock). Never repositions while visible.

**Geometry per state** (one capsule, morphing — use `matchedGeometryEffect` or animate frame directly):

| State | Size (pt) | Contents |
|---|---|---|
| `hidden` | — | not on screen |
| `listening` | 180 × 44 | 8 pt red dot • 24-bar waveform (120 pt) • timer text |
| `transcribing` | 180 × 44 | waveform bars settle to 4 pt and run a left-to-right shimmer |
| `inserted` | 44 × 44 (circle) | `checkmark` SF Symbol, 17 pt semibold |
| `error` | 260 × 44 | `exclamationmark.triangle.fill` + one-line message + "Retry" |

Corner radius: always `height / 2` (22 pt) — capsule at every size, so the morph never shows a radius pop.

**Materials & colors:**
- Fill: on macOS 26 use `.glassEffect(.regular, in: Capsule())` if available in the SDK; fallback (and macOS 14–15): `Capsule().fill(.ultraThinMaterial)` over an `NSVisualEffectView` with `material: .hudWindow`, `state: .active`.
- Tint overlay: dark mode `Color.black.opacity(0.30)`, light mode `Color.white.opacity(0.25)` — keeps waveform contrast on busy wallpapers.
- Border: `Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)` dark / `.black.opacity(0.08)` light.
- Shadow (SwiftUI): `color: .black.opacity(0.25), radius: 20, x: 0, y: 6`.
- Recording dot: `Color(nsColor: .systemRed)`, 8 pt circle, pulsing `opacity 1.0 → 0.55`, `easeInOut(duration: 1.0).repeatForever(autoreverses: true)`.
- Waveform bars: dark mode `.white.opacity(0.9)`; light mode `.black.opacity(0.75)`. On success flash: bars tint to `Color(nsColor: .systemGreen)` for 150 ms before the circle morph.
- Timer text: `Font.system(size: 12, weight: .medium).monospacedDigit()`, `.secondary` foreground, format `m:ss`.

**Animation spec:**

| Transition | Animation |
|---|---|
| appear (hidden→listening) | `.spring(response: 0.35, dampingFraction: 0.75)`; scale from 0.8, opacity from 0, translateY from +12 pt |
| listening→transcribing | bars animate to uniform 4 pt height with `.spring(response: 0.3, dampingFraction: 0.9)`; shimmer: 60 pt wide linear-gradient highlight sweeping the 120 pt strip every 1.2 s, `easeInOut`, repeatForever |
| transcribing→inserted | width 180→44 with `.spring(response: 0.4, dampingFraction: 0.8)`; checkmark appears with `.transition(.scale.combined(with: .opacity))` + `.symbolEffect(.bounce, value:)` |
| inserted→hidden | hold 600 ms, then `easeOut(duration: 0.25)`: opacity→0, scale→0.85 |
| cancel (Esc) | `easeOut(duration: 0.18)`: opacity→0, scale→0.9, translateY +8 pt — deliberately faster than success, no bounce |

Rule: **success bounces, cancellation doesn't.** Nothing on the HUD ever moves except via these five transitions and the waveform.

---

## 2. Live waveform rendering (SwiftUI)

**Pipeline (matches the existing spike's RMS tap):**
1. `AVAudioEngine` input tap, `bufferSize: 1024`. At 16 kHz that's ~64 ms/buffer → ~15 Hz raw level updates; compute RMS per buffer, convert `db = 20 * log10(rms)`, normalize `level = max(0, (db + 50) / 50)` (−50 dBFS floor), clamp 0…1.
2. Publish into a fixed ring buffer of the last 24 levels (one per bar) on the main actor — a plain `@Observable` class with a `[Float]` is fine; do **not** create SwiftUI state churn per audio buffer beyond this one array write.
3. Smooth asymmetrically per bar: `display = display + (target − display) * k`, with `k = 0.55` when rising (fast attack) and `k = 0.12` when falling (slow decay). This is what makes bars feel "alive" instead of jittery.

**Rendering:**
- `TimelineView(.animation)` wrapping a `Canvas`. The Canvas redraws every frame (ProMotion gives you 120 Hz for free); interpolate between audio updates inside the draw closure using the timeline date — never rely on the 15 Hz audio rate for motion.
- Draw each bar as `Path(roundedRect:cornerRadius:)`: bar width **3 pt**, gap **2 pt**, corner radius **1.5 pt**, height mapped `4 + level * 24` pt (4 pt floor, 28 pt max inside the 44 pt pill), vertically centered. 24 bars × 5 pt pitch = 120 pt strip.
- Performance rules: one `Canvas`, zero per-bar SwiftUI views (24 animated `Capsule()` views + springs is the classic mistake — it thrashes the layout engine); no `.shadow` inside the Canvas; no `drawingGroup()` needed (Canvas is already Metal-backed); keep the Canvas exactly 120×28 pt, not full-window.
- Idle/silence behavior: below `level 0.03`, drive bars with a gentle standing wave `4 + 2 * sin(t * 2π * 0.8 + barIndex * 0.5)` pt so the HUD reads "listening" even in silence.

---

## 3. Menubar (macOS 26 conventions)

- Use `MenuBarExtra("Velora", systemImage:)` with `.menuBarExtraStyle(.menu)` — a real NSMenu, not a popover panel; popover-style extras feel non-native for utility apps.
- Icon is always a **template image** (monochrome, system-tinted) — never colored. State via symbol swap + symbol effect, not tint:

| State | SF Symbol | Effect |
|---|---|---|
| idle | `waveform` | none |
| recording | `waveform` | `.symbolEffect(.variableColor.iterative.dimInactiveLayers)` (macOS 14+; via `NSImageView.addSymbolEffect` if you drop to `NSStatusItem`) |
| transcribing | `waveform.badge.magnifyingglass` (fallback `ellipsis`) | `.replace` content transition |
| error / no permission | `waveform.badge.exclamationmark` | static |

- Menu contents, top to bottom: **Start Dictation** (`⌥Space`, bold as default action) · **Last transcription** header + 3 most recent items (truncated to 40 chars, click = copy) · separator · **Settings…** `⌘,` · **Check Permissions…** (only visible when degraded) · separator · **Quit Velora** `⌘Q`. Nothing else; every added item is a tax on the 99 %-of-opens case.
- `LSUIElement = true` (no Dock icon); Dock icon appears only while the onboarding window is open (`NSApp.setActivationPolicy(.regular)` temporarily).

---

## 4. Settings & onboarding

### 4.1 Settings window

- SwiftUI `Settings` scene, native toolbar-style `TabView` (the macOS 26 settings idiom — Raycast/Linear-style sidebars only pay off past ~6 sections; Velora has 5):

| Tab | SF Symbol | Contents |
|---|---|---|
| General | `gearshape` | launch at login (`SMAppService`), HUD position picker, appearance |
| Dictation | `mic` | hotkey mode (hold vs toggle), language, auto-punctuation, sounds on/off + volume slider (0–100, default 40) |
| Model | `cpu` | model picker with size/speed table, download progress, storage used |
| Shortcuts | `keyboard` | recorder controls (use KeyboardShortcuts-style recorder UI) |
| About | `info.circle` | version, GitHub link, acknowledgments, "Check for Updates" |

- Every tab: `Form { … }.formStyle(.grouped)`, window width fixed **580 pt**, height hugs content. No custom chrome — grouped forms on macOS 26 already look like Apple's System Settings.

### 4.2 Onboarding (the premium-feel moment)

Separate window, **640 × 520 pt**, non-resizable, `.windowStyle(.hiddenTitleBar)`, centered. Five steps with a 6 pt-dot page indicator, transitions `.push(from: .trailing)` with `.spring(response: 0.4, dampingFraction: 0.85)`:

1. **Welcome** — app icon 96 pt, one sentence, "Get Started" (`.borderedProminent`, `.controlSize(.large)`).
2. **Microphone** — permission card (below). Trigger `AVCaptureDevice.requestAccess(for: .audio)` from the button — never at launch.
3. **Accessibility** — permission card; button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and the card **live-polls `AXIsProcessTrusted()` on a 1 s timer**, flipping to granted-state without any "I did it" button. This self-updating flip is the single biggest premium signal — it's how CleanShot X and Raycast walkthroughs feel (UNVERIFIED as current behavior; pattern from training knowledge).
4. **Hotkey** — shows default `⌥Space` in a keycap-styled view (`RoundedRectangle(cornerRadius: 6)`, `.regularMaterial`, 1 pt `.separator` border, `Font.system(size: 13, weight: .semibold, design: .rounded)`), with inline recorder to change it.
5. **Try it** — a live `TextEditor` and the instruction "Hold ⌥Space and speak." Completing a real dictation here fires the success morph + sound; "Finish" enables only after one successful insertion (skippable via subdued "Skip" text button).

**Permission card component (used in steps 2–3):** 480 pt wide, `RoundedRectangle(cornerRadius: 12)`, `.quaternary` 1 pt border, `.background(.regularMaterial)`; leading SF Symbol 28 pt (`mic.fill` / `accessibility`) in a 44 pt tinted circle; title 15 pt semibold; two-line 13 pt `.secondary` explanation of *why* ("Velora types for you — that requires the Accessibility permission"); trailing button. Granted state: symbol crossfades to `checkmark.circle.fill` in `.green` with `.symbolEffect(.bounce)`, button becomes disabled "Granted".

Re-run path: a degraded-permission state shows the menubar error icon + "Check Permissions…" item that reopens the relevant step directly.

### 4.3 Anti-goals (enforce in review)
No custom title bars in settings, no marketing copy inside the app, no window > 640 pt wide, no more than one accent color (`Color.accentColor` only), no onboarding step without a Skip path after step 3.

---

## 5. Sound design

- **Do not** use `NSSound(named:)` stock sounds (Tink/Pop/etc.) — they read as system alerts, not app feedback. Do not ship Apple's private dictation `.caf` assets (they live in private framework bundles; copying them is a licensing problem).
- Ship two synthesized assets (~5 KB each, AAC in `.caf`):
  - **start.caf** — two ascending sine tones, 660 Hz then 880 Hz (E5→A5), each 70 ms, 8 ms attack / 60 ms exponential decay, peak **−18 dBFS**.
  - **stop.caf** — the reverse, 880 Hz→660 Hz, same envelope, −20 dBFS (stop should be quieter than start).
  - Optional **error.caf** — single 330 Hz tone, 120 ms, −18 dBFS.
- Playback: `AVAudioPlayer` with `player.volume` bound to the settings slider (default 0.4); no ducking, no `NSSound.beep()`. Respect the "Play sounds" toggle and skip entirely when output device is the same as an active call device if detectable — otherwise don't over-engineer.
- Rationale: Wispr Flow's cues are short synthesized blips in this register (UNVERIFIED exact frequencies; pattern from training knowledge). Rising = "I'm listening", falling = "got it" is the universal grammar (Siri, Google Assistant).

---

## Verified
- No web search tool exists in this session (tool list contains no search/fetch capability) — the task's research-method clause is unsatisfiable here.
- Repo state: only `spikes/menubar` (Swift) and `spikes/engine` (Python) exist; no production UI. Quoted `main.swift:36-39` confirms mic capture is 16 kHz mono Float32 with RMS prints, and `main.swift:42-43` confirms the menubar + overlay-pill + hotkey architecture the spec targets.

## Inferred (training knowledge, cutoff Jan 2026 — not live-checked)
- Wispr Flow / Superwhisper HUD descriptions (§1.1), CleanShot X/Raycast onboarding patterns (§4.2), Wispr Flow sound character (§5).
- macOS 26 Liquid Glass API names (`glassEffect`) — verify against the current SDK; the `Material`/`NSVisualEffectView` fallbacks specified are stable macOS 12+ API.
- All SF Symbol names existed in SF Symbols 6; confirm `waveform.badge.magnifyingglass` in the SF Symbols app, fallback given.

**Unblock step:** one pass with web access (or manual screenshots + CleanShot ruler measurements of Flow/Superwhisper) to confirm §1.1; nothing in Velora's prescriptive spec depends on it.
