# Personal Dictionary and Private iCloud Sync Design

**Date:** 2026-07-11  
**Status:** Approved  
**Privacy choice:** Standard iCloud Drive protection; no iCloud Keychain dependency

## Goal

Let every Velora user teach the app both exact names/terms and explicit
“heard as → write as” corrections, then carry confirmed learning across their
Macs through a dedicated private iCloud Drive folder without syncing audio,
transcripts, history, or device-specific model state.

This closes a retention and learning-speed gap: once a user fixes a colleague,
company, product, acronym, or recurring mishearing, they should not have to fix
it again on this Mac or another Mac signed into the same Apple Account.

## What already exists

Velora already has most engine primitives, but not the complete product:

- `LearningStore` watches post-dictation edits, commits conservative hard or
  context-gated soft corrections, and adds corrected spellings to learned
  vocabulary.
- `AutoVocabStore` manages terms promoted by the engine's idle vocabulary
  miner.
- `config.json` and custom modes already support vocabulary and deterministic
  replacements.
- Whisper consumes global vocabulary as an initial-prompt glossary, and Qwen
  consumes vocabulary plus soft corrections in its cleanup prompt.
- Settings can list learned corrections and auto-learned terms and can import
  or export part of the learned store.

The missing pieces are a global manual editor, one coherent source-management
surface, correct import/export semantics, deletion-safe cross-Mac sync, and the
Developer ID/iCloud provisioning required to ship it.

## Product tenets

1. **Keep the simple case simple.** Entering `Airlearn` and pressing Return is
   enough. “When Velora hears” is optional complexity.
2. **Explicit user intent wins.** A manual term or replacement outranks an
   automatically learned spelling.
3. **Learning is reversible.** Every entry is visible and removable; deleting
   on one Mac must not let an old Mac resurrect it.
4. **Dictation remains local-first.** Local changes take effect immediately and
   continue working offline. iCloud sync is asynchronous.
5. **Sync only the dictionary.** Never infer that the rest of `~/.velora`
   belongs in iCloud.
6. **Tell the truth about privacy.** Velora sends no learning to a Velora
   server. The approved build uses the user's normal iCloud Drive protection;
   it does not claim app-level end-to-end encryption.

## User experience

### Dedicated Dictionary tab

Add a native `Dictionary` toolbar tab rather than expanding the already dense
Dictation form. The user's goal is apparent immediately: find, add, correct,
edit, or remove a word.

The main surface contains:

- a search field;
- an `Add` button;
- one compact list combining Added, Learned, and Auto-learned entries;
- source labels so automatic behavior is understandable;
- edit and delete actions;
- import/export actions; and
- an unobtrusive sync status footer.

The empty state says that names, product terms, acronyms, and recurring
mishearings can be taught here. It includes a single primary `Add a word`
action.

### Add and edit sheet

The form starts with one required field:

- **Write as** — the exact output, for example `Airlearn` or `Sushil Kumar`.

An optional disclosure reveals:

- **When Velora hears** — a recurring transcription, for example `air learn`.

With only **Write as**, the entry is a vocabulary term. It biases Whisper and
the cleanup model toward the exact spelling. With both fields, the written
value also becomes a deterministic manual replacement, so it works for short
utterances and Parakeet sessions that cannot consume a Whisper glossary.

The sheet explains that an explicit heard-as rule replaces every exact
word-boundary occurrence. Common-word heard forms receive a warning before
saving because a rule such as `lung → Airlearn` can change a legitimate use of
“lung.” Edit-learned real-word corrections remain soft/context-gated unless the
user explicitly converts one into a manual rule.

### Learning controls

The `Learn from my edits` and `Learn new words automatically` toggles remain in
Dictation settings. Their entry-management lists move to Dictionary so there
is one place to understand and control remembered language.

### Sync status

The Dictionary footer reports one of:

- `Synced with iCloud`;
- `Syncing…`;
- `Saved on this Mac — iCloud Drive is unavailable`;
- `Waiting for download…`; or
- an actionable conflict/account-change error.

No sync failure blocks dictation or local dictionary edits.

## Storage boundaries

### Local engine-facing stores

Keep the existing local files as the low-latency runtime projection:

- `~/.velora/config.json` — manual global vocabulary and manual replacements;
- `~/.velora/learned.json` — committed edit-learned hard/soft corrections and
  the local pending confirmation counts;
- `~/.velora/auto_learned.json` — device-local mining checkpoint/candidates,
  promoted terms, and bans.

The engine continues reading these files synchronously. It never waits for or
directly reads iCloud.

### Allow-listed sync document

The Swift app owns a versioned sync document containing only:

- manual vocabulary entries;
- manual heard-as replacement entries;
- committed edit-learned hard and soft corrections;
- promoted auto-learned vocabulary;
- user bans/deletions;
- per-entry revisions, deletion tombstones, and clear-all generations; and
- schema/merge metadata.

It explicitly excludes:

- raw or final transcripts;
- history rows or SQLite identifiers;
- audio paths or audio data;
- pending edit-observation counts;
- auto-miner candidates and transcript checkpoints;
- model choices, language, hotkeys, or other device preferences; and
- screen context.

Serialization tests assert that these forbidden field names and representative
private values cannot appear in the cloud payload.

### iCloud location

Use an app-specific iCloud Documents ubiquity container presented as:

`iCloud Drive/Velora/Personal Dictionary/`

The folder contains a versioned Velora dictionary document. Swift resolves the
container with `FileManager.url(forUbiquityContainerIdentifier:)` off the main
thread, uses `NSFileCoordinator` for reads/writes, requests downloads when
needed, and observes remote changes through an `NSMetadataQuery` or file
presenter.

The local dictionary remains authoritative for immediate interaction. The
cloud document is a synchronized replica and recovery source, not a runtime
dependency.

## Merge and conflict behavior

Every logical entry has a stable normalized key, source, value, revision,
modification date, and deletion state. A local pending-operation journal is
persisted before publishing to iCloud.

Merge rules:

1. Merge independent additions from both Macs.
2. For the same logical key, explicit manual data outranks learned/auto data.
3. A newer explicit edit wins over an older value.
4. Deletion wins over a concurrent update unless the user explicitly re-adds
   the entry after seeing the deletion.
5. Tombstones prevent a long-offline Mac from resurrecting removed entries.
6. `Forget all` increments a namespace generation so an old full snapshot
   cannot restore the cleared class.
7. Unresolved `NSFileVersion` conflicts are all decoded and merged before the
   coordinated winner is written and stale conflict versions are resolved.

An Apple Account identity change is a privacy boundary. Velora pauses cloud
sync and lets the user keep the local dictionary, replace it with the newly
signed-in account's dictionary, or explicitly merge. It never silently uploads
one account's local names into another account.

## Data validation and limits

- Trim and normalize whitespace.
- Deduplicate case-insensitively while preserving the user's chosen spelling.
- Reject empty values, newlines, control characters, and oversized entries.
- Limit a term or heard form to 60 characters.
- Bound total entries and serialized payload well below iCloud document and
  prompt limits.
- Preserve useful punctuation in technical terms such as `C++`, `node.js`,
  `auth_check`, hyphenated names, and apostrophes.
- Apply the same validation to manual input and imported dictionaries.

## Engine behavior and precedence

After every local or merged cloud change, Swift atomically projects the
effective state to the existing local stores and sends `reload_config`.

Precedence remains:

1. manual global replacement/vocabulary;
2. committed edit-learned correction/vocabulary;
3. auto-learned vocabulary; then
4. mode-specific and volatile screen context according to the existing prompt
   path.

Manual vocabulary reaches both the Whisper glossary and Qwen cleanup prompt.
Manual replacements run through the existing word-boundary deterministic path
for short and long utterances. Mode vocabulary remains mode-specific, but the
cleanup divergence allow-list must include the active mode's vocabulary so an
explicitly configured spelling is not rejected as novel output.

## Migration and existing bug fixes

Migration is idempotent and preserves:

- `config.json` manual vocabulary/replacements;
- standalone imported vocabulary in `learned.json`;
- learned hard/soft corrections and their safety tier; and
- promoted auto vocabulary plus bans, without copying miner checkpoints or
  candidates.

Related fixes included in this feature:

- `Forget learned corrections` must preserve manual/imported vocabulary.
- Vocabulary-only dictionaries remain visible, removable, and exportable.
- Import/export covers the complete portable dictionary but excludes pending
  counts and device-local mining state.
- Import rejects prompt-active malformed or unbounded strings.
- Auto-miner and Swift writes cannot overwrite each other's promoted terms or
  bans.

## Privacy and security

- The iCloud document belongs to the user's private Apple Account container.
- Velora has no dictionary server, analytics upload, or sharing endpoint.
- Standard iCloud Drive encryption is the approved initial protection level.
- Settings copy says `Synced privately through your iCloud Drive` and links to
  the exact folder; it does not say “end-to-end encrypted.”
- File permissions for all local projections remain owner-only.
- Corrupt, unsupported-newer, or partially downloaded cloud documents never
  replace a valid local dictionary; they surface an error and keep local
  dictation working.

## Signing and release boundary

The current Developer ID build has only the microphone entitlement and no
embedded Velora provisioning profile. Shipping requires:

1. enabling iCloud Documents for the explicit `com.sushil.velora` App ID;
2. creating the Velora iCloud container;
3. generating a Developer ID provisioning profile that authorizes it;
4. embedding the profile in `Contents/embedded.provisionprofile`;
5. signing the exact iCloud container/services entitlements;
6. declaring the ubiquity container display/document scope in `Info.plist`;
7. extending `make-app.sh` to fail closed when the release profile is missing;
8. extending `verify-dmg.sh` to decode and verify both signed entitlements and
   the embedded profile; and
9. retaining hardened runtime, Developer ID signing, notarization, stapling,
   and Gatekeeper verification.

A development build without an authorized profile falls back to local-only
dictionary behavior instead of failing to launch.

## Verification contract

The feature is not complete until all of the following pass:

1. Swift tests cover validation, CRUD, precedence, migration, serialization
   allow-list, add/add, update/update, add/delete, clear-all, long-offline
   rejoin, corrupt/newer schema, iCloud unavailable, and account change.
2. Python tests prove manual/learned/auto precedence, short-utterance manual
   replacements, global/mode vocabulary prompts, and divergence allow-listing.
3. Miner/write race tests cover both writer orderings.
4. Swift release build, all Swift selftests, and the full Python suite pass.
5. The release bundle contains the authorized profile and exact iCloud
   entitlements; notarization, stapling, and Gatekeeper assessment pass.
6. Installed-app testing proves add, edit, delete, import/export, local engine
   reload, offline fallback, iCloud folder creation, and remote-change merge.
7. The running `/Applications/Velora.app` and bundled engine resolve to the new
   build, with no transcript/audio files under the iCloud container.
8. An adversarial code/design/security review finds no unresolved blocker.
9. The verified feature branch is merged into `main`, the release commit is
   pushed to `origin/main`, and the installed version matches that commit.

## Out of scope

- Syncing transcripts, audio, history, modes, general settings, or models.
- Team/shared dictionaries.
- A Velora account or server.
- App-managed encryption for this initial standard-protection release.
- Mobile clients.
