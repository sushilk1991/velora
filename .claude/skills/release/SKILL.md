---
name: release
description: Cut and publish a Velora release end to end — version bump, signed app, notarized DMG, GitHub release, AND Homebrew tap. Use whenever the user says release, ship a build, cut a version, publish, new DMG, or update Homebrew. A release is not done until BOTH GitHub and the tap serve the new version.
---

# Release Velora

Deep reference: `docs/RELEASING.md`. This skill is the operating order; that
document has prerequisites, troubleshooting, and rationale.

**The invariant you exist to enforce:** every release ships to **both** the
GitHub release feed (the in-app updater reads `/releases/latest`) and the
Homebrew tap. Never stop after the DMG or the GitHub release — a "release"
that skipped the tap (or vice versa) is a bug, not a partial success.

## Operating order

1. **Preflight.** Working tree state understood (unrelated dirty files stay
   out of the release commit). `make test` is green — do not release on red.
   Confirm `VELORA_PROVISIONING_PROFILE` is exported and points at the
   **"Mac Team Direct Provisioning Profile: com.sushil.velora"** (discovery
   loop in docs/RELEASING.md); confirm the tap clone exists at
   `~/Code/Github/homebrew-tap`.

2. **Decide the bump** with the owner's rule of thumb: `patch` for little
   fixes (default), `minor` for a notable feature round, `major` for a
   genuinely better/rewritten build. If the session's work obviously matches
   one, proceed; ask only when it is genuinely ambiguous.

3. **Write the notes** at `docs/releases/vX.Y.Z.md` for the post-bump
   version, matching the established voice (read the two most recent files
   first): first line `# Velora X.Y.Z`, a one-sentence user-facing headline,
   then short bullets about what users will notice. No internals, no
   engineering credits. This file becomes the GitHub release body verbatim.

4. **Build:** `./scripts/make-dmg.sh release [patch|minor|major]` →
   signed, notarized, stapled, verified `build/Velora-X.Y.Z.dmg`.
   It refuses to overwrite an existing DMG: a version never ships twice —
   if the artifact is wrong, bump again.

5. **Commit the round:** `git add VERSION docs/releases/vX.Y.Z.md` (plus any
   release-round files), commit `release: prepare Velora X.Y.Z`, push to
   `main`. The publish script refuses to run if VERSION isn't on
   `origin/main`.

6. **Publish both targets:**
   `./scripts/publish-release.sh --dry-run` to see the plan, then
   `./scripts/publish-release.sh`. It creates the full GitHub release
   (never draft/prerelease), verifies `/releases/latest` and the asset URL,
   then bumps `Casks/velora.rb` (version + sha256) and pushes the tap.
   Safe to re-run after any partial failure — it continues from the first
   missing stage.

7. **Done gate — verify live state, then report with evidence:**
   - `gh api repos/sushilk1991/velora/releases/latest --jq .tag_name` → the new tag
   - `curl -fsIL` on the cask's download URL → 200
   - `brew update && brew fetch --cask sushilk1991/tap/velora` → new version,
     checksum accepted
   Report the tag, the DMG sha256, the tap commit, and anything skipped.

## Failure rules

- Any stage fails → stop, read the actual error (`build/notarytool-*-log.json`
  for notarization), fix, and re-run `publish-release.sh` — never hand-edit
  the tap to "catch up" without the GitHub release existing first.
- Never delete or replace a published release asset; wrong bytes → new patch
  version.
- Do not fold unrelated uncommitted work into the release commit.
