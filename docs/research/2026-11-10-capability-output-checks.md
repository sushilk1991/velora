# Capability output checks

These checks used synthetic text with the installed `mlx-community/Qwen3.5-4B-MLX-8bit` writing model, loaded from its existing local cache with Hub access disabled. They did not use private dictation or meeting content. They are examples of working output, not a broad quality benchmark.

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

English, Hindi and Spanish have independent interface choices and English fallback. The catalogs cover the selected settings, onboarding, menu, HUD and accessibility surfaces; other panes and some dynamic engine/updater text retain English fallback. Permission descriptions have separate localized InfoPlist strings. All catalogs pass property-list parsing, and translated placeholder counts match.

Classic cue files are unchanged. Soft and Chime add six distinct, reproducible local PCM sounds. Preview does not start recording.

## Remaining qualification

Real target-app insertion, device-specific cold/warm memory behavior, broad meeting/translation quality, subtitle alignment, and live meeting capture each need their own evidence. Unit tests and valid exports do not establish those properties. The existing native-cleanup trial keeps its prior supported-input limits.
