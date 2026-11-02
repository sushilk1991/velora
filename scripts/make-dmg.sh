#!/bin/zsh
# Builds a distributable DMG: Developer ID-signed, hardened Velora.app inside
# a signed, notarized, and stapled compressed UDZO image.
# Output: build/Velora-<CFBundleShortVersionString>.dmg, plus
# build/Velora-<version>.dSYM.zip with the symbols of its stripped executable.
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
DSYM="build/Velora.app.dSYM"
DSYM_ZIP="build/Velora-$VERSION.dSYM.zip"
PENDING_DSYM_ZIP="build/.Velora-$VERSION.dSYM.pending.zip"
STAGING="build/dmg-staging"
# Refuse before any cleanup can run: a published DMG may sit beside the
# pending symbols an interrupted run left for a manual rename.
for artifact in "$DMG" "$DSYM_ZIP"; do
  if [[ -e "$artifact" ]]; then
    echo "ERROR: refusing to overwrite existing release artifact $artifact" >&2
    exit 1
  fi
done
PUBLISHED=0
cleanup() {
  rm -rf "$STAGING"
  [[ "$PUBLISHED" == "1" ]] || rm -f "$PENDING_DMG" "$PENDING_DSYM_ZIP"
}
trap cleanup EXIT

rm -rf "$STAGING"
rm -f "$PENDING_DMG" "$PENDING_DSYM_ZIP"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# The shipped executable is stripped: a user's crash report carries only
# addresses and this build's UUID, and this archive is what names them. Take
# it now, beside the staged copy, so a rebuild during notarization cannot
# swap in another build's symbols.
STAGED_UUID="$(dwarfdump --uuid "$STAGING/Velora.app/Contents/MacOS/Velora" | awk '{print $2}')"
if [[ -z "$STAGED_UUID" || "$(dwarfdump --uuid "$DSYM" | awk '{print $2}')" != "$STAGED_UUID" ]]; then
  echo "ERROR: $DSYM does not match the staged executable ($STAGED_UUID)" >&2
  exit 1
fi
ditto -c -k --keepParent "$DSYM" "$PENDING_DSYM_ZIP"

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

# The DMG goes first: once it exists the version is spent, so the pending
# symbols are kept for a manual rename rather than cleaned up.
mv "$PENDING_DMG" "$DMG"
PUBLISHED=1
mv "$PENDING_DSYM_ZIP" "$DSYM_ZIP"
echo "OK: $DMG"
echo "OK: $DSYM_ZIP (private: archive it in ~/Library/Developer/Velora/dSYMs, never publish it)"
