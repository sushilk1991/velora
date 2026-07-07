#!/bin/zsh
# Builds Velora.app by hand from the SwiftPM binary (no Xcode).
#
# - Release build via swift build
# - Bundle layout: Velora.app/Contents/{MacOS,Resources}
# - Info.plist copied from Resources/Info.plist (authoritative for the bundle;
#   the binary also embeds a copy in __TEXT,__info_plist for bare-binary runs)
# - VeloraEngineDir is baked into the bundle Info.plist so the .app can find
#   the Python engine when launched from anywhere. Note: for v1 the .app is
#   therefore tied to this source checkout — the engine project, its .venv,
#   and downloaded models all live here. Moving/deleting the checkout breaks
#   the bundled app (set VELORA_ENGINE_DIR to override at runtime).
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

# Bake the absolute engine directory into the bundle so ResourceLocator can
# find it when the .app is launched outside the checkout (see header note).
ENGINE_DIR="$(pwd)/engine"
/usr/libexec/PlistBuddy -c "Delete :VeloraEngineDir" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :VeloraEngineDir string $ENGINE_DIR" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign with a stable identifier. Note: the bundle Info.plist takes
# precedence over the binary's __info_plist section once inside a bundle.
codesign --force --deep --sign - --identifier com.velora.app "$APP"
codesign --verify --verbose=2 "$APP"

echo "OK: $APP"
