#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

SCRIPT_NAME="${0:t}"
print_usage() {
  print -r -- "Usage: $SCRIPT_NAME [--json]"
  print -r -- "       $SCRIPT_NAME --help"
  print -r -- ""
  print -r -- "Inspect the local Apple release toolchain and emit one JSON readiness report."
  print -r -- "This command is read-only and never archives, signs, uploads, or changes Apple services."
}

if (( $# > 1 )); then
  print -u2 -- "Unexpected arguments: ${argv[*]}"
  print_usage >&2
  exit 64
fi
if (( $# == 1 )); then
  case "$1" in
    --json)
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      print -u2 -- "Unknown argument: $1"
      print_usage >&2
      exit 64
      ;;
  esac
fi

PROJECT_DIR="${0:A:h:h}"
READINESS_ROOT="$(mktemp -d /private/tmp/agentisland-readiness.XXXXXX)"
trap '[[ "$READINESS_ROOT" == /private/tmp/agentisland-readiness.* ]] && /bin/rm -rf "$READINESS_ROOT"' EXIT HUP INT TERM
trap 'rc=$?; print -u2 -- "release-readiness.sh failed at line $LINENO (exit $rc)"; trap - ZERR; exit $rc' ZERR
DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
FULL_XCODE=false
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] && FULL_XCODE=true

valid_bundle_id() {
  local value="$1"
  [[ "$value" == [A-Za-z0-9.-]## && "$value" == *.* && "$value" != *..* && "$value" != .* && "$value" != *. ]]
}

production_bundle_id() {
  local value="$1"
  local normalized="${value:l}"
  valid_bundle_id "$value" || return 1
  [[ "$normalized" != local.* && "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *yourdomain* && "$normalized" != *placeholder* ]]
}

production_https_url() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == https://* && "$value" != *[[:space:]]* && \
    "$normalized" != *localhost* && "$normalized" != *127.0.0.1* && \
    "$normalized" != *example* && "$normalized" != *placeholder* && \
    "$normalized" != *yourdomain* && "$normalized" != *.invalid/* && "$normalized" != *.test/* ]]
}

production_team_id() {
  [[ "$1" == [A-Z0-9]## && ${#1} -eq 10 && "${1:l}" != *placeholder* ]]
}

utf8_character_count() {
  printf '%s' "$1" | LC_ALL= LC_CTYPE=UTF-8 /usr/bin/wc -m | /usr/bin/tr -d '[:space:]'
}

production_display_name() {
  local value="$1"
  local comparison
  local character_count
  character_count="$(utf8_character_count "$value")"
  (( character_count >= 2 && character_count <= 30 )) || return 1
  [[ "$value" != [[:space:]]* && "$value" != *[[:space:]] && "$value" != *[[:cntrl:]]* ]] || return 1
  comparison="$(print -rn -- "$value" | /usr/bin/tr -cd '[:alnum:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$comparison" != "agentisland" && "$comparison" != "tasklume" ]]
}

production_container_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == iCloud.* && "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *placeholder* ]]
}

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
}

IOS_XCCONFIG_PATH="$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
MAC_XCCONFIG_PATH="$PROJECT_DIR/ApplePlatforms/macOS/Config/Project.xcconfig"
xcconfig_value() {
  local key="$1"
  [[ -f "$IOS_XCCONFIG_PATH" ]] || return 0
  /usr/bin/awk -v key="$key" '
    $1 == key && $2 == "=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*\/\/.*$/, "")
      gsub(/\$\(AGENT_ISLAND_URL_SLASH\)/, "/")
      print
      exit
    }
  ' "$IOS_XCCONFIG_PATH"
}

mac_xcconfig_value() {
  local key="$1"
  [[ -f "$MAC_XCCONFIG_PATH" ]] || return 0
  /usr/bin/awk -v key="$key" '
    $1 == key && $2 == "=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*\/\/.*$/, "")
      print
      exit
    }
  ' "$MAC_XCCONFIG_PATH"
}

XCODE_VERSION=""
XCODE_MAJOR=0
IPHONE_SDK=""
IPHONE_SDK_MAJOR=0
if [[ "$FULL_XCODE" == true ]]; then
  # Read the complete xcodebuild output before awk exits.  With pipefail enabled,
  # stopping after the first line can send SIGPIPE to xcodebuild (exit 141) on
  # GitHub's full Xcode runners even though the version lookup succeeded.
  XCODE_VERSION="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/awk '/^Xcode / {print $2}')"
  [[ "$XCODE_VERSION" == <->* ]] && XCODE_MAJOR="${XCODE_VERSION%%.*}"
  IPHONE_SDK="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  [[ "$IPHONE_SDK" == <->* ]] && IPHONE_SDK_MAJOR="${IPHONE_SDK%%.*}"
fi

IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
VALID_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec '^[[:space:]]*[0-9]+\)' || true)"
DEVELOPER_ID_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -c 'Developer ID Application:' || true)"
APPLE_DEVELOPMENT_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec 'Apple Development:|iPhone Developer:' || true)"
APPLE_DISTRIBUTION_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec 'Apple Distribution:|iPhone Distribution:|3rd Party Mac Developer Application:' || true)"

AVAILABLE_KIB="$(/bin/df -k /Applications | /usr/bin/awk 'NR==2 {print $4}')"
AVAILABLE_GIB="$(( AVAILABLE_KIB / 1024 / 1024 ))"

typeset -a AMBIGUOUS_MAC_ARCHIVE_NAMES
AMBIGUOUS_MAC_ARCHIVE_NAMES=()
PUBLIC_APP_NAME="MAC版灵动岛--Agent运行监测"
CANONICAL_MAC_ARCHIVE="$PROJECT_DIR/dist/$PUBLIC_APP_NAME-macOS-universal.zip"
for ARCHIVE_CANDIDATE in "$PROJECT_DIR"/dist/*macOS-universal*.zip(N); do
  [[ "$ARCHIVE_CANDIDATE" == "$CANONICAL_MAC_ARCHIVE" ]] || AMBIGUOUS_MAC_ARCHIVE_NAMES+=("${ARCHIVE_CANDIDATE:t}")
done
MAC_ARCHIVE_SET_CLEAN=false
AMBIGUOUS_MAC_ARCHIVES_JSON="[]"
if (( ${#AMBIGUOUS_MAC_ARCHIVE_NAMES[@]} == 0 )); then
  MAC_ARCHIVE_SET_CLEAN=true
else
  AMBIGUOUS_MAC_ARCHIVES_JSON="$(print -rl -- "${AMBIGUOUS_MAC_ARCHIVE_NAMES[@]}" | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
fi

MAC_BUNDLE_ID="${AGENT_ISLAND_BUNDLE_ID:-}"
MAC_SIGN_IDENTITY="${AGENT_ISLAND_DEVELOPER_ID_APPLICATION:-}"
DISPLAY_NAME="${AGENT_ISLAND_DISPLAY_NAME:-}"
CONFIGURED_TEAM_ID="${AGENT_ISLAND_DEVELOPMENT_TEAM:-$(xcconfig_value AGENT_ISLAND_DEVELOPMENT_TEAM)}"
IOS_APP_BUNDLE_ID="$(xcconfig_value AGENT_ISLAND_APP_BUNDLE_ID)"
IOS_WIDGET_BUNDLE_ID="$(xcconfig_value AGENT_ISLAND_WIDGET_BUNDLE_ID)"
[[ "$IOS_WIDGET_BUNDLE_ID" == '$('* ]] && IOS_WIDGET_BUNDLE_ID="$IOS_APP_BUNDLE_ID.liveactivity"
NOTARY_PROFILE="${AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE:-}"
ENTITLEMENTS_PATH="${AGENT_ISLAND_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${AGENT_ISLAND_PROVISIONING_PROFILE:-}"
RELEASE_PRIVACY_URL="${AGENT_ISLAND_PRIVACY_POLICY_URL:-}"
RELEASE_SUPPORT_URL="${AGENT_ISLAND_SUPPORT_URL:-}"
IOS_PRIVACY_URL="$(xcconfig_value AGENT_ISLAND_PRIVACY_POLICY_URL)"
IOS_SUPPORT_URL="$(xcconfig_value AGENT_ISLAND_SUPPORT_URL)"
IOS_TEAM_ID="$(xcconfig_value AGENT_ISLAND_DEVELOPMENT_TEAM)"
CLOUDKIT_CONTAINER_ID="${AGENT_ISLAND_ICLOUD_CONTAINER_ID:-$(xcconfig_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)}"
IOS_CONTAINER_ID="$(xcconfig_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)"
IOS_DISPLAY_NAME="$(xcconfig_value AGENT_ISLAND_DISPLAY_NAME)"
IOS_MARKETING_VERSION="$(xcconfig_value MARKETING_VERSION)"
IOS_BUILD_NUMBER="$(xcconfig_value CURRENT_PROJECT_VERSION)"
MAC_CONFIG_MARKETING_VERSION="$(mac_xcconfig_value MARKETING_VERSION)"
MAC_CONFIG_BUILD_NUMBER="$(mac_xcconfig_value CURRENT_PROJECT_VERSION)"
MAC_MARKETING_VERSION="$MAC_CONFIG_MARKETING_VERSION"
MAC_BUILD_NUMBER="$MAC_CONFIG_BUILD_NUMBER"
IOS_TESTFLIGHT_VERIFICATION_EVIDENCE="${AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE:-}"
IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256="${AGENT_ISLAND_IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256:-}"

IOS_XCODE_PROJECT="$PROJECT_DIR/ApplePlatforms/iOS/AgentIsland.xcodeproj"
IOS_XCODE_SCHEME="AgentIslandMobile"
IOS_BUILD_SETTINGS_VALIDATOR="$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-build-settings.mjs"
IOS_BUILD_SETTINGS_JSON="$READINESS_ROOT/ios-build-settings.json"
IOS_BUILD_SETTINGS_RESULT="$READINESS_ROOT/ios-build-settings-result.json"
IOS_BUILD_SETTINGS_RESOLVED=false
IOS_TARGET_BUILD_SETTINGS_CONFIGURED=false
IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED=false
IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT=false
IOS_BUILD_SETTINGS_MISMATCHES_JSON="[]"
if [[ "$FULL_XCODE" == true && -f "$IOS_XCODE_PROJECT/project.pbxproj" && \
    -f "$IOS_BUILD_SETTINGS_VALIDATOR" && -n "$IOS_XCODE_SCHEME" ]] && \
    command -v node >/dev/null 2>&1 && \
    DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild \
      -project "$IOS_XCODE_PROJECT" \
      -scheme "$IOS_XCODE_SCHEME" \
      -configuration Release \
      -sdk iphoneos \
      -destination 'generic/platform=iOS' \
      -showBuildSettings \
      -json >"$IOS_BUILD_SETTINGS_JSON" 2>/dev/null && \
    node "$IOS_BUILD_SETTINGS_VALIDATOR" "$IOS_BUILD_SETTINGS_JSON" \
      >"$IOS_BUILD_SETTINGS_RESULT" 2>/dev/null; then
  IOS_BUILD_SETTINGS_RESOLVED="$(/usr/bin/jq -r '.targetsResolved == true' "$IOS_BUILD_SETTINGS_RESULT")"
  IOS_TARGET_BUILD_SETTINGS_CONFIGURED="$(/usr/bin/jq -r '.targetContractReady == true' "$IOS_BUILD_SETTINGS_RESULT")"
  IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED="$(/usr/bin/jq -r '.productionConfigurationReady == true' "$IOS_BUILD_SETTINGS_RESULT")"
  IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT="$(/usr/bin/jq -r '.environmentMatches == true' "$IOS_BUILD_SETTINGS_RESULT")"
  IOS_BUILD_SETTINGS_MISMATCHES_JSON="$(/usr/bin/jq -c '.environmentMismatches' "$IOS_BUILD_SETTINGS_RESULT")"
  if [[ "$IOS_BUILD_SETTINGS_RESOLVED" == true ]]; then
    IOS_APP_BUNDLE_ID="$(/usr/bin/jq -r '.actual.appBundleID' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_WIDGET_BUNDLE_ID="$(/usr/bin/jq -r '.actual.widgetBundleID' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_TEAM_ID="$(/usr/bin/jq -r '.actual.developmentTeam' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_CONTAINER_ID="$(/usr/bin/jq -r '.actual.cloudKitContainerID' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_PRIVACY_URL="$(/usr/bin/jq -r '.actual.privacyPolicyURL' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_SUPPORT_URL="$(/usr/bin/jq -r '.actual.supportURL' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_DISPLAY_NAME="$(/usr/bin/jq -r '.actual.displayName' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_MARKETING_VERSION="$(/usr/bin/jq -r '.actual.marketingVersion' "$IOS_BUILD_SETTINGS_RESULT")"
    IOS_BUILD_NUMBER="$(/usr/bin/jq -r '.actual.buildNumber' "$IOS_BUILD_SETTINGS_RESULT")"
  fi
fi

IOS_PROJECT_RELEASE_VALIDATION=false
if "$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-project.sh" --release >/dev/null 2>&1; then
  IOS_PROJECT_RELEASE_VALIDATION=true
fi

MAC_BUNDLE_READY=false
IOS_APP_BUNDLE_READY=false
IOS_WIDGET_BUNDLE_READY=false
ENTITLEMENTS_READY=false
PROVISIONING_PROFILE_READY=false
PROVISIONING_PROFILE_CERTIFICATE_READY=false
SOURCE_APP_IDENTIFIER=""
CLOUDKIT_CONTAINER_READY=false
RELEASE_PRIVACY_READY=false
RELEASE_SUPPORT_READY=false
IOS_TEAM_READY=false
CONFIGURED_TEAM_READY=false
MAC_SIGN_IDENTITY_READY=false
DISPLAY_NAME_READY=false
IOS_CONTAINER_READY=false
IOS_PRIVACY_READY=false
IOS_SUPPORT_READY=false
IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED=false
IOS_REAL_DEVICE_SYNC_VERIFIED=false
IOS_LIVE_ACTIVITY_VERIFIED=false
IOS_REVIEW_PATH_VERIFIED=false
IOS_TESTFLIGHT_UPLOAD_VERIFIED=false
IOS_TESTFLIGHT_PROCESSING_VERIFIED=false
IOS_TESTFLIGHT_INSTALL_VERIFIED=false
IOS_TESTFLIGHT_EVIDENCE_CONFIGURED=false
IOS_LOCAL_IPA_PREFLIGHT_READY=false
IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY=false
IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=false
IOS_TESTFLIGHT_IPA_SHA256=""
IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID=""
APPLE_DISTRIBUTION_TEAM_IDENTITIES=0
APPLE_DISTRIBUTION_TEAM_IDENTITY_READY=false
production_bundle_id "$MAC_BUNDLE_ID" && MAC_BUNDLE_READY=true
if production_display_name "$DISPLAY_NAME" && [[ "$DISPLAY_NAME" == "$PUBLIC_APP_NAME" ]]; then
  DISPLAY_NAME_READY=true
fi
production_bundle_id "$IOS_APP_BUNDLE_ID" && IOS_APP_BUNDLE_READY=true
if production_bundle_id "$IOS_WIDGET_BUNDLE_ID" && [[ "$IOS_WIDGET_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID.liveactivity" ]]; then
  IOS_WIDGET_BUNDLE_READY=true
fi
production_container_id "$CLOUDKIT_CONTAINER_ID" && CLOUDKIT_CONTAINER_READY=true
if [[ "$CLOUDKIT_CONTAINER_READY" == true && -f "$ENTITLEMENTS_PATH" ]] && /usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null 2>&1 && \
    ! /usr/bin/grep -Eqi 'yourname|yourdomain|example|placeholder' "$ENTITLEMENTS_PATH"; then
  ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - "$ENTITLEMENTS_PATH" 2>/dev/null || print '{}')"
  if print -r -- "$ENTITLEMENTS_JSON" | /usr/bin/jq -e \
      --arg container "$CLOUDKIT_CONTAINER_ID" --arg bundle "$MAC_BUNDLE_ID" --arg team "$CONFIGURED_TEAM_ID" '
      (."com.apple.application-identifier" | type == "string" and endswith("." + $bundle)) and
      (."com.apple.developer.team-identifier" == $team) and
      ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
      ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
      (."com.apple.developer.icloud-container-environment" == "Production") and
      ((."com.apple.security.get-task-allow" // false) == false)
    ' >/dev/null 2>&1; then
    ENTITLEMENTS_READY=true
    SOURCE_APP_IDENTIFIER="$(print -r -- "$ENTITLEMENTS_JSON" | /usr/bin/jq -r '."com.apple.application-identifier"')"
  fi
fi
if [[ "$ENTITLEMENTS_READY" == true && -f "$PROVISIONING_PROFILE" ]]; then
  PROFILE_PLIST="$READINESS_ROOT/provisioning-profile.plist"
  if /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST" >/dev/null 2>&1 && \
      /usr/bin/plutil -lint "$PROFILE_PLIST" >/dev/null 2>&1; then
    PROFILE_ENTITLEMENTS_PLIST="$READINESS_ROOT/provisioning-profile-entitlements.plist"
    PROFILE_ENTITLEMENTS_JSON="$READINESS_ROOT/provisioning-profile-entitlements.json"
    if /usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST" >/dev/null 2>&1 && \
        /usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON" "$PROFILE_ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
      PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
      if /usr/bin/jq -e \
          --arg container "$CLOUDKIT_CONTAINER_ID" --arg sourceAppIdentifier "$SOURCE_APP_IDENTIFIER" --arg team "$CONFIGURED_TEAM_ID" '
          (."com.apple.application-identifier" == $sourceAppIdentifier) and
          (."com.apple.developer.team-identifier" == $team) and
          ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
          ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
          (."com.apple.developer.icloud-container-environment" == "Production") and
          ((."com.apple.security.get-task-allow" // false) == false)
        ' "$PROFILE_ENTITLEMENTS_JSON" >/dev/null 2>&1 && \
          [[ "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TEAM" == "$CONFIGURED_TEAM_ID" && \
            "$PROFILE_PLATFORM_COUNT" == "1" && "$PROFILE_PLATFORM" == "OSX" && \
            "$PROFILE_CERTIFICATE_COUNT" == <-> && "$PROFILE_CERTIFICATE_COUNT" -gt 0 && \
            "$PROFILE_PROVISIONS_ALL_DEVICES" == "true" && "$PROFILE_EXPIRATION_EPOCH" == <-> && \
            "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]]; then
        PROVISIONING_PROFILE_READY=true
      fi
    fi
  fi
fi

# A profile can match the Team/App ID yet authorize a different Developer ID
# certificate. Gatekeeper evaluates Developer ID profiles at launch, so report
# that certificate binding separately rather than claiming release readiness.
CONFIGURED_IDENTITY_MATCH_COUNT="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$MAC_SIGN_IDENTITY\"" || true)"
CONFIGURED_IDENTITY_SHA1=""
if [[ "$CONFIGURED_IDENTITY_MATCH_COUNT" == "1" ]]; then
  CONFIGURED_IDENTITY_SHA1="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -F "\"$MAC_SIGN_IDENTITY\"" | /usr/bin/awk '{print toupper($2); exit}')"
fi
if [[ "$PROVISIONING_PROFILE_READY" == true && "$CONFIGURED_IDENTITY_SHA1" == [0-9A-F]## && ${#CONFIGURED_IDENTITY_SHA1} -eq 40 ]]; then
  for (( PROFILE_CERTIFICATE_INDEX = 0; PROFILE_CERTIFICATE_INDEX < PROFILE_CERTIFICATE_COUNT; PROFILE_CERTIFICATE_INDEX++ )); do
    PROFILE_CERTIFICATE_PATH="$READINESS_ROOT/profile-certificate-$PROFILE_CERTIFICATE_INDEX.cer"
    PROFILE_CERTIFICATE_BASE64="$(/usr/bin/plutil -extract "DeveloperCertificates.$PROFILE_CERTIFICATE_INDEX" raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    if [[ -n "$PROFILE_CERTIFICATE_BASE64" ]] && print -rn -- "$PROFILE_CERTIFICATE_BASE64" | /usr/bin/base64 -D >"$PROFILE_CERTIFICATE_PATH" 2>/dev/null; then
      PROFILE_CERTIFICATE_SHA1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$PROFILE_CERTIFICATE_PATH" | /usr/bin/awk '{print toupper($1)}')"
      if [[ "$PROFILE_CERTIFICATE_SHA1" == "$CONFIGURED_IDENTITY_SHA1" ]]; then
        PROVISIONING_PROFILE_CERTIFICATE_READY=true
        break
      fi
    fi
  done
fi
production_https_url "$RELEASE_PRIVACY_URL" && RELEASE_PRIVACY_READY=true
production_https_url "$RELEASE_SUPPORT_URL" && RELEASE_SUPPORT_READY=true
production_team_id "$CONFIGURED_TEAM_ID" && CONFIGURED_TEAM_READY=true
production_team_id "$IOS_TEAM_ID" && IOS_TEAM_READY=true
if [[ "$CONFIGURED_TEAM_READY" == true ]]; then
  APPLE_DISTRIBUTION_TEAM_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/awk -v team="$CONFIGURED_TEAM_ID" '
    /Apple Distribution:|iPhone Distribution:|3rd Party Mac Developer Application:/ &&
      index($0, "(" team ")") { count += 1 }
    END { print count + 0 }
  ')"
  (( APPLE_DISTRIBUTION_TEAM_IDENTITIES > 0 )) && APPLE_DISTRIBUTION_TEAM_IDENTITY_READY=true
fi
if [[ "$CONFIGURED_TEAM_READY" == true && "$MAC_SIGN_IDENTITY" == "Developer ID Application:"* && \
    "$MAC_SIGN_IDENTITY" == *"($CONFIGURED_TEAM_ID)" && \
    "$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$MAC_SIGN_IDENTITY\"" || true)" == "1" ]]; then
  MAC_SIGN_IDENTITY_READY=true
fi
production_container_id "$IOS_CONTAINER_ID" && IOS_CONTAINER_READY=true
production_https_url "$IOS_PRIVACY_URL" && IOS_PRIVACY_READY=true
production_https_url "$IOS_SUPPORT_URL" && IOS_SUPPORT_READY=true
[[ "${AGENT_ISLAND_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED:-false}" == "true" ]] && IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED=true
[[ "${AGENT_ISLAND_IOS_REAL_DEVICE_SYNC_VERIFIED:-false}" == "true" ]] && IOS_REAL_DEVICE_SYNC_VERIFIED=true
[[ "${AGENT_ISLAND_IOS_LIVE_ACTIVITY_VERIFIED:-false}" == "true" ]] && IOS_LIVE_ACTIVITY_VERIFIED=true
[[ "${AGENT_ISLAND_IOS_REVIEW_PATH_VERIFIED:-false}" == "true" ]] && IOS_REVIEW_PATH_VERIFIED=true

# Consume the immutable post-upload evidence produced by
# confirm-testflight-evidence.sh. Free-standing environment booleans are not
# accepted as proof that Apple received, processed, distributed, or installed
# the candidate.
if [[ -n "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" ]]; then
  IOS_TESTFLIGHT_EVIDENCE_CONFIGURED=true
  if [[ "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" == /* && \
      -f "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" && \
      ! -L "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" ]]; then
    IOS_EVIDENCE_PATH="${IOS_TESTFLIGHT_VERIFICATION_EVIDENCE:A}"
    IOS_EVIDENCE_DIRECTORY="${IOS_EVIDENCE_PATH:h}"
    if [[ "$IOS_EVIDENCE_PATH" == \
        "$PROJECT_DIR"/dist/ios/*/testflight-verification-*.json && \
        ! -L "$IOS_EVIDENCE_DIRECTORY" ]]; then
      IOS_EVIDENCE_BUNDLE_ID="$(/usr/bin/jq -r '.appBundleID // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_VERSION="$(/usr/bin/jq -r '.version // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_BUILD="$(/usr/bin/jq -r '.build // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_IPA_PATH="$(/usr/bin/jq -r '.ipaPath // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_IPA_SHA="$(/usr/bin/jq -r '.ipaSHA256 // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_METADATA_PATH="$(/usr/bin/jq -r '.releaseMetadataPath // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_METADATA_SHA="$(/usr/bin/jq -r '.releaseMetadataSHA256 // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_DELIVERY_PATH="$(/usr/bin/jq -r '.deliveryRecordPath // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_DELIVERY_SHA="$(/usr/bin/jq -r '.deliveryRecordSHA256 // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_BUILD_ID="$(/usr/bin/jq -r '.appStoreConnectBuildID // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_PROCESSING_STATE="$(/usr/bin/jq -r '.processingState // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_PROCESSING_AT="$(/usr/bin/jq -r '.processingVerifiedAt // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"
      IOS_EVIDENCE_TESTED_AT="$(/usr/bin/jq -r '.testedAt // ""' \
        "$IOS_EVIDENCE_PATH" 2>/dev/null || true)"

      if [[ "$IOS_EVIDENCE_IPA_PATH" == "$IOS_EVIDENCE_DIRECTORY"/* && \
          "$IOS_EVIDENCE_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID" && \
          "$IOS_EVIDENCE_VERSION" == "$IOS_MARKETING_VERSION" && \
          "$IOS_EVIDENCE_BUILD" == "$IOS_BUILD_NUMBER" && \
          "$IOS_EVIDENCE_METADATA_PATH" == "$IOS_EVIDENCE_DIRECTORY/release-metadata.json" && \
          "$IOS_EVIDENCE_DELIVERY_PATH" == "$IOS_EVIDENCE_DIRECTORY"/testflight-delivery-*.json && \
          -f "$IOS_EVIDENCE_IPA_PATH" && ! -L "$IOS_EVIDENCE_IPA_PATH" && \
          -f "$IOS_EVIDENCE_METADATA_PATH" && ! -L "$IOS_EVIDENCE_METADATA_PATH" && \
          -f "$IOS_EVIDENCE_DELIVERY_PATH" && ! -L "$IOS_EVIDENCE_DELIVERY_PATH" && \
          "$IOS_EVIDENCE_IPA_SHA" == [0-9a-f]## && ${#IOS_EVIDENCE_IPA_SHA} -eq 64 && \
          "$IOS_EVIDENCE_METADATA_SHA" == [0-9a-f]## && ${#IOS_EVIDENCE_METADATA_SHA} -eq 64 && \
          "$IOS_EVIDENCE_DELIVERY_SHA" == [0-9a-f]## && ${#IOS_EVIDENCE_DELIVERY_SHA} -eq 64 && \
          "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_IPA_PATH" | /usr/bin/awk '{print $1}')" == "$IOS_EVIDENCE_IPA_SHA" && \
          "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_METADATA_PATH" | /usr/bin/awk '{print $1}')" == "$IOS_EVIDENCE_METADATA_SHA" && \
          "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_DELIVERY_PATH" | /usr/bin/awk '{print $1}')" == "$IOS_EVIDENCE_DELIVERY_SHA" ]]; then
        # Reuse the exact credential-free preflight used before a deliberate
        # upload. Hashes and hand-authored JSON alone are not evidence that an
        # IPA is a real signed iOS payload with the reviewed profiles,
        # entitlements, privacy manifests, and arm64 binaries.
        if "$PROJECT_DIR/ApplePlatforms/iOS/scripts/submit-testflight.sh" \
            --check "$IOS_EVIDENCE_DIRECTORY" >/dev/null 2>&1; then
          IOS_LOCAL_IPA_PREFLIGHT_READY=true
        fi

        IOS_DELIVERY_VALIDATION_PATH="$(/usr/bin/jq -r '.validationResultPath // ""' \
          "$IOS_EVIDENCE_DELIVERY_PATH" 2>/dev/null || true)"
        IOS_DELIVERY_VALIDATION_SHA="$(/usr/bin/jq -r '.validationResultSHA256 // ""' \
          "$IOS_EVIDENCE_DELIVERY_PATH" 2>/dev/null || true)"
        IOS_DELIVERY_UPLOAD_PATH="$(/usr/bin/jq -r '.uploadResultPath // ""' \
          "$IOS_EVIDENCE_DELIVERY_PATH" 2>/dev/null || true)"
        IOS_DELIVERY_UPLOAD_SHA="$(/usr/bin/jq -r '.uploadResultSHA256 // ""' \
          "$IOS_EVIDENCE_DELIVERY_PATH" 2>/dev/null || true)"
        IOS_DELIVERY_SUBMITTED_AT="$(/usr/bin/jq -r '.submittedAt // ""' \
          "$IOS_EVIDENCE_DELIVERY_PATH" 2>/dev/null || true)"
        if [[ "$IOS_DELIVERY_VALIDATION_PATH" == "$IOS_EVIDENCE_DIRECTORY"/* && \
            "$IOS_DELIVERY_UPLOAD_PATH" == "$IOS_EVIDENCE_DIRECTORY"/* && \
            -f "$IOS_DELIVERY_VALIDATION_PATH" && ! -L "$IOS_DELIVERY_VALIDATION_PATH" && \
            -f "$IOS_DELIVERY_UPLOAD_PATH" && ! -L "$IOS_DELIVERY_UPLOAD_PATH" && \
            "$IOS_DELIVERY_VALIDATION_SHA" == [0-9a-f]## && ${#IOS_DELIVERY_VALIDATION_SHA} -eq 64 && \
            "$IOS_DELIVERY_UPLOAD_SHA" == [0-9a-f]## && ${#IOS_DELIVERY_UPLOAD_SHA} -eq 64 && \
            "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_DELIVERY_VALIDATION_PATH" | /usr/bin/awk '{print $1}')" == "$IOS_DELIVERY_VALIDATION_SHA" && \
            "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_DELIVERY_UPLOAD_PATH" | /usr/bin/awk '{print $1}')" == "$IOS_DELIVERY_UPLOAD_SHA" ]] && \
            /usr/bin/jq -e \
              --arg bundle "$IOS_EVIDENCE_BUNDLE_ID" --arg version "$IOS_EVIDENCE_VERSION" \
              --arg build "$IOS_EVIDENCE_BUILD" --arg ipaPath "$IOS_EVIDENCE_IPA_PATH" \
              --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" \
              --arg metadataPath "$IOS_EVIDENCE_METADATA_PATH" \
              --arg metadataSHA "$IOS_EVIDENCE_METADATA_SHA" \
              --arg deliveryPath "$IOS_EVIDENCE_DELIVERY_PATH" \
              --arg deliverySHA "$IOS_EVIDENCE_DELIVERY_SHA" '
                .schemaVersion == 1 and .platform == "iOS" and
                .appBundleID == $bundle and .version == $version and .build == $build and
                .ipaPath == $ipaPath and .ipaSHA256 == $ipaSHA and
                .releaseMetadataPath == $metadataPath and
                .releaseMetadataSHA256 == $metadataSHA and
                .deliveryRecordPath == $deliveryPath and
                .deliveryRecordSHA256 == $deliverySHA and
                .uploadAccepted == true and
                (.appStoreConnectBuildID | type == "string" and length > 0) and
                (.processingState == "VALID" or .processingState == "Complete") and
                (.processingVerifiedAt | type == "string" and length > 0) and
                .distributedToTesters == true and .installedFromTestFlight == true and
                (.testedAt | type == "string" and length > 0)
              ' "$IOS_EVIDENCE_PATH" >/dev/null 2>&1 && \
            /usr/bin/jq -e \
              --arg bundle "$IOS_EVIDENCE_BUNDLE_ID" --arg version "$IOS_EVIDENCE_VERSION" \
              --arg build "$IOS_EVIDENCE_BUILD" --arg ipaPath "$IOS_EVIDENCE_IPA_PATH" \
              --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" '
                .schemaVersion == 1 and .appBundleID == $bundle and
                .version == $version and .build == $build and
                .exportedIPA == $ipaPath and .ipaSHA256 == $ipaSHA and
                (.allowProvisioningUpdates | type == "boolean") and .uploaded == false
              ' "$IOS_EVIDENCE_METADATA_PATH" >/dev/null 2>&1 && \
            /usr/bin/jq -e \
              --arg team "$IOS_TEAM_ID" \
              --arg widgetBundle "$IOS_WIDGET_BUNDLE_ID" \
              --arg displayName "$IOS_DISPLAY_NAME" \
              --arg container "$IOS_CONTAINER_ID" \
              --arg privacyURL "$IOS_PRIVACY_URL" \
              --arg supportURL "$IOS_SUPPORT_URL" '
                .teamID == $team and .widgetBundleID == $widgetBundle and
                .displayName == $displayName and .cloudContainerID == $container and
                .privacyPolicyURL == $privacyURL and .supportURL == $supportURL and
                .cloudKitEnvironment == "Production"
              ' "$IOS_EVIDENCE_METADATA_PATH" >/dev/null 2>&1 && \
            /usr/bin/jq -e \
              --arg bundle "$IOS_EVIDENCE_BUNDLE_ID" --arg version "$IOS_EVIDENCE_VERSION" \
              --arg build "$IOS_EVIDENCE_BUILD" --arg ipaPath "$IOS_EVIDENCE_IPA_PATH" \
              --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" \
              --arg metadataPath "$IOS_EVIDENCE_METADATA_PATH" \
              --arg metadataSHA "$IOS_EVIDENCE_METADATA_SHA" \
              --arg validationPath "$IOS_DELIVERY_VALIDATION_PATH" \
              --arg validationSHA "$IOS_DELIVERY_VALIDATION_SHA" \
              --arg uploadPath "$IOS_DELIVERY_UPLOAD_PATH" \
              --arg uploadSHA "$IOS_DELIVERY_UPLOAD_SHA" '
                .schemaVersion == 1 and .platform == "iOS" and
                .destination == "App Store Connect / TestFlight" and
                .appBundleID == $bundle and .version == $version and .build == $build and
                .ipaPath == $ipaPath and .ipaSHA256 == $ipaSHA and
                .releaseMetadataPath == $metadataPath and
                .releaseMetadataSHA256 == $metadataSHA and
                .validationResultPath == $validationPath and
                .validationResultSHA256 == $validationSHA and
                .uploadResultPath == $uploadPath and .uploadResultSHA256 == $uploadSHA and
                .uploadAccepted == true and .processingState == null and
                .appStoreConnectBuildID == null and .processingVerified == false and
                .distributedToTesters == false and .installedFromTestFlight == false and
                .submittedForAppReview == false
              ' "$IOS_EVIDENCE_DELIVERY_PATH" >/dev/null 2>&1 && \
            valid_utc_timestamp "$IOS_DELIVERY_SUBMITTED_AT" && \
            valid_utc_timestamp "$IOS_EVIDENCE_PROCESSING_AT" && \
            valid_utc_timestamp "$IOS_EVIDENCE_TESTED_AT" && \
            [[ "$IOS_LOCAL_IPA_PREFLIGHT_READY" == true ]]; then
          IOS_DELIVERY_SUBMITTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_DELIVERY_SUBMITTED_AT" '+%s')"
          IOS_EVIDENCE_PROCESSING_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_EVIDENCE_PROCESSING_AT" '+%s')"
          IOS_EVIDENCE_TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_EVIDENCE_TESTED_AT" '+%s')"
          if (( IOS_DELIVERY_SUBMITTED_EPOCH <= IOS_EVIDENCE_PROCESSING_EPOCH && \
              IOS_EVIDENCE_PROCESSING_EPOCH <= IOS_EVIDENCE_TESTED_EPOCH )); then
            IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY=true
            IOS_TESTFLIGHT_UPLOAD_VERIFIED=true
            IOS_TESTFLIGHT_PROCESSING_VERIFIED=true
            IOS_TESTFLIGHT_INSTALL_VERIFIED=true
            IOS_TESTFLIGHT_IPA_SHA256="$IOS_EVIDENCE_IPA_SHA"
            IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID="$IOS_EVIDENCE_BUILD_ID"
          fi
        fi
      fi
    fi
  fi
fi
if [[ "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true && \
    "$IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256" == "$IOS_TESTFLIGHT_IPA_SHA256" ]]; then
  IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=true
fi

IOS_PROJECT_PATH="$IOS_XCODE_PROJECT/project.pbxproj"
IOS_PROJECT=false
[[ -f "$IOS_PROJECT_PATH" ]] && IOS_PROJECT=true
IOS_PRIVACY_MANIFEST=false
if [[ -f "$PROJECT_DIR/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy" && \
    -f "$PROJECT_DIR/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy" ]]; then
  IOS_PRIVACY_MANIFEST=true
fi
IOS_APP_ICON=false
[[ -f "$PROJECT_DIR/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/ios-marketing.png" ]] && IOS_APP_ICON=true
IOS_SYNC_IMPLEMENTED=false
if /usr/bin/grep -Rqs --include='*.swift' 'CKContainer\|CloudKitSnapshotProvider\|HTTPSAgentSnapshotProvider' \
  "$PROJECT_DIR/ApplePlatforms/iOS/App" 2>/dev/null; then
  IOS_SYNC_IMPLEMENTED=true
fi

# Keep Mac App Store readiness independent from Developer ID distribution.
# Static source markers are only diagnostics: target readiness is established
# from one named Xcode scheme, its real build settings, and that target's build
# phases. Functional submission additionally requires exact-build evidence.
MAC_APP_STORE_PROJECT="${AGENT_ISLAND_MAC_APP_STORE_PROJECT:-$PROJECT_DIR/ApplePlatforms/macOS/AgentIslandMac.xcodeproj}"
MAC_APP_STORE_SCHEME="${AGENT_ISLAND_MAC_APP_STORE_SCHEME:-AgentIslandMac}"
MAC_APP_STORE_RECORD_MODE="${AGENT_ISLAND_APP_STORE_RECORD_MODE:-}"
MAC_APP_STORE_RELEASE_METADATA="${AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA:-}"
MAC_APP_STORE_RECORD_MODE_READY=false
MAC_UNIVERSAL_PURCHASE_BUNDLE_IDS_MATCH=false
MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID=false
if [[ -n "$MAC_BUNDLE_ID" && "$MAC_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID" ]]; then
  MAC_UNIVERSAL_PURCHASE_BUNDLE_IDS_MATCH=true
fi
if [[ "$MAC_APP_STORE_RECORD_MODE" == "universal-purchase" ]]; then
  MAC_APP_STORE_RECORD_MODE_READY=true
  [[ "$MAC_BUNDLE_READY" == true && "$IOS_APP_BUNDLE_READY" == true && \
    "$MAC_UNIVERSAL_PURCHASE_BUNDLE_IDS_MATCH" == true ]] && \
    MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID=true
elif [[ "$MAC_APP_STORE_RECORD_MODE" == "separate-records" ]]; then
  MAC_APP_STORE_RECORD_MODE_READY=true
  if [[ "$MAC_BUNDLE_READY" == true && "$IOS_APP_BUNDLE_READY" == true && \
      "$MAC_BUNDLE_ID" != "$IOS_APP_BUNDLE_ID" ]]; then
    MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID=true
  fi
fi

MAC_APP_STORE_VALIDATOR="$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-project.sh"
MAC_APP_STORE_STATIC_PROJECT_VALIDATION=false
if [[ -x "$MAC_APP_STORE_VALIDATOR" ]] && "$MAC_APP_STORE_VALIDATOR" >/dev/null 2>&1; then
  MAC_APP_STORE_STATIC_PROJECT_VALIDATION=true
fi
MAC_APP_STORE_XCODE_PROJECT=false
MAC_APP_STORE_TARGET_MEMBERSHIP=false
MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET=false
MAC_APP_STORE_BUILD_SETTINGS_MATCH=false
MAC_PRIVACY_MANIFEST_IN_APP_TARGET=false
MAC_APP_STORE_INFO_PLIST_CONFIGURED=false
MAC_APP_SANDBOX_ENTITLEMENT=false
MAC_USER_SELECTED_READ_ONLY_ENTITLEMENT=false
MAC_APP_SCOPE_BOOKMARK_ENTITLEMENT=false
MAC_NETWORK_CLIENT_ENTITLEMENT=false
MAC_APP_STORE_CLOUDKIT_ENTITLEMENT=false
MAC_APP_STORE_ENTITLEMENTS_READY=false
MAC_APP_STORE_ENTITLEMENTS_PATH=""
MAC_APP_STORE_INFO_PLIST_PATH=""
MAC_APP_STORE_TARGET_NAME=""

MAC_PROJECT_FILE="$MAC_APP_STORE_PROJECT/project.pbxproj"
MAC_BUILD_SETTINGS_JSON="$READINESS_ROOT/mac-app-store-build-settings.json"
MAC_PROJECT_JSON="$READINESS_ROOT/mac-app-store-project.json"
if [[ "$FULL_XCODE" == true && -f "$MAC_PROJECT_FILE" && -n "$MAC_APP_STORE_SCHEME" ]] && \
    /usr/bin/xcodebuild -project "$MAC_APP_STORE_PROJECT" -scheme "$MAC_APP_STORE_SCHEME" \
      -configuration Release -showBuildSettings -json >"$MAC_BUILD_SETTINGS_JSON" 2>/dev/null; then
  MAC_APP_SETTINGS_COUNT="$(/usr/bin/jq '[.[] | select(
    .buildSettings.WRAPPER_EXTENSION == "app" and
    .buildSettings.PLATFORM_NAME == "macosx"
  )] | length' "$MAC_BUILD_SETTINGS_JSON")"
  if [[ "$MAC_APP_SETTINGS_COUNT" == "1" ]]; then
    MAC_APP_STORE_XCODE_PROJECT=true
    MAC_APP_STORE_TARGET_NAME="$(/usr/bin/jq -r '.[] | select(
      .buildSettings.WRAPPER_EXTENSION == "app" and
      .buildSettings.PLATFORM_NAME == "macosx"
    ) | .target' "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_BUNDLE_ID="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.PRODUCT_BUNDLE_IDENTIFIER // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_TEAM="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.DEVELOPMENT_TEAM // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_DISPLAY_NAME="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.AGENT_ISLAND_DISPLAY_NAME // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_CONTAINER_ID="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.AGENT_ISLAND_ICLOUD_CONTAINER_ID // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_PRIVACY_URL="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.AGENT_ISLAND_PRIVACY_POLICY_URL // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_SUPPORT_URL="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.AGENT_ISLAND_SUPPORT_URL // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_MARKETING_VERSION="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.MARKETING_VERSION // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_BUILD_NUMBER="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.CURRENT_PROJECT_VERSION // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_SRCROOT="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.SRCROOT // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_ENTITLEMENTS="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.CODE_SIGN_ENTITLEMENTS // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    MAC_SETTINGS_INFO_PLIST="$(/usr/bin/jq -r --arg target "$MAC_APP_STORE_TARGET_NAME" \
      '.[] | select(.target == $target) | .buildSettings.INFOPLIST_FILE // ""' \
      "$MAC_BUILD_SETTINGS_JSON")"
    if [[ "$MAC_SETTINGS_BUNDLE_ID" == "$MAC_BUNDLE_ID" && \
        "$MAC_SETTINGS_TEAM" == "$CONFIGURED_TEAM_ID" && \
        "$MAC_SETTINGS_DISPLAY_NAME" == "$DISPLAY_NAME" && \
        "$MAC_SETTINGS_CONTAINER_ID" == "$CLOUDKIT_CONTAINER_ID" && \
        "$MAC_SETTINGS_PRIVACY_URL" == "$RELEASE_PRIVACY_URL" && \
        "$MAC_SETTINGS_SUPPORT_URL" == "$RELEASE_SUPPORT_URL" && \
        "$MAC_SETTINGS_MARKETING_VERSION" == "$MAC_CONFIG_MARKETING_VERSION" && \
        "$MAC_SETTINGS_BUILD_NUMBER" == "$MAC_CONFIG_BUILD_NUMBER" ]]; then
      MAC_APP_STORE_BUILD_SETTINGS_MATCH=true
    fi
    [[ -n "$MAC_SETTINGS_MARKETING_VERSION" ]] && \
      MAC_MARKETING_VERSION="$MAC_SETTINGS_MARKETING_VERSION"
    [[ -n "$MAC_SETTINGS_BUILD_NUMBER" ]] && MAC_BUILD_NUMBER="$MAC_SETTINGS_BUILD_NUMBER"
    if [[ "$MAC_SETTINGS_ENTITLEMENTS" == /* ]]; then
      MAC_APP_STORE_ENTITLEMENTS_PATH="$MAC_SETTINGS_ENTITLEMENTS"
    elif [[ -n "$MAC_SETTINGS_SRCROOT" && -n "$MAC_SETTINGS_ENTITLEMENTS" ]]; then
      MAC_APP_STORE_ENTITLEMENTS_PATH="$MAC_SETTINGS_SRCROOT/$MAC_SETTINGS_ENTITLEMENTS"
    fi
    if [[ "$MAC_SETTINGS_INFO_PLIST" == /* ]]; then
      MAC_APP_STORE_INFO_PLIST_PATH="$MAC_SETTINGS_INFO_PLIST"
    elif [[ -n "$MAC_SETTINGS_SRCROOT" && -n "$MAC_SETTINGS_INFO_PLIST" ]]; then
      MAC_APP_STORE_INFO_PLIST_PATH="$MAC_SETTINGS_SRCROOT/$MAC_SETTINGS_INFO_PLIST"
    fi
  fi

  if [[ -n "$MAC_APP_STORE_TARGET_NAME" ]] && \
      /usr/bin/plutil -convert json -o "$MAC_PROJECT_JSON" "$MAC_PROJECT_FILE" >/dev/null 2>&1; then
    MAC_TARGET_MEMBERSHIP_JSON="$(/usr/bin/jq -c --arg target "$MAC_APP_STORE_TARGET_NAME" '
        .objects as $objects
        | ($objects | to_entries[]
          | select(.value.isa == "PBXNativeTarget"
            and .value.name == $target
            and .value.productType == "com.apple.product-type.application").value) as $app
        | def members($phaseType):
            [$app.buildPhases[]? as $phaseID
              | $objects[$phaseID]
              | select(.isa == $phaseType)
              | .files[]? as $buildFileID
              | $objects[$buildFileID].fileRef as $fileRefID
              | ($objects[$fileRefID].path // $objects[$fileRefID].name // "")];
          (members("PBXSourcesBuildPhase")) as $sources
          | (members("PBXResourcesBuildPhase")) as $resources
          | (members("PBXCopyFilesBuildPhase")) as $copiedResources
          | {
              nativeSource: ($sources | any(endswith("AgentIsland.m"))),
              privacyManifest: ($resources | any(endswith("PrivacyInfo.xcprivacy"))),
              webInterface: (($resources + $copiedResources) | any(endswith("index.html"))),
              appIcon: ($resources | any(endswith("AgentIsland.icns"))),
              notices: ($resources | any(endswith("THIRD_PARTY_NOTICES.md")))
            }
      ' "$MAC_PROJECT_JSON" 2>/dev/null || print '{}')"
    print -r -- "$MAC_TARGET_MEMBERSHIP_JSON" | /usr/bin/jq -e '.privacyManifest == true' >/dev/null 2>&1 && \
      MAC_PRIVACY_MANIFEST_IN_APP_TARGET=true
    if print -r -- "$MAC_TARGET_MEMBERSHIP_JSON" | /usr/bin/jq -e '
        .webInterface == true and .appIcon == true and .notices == true
      ' >/dev/null 2>&1; then
      MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET=true
    fi
    if print -r -- "$MAC_TARGET_MEMBERSHIP_JSON" | /usr/bin/jq -e '
        .nativeSource == true and .privacyManifest == true and
        .webInterface == true and .appIcon == true and .notices == true
      ' >/dev/null 2>&1; then
      MAC_APP_STORE_TARGET_MEMBERSHIP=true
    fi
  fi
fi

if [[ -n "$MAC_APP_STORE_INFO_PLIST_PATH" && -f "$MAC_APP_STORE_INFO_PLIST_PATH" ]] && \
    /usr/bin/plutil -lint "$MAC_APP_STORE_INFO_PLIST_PATH" >/dev/null 2>&1; then
  MAC_INFO_DISPLAY_NAME="$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$MAC_APP_STORE_INFO_PLIST_PATH" 2>/dev/null || true)"
  MAC_INFO_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$MAC_APP_STORE_INFO_PLIST_PATH" 2>/dev/null || true)"
  MAC_INFO_PRIVACY_URL="$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw -o - "$MAC_APP_STORE_INFO_PLIST_PATH" 2>/dev/null || true)"
  MAC_INFO_SUPPORT_URL="$(/usr/bin/plutil -extract AgentIslandSupportURL raw -o - "$MAC_APP_STORE_INFO_PLIST_PATH" 2>/dev/null || true)"
  if [[ ( "$MAC_INFO_DISPLAY_NAME" == "$DISPLAY_NAME" || "$MAC_INFO_DISPLAY_NAME" == '$(AGENT_ISLAND_DISPLAY_NAME)' ) && \
      ( "$MAC_INFO_EXECUTABLE" == "AgentIsland" || "$MAC_INFO_EXECUTABLE" == '$(EXECUTABLE_NAME)' ) && \
      ( "$MAC_INFO_PRIVACY_URL" == "$RELEASE_PRIVACY_URL" || "$MAC_INFO_PRIVACY_URL" == '$(AGENT_ISLAND_PRIVACY_POLICY_URL)' ) && \
      ( "$MAC_INFO_SUPPORT_URL" == "$RELEASE_SUPPORT_URL" || "$MAC_INFO_SUPPORT_URL" == '$(AGENT_ISLAND_SUPPORT_URL)' ) ]]; then
    MAC_APP_STORE_INFO_PLIST_CONFIGURED=true
  fi
fi

if [[ -n "$MAC_APP_STORE_ENTITLEMENTS_PATH" && -f "$MAC_APP_STORE_ENTITLEMENTS_PATH" ]] && \
    /usr/bin/plutil -lint "$MAC_APP_STORE_ENTITLEMENTS_PATH" >/dev/null 2>&1; then
  MAC_ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - \
    "$MAC_APP_STORE_ENTITLEMENTS_PATH" 2>/dev/null || print '{}')"
  print -r -- "$MAC_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
    '."com.apple.security.app-sandbox" == true' >/dev/null 2>&1 && MAC_APP_SANDBOX_ENTITLEMENT=true
  print -r -- "$MAC_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
    '."com.apple.security.files.user-selected.read-only" == true' >/dev/null 2>&1 && MAC_USER_SELECTED_READ_ONLY_ENTITLEMENT=true
  print -r -- "$MAC_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
    '."com.apple.security.files.bookmarks.app-scope" == true' >/dev/null 2>&1 && MAC_APP_SCOPE_BOOKMARK_ENTITLEMENT=true
  print -r -- "$MAC_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
    '."com.apple.security.network.client" == true' >/dev/null 2>&1 && MAC_NETWORK_CLIENT_ENTITLEMENT=true
  print -r -- "$MAC_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
    --arg container "$CLOUDKIT_CONTAINER_ID" '
      ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null)
      and (((."com.apple.developer.icloud-container-identifiers" // []) == [$container])
        or ((."com.apple.developer.icloud-container-identifiers" // [])
          == ["$(AGENT_ISLAND_ICLOUD_CONTAINER_ID)"]))
      and (."com.apple.developer.icloud-container-environment" == "Production")
    ' >/dev/null 2>&1 && MAC_APP_STORE_CLOUDKIT_ENTITLEMENT=true
  if [[ "$MAC_APP_SANDBOX_ENTITLEMENT" == true && \
      "$MAC_USER_SELECTED_READ_ONLY_ENTITLEMENT" == true && \
      "$MAC_APP_SCOPE_BOOKMARK_ENTITLEMENT" == true && \
      "$MAC_NETWORK_CLIENT_ENTITLEMENT" == true && \
      "$MAC_APP_STORE_CLOUDKIT_ENTITLEMENT" == true ]]; then
    MAC_APP_STORE_ENTITLEMENTS_READY=true
  fi
fi

# These source-string checks expose current migration work but never establish
# readiness by themselves; comments or dead code must not be accepted as proof.
MAC_SECURITY_SCOPED_BOOKMARK_MARKERS=false
MAC_BOOKMARK_MARKERS_PRESENT=true
for MAC_BOOKMARK_MARKER in \
    'bookmarkDataWithOptions' 'URLByResolvingBookmarkData' \
    'startAccessingSecurityScopedResource' 'stopAccessingSecurityScopedResource'; do
  /usr/bin/grep -Fq "$MAC_BOOKMARK_MARKER" "$PROJECT_DIR/Native/AgentIsland.m" 2>/dev/null \
    || MAC_BOOKMARK_MARKERS_PRESENT=false
done
[[ "$MAC_BOOKMARK_MARKERS_PRESENT" == true ]] && MAC_SECURITY_SCOPED_BOOKMARK_MARKERS=true

MAC_AUTOMATIC_HOME_SCAN_MARKERS=false
for MAC_HOME_SCAN_MARKER in \
    'stringByAppendingPathComponent:@".codex"' \
    'stringByAppendingPathComponent:@".claude/projects"' \
    'Library/Application Support/Code/User/globalStorage/agent-host.db' \
    'stringByAppendingPathComponent:@".vscode/extensions/extensions.json"' \
    'stringByAppendingPathComponent:@".cursor/extensions/extensions.json"' \
    'stringByAppendingPathComponent:@".windsurf/extensions/extensions.json"' \
    'Library/Application Support/Cursor' 'Library/Application Support/Windsurf' \
    'Library/Application Support/Zed' 'stringByAppendingPathComponent:@".config/zed"'; do
  if /usr/bin/grep -Fq "$MAC_HOME_SCAN_MARKER" "$PROJECT_DIR/Native/AgentIsland.m" 2>/dev/null; then
    MAC_AUTOMATIC_HOME_SCAN_MARKERS=true
    break
  fi
done

MAC_PRIVACY_SOURCE_READY=false
APP_PRIVACY_RELEASE_EVIDENCE_READY=false
MAC_PRIVACY_RELEASE_EVIDENCE_READY=false
IOS_PRIVACY_RELEASE_EVIDENCE_READY=false
MAC_PRIVACY_VALIDATION_JSON="$READINESS_ROOT/app-privacy-validation.json"
if node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" >"$MAC_PRIVACY_VALIDATION_JSON" 2>/dev/null; then
  /usr/bin/jq -e '.sourcePrivacyReady == true' "$MAC_PRIVACY_VALIDATION_JSON" >/dev/null 2>&1 && \
    MAC_PRIVACY_SOURCE_READY=true
  /usr/bin/jq -e '.releaseEvidenceReady == true' "$MAC_PRIVACY_VALIDATION_JSON" >/dev/null 2>&1 && \
    APP_PRIVACY_RELEASE_EVIDENCE_READY=true
fi

# App Privacy is submitted per App Store record/build. A globally valid
# evidence document is therefore only source material: readiness additionally
# requires one archive entry whose platform, bundle/version/build tuple, and
# immutable upload-artifact fingerprint all match the exact candidate above.
privacy_evidence_matches_candidate() {
  local platform="$1"
  local distribution="$2"
  local bundle="$3"
  local version="$4"
  local build="$5"
  local artifact_sha="$6"
  [[ "$APP_PRIVACY_RELEASE_EVIDENCE_READY" == true ]] || return 1
  [[ "$MAC_APP_STORE_RECORD_MODE" == "universal-purchase" || \
      "$MAC_APP_STORE_RECORD_MODE" == "separate-records" ]] || return 1
  /usr/bin/jq -e \
    --arg platform "$platform" \
    --arg distribution "$distribution" \
    --arg bundle "$bundle" \
    --arg version "$version" \
    --arg build "$build" \
    --arg artifactSHA "$artifact_sha" \
    --arg recordScope "$MAC_APP_STORE_RECORD_MODE" '
      .releaseEvidenceReady == true and
      .releaseEvidence.recordScope == $recordScope and
      ([.releaseEvidence.archives[]? | select(
        .platform == $platform and .distribution == $distribution and
        .bundleID == $bundle and .version == $version and .build == $build and
        .sha256 == $artifactSHA
      )] | length) == 1
    ' "$MAC_PRIVACY_VALIDATION_JSON" >/dev/null 2>&1
}

if [[ "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true ]] && \
    privacy_evidence_matches_candidate \
      "iOS" "app-store" "$IOS_APP_BUNDLE_ID" "$IOS_MARKETING_VERSION" \
      "$IOS_BUILD_NUMBER" "$IOS_TESTFLIGHT_IPA_SHA256"; then
  IOS_PRIVACY_RELEASE_EVIDENCE_READY=true
fi
STORE_SUBMISSION_ASSETS_READY=false
if node "$PROJECT_DIR/scripts/validate-store-submission.mjs" --release >/dev/null 2>&1; then
  STORE_SUBMISSION_ASSETS_READY=true
fi

# Bind Mac App Store QA claims to the exact locally exported candidate instead
# of accepting free-standing booleans. The metadata and both uploadable/local
# artifacts must still exist inside one dist release directory and retain the
# SHA-256 values written by the release script.
MAC_APP_STORE_RELEASE_METADATA_CONFIGURED=false
MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY=false
MAC_APP_STORE_ARCHIVE_ZIP_SHA256=""
MAC_APP_STORE_PACKAGE_SHA256=""
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256="${AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256:-}"
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256="${AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256:-}"
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=false
if [[ -n "$MAC_APP_STORE_RELEASE_METADATA" ]]; then
  MAC_APP_STORE_RELEASE_METADATA_CONFIGURED=true
  if [[ "$MAC_APP_STORE_RELEASE_METADATA" == /* && \
      -f "$MAC_APP_STORE_RELEASE_METADATA" && ! -L "$MAC_APP_STORE_RELEASE_METADATA" ]]; then
    MAC_CANDIDATE_METADATA_PATH="${MAC_APP_STORE_RELEASE_METADATA:A}"
    MAC_CANDIDATE_DIRECTORY="${MAC_CANDIDATE_METADATA_PATH:h}"
    if [[ "$MAC_CANDIDATE_METADATA_PATH" == \
        "$PROJECT_DIR"/dist/macos-app-store/*/release-metadata.json && \
        ! -L "$MAC_CANDIDATE_DIRECTORY" ]]; then
      MAC_CANDIDATE_ARCHIVE_ZIP="$(/usr/bin/jq -r '.archiveZip // ""' \
        "$MAC_CANDIDATE_METADATA_PATH" 2>/dev/null || true)"
      MAC_CANDIDATE_ARCHIVE_SHA="$(/usr/bin/jq -r '.archiveZipSHA256 // ""' \
        "$MAC_CANDIDATE_METADATA_PATH" 2>/dev/null || true)"
      MAC_CANDIDATE_PACKAGE="$(/usr/bin/jq -r '.exportedPackage // ""' \
        "$MAC_CANDIDATE_METADATA_PATH" 2>/dev/null || true)"
      MAC_CANDIDATE_PACKAGE_SHA="$(/usr/bin/jq -r '.packageSHA256 // ""' \
        "$MAC_CANDIDATE_METADATA_PATH" 2>/dev/null || true)"
      if [[ "$MAC_CANDIDATE_ARCHIVE_ZIP" == "$MAC_CANDIDATE_DIRECTORY"/* && \
          "$MAC_CANDIDATE_PACKAGE" == "$MAC_CANDIDATE_DIRECTORY"/* && \
          -f "$MAC_CANDIDATE_ARCHIVE_ZIP" && ! -L "$MAC_CANDIDATE_ARCHIVE_ZIP" && \
          -f "$MAC_CANDIDATE_PACKAGE" && ! -L "$MAC_CANDIDATE_PACKAGE" && \
          "$MAC_CANDIDATE_ARCHIVE_SHA" == [0-9a-f]## && \
          ${#MAC_CANDIDATE_ARCHIVE_SHA} -eq 64 && \
          "$MAC_CANDIDATE_PACKAGE_SHA" == [0-9a-f]## && \
          ${#MAC_CANDIDATE_PACKAGE_SHA} -eq 64 && \
          "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$MAC_CANDIDATE_ARCHIVE_ZIP" | /usr/bin/awk '{print $1}')" == "$MAC_CANDIDATE_ARCHIVE_SHA" && \
          "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$MAC_CANDIDATE_PACKAGE" | /usr/bin/awk '{print $1}')" == "$MAC_CANDIDATE_PACKAGE_SHA" ]] && \
          /usr/bin/jq -e \
            --arg bundle "$MAC_BUNDLE_ID" \
            --arg team "$CONFIGURED_TEAM_ID" \
            --arg displayName "$DISPLAY_NAME" \
            --arg version "$MAC_MARKETING_VERSION" \
            --arg build "$MAC_BUILD_NUMBER" \
            --arg container "$CLOUDKIT_CONTAINER_ID" \
            --arg privacyURL "$RELEASE_PRIVACY_URL" \
            --arg supportURL "$RELEASE_SUPPORT_URL" \
            --arg archiveZip "$MAC_CANDIDATE_ARCHIVE_ZIP" \
            --arg archiveSHA "$MAC_CANDIDATE_ARCHIVE_SHA" \
            --arg package "$MAC_CANDIDATE_PACKAGE" \
            --arg packageSHA "$MAC_CANDIDATE_PACKAGE_SHA" '
              .schemaVersion == 1 and .platform == "macOS" and
              .distribution == "mac-app-store" and .uploaded == false and
              .appBundleID == $bundle and .teamID == $team and
              .displayName == $displayName and .cloudContainerID == $container and
              .version == $version and .build == $build and
              .privacyPolicyURL == $privacyURL and .supportURL == $supportURL and
              .archiveZip == $archiveZip and .archiveZipSHA256 == $archiveSHA and
              .exportedPackage == $package and .packageSHA256 == $packageSHA and
              .exportMethod == "app-store-connect" and .exportDestination == "export" and
              .provisioningProfile.certificateMatches == true
            ' "$MAC_CANDIDATE_METADATA_PATH" >/dev/null 2>&1; then
        MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY=true
        MAC_APP_STORE_ARCHIVE_ZIP_SHA256="$MAC_CANDIDATE_ARCHIVE_SHA"
        MAC_APP_STORE_PACKAGE_SHA256="$MAC_CANDIDATE_PACKAGE_SHA"
      fi
    fi
  fi
fi

MAC_PRIVACY_CANDIDATE_SHA256="$MAC_APP_STORE_PACKAGE_SHA256"
[[ -n "$MAC_PRIVACY_CANDIDATE_SHA256" ]] || \
  MAC_PRIVACY_CANDIDATE_SHA256="$MAC_APP_STORE_ARCHIVE_ZIP_SHA256"
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true ]] && \
    privacy_evidence_matches_candidate \
      "macOS" "mac-app-store" "$MAC_BUNDLE_ID" "$MAC_MARKETING_VERSION" \
      "$MAC_BUILD_NUMBER" "$MAC_PRIVACY_CANDIDATE_SHA256"; then
  MAC_PRIVACY_RELEASE_EVIDENCE_READY=true
fi

# A human QA claim is accepted only when both supplied fingerprints identify
# the same immutable Archive ZIP and installer package that passed the metadata
# contract above. This prevents a leftover `true` environment variable from
# carrying forward to a rebuilt candidate.
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    -n "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256" && \
    -n "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256" && \
    "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256" == "$MAC_APP_STORE_ARCHIVE_ZIP_SHA256" && \
    "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256" == "$MAC_APP_STORE_PACKAGE_SHA256" ]]; then
  MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=true
fi

MAC_APP_STORE_SANDBOX_FLOW_VERIFIED=false
MAC_APP_STORE_ARCHIVE_VERIFIED=false
MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED=false
MAC_APP_STORE_PRIVACY_REPORT_VERIFIED=false
MAC_APP_STORE_REVIEW_PATH_VERIFIED=false
if [[ "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" == true ]]; then
  [[ "${AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED:-false}" == "true" ]] && MAC_APP_STORE_SANDBOX_FLOW_VERIFIED=true
  [[ "${AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED:-false}" == "true" ]] && MAC_APP_STORE_ARCHIVE_VERIFIED=true
  [[ "${AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED:-false}" == "true" ]] && MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED=true
  [[ "${AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED:-false}" == "true" ]] && MAC_APP_STORE_PRIVACY_REPORT_VERIFIED=true
  [[ "${AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED:-false}" == "true" ]] && MAC_APP_STORE_REVIEW_PATH_VERIFIED=true
fi

NOTARY_PROFILE_CONFIGURED=false
[[ -n "$NOTARY_PROFILE" ]] && NOTARY_PROFILE_CONFIGURED=true
MAC_DEVELOPER_ID_TOOLCHAIN=false
MACOS_SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
MAC_RELEASE_TOOLS_PRESENT=true
for MAC_RELEASE_TOOL in clang notarytool stapler; do
  /usr/bin/xcrun --find "$MAC_RELEASE_TOOL" >/dev/null 2>&1 || MAC_RELEASE_TOOLS_PRESENT=false
done
for MAC_RELEASE_TOOL_PATH in \
    /usr/bin/codesign /usr/bin/ditto /usr/bin/jq /usr/bin/lipo \
    /usr/bin/plutil /usr/bin/security /usr/bin/shasum /usr/sbin/spctl; do
  [[ -x "$MAC_RELEASE_TOOL_PATH" ]] || MAC_RELEASE_TOOLS_PRESENT=false
done
if [[ -n "$MACOS_SDK_PATH" && -d "$MACOS_SDK_PATH" && "$MAC_RELEASE_TOOLS_PRESENT" == true ]]; then
  MAC_DEVELOPER_ID_TOOLCHAIN=true
fi
CURRENT_UPLOAD_TOOLCHAIN=false
(( XCODE_MAJOR >= 26 && IPHONE_SDK_MAJOR >= 26 )) && CURRENT_UPLOAD_TOOLCHAIN=true
CURRENT_MAC_APP_STORE_TOOLCHAIN=false
(( XCODE_MAJOR >= 26 )) && CURRENT_MAC_APP_STORE_TOOLCHAIN=true
ENOUGH_DISK_FOR_XCODE=false
(( AVAILABLE_GIB >= 30 )) && ENOUGH_DISK_FOR_XCODE=true

READY_DEVELOPER_ID=false
if [[ "$MAC_DEVELOPER_ID_TOOLCHAIN" == true && "$DEVELOPER_ID_IDENTITIES" -gt 0 && "$MAC_SIGN_IDENTITY_READY" == true && "$MAC_BUNDLE_READY" == true && \
  "$DISPLAY_NAME_READY" == true && "$MAC_ARCHIVE_SET_CLEAN" == true && \
  "$NOTARY_PROFILE_CONFIGURED" == true && "$ENTITLEMENTS_READY" == true && \
  "$PROVISIONING_PROFILE_READY" == true && "$PROVISIONING_PROFILE_CERTIFICATE_READY" == true && \
  "$CLOUDKIT_CONTAINER_READY" == true && "$RELEASE_PRIVACY_READY" == true && \
  "$RELEASE_SUPPORT_READY" == true && "$CONFIGURED_TEAM_READY" == true ]]; then
  READY_DEVELOPER_ID=true
fi

READY_IOS_ARCHIVE=false
if [[ "$FULL_XCODE" == true && "$CURRENT_UPLOAD_TOOLCHAIN" == true && "$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY" == true && \
  "$IOS_PROJECT" == true && "$IOS_PROJECT_RELEASE_VALIDATION" == true && \
  "$IOS_BUILD_SETTINGS_RESOLVED" == true && "$IOS_TARGET_BUILD_SETTINGS_CONFIGURED" == true && \
  "$IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED" == true && "$IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT" == true && \
  "$IOS_PRIVACY_MANIFEST" == true && "$IOS_APP_ICON" == true && \
  "$IOS_APP_BUNDLE_READY" == true && "$IOS_WIDGET_BUNDLE_READY" == true && "$IOS_TEAM_READY" == true && \
  "$IOS_CONTAINER_READY" == true && "$IOS_PRIVACY_READY" == true && "$IOS_SUPPORT_READY" == true ]]; then
  READY_IOS_ARCHIVE=true
fi

READY_MAC_APP_STORE_ARCHIVE=false
if [[ "$FULL_XCODE" == true && "$CURRENT_MAC_APP_STORE_TOOLCHAIN" == true && \
    "$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY" == true && \
    "$MAC_APP_STORE_STATIC_PROJECT_VALIDATION" == true && "$MAC_APP_STORE_XCODE_PROJECT" == true && \
    "$MAC_APP_STORE_TARGET_MEMBERSHIP" == true && "$MAC_APP_STORE_BUILD_SETTINGS_MATCH" == true && \
    "$MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET" == true && "$MAC_APP_STORE_INFO_PLIST_CONFIGURED" == true && \
    "$MAC_PRIVACY_MANIFEST_IN_APP_TARGET" == true && "$MAC_PRIVACY_SOURCE_READY" == true && \
    "$MAC_APP_STORE_ENTITLEMENTS_READY" == true && "$MAC_APP_STORE_RECORD_MODE_READY" == true && \
    "$MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID" == true && \
    "$MAC_BUNDLE_READY" == true && "$DISPLAY_NAME_READY" == true && "$CONFIGURED_TEAM_READY" == true && \
    "$CLOUDKIT_CONTAINER_READY" == true && "$RELEASE_PRIVACY_READY" == true && \
    "$RELEASE_SUPPORT_READY" == true ]]; then
  READY_MAC_APP_STORE_ARCHIVE=true
fi

READY_MAC_APP_STORE_UPLOAD=false
if [[ "$READY_MAC_APP_STORE_ARCHIVE" == true && \
    "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" == true && \
    "$MAC_APP_STORE_SANDBOX_FLOW_VERIFIED" == true && \
    "$MAC_APP_STORE_ARCHIVE_VERIFIED" == true && \
    "$MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED" == true && \
    "$MAC_APP_STORE_PRIVACY_REPORT_VERIFIED" == true && \
    "$MAC_APP_STORE_REVIEW_PATH_VERIFIED" == true && \
    "$IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED" == true && \
    "$MAC_PRIVACY_RELEASE_EVIDENCE_READY" == true && \
    "$STORE_SUBMISSION_ASSETS_READY" == true ]]; then
  READY_MAC_APP_STORE_UPLOAD=true
fi

# Compatibility only. This repository deliberately has no macOS delivery and
# App Store Connect processing evidence chain yet, so it must never claim that
# an `uploaded: false` local artifact is ready for review submission.
READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=false

/usr/bin/jq -n \
  --arg developerPath "$DEVELOPER_PATH" \
  --arg xcodeVersion "$XCODE_VERSION" \
  --arg iphoneSDK "$IPHONE_SDK" \
  --arg macBundleID "$MAC_BUNDLE_ID" \
  --arg displayName "$DISPLAY_NAME" \
  --arg iosAppBundleID "$IOS_APP_BUNDLE_ID" \
  --arg iosWidgetBundleID "$IOS_WIDGET_BUNDLE_ID" \
  --arg iosDevelopmentTeam "$IOS_TEAM_ID" \
  --arg iosCloudKitContainer "$IOS_CONTAINER_ID" \
  --arg iosDisplayName "$IOS_DISPLAY_NAME" \
  --arg iosMarketingVersion "$IOS_MARKETING_VERSION" \
  --arg iosBuildNumber "$IOS_BUILD_NUMBER" \
  --arg macMarketingVersion "$MAC_MARKETING_VERSION" \
  --arg macBuildNumber "$MAC_BUILD_NUMBER" \
  --arg iosTestFlightVerificationEvidencePath "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" \
  --arg iosFunctionalEvidenceIPASHA256 "$IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256" \
  --arg iosTestFlightIPASHA256 "$IOS_TESTFLIGHT_IPA_SHA256" \
  --arg iosTestFlightAppStoreConnectBuildID "$IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID" \
  --arg iosXcodeProject "$IOS_XCODE_PROJECT" \
  --arg iosXcodeScheme "$IOS_XCODE_SCHEME" \
  --arg macAppStoreProject "$MAC_APP_STORE_PROJECT" \
  --arg macAppStoreScheme "$MAC_APP_STORE_SCHEME" \
  --arg macAppStoreTargetName "$MAC_APP_STORE_TARGET_NAME" \
  --arg macAppStoreEntitlementsPath "$MAC_APP_STORE_ENTITLEMENTS_PATH" \
  --arg macAppStoreInfoPlistPath "$MAC_APP_STORE_INFO_PLIST_PATH" \
  --arg macAppStoreReleaseMetadataPath "$MAC_APP_STORE_RELEASE_METADATA" \
  --arg macAppStoreArchiveZipSHA256 "$MAC_APP_STORE_ARCHIVE_ZIP_SHA256" \
  --arg macAppStorePackageSHA256 "$MAC_APP_STORE_PACKAGE_SHA256" \
  --arg macAppStoreFunctionalEvidenceArchiveSHA256 "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256" \
  --arg macAppStoreFunctionalEvidencePackageSHA256 "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256" \
  --arg appStoreRecordMode "$MAC_APP_STORE_RECORD_MODE" \
  --argjson fullXcode "$FULL_XCODE" \
  --argjson macDeveloperIDToolchain "$MAC_DEVELOPER_ID_TOOLCHAIN" \
  --argjson currentUploadToolchain "$CURRENT_UPLOAD_TOOLCHAIN" \
  --argjson currentMacAppStoreToolchain "$CURRENT_MAC_APP_STORE_TOOLCHAIN" \
  --argjson validIdentities "${VALID_IDENTITIES:-0}" \
  --argjson developerIDIdentities "${DEVELOPER_ID_IDENTITIES:-0}" \
  --argjson developerIDIdentityConfigured "$MAC_SIGN_IDENTITY_READY" \
  --argjson appleDevelopmentIdentities "${APPLE_DEVELOPMENT_IDENTITIES:-0}" \
  --argjson appleDistributionIdentities "${APPLE_DISTRIBUTION_IDENTITIES:-0}" \
  --argjson appleDistributionTeamIdentities "${APPLE_DISTRIBUTION_TEAM_IDENTITIES:-0}" \
  --argjson appleDistributionTeamIdentityConfigured "$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY" \
  --argjson availableGiB "$AVAILABLE_GIB" \
  --argjson enoughDiskForXcode "$ENOUGH_DISK_FOR_XCODE" \
  --argjson macDistributionArchiveSetClean "$MAC_ARCHIVE_SET_CLEAN" \
  --argjson ambiguousMacDistributionArchives "$AMBIGUOUS_MAC_ARCHIVES_JSON" \
  --argjson productionMacBundleID "$MAC_BUNDLE_READY" \
  --argjson productionDisplayName "$DISPLAY_NAME_READY" \
  --argjson productionIOSAppBundleID "$IOS_APP_BUNDLE_READY" \
  --argjson productionIOSWidgetBundleID "$IOS_WIDGET_BUNDLE_READY" \
  --argjson notaryProfileConfigured "$NOTARY_PROFILE_CONFIGURED" \
  --argjson cloudKitEntitlementsConfigured "$ENTITLEMENTS_READY" \
  --argjson cloudKitContainerConfigured "$CLOUDKIT_CONTAINER_READY" \
  --argjson provisioningProfileConfigured "$PROVISIONING_PROFILE_READY" \
  --argjson provisioningProfileSigningCertificateConfigured "$PROVISIONING_PROFILE_CERTIFICATE_READY" \
  --argjson privacyPolicyURLConfigured "$RELEASE_PRIVACY_READY" \
  --argjson supportURLConfigured "$RELEASE_SUPPORT_READY" \
  --argjson iosDevelopmentTeamConfigured "$IOS_TEAM_READY" \
  --argjson iosCloudKitContainerConfigured "$IOS_CONTAINER_READY" \
  --argjson iosPrivacyPolicyURLConfigured "$IOS_PRIVACY_READY" \
  --argjson iosSupportURLConfigured "$IOS_SUPPORT_READY" \
  --argjson cloudKitProductionSchemaVerified "$IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED" \
  --argjson iosRealDeviceSyncVerified "$IOS_REAL_DEVICE_SYNC_VERIFIED" \
  --argjson iosLiveActivityVerified "$IOS_LIVE_ACTIVITY_VERIFIED" \
  --argjson iosReviewPathVerified "$IOS_REVIEW_PATH_VERIFIED" \
  --argjson iosTestFlightUploadVerified "$IOS_TESTFLIGHT_UPLOAD_VERIFIED" \
  --argjson iosTestFlightProcessingVerified "$IOS_TESTFLIGHT_PROCESSING_VERIFIED" \
  --argjson iosTestFlightInstallVerified "$IOS_TESTFLIGHT_INSTALL_VERIFIED" \
  --argjson iosTestFlightEvidenceConfigured "$IOS_TESTFLIGHT_EVIDENCE_CONFIGURED" \
  --argjson iosLocalIPAPreflightPassed "$IOS_LOCAL_IPA_PREFLIGHT_READY" \
  --argjson iosTestFlightExactBuildEvidenceReady "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" \
  --argjson iosFunctionalEvidenceBoundToCandidate "$IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" \
  --argjson iosProject "$IOS_PROJECT" \
  --argjson iosProjectReleaseValidation "$IOS_PROJECT_RELEASE_VALIDATION" \
  --argjson iosBuildSettingsResolved "$IOS_BUILD_SETTINGS_RESOLVED" \
  --argjson iosTargetBuildSettingsConfigured "$IOS_TARGET_BUILD_SETTINGS_CONFIGURED" \
  --argjson iosProductionBuildSettingsConfigured "$IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED" \
  --argjson iosBuildSettingsMatchEnvironment "$IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT" \
  --argjson iosBuildSettingsMismatches "$IOS_BUILD_SETTINGS_MISMATCHES_JSON" \
  --argjson iosPrivacyManifest "$IOS_PRIVACY_MANIFEST" \
  --argjson iosAppIcon "$IOS_APP_ICON" \
  --argjson iosSyncImplemented "$IOS_SYNC_IMPLEMENTED" \
  --argjson macAppStoreStaticProjectValidation "$MAC_APP_STORE_STATIC_PROJECT_VALIDATION" \
  --argjson macAppStoreXcodeProject "$MAC_APP_STORE_XCODE_PROJECT" \
  --argjson macAppStoreTargetMembership "$MAC_APP_STORE_TARGET_MEMBERSHIP" \
  --argjson macAppStoreRuntimeResources "$MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET" \
  --argjson macAppStoreBuildSettingsMatch "$MAC_APP_STORE_BUILD_SETTINGS_MATCH" \
  --argjson macPrivacyManifestInAppTarget "$MAC_PRIVACY_MANIFEST_IN_APP_TARGET" \
  --argjson macAppStoreInfoPlist "$MAC_APP_STORE_INFO_PLIST_CONFIGURED" \
  --argjson macAppSandboxEntitlement "$MAC_APP_SANDBOX_ENTITLEMENT" \
  --argjson macUserSelectedReadOnlyEntitlement "$MAC_USER_SELECTED_READ_ONLY_ENTITLEMENT" \
  --argjson macAppScopeBookmarkEntitlement "$MAC_APP_SCOPE_BOOKMARK_ENTITLEMENT" \
  --argjson macNetworkClientEntitlement "$MAC_NETWORK_CLIENT_ENTITLEMENT" \
  --argjson macAppStoreCloudKitEntitlement "$MAC_APP_STORE_CLOUDKIT_ENTITLEMENT" \
  --argjson macAppStoreEntitlements "$MAC_APP_STORE_ENTITLEMENTS_READY" \
  --argjson macSecurityScopedBookmarkMarkers "$MAC_SECURITY_SCOPED_BOOKMARK_MARKERS" \
  --argjson macAutomaticHomeScanMarkers "$MAC_AUTOMATIC_HOME_SCAN_MARKERS" \
  --argjson macPrivacySourceReady "$MAC_PRIVACY_SOURCE_READY" \
  --argjson appPrivacyReleaseEvidenceReady "$APP_PRIVACY_RELEASE_EVIDENCE_READY" \
  --argjson macPrivacyReleaseEvidenceReady "$MAC_PRIVACY_RELEASE_EVIDENCE_READY" \
  --argjson iosPrivacyReleaseEvidenceReady "$IOS_PRIVACY_RELEASE_EVIDENCE_READY" \
  --argjson storeSubmissionAssetsReady "$STORE_SUBMISSION_ASSETS_READY" \
  --argjson macAppStoreReleaseMetadataConfigured "$MAC_APP_STORE_RELEASE_METADATA_CONFIGURED" \
  --argjson macAppStoreExactCandidateEvidenceReady "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" \
  --argjson macAppStoreFunctionalEvidenceBoundToCandidate "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" \
  --argjson appStoreRecordModeConfigured "$MAC_APP_STORE_RECORD_MODE_READY" \
  --argjson universalPurchaseBundleIDsMatch "$MAC_UNIVERSAL_PURCHASE_BUNDLE_IDS_MATCH" \
  --argjson appStoreRecordModeBundleIDsValid "$MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID" \
  --argjson macAppStoreSandboxFlowVerified "$MAC_APP_STORE_SANDBOX_FLOW_VERIFIED" \
  --argjson macAppStoreArchiveVerified "$MAC_APP_STORE_ARCHIVE_VERIFIED" \
  --argjson macAppStoreProfileCertificateVerified "$MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED" \
  --argjson macAppStorePrivacyReportVerified "$MAC_APP_STORE_PRIVACY_REPORT_VERIFIED" \
  --argjson macAppStoreReviewPathVerified "$MAC_APP_STORE_REVIEW_PATH_VERIFIED" \
  --argjson readyDeveloperID "$READY_DEVELOPER_ID" \
  --argjson readyMacAppStoreArchive "$READY_MAC_APP_STORE_ARCHIVE" \
  --argjson readyMacAppStoreUpload "$READY_MAC_APP_STORE_UPLOAD" \
  --argjson readyFunctionalMacAppStoreSubmission "$READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION" \
  --argjson readyIOSArchive "$READY_IOS_ARCHIVE" \
  '{
    fullXcode: $fullXcode,
    macDeveloperIDToolchainConfigured: $macDeveloperIDToolchain,
    developerPath: $developerPath,
    xcodeVersion: (if $xcodeVersion == "" then null else $xcodeVersion end),
    iphoneSDK: (if $iphoneSDK == "" then null else $iphoneSDK end),
    currentUploadToolchain: $currentUploadToolchain,
    currentMacAppStoreToolchain: $currentMacAppStoreToolchain,
    validSigningIdentities: $validIdentities,
    developerIDApplicationIdentities: $developerIDIdentities,
    developerIDIdentityConfigured: $developerIDIdentityConfigured,
    appleDevelopmentIdentities: $appleDevelopmentIdentities,
    appleDistributionIdentities: $appleDistributionIdentities,
    appleDistributionTeamIdentities: $appleDistributionTeamIdentities,
    appleDistributionTeamIdentityConfigured: $appleDistributionTeamIdentityConfigured,
    availableDiskGiB: $availableGiB,
    enoughDiskForXcode: $enoughDiskForXcode,
    macDistributionArchiveSetClean: $macDistributionArchiveSetClean,
    ambiguousMacDistributionArchives: $ambiguousMacDistributionArchives,
    productionBundleIDConfigured: $productionMacBundleID,
    productionBundleID: (if $macBundleID == "" then null else $macBundleID end),
    productionDisplayNameConfigured: $productionDisplayName,
    productionDisplayName: (if $displayName == "" then null else $displayName end),
    iosAppBundleIDConfigured: $productionIOSAppBundleID,
    iosAppBundleID: (if $iosAppBundleID == "" then null else $iosAppBundleID end),
    iosWidgetBundleIDConfigured: $productionIOSWidgetBundleID,
    iosWidgetBundleID: (if $iosWidgetBundleID == "" then null else $iosWidgetBundleID end),
    notaryProfileConfigured: $notaryProfileConfigured,
    cloudKitEntitlementsConfigured: $cloudKitEntitlementsConfigured,
    cloudKitContainerConfigured: $cloudKitContainerConfigured,
    provisioningProfileConfigured: $provisioningProfileConfigured,
    provisioningProfileSigningCertificateConfigured: $provisioningProfileSigningCertificateConfigured,
    privacyPolicyURLConfigured: $privacyPolicyURLConfigured,
    supportURLConfigured: $supportURLConfigured,
    iosDevelopmentTeamConfigured: $iosDevelopmentTeamConfigured,
    iosDevelopmentTeam: (if $iosDevelopmentTeam == "" then null else $iosDevelopmentTeam end),
    iosCloudKitContainerConfigured: $iosCloudKitContainerConfigured,
    iosCloudKitContainer: (if $iosCloudKitContainer == "" then null else $iosCloudKitContainer end),
    iosDisplayName: (if $iosDisplayName == "" then null else $iosDisplayName end),
    iosMarketingVersion: (if $iosMarketingVersion == "" then null else $iosMarketingVersion end),
    iosBuildNumber: (if $iosBuildNumber == "" then null else $iosBuildNumber end),
    macMarketingVersion: (if $macMarketingVersion == "" then null else $macMarketingVersion end),
    macBuildNumber: (if $macBuildNumber == "" then null else $macBuildNumber end),
    iosPrivacyPolicyURLConfigured: $iosPrivacyPolicyURLConfigured,
    iosSupportURLConfigured: $iosSupportURLConfigured,
    cloudKitProductionSchemaVerified: $cloudKitProductionSchemaVerified,
    iosRealDeviceSyncVerified: $iosRealDeviceSyncVerified,
    iosLiveActivityVerified: $iosLiveActivityVerified,
    iosReviewPathVerified: $iosReviewPathVerified,
    iosTestFlightUploadVerified: $iosTestFlightUploadVerified,
    iosTestFlightProcessingVerified: $iosTestFlightProcessingVerified,
    iosTestFlightInstallVerified: $iosTestFlightInstallVerified,
    iosTestFlightEvidenceConfigured: $iosTestFlightEvidenceConfigured,
    iosLocalIPAPreflightPassed: $iosLocalIPAPreflightPassed,
    iosTestFlightVerificationEvidencePath: (if $iosTestFlightVerificationEvidencePath == "" then null else $iosTestFlightVerificationEvidencePath end),
    iosTestFlightExactBuildEvidenceReady: $iosTestFlightExactBuildEvidenceReady,
    iosTestFlightIPASHA256: (if $iosTestFlightIPASHA256 == "" then null else $iosTestFlightIPASHA256 end),
    iosTestFlightAppStoreConnectBuildID: (if $iosTestFlightAppStoreConnectBuildID == "" then null else $iosTestFlightAppStoreConnectBuildID end),
    iosFunctionalEvidenceIPASHA256: (if $iosFunctionalEvidenceIPASHA256 == "" then null else $iosFunctionalEvidenceIPASHA256 end),
    iosFunctionalEvidenceBoundToCandidate: $iosFunctionalEvidenceBoundToCandidate,
    iosProjectConfigured: $iosProject,
    iosProjectPath: $iosXcodeProject,
    iosScheme: $iosXcodeScheme,
    iosProjectReleaseValidationPassed: $iosProjectReleaseValidation,
    iosBuildSettingsResolved: $iosBuildSettingsResolved,
    iosTargetBuildSettingsConfigured: $iosTargetBuildSettingsConfigured,
    iosProductionBuildSettingsConfigured: $iosProductionBuildSettingsConfigured,
    iosBuildSettingsMatchEnvironment: $iosBuildSettingsMatchEnvironment,
    iosBuildSettingsMismatches: $iosBuildSettingsMismatches,
    iosPrivacyManifestPresent: $iosPrivacyManifest,
    iosAppIconPresent: $iosAppIcon,
    iosSyncTransportImplemented: $iosSyncImplemented,
    macAppStoreProjectPath: $macAppStoreProject,
    macAppStoreScheme: $macAppStoreScheme,
    macAppStoreTargetName: (if $macAppStoreTargetName == "" then null else $macAppStoreTargetName end),
    macAppStoreEntitlementsPath: (if $macAppStoreEntitlementsPath == "" then null else $macAppStoreEntitlementsPath end),
    macAppStoreInfoPlistPath: (if $macAppStoreInfoPlistPath == "" then null else $macAppStoreInfoPlistPath end),
    macAppStoreReleaseMetadataPath: (if $macAppStoreReleaseMetadataPath == "" then null else $macAppStoreReleaseMetadataPath end),
    macAppStoreReleaseMetadataConfigured: $macAppStoreReleaseMetadataConfigured,
    macAppStoreExactCandidateEvidenceReady: $macAppStoreExactCandidateEvidenceReady,
    macAppStoreArchiveZipSHA256: (if $macAppStoreArchiveZipSHA256 == "" then null else $macAppStoreArchiveZipSHA256 end),
    macAppStorePackageSHA256: (if $macAppStorePackageSHA256 == "" then null else $macAppStorePackageSHA256 end),
    macAppStoreFunctionalEvidenceArchiveSHA256: (if $macAppStoreFunctionalEvidenceArchiveSHA256 == "" then null else $macAppStoreFunctionalEvidenceArchiveSHA256 end),
    macAppStoreFunctionalEvidencePackageSHA256: (if $macAppStoreFunctionalEvidencePackageSHA256 == "" then null else $macAppStoreFunctionalEvidencePackageSHA256 end),
    macAppStoreFunctionalEvidenceBoundToCandidate: $macAppStoreFunctionalEvidenceBoundToCandidate,
    macAppStoreStaticProjectValidationPassed: $macAppStoreStaticProjectValidation,
    macAppStoreXcodeProjectConfigured: $macAppStoreXcodeProject,
    macAppStoreTargetMembershipConfigured: $macAppStoreTargetMembership,
    macAppStoreRuntimeResourcesInTarget: $macAppStoreRuntimeResources,
    macAppStoreBuildSettingsMatch: $macAppStoreBuildSettingsMatch,
    macPrivacyManifestInAppTarget: $macPrivacyManifestInAppTarget,
    macAppStoreInfoPlistConfigured: $macAppStoreInfoPlist,
    macAppSandboxEntitlementConfigured: $macAppSandboxEntitlement,
    macUserSelectedReadOnlyEntitlementConfigured: $macUserSelectedReadOnlyEntitlement,
    macAppScopeBookmarkEntitlementConfigured: $macAppScopeBookmarkEntitlement,
    macNetworkClientEntitlementConfigured: $macNetworkClientEntitlement,
    macAppStoreCloudKitEntitlementConfigured: $macAppStoreCloudKitEntitlement,
    macAppStoreEntitlementsConfigured: $macAppStoreEntitlements,
    macSecurityScopedBookmarkMarkersPresent: $macSecurityScopedBookmarkMarkers,
    macAutomaticHomeScanMarkersPresent: $macAutomaticHomeScanMarkers,
    macPrivacySourceReady: $macPrivacySourceReady,
    appPrivacyReleaseEvidenceReady: $appPrivacyReleaseEvidenceReady,
    macPrivacyReleaseEvidenceReady: $macPrivacyReleaseEvidenceReady,
    iosPrivacyReleaseEvidenceReady: $iosPrivacyReleaseEvidenceReady,
    storeSubmissionAssetsReady: $storeSubmissionAssetsReady,
    appStoreRecordModeConfigured: $appStoreRecordModeConfigured,
    appStoreRecordMode: (if $appStoreRecordMode == "" then null else $appStoreRecordMode end),
    universalPurchaseBundleIDsMatch: $universalPurchaseBundleIDsMatch,
    appStoreRecordModeBundleIDsValid: $appStoreRecordModeBundleIDsValid,
    macAppStoreSandboxFlowVerified: $macAppStoreSandboxFlowVerified,
    macAppStoreArchiveVerified: $macAppStoreArchiveVerified,
    macAppStoreProfileCertificateVerified: $macAppStoreProfileCertificateVerified,
    macAppStorePrivacyReportVerified: $macAppStorePrivacyReportVerified,
    macAppStoreReviewPathVerified: $macAppStoreReviewPathVerified,
    readyForDeveloperIDRelease: $readyDeveloperID,
    readyForMacAppStoreArchive: $readyMacAppStoreArchive,
    readyForMacAppStoreUpload: $readyMacAppStoreUpload,
    readyForFunctionalMacAppStoreSubmissionDeprecated: true,
    readyForFunctionalMacAppStoreSubmission: $readyFunctionalMacAppStoreSubmission,
    readyForIOSArchive: $readyIOSArchive,
    readyForFunctionalIOSTestFlight: ($readyIOSArchive and $iosSyncImplemented and
      $iosCloudKitContainerConfigured and $iosPrivacyPolicyURLConfigured and $iosSupportURLConfigured and
      $cloudKitProductionSchemaVerified and $iosRealDeviceSyncVerified and
      $iosLiveActivityVerified and $iosReviewPathVerified and
      $iosTestFlightExactBuildEvidenceReady and $iosFunctionalEvidenceBoundToCandidate and
      $iosTestFlightUploadVerified and $iosTestFlightProcessingVerified and
      $iosTestFlightInstallVerified and $iosPrivacyReleaseEvidenceReady)
  }'
