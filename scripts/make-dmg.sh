#!/bin/zsh
# Builds a distributable DMG: make-app.sh (self-contained Velora.app), then
# a compressed UDZO image containing the app + an /Applications symlink.
# Output: build/Velora-<CFBundleShortVersionString>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# 2nd arg = version bump level, forwarded to make-app.sh. Defaults to "none":
# a DMG packages an already-decided version, so it shouldn't bump on its own
# (bump when you build the app; pass e.g. `make-dmg.sh release minor` to do both).
BUMP="${2:-none}"
./scripts/make-app.sh "$CONFIG" "$BUMP"

APP="build/Velora.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Velora-$VERSION.dmg"
STAGING="build/dmg-staging"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname Velora -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "OK: $DMG"
