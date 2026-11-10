---
title: Velora capability roadmap - Plan
type: feat
date: 2026-11-10
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: hex-teardown-and-repository-review
origin: docs/research/2026-11-09-hex-teardown.md
---

# Velora capability roadmap - Plan

## Goal Capsule

**Objective:** People can use Velora for more of their daily writing, editing, and meeting work, with less correction and less setup.

**Direction:** Connect each result to correction and recovery tools first, make useful workflows reusable, then deepen meeting memory and local automation. Keep the normal interaction familiar: speak, release, continue working.

**Authority:** The user's request for broader capability and simple use governs this roadmap. The Hex teardown supplies ideas; current Velora source establishes what already exists. Existing on-device processing and explicit recording consent remain product requirements.

**Planning scope:** This is a product roadmap with engineering starting points and acceptance criteria. It defines what to build and in what order. Later experiments need qualification before becoming implementation-ready work; this file is not an instruction to implement every item in one pass.

---

## Product Contract

### Summary

Build six connected capabilities: correction and recovery, reusable writing workflows, better language and model choices, meeting review and reuse, local integrations, and feedback that helps people understand the app. Put these capabilities into the existing HUD, History, Modes, Meetings, and Settings surfaces.

The first release should connect **Fix this**, text-only reformatting, and a mode playground. This gives people an immediate way to recover a bad result, prevent a recurring mistake, and create a workflow that suits their work. Delivery preferences are a small parallel addition. Subtitle export and sound choices are worthwhile, but should not displace this core improvement.

### Problem Frame

Velora already has substantial capability: custom modes, editing, proofreading, correction learning, file transcription, meeting notes, and spoken actions. Some of that power is difficult to discover or disconnected from the moment a person needs it. A wrong output sends the person to separate History, Dictionary, or Modes screens; a saved transcript cannot always be restyled without rerunning speech recognition; a meeting search result does not take the person directly to its audio.

Adding more independent toggles would leave those problems in place. The opportunity is to connect existing capabilities and add new ones at the point of use.

### What the teardown changes after checking source

Hex's evidence is a static inspection of its shipped artifact, not runtime verification. Its feature surfaces are useful inspiration, but do not establish that a feature works well. The teardown also contains several incorrect or incomplete claims about Velora at the checked commit, `a977d80`.

| Topic | Verified Velora foundation | Roadmap consequence |
|---|---|---|
| Filler removal | `scrub_fillers` already runs on ordinary deterministic and model paths; the cleanup-disabled path bypasses it | Offer hesitation removal without rewriting as a deliberate choice; reuse the existing implementation |
| Smart spacing | Caret-aware boundary adjustment and a bounded continuation fallback already exist in `TextInserter.swift` and `TextInsertionBoundary.swift` | Keep and verify this behavior; do not schedule a new spacing engine |
| Clipboard | The controller already stages the final transcript persistently; temporary paste text restores that staged result | Preserve the current keep-result default; add explicit alternatives |
| Copy only | Home already starts clipboard-only dictation | Make it available as a general delivery preference |
| Modes | The GUI already creates, duplicates, edits, saves, resets, and deletes custom modes | Add examples, previews, sharing, and better authoring ergonomics |
| Raw recovery | The menubar already offers As Heard (Original) | Improve access and safe replacement instead of building raw recovery again |
| Editing | Voice Edit and Proofread already ship | Add useful presets and an easier last-result workflow |
| Model picker | The speech catalog already exposes language-aware recommendations; path sorting also appears in storage management | Improve the actual picker rather than treating storage ordering as the whole picker |
| Meeting ending | Native-call end detection can already finish a recording; weaker browser/manual signals prompt the user | Expose understandable policy over the current detector |
| Meeting notes | A user-editable notes prompt already exists | Add named templates and better use of the resulting notes |
| Diarization | The UI already explains remote speech detection and the initial model download; output deliberately remains Me/Them | Individual speaker labels would be a new capability needing evaluation |
| Exports and chapters | Segment times exist, but commonly describe roughly minute-long audio slices; processing currently happens after capture | Separate timed transcript export, readable subtitles, post-meeting chapters, and live processing |
| Statistics and learning | Stats and automatic correction learning already exist | Improve access and correction control; do not build duplicate stats or learning engines |

### Requirements

**Everyday dictation and writing**

- R1. A person can correct a result and choose whether that correction affects only this result, a remembered spelling, or an app's writing style.
- R2. A person can recover the original words or reformat saved text without needing archived audio.
- R3. A person can create and try a reusable writing recipe from examples in Modes.
- R4. A person can choose paste and keep, paste and restore, or copy only; existing installs retain today's paste-and-keep behavior.
- R5. A person can use hesitation removal without generative rewriting, while As Heard preserves the recognizer's words and Code/Terminal keep their conservative behavior.
- R6. A person can discover common editing operations and optionally see provisional words while speaking.

**Languages and resources**

- R7. A person can find an appropriate installed speech model by language and task, and optionally route language/model choices from their keyboard input source.
- R8. A person can choose faster readiness or lower idle memory without managing model-worker internals.

**Meeting memory**

- R9. A person can jump from a meeting search hit, transcript line, chapter, or supported note to the relevant recording position.
- R10. A person can import a supported recording into Meetings and export transcripts in useful formats, with honest timing quality.
- R11. A person can choose a meeting-note template and turn supported decisions and actions into editable follow-up material.
- R12. A person can control meeting reminder/end behavior; recording still begins only after explicit confirmation.

**Control and simplicity**

- R13. A person can understand why a result changed and repair a failure from the existing app surfaces.
- R14. CLI, MCP, and optional Mac Shortcuts integrations reuse the app's capabilities and permission policy.
- R15. Dictation, cleanup, and meeting inference remain on-device; imported recipes do not silently execute code or grant access.
- R16. New features do not add mandatory onboarding steps or require configuring a pipeline before ordinary dictation works.

### Track 1: Correct a result and improve the next one

**Build first: a general Fix this action.** Offer it in History and in the recent-result menu on the HUD. Show the original transcript, current result, and an editable correction. The first action saves a corrected version; remembering a spelling or changing an app's style is a separate, explicit choice.

For example, correcting “Valora” to “Velora” can offer **Remember this spelling**. Correcting an entire paragraph should not turn that paragraph into a dictionary replacement. A style complaint can open the existing app-bound mode with the example available to test. Keep the current automatic learning system, but make its proposed and confirmed entries easier to inspect and undo.

**Add text-only reformatting.** Let people run “make this a short work update” or another saved mode against the stored raw transcript. Retrying speech recognition remains a separate action for cases where the words were misheard. A text-only retry must work after the audio has expired.

**Make As Heard and safe replacement immediate.** Add a recent-result action and optional shortcut. Replacement is available only while the exact inserted range can still be established. After a focus change or intervening edit, show a preview and copy the recovered text instead of guessing what to overwrite.

**Acceptance:** A corrected name can improve a later dictation after confirmation; a sentence rewrite never becomes an accidental global replacement; undo removes the new rule; text-only reformat works without audio; stale result operations cannot overwrite newer edits. Covers R1, R2, R13.

### Track 2: Make writing workflows easy to create and reuse

**Build a recipe gallery inside Modes.** Start with Work update, Issue report, Meeting follow-up, Structured note, Email, and Conservative technical text. Reuse suitable existing modes rather than adding duplicates. A recipe is a mode with a useful example and clear instructions.

**Add a Try it area.** Paste a sample transcript, select a mode, inspect the result, change instructions, and try again. Show a compact “what happened” explanation: selected app rule, deterministic changes, writing model, and any fallback. Keep raw/final comparison one click away.

**Offer common editing presets.** Shorter, Clearer, Formal, and Bullets should call the existing editing path. These are explicit transformations, so they can make changes that ordinary conservative dictation should not. Add Translate as a later explicit transformation after qualifying supported local models and language pairs; do not silently translate dictation.

**Add snippets and reusable structures next.** A phrase such as “my booking link” can expand to an explicitly saved value. A work-update recipe can organize only the facts dictated. Put simple expansions beside Dictionary replacements; add a richer snippet object only when variables or multiple paragraphs need it. Missing facts stay absent rather than being invented.

**Make advanced customization real.** Add recipe export/import, a versioned JSON Schema, a scaffold/validate CLI command, precise errors, and last-known-good reload behavior. Let advanced users enable or disable named processing steps. Consider reordering only stages whose combinations have defined semantics; there is no need for a visual node editor in the first version.

**Improve app rules.** Show the effective mode and precedence before Save. Support site-level rules when reliable local context identifies the site, and make temporary overrides easy. A person editing a rule and pressing Save has already expressed intent; avoid an extra trust dialog on every normal edit. Imported executable integrations, if added later, need their own approval.

**Acceptance:** A person can create and test an Issue report recipe without editing files; importing an invalid recipe preserves the working mode; explicit mode choices beat automatic rules; recipes cannot invent a reproduction step that was never dictated. Covers R3, R6, R13, R15, R16.

### Track 3: Better delivery, language choice, and readiness

**Delivery preferences:** Add one choice for Paste and keep, Paste and restore previous clipboard, or Copy only. Start globally; permit a mode override when a concrete workflow needs it. Preserve capture-time intent, clipboard change-count guards, transient markers, and existing spacing behavior. A copy-only take must never send a paste keystroke or enter Action Mode.

**Model-free cleanup:** Expose Remove hesitation sounds independently of generative rewriting. Reuse the filler scrubber, with coverage for literal “uh-huh,” quoted/code text, repeated fillers, and meaningful words such as “like.” Keep As Heard distinct and explain what the option changes.

**A clearer model picker:** Keep the recommendation prominent. Offer Installed, language capability, task suitability, and sorting by name or download size. Put technical details and measured device results in an expandable area. Do not infer runtime RAM requirements from download size or compare unlike workloads as if they were one benchmark.

**Optional Follow keyboard language:** Let users map input sources to an installed model and language, with a manual override. Choose and freeze the route when a take starts. Switching keyboards during a take affects the next take. An unavailable model gets an explicit fallback or a download offer; a keyboard switch must not start a large download by itself. Mixed-language speech remains a recognizer capability to qualify, not something keyboard routing proves.

**Simple memory policy:** Offer Automatic, Keep ready, and Save memory, with explanatory copy about the first dictation after unloading. Extend cleanup-worker hibernation first. Speech-model unloading is a separate backend lifecycle task. Never unload a worker during a take or an active meeting job. Keep experimental native cleanup's existing routing limits until quality evidence supports expansion.

**Acceptance:** All delivery choices survive delayed paste and user clipboard changes; a language route does not change mid-take; idle release and lazy reload work without losing a take; readiness and memory claims come from actual representative-device measurements. Covers R4, R5, R7, R8.

### Track 4: Make meetings easier to review and reuse

**Start with playback in meeting detail.** Clicking a transcript timestamp seeks to that passage; search results open the matching excerpt; the current passage highlights during playback. Add microphone/system-track selection for captured meetings. This makes the existing transcript and search immediately more useful.

**Import into Meetings.** Extend existing file transcription so a recording can become a durable meeting-library item with notes, playback, search, and exports. Label imported audio honestly instead of assigning it to Me/Them. Long imports use the existing resumable job and foreground-priority mechanisms.

**Ship export in two useful stages.** First add plain text and SRT/VTT as timed transcript blocks, clearly described as coarse when only chunk timings are available. Then add readable subtitle cues using genuine finer timing, suitable cue lengths, and alignment checks. Formatter validity alone is insufficient. WebVTT timing must follow the [W3C format](https://www.w3.org/TR/webvtt1/).

**Add post-meeting chapters before live chapters.** Chapters need titles, stable transcript ranges, and playback links. Live transcript and chapter previews follow after incremental transcription, capture-safe reads, checkpointing, and final reconciliation exist. Provisional titles may change; recording must continue if chapter generation fails.

**Named notes templates:** General, Standup, Interview, and Lecture can reuse the existing prompt editor and strict output schema. Add lightweight action checkboxes, links to supporting passages, Copy follow-up, and Draft recap. Preserve user edits when regenerating notes. Only attach an owner or deadline when the recording supports it.

**Local questions about a meeting:** Begin with search-backed answers for one meeting, each linked to supporting passages and able to say the transcript does not answer. Cross-meeting questions come later, after indexing, retrieval quality, deletion, and model-resource costs are measured. This extends the existing library rather than introducing a separate chat product.

**Expose meeting policy:** Add calendar lead time and clear Ask / Finish confirmed native calls / Never auto-finish choices over the existing detector. Preserve stronger caution for browser/manual recordings, and keep a visible way to continue recording.

**Acceptance:** A search hit seeks to the right passage; deletion stops playback and invalidates links; an imported interview never becomes “Me”; coarse exports state their limits; chapters survive a resumable job without duplicates; unsupported owners, deadlines, and answers are not invented. Covers R9, R10, R11, R12.

### Track 5: Useful local automation and extensibility

**Expand the existing CLI by workflow.** Add mode listing/validation, vocabulary management, meeting list/search/show/export, paste-last with deliberate delivery intent, and model status. Extend existing `stats` rather than creating a duplicate history-statistics product. Destructive commands such as history deletion need an explicit destructive-action flag and scope.

**Give MCP meaningful parity.** Add meeting discovery and selected content retrieval after introducing a separate meeting-data grant. Reading history, reading meeting content, running actions, and microphone use should not collapse into one broad switch. Mutation and delivery capabilities use the same app-owned checks as GUI actions. Recording still requires per-request visible consent.

**Add Mac Shortcuts actions.** Useful starting points are Transcribe file, Reformat text, Get last result, and Export meeting. On Mac, expose App Intents actions that people can compose in Shortcuts; Apple's documentation distinguishes these from automatically supplied App Shortcuts. [Apple guidance](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts).

**Allow named workflow handoffs later.** A recipe could draft a recap and then offer a chosen Shortcut or an existing Velora action. Make the destination and send/draft behavior visible. Integrations can have external effects, but do not move STT or cleanup to a cloud provider. Shared recipes should describe such a handoff without silently installing or enabling it.

**Acceptance:** UI, CLI, and MCP observe the same grants and deletion state; enabling dictation history does not expose meetings; a disabled integration cannot execute through a recipe; no new network listener is necessary. Covers R14, R15.

### Track 6: Feedback, polish, and accessibility without more clutter

**Live words beside the HUD:** Add optional read-only partial text for ordinary dictation, clearly provisional. Reuse STT partials without enabling streaming insertion. Keep it compact and easy to hide.

**Useful diagnostics:** Put recent failures, retries, and recovery actions under Help or Advanced first. Record structured events rather than rendering raw logs. Explain “model unavailable” or “paste blocked” and offer a relevant action. A separate Activity pane is justified only if people need to revisit it frequently.

**Storage and retention:** Make transcript, dictation audio, and meeting retention separate and understandable. Preserve current transcript retention by default. Preview how much will be removed before tightening a policy, apply record/audio cleanup consistently, and ensure search indexes and derived meeting material follow deletion.

**Sounds and shortcuts:** Add volume, a few distinct sound sets, preview without recording, and an optional second dictation shortcut with conflict detection and Restore defaults. These can ship alongside a larger track; none needs its own navigation surface.

**HUD preview:** Add a small settings preview with synthetic audio levels, useful choices such as compact/expanded display and contrast, and reversible changes. Start with a handful of choices; expand only if people use them. A dedicated HUD Lab can remain an experimental tool.

**Localization:** Schedule string extraction and translation support, including permission, error, and onboarding copy. Choose initial UI languages from actual users; keep UI language independent from speech language. Validate layout, accessibility labels, and locale formatting. This is broader than adding model language choices, but belongs on the roadmap.

**Acceptance:** Nothing here adds a required onboarding step; the default HUD remains compact; a preview never opens the microphone; deletion previews match actual cleanup; diagnostic export excludes transcript and context content by default. Covers R6, R13, R16.

### How the app stays simple

| Existing place | What belongs there |
|---|---|
| HUD and recent-result menu | As Heard, Fix this, retry/replace, optional live words |
| History | Compare versions, correct a result, reformat stored text, inspect why |
| Modes | Recipe examples, Try it, instructions, app/site rules, import/export |
| Dictionary | Confirmed spellings, simple expansions, inspect/undo learning |
| Meetings | Playback, source-linked notes, imports, chapters, templates, exports |
| Settings | Delivery, language/model choice, memory policy, sounds, permissions, retention |
| Help or Advanced | Diagnostics, experimental capabilities, detailed model measurements |

The first two releases should add no permanent sidebar pane. Do not require a new hotkey for every capability. Use contextual actions first, optional shortcuts second, and advanced controls only when a person asks for more control.

---

## Delivery Sequence

Effort labels describe relative scope in this repository: **S** is a contained behavior or UI extension, **M** spans persistence/UI/engine boundaries, and **L** needs new processing behavior or substantial quality evaluation. These are planning judgments, not time estimates.

| Release or track | Work | Relative effort | Dependency and release condition |
|---|---|---|---|
| 1A: Correct and reuse | Fix this for every dictation; guarded corrected versions; remembered-spelling preview and undo | M | Build on existing History feedback and learning; no automatic rule from a full rewrite |
| 1B: Reformat without audio | Text-only reformat and preview; quick As Heard access | M | Stored transcript/version handling; safe replacement falls back to copy |
| 1C: Make modes usable | Try it, a small recipe gallery, result explanation | M | Reuse existing modes and formatting; expose actual fallback rather than guessing stages |
| Small parallel work | Delivery preference and explicit model-free hesitation removal | S–M | Preserve existing clipboard and raw-mode contracts |
| 2A: Faster everyday writing | Editing presets, simple snippets, app/site rule preview, recipe sharing and validation | M | 1B/1C establish preview and retry; shared files cannot execute code |
| 2B: Language and readiness | Picker improvements, optional keyboard routing, cleanup idle-memory policy | M–L | Capture-time routing; backend-specific release/reload proof |
| 3A: Review recordings | Timestamp playback, search navigation, imported meeting-library items | M | Versioned source references and deletion-safe playback |
| 3B: Reuse recordings | Timed exports, finer subtitle timing, notes templates, chapters, supported action items | M–L | Timing work precedes subtitle-quality claims; evidence links precede answer generation |
| 4A: Meeting intelligence | Questions about one meeting; live transcript/chapter previews | L | Retrieval evaluation and incremental processing; foreground dictation remains responsive |
| 4B: Connected workflows | Narrow CLI/MCP capabilities, separate grants, Mac Shortcuts actions, explicit handoffs | M–L | Reuse each domain feature as it lands; packaged-app capability discovery first |
| Ongoing craft | Sounds, second shortcut, HUD preview/live words, diagnostics, storage controls, localization | S–L | Ship independently when useful; localization is its own larger slice |

Begin with 1A, then 1B and 1C. This order makes each later recipe or model improvement easier to evaluate and recover from. Meeting playback is the next strongest separate feature if meeting use is the immediate priority. Do not wait for all writing work before landing a focused meeting improvement.

### Open experiments with a useful first version

| Idea | Smallest useful version | Evidence needed before wider release |
|---|---|---|
| Individual meeting speakers | Anonymous Speaker 1/2 labels with manual rename/merge and Me/Them fallback | Representative multi-speaker, overlapping, long, and low-quality calls; explicit update to the current Me/Them product contract; no inferred personal identity |
| Flexible processing steps | Named switches and advanced declarative ordering for a supported subset | Defined ordering, preview, undo, invalid-combination handling, and repeatable output tests |
| More local summarizers | One optional backend with the same notes schema and template behavior | Actual output quality, hardware support, latency and contention; no need to add a provider merely because Hex names one |
| Richer translation and mixed-language writing | Explicit selected-text translation for a qualified language pair | Meaning preservation, terminology, code-switching, and unsupported-language behavior |
| Cross-meeting memory | Search across selected meetings, then cited answers | Retrieval quality, source completeness, reprocessing/deletion invalidation, practical local resource costs |
| Executable extensions | A named, explicitly enabled OS Shortcut or existing action | Clear requested capability and visible destination; isolated execution design before general scripts |
| Virtual microphone or audio effects | A separate prototype only for a real microphone-routing need | A useful recording/call workflow that justifies driver installation and support cost |
| Screen-related capture | Continue local context hints; evaluate richer capture only for a concrete user task | An explicit product need and permission design; a framework import in Hex is not enough reason |

These are candidates, not permanent exclusions. Prioritize them when a useful workflow and a credible implementation justify the additional maintenance. Keep cloud inference and silent recording outside this roadmap under R15 and R12. A loopback HTTP server and a new UI framework are unnecessary for the capabilities proposed here; the existing broker and native UI can deliver them.

---

## Engineering Starting Points

| Work package | Existing code and patterns | Verification starting points |
|---|---|---|
| Correction and corrected versions | `Sources/Velora/History/HistoryTrialFeedback.swift`, `HistoryStore.swift`; `Sources/Velora/Learning/DictionaryRepository.swift`, `LearningStore.swift`, `EditWatcher.swift` | `Sources/Velora/Selftest/Selftest.swift`: stale edits, version conflicts, rule preview/undo, deletion; `engine/tests/test_formatting.py`: correction application |
| Text-only reformat and editing presets | `Sources/Velora/App/DictationController.swift`; `engine/src/velora_engine/server.py`, `formatting.py`, `editing.py` | `engine/tests/test_server.py`, `test_formatting.py`, `test_editing.py`; Swift selftests for focus changes and unavailable audio |
| Recipe authoring and explanation | `Sources/Velora/Settings/ModesSettingsView.swift`; `engine/src/velora_engine/config.py`, `modes_builtin/`, `formatting.py` | Swift mode suites; `engine/tests/test_config_migrations.py`, `test_formatting.py`; invalid reload, rule precedence and native-backend fallback |
| Delivery and hesitation choice | `Sources/Velora/Insert/TextInserter.swift`, `TextInsertionBoundary.swift`; `Sources/Velora/Config/SettingsDocument.swift`; `formatting.py` | Swift insertion/pasteboard suites; `engine/tests/test_formatting.py`; real target-app checks in `docs/TESTING.md` |
| Model selection and memory | `Sources/Velora/Settings/SettingsViews.swift`, `SettingsModel.swift`; `engine/src/velora_engine/models.py`, `server.py`, `cleanup_process.py`, `native_cleanup.py` | `engine/tests/test_models.py`, `test_server.py`, `test_cleanup_process.py`, `test_cleanup_parking.py`, `test_native_cleanup.py`; measure cold/warm behavior on target Macs |
| Meeting playback and imports | `Sources/Velora/Meetings/MeetingStore.swift`, `MeetingProcessor.swift`; `Sources/Velora/Settings/MeetingsSettingsView.swift`; `Sources/Velora/App/FileTranscriber.swift`; `engine/src/velora_engine/media.py` | Swift meeting suites; `engine/tests/test_media.py`, `test_meeting_media_long.py`, `test_meeting_media_errors.py`; delete during playback/import, cancellation, resume, stable seek references |
| Meeting notes, chapters and exports | `Sources/Velora/Meetings/MeetingNotesWindowController.swift`, `MeetingStore.swift`, `MeetingAudioCapture.swift`; `engine/src/velora_engine/meeting_notes.py`, `server.py` | `engine/tests/test_meetings.py`, `test_diarization.py`; Swift stale-export guards; subtitle parsing plus human review of cue readability |
| Meeting policy | `Sources/Velora/Meetings/MeetingCoordinator.swift`, `MeetingDetector.swift`, `MeetingEndWatch.swift` | Swift cases for rejoining, unrelated calls, calendar timing, manual/browser uncertainty and keep-recording override |
| Local integrations | `Sources/Velora/Control/VeloraCLI.swift`, `MCPStdioServer.swift`, `LocalControlServer.swift`, `AgentIntegration.swift`; existing Action Mode | Swift broker/CLI/MCP suites; packaged-app checks for grants, off/default state, deletion, live-listen approval and foreground arbitration |
| HUD and support | `Sources/Velora/HUD/HUDModel.swift`, `HUDStyle.swift`; `Sources/Velora/App/SoundPlayer.swift`, `VeloraLog.swift`; existing settings/hotkey views | Swift logic tests; actual signed-app keyboard, reduced-motion, VoiceOver, contrast and permission-free preview checks |

For the initial writing release, define the text-only formatting request and corrected-version storage before adding convenience UI. Preserve raw text and bind asynchronous operations to the history-record version they started from. Reuse one formatting path for Modes previews, History retries, and future automation, while keeping insertion an explicit app-owned operation.

For meeting links, introduce a meeting revision and stable segment identifiers before building links from summaries or search results. Regenerated transcripts invalidate or remap references rather than silently pointing at unrelated audio. Live processing needs its own bounded incremental design; it must not repeatedly run the full post-pass over a growing recording.

### Qualification and completion

- Use actual dictation examples to compare raw, current, and proposed output. Measure preservation of meaning and useful correction, not just schema validity or model routing. Include names, negation, dates, technical identifiers, lists, mixed-language speech, and literal filler-like words.
- Compare matched cold and warm workloads for readiness changes. Record combined app and engine memory separately from individual-worker snapshots. Extend native cleanup support only after output-quality qualification, using `docs/research/2026-11-07-native-cleanup-trial.md` as existing context.
- Use `Sources/Velora/Selftest/Selftest.swift` for Mac logic and the relevant engine tests above. Each implementation slice must pass the repository's `make test` gate and its user-flow acceptance criteria; permission-sensitive capture and insertion also require the signed app and `docs/TESTING.md` checks.
- Keep built-in mode changes migration-safe through `_BUILTIN_MODE_SUPERSEDED` and `_BUILTIN_MODES_REV`. Version stored meeting/History changes so old records remain readable and user edits remain recoverable.
- Land each finished implementation slice on `main` with the project's normal release discipline. Do not bundle the whole roadmap into one release or leave a useful finished feature waiting on an unrelated experiment.

### Questions to resolve when selecting a later slice

The first writing release has no unresolved product blocker. Later slices should settle which UI languages users need first, which language pairs merit translation support, whether people want configurable step ordering, and whether individual remote-speaker labels are accurate enough to be useful. Treat these as targeted decisions for their own slice rather than reasons to delay the initial improvements.

---

## Sources

- `docs/research/2026-11-09-hex-teardown.md`: Hex feature surfaces and original adoption suggestions; runtime behavior was not established.
- `docs/SPEC.md`, `docs/ARCHITECTURE.md`, `README.md`, and current owning code listed above: Velora behavior and existing product contracts checked at `a977d80`.
- `docs/plans/2026-11-07-native-cleanup-trial.md`, `docs/research/2026-11-07-native-cleanup-trial.md`: current experimental-cleanup scope and evidence limits.
- [W3C WebVTT](https://www.w3.org/TR/webvtt1/): export timing contract; does not establish the precision of Velora's current segments.
- [Apple App Shortcuts guidance](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts): Mac Shortcuts can use App Intents actions; framework discovery in Velora's SwiftPM-packaged app needs a focused implementation check.
