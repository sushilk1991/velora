#!/bin/zsh
# Deterministic checks for Velora's restricted iCloud entitlement packaging.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/signing-config.sh

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/velora-signing-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

REQUESTED="$TMP_DIR/requested.plist"
PROFILE="$TMP_DIR/profile.plist"
INFO="$TMP_DIR/info.plist"

cat > "$REQUESTED" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.application-identifier</key>
  <string>JZFVKGDPU4.com.sushil.velora</string>
  <key>com.apple.developer.team-identifier</key>
  <string>JZFVKGDPU4</string>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>iCloud.com.velora.app</string></array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array><string>iCloud.com.velora.app</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudDocuments</string></array>
  <key>com.apple.developer.icloud-container-environment</key>
  <string>Production</string>
</dict></plist>
PLIST

cat > "$PROFILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Name</key><string>Velora Developer ID</string>
  <key>Platform</key><array><string>OSX</string></array>
  <key>ProvisionsAllDevices</key><true/>
  <key>ExpirationDate</key><date>2035-01-01T00:00:00Z</date>
  <key>Entitlements</key><dict>
    <key>com.apple.application-identifier</key><string>JZFVKGDPU4.com.sushil.velora</string>
    <key>com.apple.developer.team-identifier</key><string>JZFVKGDPU4</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.com.velora.app</string></array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array><string>iCloud.com.velora.app</string></array>
    <key>com.apple.developer.icloud-services</key>
    <array><string>CloudDocuments</string></array>
    <key>com.apple.developer.icloud-container-environment</key>
    <string>Production</string>
    <key>get-task-allow</key><false/>
  </dict>
</dict></plist>
PLIST

cat > "$INFO" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sushil.velora</string>
  <key>NSUbiquitousContainers</key><dict>
    <key>iCloud.com.velora.app</key><dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
      <key>NSUbiquitousContainerName</key><string>Velora</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
    </dict>
  </dict>
</dict></plist>
PLIST

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$TMP_DIR/failure.log" 2>&1; then
    echo "FAIL: $label unexpectedly succeeded" >&2
    exit 1
  fi
}

validate_signing_plists "$REQUESTED" "$PROFILE" "$INFO"
validate_developer_id_identity_name \
  'Developer ID Application: Sushil Kumar (JZFVKGDPU4)'
validate_signature_team_value 'JZFVKGDPU4'
expect_failure "wrong Developer ID identity team" \
  validate_developer_id_identity_name \
  'Developer ID Application: Another Team (WRONGTEAM)'
expect_failure "wrong signed-app team" validate_signature_team_value 'WRONGTEAM'

LOCAL_IDENTITIES='  1) AAA "Apple Development: Developer (OTHERTEAM)"
  2) BBB "Developer ID Application: Sushil Kumar (JZFVKGDPU4)"'
[[ "$(select_local_signing_identity "$LOCAL_IDENTITIES")" \
    == 'Developer ID Application: Sushil Kumar (JZFVKGDPU4)' ]]
[[ "$(select_local_signing_identity \
    '  1) AAA "Velora Dev Signing"')" == 'Velora Dev Signing' ]]
[[ "$(select_local_signing_identity \
    '  1) AAA "Apple Development: Developer (OTHERTEAM)"')" \
    == 'Apple Development: Developer (OTHERTEAM)' ]]
expect_failure "local build without a stable identity" \
  select_local_signing_identity '0 valid identities found'
require_bundle_uv 0 ''
require_bundle_uv 1 /usr/bin/true
expect_failure "distribution build without bundled uv" require_bundle_uv 1 ''

cp "$REQUESTED" "$TMP_DIR/wrong-requested-team.plist"
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.developer.team-identifier WRONGTEAM' \
  "$TMP_DIR/wrong-requested-team.plist"
expect_failure "mismatched requested team identifier" \
  validate_signing_plists "$TMP_DIR/wrong-requested-team.plist" "$PROFILE" "$INFO"

cp "$PROFILE" "$TMP_DIR/mismatch.plist"
/usr/libexec/PlistBuddy -c \
  'Set :Entitlements:com.apple.application-identifier WRONG.com.sushil.velora' \
  "$TMP_DIR/mismatch.plist"
expect_failure "mismatched application identifier" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/mismatch.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/no-container.plist"
/usr/libexec/PlistBuddy -c \
  'Delete :Entitlements:com.apple.developer.ubiquity-container-identifiers' \
  "$TMP_DIR/no-container.plist"
expect_failure "missing ubiquity authorization" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/no-container.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/no-service.plist"
/usr/libexec/PlistBuddy -c \
  'Delete :Entitlements:com.apple.developer.icloud-services' \
  "$TMP_DIR/no-service.plist"
expect_failure "missing CloudDocuments authorization" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/no-service.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/debuggable-profile.plist"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:get-task-allow true' \
  "$TMP_DIR/debuggable-profile.plist"
expect_failure "debuggable distribution profile" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/debuggable-profile.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/ios-profile.plist"
/usr/libexec/PlistBuddy -c 'Set :Platform:0 iOS' "$TMP_DIR/ios-profile.plist"
expect_failure "iOS profile for macOS app" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/ios-profile.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/device-profile.plist"
/usr/libexec/PlistBuddy -c 'Delete :ProvisionsAllDevices' "$TMP_DIR/device-profile.plist"
expect_failure "device-limited profile" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/device-profile.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/wrong-cloud-container.plist"
/usr/libexec/PlistBuddy -c \
  'Set :Entitlements:com.apple.developer.icloud-container-identifiers:0 iCloud.com.example.wrong' \
  "$TMP_DIR/wrong-cloud-container.plist"
expect_failure "wrong iCloud container authorization" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/wrong-cloud-container.plist" "$INFO"

cp "$REQUESTED" "$TMP_DIR/development-environment.plist"
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.developer.icloud-container-environment Development' \
  "$TMP_DIR/development-environment.plist"
expect_failure "non-production requested iCloud environment" \
  validate_signing_plists "$TMP_DIR/development-environment.plist" "$PROFILE" "$INFO"

cp "$PROFILE" "$TMP_DIR/development-profile.plist"
/usr/libexec/PlistBuddy -c \
  'Set :Entitlements:com.apple.developer.icloud-container-environment Development' \
  "$TMP_DIR/development-profile.plist"
expect_failure "non-production profile iCloud environment" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/development-profile.plist" "$INFO"

cp "$PROFILE" "$TMP_DIR/expired.plist"
plutil -replace ExpirationDate -date '2020-01-01T00:00:00Z' \
  "$TMP_DIR/expired.plist"
expect_failure "expired profile" \
  validate_signing_plists "$REQUESTED" "$TMP_DIR/expired.plist" "$INFO"

cp "$REQUESTED" "$TMP_DIR/no-microphone.plist"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.device.audio-input' \
  "$TMP_DIR/no-microphone.plist"
expect_failure "missing microphone entitlement" \
  validate_signing_plists "$TMP_DIR/no-microphone.plist" "$PROFILE" "$INFO"

validate_signing_plists Resources/Velora.entitlements "$PROFILE" Resources/Info.plist

mkdir -p "$TMP_DIR/Velora.app/Contents"
printf 'fixture-profile' > "$TMP_DIR/raw.provisionprofile"
embed_provisioning_profile "$TMP_DIR/raw.provisionprofile" "$TMP_DIR/Velora.app"
cmp -s "$TMP_DIR/raw.provisionprofile" \
  "$TMP_DIR/Velora.app/Contents/embedded.provisionprofile"

grep -Fq 'embed_provisioning_profile "$PROVISIONING_PROFILE" "$APP"' scripts/make-app.sh
grep -Fq 'validate_signed_app_team "$APP"' scripts/make-app.sh
grep -Fq 'validate_signed_app_team "$APP"' scripts/verify-dmg.sh
grep -Fq 'validate_signing_plists "$ENTITLEMENTS_FILE" "$PROFILE_PLIST" "$APP/Contents/Info.plist"' \
  scripts/verify-dmg.sh
grep -Fq 'require_bundle_uv "${VELORA_DISTRIBUTION:-0}" "$UV_BIN"' scripts/make-app.sh
grep -Fq 'test -x "$UV"' scripts/verify-dmg.sh
grep -Fq 'test -x "$CLI"' scripts/verify-dmg.sh
grep -Fq 'test -f "$ENGINE/src/velora_engine/server.py"' scripts/verify-dmg.sh
grep -Fq 'test -f "$ENGINE/src/velora_engine/cleanup_process.py"' scripts/verify-dmg.sh
grep -Fq 'CleanupProcess("probe").probe_async()' scripts/verify-dmg.sh
grep -Fq '"$CLI" mcp' scripts/verify-dmg.sh

VERSION_HASH="$(shasum VERSION Resources/Info.plist)"
if env -u VELORA_PROVISIONING_PROFILE VELORA_DISTRIBUTION=1 \
  ./scripts/make-app.sh release none >"$TMP_DIR/missing-profile.log" 2>&1; then
  echo "FAIL: distribution build accepted a missing provisioning profile" >&2
  exit 1
fi
grep -q 'VELORA_PROVISIONING_PROFILE' "$TMP_DIR/missing-profile.log"
[[ "$(shasum VERSION Resources/Info.plist)" == "$VERSION_HASH" ]]

plutil -lint Resources/Info.plist Resources/Velora.entitlements >/dev/null
echo "signing config tests OK"
