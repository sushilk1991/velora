#!/bin/zsh
# Deterministic checks for verify-engine-bootstrap.sh: a fake Velora.app whose
# bundled uv is a stub that records how it was run. No network, no real venv.
#
# The rule under test: a release is rejected unless its bundled engine builds
# the way a fresh install builds it (0.29.2 shipped while Homebrew's Python
# 3.15 could not install mlx, and every new install restarted the engine forever).
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/verify-engine-bootstrap.sh"
SCRATCH="$(mktemp -d /tmp/velora-bootstrap-test.XXXXXX)"
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

# --- a fake app: bundled engine plus a uv stub ------------------------------
#
# The stub logs its arguments, working directory and environment next to
# itself, then acts on STUB_MODE in the engine copy it runs in:
#   ok     builds .venv on CPython 3.14.7 and prints the engine's usage
#   fail   prints uv's real cp315 error and exits 2
#   silent exits 0 without running the engine entrypoint

APP="$SCRATCH/Velora.app"
ENGINE="$APP/Contents/Resources/engine"
UV_LOG="$APP/Contents/Resources/bin/uv.log"
mkdir -p "$ENGINE/.venv" "$APP/Contents/Resources/bin"
printf '[project]\nname = "velora-engine"\n' > "$ENGINE/pyproject.toml"
printf 'stale' > "$ENGINE/.venv/marker"
# -f: the stub must not source ~/.zshenv, which would edit the PATH it logs.
cat > "$APP/Contents/Resources/bin/uv" <<'EOF'
#!/bin/zsh -f
{
  print -r -- "args=$*"
  print -r -- "pwd=$PWD"
  print -r -- "PATH=$PATH"
  print -r -- "UV_CACHE_DIR=${UV_CACHE_DIR-unset}"
  print -r -- "UV_PYTHON_INSTALL_DIR=${UV_PYTHON_INSTALL_DIR-unset}"
  print -r -- "UV_PYTHON=${UV_PYTHON-unset}"
  print -r -- "venv_before=$([[ -e .venv ]] && echo yes || echo no)"
  print -r -- "python_entries=$(ls -A "${UV_PYTHON_INSTALL_DIR:-/nonexistent}" 2>/dev/null | wc -l | tr -d ' ')"
} > "${0:A:h}/uv.log"
case "$(cat STUB_MODE)" in
  fail)
    echo "error: Distribution \`mlx==0.31.2\` can't be installed because it doesn't have a source distribution or wheel for the current platform" >&2
    exit 2 ;;
  silent)
    exit 0 ;;
esac
mkdir -p .venv
print 'version_info = 3.14.7' > .venv/pyvenv.cfg
echo "usage: velora-engine [-h] [--socket SOCKET]"
EOF
chmod +x "$APP/Contents/Resources/bin/uv"

logged() { sed -n "s/^$1=//p" "$UV_LOG" 2>/dev/null || true; }
run() {
  printf '%s' "$1" > "$ENGINE/STUB_MODE"
  rm -f "$UV_LOG"
  # A caller's UV_PYTHON must not decide the interpreter: the app never has one.
  UV_PYTHON=3.15 VELORA_BOOTSTRAP_UV_CACHE="$SCRATCH/cache" zsh "$SCRIPT" "$APP"
}

# --- a bundle that builds passes, the way the supervisor spawns it ----------

OUT="$(run ok 2>&1)" && STATUS=0 || STATUS=$?
WORK="$(logged pwd)"
check "a buildable engine passes" test "$STATUS" -eq 0
check "the chosen Python is reported" grep -q "CPython 3.14.7" <<< "$OUT"
check "uv runs the engine entrypoint from a copy" \
  test "$(logged args)" = "run --project $WORK velora-engine --help"
check "the copy is not the bundle" test "$WORK" != "$ENGINE"
check "the bundle's .venv is not carried into the copy" test "$(logged venv_before)" = "no"
check "PATH is the supervisor's, ahead of launchd's default" \
  test "$(logged PATH)" = "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
check "the release wheel cache is used" test "$(logged UV_CACHE_DIR)" = "$SCRATCH/cache"
check "managed Pythons start empty, like a new user's" test "$(logged python_entries)" = "0"
check "managed Pythons are not kept in the wheel cache" \
  test "$(logged UV_PYTHON_INSTALL_DIR)" != "$SCRATCH/cache"
check "the caller's UV_PYTHON does not leak" test "$(logged UV_PYTHON)" = "unset"
check "the copy is removed after a pass" test ! -e "$WORK"
check "the bundle is left untouched" test -e "$ENGINE/.venv/marker" -a ! -e "$ENGINE/.venv/pyvenv.cfg"

# --- an engine uv cannot install fails closed with uv's own error -----------

OUT="$(run fail 2>&1)" && STATUS=0 || STATUS=$?
check "an uninstallable engine fails the release" test "$STATUS" -ne 0
check "uv's error is shown" grep -q 'mlx==0.31.2' <<< "$OUT"
check "the copy is removed after a failure" test ! -e "$(logged pwd)"

# --- uv exiting 0 without starting the engine is not a pass -----------------

OUT="$(run silent 2>&1)" && STATUS=0 || STATUS=$?
check "an engine that never printed its usage fails" test "$STATUS" -ne 0

# --- the release gate runs it on every DMG -----------------------------------

check "verify-dmg.sh runs the bootstrap check" \
  grep -Fq './scripts/verify-engine-bootstrap.sh "$APP"' scripts/verify-dmg.sh

if [[ "$FAILURES" -ne 0 ]]; then
  echo "$FAILURES engine bootstrap check(s) failed" >&2
  exit 1
fi
echo "engine bootstrap checks OK"
