#!/bin/zsh
# Shared fail-closed checks for Velora's restricted iCloud entitlements.
# Source this file from zsh scripts; it intentionally performs no work itself.

VELORA_BUNDLE_ID="com.velora.app"
VELORA_TEAM_ID="JZFVKGDPU4"
VELORA_ICLOUD_CONTAINER="iCloud.com.velora.app"

signing_error() {
  echo "ERROR: $*" >&2
  return 1
}

validate_developer_id_identity_name() {
  local identity="$1"
  [[ "$identity" == "Developer ID Application: "*" (${VELORA_TEAM_ID})" ]] \
    || { signing_error "Developer ID identity must belong to Team ${VELORA_TEAM_ID}"; return 1; }
}

validate_signature_team_value() {
  local team="$1"
  [[ "$team" == "$VELORA_TEAM_ID" ]] \
    || { signing_error "signed artifact TeamIdentifier must be ${VELORA_TEAM_ID}"; return 1; }
}

validate_signed_app_team() {
  local app="$1"
  local details team
  details="$(codesign -dvvv --verbose=4 "$app" 2>&1)" \
    || { signing_error "could not inspect the signed app identity"; return 1; }
  team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  validate_signature_team_value "$team"
}

plist_value() {
  local file="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$file" 2>/dev/null
}

plist_array_contains() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local output
  output="$(plist_value "$file" "$key")" || return 1
  printf '%s\n' "$output" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -Fqx -- "$expected"
}

plist_array_count() {
  local file="$1"
  local key="$2"
  local output
  output="$(plist_value "$file" "$key")" || return 1
  printf '%s\n' "$output" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | sed -e '/^Array {$/d' -e '/^}$/d' -e '/^$/d' \
    | wc -l \
    | tr -d '[:space:]'
}

require_exact_array_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  plist_array_contains "$file" "$key" "$expected" \
    || { signing_error "$label must authorize $expected"; return 1; }
  [[ "$(plist_array_count "$file" "$key")" == "1" ]] \
    || { signing_error "$label must contain only $expected"; return 1; }
}

profile_authorizes_value() {
  local profile="$1"
  local key="$2"
  local expected="$3"
  local raw
  raw="$(plist_value "$profile" "Entitlements:${key}")" || return 1
  [[ "$raw" == "*" ]] && return 0
  plist_array_contains "$profile" "Entitlements:${key}" "$expected"
}

validate_signing_plists() {
  local requested="$1"
  local profile="$2"
  local info="$3"

  plutil -lint "$requested" "$profile" "$info" >/dev/null \
    || { signing_error "signing metadata contains an invalid property list"; return 1; }

  [[ "$(plist_value "$requested" 'com.apple.security.device.audio-input')" == "true" ]] \
    || { signing_error "requested entitlements must keep microphone access"; return 1; }
  [[ "$(plist_value "$requested" 'com.apple.application-identifier')" \
      == "$VELORA_TEAM_ID.$VELORA_BUNDLE_ID" ]] \
    || { signing_error "requested application identifier must be $VELORA_TEAM_ID.$VELORA_BUNDLE_ID"; return 1; }
  [[ "$(plist_value "$requested" 'com.apple.developer.team-identifier')" \
      == "$VELORA_TEAM_ID" ]] \
    || { signing_error "requested team identifier must be $VELORA_TEAM_ID"; return 1; }
  require_exact_array_value "$requested" \
    'com.apple.developer.icloud-container-identifiers' \
    "$VELORA_ICLOUD_CONTAINER" 'requested iCloud containers' || return 1
  require_exact_array_value "$requested" \
    'com.apple.developer.ubiquity-container-identifiers' \
    "$VELORA_ICLOUD_CONTAINER" 'requested ubiquity containers' || return 1
  require_exact_array_value "$requested" \
    'com.apple.developer.icloud-services' \
    'CloudDocuments' 'requested iCloud services' || return 1

  [[ "$(plist_value "$profile" 'Entitlements:application-identifier')" \
      == "$VELORA_TEAM_ID.$VELORA_BUNDLE_ID" ]] \
    || { signing_error "profile application identifier must be $VELORA_TEAM_ID.$VELORA_BUNDLE_ID"; return 1; }
  [[ "$(plist_value "$profile" 'Entitlements:com.apple.developer.team-identifier')" \
      == "$VELORA_TEAM_ID" ]] \
    || { signing_error "profile team identifier must be $VELORA_TEAM_ID"; return 1; }
  plist_array_contains "$profile" 'Platform' 'OSX' \
    || { signing_error "profile must authorize macOS"; return 1; }
  [[ "$(plist_value "$profile" 'ProvisionsAllDevices')" == "true" ]] \
    || { signing_error "profile must be a Developer ID distribution profile"; return 1; }
  [[ "$(plist_value "$profile" 'Entitlements:get-task-allow')" != "true" ]] \
    || { signing_error "distribution profile must not allow debugging"; return 1; }
  profile_authorizes_value "$profile" \
    'com.apple.developer.icloud-container-identifiers' "$VELORA_ICLOUD_CONTAINER" \
    || { signing_error "profile does not authorize the Velora iCloud container"; return 1; }
  profile_authorizes_value "$profile" \
    'com.apple.developer.ubiquity-container-identifiers' "$VELORA_ICLOUD_CONTAINER" \
    || { signing_error "profile does not authorize the Velora ubiquity container"; return 1; }
  profile_authorizes_value "$profile" \
    'com.apple.developer.icloud-services' 'CloudDocuments' \
    || { signing_error "profile does not authorize iCloud Documents"; return 1; }

  local expiry expiry_epoch now_epoch
  expiry="$(plutil -extract ExpirationDate xml1 -o - "$profile" 2>/dev/null \
    | sed -n 's:.*<date>\(.*\)</date>.*:\1:p')"
  [[ -n "$expiry" ]] \
    || { signing_error "profile is missing an expiration date"; return 1; }
  expiry_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" '+%s' 2>/dev/null)" \
    || { signing_error "profile expiration date is invalid"; return 1; }
  now_epoch="$(date -u '+%s')"
  (( expiry_epoch > now_epoch )) \
    || { signing_error "provisioning profile is expired"; return 1; }

  [[ "$(plist_value "$info" 'CFBundleIdentifier')" == "$VELORA_BUNDLE_ID" ]] \
    || { signing_error "Info.plist bundle identifier must be $VELORA_BUNDLE_ID"; return 1; }
  [[ "$(plist_value "$info" \
      "NSUbiquitousContainers:${VELORA_ICLOUD_CONTAINER}:NSUbiquitousContainerIsDocumentScopePublic")" \
      == "true" ]] \
    || { signing_error "Info.plist must expose the Velora iCloud document scope"; return 1; }
  [[ "$(plist_value "$info" \
      "NSUbiquitousContainers:${VELORA_ICLOUD_CONTAINER}:NSUbiquitousContainerName")" \
      == "Velora" ]] \
    || { signing_error "Info.plist iCloud container name must be Velora"; return 1; }
  [[ "$(plist_value "$info" \
      "NSUbiquitousContainers:${VELORA_ICLOUD_CONTAINER}:NSUbiquitousContainerSupportedFolderLevels")" \
      == "Any" ]] \
    || { signing_error "Info.plist must allow the Personal Dictionary subfolder"; return 1; }
}

decode_and_validate_provisioning_profile() {
  local raw_profile="$1"
  local requested="$2"
  local info="$3"
  local decoded="$4"

  [[ -f "$raw_profile" && -r "$raw_profile" ]] \
    || { signing_error "provisioning profile is missing or unreadable: $raw_profile"; return 1; }
  security cms -D -i "$raw_profile" > "$decoded" 2>/dev/null \
    || { signing_error "VELORA_PROVISIONING_PROFILE is not a valid Apple provisioning profile"; return 1; }
  validate_signing_plists "$requested" "$decoded" "$info"
}

embed_provisioning_profile() {
  local raw_profile="$1"
  local app="$2"
  [[ -f "$raw_profile" && -d "$app/Contents" ]] \
    || { signing_error "cannot embed a missing profile or app bundle"; return 1; }
  cp "$raw_profile" "$app/Contents/embedded.provisionprofile" || return 1
  chmod 644 "$app/Contents/embedded.provisionprofile" || return 1
}
