# Velora design guidelines

How Velora looks, moves, and speaks across the Mac app, the iPhone
companion, and the website. Read this before adding a screen, a HUD state,
a settings card, or a page. Tokens named here exist in code; if you need a
value that is not here, add the token first, then use it.

```
                 brand mark  ──►  app icon, favicon, OG image, header
                     │
   ┌─────────────────┼─────────────────┐
   ▼                 ▼                 ▼
 Mac app           iPhone            Website
 HUDStyle.swift    (alpha)           styles.css :root
 SettingsDesign.swift                script.js / scene.js
```

## 1. The brand mark

A serif italic **V** with an apricot full stop, on a sky plate (deep sky at
the top-left running to sky at the bottom-right, with a soft lighter-sky
bloom low-left). The V is the wordmark's own letter (Instrument Serif); the
full stop is the point of the product: the sentence is finished, and it was
finished here.

- Source of truth: `scripts/make-icon.py`. It regenerates every asset from
  one vector description. Never hand-edit a PNG; edit the script and re-run:

  ```sh
  uv run --script scripts/make-icon.py
  ```

  Outputs: `Resources/AppIcon.icns`, `Resources/branding/AppIcon-1024.png`,
  `Resources/branding/velora-mark.svg`, the iOS `AppIcon-1024.png`,
  `site/assets/velora-mark.svg`, `site/assets/app-icon.png` (must stay
  under 50 000 bytes, the site test enforces it) and `site/assets/og.png`.
- The macOS icon sits on Apple's 824 px squircle inside a 1024 canvas;
  the iOS icon is full-bleed. The site uses the SVG mark everywhere it can
  and the PNG only for `apple-touch-icon`.
- The menubar item stays the SF Symbol `waveform` as a template image; the
  mark never appears in the menubar.
- Do not add taglines, gradients, or extra glyphs to the mark. It has to
  read at 16 px.

### Palette

Brand v2 (2026-09): warm ink and paper surfaces, one sky accent, apricot
reserved for the headline's full stop and "learned" moments.

| Token | Hex | Where |
|---|---|---|
| Plate origin | `#0b5ea0` `VeloraBrand.skyPlate` | icon gradient start (top-left) |
| Sky-deep | `#0f74c5` `VeloraBrand.skyDeep` | icon gradient middle; the accent on light surfaces |
| Sky | `#4dacf6` `VeloraBrand.sky` | icon gradient end; the accent on dark surfaces |
| Sky link | `#71bfff` `VeloraBrand.skyLink` | links on dark surfaces |
| Apricot | `#e78a45` `VeloraBrand.apricot` | the full stop; warm accent on dark, site `--accent-2` |
| Apricot-deep | `#c06325` `VeloraBrand.apricotDeep` | warm accent on light |
| Ink window / card / raised | `#161311` / `#201d1b` / `#2c2927` | `VeloraPanel.canvas` / `.card` / `.raised` in dark |
| Paper window / card / sunk | `#faf8f5` / `#ffffff` / `#f3f1ee` | `VeloraPanel.canvas` / `.card` / `.raised` in light |

Dynamic pairs pick the right side per appearance: `VeloraBrand.accent`
(sky / sky-deep), `VeloraBrand.warm` (apricot / apricot-deep),
`VeloraBrand.link`. Glass sidebar fill is white 7 % on dark / 55 % on light
(`VeloraPanel.sidebar`, border `.sidebarLine`, top highlight
`.sidebarHighlight`); the selected row is white 14 % / ink 9 %
(`.sidebarSelection`); card borders and dividers use `.hairline` (white 10 %
/ ink 10 %). A primary button is sky with ink text on dark, sky-deep with
white text on light (`VeloraPanel.onAccent`). The HUD keeps its warm-dark
material fill; only its accent hue changed. Apricot is never a status
colour. The app takes system semantic colours for everything that is not
brand: `VeloraStatus.success`, `.warning`, `.danger` map to the system
green/orange/red and are the only status colours.

## 2. Type

- **Display (site):** Instrument Serif, regular and italic, self-hosted in
  `site/assets/*.woff2`. Used for headlines, the hero demo text and the
  wordmark. The italic is the "voice" — it carries the second, emotional
  line of a headline (`It reads like you wrote it.`).
- **Display (app):** the system serif (New York) via `design: .serif`,
  regular weight, 30 pt (34 pt hero), through `SerifHeadline`. It draws the
  closing full stop in `VeloraBrand.warm`; pass the sentence without it. The
  app never bundles a webfont.
- **Body:** the system sans everywhere (SF on Apple platforms). Never load a
  second webfont.
- **Mono:** system monospace for shortcuts, timers, ledgers, and anything
  measured (`0 B audio`).
- App text sizes: 22 pt bold for pane titles, 13 pt semibold for card
  titles, 13 pt for rows, 11 pt secondary for sub-captions, `.caption` for
  helper text, 26 pt bold with monospaced digits for stat values.
  Do not introduce a new size without a token in `SettingsDesign.swift`.

## 3. Spacing, radius, elevation

App (`HUDStyle.swift`, `SettingsDesign.swift`):

| Token | Value |
|---|---|
| `VeloraSpacing.xs / s / m / l / xl` | 4 / 8 / 12 / 16 / 20 pt |
| `VeloraRadius.control / tile / row / card` | 6 / 8 / 9 / 12 pt |
| `VeloraRadius.sidebar / capsule / window` | 14 / 14 / 18 pt (window is cosmetic; AppKit owns the corners) |
| `HUDGeometry.height` | 56 pt pill |
| Card | `VeloraPanel.card` fill, hairline `separatorColor` at 0.8, shadow black 5 % radius 2 y 1 |
| Group card | `VeloraPanel.card` fill, `VeloraPanel.hairline` border, no shadow |
| Sidebar | inset 8 pt, glass over `VeloraPanel.sidebar`, rows 32 pt |
| Window glow | `WindowGlow`: sky radial top-left (22 % dark / 18 % light), apricot bottom-right (16 % / 14 %); dark runs stronger because ink swallows the tint |

Site (`styles.css :root`): `--r-xs … --r-xl` (0.5 → 2.25 rem), shadows
`--shadow-sm/md/lg/accent`, shell 76 rem, gutter `clamp(1.25rem, 4.5vw, 3rem)`.

Rules:

- **Concentric corners.** A nested surface's radius = outer radius − padding.
  A 12 pt card with 16 pt padding holds 8 pt tiles, not 12 pt ones.
- Solid backgrounds in the settings window. Materials render blank in the
  snapshot pipeline; `VeloraPanel.canvas` and `.card` are the only grounds.
  `FloatingSidebar` is the one exception: it draws its translucent fill
  first and adds `glassEffect` on macOS 26 only, so the snapshot still shows
  the sidebar.
- Feature bands on the site are always the deep sky `--feature`, in both
  themes. They do not flip with the theme.

## 4. Motion

App (`VeloraMotion`):

| Token | Use |
|---|---|
| `quick` (150 ms ease-out) | hover, toggles, chips |
| `standard` (250 ms ease-out) | HUD state changes |
| `spring` (0.35 / 0.8) | HUD pill resize, card appearance |
| `springSlow` (0.4 / 0.85) | window-level transitions |

Site (`--ease`, `--ease-soft`, `--ease-both`):

- Reveals rise 1.4 rem, un-blur from 6 px, 780 ms, staggered 90 ms per
  `--reveal-order`. The observer fires at the first visible pixel so a fast
  scroll never lands on a blank card.
- Headlines marked `data-split` reveal word by word (46 ms per word) from a
  clipped line box. The mechanism is in `script.js`; do not hand-wrap words.
- Ambient loops (marquee, voice bars, record pulse) run only while on
  screen; the WebGL field stops when off screen or in a hidden tab.
- The hero field swells while the demo "listens" via the `velora:voice`
  event. Any new demo that represents speech should dispatch the same event.
- **Reduced motion is a contract.** `@media (prefers-reduced-motion: reduce)`
  collapses every transition and animation to 0.01 ms and the JS checks
  `reducedMotion()` before scripting anything. Never add `transition: all`.
- No motion for its own sake: an animation must show a state change (typing
  landing, a correction applied, a bar counting up) or it is removed.

## 5. Copy voice

Velora is *plain but not blunt, confident but not salesy*. The reader is a
person who types for a living and does not trust "AI" claims.

- Lead with the outcome in the reader's words (the Bar Test: could you say it
  to a friend?). "Talk like you talk. It reads like you wrote it."
- One idea per sentence. Cut "seamlessly", "powerful", "leverage", "AI-powered".
- State the boundary next to the promise. Every feature page ends with
  "The fine print". A claim that cannot be traced to code does not ship.
- British "-ise" spelling on the site (recognised, capitalised); the app
  follows macOS conventions (Title Case for buttons and menu items).

### Casing and punctuation

| Element | Style | Example |
|---|---|---|
| Buttons, menu items, tabs | Title Case | `Download for Mac`, `Open History` |
| Section titles, card titles | Sentence case | `Personal dictionary` |
| Labels, toggles | Sentence case, no period | `Pause music while dictating` |
| Helper / subtitle text | Sentence, ends with a period | `Fix spelling and grammar in selected text, no microphone needed.` |
| Menu items that open a window or ask | trailing `…` (U+2026) | `Transcribe File…` |
| Shortcuts | glyph notation, no plus signs | `⌃⇧S`, `⌥⇧E`, `Right Option` |
| Numbers with units | space before GB/MB, none before s | `1.6 GB`, `2.3s` |

### Canonical names

Use exactly these, capitalised as shown, everywhere: **Dictation**,
**Stream Typing**, **Voice Edit**, **Proofread**, **Action Mode**,
**Meetings** (the pane; its output is "meeting notes"), **Dictionary**,
**History**, **Stats**, **Modes**, **Models**. "Safe Voice Edit" is retired.

Destructive verbs: **Delete** (a record), **Remove** (from a list),
**Forget** (a learned term). Never "Clear" for data.

Privacy line, verbatim: **Your voice never leaves this Mac.** Scope it to
audio and transcripts; the optional iCloud dictionary sync means "everything"
would be false.

## 6. The HUD

The pill by the cursor is the product's face. Rules:

- One state at a time: standby, listening, polishing, inserted, error,
  meeting. Each has a fixed geometry in `HUDGeometry`; text never reflows the
  pill mid-state.
- Listening shows the dot, the waveform, a status word and a monospaced
  timer. Inserted collapses to a circle with a check. Error is 320 pt with a
  single retry chip.
- The HUD never takes focus and never appears over a secure input field.
- Copy in the HUD is ≤ 4 words, present tense: `Listening`, `Polishing`,
  `Pasted at your cursor`, `Proofread text on clipboard`.

## 7. Settings

- The sidebar is a `FloatingSidebar` of monochrome `SidebarRow`s
  (Finder/Notes style: symbol in `VeloraBrand.accent` when selected,
  `.secondary` otherwise; no coloured tiles). `WindowGlow` sits behind the
  whole window.
- Every pane opens with a `PaneHeader` (22 pt bold title, trailing
  controls) and stacks `GroupCard`s on `VeloraPanel.canvas`: an uppercase
  section header, `GroupRow`s (13 pt label, 11 pt sub-caption, trailing
  control) separated by `GroupDivider`, an optional footer. `SettingsCard`
  with `CardHeader` (symbol, colour, title, subtitle, master toggle) and
  `CardDivider` remains for panes not yet moved over.
- Buttons outside Forms use `.buttonStyle(.capsule)` (glass, 28 pt) or
  `.primaryCapsule` (accent fill). One primary per pane.
- A pane's one sentence of welcome or celebration is a `SerifHeadline`.
- One SF Symbol per concept, fixed (sidebar symbols in `SettingsTab.symbol`,
  feature cards in the Shortcuts pane, menu items in
  `StatusItemController.swift`):

  | Concept | Symbol |
  |---|---|
  | Menubar item | `waveform` (template) |
  | General | `gearshape.fill` |
  | Dictation | `mic.fill` |
  | Stream Typing | `keyboard.fill` |
  | Voice Edit | `wand.and.stars` |
  | Proofread | `text.badge.checkmark` |
  | Action Mode | `sparkles` |
  | Meetings | `person.2.wave.2.fill` |
  | Dictionary | `character.book.closed.fill` |
  | Models | `cpu.fill` |
  | Modes | `slider.horizontal.3` |
  | History | `clock.arrow.circlepath` |
  | Stats | `chart.bar.fill` |
  | Shortcuts | `keyboard.fill` |
  | About | `info.circle.fill` |

  If a concept already has a symbol, reuse it; a new symbol needs a row here.
- Shortcuts render through `KeycapsLabel`, never as plain text.
- Metrics use `StatTile` (hero: 12 pt label over a 26 pt bold tabular value,
  `emphasis: .accent` for the one number that matters) or `CardMetricRow`
  (inline). No ad hoc `HStack(Text, Spacer, Text)`.
- A card that can be turned off dims to 50 % and disables its rows; it does
  not hide them.

## 8. The website

- Static, self-hosted, no analytics. `scripts/test-site.py` is the contract:
  run `make test-site` after any change; it fails on remote scripts, a
  second `h1`, a missing section id, a stale honesty string, or a favicon
  over budget.
- Every page has the same header and footer and links to the brand SVG.
  `og:image` is always `https://sushilk1991.github.io/velora/assets/og.png`.
- Light and dark palettes are defined twice on purpose (`prefers-color-scheme`
  and `[data-theme]`) and must stay identical. The test compares them.
- New feature ⇒ four edits: a bento tile or index row on `index.html`, a
  page in `features/`, a link in the previous/next chain, and a line in
  the comparison table if a competitor differs.
- The "New" badge lives on at most one feature at a time, the most recent
  one.

## 9. Checklist for a UI change

1. Uses existing tokens (`VeloraSpacing`, `VeloraRadius`, `VeloraMotion`,
   site `--*` variables). No literal `8`, `12`, `0.25s`.
2. Copy follows §5: casing, canonical names, ellipsis, shortcut glyphs.
3. Symbol is the one from §7's table.
4. Works in light and dark, and in `prefers-reduced-motion`.
5. Screenshot both themes (`.build/release/Velora --snapshot` for the app;
   the local server for the site) and look at them before claiming done.
6. `make test` is green; for site changes `make test-site` specifically.
7. Icon or brand change ⇒ re-run `scripts/make-icon.py` and commit every
   output together.
