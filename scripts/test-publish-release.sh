#!/bin/zsh
# Deterministic checks for publish-release.sh — the dry-run plan and every
# local precondition it promises to enforce. No network, no real artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/publish-release.sh"
SCRATCH="$(mktemp -d /tmp/velora-publish-test.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

FAILURES=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAIL: $name" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# --- a minimal fake project the script accepts ------------------------------

PROJECT="$SCRATCH/project"
mkdir -p "$PROJECT/scripts" "$PROJECT/build" "$PROJECT/docs/releases"
cp "$SCRIPT" "$PROJECT/scripts/publish-release.sh"
printf '9.9.9' > "$PROJECT/VERSION"
printf '# Velora 9.9.9\n\nTest notes.\n' > "$PROJECT/docs/releases/v9.9.9.md"
head -c 4096 /dev/urandom > "$PROJECT/build/Velora-9.9.9.dmg"
git -C "$PROJECT" init --quiet
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit --quiet -m init

TAP="$SCRATCH/tap"
mkdir -p "$TAP/Casks"
printf 'cask "velora" do\n  version "9.9.8"\n  sha256 "old"\nend\n' > "$TAP/Casks/velora.rb"
git -C "$TAP" init --quiet
git -C "$TAP" -c user.email=t@t -c user.name=t add -A
git -C "$TAP" -c user.email=t@t -c user.name=t commit --quiet -m init

run() { (cd "$PROJECT" && VELORA_TAP_DIR="$TAP" zsh scripts/publish-release.sh "$@") }

# --- the happy dry run ------------------------------------------------------

OUT="$(run --dry-run)"
check "dry run passes with a complete release round" test $? -eq 0
check "dry run names the tag" grep -q "tag        v9.9.9" <<< "$OUT"
EXPECTED_SHA="$(shasum -a 256 "$PROJECT/build/Velora-9.9.9.dmg" | cut -d' ' -f1)"
check "dry run computes the DMG sha256" grep -q "$EXPECTED_SHA" <<< "$OUT"
check "dry run points at the cask" grep -q "Casks/velora.rb" <<< "$OUT"
check "dry run states the updater feed" grep -q "releases/latest" <<< "$OUT"

# --- every local precondition fails closed ----------------------------------

mv "$PROJECT/build/Velora-9.9.9.dmg" "$PROJECT/build/away.dmg"
if run --dry-run >/dev/null 2>&1; then
  echo "FAIL: missing DMG must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: missing DMG is refused"
fi
mv "$PROJECT/build/away.dmg" "$PROJECT/build/Velora-9.9.9.dmg"

printf '# Velora 9.9.8\n\nWrong headline.\n' > "$PROJECT/docs/releases/v9.9.9.md"
if run --dry-run >/dev/null 2>&1; then
  echo "FAIL: notes for the wrong version must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: notes for the wrong version are refused"
fi
printf '# Velora 9.9.9\n\nTest notes.\n' > "$PROJECT/docs/releases/v9.9.9.md"

printf '9.9.10-dirty' > "$PROJECT/VERSION"
if run --dry-run >/dev/null 2>&1; then
  echo "FAIL: a malformed VERSION must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: a malformed VERSION is refused"
fi
git -C "$PROJECT" checkout --quiet -- VERSION

printf '9.9.9' > "$PROJECT/VERSION.tmp" && printf '8.8.8' > "$PROJECT/VERSION"
if run --dry-run >/dev/null 2>&1; then
  echo "FAIL: an uncommitted VERSION must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: an uncommitted VERSION is refused"
fi
git -C "$PROJECT" checkout --quiet -- VERSION && rm "$PROJECT/VERSION.tmp"

if VELORA_TAP_DIR="$SCRATCH/no-such-tap" \
  sh -c "cd '$PROJECT' && zsh scripts/publish-release.sh --dry-run" >/dev/null 2>&1; then
  echo "FAIL: a missing tap clone must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: a missing tap clone is refused"
fi

if run --publish-everything >/dev/null 2>&1; then
  echo "FAIL: unknown arguments must be refused" >&2; FAILURES=$((FAILURES + 1))
else
  echo "ok: unknown arguments are refused"
fi

# --- the real repo's own dry-run wiring -------------------------------------

grep -q 'releases/latest' scripts/publish-release.sh \
  || { echo "FAIL: the script must document the updater feed" >&2; FAILURES=$((FAILURES + 1)); }
grep -q -- '--target main' scripts/publish-release.sh \
  || { echo "FAIL: releases must target main" >&2; FAILURES=$((FAILURES + 1)); }
grep -q -- '--notes-file' scripts/publish-release.sh \
  || { echo "FAIL: release notes must come from docs/releases" >&2; FAILURES=$((FAILURES + 1)); }
if grep -qE -- '--draft|--prerelease' scripts/publish-release.sh; then
  echo "FAIL: the updater cannot see drafts or prereleases" >&2; FAILURES=$((FAILURES + 1))
fi

if (( FAILURES )); then
  echo "publish-release checks FAILED ($FAILURES)" >&2
  exit 1
fi
echo "publish-release checks OK"
