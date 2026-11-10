# Capability output checks

These checks used synthetic text with the installed `mlx-community/Qwen3.5-4B-MLX-8bit` writing model, loaded from its existing local cache with Hub access disabled. They did not use private dictation or meeting content. They are examples of working output, not a broad quality benchmark.

## Implementation checkpoint

The main roadmap now has implementations in the existing app surfaces:

| Area | Available work |
|---|---|
| Correction and recovery | Fix this, remembered spelling with guarded undo, corrected versions, raw comparison, text-only reformatting |
| Reusable writing | Recipe examples and playground, import/export and validation, app/site precedence, supported deterministic step ordering, snippets, editing and translation presets |
| Delivery and resources | Paste/clipboard choices, independent hesitation removal, installed-model filtering, optional keyboard-language routing, cleanup idle-memory policy |
| Meeting review | Playback and seek links, recording imports, coarse exports, fine-timing subtitle previews, templates, semantic chapters, exact retrieved excerpts, action checkboxes, personal notes, editable recaps |
| Local workflows | Narrow CLI/MCP grants, four discoverable native Shortcuts actions, explicit result sharing through the Mac share chooser |
| Settings and feedback | Live HUD words and synthetic preview, diagnostics, separate retention controls, sounds and volume, alternate shortcut, English/Spanish interface support |

Live meeting transcript/topic previews are implemented as an opt-in experiment with the limits below. Individual remote-speaker identities, synthesized cross-meeting answers, general executable recipe extensions, virtual microphones, and richer screen capture remain roadmap experiments. No public release was created in this implementation round.

The complete `make test` gate passed with 4,279 Swift checks and 2,394 engine tests (3 skipped). Site, App Intents metadata, signing, publishing, engine bootstrap, and update-lifecycle checks passed too. The installed interface picker was also checked directly: its only choices are English and Español.

## Selected text

| Operation | Input covered | Observed output |
|---|---|---|
| Shorter | Priya has **not** approved a launch; 12 November, 3 PM; budget unconfirmed | Negation, date, time and budget uncertainty preserved |
| Bullets | Priya's approval; `/v1/exports`; do not ship before Friday | Three bullets, preserving the API path and restriction |
| English → Hindi | Do not send an invoice before 12 November; ₹4,500 | Negation, date and amount preserved; Hindi phrasing was understandable but less natural than ideal |
| English → Spanish | Same invoice example | Negation, date and amount preserved |
| Hindi → English | Same instruction in Devanagari | Negation, date and amount preserved; “चालान” became “challan,” showing a terminology limitation |
| Spanish → English | Same invoice instruction in Spanish | Negation, date and amount preserved |

This covers one writing model and a few short sentences. It does not qualify long selections, mixed-language text, all model choices, specialized terminology, or every translation direction. The presets remain explicit selected-text transformations with normal undo and existing selection guards.

## Meeting notes and chapters

The real notes pipeline processed four synthetic Me/Them blocks about launch approval and onboarding. It preserved the unapproved launch date, the Friday checklist, and the absence of an onboarding deadline. No participant identity was inferred.

The first run generated chapter keys such as `@me:0`, copying the displayed source marker despite instructions to omit it. The validator rejected them, leaving no chapters. The fix accepts the optional display marker and still requires an exact real source key visible in that model input. A regression test failed before this fix and passed afterward.

The next real-model run returned two accepted chapters, **Launch Budget and Approval** and **Onboarding Improvements**, each tied to the actual first and last transcript blocks and exact source text. Their timing remains the transcript block timing; these checks do not establish word-level subtitle alignment.

Generated notes still require review. In this example, a suggestion to add a microphone label was grouped into an onboarding agreement. Related-passage links make the source inspectable; lexical overlap does not prove that every claim in a note is supported. Meeting questions return exact retrieved excerpts rather than synthesizing an unsupported answer.

## Interface and resource checks

English and Spanish have independent interface choices and English fallback. Hindi was removed from the interface at the user's request; this does not remove Hindi speech recognition or the translation capability checked above. The catalogs cover the selected settings, onboarding, menu, HUD and accessibility surfaces; other panes and some dynamic engine/updater text retain English fallback. Permission descriptions have separate localized InfoPlist strings. Catalogs pass property-list parsing, and translated placeholder counts match.

Classic cue files are unchanged. Soft and Chime add six distinct, reproducible local PCM sounds. Preview does not start recording.

## Subtitle timing and live preview

The installed full `mlx-community/whisper-large-v3-turbo` model processed synthetic macOS voices with Hub access disabled. Separate English and Spanish samples each recovered all 17 expected words and produced three pause-separated cues. English cue ranges were 0–1.44, 2.66–4.48, and 5.64–7.82 seconds; Spanish ranges were 0–1.26, 2.24–4.14, and 4.94–7.12 seconds. These are model-estimated word times from the audio, not evenly divided transcript blocks.

A longer synthetic planning recording exercised the real engine command, CAF conversion, shared STT executor, multiple audio windows, source fingerprints, and completion events. It produced 12 readable cues, preserved the unapproved budget and review restriction, and released its audio lease after completion. Punctuation differed slightly from the supplied script. SRT and WebVTT structure, escaping, cue limits, channel labels, and invalid alignment are also checked independently in Swift and Python tests.

The first timed-subtitle backend is the already-installed full Whisper Turbo model. Other speech backends retain coarse timed-transcript exports and receive an explanation when fine timing is requested. Subtitle generation recognizes the saved audio again; its words can differ from the stored transcript. This small synthetic check does not qualify noisy calls, accents, overlapping voices, or every language.

Live meeting previews are optional, default off, and marked experimental. Synthetic checks use the actual sealed-window writer, system-audio disk writer, controller, and meeting store. They cover real sample offsets, bounded backlog, cursor replay, checkpoint restoration, stale replies, cancellation, and preview-storage failure without truncating the main recording. Provisional results never replace committed notes or transcript text; final processing uses the complete recording. An uncertain engine disconnect keeps preview audio pinned until a terminal reply or a newly accepted job proves the previous reader has settled. If the engine never returns, finalization waits rather than deleting potentially in-use audio.

## Remaining qualification

Real target-app insertion, device-specific cold/warm memory behavior, broad meeting/translation quality, subtitle alignment on representative calls, and hardware live meeting capture each need their own evidence. Unit tests and synthetic exports do not establish those properties. The existing native-cleanup trial keeps its prior supported-input limits.
