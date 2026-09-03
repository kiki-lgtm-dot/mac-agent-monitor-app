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
contains 'select full Xcode 26 or newer' "$PREFLIGHT_OUTPUT"

for marker in \
  'Xcode 26 or newer is required for this App Store candidate' \
  'the macOS 26 SDK or newer is required for this App Store candidate' \
  'destination -string export' \
  'method -string app-store-connect' \
  'manageAppVersionAndBuildNumber -bool false' \
  'schemaVersion: 1' \
  'version: $version' \
  'build: $build' \
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
  'pkgutil --check-signature' \
  'pkgutil --expand' \
  'shasum -a 256' \
  'COPYFILE_DISABLE=1' \
  'xcarchive ZIP failed integrity validation' \
  'mktemp -d "$DIST_ROOT/.agentisland-mac-store.XXXXXX"' \
  '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"'; do
  contains "$marker" "$SCRIPT"
done

for marker in \
  '.version == $version and .build == $build' \
  'AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256' \
  'AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256' \
  'MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE' \
  'readyForMacAppStoreUpload' \
  'readyForFunctionalMacAppStoreSubmissionDeprecated: true' \
  'READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=false'; do
  contains "$marker" "$READINESS"
done
if /usr/bin/grep -Eq 'READY_FUNCTIONAL_MAC_APP_STORE_SUBMISSION=true' "$READINESS"; then
  fail "local uploaded:false metadata can still claim macOS review-submission readiness"
fi

/usr/bin/env \
  -u AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA \
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
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .readyForMacAppStoreUpload == false and
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
[[ "$ARCHIVE_LINE" == <-> && "$EXPORT_LINE" == <-> && \
  "$METADATA_LINE" == <-> && "$PUBLISH_LINE" == <-> && \
  "$ARCHIVE_LINE" -lt "$EXPORT_LINE" && "$EXPORT_LINE" -lt "$METADATA_LINE" && \
  "$METADATA_LINE" -lt "$PUBLISH_LINE" ]] \
  || fail "staged archive/export/metadata must complete before publication"

[[ "$(/usr/bin/plutil -extract NSHumanReadableCopyright raw "$MAC_INFO")" == \
  '$(AGENT_ISLAND_COPYRIGHT)' ]] \
  || fail "Mac App Store Info.plist is not wired to the release copyright setting"
contains 'NSHumanReadableCopyright == "$(AGENT_ISLAND_COPYRIGHT)"' "$MAC_VALIDATOR"
contains 'ApplePlatforms/macOS/scripts/release-macos-app-store.sh' "$MAC_VALIDATOR"

print -r -- "macOS App Store release-script contract passed"
