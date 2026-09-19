---
name: release
description: Cut and publish a Velora release end to end — version bump, signed app, notarized DMG, GitHub release, AND Homebrew tap. Use whenever the user says release, ship a build, cut a version, publish, new DMG, or update Homebrew. A release is not done until BOTH GitHub and the tap serve the new version.
---

# Release Velora

The release procedure lives in exactly one place: **`docs/RELEASING.md`**.
Read it and follow its "Step by step" list in order — prerequisites, the
PR-first sequence (bump and notes on a branch, merge, build from `main`,
publish), troubleshooting, and rationale are all there. Do not reconstruct
the steps from memory or from this file.

**The invariant you exist to enforce:** every release ships to **both** the
GitHub release feed (the in-app updater reads `/releases/latest`) and the
Homebrew tap. Never stop after the DMG or the GitHub release — a "release"
that skipped the tap (or vice versa) is a bug, not a partial success.

## Judgment calls the step list does not make for you

- **Bump level.** Owner's rule of thumb: `patch` for little fixes (default),
  `minor` for a notable feature round, `major` for a genuinely
  better/rewritten build. If the session's work obviously matches one,
  proceed; ask only when it is genuinely ambiguous.
- **Notes voice.** Read the two most recent `docs/releases/` files before
  writing the new one and match them.
- **Done gate report.** After the checks in RELEASING.md pass, report with
  evidence: the tag, the DMG sha256, the tap commit, and anything skipped.

## Failure rules

- Any stage fails → stop, read the actual error (`build/notarytool-*-log.json`
  for notarization), fix, and re-run `publish-release.sh` — never hand-edit
  the tap to "catch up" without the GitHub release existing first.
- Never delete or replace a published release asset; wrong bytes → new patch
  version.
- Do not fold unrelated uncommitted work into the `Release Velora X.Y.Z`
  commit.
