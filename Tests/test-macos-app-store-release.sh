#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SCRIPT="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/release-macos-app-store.sh"
READINESS="$PROJECT_ROOT/scripts/release-readiness.sh"
MAC_INFO="$PROJECT_ROOT/ApplePlatforms/macOS/Config/Mac-Info.plist"
MAC_VALIDATOR="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/validate-project.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-mac-store-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

fail() {
  print -u2 -r -- "macOS App Store release-script test failed: $*"
  exit 1
}

contains() {
  local marker="$1"
  local path="$2"
  /usr/bin/grep -Fq -- "$marker" "$path" \
    || fail "missing contract marker '$marker' in ${path#$PROJECT_ROOT/}"
}

[[ -x "$SCRIPT" ]] || fail "release script is missing or not executable"
/bin/zsh -n "$SCRIPT"
/bin/zsh -n "$READINESS"

HELP_OUTPUT="$TEST_ROOT/help.txt"
"$SCRIPT" --help >"$HELP_OUTPUT"
for marker in '--export' '--allow-provisioning-updates' \
  'The script never uploads, notarizes, or submits a build' \
  'AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT' \
  'AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY' \
  'AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY'; do
  contains "$marker" "$HELP_OUTPUT"
done

UNKNOWN_OUTPUT="$TEST_ROOT/unknown.txt"
if "$SCRIPT" --definitely-unknown >"$UNKNOWN_OUTPUT" 2>&1; then
  fail "unknown command-line option was accepted"
fi
contains 'unknown option: --definitely-unknown' "$UNKNOWN_OUTPUT"

PREFLIGHT_OUTPUT="$TEST_ROOT/preflight.txt"
if DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT='© 2026 Release Test' \
    "$SCRIPT" >"$PREFLIGHT_OUTPUT" 2>&1; then
  fail "Command Line Tools were accepted as full Xcode"
fi
contains 'select full Xcode 14 or newer' "$PREFLIGHT_OUTPUT"

for marker in \
  'MINIMUM_XCODE_MAJOR=14' \
  'Xcode 14 or newer is required for this Mac App Store candidate' \
  '"$PREFLIGHT_ASSERTION" mac-app-store "$READINESS_REPORT"' \
  '"$READINESS_SCRIPT" --json >"$READINESS_REPORT"' \
  'assert_archive_identity_lock_unchanged' \
  'assert_no_quarantine_attributes "$app_path" "$label"' \
  'assert_no_quarantine_attributes "$EXPORTED_PACKAGE" "exported App Store package"' \
  'quarantineFree: true' \
  'destination -string export' \
  'XCODE_MAJOR == 14' \
  'EXPORT_METHOD="app-store"' \
  'EXPORT_METHOD="app-store-connect"' \
  'method -string "$EXPORT_METHOD"' \
  'manageAppVersionAndBuildNumber -bool false' \
  'schemaVersion: 1' \
  'version: $version' \
  'build: $build' \
  'APP_CATEGORY="public.app-category.developer-tools"' \
  'AGENT_ISLAND_MAC_APP_BUNDLE_ID="$APP_BUNDLE_ID"' \
  'LSApplicationCategoryType raw "$info"' \
  'applicationCategory: $applicationCategory' \
  '.applicationCategory == "public.app-category.developer-tools"' \
  'uploaded: false' \
  'No build was uploaded' \
  'ProvisionsAllDevices' \
  'ProvisionedDevices' \
  'DeveloperCertificates' \
  'profileCertificateMatches: true' \
  'com.apple.security.app-sandbox' \
  'com.apple.security.files.user-selected.read-only' \
  'com.apple.security.files.bookmarks.app-scope' \
  'com.apple.security.network.client' \
  'com.apple.developer.icloud-container-identifiers' \
  'com.apple.developer.icloud-container-environment' \
  'com.apple.security.get-task-allow' \
  'approved_signed_entitlement_key' \
  'pkgutil --check-signature' \
  'pkgutil --expand' \
  'shasum -a 256' \
  'COPYFILE_DISABLE=1' \
  'xcarchive ZIP failed integrity validation' \
  'mktemp -d "$DIST_ROOT/.agentisland-mac-store.XXXXXX"' \
  'PUBLISH_LOCK="$DIST_ROOT/.agentisland-mac-store-$RELEASE_BASENAME.publish-lock"' \
  'another Mac App Store release is publishing' \
  '"$(/usr/bin/stat -f '\''%d:%i'\'' "$FINAL_RELEASE_DIR")" ==' \
  'published Mac App Store metadata changed during commit' \
  '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"'; do
  contains "$marker" "$SCRIPT"
done
if /usr/bin/grep -Fq 'the macOS 26 SDK or newer is required' "$SCRIPT"; then
  fail "macOS release still incorrectly requires the macOS 26 SDK"
fi

for marker in \
  '.version == $version and .build == $build' \
  'AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE' \
  'AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE' \
  'AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE' \
  'MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED' \
  'MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY' \
  'MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE' \
  'readyForMacAppStoreUpload' \
  'readyForMacAppStoreReviewSelection' \
  'readyForFunctionalMacAppStoreSubmissionDeprecated: true' \
  'READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=false'; do
  contains "$marker" "$READINESS"
done
contains 'MINIMUM_MAC_APP_STORE_XCODE_MAJOR=14' "$READINESS"
contains 'XCODE_MAJOR >= MINIMUM_MAC_APP_STORE_XCODE_MAJOR' "$READINESS"
contains '.objectVersion == "56"' "$MAC_VALIDATOR"
contains '.compatibilityVersion == "Xcode 14.0"' "$MAC_VALIDATOR"
if /usr/bin/grep -Eq 'READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=true' "$READINESS"; then
  fail "local uploaded:false metadata can still claim macOS review-submission readiness"
fi

/usr/bin/env \
  -u AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256 \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256 \
  -u AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED \
  "$READINESS" --json | /usr/bin/jq -e '
    .macMarketingVersion == "0.6.1" and
    .macBuildNumber == "8" and
    .macAppStoreLocalPreflightPassed == false and
    .macAppStoreFunctionalQAEvidenceReady == false and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreDeliveryEvidenceReady == false and
    .macAppStoreUploadAccepted == false and
    .macAppStoreProcessingEvidenceReady == false and
    .macAppStoreProcessingVerified == false and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreUpload == false and
    .readyForMacAppStoreReviewSelection == false and
    .readyForFunctionalMacAppStoreSubmissionDeprecated == true and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null || fail "default macOS readiness contract is unsafe"

if /usr/bin/grep -Eq -- '(^|[[:space:]])(-upload|--upload)([[:space:]]|$)|notarytool|altool|iTMSTransporter|Transporter\.app' \
    "$SCRIPT"; then
  fail "release script contains an upload, notarization, or submission command"
fi

ARCHIVE_LINE="$(/usr/bin/grep -nF 'ARCHIVE_ARGS=(' "$SCRIPT" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
EXPORT_LINE="$(/usr/bin/grep -nF 'EXPORT_ARGS=(' "$SCRIPT" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
METADATA_LINE="$(/usr/bin/grep -nF '/usr/bin/jq -n \' "$SCRIPT" \
  | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1)"
PUBLISH_LINE="$(/usr/bin/grep -nF '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"' \
  "$SCRIPT" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
READINESS_CALL_LINES=("${(@f)$(/usr/bin/grep -nF \
  'assert_archive_identity_lock_unchanged' "$SCRIPT" | /usr/bin/cut -d: -f1)}")
[[ "$ARCHIVE_LINE" == <-> && "$EXPORT_LINE" == <-> && \
  "$METADATA_LINE" == <-> && "$PUBLISH_LINE" == <-> && \
  "$ARCHIVE_LINE" -lt "$EXPORT_LINE" && "$EXPORT_LINE" -lt "$METADATA_LINE" && \
  "$METADATA_LINE" -lt "$PUBLISH_LINE" ]] \
  || fail "staged archive/export/metadata must complete before publication"
(( ${#READINESS_CALL_LINES} == 4 )) \
  || fail "archive readiness must be defined once and checked at three action boundaries"
[[ "${READINESS_CALL_LINES[2]}" -gt "$ARCHIVE_LINE" && \
  "${READINESS_CALL_LINES[2]}" -lt "$EXPORT_LINE" && \
  "${READINESS_CALL_LINES[3]}" -gt "$EXPORT_LINE" && \
  "${READINESS_CALL_LINES[3]}" -lt "$METADATA_LINE" && \
  "${READINESS_CALL_LINES[4]}" -gt "$METADATA_LINE" && \
  "${READINESS_CALL_LINES[4]}" -lt "$PUBLISH_LINE" ]] \
  || fail "archive readiness is not rechecked before archive, export, and publication"

PUBLISH_LOCK_LINE="$(/usr/bin/grep -nF \
  'PUBLISH_LOCK="$DIST_ROOT/.agentisland-mac-store-$RELEASE_BASENAME.publish-lock"' \
  "$SCRIPT" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
STAGING_LINE="$(/usr/bin/grep -nF \
  'STAGING_ROOT="$(mktemp -d "$DIST_ROOT/.agentisland-mac-store.XXXXXX")"' \
  "$SCRIPT" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
POST_RENAME_LINE="$(/usr/bin/grep -nF \
  '"$(/usr/bin/stat -f '\''%d:%i'\'' "$FINAL_RELEASE_DIR")" ==' \
  "$SCRIPT" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$PUBLISH_LOCK_LINE" == <-> && "$STAGING_LINE" == <-> && \
  "$POST_RENAME_LINE" == <-> && "$PUBLISH_LOCK_LINE" -lt "$STAGING_LINE" && \
  "$STAGING_LINE" -lt "$PUBLISH_LINE" && "$PUBLISH_LINE" -lt "$POST_RENAME_LINE" ]] \
  || fail "publish lock and post-rename inode validation do not surround publication"

RELEASE_FUNCTIONS="$TEST_ROOT/release-functions.zsh"
/usr/bin/sed -n '/^cleanup() {$/,/^}$/p' "$SCRIPT" >"$RELEASE_FUNCTIONS"
/usr/bin/sed -n '/^assert_archive_identity_lock_unchanged() {$/,/^}$/p' \
  "$SCRIPT" >>"$RELEASE_FUNCTIONS"
contains 'cleanup() {' "$RELEASE_FUNCTIONS"
contains 'assert_archive_identity_lock_unchanged() {' "$RELEASE_FUNCTIONS"

FAIL_PREFLIGHT="$TEST_ROOT/fail-preflight.zsh"
print -r -- '#!/bin/zsh
exit 2' >"$FAIL_PREFLIGHT"
/bin/chmod 0755 "$FAIL_PREFLIGHT"
READINESS_FIXTURE="$TEST_ROOT/readiness.json"
print -r -- '{}' >"$READINESS_FIXTURE"

CLEANUP_DIST="$TEST_ROOT/action-failure-cleanup"
/bin/mkdir -p "$CLEANUP_DIST"
if /bin/zsh -c '
  set -euo pipefail
  source "$1"
  fail() { exit 2; }
  DIST_ROOT="$2"
  WORK_ROOT=""
  STAGING_ROOT="$DIST_ROOT/.agentisland-mac-store.failure"
  /bin/mkdir "$STAGING_ROOT"
  STAGING_IDENTITY="$(/usr/bin/stat -f '\''%d:%i'\'' "$STAGING_ROOT")"
  PUBLISH_LOCK="$DIST_ROOT/.agentisland-mac-store-failure.publish-lock"
  /bin/mkdir "$PUBLISH_LOCK"
  PUBLISH_LOCK_IDENTITY="$(/usr/bin/stat -f '\''%d:%i'\'' "$PUBLISH_LOCK")"
  PUBLISH_LOCK_HELD=true
  PUBLISHED_RELEASE_DIR=""
  FINAL_RELEASE_DIR=""
  COMMIT_DONE=false
  PUBLISHED=false
  PREFLIGHT_ASSERTION="$3"
  READINESS_REPORT="$4"
  trap cleanup EXIT
  assert_archive_identity_lock_unchanged
' -- "$RELEASE_FUNCTIONS" "$CLEANUP_DIST" "$FAIL_PREFLIGHT" \
    "$READINESS_FIXTURE" >/dev/null 2>&1; then
  fail "a failed action-boundary preflight unexpectedly succeeded"
fi
[[ ! -e "$CLEANUP_DIST/.agentisland-mac-store.failure" && \
    ! -e "$CLEANUP_DIST/.agentisland-mac-store-failure.publish-lock" ]] \
  || fail "failed action-boundary preflight leaked its staging directory or lock"

REPLACED_LOCK_DIST="$TEST_ROOT/replaced-lock-cleanup"
/bin/mkdir -p "$REPLACED_LOCK_DIST"
if /bin/zsh -c '
  set -euo pipefail
  source "$1"
  DIST_ROOT="$2"
  WORK_ROOT=""
  STAGING_ROOT=""
  STAGING_IDENTITY=""
  PUBLISH_LOCK="$DIST_ROOT/.agentisland-mac-store-replaced.publish-lock"
  /bin/mkdir "$PUBLISH_LOCK"
  PUBLISH_LOCK_IDENTITY="$(/usr/bin/stat -f '\''%d:%i'\'' "$PUBLISH_LOCK")"
  PUBLISH_LOCK_HELD=true
  /bin/mkdir "$DIST_ROOT/replacement"
  /bin/rmdir "$PUBLISH_LOCK"
  /bin/mv "$DIST_ROOT/replacement" "$PUBLISH_LOCK"
  PUBLISHED_RELEASE_DIR=""
  FINAL_RELEASE_DIR=""
  COMMIT_DONE=false
  PUBLISHED=false
  trap cleanup EXIT
  exit 2
' -- "$RELEASE_FUNCTIONS" "$REPLACED_LOCK_DIST" >/dev/null 2>&1; then
  fail "replaced-lock cleanup fixture unexpectedly succeeded"
fi
[[ -d "$REPLACED_LOCK_DIST/.agentisland-mac-store-replaced.publish-lock" ]] \
  || fail "cleanup removed a publish lock whose filesystem identity changed"
/bin/rmdir "$REPLACED_LOCK_DIST/.agentisland-mac-store-replaced.publish-lock"

ROLLBACK_DIST="$TEST_ROOT/publication-rollback"
/bin/mkdir -p "$ROLLBACK_DIST"
if /bin/zsh -c '
  set -euo pipefail
  source "$1"
  DIST_ROOT="$2"
  WORK_ROOT=""
  STAGING_ROOT="$DIST_ROOT/.agentisland-mac-store.rollback"
  /bin/mkdir "$STAGING_ROOT"
  STAGING_IDENTITY="$(/usr/bin/stat -f '\''%d:%i'\'' "$STAGING_ROOT")"
  PUBLISH_LOCK=""
  PUBLISH_LOCK_IDENTITY=""
  PUBLISH_LOCK_HELD=false
  FINAL_RELEASE_DIR="$DIST_ROOT/final"
  /bin/mkdir "$FINAL_RELEASE_DIR"
  print -n -r -- competitor >"$FINAL_RELEASE_DIR/sentinel"
  PUBLISHED_RELEASE_DIR="$FINAL_RELEASE_DIR"
  COMMIT_DONE=false
  PUBLISHED=false
  trap cleanup EXIT
  /bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"
  exit 2
' -- "$RELEASE_FUNCTIONS" "$ROLLBACK_DIST" >/dev/null 2>&1; then
  fail "publication-race rollback fixture unexpectedly succeeded"
fi
[[ -f "$ROLLBACK_DIST/final/sentinel" && \
    "$(/bin/cat "$ROLLBACK_DIST/final/sentinel")" == competitor && \
    ! -e "$ROLLBACK_DIST/final/.agentisland-mac-store.rollback" ]] \
  || fail "publication rollback removed a competing destination or leaked staging"

[[ "$(/usr/bin/plutil -extract NSHumanReadableCopyright raw "$MAC_INFO")" == \
  '$(AGENT_ISLAND_COPYRIGHT)' ]] \
  || fail "Mac App Store Info.plist is not wired to the release copyright setting"
[[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw "$MAC_INFO")" == \
  'public.app-category.developer-tools' ]] \
  || fail "Mac App Store Info.plist does not declare the Developer Tools category"
[[ "$(/usr/bin/plutil -extract CFBundleDevelopmentRegion raw "$MAC_INFO")" == \
  '$(DEVELOPMENT_LANGUAGE)' ]] \
  || fail "Mac App Store Info.plist is not wired to the project development language"
contains 'NSHumanReadableCopyright == "$(AGENT_ISLAND_COPYRIGHT)"' "$MAC_VALIDATOR"
contains '.CFBundleDevelopmentRegion == "$(DEVELOPMENT_LANGUAGE)"' "$MAC_VALIDATOR"
contains '.LSApplicationCategoryType == "public.app-category.developer-tools"' "$MAC_VALIDATOR"
contains '(keys | sort) == [' "$MAC_VALIDATOR"
contains 'SystemCapabilities."com.apple.AppSandbox".enabled == "1"' "$MAC_VALIDATOR"
contains '.buildSettings.PRODUCT_BUNDLE_IDENTIFIER == "$(AGENT_ISLAND_MAC_APP_BUNDLE_ID)"' "$MAC_VALIDATOR"
contains 'ApplePlatforms/macOS/scripts/release-macos-app-store.sh' "$MAC_VALIDATOR"
contains 'iconutil --convert iconset' "$MAC_VALIDATOR"
contains 'icon_512x512@2x.png:1024' "$MAC_VALIDATOR"

print -r -- "macOS App Store release-script contract passed"
