#!/bin/zsh
# Builds Velora.app by hand from the SwiftPM binary (no Xcode).
#
# - Release build via swift build
# - Bundle layout: Velora.app/Contents/{MacOS,Resources}
# - Info.plist copied from Resources/Info.plist (authoritative for the bundle;
#   the binary also embeds a copy in __TEXT,__info_plist for bare-binary runs)
# - UI sounds (start/stop/error.caf) generated if missing and copied in
# - Ad-hoc codesign with the stable identifier com.velora.app so TCC grants
#   (Microphone, Accessibility) stick across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Velora"
APP="build/Velora.app"

# Ensure sounds exist (checked-in normally; regenerate when absent).
if [[ ! -f Resources/start.caf || ! -f Resources/stop.caf || ! -f Resources/error.caf ]]; then
  ./scripts/make-sounds.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Velora"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/start.caf Resources/stop.caf Resources/error.caf "$APP/Contents/Resources/"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign with a stable identifier. Note: the bundle Info.plist takes
# precedence over the binary's __info_plist section once inside a bundle.
codesign --force --deep --sign - --identifier com.velora.app "$APP"
codesign --verify --verbose=2 "$APP"

echo "OK: $APP"
