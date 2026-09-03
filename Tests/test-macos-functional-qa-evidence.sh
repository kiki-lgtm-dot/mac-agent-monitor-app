#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
GENERATOR_SOURCE="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh"
VALIDATOR_SOURCE="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-macos-functional-evidence-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "macOS functional QA evidence test failed: $*"
  exit 1
}

contains() {
  local marker="$1"
  local path="$2"
  /usr/bin/grep -Fq -- "$marker" "$path" \
    || fail "missing '$marker' in ${path#$PROJECT_ROOT/}"
}

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

[[ -x "$GENERATOR_SOURCE" ]] || fail "functional QA evidence generator is missing or not executable"
[[ -x "$VALIDATOR_SOURCE" ]] || fail "functional QA evidence validator is missing or not executable"
/bin/zsh -n "$GENERATOR_SOURCE"
/bin/zsh -n "$VALIDATOR_SOURCE"

for marker in \
  'AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA' \
  'all five functional QA results must be exactly passed' \
  'five distinct evidence attachments' \
  'refusing to overwrite an existing macOS functional QA evidence file' \
  '/bin/ln "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH"' \
  '/bin/chmod 0444 "$EVIDENCE_PATH"' \
  'authorizationConfirmed: true' \
  'denialConfirmed: true' \
  'revocationConfirmed: true' \
  'recoveryConfirmed: true' \
  'packageInstalled: true' \
  'launchConfirmed: true' \
  'quitConfirmed: true' \
  'certificateMatchConfirmed: true' \
  'reportReviewed: true' \
  'exampleModeConfirmed: true' \
  'productionPathConfirmed: true'; do
  contains "$marker" "$GENERATOR_SOURCE"
done
for marker in \
  'submit-macos-app-store.sh" --check' \
  'Archive ZIP SHA-256 differs from release metadata' \
  'App Store package SHA-256 differs from release metadata' \
  'functional QA evidence candidate does not match the exact Archive ZIP and package' \
  'must be read-only (no write permission bits)' \
  'QA attachment SHA-256 does not match the functional QA record' \
  'cannot reuse one file through hard links' \
  'five different content SHA-256 values' \
  'QA attachment content cannot match metadata, Archive ZIP, package, or evidence' \
  'sandboxFlowVerified: true' \
  'archiveInstallLaunchQuitVerified: true' \
  'profileCertificateVerified: true' \
  'privacyReportVerified: true' \
  'reviewPathVerified: true'; do
  contains "$marker" "$VALIDATOR_SOURCE"
done
for script in "$GENERATOR_SOURCE" "$VALIDATOR_SOURCE"; do
  for forbidden_marker in '/usr/bin/xcrun' 'altool' 'iTMSTransporter' '/usr/bin/curl'; do
    if /usr/bin/grep -Fq -- "$forbidden_marker" "$script"; then
      fail "${script:t} must remain local-only and contains $forbidden_marker"
    fi
  done
done

INSTRUMENTED_ROOT="$TEST_ROOT/ApplePlatforms/macOS"
INSTRUMENTED_SCRIPTS="$INSTRUMENTED_ROOT/scripts"
GENERATOR="$INSTRUMENTED_SCRIPTS/confirm-functional-qa-evidence.sh"
VALIDATOR="$INSTRUMENTED_SCRIPTS/validate-functional-qa-evidence.sh"
/bin/mkdir -p "$INSTRUMENTED_SCRIPTS"
/bin/cp "$GENERATOR_SOURCE" "$GENERATOR"
/bin/cp "$VALIDATOR_SOURCE" "$VALIDATOR"

# This strict stub proves the tools only reuse the existing credential-free
# exact-candidate preflight. The fixture does not need Xcode or signing keys.
/bin/cat >"$INSTRUMENTED_SCRIPTS/submit-macos-app-store.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "--check" \
    && "$2" == "$AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY" ]] || exit 64
[[ -f "$2/release-metadata.json" ]] || exit 65
print -r -- "$*" >>"$AGENT_ISLAND_TEST_CHECK_LOG"
EOF
/bin/chmod 0755 "$GENERATOR" "$VALIDATOR" \
  "$INSTRUMENTED_SCRIPTS/submit-macos-app-store.sh"

RELEASE_DIRECTORY="$TEST_ROOT/release"
ARCHIVE_PATH="$RELEASE_DIRECTORY/AgentIslandMac.xcarchive"
ARCHIVE_ZIP_PATH="$RELEASE_DIRECTORY/AgentIslandMac.xcarchive.zip"
PACKAGE_PATH="$RELEASE_DIRECTORY/export/AgentIslandMac.pkg"
METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"
FUNCTIONAL_EVIDENCE_PATH="$RELEASE_DIRECTORY/macos-functional-verification-test.json"
CHECK_LOG="$TEST_ROOT/check.log"
/bin/mkdir -p "$ARCHIVE_PATH" "${PACKAGE_PATH:h}"
export AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$RELEASE_DIRECTORY"
export AGENT_ISLAND_TEST_CHECK_LOG="$CHECK_LOG"

print -n -r -- 'exact Archive ZIP fixture' >"$ARCHIVE_ZIP_PATH"
print -n -r -- 'exact App Store package fixture' >"$PACKAGE_PATH"
ARCHIVE_ZIP_SHA256="$(file_sha256 "$ARCHIVE_ZIP_PATH")"
PACKAGE_SHA256="$(file_sha256 "$PACKAGE_PATH")"

APP_BUNDLE_ID="com.agentisland.mac.release"
VERSION="1.2.3"
BUILD_NUMBER="42"
CANDIDATE_CREATED_AT="$(/bin/date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
FUNCTIONAL_TESTED_AT="$(/bin/date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/jq -n \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archivePath "$ARCHIVE_PATH" \
  --arg archiveZip "$ARCHIVE_ZIP_PATH" \
  --arg archiveSHA "$ARCHIVE_ZIP_SHA256" \
  --arg packagePath "$PACKAGE_PATH" \
  --arg packageSHA "$PACKAGE_SHA256" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg createdAt "$CANDIDATE_CREATED_AT" '{
    schemaVersion: 1,
    product: "MAC版灵动岛--Agent运行监测",
    platform: "macOS",
    distribution: "mac-app-store",
    version: $version,
    build: $build,
    archivePath: $archivePath,
    archiveZip: $archiveZip,
    archiveZipSHA256: $archiveSHA,
    resultBundle: null,
    exportedPackage: $packagePath,
    packageSHA256: $packageSHA,
    exportMethod: "app-store-connect",
    exportDestination: "export",
    xcodeVersion: "Xcode 26.0",
    macosSDK: "macOS 26.0",
    teamID: "ABCDE12345",
    appBundleID: $appBundleID,
    displayName: "MAC版灵动岛--Agent运行监测",
    applicationCategory: "public.app-category.developer-tools",
    copyright: "© 2026 Agent Island Release Test",
    applicationIdentifier: ("ABCDE12345." + $appBundleID),
    cloudContainerID: "iCloud.com.agentisland.mac.release",
    cloudKitEnvironment: "Production",
    privacyPolicyURL: "https://agentisland.test/privacy",
    supportURL: "https://agentisland.test/support",
    privacyManifestSHA256: ("a" * 64),
    signingIdentity: "Apple Distribution: Release Fixture (ABCDE12345)",
    signingCertificateSHA1: ("A" * 40),
    provisioningProfile: {
      uuid: "11111111-2222-3333-4444-555555555555",
      name: "Agent Island Mac App Store Fixture",
      expiration: "2099-01-01T00:00:00Z",
      certificateMatches: true
    },
    installerSigningIdentity: "Mac Installer Distribution: Release Fixture (ABCDE12345)",
    exportedProvisioningProfileExpiration: "2099-01-01T00:00:00Z",
    allowProvisioningUpdates: false,
    uploaded: false,
    createdAt: $createdAt
  }' >"$METADATA_PATH"

SANDBOX_EVIDENCE="$RELEASE_DIRECTORY/sandbox-flow-report.txt"
ARCHIVE_EVIDENCE="$RELEASE_DIRECTORY/archive-install-report.txt"
PROFILE_EVIDENCE="$RELEASE_DIRECTORY/profile-certificate-report.txt"
PRIVACY_EVIDENCE="$RELEASE_DIRECTORY/xcode-privacy-report.txt"
REVIEW_EVIDENCE="$RELEASE_DIRECTORY/review-path-report.txt"
print -n -r -- 'Authorization, denial, revocation, and recovery verified.' >"$SANDBOX_EVIDENCE"
print -n -r -- 'Archive inspected; package installed; launch and quit verified.' >"$ARCHIVE_EVIDENCE"
print -n -r -- 'Provisioning profile and signing certificate match verified.' >"$PROFILE_EVIDENCE"
print -n -r -- 'Xcode Privacy Report inspected against declared data use.' >"$PRIVACY_EVIDENCE"
print -n -r -- 'Example and production review paths completed.' >"$REVIEW_EVIDENCE"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$ARCHIVE_ZIP_SHA256:$PACKAGE_SHA256"

run_generator() {
  local sandbox_result="$1"
  local mac_model="$2"
  local output_path="$3"
  local confirmation_value="$4"
  local sandbox_attachment="${5:-$SANDBOX_EVIDENCE}"
  local archive_attachment="${6:-$ARCHIVE_EVIDENCE}"
  local macos_version="${7:-15.6.1}"
  AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA="$confirmation_value" \
    "$GENERATOR" \
      --mac-model "$mac_model" \
      --macos-version "$macos_version" \
      --tested-at "$FUNCTIONAL_TESTED_AT" \
      --sandbox-flow-result "$sandbox_result" \
      --sandbox-flow-evidence "$sandbox_attachment" \
      --archive-install-launch-quit-result passed \
      --archive-install-launch-quit-evidence "$archive_attachment" \
      --profile-certificate-result passed \
      --profile-certificate-evidence "$PROFILE_EVIDENCE" \
      --privacy-report-result passed \
      --privacy-report-evidence "$PRIVACY_EVIDENCE" \
      --review-path-result passed \
      --review-path-evidence "$REVIEW_EVIDENCE" \
      --output "$output_path" \
      "$METADATA_PATH"
}

expect_generator_rejected() {
  local marker="$1"
  shift
  local output="$TEST_ROOT/generator-rejected.txt"
  if run_generator "$@" >"$output" 2>&1; then
    fail "generator accepted fixture expected to fail with: $marker"
  fi
  /usr/bin/grep -Fq -- "$marker" "$output" \
    || fail "generator rejection did not contain '$marker': $(/bin/cat "$output")"
}

expect_validator_rejected() {
  local marker="$1"
  local evidence_path="$2"
  shift 2
  local output="$TEST_ROOT/validator-rejected.txt"
  if "$VALIDATOR" "$@" "$evidence_path" >"$output" 2>&1; then
    fail "validator accepted fixture expected to fail with: $marker"
  fi
  /usr/bin/grep -Fq -- "$marker" "$output" \
    || fail "validator rejection did not contain '$marker': $(/bin/cat "$output")"
}

expect_generator_rejected \
  'all five functional QA results must be exactly passed' \
  false 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-false.json" "$CONFIRMATION_VALUE"
expect_generator_rejected \
  '--mac-model is missing or a placeholder' \
  passed '<MAC MODEL>' \
  "$RELEASE_DIRECTORY/macos-functional-verification-placeholder.json" "$CONFIRMATION_VALUE"
expect_generator_rejected \
  '--macos-version must contain 2 or 3 numeric components' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-invalid-os.json" \
  "$CONFIRMATION_VALUE" "$SANDBOX_EVIDENCE" "$ARCHIVE_EVIDENCE" '15'
expect_generator_rejected \
  'does not match this exact Archive ZIP and package' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-wrong-confirmation.json" \
  'wrong:confirmation:value'

OUTSIDE_ATTACHMENT="$TEST_ROOT/outside-report.txt"
print -n -r -- 'outside release' >"$OUTSIDE_ATTACHMENT"
expect_generator_rejected \
  'must be stored inside the exact candidate release directory' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-outside.json" "$CONFIRMATION_VALUE" \
  "$OUTSIDE_ATTACHMENT"

SYMLINK_ATTACHMENT="$RELEASE_DIRECTORY/sandbox-symlink.txt"
/bin/ln -s "$SANDBOX_EVIDENCE" "$SYMLINK_ATTACHMENT"
expect_generator_rejected \
  'must be an existing, absolute, non-symlink file' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-symlink.json" "$CONFIRMATION_VALUE" \
  "$SYMLINK_ATTACHMENT"
expect_generator_rejected \
  'cannot reuse a core release artifact' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-artifact.json" "$CONFIRMATION_VALUE" \
  "$ARCHIVE_ZIP_PATH"
expect_generator_rejected \
  'five QA checks must use five distinct evidence attachments' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-duplicate.json" "$CONFIRMATION_VALUE" \
  "$SANDBOX_EVIDENCE" "$SANDBOX_EVIDENCE"

HARDLINK_ATTACHMENT="$RELEASE_DIRECTORY/sandbox-hardlink.txt"
/bin/ln "$SANDBOX_EVIDENCE" "$HARDLINK_ATTACHMENT"
expect_generator_rejected \
  'cannot reuse one file through hard links' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-hardlink.json" "$CONFIRMATION_VALUE" \
  "$SANDBOX_EVIDENCE" "$HARDLINK_ATTACHMENT"

SAME_CONTENT_ATTACHMENT="$RELEASE_DIRECTORY/sandbox-same-content.txt"
/bin/cp "$SANDBOX_EVIDENCE" "$SAME_CONTENT_ATTACHMENT"
expect_generator_rejected \
  'five different content SHA-256 values' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-same-content.json" "$CONFIRMATION_VALUE" \
  "$SANDBOX_EVIDENCE" "$SAME_CONTENT_ATTACHMENT"

CORE_CONTENT_ATTACHMENT="$RELEASE_DIRECTORY/archive-content-disguised-as-report.txt"
print -n -r -- 'exact Archive ZIP fixture' >"$CORE_CONTENT_ATTACHMENT"
expect_generator_rejected \
  'QA attachment content cannot match a core release artifact' \
  passed 'MacBook Pro 14-inch (2024)' \
  "$RELEASE_DIRECTORY/macos-functional-verification-core-content.json" "$CONFIRMATION_VALUE" \
  "$CORE_CONTENT_ATTACHMENT"

run_generator passed 'MacBook Pro 14-inch (2024)' "$FUNCTIONAL_EVIDENCE_PATH" \
  "$CONFIRMATION_VALUE" >"$TEST_ROOT/generator-valid.txt" 2>&1 \
  || fail "valid exact-candidate QA fixture was rejected: $(/bin/cat "$TEST_ROOT/generator-valid.txt")"
contains 'macOS functional QA evidence recorded:' "$TEST_ROOT/generator-valid.txt"
[[ "$(/usr/bin/stat -f '%Lp' "$FUNCTIONAL_EVIDENCE_PATH")" == "444" ]] \
  || fail "generated functional QA evidence is not mode 0444"

VALID_JSON="$TEST_ROOT/validator-valid.json"
"$VALIDATOR" --json \
  --expected-release-metadata "$METADATA_PATH" \
  --expected-archive-sha256 "$ARCHIVE_ZIP_SHA256" \
  --expected-package-sha256 "$PACKAGE_SHA256" \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$VALID_JSON" \
  || fail "validator rejected generated exact-candidate QA evidence"
/usr/bin/jq -e \
  --arg archiveSHA "$ARCHIVE_ZIP_SHA256" \
  --arg packageSHA "$PACKAGE_SHA256" '
    .evidenceReady == true and
    .candidate.archiveZipSHA256 == $archiveSHA and
    .candidate.packageSHA256 == $packageSHA and
    .testMachine.model == "MacBook Pro 14-inch (2024)" and
    .testMachine.osVersion == "15.6.1" and
    .sandboxFlowVerified == true and
    .archiveInstallLaunchQuitVerified == true and
    .profileCertificateVerified == true and
    .privacyReportVerified == true and
    .reviewPathVerified == true
  ' "$VALID_JSON" >/dev/null \
  || fail "validator JSON did not expose the machine and all five exact-candidate gates"
[[ "$(/usr/bin/sort -u "$CHECK_LOG" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] \
  || fail "functional evidence tools invoked a non-deterministic submission preflight"
contains "--check $RELEASE_DIRECTORY" "$CHECK_LOG"

expect_generator_rejected \
  'refusing to overwrite an existing macOS functional QA evidence file' \
  passed 'MacBook Pro 14-inch (2024)' "$FUNCTIONAL_EVIDENCE_PATH" "$CONFIRMATION_VALUE"

print -n -r -- 'tampered sandbox evidence' >>"$SANDBOX_EVIDENCE"
expect_validator_rejected \
  'sandboxAuthorizationFlow QA attachment size does not match the functional QA record' \
  "$FUNCTIONAL_EVIDENCE_PATH"
print -n -r -- 'Authorization, denial, revocation, and recovery verified.' >"$SANDBOX_EVIDENCE"

print -n -r -- 'tamper' >>"$ARCHIVE_ZIP_PATH"
expect_validator_rejected \
  'Archive ZIP SHA-256 differs from release metadata' "$FUNCTIONAL_EVIDENCE_PATH"
print -n -r -- 'exact Archive ZIP fixture' >"$ARCHIVE_ZIP_PATH"

print -n -r -- 'tamper' >>"$PACKAGE_PATH"
expect_validator_rejected \
  'App Store package SHA-256 differs from release metadata' "$FUNCTIONAL_EVIDENCE_PATH"
print -n -r -- 'exact App Store package fixture' >"$PACKAGE_PATH"

FALSE_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-false-field.json"
/usr/bin/jq '.qa.xcodePrivacyReport.result = "failed"' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$FALSE_EVIDENCE"
/bin/chmod 0444 "$FALSE_EVIDENCE"
expect_validator_rejected 'contains false results' "$FALSE_EVIDENCE"

MISMATCH_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-hash-mismatch.json"
/usr/bin/jq '.candidate.packageSHA256 = ("0" * 64)' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$MISMATCH_EVIDENCE"
/bin/chmod 0444 "$MISMATCH_EVIDENCE"
expect_validator_rejected \
  'candidate does not match the exact Archive ZIP and package' "$MISMATCH_EVIDENCE"

MUTABLE_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-mutable.json"
/bin/cp "$FUNCTIONAL_EVIDENCE_PATH" "$MUTABLE_EVIDENCE"
/bin/chmod 0644 "$MUTABLE_EVIDENCE"
expect_validator_rejected 'must be read-only' "$MUTABLE_EVIDENCE"

HARDLINK_FIELD_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-hardlink-field.json"
/usr/bin/jq --arg path "$HARDLINK_ATTACHMENT" \
  '.qa.archiveInstallLaunchQuit.evidence.path = $path |
   .qa.archiveInstallLaunchQuit.evidence.sha256 = .qa.sandboxAuthorizationFlow.evidence.sha256 |
   .qa.archiveInstallLaunchQuit.evidence.sizeBytes = .qa.sandboxAuthorizationFlow.evidence.sizeBytes' \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$HARDLINK_FIELD_EVIDENCE"
/bin/chmod 0444 "$HARDLINK_FIELD_EVIDENCE"
expect_validator_rejected \
  'cannot reuse one file through hard links' "$HARDLINK_FIELD_EVIDENCE"

SAME_CONTENT_FIELD_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-same-content-field.json"
/usr/bin/jq --arg path "$SAME_CONTENT_ATTACHMENT" \
  '.qa.archiveInstallLaunchQuit.evidence.path = $path |
   .qa.archiveInstallLaunchQuit.evidence.sha256 = .qa.sandboxAuthorizationFlow.evidence.sha256 |
   .qa.archiveInstallLaunchQuit.evidence.sizeBytes = .qa.sandboxAuthorizationFlow.evidence.sizeBytes' \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$SAME_CONTENT_FIELD_EVIDENCE"
/bin/chmod 0444 "$SAME_CONTENT_FIELD_EVIDENCE"
expect_validator_rejected \
  'five different content SHA-256 values' "$SAME_CONTENT_FIELD_EVIDENCE"

INVALID_OS_EVIDENCE="$RELEASE_DIRECTORY/macos-functional-verification-invalid-os-field.json"
/usr/bin/jq '.testMachine.osVersion = "15"' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$INVALID_OS_EVIDENCE"
/bin/chmod 0444 "$INVALID_OS_EVIDENCE"
expect_validator_rejected \
  'macOS version must contain 2 or 3 numeric components' "$INVALID_OS_EVIDENCE"

WRONG_EXPECTED_SHA="0000000000000000000000000000000000000000000000000000000000000000"
expect_validator_rejected \
  'is not bound to the expected package SHA-256' "$FUNCTIONAL_EVIDENCE_PATH" \
  --expected-package-sha256 "$WRONG_EXPECTED_SHA"

print -r -- 'macOS exact-candidate functional QA evidence tests passed'
