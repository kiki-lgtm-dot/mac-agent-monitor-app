#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB
umask 077

IOS_ROOT="${0:A:h:h}"
CONFIG_FILE="$IOS_ROOT/Config/Project.xcconfig"
PRIVACY_CONTRACT="$IOS_ROOT/scripts/privacy-manifest-contract.jq"
MODE="check"
MODE_WAS_EXPLICIT=false
RELEASE_DIRECTORY=""

usage() {
  /bin/cat <<'EOF'
Usage:
  ./scripts/submit-testflight.sh [--check] RELEASE_DIRECTORY
  ./scripts/submit-testflight.sh --validate RELEASE_DIRECTORY
  ./scripts/submit-testflight.sh --upload RELEASE_DIRECTORY

--check performs an entirely local, credential-free preflight of an IPA and
the release-metadata.json produced by release-ios.sh --export.

--validate additionally asks App Store Connect to validate that exact IPA.
--upload first validates and then uploads that exact IPA to App Store Connect.
Neither remote mode creates an App Store version, distributes the build to
testers, or submits it for App Review.

Remote modes use an App Store Connect team API key. Set:
  AGENT_ISLAND_ASC_API_KEY_ID
  AGENT_ISLAND_ASC_API_ISSUER_ID

Store the private key outside this repository at:
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

For --upload only, also set AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD to the exact
confirmation value printed by a successful --check. The private key is never
accepted as a command-line value and is never copied into the release folder.
EOF
}

fail() {
  print -u2 -r -- "TestFlight submission failed: $*"
  exit 2
}

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_altool_success_json() {
  local result_path="$1"
  local operation="$2"
  /usr/bin/jq -s -e '
    if length != 1 or (.[0] | type) != "object" then
      false
    else
      .[0] as $result |
      ($result["success-message"] | type == "string" and length > 0) and
      (($result | has("product-errors") | not) or
        $result["product-errors"] == null or
        (($result["product-errors"] | type) == "array" and
          ($result["product-errors"] | length) == 0)) and
      (($result | has("errors") | not) or
        $result.errors == null or
        (($result.errors | type) == "array" and
          ($result.errors | length) == 0))
    end
  ' "$result_path" >/dev/null \
    || fail "App Store Connect $operation result does not contain an unambiguous altool success response"
}

publish_readonly_no_overwrite() {
  local temporary_path="$1"
  local destination_path="$2"
  local label="$3"
  local temporary_identity misplaced_path
  [[ "${temporary_path:h}" == "${destination_path:h}" ]] \
    || fail "$label temporary file is not on the release volume"
  [[ "$(/usr/bin/stat -f '%Sp' "$temporary_path")" != *w* ]] \
    || fail "$label temporary inode is not read-only"
  temporary_identity="$(/usr/bin/stat -f '%d:%i' "$temporary_path")"
  /bin/ln -h "$temporary_path" "$destination_path" \
    || fail "could not publish $label without overwriting a file"
  if [[ ! -f "$destination_path" || -L "$destination_path" \
      || "$(/usr/bin/stat -f '%d:%i' "$destination_path")" != "$temporary_identity" ]]; then
    misplaced_path="$destination_path/${temporary_path:t}"
    if [[ -f "$misplaced_path" && ! -L "$misplaced_path" \
        && "$(/usr/bin/stat -f '%d:%i' "$misplaced_path")" == "$temporary_identity" ]]; then
      /bin/rm -f "$misplaced_path" \
        || fail "could not remove misplaced $label after a destination-directory race"
    fi
    fail "$label destination did not resolve to the sealed temporary inode"
  fi
  /bin/rm -f "$temporary_path" \
    || fail "could not remove $label temporary name after publication"
}

setting_value() {
  local key="$1"
  /usr/bin/sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" \
    "$CONFIG_FILE" | /usr/bin/tail -n 1
}

resolved_url_setting() {
  local key="$1"
  local value url_slash
  local url_slash_reference='$(AGENT_ISLAND_URL_SLASH)'
  url_slash="$(setting_value AGENT_ISLAND_URL_SLASH)"
  [[ "$url_slash" == "/" ]] \
    || fail "Project.xcconfig AGENT_ISLAND_URL_SLASH must remain a single slash"
  value="$(setting_value "$key")"
  value="${value//$url_slash_reference/$url_slash}"
  [[ -n "$value" && "$value" != *'$('* && "$value" != *'${'* ]] \
    || fail "Project.xcconfig $key is empty or unresolved"
  print -r -- "$value"
}

extract_profile_entitlements_json() {
  local profile_plist="$1"
  local json_output="$2"
  local entitlements_plist="${json_output%.json}.plist"

  # A decoded mobileprovision can contain Date/Data values that are not safe to
  # convert as one JSON document. Isolate its Entitlements dictionary first.
  /usr/bin/plutil -extract Entitlements xml1 -o "$entitlements_plist" \
    "$profile_plist" \
    || fail "could not extract provisioning-profile entitlements"
  /usr/bin/plutil -convert json -o "$json_output" "$entitlements_plist" \
    || fail "could not convert provisioning-profile entitlements to JSON"
}

profile_scalar() {
  local profile="$1"
  local key_path="$2"
  local label="$3"
  local value
  value="$(/usr/bin/plutil -extract "$key_path" raw "$profile" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "$label provisioning profile is missing $key_path"
  print -r -- "$value"
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
    certificate_path="$WORK_DIRECTORY/${label//[^A-Za-z0-9]/-}-profile-certificate-$index.der"
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

while (( $# > 0 )); do
  case "$1" in
    --check)
      [[ "$MODE_WAS_EXPLICIT" == false ]] || fail "choose only one of --check, --validate, or --upload"
      MODE="check"
      MODE_WAS_EXPLICIT=true
      ;;
    --validate)
      [[ "$MODE_WAS_EXPLICIT" == false ]] || fail "choose only one of --check, --validate, or --upload"
      MODE="validate"
      MODE_WAS_EXPLICIT=true
      ;;
    --upload)
      [[ "$MODE_WAS_EXPLICIT" == false ]] || fail "choose only one of --check, --validate, or --upload"
      MODE="upload"
      MODE_WAS_EXPLICIT=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$RELEASE_DIRECTORY" ]] || fail "only one release directory may be supplied"
      RELEASE_DIRECTORY="$1"
      ;;
  esac
  shift
done

[[ -n "$RELEASE_DIRECTORY" ]] || fail "a release directory is required"
[[ -d "$RELEASE_DIRECTORY" && ! -L "$RELEASE_DIRECTORY" ]] \
  || fail "release directory must be an existing, non-symlink directory"
RELEASE_DIRECTORY_ABSOLUTE="${RELEASE_DIRECTORY:a}"
RELEASE_DIRECTORY="${RELEASE_DIRECTORY:A}"
[[ "$RELEASE_DIRECTORY_ABSOLUTE" == "$RELEASE_DIRECTORY" ]] \
  || fail "release directory path must not traverse symlink parents"

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v codesign >/dev/null 2>&1 || fail "codesign is required"
command -v security >/dev/null 2>&1 || fail "security is required"
command -v lipo >/dev/null 2>&1 || fail "lipo is required"
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] \
  || fail "Config/Project.xcconfig is missing or is a symlink"
[[ -f "$PRIVACY_CONTRACT" ]] || fail "privacy-manifest-contract.jq is required"

METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"
[[ -f "$METADATA_PATH" && ! -L "$METADATA_PATH" ]] \
  || fail "release-metadata.json is missing or is a symlink"

/usr/bin/jq -e '
  . as $root |
  type == "object" and
  .schemaVersion == 1 and
  (.product | type == "string" and length > 0) and
  (.version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$")) and
  (.build | type == "string" and test("^[1-9][0-9]*$")) and
  (.archivePath | type == "string" and length > 0) and
  (.exportedIPA | type == "string" and length > 0) and
  (.ipaSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.teamID | type == "string" and test("^[A-Z0-9]{10}$")) and
  (.appBundleID | type == "string" and test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")) and
  (.widgetBundleID == (.appBundleID + ".liveactivity")) and
  (.displayName | type == "string" and length > 0) and
  (.widgetDisplayName | type == "string" and length > 0) and
  (.privacyPolicyURL | type == "string" and startswith("https://") and length > 8) and
  (.supportURL | type == "string" and startswith("https://") and length > 8) and
  (.appIdentifier | type == "string" and endswith("." + $root.appBundleID)) and
  (.widgetIdentifier | type == "string" and endswith("." + $root.widgetBundleID)) and
  (.cloudContainerID | type == "string" and test("^iCloud\\.[A-Za-z0-9.-]+$")) and
  (.cloudKitEnvironment == "Production") and
  (.cloudKitRecordContract == {
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON"
  }) and
  (.privacyManifestSHA256.app | type == "string" and test("^[0-9a-f]{64}$")) and
  (.privacyManifestSHA256.widget | type == "string" and test("^[0-9a-f]{64}$")) and
  (.signingIdentity | type == "string" and startswith("Apple Distribution: ")) and
  (.signingCertificateSHA1 | type == "string" and test("^[0-9A-F]{40}$")) and
  (.exportedProvisioningProfileExpiration.app | type == "string" and length > 0) and
  (.exportedProvisioningProfileExpiration.widget | type == "string" and length > 0) and
  (.allowProvisioningUpdates | type == "boolean") and
  (.uploaded == false)
' "$METADATA_PATH" >/dev/null \
  || fail "release metadata is incomplete, unverified, or from an unsupported schema"

VERSION="$(/usr/bin/jq -r '.version' "$METADATA_PATH")"
BUILD_NUMBER="$(/usr/bin/jq -r '.build' "$METADATA_PATH")"
TEAM_ID="$(/usr/bin/jq -r '.teamID' "$METADATA_PATH")"
APP_BUNDLE_ID="$(/usr/bin/jq -r '.appBundleID' "$METADATA_PATH")"
WIDGET_BUNDLE_ID="$(/usr/bin/jq -r '.widgetBundleID' "$METADATA_PATH")"
DISPLAY_NAME="$(/usr/bin/jq -r '.displayName' "$METADATA_PATH")"
WIDGET_DISPLAY_NAME="$(/usr/bin/jq -r '.widgetDisplayName' "$METADATA_PATH")"
PRIVACY_POLICY_URL="$(/usr/bin/jq -r '.privacyPolicyURL' "$METADATA_PATH")"
SUPPORT_URL="$(/usr/bin/jq -r '.supportURL' "$METADATA_PATH")"
APP_IDENTIFIER="$(/usr/bin/jq -r '.appIdentifier' "$METADATA_PATH")"
WIDGET_IDENTIFIER="$(/usr/bin/jq -r '.widgetIdentifier' "$METADATA_PATH")"
CLOUD_CONTAINER_ID="$(/usr/bin/jq -r '.cloudContainerID' "$METADATA_PATH")"
EXPECTED_IPA_SHA256="$(/usr/bin/jq -r '.ipaSHA256' "$METADATA_PATH")"
IPA_PATH="$(/usr/bin/jq -r '.exportedIPA' "$METADATA_PATH")"
ARCHIVE_PATH="$(/usr/bin/jq -r '.archivePath' "$METADATA_PATH")"
SIGNING_IDENTITY="$(/usr/bin/jq -r '.signingIdentity' "$METADATA_PATH")"
SIGNING_CERTIFICATE_SHA1="$(/usr/bin/jq -r '.signingCertificateSHA1' "$METADATA_PATH")"
EXPECTED_APP_PROFILE_EXPIRATION="$(/usr/bin/jq -r \
  '.exportedProvisioningProfileExpiration.app' "$METADATA_PATH")"
EXPECTED_WIDGET_PROFILE_EXPIRATION="$(/usr/bin/jq -r \
  '.exportedProvisioningProfileExpiration.widget' "$METADATA_PATH")"

CURRENT_DISPLAY_NAME="$(setting_value AGENT_ISLAND_DISPLAY_NAME)"
CURRENT_WIDGET_DISPLAY_NAME="$(setting_value AGENT_ISLAND_WIDGET_DISPLAY_NAME)"
CURRENT_PRIVACY_POLICY_URL="$(resolved_url_setting AGENT_ISLAND_PRIVACY_POLICY_URL)"
CURRENT_SUPPORT_URL="$(resolved_url_setting AGENT_ISLAND_SUPPORT_URL)"
[[ "$DISPLAY_NAME" == "$CURRENT_DISPLAY_NAME" ]] \
  || fail "release metadata display name does not match current Project.xcconfig"
[[ "$WIDGET_DISPLAY_NAME" == "$CURRENT_WIDGET_DISPLAY_NAME" ]] \
  || fail "release metadata Widget display name does not match current Project.xcconfig"
[[ "$PRIVACY_POLICY_URL" == "$CURRENT_PRIVACY_POLICY_URL" ]] \
  || fail "release metadata privacy policy URL does not match current Project.xcconfig"
[[ "$SUPPORT_URL" == "$CURRENT_SUPPORT_URL" ]] \
  || fail "release metadata support URL does not match current Project.xcconfig"

case "${APP_BUNDLE_ID:l}" in
  local.*|*example*|*placeholder*|*yourname*|*yourdomain*)
    fail "release metadata still contains a non-production App bundle ID"
    ;;
esac
case "${CLOUD_CONTAINER_ID:l}" in
  *example*|*placeholder*|*yourname*|*yourdomain*)
    fail "release metadata still contains a non-production CloudKit container"
    ;;
esac

[[ "$IPA_PATH" == /* && -f "$IPA_PATH" && ! -L "$IPA_PATH" ]] \
  || fail "exportedIPA must be an existing, absolute, non-symlink file"
[[ "$ARCHIVE_PATH" == /* && -d "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] \
  || fail "archivePath must be an existing, absolute, non-symlink directory"
RAW_IPA_PATH="$IPA_PATH"
RAW_ARCHIVE_PATH="$ARCHIVE_PATH"
IPA_PATH="${IPA_PATH:A}"
ARCHIVE_PATH="${ARCHIVE_PATH:A}"
[[ "$RAW_IPA_PATH" == "$IPA_PATH" && "$RAW_ARCHIVE_PATH" == "$ARCHIVE_PATH" ]] \
  || fail "release artifact paths must already be canonical and must not traverse symlink parents"
[[ "$IPA_PATH" == "$RELEASE_DIRECTORY"/* ]] \
  || fail "the IPA must remain inside the release directory"
[[ "$ARCHIVE_PATH" == "$RELEASE_DIRECTORY"/* ]] \
  || fail "the archive must remain inside the release directory"

ACTUAL_IPA_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IPA_PATH" \
  | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_IPA_SHA256" == "$EXPECTED_IPA_SHA256" ]] \
  || fail "the IPA SHA-256 no longer matches release-metadata.json"
EXPECTED_METADATA_SHA256="$(file_sha256 "$METADATA_PATH")"
verify_core_candidate_unchanged() {
  [[ -f "$METADATA_PATH" && ! -L "$METADATA_PATH" \
      && "${METADATA_PATH:A}" == "$METADATA_PATH" ]] \
    || fail "release metadata became unsafe during delivery"
  [[ -f "$IPA_PATH" && ! -L "$IPA_PATH" && "${IPA_PATH:A}" == "$IPA_PATH" ]] \
    || fail "the IPA became unsafe during delivery"
  [[ "$(file_sha256 "$METADATA_PATH")" == "$EXPECTED_METADATA_SHA256" ]] \
    || fail "release metadata changed during delivery"
  [[ "$(file_sha256 "$IPA_PATH")" == "$EXPECTED_IPA_SHA256" ]] \
    || fail "the IPA changed during delivery"
}

CHECKSUM_PATH="$IPA_PATH.sha256"
[[ -f "$CHECKSUM_PATH" && ! -L "$CHECKSUM_PATH" ]] \
  || fail "the IPA checksum sidecar is missing or is a symlink"
EXPECTED_CHECKSUM_LINE="$EXPECTED_IPA_SHA256  ${IPA_PATH:t}"
[[ "$(/bin/cat "$CHECKSUM_PATH")" == "$EXPECTED_CHECKSUM_LINE" ]] \
  || fail "the IPA checksum sidecar does not match the verified artifact"

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/agentisland-testflight.XXXXXX")"
LOCK_DIRECTORY=""
LOCK_HELD=false
VALIDATION_RESULT_TEMP=""
UPLOAD_RESULT_TEMP=""
DELIVERY_RECORD_TEMP=""
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  local temporary_path
  for temporary_path in "$VALIDATION_RESULT_TEMP" "$UPLOAD_RESULT_TEMP" \
      "$DELIVERY_RECORD_TEMP"; do
    if [[ -n "$temporary_path" && "$temporary_path" == "$RELEASE_DIRECTORY"/.testflight-* \
        && -f "$temporary_path" && ! -L "$temporary_path" ]]; then
      /bin/rm -f "$temporary_path"
    fi
  done
  if [[ "$LOCK_HELD" == true && -n "$LOCK_DIRECTORY" ]]; then
    /bin/rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
  fi
  if [[ "$WORK_DIRECTORY" == "${TMPDIR:-/tmp}"/agentisland-testflight.* ]]; then
    /bin/rm -rf "$WORK_DIRECTORY"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/chmod 0700 "$WORK_DIRECTORY" \
  || fail "could not secure the private TestFlight working directory"

/usr/bin/ditto -x -k "$IPA_PATH" "$WORK_DIRECTORY/payload"
exported_apps=("$WORK_DIRECTORY/payload/Payload"/*.app(N))
(( ${#exported_apps} == 1 )) || fail "IPA must contain exactly one App"
APP_PATH="${exported_apps[1]}"
WIDGET_PATH="$APP_PATH/PlugIns/AgentIslandLiveActivityExtension.appex"
[[ -d "$WIDGET_PATH" ]] || fail "IPA is missing the embedded Live Activity extension"
embedded_extensions=("$APP_PATH/PlugIns"/*.appex(N))
(( ${#embedded_extensions} == 1 )) \
  || fail "IPA must contain exactly one embedded extension"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$WIDGET_PATH"

APP_INFO="$APP_PATH/Info.plist"
WIDGET_INFO="$WIDGET_PATH/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_INFO")" == "$APP_BUNDLE_ID" ]] \
  || fail "IPA App bundle ID does not match release metadata"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$WIDGET_INFO")" == "$WIDGET_BUNDLE_ID" ]] \
  || fail "IPA Widget bundle ID does not match release metadata"
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$APP_INFO" 2>/dev/null)" == \
    "$DISPLAY_NAME" ]] \
  || fail "IPA App display name does not match release metadata"
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$WIDGET_INFO" 2>/dev/null)" == \
    "$WIDGET_DISPLAY_NAME" ]] \
  || fail "IPA Widget display name does not match release metadata"
[[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$APP_INFO" 2>/dev/null)" == \
    "$PRIVACY_POLICY_URL" ]] \
  || fail "IPA App privacy policy URL does not match release metadata"
[[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$APP_INFO" 2>/dev/null)" == \
    "$SUPPORT_URL" ]] \
  || fail "IPA App support URL does not match release metadata"
for plist in "$APP_INFO" "$WIDGET_INFO"; do
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")" == "$VERSION" ]] \
    || fail "IPA target version does not match release metadata"
  [[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$plist")" == "$BUILD_NUMBER" ]] \
    || fail "IPA target build number does not match release metadata"
done
[[ "$(/usr/bin/plutil -extract AgentIslandCloudKitContainerIdentifier raw "$APP_INFO")" == \
    "$CLOUD_CONTAINER_ID" ]] \
  || fail "IPA App CloudKit container does not match release metadata"
[[ "$(/usr/bin/plutil -extract AgentIslandCloudKitRecordType raw "$APP_INFO")" == \
    "AgentIslandSnapshot" ]] \
  || fail "IPA App has the wrong CloudKit record type"
[[ "$(/usr/bin/plutil -extract AgentIslandCloudKitRecordName raw "$APP_INFO")" == "latest" ]] \
  || fail "IPA App has the wrong CloudKit record name"
[[ "$(/usr/bin/plutil -extract AgentIslandCloudKitPayloadField raw "$APP_INFO")" == \
    "payloadJSON" ]] \
  || fail "IPA App has the wrong CloudKit payload field"
[[ "$(/usr/bin/plutil -extract ITSAppUsesNonExemptEncryption raw "$APP_INFO")" == false ]] \
  || fail "IPA App export-compliance declaration changed"

APP_PRIVACY="$APP_PATH/PrivacyInfo.xcprivacy"
WIDGET_PRIVACY="$WIDGET_PATH/PrivacyInfo.xcprivacy"
[[ -f "$APP_PRIVACY" && -f "$WIDGET_PRIVACY" ]] \
  || fail "IPA App or Widget privacy manifest is missing"
APP_PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$APP_PRIVACY" \
  | /usr/bin/awk '{print $1}')"
WIDGET_PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$WIDGET_PRIVACY" \
  | /usr/bin/awk '{print $1}')"
[[ "$APP_PRIVACY_SHA256" == "$(/usr/bin/jq -r '.privacyManifestSHA256.app' "$METADATA_PATH")" ]] \
  || fail "IPA App privacy manifest changed after release verification"
[[ "$WIDGET_PRIVACY_SHA256" == "$(/usr/bin/jq -r '.privacyManifestSHA256.widget' "$METADATA_PATH")" ]] \
  || fail "IPA Widget privacy manifest changed after release verification"
/usr/bin/plutil -convert json -o "$WORK_DIRECTORY/app-privacy.json" "$APP_PRIVACY"
/usr/bin/plutil -convert json -o "$WORK_DIRECTORY/widget-privacy.json" "$WIDGET_PRIVACY"
/usr/bin/jq -e --arg target app -f "$PRIVACY_CONTRACT" \
  "$WORK_DIRECTORY/app-privacy.json" >/dev/null \
  || fail "IPA App privacy manifest no longer matches the reviewed disclosure"
/usr/bin/jq -e --arg target widget -f "$PRIVACY_CONTRACT" \
  "$WORK_DIRECTORY/widget-privacy.json" >/dev/null \
  || fail "IPA Widget privacy manifest no longer matches the reviewed disclosure"

APP_SIGNATURE_INFO="$WORK_DIRECTORY/app-signature.txt"
WIDGET_SIGNATURE_INFO="$WORK_DIRECTORY/widget-signature.txt"
/usr/bin/codesign -d --verbose=4 "$APP_PATH" >/dev/null 2>"$APP_SIGNATURE_INFO"
/usr/bin/codesign -d --verbose=4 "$WIDGET_PATH" >/dev/null 2>"$WIDGET_SIGNATURE_INFO"
APP_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' "$APP_SIGNATURE_INFO" | /usr/bin/head -n 1)"
WIDGET_AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' "$WIDGET_SIGNATURE_INFO" | /usr/bin/head -n 1)"
APP_SIGNED_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$APP_SIGNATURE_INFO" | /usr/bin/head -n 1)"
WIDGET_SIGNED_TEAM="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$WIDGET_SIGNATURE_INFO" | /usr/bin/head -n 1)"
[[ "$APP_AUTHORITY" == "$SIGNING_IDENTITY" && "$WIDGET_AUTHORITY" == "$SIGNING_IDENTITY" ]] \
  || fail "IPA signing identity differs from release metadata"
[[ "$APP_SIGNED_TEAM" == "$TEAM_ID" && "$WIDGET_SIGNED_TEAM" == "$TEAM_ID" ]] \
  || fail "IPA TeamIdentifier differs from release metadata"
APP_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
  "$APP_PATH" "$WORK_DIRECTORY/submission-app-certificates" "IPA App")"
WIDGET_CERTIFICATE_SHA1="$(extract_leaf_certificate_sha1 \
  "$WIDGET_PATH" "$WORK_DIRECTORY/submission-widget-certificates" "IPA Widget")"
[[ "$APP_CERTIFICATE_SHA1" == "$SIGNING_CERTIFICATE_SHA1" && \
    "$WIDGET_CERTIFICATE_SHA1" == "$SIGNING_CERTIFICATE_SHA1" ]] \
  || fail "an IPA target signing certificate differs from release metadata"

/usr/bin/codesign -d --entitlements - "$APP_PATH" >"$WORK_DIRECTORY/app-entitlements.plist" 2>/dev/null
/usr/bin/codesign -d --entitlements - "$WIDGET_PATH" >"$WORK_DIRECTORY/widget-entitlements.plist" 2>/dev/null
/usr/bin/plutil -convert json -o "$WORK_DIRECTORY/app-entitlements.json" \
  "$WORK_DIRECTORY/app-entitlements.plist"
/usr/bin/plutil -convert json -o "$WORK_DIRECTORY/widget-entitlements.json" \
  "$WORK_DIRECTORY/widget-entitlements.plist"

APP_PROFILE="$APP_PATH/embedded.mobileprovision"
WIDGET_PROFILE="$WIDGET_PATH/embedded.mobileprovision"
[[ -f "$APP_PROFILE" && ! -L "$APP_PROFILE" ]] \
  || fail "IPA App is missing a regular embedded.mobileprovision"
[[ -f "$WIDGET_PROFILE" && ! -L "$WIDGET_PROFILE" ]] \
  || fail "IPA Widget is missing a regular embedded.mobileprovision"
APP_PROFILE_PLIST="$WORK_DIRECTORY/app-profile.plist"
WIDGET_PROFILE_PLIST="$WORK_DIRECTORY/widget-profile.plist"
APP_PROFILE_ENTITLEMENTS_JSON="$WORK_DIRECTORY/app-profile-entitlements.json"
WIDGET_PROFILE_ENTITLEMENTS_JSON="$WORK_DIRECTORY/widget-profile-entitlements.json"
/usr/bin/security cms -D -i "$APP_PROFILE" >"$APP_PROFILE_PLIST" \
  || fail "could not decode IPA App embedded.mobileprovision"
/usr/bin/security cms -D -i "$WIDGET_PROFILE" >"$WIDGET_PROFILE_PLIST" \
  || fail "could not decode IPA Widget embedded.mobileprovision"
extract_profile_entitlements_json "$APP_PROFILE_PLIST" \
  "$APP_PROFILE_ENTITLEMENTS_JSON"
extract_profile_entitlements_json "$WIDGET_PROFILE_PLIST" \
  "$WIDGET_PROFILE_ENTITLEMENTS_JSON"
profile_authorizes_certificate_sha1 "$APP_PROFILE_PLIST" \
  "$APP_CERTIFICATE_SHA1" "IPA App"
profile_authorizes_certificate_sha1 "$WIDGET_PROFILE_PLIST" \
  "$WIDGET_CERTIFICATE_SHA1" "IPA Widget"

APP_PREFIX_COUNT="$(profile_scalar "$APP_PROFILE_PLIST" \
  ApplicationIdentifierPrefix "IPA App")"
WIDGET_PREFIX_COUNT="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ApplicationIdentifierPrefix "IPA Widget")"
APP_PROFILE_TEAM_COUNT="$(profile_scalar "$APP_PROFILE_PLIST" TeamIdentifier "IPA App")"
WIDGET_PROFILE_TEAM_COUNT="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  TeamIdentifier "IPA Widget")"
[[ "$APP_PREFIX_COUNT" == "1" && "$WIDGET_PREFIX_COUNT" == "1" ]] \
  || fail "IPA App and Widget profiles must each contain exactly one App ID prefix"
[[ "$APP_PROFILE_TEAM_COUNT" == "1" && "$WIDGET_PROFILE_TEAM_COUNT" == "1" ]] \
  || fail "IPA App and Widget profiles must each contain exactly one TeamIdentifier"

APP_ID_PREFIX="$(profile_scalar "$APP_PROFILE_PLIST" \
  ApplicationIdentifierPrefix.0 "IPA App")"
WIDGET_ID_PREFIX="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ApplicationIdentifierPrefix.0 "IPA Widget")"
APP_PROFILE_TEAM="$(profile_scalar "$APP_PROFILE_PLIST" TeamIdentifier.0 "IPA App")"
WIDGET_PROFILE_TEAM="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  TeamIdentifier.0 "IPA Widget")"
APP_PROFILE_EXPIRATION="$(profile_scalar "$APP_PROFILE_PLIST" ExpirationDate "IPA App")"
WIDGET_PROFILE_EXPIRATION="$(profile_scalar "$WIDGET_PROFILE_PLIST" \
  ExpirationDate "IPA Widget")"
[[ "$APP_PROFILE_TEAM" == "$TEAM_ID" && "$WIDGET_PROFILE_TEAM" == "$TEAM_ID" ]] \
  || fail "IPA App or Widget provisioning profile belongs to a different Team ID"
validate_app_store_profile_shape "$APP_PROFILE_PLIST" "IPA App" \
  "$APP_PROFILE_EXPIRATION"
validate_app_store_profile_shape "$WIDGET_PROFILE_PLIST" "IPA Widget" \
  "$WIDGET_PROFILE_EXPIRATION"
[[ "$APP_PROFILE_EXPIRATION" == "$EXPECTED_APP_PROFILE_EXPIRATION" && \
    "$WIDGET_PROFILE_EXPIRATION" == "$EXPECTED_WIDGET_PROFILE_EXPIRATION" ]] \
  || fail "IPA provisioning profile expiration differs from release metadata"

EXPECTED_APP_IDENTIFIER="$APP_ID_PREFIX.$APP_BUNDLE_ID"
EXPECTED_WIDGET_IDENTIFIER="$WIDGET_ID_PREFIX.$WIDGET_BUNDLE_ID"
[[ "$APP_IDENTIFIER" == "$EXPECTED_APP_IDENTIFIER" && \
    "$WIDGET_IDENTIFIER" == "$EXPECTED_WIDGET_IDENTIFIER" ]] \
  || fail "release metadata identifiers do not match the IPA provisioning profiles"

/usr/bin/jq -e -s \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER_ID" '
    .[0] as $signed
    | .[1] as $profile
    | $signed."application-identifier" == $identifier
      and $profile."application-identifier" == $identifier
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
  ' "$WORK_DIRECTORY/app-entitlements.json" \
    "$APP_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
  || fail "IPA App signature/profile failed exact production CloudKit entitlement validation"
/usr/bin/jq -e -s \
  --arg identifier "$WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '
    def no_cloud:
      [keys[] | select(
        startswith("com.apple.developer.icloud") or
        startswith("com.apple.developer.ubiquity")
      )] | length == 0;
    .[0] as $signed
    | .[1] as $profile
    | $signed."application-identifier" == $identifier
      and $profile."application-identifier" == $identifier
      and $signed."application-identifier" == $profile."application-identifier"
      and $signed."com.apple.developer.team-identifier" == $team
      and $profile."com.apple.developer.team-identifier" == $team
      and (($signed."get-task-allow" // false) == false)
      and (($profile."get-task-allow" // false) == false)
      and ($signed | no_cloud)
      and ($profile | no_cloud)
  ' "$WORK_DIRECTORY/widget-entitlements.json" \
    "$WIDGET_PROFILE_ENTITLEMENTS_JSON" >/dev/null \
  || fail "IPA Widget signature/profile identifiers are wrong or an iCloud entitlement leaked"

APP_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw "$APP_INFO")"
WIDGET_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw "$WIDGET_INFO")"
for executable in "$APP_PATH/$APP_EXECUTABLE" "$WIDGET_PATH/$WIDGET_EXECUTABLE"; do
  [[ -f "$executable" ]] || fail "IPA target executable is missing"
  ARCHITECTURES="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)" \
    || fail "could not inspect IPA target architectures"
  [[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " != *" x86_64 "* ]] \
    || fail "IPA targets must contain arm64 and must not contain simulator architecture x86_64"
done

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$EXPECTED_IPA_SHA256"
print -r -- "Local TestFlight preflight passed."
print -r -- "IPA: $IPA_PATH"
print -r -- "Bundle: $APP_BUNDLE_ID"
print -r -- "Version/build: $VERSION ($BUILD_NUMBER)"
print -r -- "SHA-256: $EXPECTED_IPA_SHA256"
print -r -- "Upload confirmation: $CONFIRMATION_VALUE"

[[ "$MODE" != "check" ]] || exit 0
verify_core_candidate_unchanged

DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] \
  || fail "select full Xcode 26 or newer before contacting App Store Connect"
[[ -x "$DEVELOPER_PATH/usr/bin/altool" || -x "$DEVELOPER_PATH/../SharedFrameworks/ContentDeliveryServices.framework/Frameworks/AppStoreService.framework/Support/altool" \
    || -n "$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun --find altool 2>/dev/null || true)" ]] \
  || fail "the selected Xcode does not provide altool"
XCODE_VERSION="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild -version \
  | /usr/bin/awk '/^Xcode / {print $2; exit}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
[[ "$XCODE_MAJOR" == <-> ]] || fail "could not determine the selected Xcode version"
(( XCODE_MAJOR >= 26 )) || fail "Xcode 26 or newer is required"

API_KEY_ID="${AGENT_ISLAND_ASC_API_KEY_ID:-}"
API_ISSUER_ID="${AGENT_ISLAND_ASC_API_ISSUER_ID:-}"
print -r -- "$API_KEY_ID" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$' \
  || fail "AGENT_ISLAND_ASC_API_KEY_ID must be a 10-character uppercase key ID"
print -r -- "$API_ISSUER_ID" | /usr/bin/grep -Eq \
  '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
  || fail "AGENT_ISLAND_ASC_API_ISSUER_ID must be the App Store Connect issuer UUID"

PRIVATE_KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
[[ -f "$PRIVATE_KEY_PATH" && ! -L "$PRIVATE_KEY_PATH" ]] \
  || fail "App Store Connect private key is missing from ~/.appstoreconnect/private_keys"
PRIVATE_KEY_MODE="$(/usr/bin/stat -f '%Lp' "$PRIVATE_KEY_PATH")"
[[ "$PRIVATE_KEY_MODE" == <-> ]] || fail "could not inspect private-key permissions"
(( (8#$PRIVATE_KEY_MODE & 8#077) == 0 )) \
  || fail "App Store Connect private key must not be readable by group or other users"

[[ -w "$RELEASE_DIRECTORY" ]] \
  || fail "release directory must be writable before recording App Store Connect results"
LOCK_DIRECTORY="$RELEASE_DIRECTORY/.testflight-submit.lock"
/bin/mkdir "$LOCK_DIRECTORY" 2>/dev/null \
  || fail "another TestFlight validation or upload is already active for this release directory"
LOCK_HELD=true
/bin/chmod 0700 "$LOCK_DIRECTORY" \
  || fail "could not secure the TestFlight release-directory lock"

STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
VALIDATION_RESULT="$RELEASE_DIRECTORY/testflight-validation-$STAMP.json"
[[ ! -e "$VALIDATION_RESULT" && ! -L "$VALIDATION_RESULT" ]] \
  || fail "refusing to overwrite an existing App Store Connect validation result"
if [[ "$MODE" == "upload" ]]; then
  UPLOAD_RESULT="$RELEASE_DIRECTORY/testflight-upload-$STAMP.json"
  DELIVERY_RECORD="$RELEASE_DIRECTORY/testflight-delivery-$STAMP.json"
  [[ ! -e "$UPLOAD_RESULT" && ! -L "$UPLOAD_RESULT" ]] \
    || fail "refusing to overwrite an existing App Store Connect upload result"
  [[ ! -e "$DELIVERY_RECORD" && ! -L "$DELIVERY_RECORD" ]] \
    || fail "refusing to overwrite an existing TestFlight delivery record"
fi

STAGED_IPA_PATH="$WORK_DIRECTORY/testflight-upload-candidate.ipa"
/bin/cp "$IPA_PATH" "$STAGED_IPA_PATH" \
  || fail "could not copy the verified IPA into private staging"
[[ -f "$STAGED_IPA_PATH" && ! -L "$STAGED_IPA_PATH" ]] \
  || fail "private staged IPA is not a regular file"
/bin/chmod 0400 "$STAGED_IPA_PATH" \
  || fail "could not make the private staged IPA read-only"
verify_staged_candidate_unchanged() {
  [[ -f "$STAGED_IPA_PATH" && ! -L "$STAGED_IPA_PATH" ]] \
    || fail "the private staged IPA became unsafe"
  [[ "$(file_sha256 "$STAGED_IPA_PATH")" == "$EXPECTED_IPA_SHA256" ]] \
    || fail "the private staged IPA SHA-256 differs from the verified release candidate"
}
verify_staged_candidate_unchanged
verify_core_candidate_unchanged

VALIDATION_RESULT_TEMP="$(mktemp "$RELEASE_DIRECTORY/.testflight-validation.XXXXXX")"
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun altool \
  --validate-app \
  --file "$STAGED_IPA_PATH" \
  --type ios \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID" \
  --output-format json >"$VALIDATION_RESULT_TEMP"
[[ -s "$VALIDATION_RESULT_TEMP" ]] || fail "App Store Connect returned no validation result"
/bin/chmod 0444 "$VALIDATION_RESULT_TEMP" \
  || fail "could not seal the App Store Connect validation result"
verify_altool_success_json "$VALIDATION_RESULT_TEMP" "validation"
verify_staged_candidate_unchanged
verify_core_candidate_unchanged
publish_readonly_no_overwrite "$VALIDATION_RESULT_TEMP" "$VALIDATION_RESULT" \
  "App Store Connect validation result"
VALIDATION_RESULT_TEMP=""
VALIDATION_RESULT_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$VALIDATION_RESULT" | /usr/bin/awk '{print $1}')"
print -r -- "App Store Connect validation passed: $VALIDATION_RESULT"

[[ "$MODE" == "upload" ]] || exit 0
verify_core_candidate_unchanged
verify_staged_candidate_unchanged
[[ "${AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD:-}" == "$CONFIRMATION_VALUE" ]] \
  || fail "AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD does not match this exact IPA"

UPLOAD_RESULT_TEMP="$(mktemp "$RELEASE_DIRECTORY/.testflight-upload.XXXXXX")"
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun altool \
  --upload-app \
  --file "$STAGED_IPA_PATH" \
  --type ios \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID" \
  --output-format json >"$UPLOAD_RESULT_TEMP"
[[ -s "$UPLOAD_RESULT_TEMP" ]] || fail "App Store Connect returned no upload result"
/bin/chmod 0444 "$UPLOAD_RESULT_TEMP" \
  || fail "could not seal the App Store Connect upload result"
verify_altool_success_json "$UPLOAD_RESULT_TEMP" "upload"
verify_staged_candidate_unchanged
verify_core_candidate_unchanged
publish_readonly_no_overwrite "$UPLOAD_RESULT_TEMP" "$UPLOAD_RESULT" \
  "App Store Connect upload result"
UPLOAD_RESULT_TEMP=""
UPLOAD_RESULT_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$UPLOAD_RESULT" | /usr/bin/awk '{print $1}')"

verify_core_candidate_unchanged
verify_staged_candidate_unchanged
METADATA_SHA256="$EXPECTED_METADATA_SHA256"
DELIVERY_RECORD_TEMP="$(mktemp "$RELEASE_DIRECTORY/.testflight-delivery.XXXXXX")"
/usr/bin/jq -n \
  --arg submittedAt "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$EXPECTED_IPA_SHA256" \
  --arg releaseMetadataPath "$METADATA_PATH" \
  --arg releaseMetadataSHA256 "$METADATA_SHA256" \
  --arg validationResultPath "$VALIDATION_RESULT" \
  --arg validationResultSHA256 "$VALIDATION_RESULT_SHA256" \
  --arg uploadResultPath "$UPLOAD_RESULT" \
  --arg uploadResultSHA256 "$UPLOAD_RESULT_SHA256" '{
    schemaVersion: 1,
    platform: "iOS",
    destination: "App Store Connect / TestFlight",
    submittedAt: $submittedAt,
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    ipaPath: $ipaPath,
    ipaSHA256: $ipaSHA256,
    releaseMetadataPath: $releaseMetadataPath,
    releaseMetadataSHA256: $releaseMetadataSHA256,
    validationResultPath: $validationResultPath,
    validationResultSHA256: $validationResultSHA256,
    uploadResultPath: $uploadResultPath,
    uploadResultSHA256: $uploadResultSHA256,
    uploadAccepted: true,
    processingState: null,
    appStoreConnectBuildID: null,
    processingVerified: false,
    processingVerifiedAt: null,
    distributedToTesters: false,
    installedFromTestFlight: false,
    testedAt: null,
    submittedForAppReview: false
  }' >"$DELIVERY_RECORD_TEMP"

/bin/chmod 0444 "$DELIVERY_RECORD_TEMP" \
  || fail "could not seal the generated TestFlight delivery record"
/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "iOS" and
  .destination == "App Store Connect / TestFlight" and
  .uploadAccepted == true and
  .processingState == null and
  .processingVerified == false and
  .distributedToTesters == false and
  .installedFromTestFlight == false and
  .submittedForAppReview == false
' "$DELIVERY_RECORD_TEMP" >/dev/null \
  || fail "generated TestFlight delivery record failed its schema contract"
publish_readonly_no_overwrite "$DELIVERY_RECORD_TEMP" "$DELIVERY_RECORD" \
  "TestFlight delivery record"
DELIVERY_RECORD_TEMP=""

print -r -- "Upload accepted by altool: $UPLOAD_RESULT"
print -r -- "Delivery record: $DELIVERY_RECORD"
print -r -- "Wait for App Store Connect processing, inspect every warning, then verify the build before distributing it."
