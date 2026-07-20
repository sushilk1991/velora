# Portable settings plan

## Goal

A user can export Velora preferences as readable JSON, move that file to another Mac, import it safely, and see the imported preferences take effect without manually recreating their setup.

## Success criteria

1. `~/.velora/settings.json` is the durable source for every portable `AppConfig` preference and current known portable engine setting. Existing preferences migrate once without losing the speech model, default-mode/cleanup flags, streaming, recording-limit, or audio-retention choices.
2. The file has an explicit format identifier and schema version. Values are typed and human-readable. Writes are atomic and owner-only.
3. Settings → General exposes Export and Import. Exported JSON round-trips every portable preference.
4. The canonical document is portable by construction. Machine/security state and the RAM-dependent cleanup model never enter it.
5. Import validates the complete document before mutation, rejects malformed/newer versions, refuses to overwrite a newer canonical file during downgrade, warns about model downloads and tighter audio limits, preserves local state, keeps a temporary recovery copy, rolls back exact bytes if engine projection fails, and updates the running app.
6. `~/.velora/config.json` remains the engine projection. Dictionary keys and unknown future engine keys survive app writes.
7. History, recordings, dictionary data, macOS permissions, and custom mode files remain outside settings transfer and are named explicitly in the UI.

## Implementation

- Add a versioned Codable portable document with strict boundary validation; machine/security state stays in the macOS preferences domain.
- Move portable `AppConfig` getters/setters from `UserDefaults` to that document; keep a one-time migration reader.
- Mirror engine-facing settings into the existing engine config while preserving its machine-selected cleanup model and unknown keys.
- Add import/export panels, overwrite confirmation with model-download/retention warnings, inline result copy, and a single live refresh after commit.
- Cover round-trip, snake-case shape, hostile local-state injection, unknown fields, future versions, invalid ranges/shortcuts, non-Velora JSON, legacy migration, fail-closed engine projection, and rollback in the headless selftest.

## Verification

- `swift build`
- `.build/debug/Velora --selftest`
- `git diff --check`
- Independent read-only review focused on persistence races, security boundaries, migration loss, partial failure, and live side effects.
