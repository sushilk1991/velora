#!/bin/zsh
# Builds the bundled engine the way a fresh install builds it, and fails the
# release when it can't. The app ships no .python-version, so uv picks the
# first Python it finds; 0.29.2 shipped while that Python (Homebrew 3.15)
# could not install mlx, and every new install restarted the engine forever.
#
#   Velora.app/Contents/Resources/engine ──copy──▶ $WORK/engine (no .venv)
#   bundled uv run --project $WORK/engine velora-engine --help
#     env: the supervisor's PATH, a reused wheel cache, no managed Pythons
#
# Usage: verify-engine-bootstrap.sh <path-to-Velora.app>
set -euo pipefail

# EngineSupervisor.spawnEngineProcess prepends these to the GUI app's PATH,
# which launchd starts as its default.
SUPERVISOR_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
LAUNCHD_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
USAGE_LINE="usage: velora-engine"

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: verify-engine-bootstrap.sh <path-to-Velora.app>" >&2
  exit 2
fi
APP="$(cd "$APP" && pwd)"
UV="$APP/Contents/Resources/bin/uv"
ENGINE="$APP/Contents/Resources/engine"
if [[ ! -x "$UV" || ! -f "$ENGINE/pyproject.toml" ]]; then
  echo "Velora.app lacks a bundled uv or engine: $APP" >&2
  exit 2
fi

# A warm wheel cache only skips downloads; it never changes which Python uv
# picks. Managed Pythons would, so their directory starts empty every run.
CACHE="${VELORA_BOOTSTRAP_UV_CACHE:-$HOME/Library/Caches/velora-release-uv}"
# Physical path: --project and the working directory name the same place,
# as they do for the supervisor.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/velora-engine-bootstrap.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# Copy the engine writable and without any venv, as ResourceLocator syncs it.
cp -R "$ENGINE" "$WORK/engine"
chmod -R u+w "$WORK/engine"
rm -rf "$WORK/engine/.venv"
mkdir -p "$WORK/python" "$CACHE"

# Nothing else from this shell reaches uv: a UV_PYTHON or VIRTUAL_ENV here
# would hide the interpreter a user's app actually gets.
echo "Building the bundled engine as a fresh install would..."
OUTPUT="$(cd "$WORK/engine" && env -i \
  HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" \
  PATH="$SUPERVISOR_PATH:$LAUNCHD_PATH" \
  UV_CACHE_DIR="$CACHE" UV_PYTHON_INSTALL_DIR="$WORK/python" \
  "$UV" run --project "$WORK/engine" velora-engine --help 2>&1)" && STATUS=0 || STATUS=$?

# uv exiting 0 is not enough: the engine entrypoint itself must have run.
if [[ "$STATUS" -ne 0 || "$OUTPUT" != *"$USAGE_LINE"* ]]; then
  printf '%s\n' "$OUTPUT" | tail -n 20 >&2
  echo "FAIL: the bundled engine does not build on this Mac's Python (uv exit $STATUS)" >&2
  exit 1
fi

PYTHON="$(sed -n 's/^version_info = //p' "$WORK/engine/.venv/pyvenv.cfg")"
echo "OK: bundled engine builds and starts on CPython $PYTHON"
