#!/bin/zsh
set -euo pipefail

IOS_ROOT="${0:A:h:h}"
PRODUCT_ROOT="${IOS_ROOT:h:h}"
DIST_ROOT="$PRODUCT_ROOT/dist/ios"
PRIVACY_CONTRACT="$IOS_ROOT/scripts/privacy-manifest-contract.jq"
PREFLIGHT_ASSERTION="$PRODUCT_ROOT/scripts/assert-release-preflight.sh"
PROJECT_PATH="$IOS_ROOT/AgentIsland.xcodeproj"
SCHEME="AgentIslandMobile"
CONFIGURATION="Release"
EXPORT_IPA=false
ALLOW_PROVISIONING_UPDATES=false

usage() {
  /bin/cat <<'EOF'
Usage: ./scripts/release-ios.sh [--export] [--allow-provisioning-updates]

Creates a signed App Store archive under dist/ios. With --export, also exports
an IPA using Xcode's app-store-connect method. This script never uploads a
build. By default it only uses signing assets already installed on this Mac.
Pass --allow-provisioning-updates only when you deliberately permit Xcode to
contact Apple and create or update signing assets.
EOF
}

fail() {
  print -u2 -r -- "iOS release failed: $*"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --export)
      EXPORT_IPA=true
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v plutil >/dev/null 2>&1 || fail "plutil is required"
[[ -f "$PRIVACY_CONTRACT" ]] \
  || fail "privacy-manifest-contract.jq is required"
[[ -f "$PREFLIGHT_ASSERTION" && ! -L "$PREFLIGHT_ASSERTION" ]] \
  || fail "release preflight assertion is missing or unsafe"

DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] \
  || fail "select full Xcode 26 or newer with xcode-select before archiving"
[[ -d "$DEVELOPER_PATH/Platforms/iPhoneOS.platform" ]] \
  || fail "the selected Xcode does not include the iPhoneOS platform"

XCODE_VERSION="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild -version \
  | /usr/bin/awk '/^Xcode / {print $2; exit}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
[[ "$XCODE_MAJOR" == <-> ]] || fail "could not determine the Xcode version"
(( XCODE_MAJOR >= 26 )) || fail "Xcode 26 or newer is required for App Store uploads"

IPHONE_SDK="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun \
  --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
IPHONE_SDK_MAJOR="${IPHONE_SDK%%.*}"
[[ "$IPHONE_SDK_MAJOR" == <-> ]] || fail "could not determine the iPhoneOS SDK version"
(( IPHONE_SDK_MAJOR >= 26 )) || fail "the iOS 26 SDK or newer is required"

"$IOS_ROOT/scripts/validate-project.sh" --release

CONFIG_FILE="$IOS_ROOT/Config/Project.xcconfig"
setting_value() {
  local key="$1"
  /usr/bin/sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$CONFIG_FILE" \
    | /usr/bin/tail -n 1
}

TEAM_ID="$(setting_value AGENT_ISLAND_DEVELOPMENT_TEAM)"
VERSION="$(setting_value MARKETING_VERSION)"
BUILD_NUMBER="$(setting_value CURRENT_PROJECT_VERSION)"
APP_BUNDLE_ID="$(setting_value AGENT_ISLAND_APP_BUNDLE_ID)"
CLOUD_CONTAINER_ID="$(setting_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)"
DISPLAY_NAME="$(setting_value AGENT_ISLAND_DISPLAY_NAME)"
WIDGET_DISPLAY_NAME="$(setting_value AGENT_ISLAND_WIDGET_DISPLAY_NAME)"

production_https_url() {
  local value="$1"
  local normalized="${value:l}"
  local authority host normalized_host
  [[ "$value" == https://* && "$value" != *[[:space:]]* && \
    "$value" != *'#'* && "$value" != *'$('* ]] || return 1
  authority="${value#https://}"
  authority="${authority%%/*}"
  [[ -n "$authority" && "$authority" != *@* && "$authority" != *'?'* ]] || return 1
  host="${authority%%:*}"
  normalized_host="${host:l}"
  [[ "$host" == *.* && "$normalized_host" != localhost && \
    "$normalized_host" != 127.* && "$normalized_host" != *.local && \
    "$normalized_host" != *.invalid && "$normalized" != *example* && \
    "$normalized" != *placeholder* && "$normalized" != *yourdomain* && \
    "$normalized" != *yourname* ]]
}

validate_app_info() {
  local app_path="$1"
  local label="$2"
  local plist="$app_path/Info.plist"
  local actual_version actual_build actual_display_name privacy_url support_url container record_type record_name payload_field
  [[ -f "$plist" ]] || fail "$label is missing Info.plist"
  actual_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null)" \
    || fail "$label is missing CFBundleShortVersionString"
  actual_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$plist" 2>/dev/null)" \
    || fail "$label is missing CFBundleVersion"
  actual_display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$plist" 2>/dev/null)" \
    || fail "$label is missing CFBundleDisplayName"
  privacy_url="$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its privacy policy URL"
  support_url="$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its support URL"
  container="$(/usr/bin/plutil -extract AgentIslandCloudKitContainerIdentifier raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its CloudKit container"
  record_type="$(/usr/bin/plutil -extract AgentIslandCloudKitRecordType raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its CloudKit record type"
  record_name="$(/usr/bin/plutil -extract AgentIslandCloudKitRecordName raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its CloudKit record name"
  payload_field="$(/usr/bin/plutil -extract AgentIslandCloudKitPayloadField raw "$plist" 2>/dev/null)" \
    || fail "$label is missing its CloudKit payload field"
  [[ "$actual_version" == "$VERSION" && "$actual_build" == "$BUILD_NUMBER" ]] \
    || fail "$label version or build does not match Project.xcconfig"
  [[ "$actual_display_name" == "$DISPLAY_NAME" ]] \
    || fail "$label display name does not match AGENT_ISLAND_DISPLAY_NAME"
  production_https_url "$privacy_url" || fail "$label has an invalid production privacy policy URL"
  production_https_url "$support_url" || fail "$label has an invalid production support URL"
  [[ "$container" == "$CLOUD_CONTAINER_ID" ]] \
    || fail "$label CloudKit container does not match Project.xcconfig"
  [[ "$record_type" == "AgentIslandSnapshot" && "$record_name" == "latest" && \
    "$payload_field" == "payloadJSON" ]] \
    || fail "$label CloudKit record contract is not AgentIslandSnapshot/latest/payloadJSON"
  [[ "$(/usr/bin/plutil -extract NSSupportsLiveActivities raw "$plist" 2>/dev/null)" == true ]] \
    || fail "$label must declare Live Activity support"
  [[ "$(/usr/bin/plutil -extract NSSupportsLiveActivitiesFrequentUpdates raw "$plist" 2>/dev/null)" == false ]] \
    || fail "$label must not claim frequent Live Activity updates"
}

validate_widget_info() {
  local widget_path="$1"
  local label="$2"
  local plist="$widget_path/Info.plist"
  [[ -f "$plist" ]] || fail "$label is missing Info.plist"
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null)" == "$VERSION" ]] \
    || fail "$label version does not match Project.xcconfig"
  [[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$plist" 2>/dev/null)" == "$BUILD_NUMBER" ]] \
    || fail "$label build does not match Project.xcconfig"
  [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$plist" 2>/dev/null)" == \
      "$WIDGET_DISPLAY_NAME" ]] \
    || fail "$label display name does not match AGENT_ISLAND_WIDGET_DISPLAY_NAME"
  [[ "$(/usr/bin/plutil -extract NSExtension.NSExtensionPointIdentifier raw "$plist" 2>/dev/null)" == \
      "com.apple.widgetkit-extension" ]] \
    || fail "$label is not a WidgetKit extension"
}

validate_privacy_manifests() {
  local app_path="$1"
  local widget_path="$2"
  local stage="$3"
  local app_manifest="$app_path/PrivacyInfo.xcprivacy"
  local widget_manifest="$widget_path/PrivacyInfo.xcprivacy"
  local app_json="$WORK_DIR/$stage-app-privacy.json"
  local widget_json="$WORK_DIR/$stage-widget-privacy.json"

  [[ -f "$app_manifest" ]] || fail "$stage App is missing PrivacyInfo.xcprivacy"
  [[ -f "$widget_manifest" ]] || fail "$stage Widget is missing PrivacyInfo.xcprivacy"
  /usr/bin/plutil -convert json -o "$app_json" "$app_manifest" \
    || fail "$stage App privacy manifest is invalid"
  /usr/bin/plutil -convert json -o "$widget_json" "$widget_manifest" \
    || fail "$stage Widget privacy manifest is invalid"

  /usr/bin/jq -e --arg target app -f "$PRIVACY_CONTRACT" \
    "$app_json" >/dev/null \
    || fail "$stage App privacy manifest does not match the reviewed disclosure"

  /usr/bin/jq -e --arg target widget -f "$PRIVACY_CONTRACT" \
    "$widget_json" >/dev/null \
    || fail "$stage Widget privacy manifest must remain empty"
}

privacy_manifest_sha256() {
  local manifest="$1"
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}'
}

extract_profile_entitlements_json() {
  local profile_plist="$1"
  local json_output="$2"
  local entitlements_plist="${json_output%.json}.plist"

  # A decoded mobileprovision contains Date/Data values that make direct JSON
  # extraction fail on some plutil versions. Isolate the Entitlements
  # dictionary as XML first, then convert that JSON-safe child plist.
  /usr/bin/plutil -extract Entitlements xml1 -o "$entitlements_plist" "$profile_plist" \
    || fail "could not extract provisioning-profile entitlements"
  /usr/bin/plutil -convert json -o "$json_output" "$entitlements_plist" \
    || fail "could not convert provisioning-profile entitlements to JSON"
}

utf8_character_count() {
  printf '%s' "$1" | LC_ALL= LC_CTYPE=UTF-8 /usr/bin/wc -m | /usr/bin/tr -d '[:space:]'
}

extract_leaf_certificate_sha1() {
  local bundle_path="$1"
  local certificate_directory="$2"
  local label="$3"
  /bin/mkdir -p "$certificate_directory"
  (cd "$certificate_directory" && \
    /usr/bin/codesign --display --extract-certificates "$bundle_path" \
      >/dev/null 2>&1) \
    || fail "could not extract $label signing certificate"
  [[ -f "$certificate_directory/codesign0" ]] \
    || fail "$label code signature has no leaf certificate"
  LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$certificate_directory/codesign0" \
    | /usr/bin/awk '{print toupper($1)}'
}

profile_authorizes_certificate_sha1() {
  local profile="$1"
  local expected_sha1="$2"
  local label="$3"
  local certificate_count index certificate_path certificate_sha1
  certificate_count="$(profile_scalar "$profile" DeveloperCertificates "$label")"
  [[ "$certificate_count" == <-> && "$certificate_count" -gt 0 ]] \
    || fail "$label provisioning profile has no DeveloperCertificates"
  for (( index = 0; index < certificate_count; index++ )); do
    certificate_path="$WORK_DIR/${label//[^A-Za-z0-9]/-}-profile-certificate-$index.der"
    /usr/bin/plutil -extract "DeveloperCertificates.$index" raw -o - "$profile" \
      | /usr/bin/base64 -D >"$certificate_path" \
      || fail "could not decode $label provisioning-profile certificate $index"
    certificate_sha1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$certificate_path" \
      | /usr/bin/awk '{print toupper($1)}')"
    if [[ "$certificate_sha1" == "$expected_sha1" ]]; then
      return 0
    fi
  done
  fail "$label provisioning profile does not authorize the actual signing certificate"
}

[[ ${#TEAM_ID} -eq 10 && "$TEAM_ID" != *[^A-Z0-9]* ]] \
  || fail "Project.xcconfig must contain the production 10-character Team ID"
DISPLAY_NAME_CHARACTER_COUNT="$(utf8_character_count "$DISPLAY_NAME")"
WIDGET_DISPLAY_NAME_CHARACTER_COUNT="$(utf8_character_count "$WIDGET_DISPLAY_NAME")"
[[ -n "$DISPLAY_NAME" && "${DISPLAY_NAME:l}" != "agent island" && \
  "$DISPLAY_NAME_CHARACTER_COUNT" -le 30 && "$DISPLAY_NAME" != [[:space:]]* && \
  "$DISPLAY_NAME" != *[[:space:]] && \
  "$DISPLAY_NAME" != *'$('* && "$DISPLAY_NAME" != *'${'* && \
  "$DISPLAY_NAME" != *$'\n'* && "$DISPLAY_NAME" != *$'\r'* ]] \
  || fail "Project.xcconfig must contain a final, conflict-checked AGENT_ISLAND_DISPLAY_NAME"
[[ -n "$WIDGET_DISPLAY_NAME" && "$WIDGET_DISPLAY_NAME_CHARACTER_COUNT" -le 30 && \
  "$WIDGET_DISPLAY_NAME" != [[:space:]]* && "$WIDGET_DISPLAY_NAME" != *[[:space:]] ]] \
  || fail "Project.xcconfig must contain a short AGENT_ISLAND_WIDGET_DISPLAY_NAME"
print -r -- "$VERSION" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' \
  || fail "MARKETING_VERSION must contain two or three numeric components"
print -r -- "$BUILD_NUMBER" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
  || fail "CURRENT_PROJECT_VERSION must be a positive integer without leading zeroes"

IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
REQUESTED_IDENTITY="${AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY:-}"
if [[ -n "$REQUESTED_IDENTITY" ]]; then
  [[ "$REQUESTED_IDENTITY" == "Apple Distribution: "* ]] \
    || fail "AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY must name an Apple Distribution certificate"
  [[ "$REQUESTED_IDENTITY" == *" ($TEAM_ID)" ]] \
    || fail "AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY does not belong to the configured Team ID"
  REQUESTED_IDENTITY_COUNT="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$REQUESTED_IDENTITY\"" || true)"
  [[ "$REQUESTED_IDENTITY_COUNT" == "1" ]] \
    || fail "AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY must match exactly one keychain identity"
  SELECTED_IDENTITY="$REQUESTED_IDENTITY"
else
  MATCHING_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/awk -v team="$TEAM_ID" '
    match($0, /"Apple Distribution:[^"]+"/) {
      identity = substr($0, RSTART + 1, RLENGTH - 2)
      suffix = " (" team ")"
      if (length(identity) >= length(suffix)
          && substr(identity, length(identity) - length(suffix) + 1) == suffix) {
        print identity
      }
    }
  ')"
  MATCHING_IDENTITY_COUNT="$(print -r -- "$MATCHING_IDENTITIES" | /usr/bin/awk 'NF {count++} END {print count + 0}')"
  [[ "$MATCHING_IDENTITY_COUNT" == "1" ]] \
    || fail "expected exactly one Apple Distribution identity for Team $TEAM_ID; set AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY after removing duplicates"
  SELECTED_IDENTITY="$(print -r -- "$MATCHING_IDENTITIES" | /usr/bin/head -n 1)"
fi
SELECTED_IDENTITY_SHA1S="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/awk \
  -v identity="$SELECTED_IDENTITY" '
    index($0, "\"" identity "\"") {
      fingerprint = $2
      gsub(/[^0-9A-Fa-f]/, "", fingerprint)
      if (length(fingerprint) == 40) print toupper(fingerprint)
    }
  ')"
SELECTED_IDENTITY_SHA1_COUNT="$(print -r -- "$SELECTED_IDENTITY_SHA1S" \
  | /usr/bin/awk 'NF {count++} END {print count + 0}')"
[[ "$SELECTED_IDENTITY_SHA1_COUNT" == "1" ]] \
  || fail "selected Apple Distribution identity must resolve to one certificate SHA-1"
SELECTED_IDENTITY_SHA1="$(print -r -- "$SELECTED_IDENTITY_SHA1S" | /usr/bin/head -n 1)"
print -r -- "$SELECTED_IDENTITY_SHA1" | /usr/bin/grep -Eq '^[0-9A-F]{40}$' \
  || fail "selected Apple Distribution identity has an invalid certificate SHA-1"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentisland-ios-release.XXXXXX")"
READINESS_REPORT="$WORK_DIR/release-readiness.json"
STAGING_ROOT=""
PUBLISH_LOCK=""
PUBLISHED_RELEASE_DIR=""
FINAL_RELEASE_DIR=""
STAGING_INODE=""
COMMIT_DONE=false

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$STAGING_ROOT" && \
      "$STAGING_ROOT" == "$DIST_ROOT"/.agentisland-ios-release-staging.* && \
      -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
    /bin/rm -rf "$STAGING_ROOT"
  fi
  if [[ "$COMMIT_DONE" != true && -n "$PUBLISHED_RELEASE_DIR" && \
      "$PUBLISHED_RELEASE_DIR" == "$FINAL_RELEASE_DIR" && \
      -d "$PUBLISHED_RELEASE_DIR" && ! -L "$PUBLISHED_RELEASE_DIR" && \
      "$(/usr/bin/stat -f '%i' "$PUBLISHED_RELEASE_DIR" 2>/dev/null)" == \
        "$STAGING_INODE" ]]; then
    /bin/rm -rf "$PUBLISHED_RELEASE_DIR"
  fi
  if [[ -n "$PUBLISH_LOCK" && \
      "$PUBLISH_LOCK" == "$DIST_ROOT"/.agentisland-ios-release-*.publish-lock && \
      -d "$PUBLISH_LOCK" && ! -L "$PUBLISH_LOCK" ]]; then
    /bin/rmdir "$PUBLISH_LOCK" 2>/dev/null
  fi
  if [[ "$WORK_DIR" == "${TMPDIR:-/tmp}"/agentisland-ios-release.* ]]; then
    /bin/rm -rf "$WORK_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Reuse the repository's canonical readiness calculation, but consume only its
# archive-time iOS gate. Upload/processing/install/review evidence is neither
# expected nor accepted as a substitute for the locked identity and config.
if ! DEVELOPER_DIR="$DEVELOPER_PATH" \
    "$PRODUCT_ROOT/scripts/release-readiness.sh" --json >"$READINESS_REPORT"; then
  fail "could not generate the release-readiness report"
fi
/bin/zsh "$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"
RELEASE_IDENTITY_LOCK_SHA256="$(/usr/bin/jq -r \
  '.releaseIdentityLockSHA256' "$READINESS_REPORT")"

STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
RELEASE_BASENAME="$VERSION-$BUILD_NUMBER-$STAMP"
FINAL_RELEASE_DIR="$DIST_ROOT/$RELEASE_BASENAME"
FINAL_ARCHIVE_PATH="$FINAL_RELEASE_DIR/AgentIslandMobile.xcarchive"
FINAL_EXPORT_DIR="$FINAL_RELEASE_DIR/export"
FINAL_METADATA_PATH="$FINAL_RELEASE_DIR/release-metadata.json"

if [[ -L "$DIST_ROOT" || ( -e "$DIST_ROOT" && ! -d "$DIST_ROOT" ) ]]; then
  fail "$DIST_ROOT must be a regular directory, not a symlink or file"
fi
/bin/mkdir -p "$DIST_ROOT"
PUBLISH_LOCK="$DIST_ROOT/.agentisland-ios-release-$RELEASE_BASENAME.publish-lock"
if ! /bin/mkdir "$PUBLISH_LOCK" 2>/dev/null; then
  fail "another release is publishing $RELEASE_BASENAME, or its stale publish lock must be inspected"
fi
[[ ! -e "$FINAL_RELEASE_DIR" && ! -L "$FINAL_RELEASE_DIR" ]] \
  || fail "refusing to overwrite existing iOS release directory: $FINAL_RELEASE_DIR"
STAGING_ROOT="$(mktemp -d "$DIST_ROOT/.agentisland-ios-release-staging.XXXXXX")" \
  || fail "could not create same-filesystem iOS release staging directory"
STAGING_INODE="$(/usr/bin/stat -f '%i' "$STAGING_ROOT")"
[[ "$STAGING_INODE" == <-> ]] || fail "could not identify the iOS release staging directory"

RELEASE_DIR="$STAGING_ROOT"
ARCHIVE_PATH="$RELEASE_DIR/AgentIslandMobile.xcarchive"
RESULT_BUNDLE="$RELEASE_DIR/AgentIslandMobile-archive.xcresult"
EXPORT_DIR="$RELEASE_DIR/export"
METADATA_PATH="$RELEASE_DIR/release-metadata.json"

typeset -a ARCHIVE_ARGS
ARCHIVE_ARGS=(
  archive
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination 'generic/platform=iOS'
  -archivePath "$ARCHIVE_PATH"
  -resultBundlePath "$RESULT_BUNDLE"
  -derivedDataPath "$WORK_DIR/DerivedData"
)
[[ "$ALLOW_PROVISIONING_UPDATES" == true ]] \
  && ARCHIVE_ARGS+=(-allowProvisioningUpdates)
# Revalidate the lock at the archive action boundary, rather than relying only
# on the readiness snapshot generated before staging was prepared.
/bin/zsh "$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${ARCHIVE_ARGS[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SELECTED_IDENTITY"

[[ -d "$ARCHIVE_PATH" ]] || fail "Xcode did not create the expected archive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/AgentIslandMobile.app"
WIDGET_PATH="$APP_PATH/PlugIns/AgentIslandLiveActivityExtension.appex"
[[ -d "$APP_PATH" && -d "$WIDGET_PATH" ]] \
  || fail "archive is missing the app or embedded Live Activity extension"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$WIDGET_PATH"

ACTUAL_APP_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw \
  "$APP_PATH/Info.plist")"
ACTUAL_WIDGET_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw \
  "$WIDGET_PATH/Info.plist")"
[[ "$ACTUAL_APP_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] \
  || fail "archived App bundle identifier does not match Project.xcconfig"
[[ "$ACTUAL_WIDGET_BUNDLE_ID" == "$APP_BUNDLE_ID.liveactivity" ]] \
  || fail "archived Widget bundle identifier is not the configured child identifier"
validate_app_info "$APP_PATH" "archived App"
validate_widget_info "$WIDGET_PATH" "archived Widget"
validate_privacy_manifests "$APP_PATH" "$WIDGET_PATH" "archived"
ARCHIVED_APP_PRIVACY_SHA256="$(privacy_manifest_sha256 "$APP_PATH/PrivacyInfo.xcprivacy")"
ARCHIVED_WIDGET_PRIVACY_SHA256="$(privacy_manifest_sha256 "$WIDGET_PATH/PrivacyInfo.xcprivacy")"
ARCHIVED_DISPLAY_NAME="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$APP_PATH/Info.plist")"
ARCHIVED_WIDGET_DISPLAY_NAME="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$WIDGET_PATH/Info.plist")"
ARCHIVED_PRIVACY_POLICY_URL="$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$APP_PATH/Info.plist")"
ARCHIVED_SUPPORT_URL="$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$APP_PATH/Info.plist")"

APP_SIGNATURE_INFO="$WORK_DIR/app-signature.txt"
WIDGET_SIGNATURE_INFO="$WORK_DIR/widget-signature.txt"
/usr/bin/codesign -d --verbose=4 "$APP_PATH" > /dev/null 2>"$APP_SIGNATURE_INFO"
/usr/bin/codesign -d --verbose=4 "$WIDGET_PATH" > /dev/null 2>"$WIDGET_SIGNATURE_INFO"
APP_SIGNING_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' "$APP_SIGNATURE_INFO" \
  | /usr/bin/head -n 1)"
WIDGET_SIGNING_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' "$WIDGET_SIGNATURE_INFO" \
  | /usr/bin/head -n 1)"
APP_SIGNED_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$APP_SIGNATURE_INFO" \
  | /usr/bin/head -n 1)"
WIDGET_SIGNED_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$WIDGET_SIGNATURE_INFO" \
  | /usr/bin/head -n 1)"
[[ "$APP_SIGNING_AUTHORITY" == "Apple Distribution: "* \
    && "$APP_SIGNING_AUTHORITY" == *" ($TEAM_ID)" ]] \
  || fail "archived App is not signed by Apple Distribution for Team $TEAM_ID"
[[ "$WIDGET_SIGNING_AUTHORITY" == "$APP_SIGNING_AUTHORITY" ]] \
  || fail "App and Widget Extension are not signed with the same Apple Distribution identity"
[[ "$APP_SIGNING_AUTHORITY" == "$SELECTED_IDENTITY" ]] \
  || fail "archive was not signed with the selected Apple Distribution identity"
[[ "$APP_SIGNED_TEAM" == "$TEAM_ID" && "$WIDGET_SIGNED_TEAM" == "$TEAM_ID" ]] \
  || fail "App or Widget code signature TeamIdentifier does not match Project.xcconfig"
ARCHIVED_APP_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
  "$APP_PATH" "$WORK_DIR/archived-app-certificates" "archived App")"
ARCHIVED_WIDGET_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
  "$WIDGET_PATH" "$WORK_DIR/archived-widget-certificates" "archived Widget")"
[[ "$ARCHIVED_APP_CERTIFICATE_SHA1" == "$SELECTED_IDENTITY_SHA1" \
    && "$ARCHIVED_WIDGET_CERTIFICATE_SHA1" == "$SELECTED_IDENTITY_SHA1" ]] \
  || fail "App or Widget was not signed by the selected Apple Distribution certificate"

APP_ENTITLEMENTS="$WORK_DIR/app-entitlements.plist"
WIDGET_ENTITLEMENTS="$WORK_DIR/widget-entitlements.plist"
APP_ENTITLEMENTS_JSON="$WORK_DIR/app-entitlements.json"
WIDGET_ENTITLEMENTS_JSON="$WORK_DIR/widget-entitlements.json"
/usr/bin/codesign -d --entitlements - "$APP_PATH" >"$APP_ENTITLEMENTS" 2>/dev/null
/usr/bin/codesign -d --entitlements - "$WIDGET_PATH" >"$WIDGET_ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -convert json -o "$APP_ENTITLEMENTS_JSON" "$APP_ENTITLEMENTS"
/usr/bin/plutil -convert json -o "$WIDGET_ENTITLEMENTS_JSON" "$WIDGET_ENTITLEMENTS"

APP_PROFILE="$APP_PATH/embedded.mobileprovision"
WIDGET_PROFILE="$WIDGET_PATH/embedded.mobileprovision"
[[ -f "$APP_PROFILE" && -f "$WIDGET_PROFILE" ]] \
  || fail "archive is missing an embedded provisioning profile"
APP_PROFILE_PLIST="$WORK_DIR/app-profile.plist"
WIDGET_PROFILE_PLIST="$WORK_DIR/widget-profile.plist"
APP_PROFILE_ENTITLEMENTS_JSON="$WORK_DIR/app-profile-entitlements.json"
WIDGET_PROFILE_ENTITLEMENTS_JSON="$WORK_DIR/widget-profile-entitlements.json"
/usr/bin/security cms -D -i "$APP_PROFILE" >"$APP_PROFILE_PLIST"
/usr/bin/security cms -D -i "$WIDGET_PROFILE" >"$WIDGET_PROFILE_PLIST"
extract_profile_entitlements_json "$APP_PROFILE_PLIST" "$APP_PROFILE_ENTITLEMENTS_JSON"
extract_profile_entitlements_json "$WIDGET_PROFILE_PLIST" "$WIDGET_PROFILE_ENTITLEMENTS_JSON"

profile_scalar() {
  local profile="$1"
  local key_path="$2"
  local label="$3"
  local value
  value="$(/usr/bin/plutil -extract "$key_path" raw "$profile" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "$label provisioning profile is missing $key_path"
  print -r -- "$value"
}

validate_app_store_profile_shape() {
  local profile="$1"
  local label="$2"
  local expiration="$3"
  local expiration_epoch
  if /usr/bin/plutil -type ProvisionedDevices "$profile" >/dev/null 2>&1; then
    fail "$label provisioning profile is device-scoped, not an App Store profile"
  fi
  if [[ "$(/usr/bin/plutil -extract ProvisionsAllDevices raw "$profile" \
      2>/dev/null || true)" == "true" ]]; then
    fail "$label provisioning profile is an all-device profile, not an App Store profile"
  fi
  expiration_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$expiration" '+%s' 2>/dev/null || true)"
  [[ "$expiration_epoch" == <-> ]] \
    || fail "$label provisioning profile has an unreadable ExpirationDate"
  (( expiration_epoch > $(/bin/date -u '+%s') )) \
    || fail "$label provisioning profile expired at $expiration"
}

profile_authorizes_certificate_sha1 \
  "$APP_PROFILE_PLIST" "$ARCHIVED_APP_CERTIFICATE_SHA1" "archived App"
profile_authorizes_certificate_sha1 \
  "$WIDGET_PROFILE_PLIST" "$ARCHIVED_WIDGET_CERTIFICATE_SHA1" "archived Widget"

APP_PREFIX_COUNT="$(profile_scalar "$APP_PROFILE_PLIST" \
  ApplicationIdentifierPrefix "App")"
WIDGET_PREFIX_COUNT="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ApplicationIdentifierPrefix "Widget")"
APP_PROFILE_TEAM_COUNT="$(profile_scalar "$APP_PROFILE_PLIST" TeamIdentifier "App")"
WIDGET_PROFILE_TEAM_COUNT="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  TeamIdentifier "Widget")"
[[ "$APP_PREFIX_COUNT" == "1" && "$WIDGET_PREFIX_COUNT" == "1" ]] \
  || fail "App and Widget profiles must each contain exactly one App ID prefix"
[[ "$APP_PROFILE_TEAM_COUNT" == "1" && "$WIDGET_PROFILE_TEAM_COUNT" == "1" ]] \
  || fail "App and Widget profiles must each contain exactly one TeamIdentifier"

APP_ID_PREFIX="$(profile_scalar "$APP_PROFILE_PLIST" \
  ApplicationIdentifierPrefix.0 "App")"
WIDGET_ID_PREFIX="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ApplicationIdentifierPrefix.0 "Widget")"
APP_PROFILE_TEAM="$(profile_scalar "$APP_PROFILE_PLIST" TeamIdentifier.0 "App")"
WIDGET_PROFILE_TEAM="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  TeamIdentifier.0 "Widget")"
APP_PROFILE_EXPIRATION="$(profile_scalar "$APP_PROFILE_PLIST" ExpirationDate "App")"
WIDGET_PROFILE_EXPIRATION="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ExpirationDate "Widget")"
[[ "$APP_PROFILE_TEAM" == "$TEAM_ID" && "$WIDGET_PROFILE_TEAM" == "$TEAM_ID" ]] \
  || fail "App or Widget provisioning profile belongs to a different Team ID"
validate_app_store_profile_shape "$APP_PROFILE_PLIST" "App" \
  "$APP_PROFILE_EXPIRATION"
validate_app_store_profile_shape "$WIDGET_PROFILE_PLIST" "Widget" \
  "$WIDGET_PROFILE_EXPIRATION"

EXPECTED_APP_IDENTIFIER="$APP_ID_PREFIX.$APP_BUNDLE_ID"
EXPECTED_WIDGET_IDENTIFIER="$WIDGET_ID_PREFIX.$APP_BUNDLE_ID.liveactivity"
/usr/bin/jq -e -s \
  --arg applicationIdentifier "$EXPECTED_APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER_ID" '
    .[0] as $signed
    | .[1] as $profile
    | $signed."application-identifier" == $applicationIdentifier
      and $profile."application-identifier" == $applicationIdentifier
      and $signed."application-identifier" == $profile."application-identifier"
      and $signed."com.apple.developer.team-identifier" == $team
      and $profile."com.apple.developer.team-identifier" == $team
      and (($signed."get-task-allow" // false) == false)
      and (($profile."get-task-allow" // false) == false)
      and $signed."com.apple.developer.icloud-container-identifiers" == [$container]
      and $profile."com.apple.developer.icloud-container-identifiers" == [$container]
      and $signed."com.apple.developer.icloud-services" == ["CloudKit"]
      and $profile."com.apple.developer.icloud-services" == ["CloudKit"]
      and $signed."com.apple.developer.icloud-container-environment" == "Production"
      and $profile."com.apple.developer.icloud-container-environment" == "Production"
  ' "$APP_ENTITLEMENTS_JSON" "$APP_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
  || fail "App signature/profile identifiers, team, or production CloudKit entitlements do not match exactly"

/usr/bin/jq -e -s \
  --arg applicationIdentifier "$EXPECTED_WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '
    def no_icloud:
      [keys[] | select(
        startswith("com.apple.developer.icloud")
        or startswith("com.apple.developer.ubiquity")
      )] | length == 0;
    .[0] as $signed
    | .[1] as $profile
    | $signed."application-identifier" == $applicationIdentifier
      and $profile."application-identifier" == $applicationIdentifier
      and $signed."application-identifier" == $profile."application-identifier"
      and $signed."com.apple.developer.team-identifier" == $team
      and $profile."com.apple.developer.team-identifier" == $team
      and (($signed."get-task-allow" // false) == false)
      and (($profile."get-task-allow" // false) == false)
      and ($signed | no_icloud)
      and ($profile | no_icloud)
  ' "$WIDGET_ENTITLEMENTS_JSON" "$WIDGET_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
  || fail "Widget signature/profile identifiers or team do not match exactly, or iCloud entitlements leaked into the extension"

EXPORTED_IPA=""
IPA_SHA256=""
EXPORTED_APP_EXPIRATION=""
EXPORTED_WIDGET_EXPIRATION=""
if [[ "$EXPORT_IPA" == true ]]; then
  EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
  /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert destination -string export "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert uploadSymbols -bool true "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool false "$EXPORT_OPTIONS"

  /bin/mkdir -p "$EXPORT_DIR"
  typeset -a EXPORT_ARGS
  EXPORT_ARGS=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS"
  )
  [[ "$ALLOW_PROVISIONING_UPDATES" == true ]] \
    && EXPORT_ARGS+=(-allowProvisioningUpdates)
  /bin/zsh "$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"
  DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${EXPORT_ARGS[@]}"

  ipa_files=("$EXPORT_DIR"/*.ipa(N))
  (( ${#ipa_files} == 1 )) || fail "expected exactly one exported IPA"
  EXPORTED_IPA="${ipa_files[1]}"

  EXPORTED_PAYLOAD_ROOT="$WORK_DIR/exported-ipa"
  /bin/mkdir -p "$EXPORTED_PAYLOAD_ROOT"
  /usr/bin/ditto -x -k "$EXPORTED_IPA" "$EXPORTED_PAYLOAD_ROOT"
  exported_apps=("$EXPORTED_PAYLOAD_ROOT/Payload"/*.app(N))
  (( ${#exported_apps} == 1 )) || fail "exported IPA must contain exactly one App"
  EXPORTED_APP_PATH="${exported_apps[1]}"
  EXPORTED_WIDGET_PATH="$EXPORTED_APP_PATH/PlugIns/AgentIslandLiveActivityExtension.appex"
  [[ -d "$EXPORTED_WIDGET_PATH" ]] \
    || fail "exported IPA is missing the Live Activity extension"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$EXPORTED_WIDGET_PATH"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw \
      "$EXPORTED_APP_PATH/Info.plist")" == "$APP_BUNDLE_ID" ]] \
    || fail "exported App bundle identifier changed after archive export"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw \
      "$EXPORTED_WIDGET_PATH/Info.plist")" == "$APP_BUNDLE_ID.liveactivity" ]] \
    || fail "exported Widget bundle identifier changed after archive export"
  validate_app_info "$EXPORTED_APP_PATH" "exported App"
  validate_widget_info "$EXPORTED_WIDGET_PATH" "exported Widget"
  validate_privacy_manifests "$EXPORTED_APP_PATH" "$EXPORTED_WIDGET_PATH" "exported"
  [[ "$(privacy_manifest_sha256 "$EXPORTED_APP_PATH/PrivacyInfo.xcprivacy")" == \
      "$ARCHIVED_APP_PRIVACY_SHA256" ]] \
    || fail "exported App privacy manifest changed after archive export"
  [[ "$(privacy_manifest_sha256 "$EXPORTED_WIDGET_PATH/PrivacyInfo.xcprivacy")" == \
      "$ARCHIVED_WIDGET_PRIVACY_SHA256" ]] \
    || fail "exported Widget privacy manifest changed after archive export"
  [[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$EXPORTED_APP_PATH/Info.plist")" == "$ARCHIVED_PRIVACY_POLICY_URL" ]] \
    || fail "exported App privacy policy URL changed after archive export"
  [[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$EXPORTED_APP_PATH/Info.plist")" == "$ARCHIVED_SUPPORT_URL" ]] \
    || fail "exported App support URL changed after archive export"

  EXPORTED_APP_SIGNATURE_INFO="$WORK_DIR/exported-app-signature.txt"
  EXPORTED_WIDGET_SIGNATURE_INFO="$WORK_DIR/exported-widget-signature.txt"
  /usr/bin/codesign -d --verbose=4 "$EXPORTED_APP_PATH" > /dev/null \
    2>"$EXPORTED_APP_SIGNATURE_INFO"
  /usr/bin/codesign -d --verbose=4 "$EXPORTED_WIDGET_PATH" > /dev/null \
    2>"$EXPORTED_WIDGET_SIGNATURE_INFO"
  EXPORTED_APP_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' \
    "$EXPORTED_APP_SIGNATURE_INFO" | /usr/bin/head -n 1)"
  EXPORTED_WIDGET_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' \
    "$EXPORTED_WIDGET_SIGNATURE_INFO" | /usr/bin/head -n 1)"
  EXPORTED_APP_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' \
    "$EXPORTED_APP_SIGNATURE_INFO" | /usr/bin/head -n 1)"
  EXPORTED_WIDGET_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' \
    "$EXPORTED_WIDGET_SIGNATURE_INFO" | /usr/bin/head -n 1)"
  [[ "$EXPORTED_APP_AUTHORITY" == "$APP_SIGNING_AUTHORITY" \
      && "$EXPORTED_WIDGET_AUTHORITY" == "$APP_SIGNING_AUTHORITY" ]] \
    || fail "exported IPA is not signed with the verified Apple Distribution identity"
  [[ "$EXPORTED_APP_TEAM" == "$TEAM_ID" && "$EXPORTED_WIDGET_TEAM" == "$TEAM_ID" ]] \
    || fail "exported App or Widget signature has the wrong TeamIdentifier"
  EXPORTED_APP_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
    "$EXPORTED_APP_PATH" "$WORK_DIR/exported-app-certificates" "exported App")"
  EXPORTED_WIDGET_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
    "$EXPORTED_WIDGET_PATH" "$WORK_DIR/exported-widget-certificates" "exported Widget")"
  [[ "$EXPORTED_APP_CERTIFICATE_SHA1" == "$SELECTED_IDENTITY_SHA1" \
      && "$EXPORTED_WIDGET_CERTIFICATE_SHA1" == "$SELECTED_IDENTITY_SHA1" ]] \
    || fail "exported App or Widget was not signed by the selected Apple Distribution certificate"

  EXPORTED_APP_ENTITLEMENTS_JSON="$WORK_DIR/exported-app-entitlements.json"
  EXPORTED_WIDGET_ENTITLEMENTS_JSON="$WORK_DIR/exported-widget-entitlements.json"
  /usr/bin/codesign -d --entitlements - "$EXPORTED_APP_PATH" 2>/dev/null \
    | /usr/bin/plutil -convert json -o "$EXPORTED_APP_ENTITLEMENTS_JSON" -
  /usr/bin/codesign -d --entitlements - "$EXPORTED_WIDGET_PATH" 2>/dev/null \
    | /usr/bin/plutil -convert json -o "$EXPORTED_WIDGET_ENTITLEMENTS_JSON" -

  EXPORTED_APP_PROFILE_PLIST="$WORK_DIR/exported-app-profile.plist"
  EXPORTED_WIDGET_PROFILE_PLIST="$WORK_DIR/exported-widget-profile.plist"
  EXPORTED_APP_PROFILE_ENTITLEMENTS_JSON="$WORK_DIR/exported-app-profile-entitlements.json"
  EXPORTED_WIDGET_PROFILE_ENTITLEMENTS_JSON="$WORK_DIR/exported-widget-profile-entitlements.json"
  /usr/bin/security cms -D -i "$EXPORTED_APP_PATH/embedded.mobileprovision" \
    >"$EXPORTED_APP_PROFILE_PLIST"
  /usr/bin/security cms -D -i "$EXPORTED_WIDGET_PATH/embedded.mobileprovision" \
    >"$EXPORTED_WIDGET_PROFILE_PLIST"
  extract_profile_entitlements_json \
    "$EXPORTED_APP_PROFILE_PLIST" "$EXPORTED_APP_PROFILE_ENTITLEMENTS_JSON"
  extract_profile_entitlements_json \
    "$EXPORTED_WIDGET_PROFILE_PLIST" "$EXPORTED_WIDGET_PROFILE_ENTITLEMENTS_JSON"
  profile_authorizes_certificate_sha1 \
    "$EXPORTED_APP_PROFILE_PLIST" "$EXPORTED_APP_CERTIFICATE_SHA1" "exported App"
  profile_authorizes_certificate_sha1 \
    "$EXPORTED_WIDGET_PROFILE_PLIST" "$EXPORTED_WIDGET_CERTIFICATE_SHA1" "exported Widget"

  EXPORTED_APP_PREFIX_COUNT="$(profile_scalar "$EXPORTED_APP_PROFILE_PLIST" \
    ApplicationIdentifierPrefix "exported App")"
  EXPORTED_WIDGET_PREFIX_COUNT="$(profile_scalar "$EXPORTED_WIDGET_PROFILE_PLIST" \
    ApplicationIdentifierPrefix "exported Widget")"
  EXPORTED_APP_TEAM_COUNT="$(profile_scalar "$EXPORTED_APP_PROFILE_PLIST" \
    TeamIdentifier "exported App")"
  EXPORTED_WIDGET_TEAM_COUNT="$(profile_scalar "$EXPORTED_WIDGET_PROFILE_PLIST" \
    TeamIdentifier "exported Widget")"
  [[ "$EXPORTED_APP_PREFIX_COUNT" == "1" && "$EXPORTED_WIDGET_PREFIX_COUNT" == "1" \
      && "$EXPORTED_APP_TEAM_COUNT" == "1" && "$EXPORTED_WIDGET_TEAM_COUNT" == "1" ]] \
    || fail "exported App and Widget profiles must have one App ID prefix and TeamIdentifier"
  [[ "$(profile_scalar "$EXPORTED_APP_PROFILE_PLIST" \
      ApplicationIdentifierPrefix.0 "exported App")" == "$APP_ID_PREFIX" ]] \
    || fail "exported App profile changed the verified App ID prefix"
  [[ "$(profile_scalar "$EXPORTED_WIDGET_PROFILE_PLIST" \
      ApplicationIdentifierPrefix.0 "exported Widget")" == "$WIDGET_ID_PREFIX" ]] \
    || fail "exported Widget profile changed the verified App ID prefix"
  [[ "$(profile_scalar "$EXPORTED_APP_PROFILE_PLIST" TeamIdentifier.0 \
      "exported App")" == "$TEAM_ID" \
      && "$(profile_scalar "$EXPORTED_WIDGET_PROFILE_PLIST" TeamIdentifier.0 \
      "exported Widget")" == "$TEAM_ID" ]] \
    || fail "exported provisioning profile TeamIdentifier does not match"
  EXPORTED_APP_EXPIRATION="$(profile_scalar "$EXPORTED_APP_PROFILE_PLIST" \
    ExpirationDate "exported App")"
  EXPORTED_WIDGET_EXPIRATION="$(profile_scalar "$EXPORTED_WIDGET_PROFILE_PLIST" \
    ExpirationDate "exported Widget")"
  validate_app_store_profile_shape "$EXPORTED_APP_PROFILE_PLIST" "exported App" \
    "$EXPORTED_APP_EXPIRATION"
  validate_app_store_profile_shape "$EXPORTED_WIDGET_PROFILE_PLIST" "exported Widget" \
    "$EXPORTED_WIDGET_EXPIRATION"

  /usr/bin/jq -e -s \
    --arg applicationIdentifier "$EXPECTED_APP_IDENTIFIER" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER_ID" '
      .[0] as $signed
      | .[1] as $profile
      | $signed."application-identifier" == $applicationIdentifier
        and $profile."application-identifier" == $applicationIdentifier
        and $signed."application-identifier" == $profile."application-identifier"
        and $signed."com.apple.developer.team-identifier" == $team
        and $profile."com.apple.developer.team-identifier" == $team
        and (($signed."get-task-allow" // false) == false)
        and (($profile."get-task-allow" // false) == false)
        and $signed."com.apple.developer.icloud-container-identifiers" == [$container]
        and $profile."com.apple.developer.icloud-container-identifiers" == [$container]
        and $signed."com.apple.developer.icloud-services" == ["CloudKit"]
        and $profile."com.apple.developer.icloud-services" == ["CloudKit"]
        and $signed."com.apple.developer.icloud-container-environment" == "Production"
        and $profile."com.apple.developer.icloud-container-environment" == "Production"
    ' "$EXPORTED_APP_ENTITLEMENTS_JSON" \
      "$EXPORTED_APP_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
    || fail "exported App signature/profile failed exact production entitlement validation"
  /usr/bin/jq -e -s \
    --arg applicationIdentifier "$EXPECTED_WIDGET_IDENTIFIER" \
    --arg team "$TEAM_ID" '
      def no_icloud:
        [keys[] | select(
          startswith("com.apple.developer.icloud")
          or startswith("com.apple.developer.ubiquity")
        )] | length == 0;
      .[0] as $signed
      | .[1] as $profile
      | $signed."application-identifier" == $applicationIdentifier
        and $profile."application-identifier" == $applicationIdentifier
        and $signed."application-identifier" == $profile."application-identifier"
        and $signed."com.apple.developer.team-identifier" == $team
        and $profile."com.apple.developer.team-identifier" == $team
        and (($signed."get-task-allow" // false) == false)
        and (($profile."get-task-allow" // false) == false)
        and ($signed | no_icloud)
        and ($profile | no_icloud)
    ' "$EXPORTED_WIDGET_ENTITLEMENTS_JSON" \
      "$EXPORTED_WIDGET_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
    || fail "exported Widget signature/profile failed exact no-iCloud validation"

  IPA_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$EXPORTED_IPA" | /usr/bin/awk '{print $1}')"
  print -r -- "$IPA_SHA256  ${EXPORTED_IPA:t}" >"$EXPORTED_IPA.sha256"
fi

PUBLISHED_IPA=""
if [[ -n "$EXPORTED_IPA" ]]; then
  PUBLISHED_IPA="$FINAL_EXPORT_DIR/${EXPORTED_IPA:t}"
fi

CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n \
  --arg product "MAC版灵动岛--Agent运行监测 iPhone companion" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archivePath "$FINAL_ARCHIVE_PATH" \
  --arg exportedIPA "$PUBLISHED_IPA" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg xcodeVersion "$XCODE_VERSION" \
  --arg iphoneSDK "$IPHONE_SDK" \
  --arg teamID "$TEAM_ID" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg widgetBundleID "$APP_BUNDLE_ID.liveactivity" \
  --arg displayName "$ARCHIVED_DISPLAY_NAME" \
  --arg widgetDisplayName "$ARCHIVED_WIDGET_DISPLAY_NAME" \
  --arg appIdentifier "$EXPECTED_APP_IDENTIFIER" \
  --arg widgetIdentifier "$EXPECTED_WIDGET_IDENTIFIER" \
  --arg cloudContainerID "$CLOUD_CONTAINER_ID" \
  --arg privacyPolicyURL "$ARCHIVED_PRIVACY_POLICY_URL" \
  --arg supportURL "$ARCHIVED_SUPPORT_URL" \
  --arg appPrivacyManifestSHA256 "$ARCHIVED_APP_PRIVACY_SHA256" \
  --arg widgetPrivacyManifestSHA256 "$ARCHIVED_WIDGET_PRIVACY_SHA256" \
  --arg signingIdentity "$APP_SIGNING_AUTHORITY" \
  --arg signingCertificateSHA1 "$SELECTED_IDENTITY_SHA1" \
  --arg releaseIdentityLockSHA256 "$RELEASE_IDENTITY_LOCK_SHA256" \
  --arg appProfileExpiration "$APP_PROFILE_EXPIRATION" \
  --arg widgetProfileExpiration "$WIDGET_PROFILE_EXPIRATION" \
  --arg exportedAppProfileExpiration "$EXPORTED_APP_EXPIRATION" \
  --arg exportedWidgetProfileExpiration "$EXPORTED_WIDGET_EXPIRATION" \
  --argjson allowProvisioningUpdates "$ALLOW_PROVISIONING_UPDATES" \
  --arg createdAt "$CREATED_AT" \
  '{
    schemaVersion: 1,
    product: $product,
    version: $version,
    build: $build,
    archivePath: $archivePath,
    exportedIPA: (if $exportedIPA == "" then null else $exportedIPA end),
    ipaSHA256: (if $ipaSHA256 == "" then null else $ipaSHA256 end),
    xcodeVersion: $xcodeVersion,
    iphoneSDK: $iphoneSDK,
    teamID: $teamID,
    appBundleID: $appBundleID,
    widgetBundleID: $widgetBundleID,
    displayName: $displayName,
    widgetDisplayName: $widgetDisplayName,
    appIdentifier: $appIdentifier,
    widgetIdentifier: $widgetIdentifier,
    cloudContainerID: $cloudContainerID,
    privacyPolicyURL: $privacyPolicyURL,
    supportURL: $supportURL,
    privacyManifestSHA256: {
      app: $appPrivacyManifestSHA256,
      widget: $widgetPrivacyManifestSHA256
    },
    cloudKitRecordContract: {
      recordType: "AgentIslandSnapshot",
      recordName: "latest",
      payloadField: "payloadJSON"
    },
    cloudKitEnvironment: "Production",
    signingIdentity: $signingIdentity,
    signingCertificateSHA1: $signingCertificateSHA1,
    releaseIdentityLockSHA256: $releaseIdentityLockSHA256,
    provisioningProfileExpiration: {
      app: $appProfileExpiration,
      widget: $widgetProfileExpiration
    },
    exportedProvisioningProfileExpiration: (
      if $exportedAppProfileExpiration == "" then null
      else {
        app: $exportedAppProfileExpiration,
        widget: $exportedWidgetProfileExpiration
      }
      end
    ),
    allowProvisioningUpdates: $allowProvisioningUpdates,
    uploaded: false,
    createdAt: $createdAt
  }' >"$METADATA_PATH"

# Validate the complete staged directory before its one-step same-filesystem
# rename. The per-candidate publish lock serializes same-second runs, and the
# destination is checked again immediately before commit so an existing release
# is never reused or overwritten.
/usr/bin/jq -e \
  --arg archivePath "$FINAL_ARCHIVE_PATH" \
  --arg exportedIPA "$PUBLISHED_IPA" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg releaseIdentityLockSHA256 "$RELEASE_IDENTITY_LOCK_SHA256" '
    .archivePath == $archivePath and
    .exportedIPA == (if $exportedIPA == "" then null else $exportedIPA end) and
    .ipaSHA256 == (if $ipaSHA256 == "" then null else $ipaSHA256 end) and
    .releaseIdentityLockSHA256 == $releaseIdentityLockSHA256 and
    .uploaded == false
  ' "$METADATA_PATH" >/dev/null \
  || fail "staged release metadata does not describe the final publication paths"
[[ -d "$ARCHIVE_PATH" && -f "$METADATA_PATH" && ! -L "$METADATA_PATH" ]] \
  || fail "staged release directory is incomplete"
if [[ -n "$EXPORTED_IPA" ]]; then
  [[ -f "$EXPORTED_IPA" && ! -L "$EXPORTED_IPA" && \
      -f "$EXPORTED_IPA.sha256" && ! -L "$EXPORTED_IPA.sha256" ]] \
    || fail "staged IPA or checksum is missing or unsafe"
  [[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$EXPORTED_IPA" | \
      /usr/bin/awk '{print $1}')" == "$IPA_SHA256" ]] \
    || fail "staged IPA checksum changed before publication"
fi
[[ ! -e "$FINAL_RELEASE_DIR" && ! -L "$FINAL_RELEASE_DIR" ]] \
  || fail "refusing to overwrite existing iOS release directory: $FINAL_RELEASE_DIR"

# Archive/export validation may be lengthy. Do not publish a candidate whose
# identity lock no longer matches the readiness snapshot it records.
/bin/zsh "$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"
PUBLISHED_RELEASE_DIR="$FINAL_RELEASE_DIR"
/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR" \
  || fail "could not atomically publish the staged iOS release"
STAGING_ROOT=""
[[ -d "$FINAL_ARCHIVE_PATH" && -f "$FINAL_METADATA_PATH" && \
    ! -L "$FINAL_METADATA_PATH" && \
    "$(/usr/bin/stat -f '%i' "$FINAL_RELEASE_DIR")" == "$STAGING_INODE" ]] \
  || fail "published iOS release failed its post-rename integrity check"
/usr/bin/jq -e \
  --arg archivePath "$FINAL_ARCHIVE_PATH" \
  --arg exportedIPA "$PUBLISHED_IPA" \
  --arg releaseIdentityLockSHA256 "$RELEASE_IDENTITY_LOCK_SHA256" '
    .archivePath == $archivePath and
    .exportedIPA == (if $exportedIPA == "" then null else $exportedIPA end) and
    .releaseIdentityLockSHA256 == $releaseIdentityLockSHA256 and
    .uploaded == false
  ' "$FINAL_METADATA_PATH" >/dev/null \
  || fail "published iOS release metadata changed during commit"

COMMIT_DONE=true
/bin/rmdir "$PUBLISH_LOCK"
PUBLISH_LOCK=""

print -r -- "Archive: $FINAL_ARCHIVE_PATH"
[[ -n "$PUBLISHED_IPA" ]] && print -r -- "IPA: $PUBLISHED_IPA"
print -r -- "Metadata: $FINAL_METADATA_PATH"
print -r -- "No build was uploaded. Inspect the archive before using Xcode Organizer."
