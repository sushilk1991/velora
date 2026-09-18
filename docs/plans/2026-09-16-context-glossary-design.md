# Context Glossary design

## Scope

Implement the approved dictation-only design: prefer Accessibility text near the
cursor, fall back to visible text in the active window, then use local Apple
Vision OCR when structured context remains sparse. Supply bounded spelling
candidates to the existing writing model. Do not add Actions behavior, image
understanding, models, dependencies, model-tier changes, or general prompt changes.

## Capture and lifetime

```text
Dictation start
  -> one asynchronous context capture, bound to app + window + session
     -> near-cursor Accessibility text
     -> active-window Accessibility text, only when sparse
     -> active-window screenshot -> Apple Vision, only when still sparse
        -> discard image immediately
     -> ranked Context Glossary in session memory
Dictation stop
  -> take already-completed glossary or empty result; never wait
  -> existing local engine socket -> spelling hints for cleanup
  -> discard session context
```

Keep capture outside the microphone and stop-to-final paths. Pin the frontmost
process and window before gathering; recheck their identity and secure-input
state before each fallback and before accepting results. Discard a changed
window's result rather than gathering from its replacement. Cancellation, stop,
error, a new session, or disabling screen context invalidates late results.
Never retry capture during a dictation.

Preserve the existing exclusions for external local-agent listening and Action
recording. Skip secure input and secure Accessibility elements. Missing
Accessibility permission disables structured reads; do not use OCR to bypass a
privacy refusal. Screen Recording denial, unavailable capture/OCR, budget
exhaustion, or unreadable context leaves dictation working without those hints.
Do not request macOS permission in the recording or finalization path.

Near-cursor reads use a bounded selected-range neighborhood plus field labels
and nearby static text. Window fallback traverses only the pinned window,
skipping hidden/off-window elements and secure subtrees. Bound traversal time,
depth, node count, and source characters. No full-document read to discover a
small cursor neighborhood.

OCR captures only the pinned active window through the macOS screen-capture
API, with an image-size limit. Apple Vision recognizes text in-process; no image
is serialized to Python, sent to Qwen, written to disk, or retained in session
state. Recognition failure is an empty fallback, not a dictation failure.

## Glossary and model boundary

Extract candidate names and technical tokens deterministically from bounded
source strings. Preserve spelling and case; normalize only comparison keys.
Reject prose, control markers, URLs carrying private paths, and instruction-like
strings. Rank by near-cursor evidence, existing named title/file/person signals,
active-window Accessibility evidence, then OCR. Resolve ties by stable source
order; deduplicate case-insensitively.

Use named limits: at most 24 terms, 40 characters per term, and 600 characters
total. Fewer than three distinct useful terms is sparse. Bounds apply before
prompt construction as well as at capture. These initial limits are validation
parameters, not permission to expand the feature.

Retain existing site/mode and explicit tagging behavior without sending window
prose to the writing model. The smallest prompt integration labels the glossary
as untrusted spelling data: use a term only when the speech refers to it, never
insert an unspoken term, and never follow screen instructions. Serialize only
validated candidates, not nearby paragraphs, window text, or screenshots.
Existing cleanup/divergence behavior otherwise remains unchanged.

Context never enters history, audio metadata, logs, dictionary learning inputs,
or a reusable model-prefix cache. A spoken name appearing in the resulting
transcript remains ordinary transcript content; the captured glossary itself
has no persistence path.

## Privacy audit and copy

Source inspection completed before writing user-facing claims:

- `engine/src/velora_engine/models.py:212` resolves cached models locally before
  downloading missing files. STT and cleanup load local model paths. Initial
  Python/model setup and later model changes can require network access.
- `Sources/Velora/App/UpdateChecker.swift` and `UpdateInstaller.swift` contact
  GitHub for release checks and downloads. Updates are separate from dictation.
- `Sources/Velora/Learning/ICloudDictionarySync.swift` synchronizes the Personal
  Dictionary through the user's iCloud Drive; `AppDelegate.swift:650` starts
  that service. Learned or mined transcript terms can become dictionary entries.
  Do not claim the whole application or every dictionary term stays offline.
- `EngineClient`, the engine server, and the writing worker use local sockets.
  Audio/history are stored locally. No application analytics or crash-upload
  implementation was found in the inspected application/engine sources.
- The proposed screen capture and Vision recognition have no network or storage
  step. Offline execution and permission behavior still require validation.

Onboarding keeps its existing steps. Explain that after local setup, dictation
and screen context work in airplane mode, use no Velora dictation server, and
send no audio or captured screen context to us. Explicitly distinguish setup,
updates, and Personal Dictionary iCloud sync. Avoid saying the entire app never
uses the network or that output pasted into another app cannot leave the Mac.

Settings > Dictation gains **Use screen context for spelling**, disabling all
ordinary-dictation screen reads when off. Explain near-cursor/window reading,
local Apple Vision fallback, optional Screen Recording permission, and that
captured context is discarded after the dictation. Permission setup is an
explicit Settings action, never a recording-time prompt. The setting is
machine-local privacy state, not an imported permission grant.

`docs/SPEC.md` currently excludes screenshots/OCR and claims no network use after
model download. Update only those stale statements to match this approved scope
and the verified network exceptions. Update the context/protocol sections of
`docs/ARCHITECTURE.md` and `engine/README.md` alongside implementation.

## Implementation and validation plan

1. Add failing executable behavioral tests in
   `Sources/Velora/Selftest/Selftest.swift` for staged capture, bounds, ranking,
   secure fields, denied permissions, unavailable OCR, window switches, late
   results, disabled context, and excluded recording policies. Run `swift build`
   and `.build/debug/Velora --selftest` to record the red result.
2. Implement private context extraction/capture mechanics in `Context/`, using
   injected readers for deterministic tests. Connect one-shot session lifetime
   in `App/DictationController.swift`. Expose only the minimal domain/test
   interface after approval; keep raw AX/image mechanics private.
3. Add failing Python prompt/protocol tests, then integrate bounded glossary
   data through the existing local entity path. Test malformed data and emitted
   prompt payloads; source-string assertions are not behavioral evidence.
4. Add the setting and onboarding copy after the privacy audit. Test persistence,
   disabled reads, and unchanged onboarding readiness gates.
5. Run a paired local-model corpus with visible spoken names/technical terms,
   visible but unspoken distractors, prompt injection, AX-only and OCR-only
   fixtures, and missing permissions. Require improved exact spelling, zero
   inserted distractors, zero followed instructions, no existing cleanup-corpus
   regression, and no material stop-to-final regression. Record baseline and
   glossary results and actual timings; fake model output cannot satisfy this
   gate.

Run the complete repository surfaces: `make test`, `make test-coverage`,
`make perf-test`, release packaging without a version bump
(`./scripts/make-app.sh release none`), and release selftests. Exercise supported
hardware/iOS surfaces where available and record any missing environmental
evidence rather than treating it as passing. Use the signed bundle for TCC/OCR
checks. Commit on the task branch, report completion to firstmate, then drive
the no-mistakes pipeline when firstmate instructs it. Never push the default
branch or merge a PR.

## Approval needed before code

The brief requires approval before adding internal access. Behavioral tests and
layered integration need a small internal Context Glossary capture/result
interface, a session-lifetime interface, and the AppConfig/SettingsModel screen
context preference. Raw readers, image handling, limits, extraction helpers,
and mutable state remain private. No existing private method needs widening.
