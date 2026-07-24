#!/bin/zsh
# Verifies the trust chain a downloaded Velora DMG needs to pass Gatekeeper.
set -euo pipefail
CALLER_PWD="$PWD"
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_ROOT/scripts/signing-config.sh"

DMG="${1:-}"
if [[ -z "$DMG" ]]; then
  echo "usage: verify-dmg.sh <path-to-Velora.dmg>" >&2
  exit 2
fi
[[ "$DMG" == /* ]] || DMG="$CALLER_PWD/$DMG"
if [[ ! -f "$DMG" ]]; then
  echo "DMG not found: $DMG" >&2
  exit 2
fi
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"

echo "Verifying disk image integrity and signature..."
hdiutil verify "$DMG" >/dev/null
codesign --verify --strict --verbose=2 "$DMG"

DMG_SIGNATURE="$(codesign -dvvv --verbose=4 "$DMG" 2>&1)"
grep -q '^Authority=Developer ID Application:' <<< "$DMG_SIGNATURE"
validate_signature_team_value "$(sed -n 's/^TeamIdentifier=//p' <<< "$DMG_SIGNATURE" | head -n 1)"
grep -q '^Timestamp=' <<< "$DMG_SIGNATURE"

echo "Verifying notarization ticket and Gatekeeper assessment..."
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/velora-dmg.XXXXXX")"
ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/velora-entitlements.XXXXXX")"
PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/velora-profile.XXXXXX")"
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  rm -f "$ENTITLEMENTS_FILE" "$PROFILE_PLIST"
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
APP="$MOUNT_POINT/Velora.app"
if [[ ! -d "$APP" ]]; then
  echo "Velora.app is missing from $DMG" >&2
  exit 1
fi

echo "Verifying bundled app signature and hardened runtime..."
codesign --verify --deep --strict --verbose=2 "$APP"
APP_SIGNATURE="$(codesign -dvvv --verbose=4 "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application:' <<< "$APP_SIGNATURE"
validate_signed_app_team "$APP"
grep -q 'flags=.*runtime' <<< "$APP_SIGNATURE"
grep -q '^Timestamp=' <<< "$APP_SIGNATURE"

codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS_FILE" 2>/dev/null
test -s "$ENTITLEMENTS_FILE"
plutil -lint "$ENTITLEMENTS_FILE" >/dev/null

EMBEDDED_PROFILE="$APP/Contents/embedded.provisionprofile"
if [[ ! -f "$EMBEDDED_PROFILE" ]]; then
  echo "Velora.app is missing Contents/embedded.provisionprofile" >&2
  exit 1
fi
security cms -D -i "$EMBEDDED_PROFILE" > "$PROFILE_PLIST" 2>/dev/null
validate_signing_plists "$ENTITLEMENTS_FILE" "$PROFILE_PLIST" "$APP/Contents/Info.plist"

echo "Verifying bundled offline runtime and command surfaces..."
UV="$APP/Contents/Resources/bin/uv"
CLI="$APP/Contents/Resources/bin/velora"
ENGINE="$APP/Contents/Resources/engine"
test -x "$UV"
test -x "$CLI"
test -f "$ENGINE/pyproject.toml"
test -f "$ENGINE/uv.lock"
test -s "$ENGINE/.velora-build"
test -f "$ENGINE/src/velora_engine/server.py"
test -f "$ENGINE/src/velora_engine/cleanup_process.py"
test -f "$ENGINE/src/velora_engine/cleanup_worker.py"
codesign --verify --strict --verbose=2 "$UV"
"$UV" --version >/dev/null
"$CLI" --help >/dev/null
PROBE_PYTHON="$("$UV" python find 3.12)"
PYTHONPATH="$ENGINE/src" "$PROBE_PYTHON" -c \
  'import asyncio; from velora_engine.cleanup_process import CleanupProcess; asyncio.run(CleanupProcess("probe").probe_async())'
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
MCP_METADATA="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | "$CLI" mcp)"
if [[ "$MCP_METADATA" != *'"version":"'"$APP_VERSION"'"'* ]]; then
  echo "bundled MCP version does not match app version $APP_VERSION" >&2
  exit 1
fi

spctl --assess --type execute --verbose=2 "$APP"

echo "OK: $DMG is complete, provisioned for iCloud, Developer ID-signed, notarized, stapled, and Gatekeeper-approved"
