#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PREFLIGHT="$PROJECT_DIR/scripts/assert-release-preflight.sh"
ENTITLEMENTS_CONTRACT="$PROJECT_DIR/scripts/developer-id-entitlements-contract.jq"
MAC_RELEASE="$PROJECT_DIR/scripts/release-macos.sh"
IOS_RELEASE="$PROJECT_DIR/ApplePlatforms/iOS/scripts/release-ios.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-release-entrypoints.XXXXXX)"
trap '[[ "$TEST_ROOT" == /private/tmp/agentisland-release-entrypoints.* ]] && /bin/rm -rf "$TEST_ROOT"' EXIT
IDENTITY_LOCK="$TEST_ROOT/identity.lock.json"
/usr/bin/jq -n '{schemaVersion: 1, fixture: "immutable release identity"}' \
  >"$IDENTITY_LOCK"
/bin/chmod 0600 "$IDENTITY_LOCK"
IDENTITY_LOCK_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$IDENTITY_LOCK" | /usr/bin/awk '{print $1}')"

fail() {
  print -u2 -r -- "Release-entrypoint hardening test failed: $*"
  exit 1
}

contains() {
  local needle="$1"
  local path="$2"
  /usr/bin/grep -Fq -- "$needle" "$path" \
    || fail "$path is missing: $needle"
}

expect_rejected() {
  local label="$1"
  shift
  if "$@" >"$TEST_ROOT/rejected.stdout" 2>"$TEST_ROOT/rejected.stderr"; then
    fail "$label was accepted"
  fi
}

/bin/zsh -n "$PREFLIGHT" "$MAC_RELEASE" "$IOS_RELEASE"

# These reports intentionally omit every post-candidate upload, processing,
# install, review, and QA field. Archive entrypoints must accept the complete
# pre-candidate contract without accidentally depending on later evidence.
DEVELOPER_REPORT="$TEST_ROOT/developer-ready.json"
/usr/bin/jq -n --arg lockPath "$IDENTITY_LOCK" \
  --arg lockSHA256 "$IDENTITY_LOCK_SHA256" '{
  releaseIdentityLockConfigured: true,
  releaseIdentityLockValid: true,
  releaseIdentityAppliedFilesMatch: true,
  releaseIdentityMatchesConfiguration: true,
  releaseIdentityLockPath: $lockPath,
  releaseIdentityLockSHA256: $lockSHA256,
  releaseIdentityProfileRecordsPresent: true,
  releaseIdentityAuxiliaryFilesMatch: true,
  releaseIdentityProfileAssetsMatch: true,
  releaseIdentityReady: true,
  readyForDeveloperIDRelease: true
}' >"$DEVELOPER_REPORT"
"$PREFLIGHT" developer-id "$DEVELOPER_REPORT"

for field in \
    releaseIdentityLockValid \
    releaseIdentityAppliedFilesMatch \
    releaseIdentityMatchesConfiguration \
    releaseIdentityProfileRecordsPresent \
    releaseIdentityAuxiliaryFilesMatch \
    releaseIdentityProfileAssetsMatch \
    releaseIdentityReady \
    readyForDeveloperIDRelease; do
  INVALID_REPORT="$TEST_ROOT/developer-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$DEVELOPER_REPORT" >"$INVALID_REPORT"
  expect_rejected "Developer ID report with $field=false" \
    "$PREFLIGHT" developer-id "$INVALID_REPORT"
done

MAC_APP_STORE_REPORT="$TEST_ROOT/mac-app-store-ready.json"
/usr/bin/jq -n --arg lockPath "$IDENTITY_LOCK" \
  --arg lockSHA256 "$IDENTITY_LOCK_SHA256" '{
  releaseIdentityLockConfigured: true,
  releaseIdentityLockValid: true,
  releaseIdentityAppliedFilesMatch: true,
  releaseIdentityMatchesConfiguration: true,
  releaseIdentityLockPath: $lockPath,
  releaseIdentityLockSHA256: $lockSHA256,
  releaseIdentityReady: true,
  currentMacAppStoreToolchain: true,
  macAppStoreStaticProjectValidationPassed: true,
  macAppStoreXcodeProjectConfigured: true,
  macAppStoreTargetMembershipConfigured: true,
  macAppStoreRuntimeResourcesInTarget: true,
  macAppStoreBuildSettingsMatch: true,
  macPrivacyManifestInAppTarget: true,
  macAppStoreInfoPlistConfigured: true,
  macAppStoreEntitlementsConfigured: true,
  readyForMacAppStoreArchive: true
}' >"$MAC_APP_STORE_REPORT"
"$PREFLIGHT" mac-app-store "$MAC_APP_STORE_REPORT"

for field in \
    releaseIdentityLockValid \
    releaseIdentityAppliedFilesMatch \
    releaseIdentityMatchesConfiguration \
    releaseIdentityReady \
    currentMacAppStoreToolchain \
    macAppStoreStaticProjectValidationPassed \
    macAppStoreXcodeProjectConfigured \
    macAppStoreTargetMembershipConfigured \
    macAppStoreRuntimeResourcesInTarget \
    macAppStoreBuildSettingsMatch \
    macPrivacyManifestInAppTarget \
    macAppStoreInfoPlistConfigured \
    macAppStoreEntitlementsConfigured \
    readyForMacAppStoreArchive; do
  INVALID_REPORT="$TEST_ROOT/mac-app-store-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$MAC_APP_STORE_REPORT" >"$INVALID_REPORT"
  expect_rejected "Mac App Store report with $field=false" \
    "$PREFLIGHT" mac-app-store "$INVALID_REPORT"
done

MAC_APP_STORE_UPLOAD_REPORT="$TEST_ROOT/mac-app-store-upload-ready.json"
/usr/bin/jq '. + {
  macAppStoreExactCandidateEvidenceReady: true,
  macAppStoreLocalPreflightPassed: true,
  macAppStoreFunctionalQAEvidenceReady: true,
  macAppStoreFunctionalEvidenceBoundToCandidate: true,
  macAppStoreSandboxFlowVerified: true,
  macAppStoreArchiveVerified: true,
  macAppStoreProfileCertificateVerified: true,
  macAppStorePrivacyReportVerified: true,
  macAppStoreReviewPathVerified: true,
  cloudKitProductionSchemaVerified: true,
  macPrivacyReleaseEvidenceReady: true,
  macStoreSubmissionAssetsReady: true,
  iosStoreSubmissionAssetsReady: false,
  storeSubmissionAssetsReady: false,
  readyForMacAppStoreUpload: true
}' "$MAC_APP_STORE_REPORT" >"$MAC_APP_STORE_UPLOAD_REPORT"
# A complete Mac submission must not be blocked by unrelated unfinished iOS
# metadata or screenshots; the aggregate remains false in this fixture.
"$PREFLIGHT" mac-app-store-upload "$MAC_APP_STORE_UPLOAD_REPORT"

for field in \
    releaseIdentityReady \
    readyForMacAppStoreArchive \
    macAppStoreExactCandidateEvidenceReady \
    macAppStoreLocalPreflightPassed \
    macAppStoreFunctionalQAEvidenceReady \
    macAppStoreFunctionalEvidenceBoundToCandidate \
    macAppStoreSandboxFlowVerified \
    macAppStoreArchiveVerified \
    macAppStoreProfileCertificateVerified \
    macAppStorePrivacyReportVerified \
    macAppStoreReviewPathVerified \
    cloudKitProductionSchemaVerified \
    macPrivacyReleaseEvidenceReady \
    macStoreSubmissionAssetsReady \
    readyForMacAppStoreUpload; do
  INVALID_REPORT="$TEST_ROOT/mac-app-store-upload-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$MAC_APP_STORE_UPLOAD_REPORT" >"$INVALID_REPORT"
  expect_rejected "Mac App Store upload report with $field=false" \
    "$PREFLIGHT" mac-app-store-upload "$INVALID_REPORT"
done

IOS_REPORT="$TEST_ROOT/ios-ready.json"
/usr/bin/jq -n --arg lockPath "$IDENTITY_LOCK" \
  --arg lockSHA256 "$IDENTITY_LOCK_SHA256" '{
  releaseIdentityLockConfigured: true,
  releaseIdentityLockValid: true,
  releaseIdentityAppliedFilesMatch: true,
  releaseIdentityMatchesConfiguration: true,
  releaseIdentityLockPath: $lockPath,
  releaseIdentityLockSHA256: $lockSHA256,
  releaseIdentityReady: true,
  iosProjectReleaseValidationPassed: true,
  iosBuildSettingsResolved: true,
  iosTargetBuildSettingsConfigured: true,
  iosProductionBuildSettingsConfigured: true,
  iosBuildSettingsMatchEnvironment: true,
  iosAppBundleID: "com.agentisland.release",
  iosWidgetBundleID: "com.agentisland.release.liveactivity",
  iosDevelopmentTeam: "ABCDE12345",
  iosCloudKitContainer: "iCloud.com.agentisland.release",
  iosDisplayName: "Release Fixture",
  iosMarketingVersion: "1.0.0",
  iosBuildNumber: "1",
  readyForIOSArchive: true
}' >"$IOS_REPORT"
"$PREFLIGHT" ios "$IOS_REPORT"

for field in \
    releaseIdentityLockValid \
    releaseIdentityAppliedFilesMatch \
    releaseIdentityMatchesConfiguration \
    releaseIdentityReady \
    iosProjectReleaseValidationPassed \
    iosBuildSettingsResolved \
    iosTargetBuildSettingsConfigured \
    iosProductionBuildSettingsConfigured \
    iosBuildSettingsMatchEnvironment \
    readyForIOSArchive; do
  INVALID_REPORT="$TEST_ROOT/ios-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$IOS_REPORT" >"$INVALID_REPORT"
  expect_rejected "iOS report with $field=false" \
    "$PREFLIGHT" ios "$INVALID_REPORT"
done

IOS_UPLOAD_REPORT="$TEST_ROOT/ios-upload-ready.json"
/usr/bin/jq '. + {
  iosUploadCandidateLocalPreflightPassed: true,
  iosUploadCandidate: {
    releaseDirectory: "/tmp/release",
    metadataPath: "/tmp/release/release-metadata.json",
    metadataSHA256: ("b" * 64),
    ipaPath: "/tmp/release/export/AgentIsland.ipa",
    ipaSHA256: ("c" * 64),
    releaseIdentityLockSHA256: .releaseIdentityLockSHA256,
    appBundleID: .iosAppBundleID,
    widgetBundleID: .iosWidgetBundleID,
    teamID: .iosDevelopmentTeam,
    cloudContainerID: .iosCloudKitContainer,
    displayName: .iosDisplayName,
    version: .iosMarketingVersion,
    build: .iosBuildNumber
  }
}' "$IOS_REPORT" >"$IOS_UPLOAD_REPORT"
"$PREFLIGHT" ios-upload "$IOS_UPLOAD_REPORT"

for expression in \
    '.releaseIdentityReady = false' \
    '.readyForIOSArchive = false' \
    '.iosUploadCandidateLocalPreflightPassed = false' \
    '.iosUploadCandidate.releaseIdentityLockSHA256 = ("d" * 64)' \
    '.iosUploadCandidate.appBundleID = "com.agentisland.other"' \
    '.iosUploadCandidate.widgetBundleID = "com.agentisland.other.liveactivity"' \
    '.iosUploadCandidate.teamID = "ZZZZZ99999"' \
    '.iosUploadCandidate.cloudContainerID = "iCloud.com.agentisland.other"' \
    '.iosUploadCandidate.displayName = "Other"' \
    '.iosUploadCandidate.version = "2.0.0"' \
    '.iosUploadCandidate.build = "2"'; do
  INVALID_REPORT="$TEST_ROOT/ios-upload-$RANDOM.json"
  /usr/bin/jq "$expression" "$IOS_UPLOAD_REPORT" >"$INVALID_REPORT"
  expect_rejected "iOS upload report mutation: $expression" \
    "$PREFLIGHT" ios-upload "$INVALID_REPORT"
done

IOS_APP_STORE_REVIEW_REPORT="$TEST_ROOT/ios-app-store-review-ready.json"
/usr/bin/jq '. + {
  iosTestFlightExactBuildEvidenceReady: true,
  iosFunctionalQAEvidenceReady: true,
  iosFunctionalEvidenceBoundToCandidate: true,
  iosTestFlightUploadVerified: true,
  iosTestFlightProcessingVerified: true,
  iosTestFlightProcessingState: "VALID",
  iosTestFlightInstallVerified: true,
  iosTestFlightWarningsReviewed: true,
  iosTestFlightWarningsReviewedAt: "2026-09-04T00:00:00Z",
  iosPrivacyReleaseEvidenceReady: true,
  iosStoreSubmissionAssetsReady: true,
  macStoreSubmissionAssetsReady: false,
  storeSubmissionAssetsReady: false,
  appStoreRecordModeConfigured: true,
  appStoreRecordModeBundleIDsValid: true,
  iosTestFlightAppStoreConnectBuildID: "fixture-build-id",
  readyForFunctionalIOSTestFlight: true,
  readyForIOSAppStoreReviewSelection: true
}' "$IOS_REPORT" >"$IOS_APP_STORE_REVIEW_REPORT"
# A ready iOS submission must not depend on unfinished macOS store materials.
"$PREFLIGHT" ios-app-store-review "$IOS_APP_STORE_REVIEW_REPORT"

for field in \
    releaseIdentityReady \
    readyForIOSArchive \
    iosTestFlightExactBuildEvidenceReady \
    iosFunctionalQAEvidenceReady \
    iosFunctionalEvidenceBoundToCandidate \
    iosTestFlightUploadVerified \
    iosTestFlightProcessingVerified \
    iosTestFlightInstallVerified \
    iosTestFlightWarningsReviewed \
    iosPrivacyReleaseEvidenceReady \
    iosStoreSubmissionAssetsReady \
    appStoreRecordModeConfigured \
    appStoreRecordModeBundleIDsValid \
    readyForFunctionalIOSTestFlight \
    readyForIOSAppStoreReviewSelection; do
  INVALID_REPORT="$TEST_ROOT/ios-app-store-review-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
  expect_rejected "iOS App Store review report with $field=false" \
    "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"
done
INVALID_REPORT="$TEST_ROOT/ios-app-store-review-build-id-empty.json"
/usr/bin/jq '.iosTestFlightAppStoreConnectBuildID = ""' \
  "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "iOS App Store review report without an App Store Connect build ID" \
  "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"
INVALID_REPORT="$TEST_ROOT/ios-app-store-review-warning-time-empty.json"
/usr/bin/jq '.iosTestFlightWarningsReviewedAt = ""' \
  "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "iOS App Store review report without a warning-review time" \
  "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"
for invalid_state in null '"BROKEN"'; do
  INVALID_REPORT="$TEST_ROOT/ios-app-store-review-processing-state-$RANDOM.json"
  /usr/bin/jq ".iosTestFlightProcessingState = $invalid_state" \
    "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
  expect_rejected "iOS App Store review report with invalid processing state" \
    "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"
done
INVALID_REPORT="$TEST_ROOT/ios-app-store-review-warning-time-malformed.json"
/usr/bin/jq '.iosTestFlightWarningsReviewedAt = "not-a-time"' \
  "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "iOS App Store review report with malformed warning-review time" \
  "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"

# A report is only a snapshot. Every channel must independently reject lock
# content drift, a replacement symlink, and a path that traverses a symlinked
# parent before performing its protected action.
IDENTITY_LOCK_BASELINE="$TEST_ROOT/identity.lock.baseline.json"
/bin/cp "$IDENTITY_LOCK" "$IDENTITY_LOCK_BASELINE"
print -r -- 'tampered after readiness' >>"$IDENTITY_LOCK"
expect_rejected "identity lock content changed after readiness" \
  "$PREFLIGHT" developer-id "$DEVELOPER_REPORT"
/bin/cp "$IDENTITY_LOCK_BASELINE" "$IDENTITY_LOCK"

/bin/chmod 0644 "$IDENTITY_LOCK"
expect_rejected "identity lock permissions opened after readiness" \
  "$PREFLIGHT" mac-app-store-upload "$MAC_APP_STORE_UPLOAD_REPORT"
/bin/chmod 0600 "$IDENTITY_LOCK"

/bin/mv "$IDENTITY_LOCK" "$TEST_ROOT/identity.lock.real.json"
/bin/ln -s "$TEST_ROOT/identity.lock.real.json" "$IDENTITY_LOCK"
expect_rejected "identity lock replaced with a symlink" \
  "$PREFLIGHT" ios "$IOS_REPORT"
/bin/rm "$IDENTITY_LOCK"
/bin/mv "$TEST_ROOT/identity.lock.real.json" "$IDENTITY_LOCK"

/bin/mkdir "$TEST_ROOT/identity-parent"
/bin/cp "$IDENTITY_LOCK" "$TEST_ROOT/identity-parent/identity.lock.json"
/bin/ln -s "$TEST_ROOT/identity-parent" "$TEST_ROOT/identity-parent-link"
ALIASED_LOCK_REPORT="$TEST_ROOT/aliased-lock-report.json"
/usr/bin/jq --arg path "$TEST_ROOT/identity-parent-link/identity.lock.json" \
  '.releaseIdentityLockPath = $path' "$IOS_REPORT" >"$ALIASED_LOCK_REPORT"
expect_rejected "identity lock path traversing a symlink" \
  "$PREFLIGHT" ios "$ALIASED_LOCK_REPORT"

/bin/ln -s "$IOS_REPORT" "$TEST_ROOT/ios-ready-link.json"
expect_rejected "symlink readiness report" \
  "$PREFLIGHT" ios "$TEST_ROOT/ios-ready-link.json"
expect_rejected "unknown release channel" \
  "$PREFLIGHT" app-store "$IOS_REPORT"

VALID_ENTITLEMENTS="$TEST_ROOT/developer-id-entitlements.json"
/usr/bin/jq -n \
  --arg applicationIdentifier "ABCDE12345.com.agentisland.release" \
  --arg team "ABCDE12345" \
  --arg container "iCloud.com.agentisland.release" '{
    "com.apple.application-identifier": $applicationIdentifier,
    "com.apple.developer.team-identifier": $team,
    "com.apple.developer.icloud-container-identifiers": [$container],
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-services": ["CloudKit"]
  }' >"$VALID_ENTITLEMENTS"

typeset -a CONTRACT_ARGS
CONTRACT_ARGS=(
  --arg applicationIdentifier "ABCDE12345.com.agentisland.release"
  --arg team "ABCDE12345"
  --arg container "iCloud.com.agentisland.release"
  -f "$ENTITLEMENTS_CONTRACT"
)
/usr/bin/jq -e "${CONTRACT_ARGS[@]}" "$VALID_ENTITLEMENTS" >/dev/null

for extra_key in \
    com.apple.security.app-sandbox \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.get-task-allow \
    com.apple.security.network.server; do
  EXTRA_ENTITLEMENTS="$TEST_ROOT/${extra_key//./-}.json"
  /usr/bin/jq --arg key "$extra_key" '. + {($key): true}' \
    "$VALID_ENTITLEMENTS" >"$EXTRA_ENTITLEMENTS"
  expect_rejected "extra entitlement $extra_key" \
    /usr/bin/jq -e "${CONTRACT_ARGS[@]}" "$EXTRA_ENTITLEMENTS"
done

WRONG_SERVICE_ENTITLEMENTS="$TEST_ROOT/wrong-services.json"
/usr/bin/jq '."com.apple.developer.icloud-services" += ["CloudDocuments"]' \
  "$VALID_ENTITLEMENTS" >"$WRONG_SERVICE_ENTITLEMENTS"
expect_rejected "additional iCloud service" \
  /usr/bin/jq -e "${CONTRACT_ARGS[@]}" "$WRONG_SERVICE_ENTITLEMENTS"

# Exercise the real Developer ID entrypoint. The malicious entitlement must be
# rejected before it can decode a profile, touch the build, or contact Apple.
MALICIOUS_ENTITLEMENTS="$TEST_ROOT/malicious.entitlements"
/usr/bin/plutil -convert xml1 -o "$MALICIOUS_ENTITLEMENTS" \
  "$TEST_ROOT/com-apple-security-cs-disable-library-validation.json"
expect_rejected "Developer ID entrypoint with an extra sensitive entitlement" \
  /usr/bin/env \
    AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Fixture (ABCDE12345)' \
    AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='fixture-notary' \
    AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
    AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
    AGENT_ISLAND_VERSION='1.0.0' \
    AGENT_ISLAND_BUILD_NUMBER='1' \
    AGENT_ISLAND_DISPLAY_NAME='MAC版灵动岛--Agent运行监测' \
    AGENT_ISLAND_ENTITLEMENTS="$MALICIOUS_ENTITLEMENTS" \
    AGENT_ISLAND_PROVISIONING_PROFILE="$VALID_ENTITLEMENTS" \
    AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.release' \
    AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
    AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
    "$MAC_RELEASE"
contains 'extra entitlements are forbidden' "$TEST_ROOT/rejected.stderr"

PREFIXED_IDENTIFIER_JSON="$TEST_ROOT/prefixed-identifier.json"
/usr/bin/jq '."com.apple.application-identifier" =
  "ABCDE12345.EXTRA.com.agentisland.release"' \
  "$VALID_ENTITLEMENTS" >"$PREFIXED_IDENTIFIER_JSON"
PREFIXED_IDENTIFIER_ENTITLEMENTS="$TEST_ROOT/prefixed-identifier.entitlements"
/usr/bin/plutil -convert xml1 -o "$PREFIXED_IDENTIFIER_ENTITLEMENTS" \
  "$PREFIXED_IDENTIFIER_JSON"
expect_rejected "Developer ID entrypoint with a prefixed application identifier" \
  /usr/bin/env \
    AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Fixture (ABCDE12345)' \
    AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='fixture-notary' \
    AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
    AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
    AGENT_ISLAND_VERSION='1.0.0' \
    AGENT_ISLAND_BUILD_NUMBER='1' \
    AGENT_ISLAND_DISPLAY_NAME='MAC版灵动岛--Agent运行监测' \
    AGENT_ISLAND_ENTITLEMENTS="$PREFIXED_IDENTIFIER_ENTITLEMENTS" \
    AGENT_ISLAND_PROVISIONING_PROFILE="$VALID_ENTITLEMENTS" \
    AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.release' \
    AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
    AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
    "$MAC_RELEASE"
contains 'application identifier must exactly match Team ID' \
  "$TEST_ROOT/rejected.stderr"

[[ "$(/usr/bin/grep -Fc -- '  -f "$DEVELOPER_ID_ENTITLEMENTS_CONTRACT"' \
    "$MAC_RELEASE")" == "3" ]] \
  || fail "Developer ID source, signed App, and final ZIP must share the exact entitlement contract"
contains '"$PREFLIGHT_ASSERTION" developer-id "$READINESS_REPORT"' "$MAC_RELEASE"
contains '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' "$IOS_RELEASE"

[[ "$(/usr/bin/grep -Fc \
    '"$PREFLIGHT_ASSERTION" developer-id "$READINESS_REPORT"' \
    "$MAC_RELEASE")" == "3" ]] \
  || fail "Developer ID must revalidate the identity lock before build, notarization, and publication"
[[ "$(/usr/bin/grep -Fc \
    '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' \
    "$IOS_RELEASE")" == "4" ]] \
  || fail "iOS must validate the identity lock after readiness and before archive, export, and publication"

MAC_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" developer-id "$READINESS_REPORT"' "$MAC_RELEASE" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
MAC_BUILD_LINE="$(/usr/bin/grep -nF '"$PROJECT_DIR/scripts/build-app.sh"' \
  "$MAC_RELEASE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
(( MAC_GATE_LINE < MAC_BUILD_LINE )) \
  || fail "Developer ID identity gate must run before building or notarizing"
MAC_NOTARY_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" developer-id "$READINESS_REPORT"' "$MAC_RELEASE" \
  | /usr/bin/sed -n '2p' | /usr/bin/cut -d: -f1)"
MAC_NOTARY_LINE="$(/usr/bin/grep -nF \
  '/usr/bin/xcrun notarytool submit "$SOURCE_ARCHIVE"' "$MAC_RELEASE" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
MAC_PUBLISH_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" developer-id "$READINESS_REPORT"' "$MAC_RELEASE" \
  | /usr/bin/sed -n '3p' | /usr/bin/cut -d: -f1)"
MAC_COMMIT_LINE="$(/usr/bin/grep -nF 'COMMIT_STARTED=1' "$MAC_RELEASE" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$MAC_NOTARY_GATE_LINE" == <-> && "$MAC_NOTARY_LINE" == <-> && \
    "$MAC_PUBLISH_GATE_LINE" == <-> && "$MAC_COMMIT_LINE" == <-> ]] \
  || fail "could not locate Developer ID notarization/publication lock gates"
(( MAC_NOTARY_GATE_LINE < MAC_NOTARY_LINE && \
    MAC_PUBLISH_GATE_LINE < MAC_COMMIT_LINE )) \
  || fail "Developer ID must revalidate the identity lock at notarization and publication boundaries"

IOS_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' "$IOS_RELEASE" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
IOS_ARCHIVE_LINE="$(/usr/bin/grep -nF \
  'DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${ARCHIVE_ARGS[@]}"' \
  "$IOS_RELEASE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
(( IOS_GATE_LINE < IOS_ARCHIVE_LINE )) \
  || fail "iOS identity gate must run before xcodebuild archive"
IOS_ARCHIVE_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' "$IOS_RELEASE" \
  | /usr/bin/sed -n '2p' | /usr/bin/cut -d: -f1)"
IOS_EXPORT_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' "$IOS_RELEASE" \
  | /usr/bin/sed -n '3p' | /usr/bin/cut -d: -f1)"
IOS_EXPORT_LINE="$(/usr/bin/grep -nF \
  'DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${EXPORT_ARGS[@]}"' \
  "$IOS_RELEASE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
IOS_PUBLISH_GATE_LINE="$(/usr/bin/grep -nF \
  '"$PREFLIGHT_ASSERTION" ios "$READINESS_REPORT"' "$IOS_RELEASE" \
  | /usr/bin/sed -n '4p' | /usr/bin/cut -d: -f1)"
IOS_ATOMIC_PUBLISH_LINE="$(/usr/bin/grep -nF \
  '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"' "$IOS_RELEASE" \
  | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$IOS_ARCHIVE_GATE_LINE" == <-> && "$IOS_EXPORT_GATE_LINE" == <-> && \
    "$IOS_EXPORT_LINE" == <-> && "$IOS_PUBLISH_GATE_LINE" == <-> && \
    "$IOS_ATOMIC_PUBLISH_LINE" == <-> ]] \
  || fail "could not locate iOS archive/export/publication identity-lock gates"
(( IOS_ARCHIVE_GATE_LINE < IOS_ARCHIVE_LINE && \
    IOS_EXPORT_GATE_LINE < IOS_EXPORT_LINE && \
    IOS_PUBLISH_GATE_LINE < IOS_ATOMIC_PUBLISH_LINE )) \
  || fail "iOS must revalidate the identity lock at every artifact action boundary"

for marker in \
    'STAGING_ROOT="$(mktemp -d "$DIST_ROOT/.agentisland-ios-release-staging.XXXXXX")"' \
    'PUBLISH_LOCK="$DIST_ROOT/.agentisland-ios-release-$RELEASE_BASENAME.publish-lock"' \
    '[[ ! -e "$FINAL_RELEASE_DIR" && ! -L "$FINAL_RELEASE_DIR" ]]' \
    '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"' \
    '"$PUBLISHED_RELEASE_DIR" == "$FINAL_RELEASE_DIR"' \
    '"$(/usr/bin/stat -f '\''%i'\'' "$PUBLISHED_RELEASE_DIR" 2>/dev/null)" ==' \
    'COMMIT_DONE=true'; do
  contains "$marker" "$IOS_RELEASE"
done
if /usr/bin/grep -Fq '/bin/mkdir -p "$RELEASE_DIR"' "$IOS_RELEASE"; then
  fail "iOS release still creates its final public directory before validation"
fi

IOS_METADATA_LINE="$(/usr/bin/grep -nF "  }' >\"\$METADATA_PATH\"" \
  "$IOS_RELEASE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
IOS_PUBLISH_LINE="$(/usr/bin/grep -nF '/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"' \
  "$IOS_RELEASE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$IOS_METADATA_LINE" == <-> && "$IOS_PUBLISH_LINE" == <-> ]] \
  || fail "could not locate the staged metadata and publication operations"
(( IOS_METADATA_LINE < IOS_PUBLISH_LINE )) \
  || fail "iOS release must finish metadata before atomic publication"

print -r -- "Release-entrypoint hardening contract passed"
