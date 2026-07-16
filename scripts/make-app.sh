#!/bin/zsh
# Builds Velora.app by hand from the SwiftPM binary (no Xcode).
#
# - Release build via swift build
# - Bundle layout: Velora.app/Contents/{MacOS,Resources}
# - Info.plist copied from Resources/Info.plist (authoritative for the bundle;
#   the binary also embeds a copy in __TEXT,__info_plist for bare-binary runs)
# - Self-contained: the Python engine project is copied into
#   Contents/Resources/engine (with a .velora-build stamp) and the uv binary
#   into Contents/Resources/bin/uv. On first launch the app syncs the engine
#   to ~/Library/Application Support/Velora/engine and bootstraps the venv
#   there with the bundled uv — the .app works on machines with nothing but
#   the .app (models still download from Hugging Face on first run).
# - VeloraEngineDir (this checkout's engine dir) is still baked into the
#   bundle Info.plist as a dev fallback; the bundled engine takes precedence
#   (set VELORA_ENGINE_DIR to override everything at runtime).
# - UI sounds (start/stop/error.caf) generated if missing and copied in
# - Development builds require a stable signing identity so TCC grants survive
#   rebuilds. make-dmg.sh sets
#   VELORA_DISTRIBUTION=1, which requires a Developer ID Application identity
#   and an Apple-issued Developer ID provisioning profile that authorizes the
#   microphone and iCloud Documents entitlements. Restricted entitlements fail
#   closed before version stamping or compilation.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-config.sh

CONFIG="${1:-release}"
# Second arg = version bump level for this build (default patch). A new build
# never reuses a version: patch for rebuilds/fixes, minor for feature rounds,
# major for big releases, none to leave VERSION untouched (throwaway dev builds).
BUMP="${2:-patch}"

# Resolve and validate distribution credentials before bumping the version or
# doing an expensive build, so missing/mismatched provisioning cannot leave
# release metadata in a half-finished state.
PROVISIONING_PROFILE=""
PROFILE_PLIST=""
SIGNED_ENTITLEMENTS=""
trap '[[ -z "${PROFILE_PLIST:-}" ]] || rm -f "$PROFILE_PLIST"; [[ -z "${SIGNED_ENTITLEMENTS:-}" ]] || rm -f "$SIGNED_ENTITLEMENTS"' EXIT
if [[ "${VELORA_DISTRIBUTION:-0}" == "1" ]]; then
  if [[ -z "${VELORA_PROVISIONING_PROFILE:-}" ]]; then
    echo "ERROR: distribution builds require VELORA_PROVISIONING_PROFILE" >&2
    exit 1
  fi
  PROVISIONING_PROFILE="${VELORA_PROVISIONING_PROFILE}"
  PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/velora-profile.XXXXXX")"
  decode_and_validate_provisioning_profile \
    "$PROVISIONING_PROFILE" Resources/Velora.entitlements Resources/Info.plist "$PROFILE_PLIST"

  IDENTITY="${DEVELOPER_ID_APPLICATION:-$(
    security find-identity -v -p codesigning 2>/dev/null \
      | grep -F "(${VELORA_TEAM_ID})\"" \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
      | head -n 1
  )}"
  if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: distribution builds require a Developer ID Application identity" >&2
    exit 1
  fi
  validate_developer_id_identity_name "$IDENTITY"
else
  IDENTITY="$(select_local_signing_identity)"
  echo "Local signing with: $IDENTITY"
fi

VERSION="$(./scripts/bump-version.sh "$BUMP")"
# Monotonic build number for CFBundleVersion (commit count; always increases).
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "Building Velora $VERSION (build $BUILD_NUM)"

# Keep the source Info.plist in sync BEFORE swift build so the binary's embedded
# __info_plist section (bare-binary runs) reports the same version as the bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Resources/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUM" Resources/Info.plist

# SwiftPM does not track the plist consumed only through the linker's
# `-sectcreate` flag. Force one source input fresh so a version-only rebuild
# relinks the binary instead of retaining stale embedded bundle metadata.
touch Sources/Velora/App/main.swift
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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # CFBundleIconFile = AppIcon

# Bake the absolute engine directory into the bundle as a dev fallback
# (the bundled Resources/engine copy below takes precedence at runtime).
ENGINE_DIR="$(pwd)/engine"
/usr/libexec/PlistBuddy -c "Delete :VeloraEngineDir" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :VeloraEngineDir string $ENGINE_DIR" "$APP/Contents/Info.plist"

# Version keys, from the VERSION source of truth (make-dmg.sh names the image
# after CFBundleShortVersionString). The bundle plist was just copied from
# Resources/Info.plist, which we already stamped above — set explicitly anyway
# so the bundle is correct even if the copy source drifts.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUM" "$APP/Contents/Info.plist"

# Bundle the engine project (sources + lockfile; no venv/tests/caches) so the
# .app is self-contained. ResourceLocator syncs this to Application Support
# on first launch and uv bootstraps the venv there.
BUNDLED_ENGINE="$APP/Contents/Resources/engine"
mkdir -p "$BUNDLED_ENGINE"
rsync -a \
  --exclude '.venv' --exclude 'tests' \
  --exclude '__pycache__' --exclude '.pytest_cache' \
  engine/pyproject.toml engine/uv.lock engine/README.md engine/src \
  "$BUNDLED_ENGINE/"
cp LICENSE "$BUNDLED_ENGINE/LICENSE"

# Build stamp: lets the app detect a new engine version and re-sync it to
# Application Support (preserving the existing venv).
GIT_REV="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
printf '%s %s\n' "$GIT_REV" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLED_ENGINE/.velora-build"

# Bundle uv (self-contained static binary; arm64-only app) so the engine can
# bootstrap on machines without uv installed.
UV_BIN="$(command -v uv || true)"
mkdir -p "$APP/Contents/Resources/bin"
# Default macOS volumes are case-insensitive, so `Velora` and `velora` cannot
# coexist in Contents/MacOS. Keep the lowercase CLI in Resources/bin and point
# it at the one signed app executable; argv[0] still selects headless mode.
ln -s ../../MacOS/Velora "$APP/Contents/Resources/bin/velora"
if [[ -n "$UV_BIN" ]]; then
  cp "$UV_BIN" "$APP/Contents/Resources/bin/uv"
  chmod 755 "$APP/Contents/Resources/bin/uv"
else
  echo "WARNING: uv not found on PATH — bundle will not be self-contained (app falls back to a system uv)"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "${VELORA_DISTRIBUTION:-0}" == "1" ]]; then
  embed_provisioning_profile "$PROVISIONING_PROFILE" "$APP"
fi

# Sign inside-out. The bundle Info.plist takes precedence over the binary's
# __info_plist section once inside a bundle.
SIGN_ARGS=(--force)
APP_SIGN_ARGS=()
if [[ "${VELORA_DISTRIBUTION:-0}" == "1" ]]; then
  SIGN_ARGS+=(--sign "$IDENTITY" --options runtime --timestamp)
  APP_SIGN_ARGS+=(--entitlements Resources/Velora.entitlements)
  echo "Distribution signing with: $IDENTITY"
else
  SIGN_ARGS+=(--sign "$IDENTITY")
fi
# Sign the nested uv binary explicitly (Resources/ binaries are sealed as
# resources, not nested code; re-sign it before the outer seal is computed).
if [[ -x "$APP/Contents/Resources/bin/uv" ]]; then
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/bin/uv"
fi
codesign "${SIGN_ARGS[@]}" "${APP_SIGN_ARGS[@]}" --identifier "$VELORA_BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "${VELORA_DISTRIBUTION:-0}" == "1" ]]; then
  SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/velora-signed-entitlements.XXXXXX")"
  codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
  validate_signing_plists "$SIGNED_ENTITLEMENTS" "$PROFILE_PLIST" "$APP/Contents/Info.plist"
  validate_signed_app_team "$APP"
fi
echo "OK: $APP (v$VERSION, build $BUILD_NUM)"
