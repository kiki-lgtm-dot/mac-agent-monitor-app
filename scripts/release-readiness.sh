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
SIGNING_IDENTITIES_HELPER="$PROJECT_DIR/scripts/apple-signing-identities.zsh"
CMS_PROFILE_HELPER="$PROJECT_DIR/scripts/apple-cms-profile.zsh"
CLOUDKIT_PROFILE_AUTHORIZATION="$PROJECT_DIR/scripts/cloudkit-profile-authorization.jq"
[[ -f "$SIGNING_IDENTITIES_HELPER" && ! -L "$SIGNING_IDENTITIES_HELPER" ]] || {
  print -u2 -- "Apple signing identity helper is missing or unsafe"
  exit 66
}
[[ -f "$CMS_PROFILE_HELPER" && ! -L "$CMS_PROFILE_HELPER" ]] || {
  print -u2 -- "Apple CMS profile helper is missing or unsafe"
  exit 66
}
[[ -f "$CLOUDKIT_PROFILE_AUTHORIZATION" && \
  ! -L "$CLOUDKIT_PROFILE_AUTHORIZATION" ]] || {
  print -u2 -- "CloudKit profile authorization contract is missing or unsafe"
  exit 66
}
source "$SIGNING_IDENTITIES_HELPER"
source "$CMS_PROFILE_HELPER"
READINESS_ROOT="$(mktemp -d /private/tmp/agentisland-readiness.XXXXXX)"
trap '[[ "$READINESS_ROOT" == /private/tmp/agentisland-readiness.* ]] && /bin/rm -rf "$READINESS_ROOT"' EXIT HUP INT TERM
trap 'rc=$?; print -u2 -- "release-readiness.sh failed at line $LINENO (exit $rc)"; trap - ZERR; exit $rc' ZERR
DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
FULL_XCODE=false
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] && FULL_XCODE=true
HOST_MACOS_VERSION="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
MINIMUM_IOS_XCODE_MAJOR=26
MINIMUM_MAC_APP_STORE_XCODE_MAJOR=14
MINIMUM_IOS_SDK_MAJOR=26
MINIMUM_XCODE_26_HOST_MACOS="15.6"
HOST_MACOS_MAJOR="${HOST_MACOS_VERSION%%.*}"
HOST_MACOS_REMAINDER="${HOST_MACOS_VERSION#*.}"
HOST_MACOS_MINOR="${HOST_MACOS_REMAINDER%%.*}"
XCODE_26_HOST_COMPATIBLE=false
if [[ "$HOST_MACOS_MAJOR" == <-> && "$HOST_MACOS_MINOR" == <-> ]] && \
    (( HOST_MACOS_MAJOR > 15 || (HOST_MACOS_MAJOR == 15 && HOST_MACOS_MINOR >= 6) )); then
  XCODE_26_HOST_COMPATIBLE=true
fi

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

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
}

# App Store Connect snapshots use canonical ISO-8601 timestamps with
# millisecond precision while the existing operator records use whole
# seconds. Normalize both forms to epoch milliseconds before comparing them.
utc_timestamp_milliseconds() {
  local value="$1"
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    const value = process.argv[1];
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) process.exit(1);
    const milliseconds = Date.parse(value);
    if (!Number.isSafeInteger(milliseconds)) process.exit(1);
    const canonical = new Date(milliseconds).toISOString();
    if (value !== canonical && value !== canonical.replace(".000Z", "Z")) process.exit(1);
    process.stdout.write(String(milliseconds));
  ' "$value" 2>/dev/null
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

IDENTITY_OUTPUT="$(agent_island_find_identities codesigning)"
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

MAC_CONFIG_BUNDLE_ID="$(mac_xcconfig_value AGENT_ISLAND_MAC_APP_BUNDLE_ID)"
MAC_BUNDLE_ID="${AGENT_ISLAND_BUNDLE_ID:-$MAC_CONFIG_BUNDLE_ID}"
IOS_ENV_APP_BUNDLE_ID="${AGENT_ISLAND_IOS_BUNDLE_ID:-}"
IOS_ENV_WIDGET_BUNDLE_ID="${AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID:-}"
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
IOS_FUNCTIONAL_QA_EVIDENCE="${AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE:-}"
MAC_APP_STORE_RECORD_MODE="${AGENT_ISLAND_APP_STORE_RECORD_MODE:-}"
APP_STORE_SUBMISSION_MANIFEST_INPUT="${AGENT_ISLAND_APP_STORE_SUBMISSION:-.release/app-store-submission.json}"
PUBLIC_PAGES_EVIDENCE_INPUT="${AGENT_ISLAND_PUBLIC_PAGES_EVIDENCE:-.release/public-pages-evidence.json}"
MAC_ASC_BUILD_SNAPSHOT_INPUT="${AGENT_ISLAND_ASC_MAC_BUILD_SNAPSHOT:-}"
IOS_ASC_BUILD_SNAPSHOT_INPUT="${AGENT_ISLAND_ASC_IOS_BUILD_SNAPSHOT:-}"
ASC_SNAPSHOT_MAX_AGE_SECONDS="${AGENT_ISLAND_ASC_SNAPSHOT_MAX_AGE_SECONDS:-900}"
ASC_SNAPSHOT_MAX_AGE_VALID=false
if [[ "$ASC_SNAPSHOT_MAX_AGE_SECONDS" == <-> ]] && \
    (( ASC_SNAPSHOT_MAX_AGE_SECONDS >= 1 && ASC_SNAPSHOT_MAX_AGE_SECONDS <= 900 )); then
  ASC_SNAPSHOT_MAX_AGE_VALID=true
fi
RELEASE_IDENTITY_LOCK_PATH="$PROJECT_DIR/.release/identity.lock.json"
RELEASE_IDENTITY_MAC_INFO_PATH="$PROJECT_DIR/Resources/Info.plist"

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
IOS_PROJECT_RELEASE_VALIDATION_LOG="$READINESS_ROOT/ios-project-release-validation.log"
if "$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-project.sh" --release \
    >"$IOS_PROJECT_RELEASE_VALIDATION_LOG" 2>&1; then
  IOS_PROJECT_RELEASE_VALIDATION=true
fi
IOS_PROJECT_RELEASE_VALIDATION_MESSAGES_JSON="$(/usr/bin/jq -Rsc \
  'split("\n") | map(select(length > 0))' \
  "$IOS_PROJECT_RELEASE_VALIDATION_LOG")"

MAC_BUNDLE_READY=false
IOS_APP_BUNDLE_READY=false
IOS_WIDGET_BUNDLE_READY=false
ENTITLEMENTS_READY=false
PROVISIONING_PROFILE_READY=false
PROVISIONING_PROFILE_CERTIFICATE_READY=false
SOURCE_APP_IDENTIFIER=""
PROFILE_APP_ID_PREFIX=""
PROFILE_APP_ID_PREFIX_COUNT=""
PROFILE_UUID=""
PROFILE_NAME=""
PROFILE_EXPIRATION=""
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
IOS_TESTFLIGHT_WARNINGS_REVIEWED=false
IOS_TESTFLIGHT_WARNINGS_REVIEWED_AT=""
IOS_TESTFLIGHT_EVIDENCE_CONFIGURED=false
IOS_LOCAL_IPA_PREFLIGHT_READY=false
IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY=false
IOS_EVIDENCE_PROCESSING_STATE=""
IOS_TESTFLIGHT_PROCESSING_STATE=""
IOS_FUNCTIONAL_QA_EVIDENCE_CONFIGURED=false
IOS_FUNCTIONAL_QA_EVIDENCE_READY=false
IOS_FUNCTIONAL_QA_EVIDENCE_PATH=""
IOS_FUNCTIONAL_QA_EVIDENCE_SHA256=""
IOS_FUNCTIONAL_QA_DEVICE_MODEL=""
IOS_FUNCTIONAL_QA_OS_VERSION=""
IOS_FUNCTIONAL_QA_TESTED_AT=""
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
if [[ "$CLOUDKIT_CONTAINER_READY" == true && "$ENTITLEMENTS_PATH" == /* && \
    -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" && \
    "$ENTITLEMENTS_PATH" == "${ENTITLEMENTS_PATH:A}" ]] && \
    /usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null 2>&1 && \
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
if [[ "$ENTITLEMENTS_READY" == true && "$PROVISIONING_PROFILE" == /* && \
    -f "$PROVISIONING_PROFILE" && ! -L "$PROVISIONING_PROFILE" && \
    "$PROVISIONING_PROFILE" == "${PROVISIONING_PROFILE:A}" ]]; then
  PROFILE_PLIST="$READINESS_ROOT/provisioning-profile.plist"
  VERIFIED_PROVISIONING_PROFILE="$READINESS_ROOT/provisioning-profile.cms"
  if agent_island_decode_apple_signed_profile \
      "$PROVISIONING_PROFILE" "$PROFILE_PLIST" "$VERIFIED_PROVISIONING_PROFILE" && \
      /usr/bin/plutil -lint "$PROFILE_PLIST" >/dev/null 2>&1; then
    PROFILE_ENTITLEMENTS_PLIST="$READINESS_ROOT/provisioning-profile-entitlements.plist"
    PROFILE_ENTITLEMENTS_JSON="$READINESS_ROOT/provisioning-profile-entitlements.json"
    if /usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST" >/dev/null 2>&1 && \
        /usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON" "$PROFILE_ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
      PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_APP_ID_PREFIX_COUNT="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_APP_ID_PREFIX="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_UUID="$(/usr/bin/plutil -extract UUID raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_NAME="$(/usr/bin/plutil -extract Name raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
      if /usr/bin/jq -e \
          --arg applicationIdentifier "$SOURCE_APP_IDENTIFIER" \
          --arg team "$CONFIGURED_TEAM_ID" \
          --arg container "$CLOUDKIT_CONTAINER_ID" \
          -f "$CLOUDKIT_PROFILE_AUTHORIZATION" \
          "$PROFILE_ENTITLEMENTS_JSON" >/dev/null 2>&1 && \
          [[ "$PROFILE_APP_ID_PREFIX_COUNT" == "1" && \
            "$PROFILE_APP_ID_PREFIX" == [A-Z0-9]## && \
            "$SOURCE_APP_IDENTIFIER" == "$PROFILE_APP_ID_PREFIX.$MAC_BUNDLE_ID" && \
            "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TEAM" == "$CONFIGURED_TEAM_ID" && \
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

# A release identity is considered locked when the lock still describes the
# exact Mac/iOS record model and all three identity-bearing project files retain
# the paths and hashes written by apply-release-identity.sh. Profile-derived
# Developer ID material is reported and gated separately so adding it to a lock
# cannot make the App Store channels depend on a machine-local profile path.
# Legacy schema-v1 identity payloads can only represent Universal Purchase and
# are normalized for comparison; a migrated lock must still bind the macOS
# xcconfig added by schema v2 before any release readiness gate can pass.
RELEASE_IDENTITY_LOCK_CONFIGURED=false
RELEASE_IDENTITY_LOCK_VALID=false
RELEASE_IDENTITY_APPLIED_FILES_MATCH=false
RELEASE_IDENTITY_MATCHES_CONFIGURATION=false
RELEASE_IDENTITY_AUXILIARY_FILES_MATCH=false
RELEASE_IDENTITY_PROFILE_ASSETS_MATCH=false
RELEASE_IDENTITY_PROFILE_RECORDS_PRESENT=false
RELEASE_IDENTITY_LOCK_READY=false
RELEASE_IDENTITY_LOCK_SHA256=""
RELEASE_IDENTITY_INPUT_SCHEMA_VERSION=""
RELEASE_IDENTITY_NORMALIZED_SCHEMA_VERSION=""
RELEASE_IDENTITY_RECORD_MODE=""
RELEASE_IDENTITY_NORMALIZED="$READINESS_ROOT/release-identity-normalized.json"
if [[ -f "$RELEASE_IDENTITY_LOCK_PATH" && ! -L "$RELEASE_IDENTITY_LOCK_PATH" && \
    ! -L "${RELEASE_IDENTITY_LOCK_PATH:h}" && \
    "${RELEASE_IDENTITY_LOCK_PATH:A}" == "$RELEASE_IDENTITY_LOCK_PATH" ]]; then
  RELEASE_IDENTITY_LOCK_CONFIGURED=true
  RELEASE_IDENTITY_LOCK_MODE="$(/usr/bin/stat -f '%Lp' "$RELEASE_IDENTITY_LOCK_PATH" 2>/dev/null || true)"
  if [[ "$RELEASE_IDENTITY_LOCK_MODE" == <-> ]] && \
      (( (8#$RELEASE_IDENTITY_LOCK_MODE & 8#077) == 0 )) && \
      /usr/bin/jq -e -S '
        if .schemaVersion != 1 or
            (keys | sort) != ["appliedFiles", "firstAppliedAt",
              "generatedEntitlements", "identity", "provisioningProfile",
              "schemaVersion"] or
            (.firstAppliedAt | type) != "string" or
            (.firstAppliedAt | length) == 0 or
            (.identity | type) != "object" or
            (.appliedFiles | type) != "array" then
          error("unsupported release identity lock envelope")
        else
          .identity as $identity |
          if $identity.schemaVersion == 1 then
            if (($identity | keys) - ["cloudKit", "iCloudContainerIdentifier",
                "primaryBundleIdentifier", "schemaVersion", "teamIdentifier",
                "widgetBundleIdentifier"] | length) != 0 or
                ($identity.primaryBundleIdentifier | type) != "string" or
                $identity.widgetBundleIdentifier !=
                  ($identity.primaryBundleIdentifier + ".liveactivity") then
              error("unsafe legacy identity payload")
            else
              {
                schemaVersion: 2,
                inputSchemaVersion: 1,
                appStoreRecordMode: "universal-purchase",
                macOSAppBundleIdentifier: $identity.primaryBundleIdentifier,
                iOSAppBundleIdentifier: $identity.primaryBundleIdentifier,
                iOSWidgetBundleIdentifier: $identity.widgetBundleIdentifier,
                teamIdentifier: $identity.teamIdentifier,
                iCloudContainerIdentifier: $identity.iCloudContainerIdentifier,
                cloudKit: $identity.cloudKit
              }
            end
          elif $identity.schemaVersion == 2 then
            if (($identity | keys) - ["appStoreRecordMode", "cloudKit",
                "iCloudContainerIdentifier", "iOSAppBundleIdentifier",
                "iOSWidgetBundleIdentifier", "macOSAppBundleIdentifier",
                "schemaVersion", "teamIdentifier"] | length) != 0 then
              error("unsafe schema-v2 identity payload")
            else
              $identity + {inputSchemaVersion: 2}
            end
          else
            error("unsupported identity payload schema")
          end
        end
      ' "$RELEASE_IDENTITY_LOCK_PATH" >"$RELEASE_IDENTITY_NORMALIZED" 2>/dev/null; then
    RELEASE_IDENTITY_INPUT_SCHEMA_VERSION="$(/usr/bin/jq -r \
      '.inputSchemaVersion' "$RELEASE_IDENTITY_NORMALIZED")"
    RELEASE_IDENTITY_NORMALIZED_SCHEMA_VERSION="$(/usr/bin/jq -r \
      '.schemaVersion' "$RELEASE_IDENTITY_NORMALIZED")"
    RELEASE_IDENTITY_RECORD_MODE="$(/usr/bin/jq -r \
      '.appStoreRecordMode' "$RELEASE_IDENTITY_NORMALIZED")"
    if /usr/bin/jq -e '
        .schemaVersion == 2 and
        (.inputSchemaVersion == 1 or .inputSchemaVersion == 2) and
        (.appStoreRecordMode == "universal-purchase" or
          .appStoreRecordMode == "separate-records") and
        (.macOSAppBundleIdentifier | type == "string" and length > 0) and
        (.iOSAppBundleIdentifier | type == "string" and length > 0) and
        (.iOSWidgetBundleIdentifier | type == "string" and length > 0) and
        .iOSWidgetBundleIdentifier == (.iOSAppBundleIdentifier + ".liveactivity") and
        ((.appStoreRecordMode == "universal-purchase" and
            .macOSAppBundleIdentifier == .iOSAppBundleIdentifier) or
          (.appStoreRecordMode == "separate-records" and
            .macOSAppBundleIdentifier != .iOSAppBundleIdentifier)) and
        (.teamIdentifier | type == "string" and length > 0) and
        (.iCloudContainerIdentifier | type == "string" and length > 0) and
        .cloudKit == {
          databaseScope: "private",
          environment: "Production",
          recordType: "AgentIslandSnapshot",
          recordName: "latest",
          payloadField: "payloadJSON"
        }
      ' "$RELEASE_IDENTITY_NORMALIZED" >/dev/null 2>&1 && \
        /usr/bin/jq -e \
        --arg macBundle "$(/usr/bin/jq -r '.macOSAppBundleIdentifier' \
          "$RELEASE_IDENTITY_NORMALIZED")" '
          ((.provisioningProfile == null and
              .generatedEntitlements == null) or
            ((.provisioningProfile | type) == "object" and
              (.generatedEntitlements | type) == "object" and
              (.provisioningProfile | keys | sort) ==
                ["appIDPrefix", "applicationIdentifier", "expiration", "name",
                  "sha256", "uuid"] and
              (.generatedEntitlements | keys | sort) == ["path", "sha256"] and
              (.provisioningProfile.sha256 | type) == "string" and
              (.provisioningProfile.sha256 | test("^[0-9a-f]{64}$")) and
              (.provisioningProfile.uuid | type) == "string" and
              (.provisioningProfile.uuid | length) > 0 and
              (.provisioningProfile.name | type) == "string" and
              (.provisioningProfile.name | length) > 0 and
              (.provisioningProfile.expiration | type) == "string" and
              (.provisioningProfile.expiration |
                test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
              (.provisioningProfile.appIDPrefix | type) == "string" and
              (.provisioningProfile.appIDPrefix | test("^[A-Z0-9]+$")) and
              .provisioningProfile.applicationIdentifier ==
                (.provisioningProfile.appIDPrefix + "." + $macBundle) and
              .generatedEntitlements.path == ".release/CloudKit.entitlements" and
              (.generatedEntitlements.sha256 | type) == "string" and
              (.generatedEntitlements.sha256 | test("^[0-9a-f]{64}$"))))
        ' "$RELEASE_IDENTITY_LOCK_PATH" >/dev/null 2>&1; then
      RELEASE_IDENTITY_LOCK_VALID=true
    fi
    RELEASE_IDENTITY_MAC_INFO_SHA="$(/usr/bin/jq -r '
      [.appliedFiles[]? | select(.path == "Resources/Info.plist")][0].sha256 // ""
    ' "$RELEASE_IDENTITY_LOCK_PATH")"
    RELEASE_IDENTITY_IOS_CONFIG_SHA="$(/usr/bin/jq -r '
      [.appliedFiles[]? | select(.path == "ApplePlatforms/iOS/Config/Project.xcconfig")][0].sha256 // ""
    ' "$RELEASE_IDENTITY_LOCK_PATH")"
    RELEASE_IDENTITY_MAC_CONFIG_SHA="$(/usr/bin/jq -r '
      [.appliedFiles[]? | select(.path == "ApplePlatforms/macOS/Config/Project.xcconfig")][0].sha256 // ""
    ' "$RELEASE_IDENTITY_LOCK_PATH")"
    RELEASE_IDENTITY_APPLIED_FILE_COUNTS_READY=false
    if /usr/bin/jq -e '
        (.appliedFiles | length) == 3 and
        all(.appliedFiles[];
          (keys | sort) == ["path", "sha256"] and
          (.path | type) == "string" and
          (.sha256 | type) == "string" and
          (.sha256 | test("^[0-9a-f]{64}$"))) and
        ([.appliedFiles[]? | select(.path == "Resources/Info.plist")] | length) == 1 and
        ([.appliedFiles[]? | select(.path == "ApplePlatforms/iOS/Config/Project.xcconfig")] | length) == 1 and
        ([.appliedFiles[]? | select(.path == "ApplePlatforms/macOS/Config/Project.xcconfig")] | length) == 1
      ' "$RELEASE_IDENTITY_LOCK_PATH" >/dev/null 2>&1; then
      RELEASE_IDENTITY_APPLIED_FILE_COUNTS_READY=true
    fi
    if [[ "$RELEASE_IDENTITY_LOCK_VALID" == true ]]; then
      if /usr/bin/jq -e '
          .provisioningProfile == null and .generatedEntitlements == null
        ' "$RELEASE_IDENTITY_LOCK_PATH" >/dev/null 2>&1; then
        if [[ ! -e "$PROJECT_DIR/.release/CloudKit.entitlements" && \
            ! -L "$PROJECT_DIR/.release/CloudKit.entitlements" ]]; then
          RELEASE_IDENTITY_AUXILIARY_FILES_MATCH=true
        fi
      else
        RELEASE_IDENTITY_PROFILE_RECORDS_PRESENT=true
        LOCK_PROFILE_SHA256="$(/usr/bin/jq -r '.provisioningProfile.sha256' \
          "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_PROFILE_UUID="$(/usr/bin/jq -r '.provisioningProfile.uuid' \
          "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_PROFILE_NAME="$(/usr/bin/jq -r '.provisioningProfile.name' \
          "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_PROFILE_EXPIRATION="$(/usr/bin/jq -r '.provisioningProfile.expiration' \
          "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_PROFILE_APP_IDENTIFIER="$(/usr/bin/jq -r \
          '.provisioningProfile.applicationIdentifier' "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_PROFILE_APP_ID_PREFIX="$(/usr/bin/jq -r \
          '.provisioningProfile.appIDPrefix' "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_ENTITLEMENTS_RELATIVE_PATH="$(/usr/bin/jq -r \
          '.generatedEntitlements.path' "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_ENTITLEMENTS_SHA256="$(/usr/bin/jq -r \
          '.generatedEntitlements.sha256' "$RELEASE_IDENTITY_LOCK_PATH")"
        LOCK_ENTITLEMENTS_ABSOLUTE_PATH="$PROJECT_DIR/$LOCK_ENTITLEMENTS_RELATIVE_PATH"
        if [[ "$LOCK_ENTITLEMENTS_RELATIVE_PATH" == ".release/CloudKit.entitlements" && \
            "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH" == \
              "$PROJECT_DIR/.release/CloudKit.entitlements" && \
            "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH" == \
              "${LOCK_ENTITLEMENTS_ABSOLUTE_PATH:A}" && \
            -f "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH" && \
            ! -L "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH" && \
            ! -L "${LOCK_ENTITLEMENTS_ABSOLUTE_PATH:h}" && \
            "$ENTITLEMENTS_PATH" == "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH" && \
            "$PROVISIONING_PROFILE_READY" == true && \
            "$PROVISIONING_PROFILE" == /* && \
            -f "$PROVISIONING_PROFILE" && ! -L "$PROVISIONING_PROFILE" && \
            "$PROVISIONING_PROFILE" == "${PROVISIONING_PROFILE:A}" && \
            "$(file_sha256 "$VERIFIED_PROVISIONING_PROFILE")" == "$LOCK_PROFILE_SHA256" && \
            "$(file_sha256 "$LOCK_ENTITLEMENTS_ABSOLUTE_PATH")" == \
              "$LOCK_ENTITLEMENTS_SHA256" && \
            "$PROFILE_UUID" == "$LOCK_PROFILE_UUID" && \
            "$PROFILE_NAME" == "$LOCK_PROFILE_NAME" && \
            "$PROFILE_EXPIRATION" == "$LOCK_PROFILE_EXPIRATION" && \
            "$SOURCE_APP_IDENTIFIER" == "$LOCK_PROFILE_APP_IDENTIFIER" && \
            "$PROFILE_APP_ID_PREFIX" == "$LOCK_PROFILE_APP_ID_PREFIX" ]]; then
          RELEASE_IDENTITY_AUXILIARY_FILES_MATCH=true
          RELEASE_IDENTITY_PROFILE_ASSETS_MATCH=true
        fi
      fi
    fi
    if [[ "$RELEASE_IDENTITY_LOCK_VALID" == true ]] && \
        /usr/bin/jq -e \
        --arg recordMode "$MAC_APP_STORE_RECORD_MODE" \
        --arg macBundle "$MAC_BUNDLE_ID" \
        --arg iosBundle "$IOS_APP_BUNDLE_ID" \
        --arg widgetBundle "$IOS_WIDGET_BUNDLE_ID" \
        --arg iosEnvBundle "$IOS_ENV_APP_BUNDLE_ID" \
        --arg iosEnvWidget "$IOS_ENV_WIDGET_BUNDLE_ID" \
        --arg team "$CONFIGURED_TEAM_ID" \
        --arg container "$CLOUDKIT_CONTAINER_ID" '
          .appStoreRecordMode == $recordMode and
          .macOSAppBundleIdentifier == $macBundle and
          .iOSAppBundleIdentifier == $iosBundle and
          .iOSWidgetBundleIdentifier == $widgetBundle and
          ($iosEnvBundle == "" or .iOSAppBundleIdentifier == $iosEnvBundle) and
          ($iosEnvWidget == "" or .iOSWidgetBundleIdentifier == $iosEnvWidget) and
          .teamIdentifier == $team and
          .iCloudContainerIdentifier == $container and
          .cloudKit.environment == "Production"
        ' "$RELEASE_IDENTITY_NORMALIZED" >/dev/null 2>&1 && \
        [[ "$MAC_CONFIG_BUNDLE_ID" == "$MAC_BUNDLE_ID" && \
          "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
            "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || true)" == "$MAC_BUNDLE_ID" && \
          "$(xcconfig_value AGENT_ISLAND_APP_BUNDLE_ID)" == "$IOS_APP_BUNDLE_ID" && \
          "$(xcconfig_value AGENT_ISLAND_WIDGET_BUNDLE_ID)" == \
            '$(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' && \
          "$(xcconfig_value AGENT_ISLAND_DEVELOPMENT_TEAM)" == "$CONFIGURED_TEAM_ID" && \
          "$(xcconfig_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)" == "$CLOUDKIT_CONTAINER_ID" ]]; then
      RELEASE_IDENTITY_MATCHES_CONFIGURATION=true
    fi
    if [[ "$RELEASE_IDENTITY_APPLIED_FILE_COUNTS_READY" == true && \
          ! -L "$RELEASE_IDENTITY_MAC_INFO_PATH" && \
          ! -L "$IOS_XCCONFIG_PATH" && ! -L "$MAC_XCCONFIG_PATH" && \
          "$RELEASE_IDENTITY_MAC_INFO_PATH" == \
            "${RELEASE_IDENTITY_MAC_INFO_PATH:A}" && \
          "$IOS_XCCONFIG_PATH" == "${IOS_XCCONFIG_PATH:A}" && \
          "$MAC_XCCONFIG_PATH" == "${MAC_XCCONFIG_PATH:A}" && \
          "${PROJECT_DIR:A}" == "$PROJECT_DIR" && \
          "$RELEASE_IDENTITY_MAC_INFO_SHA" == [0-9a-f]## && \
          ${#RELEASE_IDENTITY_MAC_INFO_SHA} -eq 64 && \
          "$RELEASE_IDENTITY_IOS_CONFIG_SHA" == [0-9a-f]## && \
          ${#RELEASE_IDENTITY_IOS_CONFIG_SHA} -eq 64 && \
          "$RELEASE_IDENTITY_MAC_CONFIG_SHA" == [0-9a-f]## && \
          ${#RELEASE_IDENTITY_MAC_CONFIG_SHA} -eq 64 && \
          "$(file_sha256 "$RELEASE_IDENTITY_MAC_INFO_PATH")" == \
            "$RELEASE_IDENTITY_MAC_INFO_SHA" && \
          "$(file_sha256 "$IOS_XCCONFIG_PATH")" == \
            "$RELEASE_IDENTITY_IOS_CONFIG_SHA" && \
          "$(file_sha256 "$MAC_XCCONFIG_PATH")" == \
            "$RELEASE_IDENTITY_MAC_CONFIG_SHA" ]]; then
      RELEASE_IDENTITY_APPLIED_FILES_MATCH=true
    fi
    if [[ "$RELEASE_IDENTITY_LOCK_VALID" == true && \
        "$RELEASE_IDENTITY_APPLIED_FILES_MATCH" == true && \
        "$RELEASE_IDENTITY_MATCHES_CONFIGURATION" == true ]]; then
      RELEASE_IDENTITY_LOCK_READY=true
      RELEASE_IDENTITY_LOCK_SHA256="$(file_sha256 "$RELEASE_IDENTITY_LOCK_PATH")"
    fi
  fi
fi

# Consume the read-only, no-overwrite post-upload evidence produced by
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
      IOS_EVIDENCE_WARNINGS_REVIEWED_AT="$(/usr/bin/jq -r '.warningsReviewedAt // ""' \
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
                .warningsReviewed == true and
                (.warningsReviewedAt | type == "string" and length > 0) and
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
                ((.warningsReviewed // false) == false) and .warningsReviewedAt == null and
                .distributedToTesters == false and .installedFromTestFlight == false and
                .submittedForAppReview == false
              ' "$IOS_EVIDENCE_DELIVERY_PATH" >/dev/null 2>&1 && \
            valid_utc_timestamp "$IOS_DELIVERY_SUBMITTED_AT" && \
            valid_utc_timestamp "$IOS_EVIDENCE_PROCESSING_AT" && \
            valid_utc_timestamp "$IOS_EVIDENCE_WARNINGS_REVIEWED_AT" && \
            valid_utc_timestamp "$IOS_EVIDENCE_TESTED_AT" && \
            [[ "$IOS_LOCAL_IPA_PREFLIGHT_READY" == true ]]; then
          IOS_DELIVERY_SUBMITTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_DELIVERY_SUBMITTED_AT" '+%s')"
          IOS_EVIDENCE_PROCESSING_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_EVIDENCE_PROCESSING_AT" '+%s')"
          IOS_EVIDENCE_WARNINGS_REVIEWED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_EVIDENCE_WARNINGS_REVIEWED_AT" '+%s')"
          IOS_EVIDENCE_TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$IOS_EVIDENCE_TESTED_AT" '+%s')"
          if (( IOS_DELIVERY_SUBMITTED_EPOCH <= IOS_EVIDENCE_PROCESSING_EPOCH && \
              IOS_EVIDENCE_PROCESSING_EPOCH <= IOS_EVIDENCE_WARNINGS_REVIEWED_EPOCH && \
              IOS_EVIDENCE_WARNINGS_REVIEWED_EPOCH <= IOS_EVIDENCE_TESTED_EPOCH )); then
            IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY=true
            IOS_TESTFLIGHT_UPLOAD_VERIFIED=true
            IOS_TESTFLIGHT_PROCESSING_VERIFIED=true
            IOS_TESTFLIGHT_INSTALL_VERIFIED=true
            IOS_TESTFLIGHT_WARNINGS_REVIEWED=true
            IOS_TESTFLIGHT_WARNINGS_REVIEWED_AT="$IOS_EVIDENCE_WARNINGS_REVIEWED_AT"
            IOS_TESTFLIGHT_PROCESSING_STATE="$IOS_EVIDENCE_PROCESSING_STATE"
            IOS_TESTFLIGHT_IPA_SHA256="$IOS_EVIDENCE_IPA_SHA"
            IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID="$IOS_EVIDENCE_BUILD_ID"
          fi
        fi
      fi
    fi
  fi
fi
if [[ -n "$IOS_FUNCTIONAL_QA_EVIDENCE" ]]; then
  IOS_FUNCTIONAL_QA_EVIDENCE_CONFIGURED=true
fi
IOS_FUNCTIONAL_QA_VALIDATION_RESULT="$READINESS_ROOT/ios-functional-qa-validation.json"
if [[ "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true && \
    "$IOS_FUNCTIONAL_QA_EVIDENCE_CONFIGURED" == true ]] && \
    "$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-functional-qa-evidence.sh" \
      --json \
      --expected-testflight-verification "$IOS_TESTFLIGHT_VERIFICATION_EVIDENCE" \
      --expected-ipa-sha256 "$IOS_TESTFLIGHT_IPA_SHA256" \
      "$IOS_FUNCTIONAL_QA_EVIDENCE" >"$IOS_FUNCTIONAL_QA_VALIDATION_RESULT" 2>/dev/null && \
    /usr/bin/jq -e \
      --arg bundle "$IOS_APP_BUNDLE_ID" \
      --arg version "$IOS_MARKETING_VERSION" \
      --arg build "$IOS_BUILD_NUMBER" \
      --arg ipaSHA "$IOS_TESTFLIGHT_IPA_SHA256" '
        .evidenceReady == true and
        .candidate.appBundleID == $bundle and
        .candidate.version == $version and
        .candidate.build == $build and
        .candidate.ipaSHA256 == $ipaSHA and
        .cloudKitProductionSchemaVerified == true and
        .realDeviceSyncVerified == true and
        .liveActivityVerified == true and
        .reviewPathVerified == true
      ' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT" >/dev/null 2>&1; then
  IOS_FUNCTIONAL_QA_EVIDENCE_READY=true
  IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=true
  IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED="$(/usr/bin/jq -r \
    '.cloudKitProductionSchemaVerified' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_REAL_DEVICE_SYNC_VERIFIED="$(/usr/bin/jq -r \
    '.realDeviceSyncVerified' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_LIVE_ACTIVITY_VERIFIED="$(/usr/bin/jq -r \
    '.liveActivityVerified' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_REVIEW_PATH_VERIFIED="$(/usr/bin/jq -r \
    '.reviewPathVerified' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_FUNCTIONAL_QA_EVIDENCE_PATH="$(/usr/bin/jq -r \
    '.evidencePath' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_FUNCTIONAL_QA_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_FUNCTIONAL_QA_DEVICE_MODEL="$(/usr/bin/jq -r \
    '.testDevice.model' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_FUNCTIONAL_QA_OS_VERSION="$(/usr/bin/jq -r \
    '.testDevice.osVersion' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
  IOS_FUNCTIONAL_QA_TESTED_AT="$(/usr/bin/jq -r \
    '.testedAt' "$IOS_FUNCTIONAL_QA_VALIDATION_RESULT")"
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
MAC_APP_STORE_RELEASE_METADATA="${AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA:-}"
MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="${AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE:-}"
MAC_APP_STORE_DELIVERY_EVIDENCE="${AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE:-}"
MAC_APP_STORE_PROCESSING_EVIDENCE="${AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE:-}"
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
# exact upload-artifact fingerprint all match the exact candidate above.
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
      (
        .releaseEvidence.recordScope == $recordScope or
        ($recordScope == "separate-records" and
          .releaseEvidence.recordScope == $platform)
      ) and
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
MAC_STORE_SUBMISSION_ASSETS_READY=false
IOS_STORE_SUBMISSION_ASSETS_READY=false
STORE_SUBMISSION_VALIDATION_RESULT="$READINESS_ROOT/store-submission-validation.json"
STORE_SUBMISSION_VALIDATION_LOG="$READINESS_ROOT/store-submission-validation.log"
STORE_SUBMISSION_BLOCKERS_JSON="[]"
STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
MAC_STORE_SUBMISSION_BLOCKERS_JSON="[]"
IOS_STORE_SUBMISSION_BLOCKERS_JSON="[]"
MAC_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
IOS_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
# A release-mode validation may legitimately fail for just one platform. Keep
# its structured result and consume the platform-specific gates below instead
# of treating the validator's aggregate exit status as both platforms' state.
node "$PROJECT_DIR/scripts/validate-store-submission.mjs" --release \
  >"$STORE_SUBMISSION_VALIDATION_RESULT" 2>"$STORE_SUBMISSION_VALIDATION_LOG" || true
if /usr/bin/jq -e 'type == "object"' "$STORE_SUBMISSION_VALIDATION_RESULT" \
    >/dev/null 2>&1; then
  /usr/bin/jq -e '.releaseReady == true' "$STORE_SUBMISSION_VALIDATION_RESULT" \
    >/dev/null 2>&1 && STORE_SUBMISSION_ASSETS_READY=true
  /usr/bin/jq -e '.macStoreSubmissionAssetsReady == true' \
    "$STORE_SUBMISSION_VALIDATION_RESULT" >/dev/null 2>&1 && \
    MAC_STORE_SUBMISSION_ASSETS_READY=true
  /usr/bin/jq -e '.iosStoreSubmissionAssetsReady == true' \
    "$STORE_SUBMISSION_VALIDATION_RESULT" >/dev/null 2>&1 && \
    IOS_STORE_SUBMISSION_ASSETS_READY=true
  STORE_SUBMISSION_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '(.releaseBlockers // []) | unique' "$STORE_SUBMISSION_VALIDATION_RESULT")"
  STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '(.structuralErrors // []) | unique' "$STORE_SUBMISSION_VALIDATION_RESULT")"
  MAC_STORE_SUBMISSION_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '(.macStoreSubmissionBlockers // []) | unique' \
    "$STORE_SUBMISSION_VALIDATION_RESULT")"
  IOS_STORE_SUBMISSION_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '(.iosStoreSubmissionBlockers // []) | unique' \
    "$STORE_SUBMISSION_VALIDATION_RESULT")"
  MAC_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '(.macStoreSubmissionStructuralErrors // []) | unique' \
    "$STORE_SUBMISSION_VALIDATION_RESULT")"
  IOS_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '(.iosStoreSubmissionStructuralErrors // []) | unique' \
    "$STORE_SUBMISSION_VALIDATION_RESULT")"
fi

# Validate the finalized App Store submission decisions separately from the
# generated store assets above. This validator is local-only: it reads the
# manifest, the current identity lock, and the already-generated asset report.
APP_STORE_SUBMISSION_MANIFEST_CONFIGURED=false
APP_STORE_SUBMISSION_MANIFEST_READY=false
MAC_APP_STORE_SUBMISSION_MANIFEST_READY=false
IOS_APP_STORE_SUBMISSION_MANIFEST_READY=false
APP_STORE_SUBMISSION_MANIFEST_PATH=""
APP_STORE_SUBMISSION_MANIFEST_SHA256=""
APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="[]"
MAC_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
MAC_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="[]"
IOS_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="[]"
IOS_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="[]"
MAC_APP_STORE_EXPECTED_APP_RESOURCE_ID=""
MAC_APP_STORE_EXPECTED_SKU=""
MAC_APP_STORE_EXPECTED_PRIMARY_LOCALE=""
IOS_APP_STORE_EXPECTED_APP_RESOURCE_ID=""
IOS_APP_STORE_EXPECTED_SKU=""
IOS_APP_STORE_EXPECTED_PRIMARY_LOCALE=""
APP_STORE_SUBMISSION_VALIDATOR="$PROJECT_DIR/scripts/validate-app-store-submission.mjs"
APP_STORE_SUBMISSION_VALIDATION_RESULT="$READINESS_ROOT/app-store-submission-validation.json"
APP_STORE_SUBMISSION_VALIDATION_LOG="$READINESS_ROOT/app-store-submission-validation.log"
if command -v node >/dev/null 2>&1 && \
    [[ -f "$APP_STORE_SUBMISSION_VALIDATOR" && ! -L "$APP_STORE_SUBMISSION_VALIDATOR" ]]; then
  AGENT_ISLAND_APP_STORE_SUBMISSION="$APP_STORE_SUBMISSION_MANIFEST_INPUT" \
    node "$APP_STORE_SUBMISSION_VALIDATOR" --release \
      >"$APP_STORE_SUBMISSION_VALIDATION_RESULT" \
      2>"$APP_STORE_SUBMISSION_VALIDATION_LOG" || true
fi
if /usr/bin/jq -e '
    .schemaVersion == 1 and
    .mode == "release" and
    (.manifest | type == "object") and
    (.manifest.path | type == "string") and
    (.manifest.present | type == "boolean") and
    (.manifest.finalizedLocation | type == "boolean") and
    ((.manifest.sha256 == null) or (.manifest.sha256 | type == "string")) and
    (.identityLock | type == "object") and
    (.identityLock.bound | type == "boolean") and
    (.candidates.macos | type == "object") and
    (.candidates.ios | type == "object") and
    .appStoreConnectComparison.verifiedByThisValidator == false and
    .appStoreConnectComparison.requiredBeforeRemoteAction == true and
    .submissionReadyForRemoteAction == false and
    (.appStoreSubmissionManifestReady | type == "boolean") and
    (.macAppStoreSubmissionManifestReady | type == "boolean") and
    (.iosAppStoreSubmissionManifestReady | type == "boolean") and
    (.structuralErrors | type == "array" and all(.[]; type == "string")) and
    (.releaseBlockers | type == "array" and all(.[]; type == "string")) and
    (.platforms.macos.structuralErrors | type == "array" and all(.[]; type == "string")) and
    (.platforms.macos.releaseBlockers | type == "array" and all(.[]; type == "string")) and
    (.platforms.ios.structuralErrors | type == "array" and all(.[]; type == "string")) and
    (.platforms.ios.releaseBlockers | type == "array" and all(.[]; type == "string")) and
    (.appStoreConnectComparison.expected.macos.appResourceId | type == "string" or . == null) and
    (.appStoreConnectComparison.expected.macos.sku | type == "string" or . == null) and
    (.appStoreConnectComparison.expected.macos.primaryLocale | type == "string" or . == null) and
    (.appStoreConnectComparison.expected.ios.appResourceId | type == "string" or . == null) and
    (.appStoreConnectComparison.expected.ios.sku | type == "string" or . == null) and
    (.appStoreConnectComparison.expected.ios.primaryLocale | type == "string" or . == null)
  ' "$APP_STORE_SUBMISSION_VALIDATION_RESULT" >/dev/null 2>&1; then
  APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '.structuralErrors | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '.releaseBlockers | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  MAC_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '.platforms.macos.structuralErrors | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  MAC_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '.platforms.macos.releaseBlockers | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  IOS_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON="$(/usr/bin/jq -c \
    '.platforms.ios.structuralErrors | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  IOS_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON="$(/usr/bin/jq -c \
    '.platforms.ios.releaseBlockers | unique' "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"

  APP_STORE_SUBMISSION_REPORTED_PATH="$(/usr/bin/jq -r '.manifest.path' \
    "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  APP_STORE_SUBMISSION_REPORTED_SHA256="$(/usr/bin/jq -r '.manifest.sha256 // ""' \
    "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
  APP_STORE_SUBMISSION_CANDIDATE_PATH="$PROJECT_DIR/$APP_STORE_SUBMISSION_REPORTED_PATH"
  if [[ "$(/usr/bin/jq -r '.manifest.present' \
        "$APP_STORE_SUBMISSION_VALIDATION_RESULT")" == true && \
      "$APP_STORE_SUBMISSION_REPORTED_PATH" == ".release/app-store-submission.json" && \
      "$APP_STORE_SUBMISSION_REPORTED_PATH" != /* && \
      "$APP_STORE_SUBMISSION_REPORTED_PATH" != "" && \
      -f "$APP_STORE_SUBMISSION_CANDIDATE_PATH" && \
      ! -L "$APP_STORE_SUBMISSION_CANDIDATE_PATH" && \
      "${APP_STORE_SUBMISSION_CANDIDATE_PATH:A}" == \
        "$APP_STORE_SUBMISSION_CANDIDATE_PATH" && \
      "$APP_STORE_SUBMISSION_CANDIDATE_PATH" == "$PROJECT_DIR"/* && \
      "$APP_STORE_SUBMISSION_REPORTED_SHA256" == [0-9a-f]## && \
      ${#APP_STORE_SUBMISSION_REPORTED_SHA256} -eq 64 && \
      "$(file_sha256 "$APP_STORE_SUBMISSION_CANDIDATE_PATH")" == \
        "$APP_STORE_SUBMISSION_REPORTED_SHA256" ]]; then
    APP_STORE_SUBMISSION_MANIFEST_CONFIGURED=true
    APP_STORE_SUBMISSION_MANIFEST_PATH="$APP_STORE_SUBMISSION_CANDIDATE_PATH"
    APP_STORE_SUBMISSION_MANIFEST_SHA256="$APP_STORE_SUBMISSION_REPORTED_SHA256"
    MAC_APP_STORE_EXPECTED_APP_RESOURCE_ID="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.macos.appResourceId // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    MAC_APP_STORE_EXPECTED_SKU="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.macos.sku // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    MAC_APP_STORE_EXPECTED_PRIMARY_LOCALE="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.macos.primaryLocale // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    IOS_APP_STORE_EXPECTED_APP_RESOURCE_ID="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.ios.appResourceId // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    IOS_APP_STORE_EXPECTED_SKU="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.ios.sku // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    IOS_APP_STORE_EXPECTED_PRIMARY_LOCALE="$(/usr/bin/jq -r \
      '.appStoreConnectComparison.expected.ios.primaryLocale // ""' \
      "$APP_STORE_SUBMISSION_VALIDATION_RESULT")"
    if [[ "$RELEASE_IDENTITY_LOCK_READY" == true ]] && \
        /usr/bin/jq -e \
          --arg identityPath ".release/identity.lock.json" \
          --arg identitySHA "$RELEASE_IDENTITY_LOCK_SHA256" \
          --arg recordMode "$MAC_APP_STORE_RECORD_MODE" \
          --arg macBundle "$MAC_BUNDLE_ID" \
          --arg macVersion "$MAC_MARKETING_VERSION" \
          --arg macBuild "$MAC_BUILD_NUMBER" \
          --arg iosBundle "$IOS_APP_BUNDLE_ID" \
          --arg iosWidget "$IOS_WIDGET_BUNDLE_ID" \
          --arg iosVersion "$IOS_MARKETING_VERSION" \
          --arg iosBuild "$IOS_BUILD_NUMBER" '
            .mode == "release" and .manifest.finalizedLocation == true and
            .identityLock.bound == true and
            .identityLock.path == $identityPath and
            .identityLock.sha256 == $identitySHA and
            .recordMode == $recordMode and
            .candidates.macos.bundleIdentifier == $macBundle and
            .candidates.macos.version == $macVersion and
            .candidates.macos.build == $macBuild and
            .candidates.ios.bundleIdentifier == $iosBundle and
            .candidates.ios.widgetBundleIdentifier == $iosWidget and
            .candidates.ios.version == $iosVersion and
            .candidates.ios.build == $iosBuild and
            .appStoreConnectComparison.expected.macos.bundleIdentifier == $macBundle and
            .appStoreConnectComparison.expected.ios.bundleIdentifier == $iosBundle and
            .appStoreConnectComparison.verifiedByThisValidator == false and
            .appStoreConnectComparison.requiredBeforeRemoteAction == true and
            .submissionReadyForRemoteAction == false
          ' "$APP_STORE_SUBMISSION_VALIDATION_RESULT" >/dev/null 2>&1; then
      [[ "$(/usr/bin/jq -r '.appStoreSubmissionManifestReady' \
        "$APP_STORE_SUBMISSION_VALIDATION_RESULT")" == true ]] && \
        APP_STORE_SUBMISSION_MANIFEST_READY=true
      [[ "$(/usr/bin/jq -r '.macAppStoreSubmissionManifestReady' \
        "$APP_STORE_SUBMISSION_VALIDATION_RESULT")" == true ]] && \
        MAC_APP_STORE_SUBMISSION_MANIFEST_READY=true
      [[ "$(/usr/bin/jq -r '.iosAppStoreSubmissionManifestReady' \
        "$APP_STORE_SUBMISSION_VALIDATION_RESULT")" == true ]] && \
        IOS_APP_STORE_SUBMISSION_MANIFEST_READY=true
    fi
  fi
fi

# This is intentionally verification-only. Capturing public-page evidence is a
# separate, explicit network operation; readiness never fetches the web.
PUBLIC_PAGES_EVIDENCE_CONFIGURED=false
PUBLIC_PAGES_EVIDENCE_READY=false
PUBLIC_PAGES_EVIDENCE_BOUND_TO_SUBMISSION_MANIFEST=false
PUBLIC_PAGES_EVIDENCE_PATH=""
PUBLIC_PAGES_EVIDENCE_SHA256=""
PUBLIC_PAGES_EVIDENCE_BINDING_TYPE=""
PUBLIC_PAGES_EVIDENCE_BINDING_PATH=""
PUBLIC_PAGES_EVIDENCE_BINDING_SHA256=""
PUBLIC_PAGES_EVIDENCE_OLDEST_CHECKED_AT=""
PUBLIC_PAGES_EVIDENCE_NEWEST_CHECKED_AT=""
PUBLIC_PAGES_EVIDENCE_MAX_AGE_SECONDS=86400
PUBLIC_PAGES_CANDIDATE_PATH="$PUBLIC_PAGES_EVIDENCE_INPUT"
[[ "$PUBLIC_PAGES_CANDIDATE_PATH" == /* ]] || \
  PUBLIC_PAGES_CANDIDATE_PATH="$PROJECT_DIR/$PUBLIC_PAGES_CANDIDATE_PATH"
if [[ -n "$PUBLIC_PAGES_EVIDENCE_INPUT" && \
    -f "$PUBLIC_PAGES_CANDIDATE_PATH" && \
    ! -L "$PUBLIC_PAGES_CANDIDATE_PATH" && \
    "${PUBLIC_PAGES_CANDIDATE_PATH:A}" == "$PUBLIC_PAGES_CANDIDATE_PATH" && \
    "$PUBLIC_PAGES_CANDIDATE_PATH" == "$PROJECT_DIR"/* ]]; then
  PUBLIC_PAGES_EVIDENCE_CONFIGURED=true
  PUBLIC_PAGES_EVIDENCE_PATH="$PUBLIC_PAGES_CANDIDATE_PATH"
fi
PUBLIC_PAGES_EVIDENCE_VALIDATOR="$PROJECT_DIR/scripts/capture-public-pages-evidence.mjs"
PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT="$READINESS_ROOT/public-pages-evidence-validation.json"
PUBLIC_PAGES_EVIDENCE_VALIDATION_LOG="$READINESS_ROOT/public-pages-evidence-validation.log"
if [[ "$PUBLIC_PAGES_EVIDENCE_CONFIGURED" == true ]] && \
    command -v node >/dev/null 2>&1 && \
    [[ -f "$PUBLIC_PAGES_EVIDENCE_VALIDATOR" && ! -L "$PUBLIC_PAGES_EVIDENCE_VALIDATOR" ]] && \
    node "$PUBLIC_PAGES_EVIDENCE_VALIDATOR" \
      --verify "$PUBLIC_PAGES_EVIDENCE_PATH" \
      --max-age-seconds "$PUBLIC_PAGES_EVIDENCE_MAX_AGE_SECONDS" \
      >"$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT" \
      2>"$PUBLIC_PAGES_EVIDENCE_VALIDATION_LOG" && \
    /usr/bin/jq -e \
      --arg evidencePath "$PUBLIC_PAGES_EVIDENCE_PATH" \
      --argjson maxAge "$PUBLIC_PAGES_EVIDENCE_MAX_AGE_SECONDS" '
        .valid == true and .evidencePath == $evidencePath and
        (.evidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.binding | type == "object") and
        (.binding.type == "submission-manifest" or .binding.type == "identity-lock") and
        (.binding.path | type == "string" and length > 0) and
        (.binding.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.oldestCheckedAt | type == "string" and length > 0) and
        (.newestCheckedAt | type == "string" and length > 0) and
        .maxAgeSeconds == $maxAge
      ' "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT" >/dev/null 2>&1; then
  PUBLIC_PAGES_EVIDENCE_READY=true
  PUBLIC_PAGES_EVIDENCE_SHA256="$(/usr/bin/jq -r '.evidenceSHA256' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  PUBLIC_PAGES_EVIDENCE_BINDING_TYPE="$(/usr/bin/jq -r '.binding.type' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  PUBLIC_PAGES_EVIDENCE_BINDING_PATH="$(/usr/bin/jq -r '.binding.path' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  PUBLIC_PAGES_EVIDENCE_BINDING_SHA256="$(/usr/bin/jq -r '.binding.sha256' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  PUBLIC_PAGES_EVIDENCE_OLDEST_CHECKED_AT="$(/usr/bin/jq -r '.oldestCheckedAt' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  PUBLIC_PAGES_EVIDENCE_NEWEST_CHECKED_AT="$(/usr/bin/jq -r '.newestCheckedAt' \
    "$PUBLIC_PAGES_EVIDENCE_VALIDATION_RESULT")"
  if [[ "$APP_STORE_SUBMISSION_MANIFEST_READY" == true && \
      "$PUBLIC_PAGES_EVIDENCE_BINDING_TYPE" == "submission-manifest" && \
      "$PUBLIC_PAGES_EVIDENCE_BINDING_PATH" == \
        "$APP_STORE_SUBMISSION_MANIFEST_PATH" && \
      "$PUBLIC_PAGES_EVIDENCE_BINDING_SHA256" == \
        "$APP_STORE_SUBMISSION_MANIFEST_SHA256" ]]; then
    PUBLIC_PAGES_EVIDENCE_BOUND_TO_SUBMISSION_MANIFEST=true
  fi
fi

# Bind every macOS release state to one exact locally exported candidate. A
# local preflight, an accepted upload, App Store Connect processing, functional
# QA, and App Review submission are deliberately separate states. This script
# only consumes independently verified, read-only evidence and never contacts
# Apple or infers a later state from an earlier one.
MAC_APP_STORE_RELEASE_METADATA_CONFIGURED=false
MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY=false
MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED=false
MAC_APP_STORE_ARCHIVE_ZIP_SHA256=""
MAC_APP_STORE_PACKAGE_SHA256=""
MAC_CANDIDATE_METADATA_PATH=""
MAC_CANDIDATE_DIRECTORY=""
MAC_CANDIDATE_ARCHIVE_ZIP=""
MAC_CANDIDATE_PACKAGE=""

MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_CONFIGURED=false
MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY=false
MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_PATH=""
MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_SHA256=""
MAC_APP_STORE_FUNCTIONAL_QA_MAC_MODEL=""
MAC_APP_STORE_FUNCTIONAL_QA_OS_VERSION=""
MAC_APP_STORE_FUNCTIONAL_QA_TESTED_AT=""
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256=""
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256=""
MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=false
MAC_APP_STORE_SANDBOX_FLOW_VERIFIED=false
MAC_APP_STORE_ARCHIVE_VERIFIED=false
MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED=false
MAC_APP_STORE_PRIVACY_REPORT_VERIFIED=false
MAC_APP_STORE_REVIEW_PATH_VERIFIED=false

MAC_APP_STORE_DELIVERY_EVIDENCE_CONFIGURED=false
MAC_APP_STORE_DELIVERY_EVIDENCE_READY=false
MAC_APP_STORE_DELIVERY_BOUND_TO_CANDIDATE=false
MAC_APP_STORE_DELIVERY_EVIDENCE_PATH=""
MAC_APP_STORE_DELIVERY_EVIDENCE_SHA256=""
MAC_APP_STORE_UPLOAD_ACCEPTED=false
MAC_APP_STORE_UPLOAD_SUBMITTED_AT=""

MAC_APP_STORE_PROCESSING_EVIDENCE_CONFIGURED=false
MAC_APP_STORE_PROCESSING_EVIDENCE_READY=false
MAC_APP_STORE_PROCESSING_BOUND_TO_DELIVERY=false
MAC_APP_STORE_PROCESSING_EVIDENCE_PATH=""
MAC_APP_STORE_PROCESSING_EVIDENCE_SHA256=""
MAC_APP_STORE_PROCESSING_STATE=""
MAC_APP_STORE_PROCESSING_VERIFIED=false
MAC_APP_STORE_PROCESSING_VERIFIED_AT=""
MAC_APP_STORE_WARNINGS_REVIEWED=false
MAC_APP_STORE_WARNINGS_REVIEWED_AT=""
MAC_APP_STORE_CONNECT_BUILD_ID=""
MAC_APP_STORE_APP_REVIEW_SUBMISSION_RECORDED=false
if [[ -n "$MAC_APP_STORE_RELEASE_METADATA" ]]; then
  MAC_APP_STORE_RELEASE_METADATA_CONFIGURED=true
  if [[ "$MAC_APP_STORE_RELEASE_METADATA" == /* && \
      -f "$MAC_APP_STORE_RELEASE_METADATA" && ! -L "$MAC_APP_STORE_RELEASE_METADATA" && \
      "${MAC_APP_STORE_RELEASE_METADATA:A}" == "$MAC_APP_STORE_RELEASE_METADATA" ]]; then
    MAC_CANDIDATE_METADATA_PATH="${MAC_APP_STORE_RELEASE_METADATA:A}"
    MAC_CANDIDATE_DIRECTORY="${MAC_CANDIDATE_METADATA_PATH:h}"
    if [[ "$MAC_CANDIDATE_METADATA_PATH" == \
        "$PROJECT_DIR"/dist/macos-app-store/*/release-metadata.json && \
        ! -L "$MAC_CANDIDATE_DIRECTORY" && \
        "${MAC_CANDIDATE_DIRECTORY:A}" == "$MAC_CANDIDATE_DIRECTORY" ]]; then
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
          "${MAC_CANDIDATE_ARCHIVE_ZIP:A}" == "$MAC_CANDIDATE_ARCHIVE_ZIP" && \
          "${MAC_CANDIDATE_PACKAGE:A}" == "$MAC_CANDIDATE_PACKAGE" && \
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
              def export_method_matches_xcode:
                (.xcodeVersion | type == "string" and
                  test("^[0-9]+(\\.[0-9]+){1,2}$")) and
                ((.xcodeVersion | split(".")[0] | tonumber) as $xcodeMajor |
                  $xcodeMajor >= 14 and
                  .exportMethod == (if $xcodeMajor == 14 then
                    "app-store"
                  else
                    "app-store-connect"
                  end));
              .schemaVersion == 1 and .platform == "macOS" and
              .distribution == "mac-app-store" and .uploaded == false and
              .quarantineFree == true and
              .appBundleID == $bundle and .teamID == $team and
              .displayName == $displayName and .cloudContainerID == $container and
              .applicationCategory == "public.app-category.developer-tools" and
              .version == $version and .build == $build and
              .privacyPolicyURL == $privacyURL and .supportURL == $supportURL and
              .archiveZip == $archiveZip and .archiveZipSHA256 == $archiveSHA and
              .exportedPackage == $package and .packageSHA256 == $packageSHA and
              export_method_matches_xcode and .exportDestination == "export" and
              .provisioningProfile.certificateMatches == true
            ' "$MAC_CANDIDATE_METADATA_PATH" >/dev/null 2>&1; then
        MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY=true
        MAC_APP_STORE_ARCHIVE_ZIP_SHA256="$MAC_CANDIDATE_ARCHIVE_SHA"
        MAC_APP_STORE_PACKAGE_SHA256="$MAC_CANDIDATE_PACKAGE_SHA"
      fi
    fi
  fi
fi

MAC_APP_STORE_SUBMIT_TOOL="$PROJECT_DIR/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh"
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    -x "$MAC_APP_STORE_SUBMIT_TOOL" ]] && \
    "$MAC_APP_STORE_SUBMIT_TOOL" --check "$MAC_CANDIDATE_DIRECTORY" \
      >/dev/null 2>&1; then
  MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED=true
fi

MAC_PRIVACY_CANDIDATE_SHA256="$MAC_APP_STORE_PACKAGE_SHA256"
[[ -n "$MAC_PRIVACY_CANDIDATE_SHA256" ]] || \
  MAC_PRIVACY_CANDIDATE_SHA256="$MAC_APP_STORE_ARCHIVE_ZIP_SHA256"
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED" == true ]] && \
    privacy_evidence_matches_candidate \
      "macOS" "mac-app-store" "$MAC_BUNDLE_ID" "$MAC_MARKETING_VERSION" \
      "$MAC_BUILD_NUMBER" "$MAC_PRIVACY_CANDIDATE_SHA256"; then
  MAC_PRIVACY_RELEASE_EVIDENCE_READY=true
fi

if [[ -n "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE" ]]; then
  MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_CONFIGURED=true
fi
MAC_FUNCTIONAL_QA_VALIDATION_RESULT="$READINESS_ROOT/macos-functional-qa-validation.json"
MAC_FUNCTIONAL_QA_VALIDATOR="$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh"
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED" == true && \
    "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_CONFIGURED" == true && \
    -x "$MAC_FUNCTIONAL_QA_VALIDATOR" ]] && \
    "$MAC_FUNCTIONAL_QA_VALIDATOR" --json \
      --expected-release-metadata "$MAC_CANDIDATE_METADATA_PATH" \
      --expected-archive-sha256 "$MAC_APP_STORE_ARCHIVE_ZIP_SHA256" \
      --expected-package-sha256 "$MAC_APP_STORE_PACKAGE_SHA256" \
      "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE" \
      >"$MAC_FUNCTIONAL_QA_VALIDATION_RESULT" 2>/dev/null && \
    /usr/bin/jq -e \
      --arg evidence "${MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE:A}" \
      --arg evidenceSHA "$(file_sha256 "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE")" \
      --arg metadata "$MAC_CANDIDATE_METADATA_PATH" \
      --arg bundle "$MAC_BUNDLE_ID" --arg version "$MAC_MARKETING_VERSION" \
      --arg build "$MAC_BUILD_NUMBER" \
      --arg archiveZip "$MAC_CANDIDATE_ARCHIVE_ZIP" \
      --arg archiveSHA "$MAC_APP_STORE_ARCHIVE_ZIP_SHA256" \
      --arg package "$MAC_CANDIDATE_PACKAGE" \
      --arg packageSHA "$MAC_APP_STORE_PACKAGE_SHA256" '
        .evidenceReady == true and
        .evidencePath == $evidence and .evidenceSHA256 == $evidenceSHA and
        .candidate.appBundleID == $bundle and .candidate.version == $version and
        .candidate.build == $build and .candidate.archiveZipPath == $archiveZip and
        .candidate.archiveZipSHA256 == $archiveSHA and
        .candidate.packagePath == $package and
        .candidate.packageSHA256 == $packageSHA and
        (.testMachine.model | type == "string" and length > 0) and
        .testMachine.operatingSystem == "macOS" and
        (.testMachine.osVersion | type == "string" and length > 0) and
        (.testedAt | type == "string" and length > 0) and
        .sandboxFlowVerified == true and
        .archiveInstallLaunchQuitVerified == true and
        .profileCertificateVerified == true and
        .privacyReportVerified == true and .reviewPathVerified == true
      ' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT" >/dev/null 2>&1; then
  MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY=true
  MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE=true
  MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_PATH="$(/usr/bin/jq -r \
    '.evidencePath' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_QA_MAC_MODEL="$(/usr/bin/jq -r \
    '.testMachine.model' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_QA_OS_VERSION="$(/usr/bin/jq -r \
    '.testMachine.osVersion' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_QA_TESTED_AT="$(/usr/bin/jq -r \
    '.testedAt' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256="$(/usr/bin/jq -r \
    '.candidate.archiveZipSHA256' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256="$(/usr/bin/jq -r \
    '.candidate.packageSHA256' "$MAC_FUNCTIONAL_QA_VALIDATION_RESULT")"
  MAC_APP_STORE_SANDBOX_FLOW_VERIFIED=true
  MAC_APP_STORE_ARCHIVE_VERIFIED=true
  MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED=true
  MAC_APP_STORE_PRIVACY_REPORT_VERIFIED=true
  MAC_APP_STORE_REVIEW_PATH_VERIFIED=true
fi

if [[ -n "$MAC_APP_STORE_DELIVERY_EVIDENCE" ]]; then
  MAC_APP_STORE_DELIVERY_EVIDENCE_CONFIGURED=true
fi
MAC_DELIVERY_VALIDATION_RESULT="$READINESS_ROOT/macos-delivery-validation.json"
MAC_DELIVERY_VALIDATOR="$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh"
if [[ "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED" == true && \
    "$MAC_APP_STORE_DELIVERY_EVIDENCE_CONFIGURED" == true && \
    -x "$MAC_DELIVERY_VALIDATOR" ]] && \
    "$MAC_DELIVERY_VALIDATOR" --json "$MAC_APP_STORE_DELIVERY_EVIDENCE" \
      >"$MAC_DELIVERY_VALIDATION_RESULT" 2>/dev/null && \
    /usr/bin/jq -e \
      --arg evidence "${MAC_APP_STORE_DELIVERY_EVIDENCE:A}" \
      --arg evidenceSHA "$(file_sha256 "$MAC_APP_STORE_DELIVERY_EVIDENCE")" \
      --arg metadata "$MAC_CANDIDATE_METADATA_PATH" \
      --arg bundle "$MAC_BUNDLE_ID" --arg version "$MAC_MARKETING_VERSION" \
      --arg build "$MAC_BUILD_NUMBER" \
      --arg archiveZip "$MAC_CANDIDATE_ARCHIVE_ZIP" \
      --arg archiveSHA "$MAC_APP_STORE_ARCHIVE_ZIP_SHA256" \
      --arg package "$MAC_CANDIDATE_PACKAGE" \
      --arg packageSHA "$MAC_APP_STORE_PACKAGE_SHA256" '
        .schemaVersion == 1 and .platform == "macOS" and
        .evidenceVerified == true and
        .evidencePath == $evidence and .evidenceSHA256 == $evidenceSHA and
        .uploadAccepted == true and
        .processingState == null and .processingVerified == false and
        .submittedForAppReview == false and
        .releaseMetadataPath == $metadata and
        .appBundleID == $bundle and .version == $version and .build == $build and
        .archiveZipPath == $archiveZip and .archiveZipSHA256 == $archiveSHA and
        .packagePath == $package and .packageSHA256 == $packageSHA and
        (.submittedAt | type == "string" and length > 0)
      ' "$MAC_DELIVERY_VALIDATION_RESULT" >/dev/null 2>&1; then
  MAC_APP_STORE_DELIVERY_EVIDENCE_READY=true
  MAC_APP_STORE_DELIVERY_BOUND_TO_CANDIDATE=true
  MAC_APP_STORE_DELIVERY_EVIDENCE_PATH="$(/usr/bin/jq -r \
    '.evidencePath' "$MAC_DELIVERY_VALIDATION_RESULT")"
  MAC_APP_STORE_DELIVERY_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$MAC_DELIVERY_VALIDATION_RESULT")"
  MAC_APP_STORE_UPLOAD_ACCEPTED=true
  MAC_APP_STORE_UPLOAD_SUBMITTED_AT="$(/usr/bin/jq -r \
    '.submittedAt' "$MAC_DELIVERY_VALIDATION_RESULT")"
fi

if [[ -n "$MAC_APP_STORE_PROCESSING_EVIDENCE" ]]; then
  MAC_APP_STORE_PROCESSING_EVIDENCE_CONFIGURED=true
fi
MAC_PROCESSING_VALIDATION_RESULT="$READINESS_ROOT/macos-processing-validation.json"
MAC_PROCESSING_VALIDATOR="$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh"
if [[ "$MAC_APP_STORE_DELIVERY_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_PROCESSING_EVIDENCE_CONFIGURED" == true && \
    -x "$MAC_PROCESSING_VALIDATOR" ]] && \
    "$MAC_PROCESSING_VALIDATOR" --json "$MAC_APP_STORE_PROCESSING_EVIDENCE" \
      >"$MAC_PROCESSING_VALIDATION_RESULT" 2>/dev/null && \
    /usr/bin/jq -e --argjson delivery "$(/bin/cat "$MAC_DELIVERY_VALIDATION_RESULT")" \
      --arg evidence "${MAC_APP_STORE_PROCESSING_EVIDENCE:A}" \
      --arg evidenceSHA "$(file_sha256 "$MAC_APP_STORE_PROCESSING_EVIDENCE")" \
      --arg bundle "$MAC_BUNDLE_ID" --arg version "$MAC_MARKETING_VERSION" \
      --arg build "$MAC_BUILD_NUMBER" '
        .schemaVersion == 1 and .platform == "macOS" and
        .evidenceVerified == true and
        .evidencePath == $evidence and .evidenceSHA256 == $evidenceSHA and
        .deliveryEvidenceVerified == true and
        .uploadAccepted == true and .processingState == "Complete" and
        .processingVerified == true and .warningsReviewed == true and
        .submittedForAppReview == false and
        .appBundleID == $bundle and .version == $version and .build == $build and
        .deliveryRecordPath == $delivery.deliveryRecordPath and
        .deliveryRecordSHA256 == $delivery.deliveryRecordSHA256 and
        .releaseMetadataPath == $delivery.releaseMetadataPath and
        .releaseMetadataSHA256 == $delivery.releaseMetadataSHA256 and
        .archiveZipPath == $delivery.archiveZipPath and
        .archiveZipSHA256 == $delivery.archiveZipSHA256 and
        .packagePath == $delivery.packagePath and
        .packageSHA256 == $delivery.packageSHA256 and
        .validationResultPath == $delivery.validationResultPath and
        .validationResultSHA256 == $delivery.validationResultSHA256 and
        .uploadResultPath == $delivery.uploadResultPath and
        .uploadResultSHA256 == $delivery.uploadResultSHA256 and
        .submittedAt == $delivery.submittedAt and
        (.appStoreConnectBuildID | type == "string" and length > 0) and
        (.processingVerifiedAt | type == "string" and length > 0) and
        (.warningsReviewedAt | type == "string" and length > 0)
      ' "$MAC_PROCESSING_VALIDATION_RESULT" >/dev/null 2>&1; then
  MAC_APP_STORE_PROCESSING_EVIDENCE_READY=true
  MAC_APP_STORE_PROCESSING_BOUND_TO_DELIVERY=true
  MAC_APP_STORE_PROCESSING_EVIDENCE_PATH="$(/usr/bin/jq -r \
    '.evidencePath' "$MAC_PROCESSING_VALIDATION_RESULT")"
  MAC_APP_STORE_PROCESSING_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$MAC_PROCESSING_VALIDATION_RESULT")"
  MAC_APP_STORE_PROCESSING_STATE="Complete"
  MAC_APP_STORE_PROCESSING_VERIFIED=true
  MAC_APP_STORE_PROCESSING_VERIFIED_AT="$(/usr/bin/jq -r \
    '.processingVerifiedAt' "$MAC_PROCESSING_VALIDATION_RESULT")"
  MAC_APP_STORE_WARNINGS_REVIEWED=true
  MAC_APP_STORE_WARNINGS_REVIEWED_AT="$(/usr/bin/jq -r \
    '.warningsReviewedAt' "$MAC_PROCESSING_VALIDATION_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_ID="$(/usr/bin/jq -r \
    '.appStoreConnectBuildID' "$MAC_PROCESSING_VALIDATION_RESULT")"
fi

# App Store Connect is queried only by the explicit capture command. Readiness
# consumes its sealed build snapshots with the verifier's offline --verify mode
# and binds them back to the exact local artifacts and identity lock.
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED=false
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY=false
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY=false
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE=false
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=false
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED=""
MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE=""
MAC_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE=false

IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED=false
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY=false
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY=false
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE=false
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=false
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED=""
IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE=""
IOS_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE=false

ASC_BUILD_SNAPSHOT_VERIFIER="$PROJECT_DIR/scripts/capture-asc-build-snapshot.mjs"
MAC_ASC_BUILD_SNAPSHOT_RESULT="$READINESS_ROOT/macos-asc-build-snapshot.json"
MAC_ASC_BUILD_SNAPSHOT_LOG="$READINESS_ROOT/macos-asc-build-snapshot.log"
IOS_ASC_BUILD_SNAPSHOT_RESULT="$READINESS_ROOT/ios-asc-build-snapshot.json"
IOS_ASC_BUILD_SNAPSHOT_LOG="$READINESS_ROOT/ios-asc-build-snapshot.log"

if [[ -n "$MAC_ASC_BUILD_SNAPSHOT_INPUT" && \
    "$MAC_ASC_BUILD_SNAPSHOT_INPUT" == /* && \
    -f "$MAC_ASC_BUILD_SNAPSHOT_INPUT" && \
    ! -L "$MAC_ASC_BUILD_SNAPSHOT_INPUT" && \
    "${MAC_ASC_BUILD_SNAPSHOT_INPUT:A}" == "$MAC_ASC_BUILD_SNAPSHOT_INPUT" ]]; then
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED=true
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH="$MAC_ASC_BUILD_SNAPSHOT_INPUT"
fi
if [[ "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED" == true && \
    "$ASC_SNAPSHOT_MAX_AGE_VALID" == true && \
    "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" == true && \
    "$RELEASE_IDENTITY_LOCK_READY" == true ]] && \
    command -v node >/dev/null 2>&1 && \
    [[ -f "$ASC_BUILD_SNAPSHOT_VERIFIER" && ! -L "$ASC_BUILD_SNAPSHOT_VERIFIER" ]] && \
    node "$ASC_BUILD_SNAPSHOT_VERIFIER" \
      --verify "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
      --bundle-id "$MAC_BUNDLE_ID" \
      --platform macOS \
      --version "$MAC_MARKETING_VERSION" \
      --build "$MAC_BUILD_NUMBER" \
      --artifact "$MAC_CANDIDATE_PACKAGE" \
      --identity-lock "$RELEASE_IDENTITY_LOCK_PATH" \
      --max-age-seconds "$ASC_SNAPSHOT_MAX_AGE_SECONDS" \
      >"$MAC_ASC_BUILD_SNAPSHOT_RESULT" 2>"$MAC_ASC_BUILD_SNAPSHOT_LOG" && \
    /usr/bin/jq -e \
      --arg path "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
      --arg bundle "$MAC_BUNDLE_ID" \
      --arg version "$MAC_MARKETING_VERSION" \
      --arg build "$MAC_BUILD_NUMBER" \
      --arg artifact "$MAC_CANDIDATE_PACKAGE" \
      --arg identity "$RELEASE_IDENTITY_LOCK_PATH" '
        .verified == true and
        .kind == "app-store-connect-build-snapshot" and
        .snapshotPath == $path and
        (.snapshotSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.evidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.capturedAt | type == "string" and length > 0) and
        (.expiresAt | type == "string" and length > 0) and
        .query.bundleID == $bundle and .query.platform == "MAC_OS" and
        .query.version == $version and .query.build == $build and
        .candidate.artifactPath == $artifact and
        .candidate.releaseIdentityLockPath == $identity and
        .app.bundleID == $bundle and
        .app.resourceID == .resourceIDs.app and
        .build.resourceID == .resourceIDs.build and
        (.app.resourceID | type == "string" and length > 0) and
        (.build.resourceID | type == "string" and length > 0) and
        (.app.sku | type == "string" and length > 0) and
        (.app.primaryLocale | type == "string" and length > 0) and
        (.readiness.snapshotReady | type == "boolean") and
        (.readiness.exportComplianceRequired | type == "boolean") and
        (.readiness.buildUploadErrorFree | type == "boolean") and
        (.readiness.warningsPresent | type == "boolean")
      ' "$MAC_ASC_BUILD_SNAPSHOT_RESULT" >/dev/null 2>&1; then
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256="$(/usr/bin/jq -r \
    '.snapshotSHA256' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT="$(/usr/bin/jq -r \
    '.capturedAt' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT="$(/usr/bin/jq -r \
    '.expiresAt' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID="$(/usr/bin/jq -r \
    '.resourceIDs.app' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID="$(/usr/bin/jq -r \
    '.resourceIDs.build' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT="$(/usr/bin/jq -r \
    '.readiness.warningsPresent' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED="$(/usr/bin/jq -r \
    '.readiness.exportComplianceRequired' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE="$(/usr/bin/jq -r \
    '.readiness.buildUploadErrorFree' "$MAC_ASC_BUILD_SNAPSHOT_RESULT")"
  [[ "$(/usr/bin/jq -r '.readiness.snapshotReady' \
    "$MAC_ASC_BUILD_SNAPSHOT_RESULT")" == true ]] && \
    MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY=true
  if [[ "$MAC_APP_STORE_SUBMISSION_MANIFEST_READY" == true ]] && \
      /usr/bin/jq -e \
        --arg appResourceID "$MAC_APP_STORE_EXPECTED_APP_RESOURCE_ID" \
        --arg sku "$MAC_APP_STORE_EXPECTED_SKU" \
        --arg primaryLocale "$MAC_APP_STORE_EXPECTED_PRIMARY_LOCALE" '
          .app.resourceID == $appResourceID and
          .app.sku == $sku and .app.primaryLocale == $primaryLocale
        ' "$MAC_ASC_BUILD_SNAPSHOT_RESULT" >/dev/null 2>&1; then
    MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY=true
  fi
  if [[ "$MAC_APP_STORE_PROCESSING_EVIDENCE_READY" == true && \
      -n "$MAC_APP_STORE_CONNECT_BUILD_ID" && \
      "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID" == \
        "$MAC_APP_STORE_CONNECT_BUILD_ID" ]]; then
    MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE=true
  fi
  if [[ "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT" == false ]]; then
    MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=true
  elif [[ "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" == true && \
      "$MAC_APP_STORE_WARNINGS_REVIEWED" == true ]]; then
    MAC_ASC_CAPTURED_AT_MILLISECONDS="$(utc_timestamp_milliseconds \
      "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT" || true)"
    MAC_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS="$(utc_timestamp_milliseconds \
      "$MAC_APP_STORE_WARNINGS_REVIEWED_AT" || true)"
    if [[ "$MAC_ASC_CAPTURED_AT_MILLISECONDS" == <-> && \
        "$MAC_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS" == <-> ]] && \
        (( MAC_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS >= \
          MAC_ASC_CAPTURED_AT_MILLISECONDS )); then
      MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=true
    fi
  fi
fi

IOS_ASC_ARTIFACT_PATH="${IOS_EVIDENCE_IPA_PATH:-}"
if [[ -n "$IOS_ASC_BUILD_SNAPSHOT_INPUT" && \
    "$IOS_ASC_BUILD_SNAPSHOT_INPUT" == /* && \
    -f "$IOS_ASC_BUILD_SNAPSHOT_INPUT" && \
    ! -L "$IOS_ASC_BUILD_SNAPSHOT_INPUT" && \
    "${IOS_ASC_BUILD_SNAPSHOT_INPUT:A}" == "$IOS_ASC_BUILD_SNAPSHOT_INPUT" ]]; then
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED=true
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH="$IOS_ASC_BUILD_SNAPSHOT_INPUT"
fi
if [[ "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED" == true && \
    "$ASC_SNAPSHOT_MAX_AGE_VALID" == true && \
    "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true && \
    "$RELEASE_IDENTITY_LOCK_READY" == true ]] && \
    command -v node >/dev/null 2>&1 && \
    [[ -f "$ASC_BUILD_SNAPSHOT_VERIFIER" && ! -L "$ASC_BUILD_SNAPSHOT_VERIFIER" ]] && \
    node "$ASC_BUILD_SNAPSHOT_VERIFIER" \
      --verify "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
      --bundle-id "$IOS_APP_BUNDLE_ID" \
      --platform iOS \
      --version "$IOS_MARKETING_VERSION" \
      --build "$IOS_BUILD_NUMBER" \
      --artifact "$IOS_ASC_ARTIFACT_PATH" \
      --identity-lock "$RELEASE_IDENTITY_LOCK_PATH" \
      --max-age-seconds "$ASC_SNAPSHOT_MAX_AGE_SECONDS" \
      >"$IOS_ASC_BUILD_SNAPSHOT_RESULT" 2>"$IOS_ASC_BUILD_SNAPSHOT_LOG" && \
    /usr/bin/jq -e \
      --arg path "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
      --arg bundle "$IOS_APP_BUNDLE_ID" \
      --arg version "$IOS_MARKETING_VERSION" \
      --arg build "$IOS_BUILD_NUMBER" \
      --arg artifact "$IOS_ASC_ARTIFACT_PATH" \
      --arg identity "$RELEASE_IDENTITY_LOCK_PATH" '
        .verified == true and
        .kind == "app-store-connect-build-snapshot" and
        .snapshotPath == $path and
        (.snapshotSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.evidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.capturedAt | type == "string" and length > 0) and
        (.expiresAt | type == "string" and length > 0) and
        .query.bundleID == $bundle and .query.platform == "IOS" and
        .query.version == $version and .query.build == $build and
        .candidate.artifactPath == $artifact and
        .candidate.releaseIdentityLockPath == $identity and
        .app.bundleID == $bundle and
        .app.resourceID == .resourceIDs.app and
        .build.resourceID == .resourceIDs.build and
        (.app.resourceID | type == "string" and length > 0) and
        (.build.resourceID | type == "string" and length > 0) and
        (.app.sku | type == "string" and length > 0) and
        (.app.primaryLocale | type == "string" and length > 0) and
        (.readiness.snapshotReady | type == "boolean") and
        (.readiness.exportComplianceRequired | type == "boolean") and
        (.readiness.buildUploadErrorFree | type == "boolean") and
        (.readiness.warningsPresent | type == "boolean")
      ' "$IOS_ASC_BUILD_SNAPSHOT_RESULT" >/dev/null 2>&1; then
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256="$(/usr/bin/jq -r \
    '.snapshotSHA256' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256="$(/usr/bin/jq -r \
    '.evidenceSHA256' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT="$(/usr/bin/jq -r \
    '.capturedAt' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT="$(/usr/bin/jq -r \
    '.expiresAt' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID="$(/usr/bin/jq -r \
    '.resourceIDs.app' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID="$(/usr/bin/jq -r \
    '.resourceIDs.build' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT="$(/usr/bin/jq -r \
    '.readiness.warningsPresent' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED="$(/usr/bin/jq -r \
    '.readiness.exportComplianceRequired' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE="$(/usr/bin/jq -r \
    '.readiness.buildUploadErrorFree' "$IOS_ASC_BUILD_SNAPSHOT_RESULT")"
  [[ "$(/usr/bin/jq -r '.readiness.snapshotReady' \
    "$IOS_ASC_BUILD_SNAPSHOT_RESULT")" == true ]] && \
    IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY=true
  if [[ "$IOS_APP_STORE_SUBMISSION_MANIFEST_READY" == true ]] && \
      /usr/bin/jq -e \
        --arg appResourceID "$IOS_APP_STORE_EXPECTED_APP_RESOURCE_ID" \
        --arg sku "$IOS_APP_STORE_EXPECTED_SKU" \
        --arg primaryLocale "$IOS_APP_STORE_EXPECTED_PRIMARY_LOCALE" '
          .app.resourceID == $appResourceID and
          .app.sku == $sku and .app.primaryLocale == $primaryLocale
        ' "$IOS_ASC_BUILD_SNAPSHOT_RESULT" >/dev/null 2>&1; then
    IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY=true
  fi
  if [[ "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true && \
      -n "$IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID" && \
      "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID" == \
        "$IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID" ]]; then
    IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE=true
  fi
  if [[ "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT" == false ]]; then
    IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=true
  elif [[ "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" == true && \
      "$IOS_TESTFLIGHT_WARNINGS_REVIEWED" == true ]]; then
    IOS_ASC_CAPTURED_AT_MILLISECONDS="$(utc_timestamp_milliseconds \
      "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT" || true)"
    IOS_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS="$(utc_timestamp_milliseconds \
      "$IOS_TESTFLIGHT_WARNINGS_REVIEWED_AT" || true)"
    if [[ "$IOS_ASC_CAPTURED_AT_MILLISECONDS" == <-> && \
        "$IOS_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS" == <-> ]] && \
        (( IOS_ASC_WARNINGS_REVIEWED_AT_MILLISECONDS >= \
          IOS_ASC_CAPTURED_AT_MILLISECONDS )); then
      IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT=true
    fi
  fi
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
(( XCODE_MAJOR >= MINIMUM_IOS_XCODE_MAJOR && IPHONE_SDK_MAJOR >= MINIMUM_IOS_SDK_MAJOR )) \
  && CURRENT_UPLOAD_TOOLCHAIN=true
CURRENT_MAC_APP_STORE_TOOLCHAIN=false
(( XCODE_MAJOR >= MINIMUM_MAC_APP_STORE_XCODE_MAJOR )) \
  && CURRENT_MAC_APP_STORE_TOOLCHAIN=true
ENOUGH_DISK_FOR_XCODE=false
(( AVAILABLE_GIB >= 30 )) && ENOUGH_DISK_FOR_XCODE=true

READY_DEVELOPER_ID=false
if [[ "$MAC_DEVELOPER_ID_TOOLCHAIN" == true && "$DEVELOPER_ID_IDENTITIES" -gt 0 && "$MAC_SIGN_IDENTITY_READY" == true && "$MAC_BUNDLE_READY" == true && \
  "$DISPLAY_NAME_READY" == true && "$MAC_ARCHIVE_SET_CLEAN" == true && \
  "$RELEASE_IDENTITY_LOCK_READY" == true && \
  "$RELEASE_IDENTITY_AUXILIARY_FILES_MATCH" == true && \
  "$RELEASE_IDENTITY_PROFILE_ASSETS_MATCH" == true && \
  "$NOTARY_PROFILE_CONFIGURED" == true && "$ENTITLEMENTS_READY" == true && \
  "$PROVISIONING_PROFILE_READY" == true && "$PROVISIONING_PROFILE_CERTIFICATE_READY" == true && \
  "$CLOUDKIT_CONTAINER_READY" == true && "$RELEASE_PRIVACY_READY" == true && \
  "$RELEASE_SUPPORT_READY" == true && "$CONFIGURED_TEAM_READY" == true ]]; then
  READY_DEVELOPER_ID=true
fi

READY_IOS_ARCHIVE=false
if [[ "$FULL_XCODE" == true && "$XCODE_26_HOST_COMPATIBLE" == true && \
  "$CURRENT_UPLOAD_TOOLCHAIN" == true && "$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY" == true && \
  "$RELEASE_IDENTITY_LOCK_READY" == true && \
  "$IOS_PROJECT" == true && "$IOS_PROJECT_RELEASE_VALIDATION" == true && \
  "$IOS_BUILD_SETTINGS_RESOLVED" == true && "$IOS_TARGET_BUILD_SETTINGS_CONFIGURED" == true && \
  "$IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED" == true && "$IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT" == true && \
  "$IOS_PRIVACY_MANIFEST" == true && "$IOS_APP_ICON" == true && \
  "$IOS_APP_BUNDLE_READY" == true && "$IOS_WIDGET_BUNDLE_READY" == true && "$IOS_TEAM_READY" == true && \
  "$IOS_CONTAINER_READY" == true && "$IOS_PRIVACY_READY" == true && "$IOS_SUPPORT_READY" == true ]]; then
  READY_IOS_ARCHIVE=true
fi

# TestFlight functional readiness deliberately excludes App Store marketing
# assets. A build can be tested before its final screenshots and store copy are
# ready, so keep that state independent and compose a stricter App Store review
# selection gate below.
READY_FUNCTIONAL_IOS_TESTFLIGHT=false
if [[ "$READY_IOS_ARCHIVE" == true && "$IOS_SYNC_IMPLEMENTED" == true && \
    "$IOS_CONTAINER_READY" == true && "$IOS_PRIVACY_READY" == true && \
    "$IOS_SUPPORT_READY" == true && \
    "$IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED" == true && \
    "$IOS_REAL_DEVICE_SYNC_VERIFIED" == true && \
    "$IOS_LIVE_ACTIVITY_VERIFIED" == true && "$IOS_REVIEW_PATH_VERIFIED" == true && \
    "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" == true && \
    "$IOS_FUNCTIONAL_QA_EVIDENCE_READY" == true && \
    "$IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" == true && \
    "$IOS_TESTFLIGHT_UPLOAD_VERIFIED" == true && \
    "$IOS_TESTFLIGHT_PROCESSING_VERIFIED" == true && \
    "$IOS_TESTFLIGHT_INSTALL_VERIFIED" == true && \
    "$IOS_TESTFLIGHT_WARNINGS_REVIEWED" == true && \
    "$IOS_PRIVACY_RELEASE_EVIDENCE_READY" == true ]]; then
  READY_FUNCTIONAL_IOS_TESTFLIGHT=true
fi

# This state stays closed until a trusted integration compares the full remote
# App Store metadata, not just the App identity returned with a Build snapshot.
# Even then it only permits a human selection step; it never records a remote
# selection, Add for Review, or Submit for Review action.
READY_IOS_APP_STORE_REVIEW_SELECTION=false
if [[ "$READY_FUNCTIONAL_IOS_TESTFLIGHT" == true && \
    "$IOS_STORE_SUBMISSION_ASSETS_READY" == true && \
    "$IOS_APP_STORE_SUBMISSION_MANIFEST_READY" == true && \
    "$PUBLIC_PAGES_EVIDENCE_READY" == true && \
    "$PUBLIC_PAGES_EVIDENCE_BOUND_TO_SUBMISSION_MANIFEST" == true && \
    "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY" == true && \
    "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY" == true && \
    "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" == true && \
    "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT" == true && \
    "$IOS_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE" == true && \
    "$MAC_APP_STORE_RECORD_MODE_READY" == true && \
    "$MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID" == true && \
    "$IOS_TESTFLIGHT_WARNINGS_REVIEWED" == true && \
    -n "$IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID" ]]; then
  READY_IOS_APP_STORE_REVIEW_SELECTION=true
fi

READY_MAC_APP_STORE_ARCHIVE=false
if [[ "$FULL_XCODE" == true && \
    "$CURRENT_MAC_APP_STORE_TOOLCHAIN" == true && \
    "$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY" == true && \
    "$RELEASE_IDENTITY_LOCK_READY" == true && \
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
    "$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED" == true && \
    "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" == true && \
    "$MAC_APP_STORE_SANDBOX_FLOW_VERIFIED" == true && \
    "$MAC_APP_STORE_ARCHIVE_VERIFIED" == true && \
    "$MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED" == true && \
    "$MAC_APP_STORE_PRIVACY_REPORT_VERIFIED" == true && \
    "$MAC_APP_STORE_REVIEW_PATH_VERIFIED" == true && \
    "$IOS_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED" == true && \
    "$MAC_PRIVACY_RELEASE_EVIDENCE_READY" == true && \
    "$MAC_STORE_SUBMISSION_ASSETS_READY" == true ]]; then
  READY_MAC_APP_STORE_UPLOAD=true
fi

# A processed build may be selected while preparing App Review only after the
# independently verified delivery and processing records bind the same exact
# upload and a trusted integration compares the full remote App metadata. This
# does not claim that the build has been selected or submitted.
READY_MAC_APP_STORE_REVIEW_SELECTION=false
if [[ "$READY_MAC_APP_STORE_UPLOAD" == true && \
    "$MAC_APP_STORE_SUBMISSION_MANIFEST_READY" == true && \
    "$PUBLIC_PAGES_EVIDENCE_READY" == true && \
    "$PUBLIC_PAGES_EVIDENCE_BOUND_TO_SUBMISSION_MANIFEST" == true && \
    "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY" == true && \
    "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY" == true && \
    "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" == true && \
    "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT" == true && \
    "$MAC_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE" == true && \
    "$MAC_APP_STORE_DELIVERY_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_DELIVERY_BOUND_TO_CANDIDATE" == true && \
    "$MAC_APP_STORE_UPLOAD_ACCEPTED" == true && \
    "$MAC_APP_STORE_PROCESSING_EVIDENCE_READY" == true && \
    "$MAC_APP_STORE_PROCESSING_BOUND_TO_DELIVERY" == true && \
    "$MAC_APP_STORE_PROCESSING_VERIFIED" == true && \
    "$MAC_APP_STORE_PROCESSING_STATE" == "Complete" && \
    "$MAC_APP_STORE_WARNINGS_REVIEWED" == true && \
    "$MAC_APP_STORE_APP_REVIEW_SUBMISSION_RECORDED" == false ]]; then
  READY_MAC_APP_STORE_REVIEW_SELECTION=true
fi

# Backward-compatible output only. No local evidence currently records the
# remote App Review submission action, so this legacy field remains false.
READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=false

/usr/bin/jq -n \
  --arg developerPath "$DEVELOPER_PATH" \
  --arg hostMacOSVersion "$HOST_MACOS_VERSION" \
  --arg minimumXcode26HostMacOS "$MINIMUM_XCODE_26_HOST_MACOS" \
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
  --arg iosTestFlightIPASHA256 "$IOS_TESTFLIGHT_IPA_SHA256" \
  --arg iosTestFlightAppStoreConnectBuildID "$IOS_TESTFLIGHT_APP_STORE_CONNECT_BUILD_ID" \
  --arg iosTestFlightProcessingState "$IOS_TESTFLIGHT_PROCESSING_STATE" \
  --arg iosTestFlightWarningsReviewedAt "$IOS_TESTFLIGHT_WARNINGS_REVIEWED_AT" \
  --arg iosFunctionalQAEvidenceInputPath "$IOS_FUNCTIONAL_QA_EVIDENCE" \
  --arg iosFunctionalQAEvidencePath "$IOS_FUNCTIONAL_QA_EVIDENCE_PATH" \
  --arg iosFunctionalQAEvidenceSHA256 "$IOS_FUNCTIONAL_QA_EVIDENCE_SHA256" \
  --arg iosFunctionalQADeviceModel "$IOS_FUNCTIONAL_QA_DEVICE_MODEL" \
  --arg iosFunctionalQAOSVersion "$IOS_FUNCTIONAL_QA_OS_VERSION" \
  --arg iosFunctionalQATestedAt "$IOS_FUNCTIONAL_QA_TESTED_AT" \
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
  --arg releaseIdentityLockPath "$RELEASE_IDENTITY_LOCK_PATH" \
  --arg releaseIdentityLockSHA256 "$RELEASE_IDENTITY_LOCK_SHA256" \
  --arg releaseIdentityInputSchemaVersion "$RELEASE_IDENTITY_INPUT_SCHEMA_VERSION" \
  --arg releaseIdentityNormalizedSchemaVersion "$RELEASE_IDENTITY_NORMALIZED_SCHEMA_VERSION" \
  --arg releaseIdentityRecordMode "$RELEASE_IDENTITY_RECORD_MODE" \
  --arg macAppStoreFunctionalQAEvidenceInputPath "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE" \
  --arg macAppStoreFunctionalQAEvidencePath "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_PATH" \
  --arg macAppStoreFunctionalQAEvidenceSHA256 "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_SHA256" \
  --arg macAppStoreFunctionalQAMacModel "$MAC_APP_STORE_FUNCTIONAL_QA_MAC_MODEL" \
  --arg macAppStoreFunctionalQAOSVersion "$MAC_APP_STORE_FUNCTIONAL_QA_OS_VERSION" \
  --arg macAppStoreFunctionalQATestedAt "$MAC_APP_STORE_FUNCTIONAL_QA_TESTED_AT" \
  --arg macAppStoreFunctionalEvidenceArchiveSHA256 "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256" \
  --arg macAppStoreFunctionalEvidencePackageSHA256 "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256" \
  --arg macAppStoreDeliveryEvidenceInputPath "$MAC_APP_STORE_DELIVERY_EVIDENCE" \
  --arg macAppStoreDeliveryEvidencePath "$MAC_APP_STORE_DELIVERY_EVIDENCE_PATH" \
  --arg macAppStoreDeliveryEvidenceSHA256 "$MAC_APP_STORE_DELIVERY_EVIDENCE_SHA256" \
  --arg macAppStoreUploadSubmittedAt "$MAC_APP_STORE_UPLOAD_SUBMITTED_AT" \
  --arg macAppStoreProcessingEvidenceInputPath "$MAC_APP_STORE_PROCESSING_EVIDENCE" \
  --arg macAppStoreProcessingEvidencePath "$MAC_APP_STORE_PROCESSING_EVIDENCE_PATH" \
  --arg macAppStoreProcessingEvidenceSHA256 "$MAC_APP_STORE_PROCESSING_EVIDENCE_SHA256" \
  --arg macAppStoreProcessingState "$MAC_APP_STORE_PROCESSING_STATE" \
  --arg macAppStoreProcessingVerifiedAt "$MAC_APP_STORE_PROCESSING_VERIFIED_AT" \
  --arg macAppStoreWarningsReviewedAt "$MAC_APP_STORE_WARNINGS_REVIEWED_AT" \
  --arg macAppStoreConnectBuildID "$MAC_APP_STORE_CONNECT_BUILD_ID" \
  --arg appStoreRecordMode "$MAC_APP_STORE_RECORD_MODE" \
  --arg appStoreSubmissionManifestPath "$APP_STORE_SUBMISSION_MANIFEST_PATH" \
  --arg appStoreSubmissionManifestSHA256 "$APP_STORE_SUBMISSION_MANIFEST_SHA256" \
  --arg macAppStoreExpectedAppResourceID "$MAC_APP_STORE_EXPECTED_APP_RESOURCE_ID" \
  --arg macAppStoreExpectedSKU "$MAC_APP_STORE_EXPECTED_SKU" \
  --arg macAppStoreExpectedPrimaryLocale "$MAC_APP_STORE_EXPECTED_PRIMARY_LOCALE" \
  --arg iosAppStoreExpectedAppResourceID "$IOS_APP_STORE_EXPECTED_APP_RESOURCE_ID" \
  --arg iosAppStoreExpectedSKU "$IOS_APP_STORE_EXPECTED_SKU" \
  --arg iosAppStoreExpectedPrimaryLocale "$IOS_APP_STORE_EXPECTED_PRIMARY_LOCALE" \
  --arg publicPagesEvidencePath "$PUBLIC_PAGES_EVIDENCE_PATH" \
  --arg publicPagesEvidenceSHA256 "$PUBLIC_PAGES_EVIDENCE_SHA256" \
  --arg publicPagesEvidenceBindingType "$PUBLIC_PAGES_EVIDENCE_BINDING_TYPE" \
  --arg publicPagesEvidenceBindingPath "$PUBLIC_PAGES_EVIDENCE_BINDING_PATH" \
  --arg publicPagesEvidenceBindingSHA256 "$PUBLIC_PAGES_EVIDENCE_BINDING_SHA256" \
  --arg publicPagesEvidenceOldestCheckedAt "$PUBLIC_PAGES_EVIDENCE_OLDEST_CHECKED_AT" \
  --arg publicPagesEvidenceNewestCheckedAt "$PUBLIC_PAGES_EVIDENCE_NEWEST_CHECKED_AT" \
  --arg appStoreConnectSnapshotMaxAgeSeconds "$ASC_SNAPSHOT_MAX_AGE_SECONDS" \
  --arg macAppStoreConnectBuildSnapshotPath "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
  --arg macAppStoreConnectBuildSnapshotSHA256 "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256" \
  --arg macAppStoreConnectEvidenceSHA256 "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256" \
  --arg macAppStoreConnectBuildSnapshotCapturedAt "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT" \
  --arg macAppStoreConnectBuildSnapshotExpiresAt "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT" \
  --arg macAppStoreConnectBuildSnapshotAppResourceID "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID" \
  --arg macAppStoreConnectBuildSnapshotBuildResourceID "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID" \
  --arg macAppStoreConnectBuildSnapshotExportComplianceRequired "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED" \
  --arg macAppStoreConnectBuildSnapshotBuildUploadErrorFree "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE" \
  --arg iosAppStoreConnectBuildSnapshotPath "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_PATH" \
  --arg iosAppStoreConnectBuildSnapshotSHA256 "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_SHA256" \
  --arg iosAppStoreConnectEvidenceSHA256 "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EVIDENCE_SHA256" \
  --arg iosAppStoreConnectBuildSnapshotCapturedAt "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CAPTURED_AT" \
  --arg iosAppStoreConnectBuildSnapshotExpiresAt "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPIRES_AT" \
  --arg iosAppStoreConnectBuildSnapshotAppResourceID "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_APP_RESOURCE_ID" \
  --arg iosAppStoreConnectBuildSnapshotBuildResourceID "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_RESOURCE_ID" \
  --arg iosAppStoreConnectBuildSnapshotExportComplianceRequired "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_EXPORT_COMPLIANCE_REQUIRED" \
  --arg iosAppStoreConnectBuildSnapshotBuildUploadErrorFree "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_BUILD_UPLOAD_ERROR_FREE" \
  --argjson fullXcode "$FULL_XCODE" \
  --argjson minimumRequiredXcodeMajor "$MINIMUM_IOS_XCODE_MAJOR" \
  --argjson minimumRequiredMacAppStoreXcodeMajor "$MINIMUM_MAC_APP_STORE_XCODE_MAJOR" \
  --argjson minimumRequiredIOSSDKMajor "$MINIMUM_IOS_SDK_MAJOR" \
  --argjson xcode26HostCompatible "$XCODE_26_HOST_COMPATIBLE" \
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
  --argjson releaseIdentityLockConfigured "$RELEASE_IDENTITY_LOCK_CONFIGURED" \
  --argjson releaseIdentityLockValid "$RELEASE_IDENTITY_LOCK_VALID" \
  --argjson releaseIdentityAppliedFilesMatch "$RELEASE_IDENTITY_APPLIED_FILES_MATCH" \
  --argjson releaseIdentityMatchesConfiguration "$RELEASE_IDENTITY_MATCHES_CONFIGURATION" \
  --argjson releaseIdentityAuxiliaryFilesMatch "$RELEASE_IDENTITY_AUXILIARY_FILES_MATCH" \
  --argjson releaseIdentityProfileRecordsPresent "$RELEASE_IDENTITY_PROFILE_RECORDS_PRESENT" \
  --argjson releaseIdentityProfileAssetsMatch "$RELEASE_IDENTITY_PROFILE_ASSETS_MATCH" \
  --argjson releaseIdentityLockReady "$RELEASE_IDENTITY_LOCK_READY" \
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
  --argjson iosTestFlightWarningsReviewed "$IOS_TESTFLIGHT_WARNINGS_REVIEWED" \
  --argjson iosTestFlightEvidenceConfigured "$IOS_TESTFLIGHT_EVIDENCE_CONFIGURED" \
  --argjson iosLocalIPAPreflightPassed "$IOS_LOCAL_IPA_PREFLIGHT_READY" \
  --argjson iosTestFlightExactBuildEvidenceReady "$IOS_TESTFLIGHT_EXACT_BUILD_EVIDENCE_READY" \
  --argjson iosFunctionalQAEvidenceConfigured "$IOS_FUNCTIONAL_QA_EVIDENCE_CONFIGURED" \
  --argjson iosFunctionalQAEvidenceReady "$IOS_FUNCTIONAL_QA_EVIDENCE_READY" \
  --argjson iosFunctionalEvidenceBoundToCandidate "$IOS_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" \
  --argjson iosProject "$IOS_PROJECT" \
  --argjson iosProjectReleaseValidation "$IOS_PROJECT_RELEASE_VALIDATION" \
  --argjson iosProjectReleaseValidationMessages "$IOS_PROJECT_RELEASE_VALIDATION_MESSAGES_JSON" \
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
  --argjson macStoreSubmissionAssetsReady "$MAC_STORE_SUBMISSION_ASSETS_READY" \
  --argjson iosStoreSubmissionAssetsReady "$IOS_STORE_SUBMISSION_ASSETS_READY" \
  --argjson storeSubmissionBlockers "$STORE_SUBMISSION_BLOCKERS_JSON" \
  --argjson storeSubmissionStructuralErrors "$STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson macStoreSubmissionBlockers "$MAC_STORE_SUBMISSION_BLOCKERS_JSON" \
  --argjson iosStoreSubmissionBlockers "$IOS_STORE_SUBMISSION_BLOCKERS_JSON" \
  --argjson macStoreSubmissionStructuralErrors "$MAC_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson iosStoreSubmissionStructuralErrors "$IOS_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson appStoreSubmissionManifestConfigured "$APP_STORE_SUBMISSION_MANIFEST_CONFIGURED" \
  --argjson appStoreSubmissionManifestReady "$APP_STORE_SUBMISSION_MANIFEST_READY" \
  --argjson macAppStoreSubmissionManifestReady "$MAC_APP_STORE_SUBMISSION_MANIFEST_READY" \
  --argjson iosAppStoreSubmissionManifestReady "$IOS_APP_STORE_SUBMISSION_MANIFEST_READY" \
  --argjson appStoreSubmissionStructuralErrors "$APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson appStoreSubmissionReleaseBlockers "$APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON" \
  --argjson macAppStoreSubmissionStructuralErrors "$MAC_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson macAppStoreSubmissionReleaseBlockers "$MAC_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON" \
  --argjson iosAppStoreSubmissionStructuralErrors "$IOS_APP_STORE_SUBMISSION_STRUCTURAL_ERRORS_JSON" \
  --argjson iosAppStoreSubmissionReleaseBlockers "$IOS_APP_STORE_SUBMISSION_RELEASE_BLOCKERS_JSON" \
  --argjson publicPagesEvidenceConfigured "$PUBLIC_PAGES_EVIDENCE_CONFIGURED" \
  --argjson publicPagesEvidenceReady "$PUBLIC_PAGES_EVIDENCE_READY" \
  --argjson publicPagesEvidenceBoundToSubmissionManifest "$PUBLIC_PAGES_EVIDENCE_BOUND_TO_SUBMISSION_MANIFEST" \
  --argjson publicPagesEvidenceMaxAgeSeconds "$PUBLIC_PAGES_EVIDENCE_MAX_AGE_SECONDS" \
  --argjson appStoreConnectSnapshotMaxAgeValid "$ASC_SNAPSHOT_MAX_AGE_VALID" \
  --argjson macAppStoreConnectBuildSnapshotConfigured "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED" \
  --argjson macAppStoreConnectBuildSnapshotReady "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY" \
  --arg macAppStoreConnectBuildSnapshotWarningsPresent "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT" \
  --argjson macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY" \
  --argjson macAppStoreConnectBuildSnapshotMatchesOperatorEvidence "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" \
  --argjson macAppStoreConnectBuildSnapshotWarningReviewCurrent "$MAC_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT" \
  --argjson macAppStoreConnectRemoteMetadataComparisonComplete "$MAC_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE" \
  --argjson iosAppStoreConnectBuildSnapshotConfigured "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_CONFIGURED" \
  --argjson iosAppStoreConnectBuildSnapshotReady "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_READY" \
  --arg iosAppStoreConnectBuildSnapshotWarningsPresent "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNINGS_PRESENT" \
  --argjson iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_SUBMISSION_APP_IDENTITY" \
  --argjson iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_MATCHES_OPERATOR_EVIDENCE" \
  --argjson iosAppStoreConnectBuildSnapshotWarningReviewCurrent "$IOS_APP_STORE_CONNECT_BUILD_SNAPSHOT_WARNING_REVIEW_CURRENT" \
  --argjson iosAppStoreConnectRemoteMetadataComparisonComplete "$IOS_APP_STORE_CONNECT_REMOTE_METADATA_COMPARISON_COMPLETE" \
  --argjson macAppStoreReleaseMetadataConfigured "$MAC_APP_STORE_RELEASE_METADATA_CONFIGURED" \
  --argjson macAppStoreExactCandidateEvidenceReady "$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY" \
  --argjson macAppStoreLocalPreflightPassed "$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED" \
  --argjson macAppStoreFunctionalQAEvidenceConfigured "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_CONFIGURED" \
  --argjson macAppStoreFunctionalQAEvidenceReady "$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY" \
  --argjson macAppStoreFunctionalEvidenceBoundToCandidate "$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE" \
  --argjson macAppStoreDeliveryEvidenceConfigured "$MAC_APP_STORE_DELIVERY_EVIDENCE_CONFIGURED" \
  --argjson macAppStoreDeliveryEvidenceReady "$MAC_APP_STORE_DELIVERY_EVIDENCE_READY" \
  --argjson macAppStoreDeliveryBoundToCandidate "$MAC_APP_STORE_DELIVERY_BOUND_TO_CANDIDATE" \
  --argjson macAppStoreUploadAccepted "$MAC_APP_STORE_UPLOAD_ACCEPTED" \
  --argjson macAppStoreProcessingEvidenceConfigured "$MAC_APP_STORE_PROCESSING_EVIDENCE_CONFIGURED" \
  --argjson macAppStoreProcessingEvidenceReady "$MAC_APP_STORE_PROCESSING_EVIDENCE_READY" \
  --argjson macAppStoreProcessingBoundToDelivery "$MAC_APP_STORE_PROCESSING_BOUND_TO_DELIVERY" \
  --argjson macAppStoreProcessingVerified "$MAC_APP_STORE_PROCESSING_VERIFIED" \
  --argjson macAppStoreWarningsReviewed "$MAC_APP_STORE_WARNINGS_REVIEWED" \
  --argjson macAppStoreAppReviewSubmissionRecorded "$MAC_APP_STORE_APP_REVIEW_SUBMISSION_RECORDED" \
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
  --argjson readyMacAppStoreReviewSelection "$READY_MAC_APP_STORE_REVIEW_SELECTION" \
  --argjson readyFunctionalMacAppStoreSubmission "$READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION" \
  --argjson readyIOSArchive "$READY_IOS_ARCHIVE" \
  --argjson readyFunctionalIOSTestFlight "$READY_FUNCTIONAL_IOS_TESTFLIGHT" \
  --argjson readyIOSAppStoreReviewSelection "$READY_IOS_APP_STORE_REVIEW_SELECTION" \
  '{
    hostMacOSVersion: (if $hostMacOSVersion == "" then null else $hostMacOSVersion end),
    minimumHostMacOSForXcode26: $minimumXcode26HostMacOS,
    minimumRequiredXcodeMajor: $minimumRequiredXcodeMajor,
    minimumRequiredMacAppStoreXcodeMajor: $minimumRequiredMacAppStoreXcodeMajor,
    minimumRequiredIOSSDKMajor: $minimumRequiredIOSSDKMajor,
    xcode26HostCompatible: $xcode26HostCompatible,
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
    releaseIdentityLockConfigured: $releaseIdentityLockConfigured,
    releaseIdentityLockValid: $releaseIdentityLockValid,
    releaseIdentityAppliedFilesMatch: $releaseIdentityAppliedFilesMatch,
    releaseIdentityMatchesConfiguration: $releaseIdentityMatchesConfiguration,
    releaseIdentityAuxiliaryFilesMatch: $releaseIdentityAuxiliaryFilesMatch,
    releaseIdentityProfileRecordsPresent: $releaseIdentityProfileRecordsPresent,
    releaseIdentityProfileAssetsMatch: $releaseIdentityProfileAssetsMatch,
    releaseIdentityReady: $releaseIdentityLockReady,
    releaseIdentityLockPath: $releaseIdentityLockPath,
    releaseIdentityLockSHA256: (if $releaseIdentityLockSHA256 == "" then null else $releaseIdentityLockSHA256 end),
    releaseIdentityInputSchemaVersion: (if $releaseIdentityInputSchemaVersion == "" then null else ($releaseIdentityInputSchemaVersion | tonumber) end),
    releaseIdentityNormalizedSchemaVersion: (if $releaseIdentityNormalizedSchemaVersion == "" then null else ($releaseIdentityNormalizedSchemaVersion | tonumber) end),
    releaseIdentityRecordMode: (if $releaseIdentityRecordMode == "" then null else $releaseIdentityRecordMode end),
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
    iosTestFlightWarningsReviewed: $iosTestFlightWarningsReviewed,
    iosTestFlightWarningsReviewedAt: (if $iosTestFlightWarningsReviewedAt == "" then null else $iosTestFlightWarningsReviewedAt end),
    iosTestFlightEvidenceConfigured: $iosTestFlightEvidenceConfigured,
    iosLocalIPAPreflightPassed: $iosLocalIPAPreflightPassed,
    iosTestFlightVerificationEvidencePath: (if $iosTestFlightVerificationEvidencePath == "" then null else $iosTestFlightVerificationEvidencePath end),
    iosTestFlightExactBuildEvidenceReady: $iosTestFlightExactBuildEvidenceReady,
    iosTestFlightIPASHA256: (if $iosTestFlightIPASHA256 == "" then null else $iosTestFlightIPASHA256 end),
    iosTestFlightAppStoreConnectBuildID: (if $iosTestFlightAppStoreConnectBuildID == "" then null else $iosTestFlightAppStoreConnectBuildID end),
    iosTestFlightProcessingState: (if $iosTestFlightProcessingState == "" then null else $iosTestFlightProcessingState end),
    iosFunctionalQAEvidenceConfigured: $iosFunctionalQAEvidenceConfigured,
    iosFunctionalQAEvidenceReady: $iosFunctionalQAEvidenceReady,
    iosFunctionalQAEvidenceInputPath: (if $iosFunctionalQAEvidenceInputPath == "" then null else $iosFunctionalQAEvidenceInputPath end),
    iosFunctionalQAEvidencePath: (if $iosFunctionalQAEvidencePath == "" then null else $iosFunctionalQAEvidencePath end),
    iosFunctionalQAEvidenceSHA256: (if $iosFunctionalQAEvidenceSHA256 == "" then null else $iosFunctionalQAEvidenceSHA256 end),
    iosFunctionalQADeviceModel: (if $iosFunctionalQADeviceModel == "" then null else $iosFunctionalQADeviceModel end),
    iosFunctionalQAOSVersion: (if $iosFunctionalQAOSVersion == "" then null else $iosFunctionalQAOSVersion end),
    iosFunctionalQATestedAt: (if $iosFunctionalQATestedAt == "" then null else $iosFunctionalQATestedAt end),
    iosFunctionalEvidenceBoundToCandidate: $iosFunctionalEvidenceBoundToCandidate,
    iosProjectConfigured: $iosProject,
    iosProjectPath: $iosXcodeProject,
    iosScheme: $iosXcodeScheme,
    iosProjectReleaseValidationPassed: $iosProjectReleaseValidation,
    iosProjectReleaseValidationMessages: $iosProjectReleaseValidationMessages,
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
    macAppStoreLocalPreflightPassed: $macAppStoreLocalPreflightPassed,
    macAppStoreArchiveZipSHA256: (if $macAppStoreArchiveZipSHA256 == "" then null else $macAppStoreArchiveZipSHA256 end),
    macAppStorePackageSHA256: (if $macAppStorePackageSHA256 == "" then null else $macAppStorePackageSHA256 end),
    macAppStoreFunctionalQAEvidenceConfigured: $macAppStoreFunctionalQAEvidenceConfigured,
    macAppStoreFunctionalQAEvidenceReady: $macAppStoreFunctionalQAEvidenceReady,
    macAppStoreFunctionalQAEvidenceInputPath: (if $macAppStoreFunctionalQAEvidenceInputPath == "" then null else $macAppStoreFunctionalQAEvidenceInputPath end),
    macAppStoreFunctionalQAEvidencePath: (if $macAppStoreFunctionalQAEvidencePath == "" then null else $macAppStoreFunctionalQAEvidencePath end),
    macAppStoreFunctionalQAEvidenceSHA256: (if $macAppStoreFunctionalQAEvidenceSHA256 == "" then null else $macAppStoreFunctionalQAEvidenceSHA256 end),
    macAppStoreFunctionalQAMacModel: (if $macAppStoreFunctionalQAMacModel == "" then null else $macAppStoreFunctionalQAMacModel end),
    macAppStoreFunctionalQAOSVersion: (if $macAppStoreFunctionalQAOSVersion == "" then null else $macAppStoreFunctionalQAOSVersion end),
    macAppStoreFunctionalQATestedAt: (if $macAppStoreFunctionalQATestedAt == "" then null else $macAppStoreFunctionalQATestedAt end),
    macAppStoreFunctionalEvidenceArchiveSHA256: (if $macAppStoreFunctionalEvidenceArchiveSHA256 == "" then null else $macAppStoreFunctionalEvidenceArchiveSHA256 end),
    macAppStoreFunctionalEvidencePackageSHA256: (if $macAppStoreFunctionalEvidencePackageSHA256 == "" then null else $macAppStoreFunctionalEvidencePackageSHA256 end),
    macAppStoreFunctionalEvidenceBoundToCandidate: $macAppStoreFunctionalEvidenceBoundToCandidate,
    macAppStoreDeliveryEvidenceConfigured: $macAppStoreDeliveryEvidenceConfigured,
    macAppStoreDeliveryEvidenceReady: $macAppStoreDeliveryEvidenceReady,
    macAppStoreDeliveryEvidenceInputPath: (if $macAppStoreDeliveryEvidenceInputPath == "" then null else $macAppStoreDeliveryEvidenceInputPath end),
    macAppStoreDeliveryEvidencePath: (if $macAppStoreDeliveryEvidencePath == "" then null else $macAppStoreDeliveryEvidencePath end),
    macAppStoreDeliveryEvidenceSHA256: (if $macAppStoreDeliveryEvidenceSHA256 == "" then null else $macAppStoreDeliveryEvidenceSHA256 end),
    macAppStoreDeliveryBoundToCandidate: $macAppStoreDeliveryBoundToCandidate,
    macAppStoreUploadAccepted: $macAppStoreUploadAccepted,
    macAppStoreUploadSubmittedAt: (if $macAppStoreUploadSubmittedAt == "" then null else $macAppStoreUploadSubmittedAt end),
    macAppStoreProcessingEvidenceConfigured: $macAppStoreProcessingEvidenceConfigured,
    macAppStoreProcessingEvidenceReady: $macAppStoreProcessingEvidenceReady,
    macAppStoreProcessingEvidenceInputPath: (if $macAppStoreProcessingEvidenceInputPath == "" then null else $macAppStoreProcessingEvidenceInputPath end),
    macAppStoreProcessingEvidencePath: (if $macAppStoreProcessingEvidencePath == "" then null else $macAppStoreProcessingEvidencePath end),
    macAppStoreProcessingEvidenceSHA256: (if $macAppStoreProcessingEvidenceSHA256 == "" then null else $macAppStoreProcessingEvidenceSHA256 end),
    macAppStoreProcessingBoundToDelivery: $macAppStoreProcessingBoundToDelivery,
    macAppStoreProcessingState: (if $macAppStoreProcessingState == "" then null else $macAppStoreProcessingState end),
    macAppStoreProcessingVerified: $macAppStoreProcessingVerified,
    macAppStoreProcessingVerifiedAt: (if $macAppStoreProcessingVerifiedAt == "" then null else $macAppStoreProcessingVerifiedAt end),
    macAppStoreWarningsReviewed: $macAppStoreWarningsReviewed,
    macAppStoreWarningsReviewedAt: (if $macAppStoreWarningsReviewedAt == "" then null else $macAppStoreWarningsReviewedAt end),
    macAppStoreConnectBuildID: (if $macAppStoreConnectBuildID == "" then null else $macAppStoreConnectBuildID end),
    macAppStoreAppReviewSubmissionRecorded: $macAppStoreAppReviewSubmissionRecorded,
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
    storeSubmissionBlockerCount: ($storeSubmissionBlockers | length),
    storeSubmissionBlockers: $storeSubmissionBlockers,
    storeSubmissionStructuralErrors: $storeSubmissionStructuralErrors,
    macStoreSubmissionAssetsReady: $macStoreSubmissionAssetsReady,
    macStoreSubmissionBlockerCount: ($macStoreSubmissionBlockers | length),
    macStoreSubmissionBlockers: $macStoreSubmissionBlockers,
    macStoreSubmissionStructuralErrors: $macStoreSubmissionStructuralErrors,
    iosStoreSubmissionAssetsReady: $iosStoreSubmissionAssetsReady,
    iosStoreSubmissionBlockerCount: ($iosStoreSubmissionBlockers | length),
    iosStoreSubmissionBlockers: $iosStoreSubmissionBlockers,
    iosStoreSubmissionStructuralErrors: $iosStoreSubmissionStructuralErrors,
    appStoreSubmissionManifestConfigured: $appStoreSubmissionManifestConfigured,
    appStoreSubmissionManifestReady: $appStoreSubmissionManifestReady,
    macAppStoreSubmissionManifestReady: $macAppStoreSubmissionManifestReady,
    iosAppStoreSubmissionManifestReady: $iosAppStoreSubmissionManifestReady,
    appStoreSubmissionManifestPath: (if $appStoreSubmissionManifestPath == "" then null else $appStoreSubmissionManifestPath end),
    appStoreSubmissionManifestSHA256: (if $appStoreSubmissionManifestSHA256 == "" then null else $appStoreSubmissionManifestSHA256 end),
    appStoreSubmissionStructuralErrors: $appStoreSubmissionStructuralErrors,
    appStoreSubmissionReleaseBlockers: $appStoreSubmissionReleaseBlockers,
    macAppStoreSubmissionStructuralErrors: $macAppStoreSubmissionStructuralErrors,
    macAppStoreSubmissionReleaseBlockers: $macAppStoreSubmissionReleaseBlockers,
    iosAppStoreSubmissionStructuralErrors: $iosAppStoreSubmissionStructuralErrors,
    iosAppStoreSubmissionReleaseBlockers: $iosAppStoreSubmissionReleaseBlockers,
    macAppStoreExpectedAppResourceID: (if $macAppStoreExpectedAppResourceID == "" then null else $macAppStoreExpectedAppResourceID end),
    macAppStoreExpectedSKU: (if $macAppStoreExpectedSKU == "" then null else $macAppStoreExpectedSKU end),
    macAppStoreExpectedPrimaryLocale: (if $macAppStoreExpectedPrimaryLocale == "" then null else $macAppStoreExpectedPrimaryLocale end),
    iosAppStoreExpectedAppResourceID: (if $iosAppStoreExpectedAppResourceID == "" then null else $iosAppStoreExpectedAppResourceID end),
    iosAppStoreExpectedSKU: (if $iosAppStoreExpectedSKU == "" then null else $iosAppStoreExpectedSKU end),
    iosAppStoreExpectedPrimaryLocale: (if $iosAppStoreExpectedPrimaryLocale == "" then null else $iosAppStoreExpectedPrimaryLocale end),
    publicPagesEvidenceConfigured: $publicPagesEvidenceConfigured,
    publicPagesEvidenceReady: $publicPagesEvidenceReady,
    publicPagesEvidenceBoundToSubmissionManifest: $publicPagesEvidenceBoundToSubmissionManifest,
    publicPagesEvidencePath: (if $publicPagesEvidencePath == "" then null else $publicPagesEvidencePath end),
    publicPagesEvidenceSHA256: (if $publicPagesEvidenceSHA256 == "" then null else $publicPagesEvidenceSHA256 end),
    publicPagesEvidenceBindingType: (if $publicPagesEvidenceBindingType == "" then null else $publicPagesEvidenceBindingType end),
    publicPagesEvidenceBindingPath: (if $publicPagesEvidenceBindingPath == "" then null else $publicPagesEvidenceBindingPath end),
    publicPagesEvidenceBindingSHA256: (if $publicPagesEvidenceBindingSHA256 == "" then null else $publicPagesEvidenceBindingSHA256 end),
    publicPagesEvidenceOldestCheckedAt: (if $publicPagesEvidenceOldestCheckedAt == "" then null else $publicPagesEvidenceOldestCheckedAt end),
    publicPagesEvidenceNewestCheckedAt: (if $publicPagesEvidenceNewestCheckedAt == "" then null else $publicPagesEvidenceNewestCheckedAt end),
    publicPagesEvidenceMaxAgeSeconds: $publicPagesEvidenceMaxAgeSeconds,
    appStoreConnectSnapshotMaxAgeValid: $appStoreConnectSnapshotMaxAgeValid,
    appStoreConnectSnapshotMaxAgeSeconds: (if $appStoreConnectSnapshotMaxAgeValid then ($appStoreConnectSnapshotMaxAgeSeconds | tonumber) else null end),
    macAppStoreConnectBuildSnapshotConfigured: $macAppStoreConnectBuildSnapshotConfigured,
    macAppStoreConnectBuildSnapshotReady: $macAppStoreConnectBuildSnapshotReady,
    macAppStoreConnectBuildSnapshotPath: (if $macAppStoreConnectBuildSnapshotPath == "" then null else $macAppStoreConnectBuildSnapshotPath end),
    macAppStoreConnectBuildSnapshotSHA256: (if $macAppStoreConnectBuildSnapshotSHA256 == "" then null else $macAppStoreConnectBuildSnapshotSHA256 end),
    macAppStoreConnectEvidenceSHA256: (if $macAppStoreConnectEvidenceSHA256 == "" then null else $macAppStoreConnectEvidenceSHA256 end),
    macAppStoreConnectBuildSnapshotCapturedAt: (if $macAppStoreConnectBuildSnapshotCapturedAt == "" then null else $macAppStoreConnectBuildSnapshotCapturedAt end),
    macAppStoreConnectBuildSnapshotExpiresAt: (if $macAppStoreConnectBuildSnapshotExpiresAt == "" then null else $macAppStoreConnectBuildSnapshotExpiresAt end),
    macAppStoreConnectBuildSnapshotAppResourceID: (if $macAppStoreConnectBuildSnapshotAppResourceID == "" then null else $macAppStoreConnectBuildSnapshotAppResourceID end),
    macAppStoreConnectBuildSnapshotBuildResourceID: (if $macAppStoreConnectBuildSnapshotBuildResourceID == "" then null else $macAppStoreConnectBuildSnapshotBuildResourceID end),
    macAppStoreConnectBuildSnapshotWarningsPresent: (if $macAppStoreConnectBuildSnapshotWarningsPresent == "" then null else ($macAppStoreConnectBuildSnapshotWarningsPresent == "true") end),
    macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity: $macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity,
    macAppStoreConnectBuildSnapshotMatchesOperatorEvidence: $macAppStoreConnectBuildSnapshotMatchesOperatorEvidence,
    macAppStoreConnectBuildSnapshotWarningReviewCurrent: $macAppStoreConnectBuildSnapshotWarningReviewCurrent,
    macAppStoreConnectRemoteMetadataComparisonComplete: $macAppStoreConnectRemoteMetadataComparisonComplete,
    macAppStoreConnectBuildSnapshotExportComplianceRequired: (if $macAppStoreConnectBuildSnapshotExportComplianceRequired == "" then null else ($macAppStoreConnectBuildSnapshotExportComplianceRequired == "true") end),
    macAppStoreConnectBuildSnapshotBuildUploadErrorFree: (if $macAppStoreConnectBuildSnapshotBuildUploadErrorFree == "" then null else ($macAppStoreConnectBuildSnapshotBuildUploadErrorFree == "true") end),
    iosAppStoreConnectBuildSnapshotConfigured: $iosAppStoreConnectBuildSnapshotConfigured,
    iosAppStoreConnectBuildSnapshotReady: $iosAppStoreConnectBuildSnapshotReady,
    iosAppStoreConnectBuildSnapshotPath: (if $iosAppStoreConnectBuildSnapshotPath == "" then null else $iosAppStoreConnectBuildSnapshotPath end),
    iosAppStoreConnectBuildSnapshotSHA256: (if $iosAppStoreConnectBuildSnapshotSHA256 == "" then null else $iosAppStoreConnectBuildSnapshotSHA256 end),
    iosAppStoreConnectEvidenceSHA256: (if $iosAppStoreConnectEvidenceSHA256 == "" then null else $iosAppStoreConnectEvidenceSHA256 end),
    iosAppStoreConnectBuildSnapshotCapturedAt: (if $iosAppStoreConnectBuildSnapshotCapturedAt == "" then null else $iosAppStoreConnectBuildSnapshotCapturedAt end),
    iosAppStoreConnectBuildSnapshotExpiresAt: (if $iosAppStoreConnectBuildSnapshotExpiresAt == "" then null else $iosAppStoreConnectBuildSnapshotExpiresAt end),
    iosAppStoreConnectBuildSnapshotAppResourceID: (if $iosAppStoreConnectBuildSnapshotAppResourceID == "" then null else $iosAppStoreConnectBuildSnapshotAppResourceID end),
    iosAppStoreConnectBuildSnapshotBuildResourceID: (if $iosAppStoreConnectBuildSnapshotBuildResourceID == "" then null else $iosAppStoreConnectBuildSnapshotBuildResourceID end),
    iosAppStoreConnectBuildSnapshotWarningsPresent: (if $iosAppStoreConnectBuildSnapshotWarningsPresent == "" then null else ($iosAppStoreConnectBuildSnapshotWarningsPresent == "true") end),
    iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity: $iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity,
    iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence: $iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence,
    iosAppStoreConnectBuildSnapshotWarningReviewCurrent: $iosAppStoreConnectBuildSnapshotWarningReviewCurrent,
    iosAppStoreConnectRemoteMetadataComparisonComplete: $iosAppStoreConnectRemoteMetadataComparisonComplete,
    iosAppStoreConnectBuildSnapshotExportComplianceRequired: (if $iosAppStoreConnectBuildSnapshotExportComplianceRequired == "" then null else ($iosAppStoreConnectBuildSnapshotExportComplianceRequired == "true") end),
    iosAppStoreConnectBuildSnapshotBuildUploadErrorFree: (if $iosAppStoreConnectBuildSnapshotBuildUploadErrorFree == "" then null else ($iosAppStoreConnectBuildSnapshotBuildUploadErrorFree == "true") end),
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
    readyForMacAppStoreReviewSelection: $readyMacAppStoreReviewSelection,
    readyForFunctionalMacAppStoreSubmissionDeprecated: true,
    readyForFunctionalMacAppStoreSubmission: $readyFunctionalMacAppStoreSubmission,
    readyForIOSArchive: $readyIOSArchive,
    readyForFunctionalIOSTestFlight: $readyFunctionalIOSTestFlight,
    readyForIOSAppStoreReviewSelection: $readyIOSAppStoreReviewSelection
  }'
