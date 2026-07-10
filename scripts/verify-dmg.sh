#!/bin/zsh
# Verifies the trust chain a downloaded Velora DMG needs to pass Gatekeeper.
set -euo pipefail

DMG="${1:-}"
if [[ -z "$DMG" ]]; then
  echo "usage: verify-dmg.sh <path-to-Velora.dmg>" >&2
  exit 2
fi
[[ "$DMG" == /* ]] || DMG="$PWD/$DMG"
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
grep -q '^Timestamp=' <<< "$DMG_SIGNATURE"

echo "Verifying notarization ticket and Gatekeeper assessment..."
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/velora-dmg.XXXXXX")"
ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/velora-entitlements.XXXXXX")"
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  rm -f "$ENTITLEMENTS_FILE"
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
grep -q '^TeamIdentifier=' <<< "$APP_SIGNATURE"
grep -q 'flags=.*runtime' <<< "$APP_SIGNATURE"
grep -q '^Timestamp=' <<< "$APP_SIGNATURE"

codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS_FILE" 2>/dev/null
test -s "$ENTITLEMENTS_FILE"
plutil -lint "$ENTITLEMENTS_FILE" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_FILE")" == "true" ]]

spctl --assess --type execute --verbose=2 "$APP"

echo "OK: $DMG is Developer ID-signed, notarized, stapled, and Gatekeeper-approved"
