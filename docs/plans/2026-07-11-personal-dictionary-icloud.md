# Personal Dictionary and iCloud Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Velora users one global Personal Dictionary for exact terms and optional “heard as → write as” rules, preserve the existing edit-learning system, and synchronize only confirmed dictionary data through `iCloud Drive/Velora/Personal Dictionary/` without slowing or blocking dictation.

**Architecture:** Keep `config.json`, `learned.json`, and `auto_learned.json` as local engine-facing projections. Add a Swift-owned, versioned dictionary domain model and repository that imports those stores, applies deterministic precedence, journals mutations, and writes an allow-listed sync document. A lifecycle-owned iCloud coordinator reconciles that document off the main thread and projects merged state locally; Settings is only a client of the repository, never the sync owner.

**Tech Stack:** Swift 5.10, AppKit/SwiftUI, Foundation iCloud Documents APIs (`NSFileCoordinator`, `NSMetadataQuery`, `NSFileVersion`), Swift selftests, Python 3.12/pytest, SwiftPM, zsh release scripts, Developer ID signing/notarization.

---

## Execution rules

- Use `@superpowers:test-driven-development` for every behavior change: add one focused failing test, prove it fails for the intended reason, make it pass, then refactor.
- Use `@cloudkit-sync` constraints even though the chosen transport is iCloud Documents: local-first operation, account-change privacy boundary, explicit conflict handling, observable sync state, and no main-thread network/file coordination.
- Keep each commit independently buildable and scoped to the task below.
- Do not change the model size, transcription quality settings, history schema, or dictation hot path.
- Do not serialize transcripts, audio, history, pending learning counts, auto-miner candidates/checkpoints, model/settings data, or screen context.
- Before UI sign-off, use `@lenny-design-review`; before claiming completion, use `@superpowers:verification-before-completion`.

## Task 1: Define and test the portable dictionary domain

**Files:**

- Create: `Sources/Velora/Learning/DictionaryDocument.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Step 1: Add failing domain tests**

Add selftests for:

- whitespace normalization and case-insensitive stable keys;
- technical spellings such as `C++`, `node.js`, `auth_check`, hyphens, and apostrophes;
- rejection of empty strings, control characters, newlines, and values over 60 characters;
- vocabulary-only and optional heard-as entries;
- explicit manual precedence over learned and auto entries;
- independent add/add merge;
- update/update deterministic winner;
- add/delete delete-wins behavior;
- explicit re-add after deletion;
- namespace clear generation blocking long-offline resurrection;
- unsupported-newer schema and corrupt payload rejection; and
- a serialization privacy allow-list that cannot contain representative transcript, audio path, pending-count, candidate, checkpoint, model, or screen-context values.

Run:

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: build fails because `DictionaryDocument` does not exist.

**Step 2: Implement the minimum versioned model**

Implement:

- `DictionaryEntryKind`: `manualTerm`, `manualReplacement`, `learnedHard`, `learnedSoft`, `autoTerm`, `autoBan`;
- a normalized logical key distinct from the user's preserved display spelling;
- bounded `DictionaryValue` validation shared by UI/import/migration;
- per-entry epoch/revision, mutation timestamp, device identifier, and tombstone;
- per-namespace clear generations;
- deterministic merge with manual > learned > auto precedence and delete-wins within an epoch;
- explicit re-add by advancing the epoch;
- schema-version validation and stable sorted encoding.

Keep the wire payload as an explicit `Codable` allow-list rather than encoding runtime store objects.

**Step 3: Prove all tests pass**

Run:

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: all existing and new selftests pass.

**Step 4: Commit**

```bash
git add Sources/Velora/Learning/DictionaryDocument.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: define portable personal dictionary"
```

## Task 2: Make existing learning stores safely projectable

**Files:**

- Modify: `Sources/Velora/Learning/LearningStore.swift`
- Modify: `Sources/Velora/Learning/AutoVocabStore.swift`
- Modify: `Sources/Velora/Config/AppConfig.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`
- Modify: `engine/tests/test_vocab_miner.py`

**Step 1: Add failing projection and race tests**

Cover:

- portable learned snapshot excludes pending `counts`;
- applying a portable snapshot preserves local pending counts;
- `clearCorrections()` preserves standalone imported vocabulary;
- vocabulary-only dictionaries can be added, removed, exported, and imported;
- malformed/unbounded imported prompt strings are rejected;
- auto snapshot includes only promoted terms and bans;
- applying auto state preserves candidates, checkpoint, and future unknown keys;
- Swift-remove/Python-miner and Python-miner/Swift-remove orderings do not resurrect a banned term or drop a newly promoted term;
- updating manual config vocabulary/replacements preserves every unrelated config key.

Run:

```bash
swift build -c release && .build/release/Velora --selftest
cd engine && uv run pytest -q tests/test_vocab_miner.py
```

Expected: new tests fail against the current store APIs/write behavior.

**Step 2: Add narrow store APIs**

Implement atomic snapshot/apply methods:

- `LearningStore.PortableSnapshot` with hard/soft corrections and standalone vocabulary only;
- standalone vocabulary CRUD and `clearCorrections()` that does not erase it;
- strict shared validation on all imports;
- `AutoVocabStore.PortableSnapshot` with promoted terms and bans only;
- fresh-read/merge/atomic-write logic that preserves engine-owned state and avoids stale whole-file overwrites;
- `AppConfig` manual-dictionary snapshot/apply methods that mutate only `vocabulary` and `replacements`.

Use owner-only `0600` permissions for files and preserve local engine compatibility.

**Step 3: Run focused and full store tests**

```bash
swift build -c release && .build/release/Velora --selftest
cd engine && uv run pytest -q tests/test_vocab_miner.py
```

Expected: focused tests pass.

**Step 4: Commit**

```bash
git add Sources/Velora/Learning/LearningStore.swift Sources/Velora/Learning/AutoVocabStore.swift Sources/Velora/Config/AppConfig.swift Sources/Velora/Selftest/Selftest.swift engine/tests/test_vocab_miner.py
git commit -m "fix: make learning stores safely portable"
```

## Task 3: Build the local-first dictionary repository

**Files:**

- Create: `Sources/Velora/Learning/DictionaryRepository.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Step 1: Add failing repository tests**

Use temporary `config.json`, `learned.json`, `auto_learned.json`, and sync-state URLs. Test:

- idempotent first-run migration from all three current stores;
- a manual term immediately projects to config vocabulary;
- heard-as creates a manual deterministic replacement and exact written term;
- manual entries win over learned/auto collisions;
- edit/delete/clear create tombstones instead of physical erasure;
- local mutation persists before sync publication;
- merged remote state projects atomically without losing local pending counts or miner state;
- import/export covers the complete portable dictionary;
- a failed/corrupt remote apply leaves the last valid local dictionary untouched;
- mutation notifications request one engine reload after the projection is complete.

Run:

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: tests fail because the repository does not exist.

**Step 2: Implement the repository**

Create a `@MainActor` observable repository that:

- owns the canonical local `DictionaryDocument` at `~/.velora/dictionary_sync.json`;
- accepts injected store URLs, device ID, clock, and reload callback for tests;
- migrates existing stores once without duplicating entries;
- exposes unified Added/Learned/Auto rows and source metadata;
- validates, adds, edits, removes, clears, imports, and exports;
- persists the document/journal first, projects store files second, then invokes `reload_config`;
- provides immutable snapshots to the background sync coordinator;
- publishes local mutation and projection-complete notifications.

Do not put `NSFileCoordinator`, iCloud lookup, or Settings presentation logic in this type.

**Step 3: Pass repository tests**

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: all Swift selftests pass.

**Step 4: Commit**

```bash
git add Sources/Velora/Learning/DictionaryRepository.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: add local personal dictionary repository"
```

## Task 4: Prove engine precedence and mode vocabulary safety

**Files:**

- Modify: `engine/src/velora_engine/server.py`
- Modify: `engine/src/velora_engine/formatting.py` if the active-mode allow-list must be threaded there
- Modify: `engine/tests/test_formatting.py`
- Modify: `engine/tests/test_divergence.py`
- Modify: `engine/tests/test_server.py`
- Modify: `engine/tests/test_server_streaming.py`

**Step 1: Add failing engine tests**

Prove:

- manual global replacement wins over learned hard/soft data for the same heard form;
- manual vocabulary is present in both Whisper/session glossary and cleanup prompt;
- a short utterance still receives an explicit manual replacement;
- Parakeet output receives manual heard-as replacement without relying on a glossary;
- learned and auto values remain available when no manual collision exists;
- only the active mode vocabulary joins cleanup `allowed_terms`;
- active mode vocabulary works in both whole-text and streaming cleanup;
- terms from inactive modes are not globally allow-listed.

Run:

```bash
cd engine && uv run pytest -q tests/test_formatting.py tests/test_divergence.py tests/test_server.py tests/test_server_streaming.py
```

Expected: active-mode allow-list tests fail; any other failing test identifies an actual precedence regression to fix.

**Step 2: Thread active-mode vocabulary through cleanup**

Capture the active `GateResult.mode.vocabulary` for a session and pass only that mode's vocabulary, plus global learned/manual vocabulary, to cleanup divergence checking in both streaming and whole-text paths. Keep deterministic replacements before/at the existing formatting boundary so short utterances and Parakeet are covered.

**Step 3: Run focused tests**

```bash
cd engine && uv run pytest -q tests/test_formatting.py tests/test_divergence.py tests/test_server.py tests/test_server_streaming.py
```

Expected: focused tests pass.

**Step 4: Commit**

```bash
git add engine/src/velora_engine/server.py engine/src/velora_engine/formatting.py engine/tests/test_formatting.py engine/tests/test_divergence.py engine/tests/test_server.py engine/tests/test_server_streaming.py
git commit -m "fix: honor personal and mode vocabulary in cleanup"
```

## Task 5: Implement the iCloud Documents transport behind an injectable boundary

**Files:**

- Create: `Sources/Velora/Learning/ICloudDictionarySync.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Step 1: Add failing coordinator tests with a fake transport**

Cover:

- iCloud unavailable leaves local state active and reports local-only status;
- initial empty cloud publishes the local document;
- remote-only additions merge locally;
- local and remote independent additions survive;
- cloud download-in-progress reports waiting and never replaces local state;
- corrupt or newer-schema remote files surface an error without data loss;
- unresolved file versions are all merged before conflicts are marked resolved;
- account identity change pauses upload and exposes keep-local, use-cloud, and explicit-merge decisions;
- repeated notifications are debounced/coalesced;
- all coordinated I/O happens off the main thread.

Run:

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: tests fail because the sync coordinator does not exist.

**Step 2: Implement transport protocol and sync state**

Define an injectable file transport and `DictionarySyncStatus` values for synced, syncing, local-only, waiting-for-download, account-change, and actionable error. The production transport must:

- resolve `FileManager.url(forUbiquityContainerIdentifier:)` off-main;
- create `Documents/Personal Dictionary/` in the app ubiquity container;
- coordinate reads/writes with `NSFileCoordinator`;
- request ubiquitous-item downloads when needed;
- observe remote changes using `NSMetadataQuery` (or a file presenter if simpler and testable);
- decode every unresolved `NSFileVersion`, merge them, write one canonical winner, then mark stale conflicts resolved;
- atomically replace the cloud document;
- never block local mutations or the dictation path.

Persist the last observed Apple Account identity token locally. Treat a token change as a privacy gate, not an automatic merge/upload.

**Step 3: Pass sync tests**

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: all Swift selftests pass without requiring live iCloud.

**Step 4: Commit**

```bash
git add Sources/Velora/Learning/ICloudDictionarySync.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: sync personal dictionary through iCloud Drive"
```

## Task 6: Own learning and sync for the whole app lifecycle

**Files:**

- Modify: `Sources/Velora/App/AppDelegate.swift`
- Modify: `Sources/Velora/App/DictationController.swift`
- Modify: `Sources/Velora/App/EngineSupervisor.swift`
- Modify: `Sources/Velora/EngineClient/EngineEvent.swift` if adding a vocabulary-promotion event
- Modify: `engine/src/velora_engine/server.py` if adding the matching event
- Modify: `engine/src/velora_engine/vocab_miner.py` if promotion signaling belongs there
- Modify: `engine/tests/test_server.py`
- Modify: `engine/tests/test_vocab_miner.py`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Step 1: Add failing lifecycle tests**

Test that:

- AppDelegate creates one shared repository and sync coordinator before Settings opens;
- committed edit-learning is captured into the repository, projected, reloaded, and queued for sync;
- auto-miner promotion is captured while Settings is closed;
- launch performs an idempotent reconciliation scan;
- engine reload happens after projection, never before;
- sync continues independently of Settings window lifetime.

Run the relevant Swift selftests and Python promotion tests. Expected: the Settings-owned/current independent stores cannot satisfy lifecycle ownership.

**Step 2: Wire the composition root**

- Let AppDelegate own the repository and coordinator for process lifetime.
- Inject the shared repository into DictationController and Settings.
- Replace DictationController's private `LearningStore` with repository capture after committed observations.
- Add the smallest reliable engine event for auto-vocabulary promotion, or a bounded file-observation/reconciliation mechanism if an event would duplicate miner truth.
- Start sync after local migration; stop observers on termination.

**Step 3: Verify lifecycle behavior**

```bash
swift build -c release && .build/release/Velora --selftest
cd engine && uv run pytest -q tests/test_server.py tests/test_vocab_miner.py
```

Expected: tests pass.

**Step 4: Commit**

```bash
git add Sources/Velora/App/AppDelegate.swift Sources/Velora/App/DictationController.swift Sources/Velora/App/EngineSupervisor.swift Sources/Velora/EngineClient/EngineEvent.swift Sources/Velora/Selftest/Selftest.swift engine/src/velora_engine/server.py engine/src/velora_engine/vocab_miner.py engine/tests/test_server.py engine/tests/test_vocab_miner.py
git commit -m "feat: keep dictionary learning active for app lifetime"
```

## Task 7: Add the dedicated Personal Dictionary settings experience

**Files:**

- Create: `Sources/Velora/Settings/DictionarySettingsView.swift`
- Modify: `Sources/Velora/Settings/SettingsModel.swift`
- Modify: `Sources/Velora/Settings/SettingsViews.swift`
- Modify: `Sources/Velora/Settings/SettingsWindowController.swift`
- Modify: `Sources/Velora/App/AppDelegate.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Step 1: Add failing view-model tests**

Cover:

- unified Added/Learned/Auto rows and source labels;
- case-insensitive search;
- add/edit validation and duplicate/collision messaging;
- optional heard-as disclosure;
- warning for risky common-word manual replacement;
- delete/forget and class-clear confirmation semantics;
- complete import/export result counts;
- every sync status and account-change action;
- no old learning-management lists remain in Dictation settings.

Run Swift selftests. Expected: missing dictionary tab/model API failures.

**Step 2: Implement the native SwiftUI surface**

- Add `.dictionary` to `SettingsTab` with a recognizable book/dictionary symbol.
- Build the compact searchable list with Add, source labels, edit/delete, import/export, and sync footer.
- Make `Write as` primary and reveal `When Velora hears` as optional complexity.
- Keep `Learn from my edits` and `Learn new words automatically` toggles in Dictation; move only entry-management UI.
- Use truthful privacy copy: `Synced privately through your iCloud Drive` and an Open Folder action.
- Keep empty/loading/error states compact; do not add a large HUD-like card or excess vertical whitespace.
- Ensure keyboard navigation, VoiceOver labels, focus order, Dynamic Type behavior, contrast, and reduced-motion compatibility.

**Step 3: Review product quality before polishing**

Run `@lenny-design-review` against the implemented flow. Accept only changes that improve clarity, trust, or task completion without expanding scope. Record the resulting changes in the commit message/body if material.

**Step 4: Build and exercise the view model**

```bash
swift build -c release && .build/release/Velora --selftest
```

Expected: tests pass.

**Step 5: Commit**

```bash
git add Sources/Velora/Settings/DictionarySettingsView.swift Sources/Velora/Settings/SettingsModel.swift Sources/Velora/Settings/SettingsViews.swift Sources/Velora/Settings/SettingsWindowController.swift Sources/Velora/App/AppDelegate.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: add Personal Dictionary settings"
```

## Task 8: Add iCloud entitlements and fail-closed distribution packaging

**Files:**

- Modify: `Resources/Velora.entitlements`
- Modify: `Resources/Info.plist`
- Modify: `scripts/make-app.sh`
- Modify: `scripts/verify-dmg.sh`
- Create: `scripts/test-signing-config.sh`
- Modify: `.gitignore` if the local profile path needs excluding
- Modify: `README.md`

**Step 1: Add failing deterministic signing checks**

Build a fixture-oriented shell test that asserts:

- distribution packaging fails before version bump/build when `VELORA_PROVISIONING_PROFILE` is missing;
- a supplied profile is copied to `Contents/embedded.provisionprofile`;
- requested entitlements include the exact iCloud container and iCloud Documents service;
- profile entitlements authorize the same application identifier, team, container, and service;
- `Info.plist` declares the app-specific ubiquity display/document scope;
- verification fails for mismatched/missing profiles or entitlements;
- development/local-only builds still launch without a profile.

Run:

```bash
./scripts/test-signing-config.sh
```

Expected: failures against current scripts.

**Step 2: Implement fail-closed packaging**

- Add the exact iCloud container/service entitlements authorized by the Developer ID profile.
- Add ubiquity container metadata to Info.plist for the `Velora/Personal Dictionary` document scope.
- Require `VELORA_PROVISIONING_PROFILE` for `VELORA_DISTRIBUTION=1`, decode it before any version bump, compare entitlements, and embed it.
- Keep generated/expiring profiles out of Git; document local provisioning.
- Extend DMG verification to inspect signed entitlements and embedded profile, not only the microphone entitlement.

Do not weaken hardened runtime, notarization, stapling, Gatekeeper, or microphone checks.

**Step 3: Run signing configuration tests**

```bash
./scripts/test-signing-config.sh
plutil -lint Resources/Info.plist Resources/Velora.entitlements
```

Expected: tests pass.

**Step 4: Commit**

```bash
git add Resources/Velora.entitlements Resources/Info.plist scripts/make-app.sh scripts/verify-dmg.sh scripts/test-signing-config.sh .gitignore README.md
git commit -m "build: provision private iCloud dictionary sync"
```

## Task 9: Run complete regression and privacy verification

**Files:**

- Modify only files required by proven failures.

**Step 1: Run the full deterministic suites**

```bash
swift build -c release
.build/release/Velora --selftest
cd engine && uv run pytest -q
```

Expected: Swift build/selftests and all Python tests pass.

**Step 2: Run privacy payload inspection**

Generate a fixture dictionary with sentinel transcript, audio path, screen context, pending count, candidate, checkpoint, and model values in the local runtime stores. Export/sync it and prove none of those sentinels or forbidden keys occur in the cloud document.

Expected: only allow-listed dictionary entries and merge metadata are present; local files remain `0600`.

**Step 3: Run performance regression checks**

Measure repository mutation/projection on a maximum-size dictionary and launch migration on fixture data. Confirm iCloud lookup/coordination never runs on the main thread and dictation does not await sync.

Expected: no measurable transcription hot-path regression; local add/edit completes before cloud work.

**Step 4: Commit any evidence-driven corrections**

```bash
git add <only-files-needed-for-fixes>
git commit -m "fix: close dictionary verification findings"
```

Skip the commit if no files changed.

## Task 10: Run independent adversarial review and resolve findings

**Files:**

- Modify only files required by accepted findings.

**Step 1: Request falsification-focused review**

Per `CLAUDE.md`, run read-only independent review with the global `yoyo` skill/CLI:

```bash
yoyo ask codex,claude --role review --read-only --background --cwd "$PWD" "Adversarially review the Personal Dictionary and private iCloud sync branch against docs/plans/2026-07-11-personal-dictionary-icloud-design.md. Try to falsify privacy allow-listing, deletion/tombstone convergence, account-change isolation, store race safety, engine precedence, main-thread performance, Settings UX clarity, and Developer ID entitlement/profile verification. Report only evidence-backed blockers or concrete improvements with file/line references."
```

**Step 2: Independently inspect every finding**

Do not accept review claims without reproducing them in code/tests. For every valid issue, add a failing regression test first, implement the smallest fix, and rerun the focused suite.

**Step 3: Re-run complete tests**

```bash
swift build -c release && .build/release/Velora --selftest
cd engine && uv run pytest -q
```

**Step 4: Commit accepted fixes**

```bash
git add <review-fix-files>
git commit -m "fix: resolve personal dictionary review findings"
```

Skip the commit if the review finds no valid issues.

## Task 11: Provision, package, notarize, and verify the release

**Files:**

- Modify: `VERSION` and stamped `Resources/Info.plist` through release scripts.

**Step 1: Verify external Apple capability state**

Before building the distribution artifact, prove the explicit App ID `com.sushil.velora`, iCloud Documents service, `iCloud.com.velora.app` ubiquity container, and Developer ID provisioning profile all agree. Decode the profile locally and compare it to source entitlements.

**Step 2: Build the feature release**

Use a minor version bump because this is a user-visible feature:

```bash
VELORA_PROVISIONING_PROFILE="/absolute/path/to/Velora_Developer_ID.provisionprofile" ./scripts/make-dmg.sh release minor
```

Expected: Developer ID-signed, notarized, stapled DMG is produced and `verify-dmg.sh` passes exact profile/entitlement checks.

**Step 3: Inspect the artifact directly**

Verify:

- bundle/version/build identity;
- embedded engine is from this branch;
- hardened runtime and Developer ID chain;
- embedded provisioning profile;
- exact microphone + iCloud entitlements;
- notarization ticket, stapling, and Gatekeeper approval.

**Step 4: Commit release metadata**

```bash
git add VERSION Resources/Info.plist
git commit -m "release: Velora <new-version>"
```

## Task 12: Install and prove the real user-visible workflow

**Files:** None unless a proven runtime defect requires a test-first fix.

**Step 1: Install the verified artifact**

Quit Velora, replace `/Applications/Velora.app` with the verified build, relaunch it, and confirm the running process and bundled engine resolve to the new version/commit.

**Step 2: Exercise local dictionary behavior**

In the installed app:

- add a vocabulary-only technical term;
- add a `heard as → write as` name correction;
- dictate short and long examples, including text after an existing sentence;
- edit/delete entries and confirm engine reload/output changes;
- import/export a vocabulary-only and mixed dictionary;
- verify Learned and Auto source rows remain manageable;
- disable network/iCloud availability and confirm local edits/dictation continue.

**Step 3: Exercise live iCloud behavior**

Prove:

- `iCloud Drive/Velora/Personal Dictionary/` is created;
- the cloud file contains the expected allow-listed entries and no private sentinel data;
- a simulated/second-device remote add merges;
- a remote deletion does not resurrect after local reconnect;
- corrupt remote content leaves the local dictionary working;
- sync status accurately reflects syncing, synced, unavailable, waiting, and account-change states.

**Step 4: Capture installed evidence**

Record version/build, process path, signed entitlements/profile identity, sync document path, sanitized payload keys, and observed test outcomes. Do not include the user's actual private names/terms in logs or the final report.

## Task 13: Merge and push the verified branch to main

Use `@superpowers:finishing-a-development-branch` only after `@superpowers:verification-before-completion` confirms fresh evidence for every required check.

**Step 1: Confirm branch cleanliness and upstream state**

```bash
git status --short --branch
git fetch origin
git log --oneline --decorate --max-count=12
```

Rebase/merge current `origin/main` only if needed, then rerun the full Swift/Python/signing verification on the exact resulting commit.

**Step 2: Merge to main without losing unrelated work**

From the primary clean checkout, merge `feature/personal-dictionary-icloud` into `main` with a normal non-destructive merge. Do not reset or overwrite unrelated user changes.

**Step 3: Push and prove remote truth**

```bash
git push origin main
git rev-parse main
git rev-parse origin/main
```

Expected: local `main`, `origin/main`, installed app source stamp, and the reported release commit agree.

**Step 4: Final handoff**

Report:

- what was already present versus newly added;
- the exact local/cloud privacy boundary;
- tests and live installed checks performed;
- version/build, release artifact, and pushed commit SHA;
- any remaining non-blocking limitation, stated plainly.
