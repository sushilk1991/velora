#!/bin/zsh
# Publishes an already-built, verified DMG to BOTH places users get Velora:
#
#   1. A full GitHub release (the in-app updater reads /releases/latest,
#      so drafts and prereleases are invisible to it).
#   2. The Homebrew tap cask (brew install --cask sushilk1991/tap/velora),
#      whose URL 404s until the GitHub release asset exists — which is why
#      the GitHub release always goes first.
#
# A release is not done until both are live. This script is safe to re-run
# after a partial publish: it detects each already-completed stage and
# continues from the first missing one.
#
# Usage:
#   ./scripts/publish-release.sh             # publish VERSION everywhere
#   ./scripts/publish-release.sh --dry-run   # validate preconditions, print plan
#
# Environment seams (defaults are the real ones; overridden by tests):
#   VELORA_RELEASE_REPO   GitHub repo slug            (sushilk1991/velora)
#   VELORA_TAP_DIR        local tap clone             (~/Code/Github/homebrew-tap)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${VELORA_RELEASE_REPO:-sushilk1991/velora}"
TAP_DIR="${VELORA_TAP_DIR:-$HOME/Code/Github/homebrew-tap}"
CASK="$TAP_DIR/Casks/velora.rb"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ -n "${1:-}" ]]; then
  echo "ERROR: unknown argument '$1' (only --dry-run is supported)" >&2
  exit 1
fi

fail() { echo "ERROR: $1" >&2; exit 1; }
note() { echo "==> $1"; }

# --- preconditions (all local; a dry run stops after these) -----------------

VERSION="$(<VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION '$VERSION' is not MAJOR.MINOR.PATCH"
TAG="v$VERSION"
DMG="build/Velora-$VERSION.dmg"
NOTES="docs/releases/$TAG.md"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/Velora-$VERSION.dmg"

[[ -f "$DMG" ]] || fail "$DMG does not exist — build it first: ./scripts/make-dmg.sh"

[[ -f "$NOTES" ]] || fail "$NOTES does not exist — write the release notes first"
head -n 1 "$NOTES" | grep -q "^# Velora $VERSION$" \
  || fail "$NOTES must start with '# Velora $VERSION' (it becomes the release body)"

git diff --quiet -- VERSION && git diff --cached --quiet -- VERSION \
  || fail "VERSION has uncommitted changes — commit the release round first"

[[ -d "$TAP_DIR/.git" ]] || fail "tap clone not found at $TAP_DIR (clone sushilk1991/homebrew-tap)"
[[ -f "$CASK" ]] || fail "cask not found at $CASK"

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if (( DRY_RUN )); then
  note "dry run OK — would publish:"
  echo "    tag        $TAG (full release, target main)"
  echo "    asset      $DMG (sha256 $SHA256)"
  echo "    notes      $NOTES"
  echo "    updater    https://api.github.com/repos/$REPO/releases/latest"
  echo "    cask       $CASK -> version $VERSION"
  echo "    brew url   $DOWNLOAD_URL"
  exit 0
fi

# --- remote preconditions ---------------------------------------------------

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run: gh auth login)"

./scripts/verify-dmg.sh "$DMG"

git fetch --quiet origin main
[[ "$(git show origin/main:VERSION)" == "$VERSION" ]] \
  || fail "origin/main VERSION differs — push the release commit before publishing"

# --- stage 1: GitHub release ------------------------------------------------

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  REMOTE_DIGEST="$(gh release view "$TAG" --repo "$REPO" \
    --json assets --jq '.assets[] | select(.name == "Velora-'"$VERSION"'.dmg") | .digest' \
    2>/dev/null || true)"
  [[ "$REMOTE_DIGEST" == "sha256:$SHA256" ]] \
    || fail "release $TAG already exists with a different asset ($REMOTE_DIGEST vs sha256:$SHA256) — a version must never ship twice; bump instead"
  note "release $TAG already published with this exact DMG — continuing to the tap"
else
  note "creating GitHub release $TAG"
  gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --target main \
    --title "Velora $VERSION" \
    --notes-file "$NOTES"
fi

LATEST_TAG="$(gh api "repos/$REPO/releases/latest" --jq .tag_name)"
[[ "$LATEST_TAG" == "$TAG" ]] \
  || fail "/releases/latest serves $LATEST_TAG, not $TAG — the in-app updater will not see this release"

curl -fsIL -o /dev/null "$DOWNLOAD_URL" \
  || fail "release asset is not downloadable at $DOWNLOAD_URL"

# --- stage 2: Homebrew tap --------------------------------------------------

if grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA256\"" "$CASK"; then
  note "cask already at $VERSION with the matching sha256"
else
  git -C "$TAP_DIR" diff --quiet && git -C "$TAP_DIR" diff --cached --quiet \
    || fail "tap clone at $TAP_DIR has uncommitted changes — resolve them first"
  git -C "$TAP_DIR" pull --ff-only --quiet
  note "updating cask to $VERSION"
  sed -i '' -E "s|^  version \".*\"$|  version \"$VERSION\"|" "$CASK"
  sed -i '' -E "s|^  sha256 \".*\"$|  sha256 \"$SHA256\"|" "$CASK"
  grep -q "version \"$VERSION\"" "$CASK" || fail "cask version rewrite failed"
  grep -q "sha256 \"$SHA256\"" "$CASK" || fail "cask sha256 rewrite failed"
  git -C "$TAP_DIR" add "Casks/velora.rb"
  git -C "$TAP_DIR" commit --quiet -m "Update Velora to $VERSION"
fi

if [[ -n "$(git -C "$TAP_DIR" log origin/main..HEAD --oneline)" ]]; then
  git -C "$TAP_DIR" push --quiet origin main
  note "tap pushed"
fi

# --- done gate ---------------------------------------------------------------

note "published Velora $VERSION"
echo "    updater  sees $TAG at /releases/latest"
echo "    download $DOWNLOAD_URL"
echo "    brew     brew update && brew install --cask sushilk1991/tap/velora"
