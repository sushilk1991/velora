#!/bin/zsh
# Builds a distributable DMG: Developer ID-signed, hardened Velora.app inside
# a signed, notarized, and stapled compressed UDZO image.
# Output: build/Velora-<CFBundleShortVersionString>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# 2nd arg = version bump level, forwarded to make-app.sh. Defaults to "none":
# a DMG packages an already-decided version, so it shouldn't bump on its own
# (bump when you build the app; pass e.g. `make-dmg.sh release minor` to do both).
BUMP="${2:-none}"

NOTARY_PROFILE="${VELORA_NOTARY_PROFILE:-velora-notary}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: no valid notarytool credentials for profile '$NOTARY_PROFILE'" >&2
  echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id JZFVKGDPU4" >&2
  exit 1
fi

VELORA_DISTRIBUTION=1 ./scripts/make-app.sh "$CONFIG" "$BUMP"

APP="build/Velora.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Velora-$VERSION.dmg"
PENDING_DMG="build/.Velora-$VERSION.pending.dmg"
STAGING="build/dmg-staging"
PUBLISHED=0
cleanup() {
  rm -rf "$STAGING"
  [[ "$PUBLISHED" == "1" ]] || rm -f "$PENDING_DMG"
}
trap cleanup EXIT

rm -rf "$STAGING"
rm -f "$PENDING_DMG"
if [[ -e "$DMG" ]]; then
  echo "ERROR: refusing to overwrite existing release artifact $DMG" >&2
  exit 1
fi
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname Velora -srcfolder "$STAGING" -ov -format UDZO "$PENDING_DMG"

IDENTITY="${DEVELOPER_ID_APPLICATION:-$(
  codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1
)}"
if [[ -z "$IDENTITY" ]]; then
  echo "ERROR: could not read the Developer ID Application identity from $APP" >&2
  exit 1
fi
codesign --force --sign "$IDENTITY" --timestamp "$PENDING_DMG"
codesign --verify --strict --verbose=2 "$PENDING_DMG"

NOTARY_RESULT="build/notarytool-$VERSION-result.plist"
NOTARY_LOG="build/notarytool-$VERSION-log.json"
rm -f "$NOTARY_RESULT" "$NOTARY_LOG"
SUBMIT_RC=0
xcrun notarytool submit "$PENDING_DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format plist > "$NOTARY_RESULT" || SUBMIT_RC=$?
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || echo Unknown)"
if [[ -n "$SUBMISSION_ID" ]]; then
  if ! xcrun notarytool log "$SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" "$NOTARY_LOG"; then
    echo "WARNING: could not fetch the notarization log for $SUBMISSION_ID" >&2
  fi
fi
if (( SUBMIT_RC != 0 )) || [[ "$STATUS" != "Accepted" ]]; then
  echo "ERROR: Apple notarization status was '$STATUS'; see $NOTARY_LOG" >&2
  exit 1
fi

xcrun stapler staple "$PENDING_DMG"
xcrun stapler validate "$PENDING_DMG"
./scripts/verify-dmg.sh "$PENDING_DMG"

mv "$PENDING_DMG" "$DMG"
PUBLISHED=1
echo "OK: $DMG"
