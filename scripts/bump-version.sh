#!/bin/zsh
# Bumps the semver in the repo-root VERSION file (the single source of truth for
# the app version). make-app.sh calls this on every build so a new build never
# ships the same version twice.
#
#   ./scripts/bump-version.sh            # patch: 0.1.0 -> 0.1.1  (default)
#   ./scripts/bump-version.sh patch      # small fixes / rebuilds
#   ./scripts/bump-version.sh minor      # notable new features:  0.1.4 -> 0.2.0
#   ./scripts/bump-version.sh major      # big / breaking release: 0.9.x -> 1.0.0
#   ./scripts/bump-version.sh none       # print current, don't change
#
# Prints the resulting version to stdout (and nothing else) so callers can
# capture it: NEW=$(scripts/bump-version.sh minor)
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL="${1:-patch}"
CUR="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.0.0)"
IFS=. read -r MAJ MIN PAT <<< "$CUR"
: "${MAJ:=0}" "${MIN:=0}" "${PAT:=0}"

case "$LEVEL" in
  major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
  minor) MIN=$((MIN + 1)); PAT=0 ;;
  patch) PAT=$((PAT + 1)) ;;
  none)  ;;
  *) echo "usage: bump-version.sh [major|minor|patch|none]" >&2; exit 1 ;;
esac

NEW="$MAJ.$MIN.$PAT"
printf '%s\n' "$NEW" > VERSION
printf '%s\n' "$NEW"
