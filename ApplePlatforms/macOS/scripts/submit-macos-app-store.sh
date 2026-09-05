#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB NULL_GLOB
umask 077

MAC_ROOT="${0:A:h:h}"
PRODUCT_ROOT="${MAC_ROOT:h:h}"
MAC_CONFIG_FILE="$MAC_ROOT/Config/Project.xcconfig"
SHARED_CONFIG_FILE="$PRODUCT_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
SOURCE_PRIVACY_MANIFEST="$PRODUCT_ROOT/Resources/PrivacyInfo.xcprivacy"
PREFLIGHT_ASSERTION="$PRODUCT_ROOT/scripts/assert-release-preflight.sh"
READINESS_SCRIPT="$PRODUCT_ROOT/scripts/release-readiness.sh"
CMS_PROFILE_HELPER="$PRODUCT_ROOT/scripts/apple-cms-profile.zsh"
CLOUDKIT_PROFILE_AUTHORIZATION="$PRODUCT_ROOT/scripts/cloudkit-profile-authorization.jq"
PUBLIC_APP_NAME="MAC版灵动岛--Agent运行监测"
APP_CATEGORY="public.app-category.developer-tools"
MINIMUM_XCODE_MAJOR=14
MODE="check"
MODE_WAS_EXPLICIT=false
RELEASE_DIRECTORY=""
WORK_DIRECTORY=""
VALIDATION_TEMP=""
UPLOAD_TEMP=""
DELIVERY_TEMP=""
UPLOAD_READINESS_REPORT=""
REMOTE_LOCK_DIRECTORY=""
REMOTE_LOCK_IDENTITY=""
REMOTE_LOCK_HELD=false

usage() {
  /bin/cat <<'EOF'
Usage:
  ./submit-macos-app-store.sh [--check] RELEASE_DIRECTORY
  ./submit-macos-app-store.sh --validate RELEASE_DIRECTORY
  ./submit-macos-app-store.sh --upload RELEASE_DIRECTORY

--check performs a credential-free, offline verification of the exact Mac App
Store .pkg, Archive ZIP, release metadata, signatures, provisioning profile,
entitlements, privacy manifest, and packaged application contents.

--validate additionally asks App Store Connect to validate that exact .pkg.
--upload validates first and then uploads that exact .pkg. Upload acceptance is
not evidence that Apple processing is Complete, that warnings were reviewed,
or that the build was submitted for App Review.

Remote modes use an App Store Connect team API key. Set:
  AGENT_ISLAND_ASC_API_KEY_ID
  AGENT_ISLAND_ASC_API_ISSUER_ID

Store the private key outside this repository at:
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

For --upload only, set AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD to the exact
Bundle-ID:Version:Build:PKG-SHA-256 value printed by a successful --check.
EOF
}

fail() {
  print -u2 -r -- "macOS App Store delivery failed: $*"
  exit 2
}

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$WORK_DIRECTORY" && \
      "$WORK_DIRECTORY" == /private/tmp/agentisland-mac-delivery.* ]]; then
    /bin/rm -rf "$WORK_DIRECTORY"
  fi
  for temporary_path in "$VALIDATION_TEMP" "$UPLOAD_TEMP" "$DELIVERY_TEMP"; do
    if [[ -n "$RELEASE_DIRECTORY" && -n "$temporary_path" && \
        "$temporary_path" == "$RELEASE_DIRECTORY"/.mac-app-store-*.?????? && \
        -f "$temporary_path" && ! -L "$temporary_path" ]]; then
      /bin/rm -f "$temporary_path"
    fi
  done
  if [[ "$REMOTE_LOCK_HELD" == true && -n "$RELEASE_DIRECTORY" && \
      "$REMOTE_LOCK_DIRECTORY" == \
        "$RELEASE_DIRECTORY/.mac-app-store-submit.lock" && \
      -d "$REMOTE_LOCK_DIRECTORY" && ! -L "$REMOTE_LOCK_DIRECTORY" && \
      "$(/usr/bin/stat -f '%d:%i' "$REMOTE_LOCK_DIRECTORY" 2>/dev/null)" == \
        "$REMOTE_LOCK_IDENTITY" ]]; then
    /bin/rmdir "$REMOTE_LOCK_DIRECTORY" 2>/dev/null
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# > 0 )); do
  case "$1" in
    --check)
      [[ "$MODE_WAS_EXPLICIT" == false ]] \
        || fail "choose only one of --check, --validate, or --upload"
      MODE="check"
      MODE_WAS_EXPLICIT=true
      ;;
    --validate)
      [[ "$MODE_WAS_EXPLICIT" == false ]] \
        || fail "choose only one of --check, --validate, or --upload"
      MODE="validate"
      MODE_WAS_EXPLICIT=true
      ;;
    --upload)
      [[ "$MODE_WAS_EXPLICIT" == false ]] \
        || fail "choose only one of --check, --validate, or --upload"
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
      [[ -z "$RELEASE_DIRECTORY" ]] \
        || fail "only one release directory may be supplied"
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

for tool in /usr/bin/codesign /usr/bin/cmp /usr/bin/diff /usr/bin/ditto /usr/bin/find \
  /usr/bin/jq /usr/bin/lipo /usr/bin/plutil /usr/bin/security /usr/bin/xattr \
  /usr/bin/shasum /usr/bin/stat /usr/bin/unzip /usr/bin/zipinfo \
  /usr/sbin/pkgutil; do
  [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done
[[ -f "$MAC_CONFIG_FILE" && ! -L "$MAC_CONFIG_FILE" ]] \
  || fail "macOS Config/Project.xcconfig is missing or is a symlink"
[[ -f "$SHARED_CONFIG_FILE" && ! -L "$SHARED_CONFIG_FILE" ]] \
  || fail "shared Config/Project.xcconfig is missing or is a symlink"
[[ -f "$SOURCE_PRIVACY_MANIFEST" && ! -L "$SOURCE_PRIVACY_MANIFEST" ]] \
  || fail "reviewed source PrivacyInfo.xcprivacy is missing or is a symlink"
[[ -f "$CMS_PROFILE_HELPER" && ! -L "$CMS_PROFILE_HELPER" ]] \
  || fail "Apple CMS profile helper is missing or unsafe"
source "$CMS_PROFILE_HELPER"
[[ -f "$CLOUDKIT_PROFILE_AUTHORIZATION" && \
  ! -L "$CLOUDKIT_PROFILE_AUTHORIZATION" ]] \
  || fail "CloudKit profile authorization contract is missing or unsafe"

METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"
[[ -f "$METADATA_PATH" && ! -L "$METADATA_PATH" ]] \
  || fail "release-metadata.json is missing or is a symlink"

/usr/bin/jq -e '
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
  . as $root |
  type == "object" and
  .schemaVersion == 1 and
  .product == "MAC版灵动岛--Agent运行监测" and
  .platform == "macOS" and
  .distribution == "mac-app-store" and
  (.version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$")) and
  (.build | type == "string" and test("^[1-9][0-9]*$")) and
  (.archivePath | type == "string" and length > 0) and
  (.archiveZip | type == "string" and length > 0) and
  (.archiveZipSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.exportedPackage | type == "string" and endswith(".pkg")) and
  (.packageSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  export_method_matches_xcode and
  .exportDestination == "export" and
  (.macosSDK | type == "string" and length > 0) and
  (.teamID | type == "string" and test("^[A-Z0-9]{10}$")) and
  (.appBundleID | type == "string" and test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")) and
  .displayName == "MAC版灵动岛--Agent运行监测" and
  .applicationCategory == "public.app-category.developer-tools" and
  (.copyright | type == "string" and length >= 2 and length <= 200) and
  (.applicationIdentifier | type == "string" and endswith("." + $root.appBundleID)) and
  (.cloudContainerID | type == "string" and test("^iCloud\\.[A-Za-z0-9.-]+$")) and
  .cloudKitEnvironment == "Production" and
  (.privacyPolicyURL | type == "string" and startswith("https://") and length > 8) and
  (.supportURL | type == "string" and startswith("https://") and length > 8) and
  (.privacyManifestSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  .quarantineFree == true and
  (.signingIdentity | type == "string" and length > 0) and
  (.signingCertificateSHA1 | type == "string" and test("^[0-9A-F]{40}$")) and
  (.provisioningProfile.uuid | type == "string" and length > 0) and
  (.provisioningProfile.name | type == "string" and length > 0) and
  (.provisioningProfile.expiration | type == "string" and length > 0) and
  .provisioningProfile.certificateMatches == true and
  (.installerSigningIdentity | type == "string" and length > 0) and
  (.exportedProvisioningProfileExpiration | type == "string" and length > 0) and
  (.allowProvisioningUpdates | type == "boolean") and
  .uploaded == false
' "$METADATA_PATH" >/dev/null \
  || fail "release metadata is incomplete, unverified, or from an unsupported schema"

VERSION="$(/usr/bin/jq -r '.version' "$METADATA_PATH")"
BUILD_NUMBER="$(/usr/bin/jq -r '.build' "$METADATA_PATH")"
TEAM_ID="$(/usr/bin/jq -r '.teamID' "$METADATA_PATH")"
APP_BUNDLE_ID="$(/usr/bin/jq -r '.appBundleID' "$METADATA_PATH")"
DISPLAY_NAME="$(/usr/bin/jq -r '.displayName' "$METADATA_PATH")"
COPYRIGHT="$(/usr/bin/jq -r '.copyright' "$METADATA_PATH")"
APPLICATION_IDENTIFIER="$(/usr/bin/jq -r '.applicationIdentifier' "$METADATA_PATH")"
CLOUD_CONTAINER_ID="$(/usr/bin/jq -r '.cloudContainerID' "$METADATA_PATH")"
PRIVACY_POLICY_URL="$(/usr/bin/jq -r '.privacyPolicyURL' "$METADATA_PATH")"
SUPPORT_URL="$(/usr/bin/jq -r '.supportURL' "$METADATA_PATH")"
EXPECTED_PRIVACY_SHA256="$(/usr/bin/jq -r '.privacyManifestSHA256' "$METADATA_PATH")"
SIGNING_IDENTITY="$(/usr/bin/jq -r '.signingIdentity' "$METADATA_PATH")"
SIGNING_CERTIFICATE_SHA1="$(/usr/bin/jq -r '.signingCertificateSHA1' "$METADATA_PATH")"
PROFILE_UUID="$(/usr/bin/jq -r '.provisioningProfile.uuid' "$METADATA_PATH")"
PROFILE_NAME="$(/usr/bin/jq -r '.provisioningProfile.name' "$METADATA_PATH")"
PROFILE_EXPIRATION="$(/usr/bin/jq -r '.provisioningProfile.expiration' "$METADATA_PATH")"
EXPORTED_PROFILE_EXPIRATION="$(/usr/bin/jq -r '.exportedProvisioningProfileExpiration' "$METADATA_PATH")"
INSTALLER_SIGNING_IDENTITY="$(/usr/bin/jq -r '.installerSigningIdentity' "$METADATA_PATH")"
EXPECTED_ARCHIVE_SHA256="$(/usr/bin/jq -r '.archiveZipSHA256' "$METADATA_PATH")"
EXPECTED_PACKAGE_SHA256="$(/usr/bin/jq -r '.packageSHA256' "$METADATA_PATH")"

require_release_file() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and must not traverse symlink parents"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

require_release_directory() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -d "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink directory"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and must not traverse symlink parents"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

ARCHIVE_PATH="$(require_release_directory \
  "$(/usr/bin/jq -r '.archivePath' "$METADATA_PATH")" "Archive")"
ARCHIVE_ZIP_PATH="$(require_release_file \
  "$(/usr/bin/jq -r '.archiveZip' "$METADATA_PATH")" "Archive ZIP")"
PACKAGE_PATH="$(require_release_file \
  "$(/usr/bin/jq -r '.exportedPackage' "$METADATA_PATH")" "App Store package")"
[[ "${ARCHIVE_PATH:t}" == "AgentIslandMac.xcarchive" ]] \
  || fail "Archive has an unexpected name"
[[ "${ARCHIVE_ZIP_PATH:t}" == "AgentIslandMac.xcarchive.zip" ]] \
  || fail "Archive ZIP has an unexpected name"
[[ "${PACKAGE_PATH:e:l}" == "pkg" ]] || fail "upload candidate must be a .pkg"

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

assert_no_quarantine_attributes() {
  local candidate_path="$1"
  local label="$2"
  local attribute_listing
  attribute_listing="$(LC_ALL=C /usr/bin/xattr -r "$candidate_path" 2>/dev/null)" \
    || fail "$label extended attributes could not be inspected"
  if print -r -- "$attribute_listing" \
      | /usr/bin/grep -Eq '(^|: )com\.apple\.quarantine$'; then
    fail "$label contains com.apple.quarantine; clean the candidate and rebuild"
  fi
}

assert_no_quarantine_attributes "$ARCHIVE_ZIP_PATH" "Archive ZIP"
assert_no_quarantine_attributes "$PACKAGE_PATH" "App Store package"

EXPECTED_METADATA_SHA256="$(file_sha256 "$METADATA_PATH")"
verify_core_candidate_unchanged() {
  [[ "$(file_sha256 "$METADATA_PATH")" == "$EXPECTED_METADATA_SHA256" ]] \
    || fail "release metadata changed during delivery"
  [[ "$(file_sha256 "$ARCHIVE_ZIP_PATH")" == "$EXPECTED_ARCHIVE_SHA256" ]] \
    || fail "Archive ZIP changed during delivery"
  [[ "$(file_sha256 "$PACKAGE_PATH")" == "$EXPECTED_PACKAGE_SHA256" ]] \
    || fail "App Store package changed during delivery"
  assert_no_quarantine_attributes "$ARCHIVE_ZIP_PATH" "Archive ZIP"
  assert_no_quarantine_attributes "$PACKAGE_PATH" "App Store package"
}

verify_altool_success_json() {
  local result_path="$1"
  local operation="$2"
  /usr/bin/jq -s -e '
    length == 1 and
    (.[0] |
      type == "object" and
      (.["success-message"] | type == "string" and length > 0) and
      ((has("product-errors") | not) or
        .["product-errors"] == null or .["product-errors"] == []) and
      ((has("errors") | not) or .errors == null or .errors == [])
    )
  ' "$result_path" >/dev/null \
    || fail "App Store Connect $operation result does not contain an unambiguous altool success response"
}

validate_checksum_sidecar() {
  local artifact="$1"
  local expected_sha="$2"
  local checksum_path="$artifact.sha256"
  [[ -f "$checksum_path" && ! -L "$checksum_path" ]] \
    || fail "${artifact:t}.sha256 is missing or is a symlink"
  [[ "$(/bin/cat "$checksum_path")" == "$expected_sha  ${artifact:t}" ]] \
    || fail "${artifact:t}.sha256 does not identify the exact candidate"
}

[[ "$(file_sha256 "$ARCHIVE_ZIP_PATH")" == "$EXPECTED_ARCHIVE_SHA256" ]] \
  || fail "Archive ZIP SHA-256 differs from release metadata"
[[ "$(file_sha256 "$PACKAGE_PATH")" == "$EXPECTED_PACKAGE_SHA256" ]] \
  || fail "App Store package SHA-256 differs from release metadata"
validate_checksum_sidecar "$ARCHIVE_ZIP_PATH" "$EXPECTED_ARCHIVE_SHA256"
validate_checksum_sidecar "$PACKAGE_PATH" "$EXPECTED_PACKAGE_SHA256"
/usr/bin/unzip -tq "$ARCHIVE_ZIP_PATH" >/dev/null \
  || fail "Archive ZIP failed integrity validation"
ZIP_LISTING="$(/usr/bin/zipinfo -1 "$ARCHIVE_ZIP_PATH")"
[[ "$(print -r -- "$ZIP_LISTING" | /usr/bin/grep -Ec \
    '^AgentIslandMac\.xcarchive/Info\.plist$')" == "1" && \
  "$(print -r -- "$ZIP_LISTING" | /usr/bin/grep -Ec \
    '^AgentIslandMac\.xcarchive/Products/Applications/AgentIslandMac\.app/Contents/Info\.plist$')" == "1" ]] \
  || fail "Archive ZIP does not contain the expected one-archive layout"
if print -r -- "$ZIP_LISTING" | /usr/bin/grep -Eq \
    '(^|/)(\.\.|__MACOSX|\.DS_Store|\._[^/]+)(/|$)|^/|\\|\.(p8|p12|mobileprovision|m|swift|jsonl)$'; then
  fail "Archive ZIP contains an unsafe, source, fixture, credential, or Finder path"
fi

setting_value() {
  local config_file="$1"
  local key="$2"
  /usr/bin/sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" \
    "$config_file" | /usr/bin/tail -n 1
}

resolved_shared_url() {
  local key="$1"
  local value url_slash
  local url_slash_reference='$(AGENT_ISLAND_URL_SLASH)'
  url_slash="$(setting_value "$SHARED_CONFIG_FILE" AGENT_ISLAND_URL_SLASH)"
  [[ "$url_slash" == "/" ]] \
    || fail "shared Project.xcconfig AGENT_ISLAND_URL_SLASH must remain a single slash"
  value="$(setting_value "$SHARED_CONFIG_FILE" "$key")"
  value="${value//$url_slash_reference/$url_slash}"
  [[ -n "$value" && "$value" != *'$('* && "$value" != *'${'* ]] \
    || fail "shared Project.xcconfig $key is empty or unresolved"
  print -r -- "$value"
}

CURRENT_VERSION="$(setting_value "$MAC_CONFIG_FILE" MARKETING_VERSION)"
CURRENT_BUILD="$(setting_value "$MAC_CONFIG_FILE" CURRENT_PROJECT_VERSION)"
CURRENT_DEPLOYMENT_TARGET="$(setting_value "$MAC_CONFIG_FILE" MACOSX_DEPLOYMENT_TARGET)"
CURRENT_TEAM_ID="$(setting_value "$SHARED_CONFIG_FILE" AGENT_ISLAND_DEVELOPMENT_TEAM)"
CURRENT_APP_BUNDLE_ID="$(setting_value "$MAC_CONFIG_FILE" AGENT_ISLAND_MAC_APP_BUNDLE_ID)"
CURRENT_DISPLAY_NAME="$(setting_value "$SHARED_CONFIG_FILE" AGENT_ISLAND_DISPLAY_NAME)"
CURRENT_CLOUD_CONTAINER_ID="$(setting_value "$SHARED_CONFIG_FILE" AGENT_ISLAND_ICLOUD_CONTAINER_ID)"
CURRENT_PRIVACY_POLICY_URL="$(resolved_shared_url AGENT_ISLAND_PRIVACY_POLICY_URL)"
CURRENT_SUPPORT_URL="$(resolved_shared_url AGENT_ISLAND_SUPPORT_URL)"

[[ "$VERSION" == "$CURRENT_VERSION" && "$BUILD_NUMBER" == "$CURRENT_BUILD" ]] \
  || fail "release metadata version/build does not match current macOS Project.xcconfig"
[[ "$TEAM_ID" == "$CURRENT_TEAM_ID" ]] \
  || fail "release metadata Team ID does not match current shared Project.xcconfig"
[[ "$APP_BUNDLE_ID" == "$CURRENT_APP_BUNDLE_ID" ]] \
  || fail "release metadata bundle ID does not match current macOS Project.xcconfig"
[[ "$DISPLAY_NAME" == "$CURRENT_DISPLAY_NAME" && "$DISPLAY_NAME" == "$PUBLIC_APP_NAME" ]] \
  || fail "release metadata display name does not match the current public name"
[[ "$CLOUD_CONTAINER_ID" == "$CURRENT_CLOUD_CONTAINER_ID" ]] \
  || fail "release metadata CloudKit container does not match current shared Project.xcconfig"
[[ "$PRIVACY_POLICY_URL" == "$CURRENT_PRIVACY_POLICY_URL" ]] \
  || fail "release metadata privacy-policy URL does not match current shared Project.xcconfig"
[[ "$SUPPORT_URL" == "$CURRENT_SUPPORT_URL" ]] \
  || fail "release metadata support URL does not match current shared Project.xcconfig"

case "${APP_BUNDLE_ID:l}" in
  local.*|*example*|*placeholder*|*yourname*|*yourdomain*|*.invalid)
    fail "release metadata contains a non-production App bundle ID"
    ;;
esac
case "${CLOUD_CONTAINER_ID:l}" in
  *example*|*placeholder*|*yourname*|*yourdomain*|*.invalid)
    fail "release metadata contains a non-production CloudKit container"
    ;;
esac
[[ "$SIGNING_IDENTITY" == "Apple Distribution: "* || \
  "$SIGNING_IDENTITY" == "Mac App Distribution: "* || \
  "$SIGNING_IDENTITY" == "3rd Party Mac Developer Application: "* ]] \
  || fail "release metadata does not name an App Store distribution identity"
[[ "$INSTALLER_SIGNING_IDENTITY" == "Mac Installer Distribution: "* || \
  "$INSTALLER_SIGNING_IDENTITY" == "3rd Party Mac Developer Installer: "* ]] \
  || fail "release metadata does not name a Mac Installer Distribution identity"
[[ "$SIGNING_IDENTITY" == *" ($TEAM_ID)" && \
  "$INSTALLER_SIGNING_IDENTITY" == *" ($TEAM_ID)" ]] \
  || fail "release metadata signing identities belong to another Team"

WORK_DIRECTORY="$(mktemp -d /private/tmp/agentisland-mac-delivery.XXXXXX)"
PACKAGE_SIGNATURE_INFO="$WORK_DIRECTORY/package-signature.txt"
/usr/sbin/pkgutil --check-signature "$PACKAGE_PATH" >"$PACKAGE_SIGNATURE_INFO" \
  || fail "App Store package signature is invalid or untrusted"
PACKAGE_SIGNING_AUTHORITY="$(/usr/bin/sed -n \
  's/^[[:space:]]*1\. //p' "$PACKAGE_SIGNATURE_INFO" | /usr/bin/head -n 1)"
[[ "$PACKAGE_SIGNING_AUTHORITY" == "$INSTALLER_SIGNING_IDENTITY" ]] \
  || fail "App Store package Installer identity differs from release metadata"

PACKAGE_EXPANDED="$WORK_DIRECTORY/package-expanded"
PACKAGE_PAYLOAD="$WORK_DIRECTORY/package-payload"
/usr/sbin/pkgutil --expand "$PACKAGE_PATH" "$PACKAGE_EXPANDED" \
  || fail "App Store package could not be expanded safely"
if /usr/bin/find "$PACKAGE_EXPANDED" -type d -name Scripts -print -quit \
    | /usr/bin/grep -q .; then
  fail "App Store package unexpectedly contains installer scripts"
fi
payload_archives=("$PACKAGE_EXPANDED"/**/Payload(.N))
(( ${#payload_archives} > 0 )) || fail "App Store package contains no payload archive"
/bin/mkdir -p "$PACKAGE_PAYLOAD"
for payload_archive in "${payload_archives[@]}"; do
  /usr/bin/ditto -x "$payload_archive" "$PACKAGE_PAYLOAD" \
    || fail "App Store package payload could not be extracted safely"
done
packaged_apps=("$PACKAGE_PAYLOAD"/**/AgentIslandMac.app(/N))
(( ${#packaged_apps} == 1 )) \
  || fail "App Store package payload must contain exactly one AgentIslandMac.app"
PACKAGED_APP="${packaged_apps[1]}"

validate_app_info_and_contents() {
  local app_path="$1"
  local label="$2"
  local info="$app_path/Contents/Info.plist"
  local executable_name executable_path normalized_arches privacy_sha
  [[ -d "$app_path" && ! -L "$app_path" ]] || fail "$label is not a regular App bundle"
  assert_no_quarantine_attributes "$app_path" "$label"
  [[ -f "$info" && ! -L "$info" ]] || fail "$label is missing Contents/Info.plist"
  /usr/bin/plutil -lint "$info" >/dev/null || fail "$label has an invalid Info.plist"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null)" == "$APP_BUNDLE_ID" ]] \
    || fail "$label bundle identifier differs from release metadata"
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info" 2>/dev/null)" == "$VERSION" ]] \
    || fail "$label marketing version differs from release metadata"
  [[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$info" 2>/dev/null)" == "$BUILD_NUMBER" ]] \
    || fail "$label build number differs from release metadata"
  [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$info" 2>/dev/null)" == "$DISPLAY_NAME" ]] \
    || fail "$label display name differs from release metadata"
  [[ "$(/usr/bin/plutil -extract CFBundleDevelopmentRegion raw "$info" 2>/dev/null)" == "en" ]] \
    || fail "$label development region must remain en"
  [[ "$(/usr/bin/plutil -extract NSHumanReadableCopyright raw "$info" 2>/dev/null)" == "$COPYRIGHT" ]] \
    || fail "$label copyright differs from release metadata"
  [[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$info" 2>/dev/null)" == "$PRIVACY_POLICY_URL" ]] \
    || fail "$label privacy-policy URL differs from release metadata"
  [[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$info" 2>/dev/null)" == "$SUPPORT_URL" ]] \
    || fail "$label support URL differs from release metadata"
  [[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$info" 2>/dev/null)" == "$CURRENT_DEPLOYMENT_TARGET" ]] \
    || fail "$label minimum macOS version differs from current Project.xcconfig"
  [[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw "$info" 2>/dev/null)" == "$APP_CATEGORY" ]] \
    || fail "$label application category must remain $APP_CATEGORY"
  [[ "$(/usr/bin/plutil -extract LSUIElement raw "$info" 2>/dev/null)" == "true" ]] \
    || fail "$label must remain an LSUIElement menu-bar application"
  [[ "$(/usr/bin/plutil -extract ITSAppUsesNonExemptEncryption raw "$info" 2>/dev/null)" == "false" ]] \
    || fail "$label encryption declaration changed"
  [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "$info" 2>/dev/null)" == "AgentIsland" ]] \
    || fail "$label icon setting changed"
  for permission_key in NSCameraUsageDescription NSMicrophoneUsageDescription \
    NSScreenCaptureUsageDescription NSAppleEventsUsageDescription; do
    if /usr/bin/plutil -extract "$permission_key" raw "$info" >/dev/null 2>&1; then
      fail "$label unexpectedly requests $permission_key"
    fi
  done
  if arbitrary_loads="$(/usr/bin/plutil -extract \
      NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$info" 2>/dev/null)"; then
    [[ "$arbitrary_loads" == "false" ]] || fail "$label enables arbitrary network loads"
  fi
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$info" 2>/dev/null)" \
    || fail "$label has no executable name"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -f "$executable_path" && -x "$executable_path" && ! -L "$executable_path" ]] \
    || fail "$label executable is missing, non-executable, or a symlink"
  normalized_arches="$(/usr/bin/lipo -archs "$executable_path" \
    | /usr/bin/tr ' ' '\n' | LC_ALL=C /usr/bin/sort -u | /usr/bin/paste -sd ' ' -)"
  [[ "$normalized_arches" == "arm64 x86_64" ]] \
    || fail "$label executable must contain exactly arm64 and x86_64"
  [[ -f "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" && \
    -f "$app_path/Contents/Resources/AgentIsland.icns" && \
    -f "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" && \
    -f "$app_path/Contents/Resources/Web/index.html" ]] \
    || fail "$label is missing a required privacy, icon, notice, or Web resource"
  /usr/bin/cmp -s "$SOURCE_PRIVACY_MANIFEST" \
    "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" \
    || fail "$label privacy manifest differs from the reviewed source manifest"
  privacy_sha="$(file_sha256 "$app_path/Contents/Resources/PrivacyInfo.xcprivacy")"
  [[ "$privacy_sha" == "$EXPECTED_PRIVACY_SHA256" ]] \
    || fail "$label privacy manifest SHA-256 differs from release metadata"
  if /usr/bin/find "$app_path" \( -name '.DS_Store' -o -name '._*' -o \
      -name '*.p8' -o -name '*.p12' -o -name '*.mobileprovision' -o \
      -name '*.m' -o -name '*.swift' -o -name '*.jsonl' \) -print -quit \
      | /usr/bin/grep -q .; then
    fail "$label contains source, fixture, credential, or Finder metadata"
  fi
}

validate_signature_and_profile() {
  local app_path="$1"
  local label="$2"
  local key="$3"
  local expected_profile_expiration="$4"
  local verify_archive_profile_metadata="$5"
  local signature_info="$WORK_DIRECTORY/$key-signature.txt"
  local signed_entitlements="$WORK_DIRECTORY/$key-entitlements.plist"
  local signed_entitlements_json="$WORK_DIRECTORY/$key-entitlements.json"
  local profile="$app_path/Contents/embedded.provisionprofile"
  local profile_plist="$WORK_DIRECTORY/$key-profile.plist"
  local profile_entitlements="$WORK_DIRECTORY/$key-profile-entitlements.plist"
  local profile_entitlements_json="$WORK_DIRECTORY/$key-profile-entitlements.json"
  local certificate_directory="$WORK_DIRECTORY/$key-signing-certificate"
  local signing_authority signed_team leaf_sha profile_prefix_count profile_team_count
  local profile_platform_count profile_prefix profile_team profile_platform
  local profile_expiration profile_expiration_epoch profile_cert_count
  local profile_uuid profile_name profile_cert_path profile_cert_base64 profile_cert_sha1
  local profile_certificate_matches=false

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" \
    || fail "$label code signature failed strict verification"
  /usr/bin/codesign -d --verbose=4 "$app_path" >/dev/null 2>"$signature_info" \
    || fail "$label signature metadata could not be read"
  signing_authority="$(/usr/bin/sed -n 's/^Authority=//p' "$signature_info" \
    | /usr/bin/head -n 1)"
  signed_team="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$signature_info" \
    | /usr/bin/head -n 1)"
  [[ "$signing_authority" == "$SIGNING_IDENTITY" && "$signed_team" == "$TEAM_ID" ]] \
    || fail "$label signing identity or Team differs from release metadata"
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$signature_info" \
    || fail "$label signature is missing Hardened Runtime"

  /bin/mkdir -p "$certificate_directory"
  (cd "$certificate_directory" && \
    /usr/bin/codesign --display --extract-certificates "$app_path" >/dev/null 2>&1) \
    || fail "$label signing certificate could not be extracted"
  [[ -f "$certificate_directory/codesign0" ]] \
    || fail "$label code signature has no leaf certificate"
  leaf_sha="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 \
    "$certificate_directory/codesign0" | /usr/bin/awk '{print toupper($1)}')"
  [[ "$leaf_sha" == "$SIGNING_CERTIFICATE_SHA1" ]] \
    || fail "$label leaf signing certificate differs from release metadata"

  /usr/bin/codesign -d --entitlements - "$app_path" \
    >"$signed_entitlements" 2>/dev/null \
    || fail "$label signed entitlements could not be read"
  /usr/bin/plutil -convert json -o "$signed_entitlements_json" "$signed_entitlements" \
    || fail "$label signed entitlements are not a valid plist"
  [[ -f "$profile" && ! -L "$profile" ]] \
    || fail "$label is missing Contents/embedded.provisionprofile"
  agent_island_decode_apple_signed_profile "$profile" "$profile_plist" \
    || fail "$label provisioning profile failed Apple CMS signer verification"
  /usr/bin/plutil -extract Entitlements xml1 -o "$profile_entitlements" "$profile_plist" \
    || fail "$label provisioning profile has no Entitlements dictionary"
  /usr/bin/plutil -convert json -o "$profile_entitlements_json" "$profile_entitlements" \
    || fail "$label provisioning-profile entitlements are invalid"
  if /usr/bin/plutil -type ProvisionedDevices "$profile_plist" >/dev/null 2>&1; then
    fail "$label provisioning profile is device-scoped, not a Mac App Store profile"
  fi
  if [[ "$(/usr/bin/plutil -extract ProvisionsAllDevices raw "$profile_plist" \
      2>/dev/null || true)" == "true" ]]; then
    fail "$label provisioning profile is an all-device Developer ID profile"
  fi

  profile_prefix_count="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_team_count="$(/usr/bin/plutil -extract TeamIdentifier raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_platform_count="$(/usr/bin/plutil -extract Platform raw \
    "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_prefix_count" == "1" && "$profile_team_count" == "1" && \
    "$profile_platform_count" == "1" ]] \
    || fail "$label profile must contain one App ID prefix, TeamIdentifier, and platform"
  profile_prefix="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix.0 raw "$profile_plist")"
  profile_team="$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$profile_plist")"
  profile_platform="$(/usr/bin/plutil -extract Platform.0 raw "$profile_plist")"
  [[ "$profile_team" == "$TEAM_ID" && "$profile_platform" == "OSX" ]] \
    || fail "$label profile belongs to another Team or platform"

  profile_expiration="$(/usr/bin/plutil -extract ExpirationDate raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_expiration_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$profile_expiration" '+%s' 2>/dev/null || true)"
  [[ "$profile_expiration_epoch" == <-> ]] \
    || fail "$label profile has an unreadable ExpirationDate"
  (( profile_expiration_epoch > $(/bin/date -u '+%s') )) \
    || fail "$label provisioning profile expired at $profile_expiration"
  [[ "$profile_expiration" == "$expected_profile_expiration" ]] \
    || fail "$label profile expiration differs from release metadata"
  profile_uuid="$(/usr/bin/plutil -extract UUID raw "$profile_plist" 2>/dev/null || true)"
  profile_name="$(/usr/bin/plutil -extract Name raw "$profile_plist" 2>/dev/null || true)"
  if [[ "$verify_archive_profile_metadata" == true ]]; then
    [[ "$profile_uuid" == "$PROFILE_UUID" && "$profile_name" == "$PROFILE_NAME" ]] \
      || fail "$label profile UUID or name differs from release metadata"
  fi

  profile_cert_count="$(/usr/bin/plutil -extract DeveloperCertificates raw \
    "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_cert_count" == <-> && "$profile_cert_count" -gt 0 ]] \
    || fail "$label profile contains no distribution certificate"
  for (( profile_cert_index = 0; profile_cert_index < profile_cert_count; profile_cert_index++ )); do
    profile_cert_path="$WORK_DIRECTORY/$key-profile-certificate-$profile_cert_index.cer"
    profile_cert_base64="$(/usr/bin/plutil -extract \
      "DeveloperCertificates.$profile_cert_index" raw "$profile_plist")"
    print -rn -- "$profile_cert_base64" | /usr/bin/base64 -D >"$profile_cert_path" \
      || fail "$label profile contains an unreadable distribution certificate"
    profile_cert_sha1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 \
      "$profile_cert_path" | /usr/bin/awk '{print toupper($1)}')"
    if [[ "$profile_cert_sha1" == "$leaf_sha" ]]; then
      profile_certificate_matches=true
      break
    fi
  done
  [[ "$profile_certificate_matches" == true ]] \
    || fail "$label profile does not authorize the actual signing certificate"

  /usr/bin/jq -e \
    --arg applicationIdentifier "$APPLICATION_IDENTIFIER" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER_ID" \
    -f "$CLOUDKIT_PROFILE_AUTHORIZATION" \
    "$profile_entitlements_json" >/dev/null \
    || fail "$label profile does not authorize the exact App ID, Team, and production CloudKit capability"

  /usr/bin/jq -e -s \
    --arg applicationIdentifier "$APPLICATION_IDENTIFIER" \
    --arg expectedIdentifier "$profile_prefix.$APP_BUNDLE_ID" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER_ID" '
      def app_identifier:
        .["com.apple.application-identifier"] // .["application-identifier"];
      def approved_signed_entitlement_key:
        . == "application-identifier" or
        . == "beta-reports-active" or
        . == "com.apple.application-identifier" or
        . == "com.apple.developer.icloud-container-environment" or
        . == "com.apple.developer.icloud-container-identifiers" or
        . == "com.apple.developer.icloud-services" or
        . == "com.apple.developer.team-identifier" or
        . == "com.apple.security.app-sandbox" or
        . == "com.apple.security.files.bookmarks.app-scope" or
        . == "com.apple.security.files.user-selected.read-only" or
        . == "com.apple.security.get-task-allow" or
        . == "com.apple.security.network.client" or
        . == "get-task-allow";
      .[0] as $signed | .[1] as $profile |
      ([$signed | keys[] | select(approved_signed_entitlement_key | not)]
        | length) == 0 and
      $applicationIdentifier == $expectedIdentifier and
      ($signed | app_identifier) == $applicationIdentifier and
      (($signed."com.apple.application-identifier" //
        $applicationIdentifier) == $applicationIdentifier) and
      (($signed."application-identifier" //
        $applicationIdentifier) == $applicationIdentifier) and
      ($profile | app_identifier) == $applicationIdentifier and
      $signed."com.apple.developer.team-identifier" == $team and
      $profile."com.apple.developer.team-identifier" == $team and
      (($signed."com.apple.security.get-task-allow" // false) == false) and
      (($signed."get-task-allow" // false) == false) and
      (($signed."beta-reports-active" // true) == true) and
      (($profile."com.apple.security.get-task-allow" //
        $profile."get-task-allow" // false) == false) and
      $signed."com.apple.security.app-sandbox" == true and
      $signed."com.apple.security.files.user-selected.read-only" == true and
      $signed."com.apple.security.files.bookmarks.app-scope" == true and
      $signed."com.apple.security.network.client" == true and
      $signed."com.apple.developer.icloud-container-identifiers" == [$container] and
      $signed."com.apple.developer.icloud-services" == ["CloudKit"] and
      $signed."com.apple.developer.icloud-container-environment" == "Production"
    ' "$signed_entitlements_json" "$profile_entitlements_json" >/dev/null \
    || fail "$label signature/profile failed exact sandbox, identity, Team, or Production CloudKit validation"
}

ARCHIVE_INFO="$ARCHIVE_PATH/Info.plist"
[[ -f "$ARCHIVE_INFO" && ! -L "$ARCHIVE_INFO" ]] \
  || fail "Archive is missing Info.plist"
/usr/bin/plutil -lint "$ARCHIVE_INFO" >/dev/null || fail "Archive Info.plist is invalid"
[[ "$(/usr/bin/plutil -extract ApplicationProperties.CFBundleIdentifier raw \
    "$ARCHIVE_INFO" 2>/dev/null)" == "$APP_BUNDLE_ID" ]] \
  || fail "Archive metadata bundle identifier differs from release metadata"
[[ "$(/usr/bin/plutil -extract ApplicationProperties.ApplicationPath raw \
    "$ARCHIVE_INFO" 2>/dev/null)" == "Applications/AgentIslandMac.app" ]] \
  || fail "Archive metadata has an unexpected application path"
archive_apps=("$ARCHIVE_PATH/Products/Applications"/*.app(/N))
(( ${#archive_apps} == 1 )) || fail "Archive must contain exactly one application"
ARCHIVED_APP="${archive_apps[1]}"
[[ "${ARCHIVED_APP:t}" == "AgentIslandMac.app" ]] \
  || fail "Archive contains an unexpected application product"

ARCHIVE_ZIP_EXPANDED="$WORK_DIRECTORY/archive-zip"
/bin/mkdir -p "$ARCHIVE_ZIP_EXPANDED"
/usr/bin/ditto -x -k "$ARCHIVE_ZIP_PATH" "$ARCHIVE_ZIP_EXPANDED" \
  || fail "Archive ZIP could not be extracted safely"
ZIPPED_ARCHIVE="$ARCHIVE_ZIP_EXPANDED/AgentIslandMac.xcarchive"
[[ -d "$ZIPPED_ARCHIVE" && ! -L "$ZIPPED_ARCHIVE" ]] \
  || fail "Archive ZIP did not extract the expected Archive"
ARCHIVE_DIFF="$WORK_DIRECTORY/archive-zip-diff.txt"
if ! /usr/bin/diff -qr "$ARCHIVE_PATH" "$ZIPPED_ARCHIVE" >"$ARCHIVE_DIFF"; then
  fail "current Archive differs from the SHA-256-bound Archive ZIP"
fi

validate_app_info_and_contents "$ARCHIVED_APP" "archived App"
validate_signature_and_profile "$ARCHIVED_APP" "archived App" \
  "archive-app" "$PROFILE_EXPIRATION" true
validate_app_info_and_contents "$PACKAGED_APP" "packaged App"
validate_signature_and_profile "$PACKAGED_APP" "packaged App" \
  "package-app" "$EXPORTED_PROFILE_EXPIRATION" false

stable_app_manifest() {
  local app_path="$1"
  local output_path="$2"
  local executable_name executable_path file_path relative_path
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw \
    "$app_path/Contents/Info.plist")"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  if /usr/bin/find "$app_path" -type l -print -quit | /usr/bin/grep -q .; then
    fail "candidate App contains a symlink that cannot be compared safely"
  fi
  while IFS= read -r file_path; do
    relative_path="${file_path#$app_path/}"
    case "$relative_path" in
      Contents/_CodeSignature/*|Contents/embedded.provisionprofile|Contents/MacOS/$executable_name)
        continue
        ;;
    esac
    print -r -- "$(file_sha256 "$file_path")  $relative_path"
  done < <(/usr/bin/find "$app_path/Contents" -type f -print | LC_ALL=C /usr/bin/sort) \
    >"$output_path"
  print -r -- "$executable_path"
}

ARCHIVE_STABLE_MANIFEST="$WORK_DIRECTORY/archive-stable-manifest.txt"
PACKAGE_STABLE_MANIFEST="$WORK_DIRECTORY/package-stable-manifest.txt"
ARCHIVE_EXECUTABLE="$(stable_app_manifest "$ARCHIVED_APP" "$ARCHIVE_STABLE_MANIFEST")"
PACKAGE_EXECUTABLE="$(stable_app_manifest "$PACKAGED_APP" "$PACKAGE_STABLE_MANIFEST")"
/usr/bin/cmp -s "$ARCHIVE_STABLE_MANIFEST" "$PACKAGE_STABLE_MANIFEST" \
  || fail "Archive and package App contents differ outside signing artifacts"
ARCHIVE_UNSIGNED_EXECUTABLE="$WORK_DIRECTORY/archive-unsigned-executable"
PACKAGE_UNSIGNED_EXECUTABLE="$WORK_DIRECTORY/package-unsigned-executable"
/bin/cp "$ARCHIVE_EXECUTABLE" "$ARCHIVE_UNSIGNED_EXECUTABLE"
/bin/cp "$PACKAGE_EXECUTABLE" "$PACKAGE_UNSIGNED_EXECUTABLE"
/usr/bin/codesign --remove-signature "$ARCHIVE_UNSIGNED_EXECUTABLE" >/dev/null 2>&1 \
  || fail "archived App executable signature could not be removed for comparison"
/usr/bin/codesign --remove-signature "$PACKAGE_UNSIGNED_EXECUTABLE" >/dev/null 2>&1 \
  || fail "packaged App executable signature could not be removed for comparison"
[[ "$(file_sha256 "$ARCHIVE_UNSIGNED_EXECUTABLE")" == \
  "$(file_sha256 "$PACKAGE_UNSIGNED_EXECUTABLE")" ]] \
  || fail "Archive and package contain different executable code"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$EXPECTED_PACKAGE_SHA256"
print -r -- "Local Mac App Store package preflight passed."
print -r -- "Package: $PACKAGE_PATH"
print -r -- "Bundle: $APP_BUNDLE_ID"
print -r -- "Version/build: $VERSION ($BUILD_NUMBER)"
print -r -- "PKG SHA-256: $EXPECTED_PACKAGE_SHA256"
print -r -- "Upload confirmation: $CONFIRMATION_VALUE"

[[ "$MODE" != "check" ]] || exit 0
verify_core_candidate_unchanged
if [[ "$MODE" == "upload" ]]; then
  [[ "${AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD:-}" == "$CONFIRMATION_VALUE" ]] \
    || fail "AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD does not match this exact package"
fi

DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] \
  || fail "select full Xcode 14 or newer before contacting App Store Connect"
[[ -d "$DEVELOPER_PATH/Platforms/MacOSX.platform" ]] \
  || fail "the selected Xcode does not include the macOS platform"
XCODE_VERSION="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild -version \
  | /usr/bin/awk '/^Xcode / {print $2; exit}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
[[ "$XCODE_MAJOR" == <-> ]] || fail "could not determine the selected Xcode version"
(( XCODE_MAJOR >= MINIMUM_XCODE_MAJOR )) \
  || fail "Xcode 14 or newer is required for Mac App Store delivery"
[[ -n "$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun --find altool \
  2>/dev/null || true)" ]] || fail "the selected Xcode does not provide altool"

if [[ "$MODE" == "upload" ]]; then
  UPLOAD_READINESS_REPORT="$WORK_DIRECTORY/upload-release-readiness.json"
  [[ -x "$PREFLIGHT_ASSERTION" && -x "$READINESS_SCRIPT" ]] \
    || fail "release upload readiness gate is missing or not executable"
  if ! AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$METADATA_PATH" \
      DEVELOPER_DIR="$DEVELOPER_PATH" \
      "$READINESS_SCRIPT" --json >"$UPLOAD_READINESS_REPORT"; then
    fail "could not generate the Mac App Store upload-readiness report"
  fi
  if ! /bin/zsh "$PREFLIGHT_ASSERTION" mac-app-store-upload \
      "$UPLOAD_READINESS_REPORT"; then
    fail "Mac App Store upload prerequisites are not satisfied"
  fi
fi

assert_upload_identity_lock_unchanged() {
  [[ "$MODE" == "upload" ]] || return 0
  /bin/zsh "$PREFLIGHT_ASSERTION" mac-app-store-upload \
    "$UPLOAD_READINESS_REPORT" \
    || fail "Mac App Store upload identity lock no longer matches the readiness snapshot"
}

API_KEY_ID="${AGENT_ISLAND_ASC_API_KEY_ID:-}"
API_ISSUER_ID="${AGENT_ISLAND_ASC_API_ISSUER_ID:-}"
print -r -- "$API_KEY_ID" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$' \
  || fail "AGENT_ISLAND_ASC_API_KEY_ID must be a 10-character uppercase key ID"
print -r -- "$API_ISSUER_ID" | /usr/bin/grep -Eq \
  '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
  || fail "AGENT_ISLAND_ASC_API_ISSUER_ID must be the App Store Connect issuer UUID"
[[ -n "${HOME:-}" ]] || fail "HOME is unavailable for locating the App Store Connect key"
PRIVATE_KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
[[ -f "$PRIVATE_KEY_PATH" && ! -L "$PRIVATE_KEY_PATH" ]] \
  || fail "App Store Connect private key is missing from ~/.appstoreconnect/private_keys"
PRIVATE_KEY_MODE="$(/usr/bin/stat -f '%Lp' "$PRIVATE_KEY_PATH")"
[[ "$PRIVATE_KEY_MODE" == <-> ]] || fail "could not inspect private-key permissions"
(( (8#$PRIVATE_KEY_MODE & 8#077) == 0 )) \
  || fail "App Store Connect private key must not be readable by group or other users"
[[ -w "$RELEASE_DIRECTORY" ]] \
  || fail "release directory must be writable before recording App Store Connect results"
REMOTE_LOCK_DIRECTORY="$RELEASE_DIRECTORY/.mac-app-store-submit.lock"
if ! /bin/mkdir "$REMOTE_LOCK_DIRECTORY" 2>/dev/null; then
  fail "another Mac App Store validation or upload is already active for this release directory"
fi
REMOTE_LOCK_HELD=true
REMOTE_LOCK_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$REMOTE_LOCK_DIRECTORY")"
[[ "$REMOTE_LOCK_IDENTITY" == <->:<-> ]] \
  || fail "could not identify the Mac App Store release-directory lock"
/bin/chmod 0700 "$REMOTE_LOCK_DIRECTORY" \
  || fail "could not secure the Mac App Store release-directory lock"

# Validate and upload a private byte-for-byte snapshot rather than reopening the
# mutable release path during either remote operation. Both altool calls consume
# this same inode; the public candidate and snapshot are re-hashed around each
# remote call before any evidence is published.
REMOTE_PACKAGE_PATH="$WORK_DIRECTORY/AgentIslandMac-upload.pkg"
/bin/cp "$PACKAGE_PATH" "$REMOTE_PACKAGE_PATH" \
  || fail "could not create a private App Store package snapshot"
[[ -f "$REMOTE_PACKAGE_PATH" && ! -L "$REMOTE_PACKAGE_PATH" ]] \
  || fail "private App Store package snapshot is missing or unsafe"
[[ "$(file_sha256 "$REMOTE_PACKAGE_PATH")" == "$EXPECTED_PACKAGE_SHA256" ]] \
  || fail "private App Store package snapshot differs from the verified candidate"
/bin/chmod 0400 "$REMOTE_PACKAGE_PATH" \
  || fail "could not make the private App Store package snapshot read-only"
verify_remote_package_unchanged() {
  [[ "$(file_sha256 "$REMOTE_PACKAGE_PATH")" == "$EXPECTED_PACKAGE_SHA256" ]] \
    || fail "private App Store package snapshot changed during delivery"
  assert_no_quarantine_attributes "$REMOTE_PACKAGE_PATH" \
    "private App Store package snapshot"
}
verify_remote_package_unchanged

publish_read_only() {
  local temporary_path="$1"
  local destination_path="$2"
  local temporary_identity misplaced_path
  [[ -f "$temporary_path" && ! -L "$temporary_path" ]] \
    || fail "temporary delivery evidence is missing or unsafe"
  [[ ! -e "$destination_path" && ! -L "$destination_path" ]] \
    || fail "refusing to overwrite existing delivery evidence: ${destination_path:t}"
  temporary_identity="$(/usr/bin/stat -f '%d:%i' "$temporary_path")" \
    || fail "could not identify temporary delivery evidence"
  /bin/chmod 0444 "$temporary_path" \
    || fail "could not make temporary delivery evidence read-only"
  /bin/ln -h "$temporary_path" "$destination_path" \
    || fail "could not publish delivery evidence without overwriting a file"
  if [[ ! -f "$destination_path" || -L "$destination_path" || \
      "$(/usr/bin/stat -f '%d:%i' "$destination_path" 2>/dev/null || true)" != \
        "$temporary_identity" ]]; then
    misplaced_path="$destination_path/${temporary_path:t}"
    if [[ -f "$misplaced_path" && ! -L "$misplaced_path" && \
        "$(/usr/bin/stat -f '%d:%i' "$misplaced_path")" == \
          "$temporary_identity" ]]; then
      /bin/rm -f "$misplaced_path" \
        || fail "could not remove misplaced delivery evidence after a destination-directory race"
    fi
    fail "published delivery evidence does not match the sealed temporary inode"
  fi
  /bin/rm -f "$temporary_path" \
    || fail "could not remove the temporary delivery evidence name"
}

STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
VALIDATION_RESULT="$RELEASE_DIRECTORY/mac-app-store-validation-$STAMP.json"
[[ ! -e "$VALIDATION_RESULT" && ! -L "$VALIDATION_RESULT" ]] \
  || fail "refusing to overwrite existing delivery evidence: ${VALIDATION_RESULT:t}"
if [[ "$MODE" == "upload" ]]; then
  UPLOAD_RESULT="$RELEASE_DIRECTORY/mac-app-store-upload-$STAMP.json"
  DELIVERY_RECORD="$RELEASE_DIRECTORY/mac-app-store-delivery-$STAMP.json"
  [[ ! -e "$UPLOAD_RESULT" && ! -L "$UPLOAD_RESULT" && \
    ! -e "$DELIVERY_RECORD" && ! -L "$DELIVERY_RECORD" ]] \
    || fail "refusing to overwrite an existing upload result or delivery record"
fi
VALIDATION_TEMP="$(mktemp "$RELEASE_DIRECTORY/.mac-app-store-validation.XXXXXX")"
assert_upload_identity_lock_unchanged
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun altool \
  --validate-app \
  --file "$REMOTE_PACKAGE_PATH" \
  --type macos \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID" \
  --output-format json >"$VALIDATION_TEMP"
[[ -s "$VALIDATION_TEMP" ]] || fail "App Store Connect returned no validation result"
verify_altool_success_json "$VALIDATION_TEMP" "validation"
verify_remote_package_unchanged
verify_core_candidate_unchanged
publish_read_only "$VALIDATION_TEMP" "$VALIDATION_RESULT"
VALIDATION_TEMP=""
VALIDATION_RESULT_SHA256="$(file_sha256 "$VALIDATION_RESULT")"
print -r -- "App Store Connect validation passed: $VALIDATION_RESULT"

[[ "$MODE" == "upload" ]] || exit 0
verify_core_candidate_unchanged
UPLOAD_TEMP="$(mktemp "$RELEASE_DIRECTORY/.mac-app-store-upload.XXXXXX")"
assert_upload_identity_lock_unchanged
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun altool \
  --upload-app \
  --file "$REMOTE_PACKAGE_PATH" \
  --type macos \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID" \
  --output-format json >"$UPLOAD_TEMP"
[[ -s "$UPLOAD_TEMP" ]] || fail "App Store Connect returned no upload result"
verify_altool_success_json "$UPLOAD_TEMP" "upload"
verify_remote_package_unchanged
verify_core_candidate_unchanged
publish_read_only "$UPLOAD_TEMP" "$UPLOAD_RESULT"
UPLOAD_TEMP=""
UPLOAD_RESULT_SHA256="$(file_sha256 "$UPLOAD_RESULT")"
verify_core_candidate_unchanged
METADATA_SHA256="$EXPECTED_METADATA_SHA256"

DELIVERY_TEMP="$(mktemp "$RELEASE_DIRECTORY/.mac-app-store-delivery.XXXXXX")"
/usr/bin/jq -n \
  --arg submittedAt "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archiveZipPath "$ARCHIVE_ZIP_PATH" \
  --arg archiveZipSHA256 "$EXPECTED_ARCHIVE_SHA256" \
  --arg packagePath "$PACKAGE_PATH" \
  --arg packageSHA256 "$EXPECTED_PACKAGE_SHA256" \
  --arg releaseMetadataPath "$METADATA_PATH" \
  --arg releaseMetadataSHA256 "$METADATA_SHA256" \
  --arg validationResultPath "$VALIDATION_RESULT" \
  --arg validationResultSHA256 "$VALIDATION_RESULT_SHA256" \
  --arg uploadResultPath "$UPLOAD_RESULT" \
  --arg uploadResultSHA256 "$UPLOAD_RESULT_SHA256" '{
    schemaVersion: 1,
    platform: "macOS",
    destination: "App Store Connect / Mac App Store",
    submittedAt: $submittedAt,
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    archiveZipPath: $archiveZipPath,
    archiveZipSHA256: $archiveZipSHA256,
    packagePath: $packagePath,
    packageSHA256: $packageSHA256,
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
    warningsReviewed: false,
    warningsReviewedAt: null,
    submittedForAppReview: false
  }' >"$DELIVERY_TEMP"
/usr/bin/jq -e '
  .schemaVersion == 1 and .platform == "macOS" and
  .destination == "App Store Connect / Mac App Store" and
  .uploadAccepted == true and .processingState == null and
  .appStoreConnectBuildID == null and .processingVerified == false and
  .processingVerifiedAt == null and .warningsReviewed == false and
  .warningsReviewedAt == null and .submittedForAppReview == false
' "$DELIVERY_TEMP" >/dev/null \
  || fail "generated delivery record failed its pre-processing schema contract"
publish_read_only "$DELIVERY_TEMP" "$DELIVERY_RECORD"
DELIVERY_TEMP=""

print -r -- "Upload accepted by altool: $UPLOAD_RESULT"
print -r -- "Delivery record: $DELIVERY_RECORD"
print -r -- "Upload acceptance is not processing completion. Wait for Complete, inspect every warning, then record post-processing evidence."
