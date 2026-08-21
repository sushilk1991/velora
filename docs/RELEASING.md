# Releasing Velora

The one rule: **a release is not done until the DMG is live in BOTH places
users get Velora** — the GitHub release (the in-app updater polls
`api.github.com/repos/sushilk1991/velora/releases/latest`) and the Homebrew
tap (`brew install --cask sushilk1991/tap/velora`, whose cask URL points at
the GitHub release asset). Shipping one without the other leaves either the
updater or `brew` serving a stale or broken version.

There is a project skill for this: ask the agent to "release" (or invoke
`/release`) and it follows this document end to end. The publish tail is
automated by `scripts/publish-release.sh`.

## The pipeline

```
VERSION bump ─▶ signed app ─▶ notarized DMG ─▶ GitHub release ─▶ Homebrew tap
   make-app.sh      │        make-dmg.sh          └── publish-release.sh ──┘
                    └─ verify-dmg.sh (run again by publish-release.sh)
```

## Prerequisites (once per machine)

- **Developer ID Application** identity in the keychain (team `JZFVKGDPU4`).
  For a new machine, see the signing kit notes (`scripts/make-signing-cert.sh`
  is only the *development* cert; distribution needs the real Developer ID).
- **Notary credentials** stored as the `velora-notary` keychain profile:
  `xcrun notarytool store-credentials velora-notary --apple-id <id> --team-id JZFVKGDPU4`
- **Provisioning profile** — iCloud entitlements make distribution builds fail
  closed without one. Use **"Mac Team Direct Provisioning Profile:
  com.sushil.velora"** (Developer ID, no ProvisionedDevices, expires 2044) —
  *not* the plain development "Mac Team Provisioning Profile". Find it:

  ```sh
  for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
    printf '%s → ' "$p"; security cms -D -i "$p" | plutil -extract Name raw -
  done
  export VELORA_PROVISIONING_PROFILE="<the Direct profile's path>"
  ```

- **Tap clone** at `~/Code/Github/homebrew-tap`
  (`git clone https://github.com/sushilk1991/homebrew-tap`); override with
  `VELORA_TAP_DIR` if it lives elsewhere.
- **`gh` authenticated** for `sushilk1991/velora`.

## Step by step

1. **Green tests.** `make test` — plus the manual permission-gated checks in
   CONTRIBUTING.md when the round touched them.

2. **Release notes.** Write `docs/releases/vX.Y.Z.md` for the version you are
   *about to create* (see the bump table in CLAUDE.md: patch by default,
   `minor`/`major` for bigger rounds). First line must be `# Velora X.Y.Z` —
   the file becomes the GitHub release body verbatim, and users read it in
   the in-app updater. Keep it in the established voice: one-sentence
   headline, then short user-facing bullets. No internals.

3. **Build the DMG** (this performs the version bump):

   ```sh
   export VELORA_PROVISIONING_PROFILE="<Direct profile path>"
   ./scripts/make-dmg.sh release [patch|minor|major]
   ```

   Output: `build/Velora-X.Y.Z.dmg` — signed, notarized, stapled, and already
   passed `verify-dmg.sh`. The script refuses to overwrite an existing DMG:
   **a version never ships twice** — if the artifact is wrong, bump again.

4. **Commit the release round** (VERSION bump + notes) and push:

   ```sh
   git add VERSION docs/releases/vX.Y.Z.md
   git commit -m "release: prepare Velora X.Y.Z"
   git push origin main
   ```

5. **Publish everywhere:**

   ```sh
   ./scripts/publish-release.sh --dry-run   # sanity-check the plan
   ./scripts/publish-release.sh
   ```

   This creates the full GitHub release (tag `vX.Y.Z`, title `Velora X.Y.Z`,
   body from the notes file, asset `Velora-X.Y.Z.dmg`, target `main` — never
   draft or prerelease, which the updater cannot see), verifies
   `/releases/latest` now serves the new tag and the asset URL downloads,
   then bumps `Casks/velora.rb` (version + sha256), commits
   `Update Velora to X.Y.Z`, and pushes the tap. It is safe to re-run after a
   partial publish — each completed stage is detected and skipped.

6. **Done gate** (publish-release.sh checks the first two; eyeball the third):

   - `gh api repos/sushilk1991/velora/releases/latest --jq .tag_name` → `vX.Y.Z`
   - the cask download URL returns 200
   - `brew update && brew fetch --cask sushilk1991/tap/velora` pulls the new
     version with a matching checksum

## Troubleshooting

- **`distribution builds require VELORA_PROVISIONING_PROFILE`** — export the
  Direct profile path (see prerequisites; the UUID filename changes when the
  profile is regenerated, so search by name).
- **`no valid notarytool credentials`** — re-store the `velora-notary`
  profile; app-specific passwords expire when the Apple ID password changes.
- **Notarization `Invalid`** — read `build/notarytool-<version>-log.json`;
  every issue names the offending file.
- **Release exists with a different asset** — that version already shipped
  with different bytes. Never replace it: bump the version and release again.
- **Tap pushed before the GitHub release** (broken `brew install`) — run
  `publish-release.sh`; it creates the missing release, verifies the URL, and
  leaves the tap as-is once the sha matches.

## Why it's shaped this way

- The updater trusts `/releases/latest`, so a draft, prerelease, or missing
  release silently strands every installed copy on the old version.
- The cask URL embeds the release asset, so the tap must always publish
  *after* the GitHub release, with the sha256 of the exact shipped DMG.
- `make-dmg.sh` fails closed at every stage (identity, profile, notarization,
  verification) rather than producing a DMG that downloaded users cannot open.
- `scripts/test-publish-release.sh` (part of `make test`) pins the publish
  script's preconditions and plan so this document and the automation cannot
  silently drift apart.
