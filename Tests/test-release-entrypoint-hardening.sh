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

sha256_file() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

iso_utc_seconds() {
  /bin/date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

iso_utc_milliseconds() {
  /bin/date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.123Z'
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

RELEASE_FIXTURE_ROOT="$TEST_ROOT/release-project"
/bin/mkdir -p "$RELEASE_FIXTURE_ROOT/.release"
FIXTURE_NOW_EPOCH="$(/bin/date -u '+%s')"
FIXTURE_CAPTURE_EPOCH="$(( FIXTURE_NOW_EPOCH - 60 ))"
FIXTURE_EXPIRES_EPOCH="$(( FIXTURE_CAPTURE_EPOCH + 900 ))"
FIXTURE_REVIEW_EPOCH="$(( FIXTURE_CAPTURE_EPOCH + 60 ))"
MAC_UPLOAD_SUBMITTED_AT="$(iso_utc_seconds "$(( FIXTURE_CAPTURE_EPOCH - 120 ))")"
MAC_PROCESSING_VERIFIED_AT="$(iso_utc_seconds "$FIXTURE_REVIEW_EPOCH")"
PUBLIC_OLDEST_CHECKED_AT="$(iso_utc_seconds "$FIXTURE_CAPTURE_EPOCH")"
PUBLIC_NEWEST_CHECKED_AT="$(iso_utc_seconds "$(( FIXTURE_CAPTURE_EPOCH + 1 ))")"
SUBMISSION_MANIFEST="$RELEASE_FIXTURE_ROOT/.release/app-store-submission.json"
MAC_APP_RESOURCE_ID="1234567890"
IOS_APP_RESOURCE_ID="1234567891"
MAC_APP_SKU="agent-island-macos"
IOS_APP_SKU="agent-island-ios"
APP_PRIMARY_LOCALE="zh-Hans"
/usr/bin/jq -n \
  --arg identitySHA "$IDENTITY_LOCK_SHA256" \
  --arg macAppID "$MAC_APP_RESOURCE_ID" \
  --arg iosAppID "$IOS_APP_RESOURCE_ID" \
  --arg macSKU "$MAC_APP_SKU" \
  --arg iosSKU "$IOS_APP_SKU" \
  --arg locale "$APP_PRIMARY_LOCALE" '{
  schemaVersion: 1,
  identityLockSHA256: $identitySHA,
  records: {
    macos: {appResourceId: $macAppID, sku: $macSKU, primaryLocale: $locale},
    ios: {appResourceId: $iosAppID, sku: $iosSKU, primaryLocale: $locale}
  }
}' >"$SUBMISSION_MANIFEST"
/bin/chmod 0444 "$SUBMISSION_MANIFEST"
SUBMISSION_MANIFEST_SHA256="$(sha256_file "$SUBMISSION_MANIFEST")"

PUBLIC_PAGES_EVIDENCE="$RELEASE_FIXTURE_ROOT/.release/public-pages-evidence.json"
/usr/bin/jq -n \
  --arg manifestSHA "$SUBMISSION_MANIFEST_SHA256" \
  --arg oldest "$PUBLIC_OLDEST_CHECKED_AT" \
  --arg newest "$PUBLIC_NEWEST_CHECKED_AT" '{
  schemaVersion: 1,
  evidenceType: "public-pages",
  productName: "MAC版灵动岛--Agent运行监测",
  configuredURLs: {
    privacy: "https://example.com/privacy/",
    support: "https://example.com/support/"
  },
  allowedOrigins: ["https://example.com"],
  binding: {
    type: "submission-manifest",
    path: ".release/app-store-submission.json",
    sha256: $manifestSHA
  },
  pages: [
    {
      kind: "privacy",
      configuredURL: "https://example.com/privacy/",
      finalURL: "https://example.com/privacy/",
      status: 200,
      contentType: "text/html; charset=utf-8",
      bodySizeBytes: 1024,
      bodySHA256: ("a" * 64),
      redirectCount: 0,
      checkedAt: $oldest,
      validations: {
        productName: true,
        bilingualLanguages: true,
        pagePurpose: true,
        contactOrDeletionPath: true
      }
    },
    {
      kind: "support",
      configuredURL: "https://example.com/support/",
      finalURL: "https://example.com/support/",
      status: 200,
      contentType: "text/html; charset=utf-8",
      bodySizeBytes: 2048,
      bodySHA256: ("b" * 64),
      redirectCount: 0,
      checkedAt: $newest,
      validations: {
        productName: true,
        bilingualLanguages: true,
        pagePurpose: true,
        contactOrDeletionPath: true
      }
    }
  ],
  createdAt: $newest
}' >"$PUBLIC_PAGES_EVIDENCE"
/bin/chmod 0444 "$PUBLIC_PAGES_EVIDENCE"
PUBLIC_PAGES_EVIDENCE_SHA256="$(sha256_file "$PUBLIC_PAGES_EVIDENCE")"

MAC_ASC_SNAPSHOT="$RELEASE_FIXTURE_ROOT/.release/mac-asc-build-snapshot.json"
MAC_ASC_EVIDENCE_SHA256="$(printf 'a%.0s' {1..64})"
MAC_ASC_CAPTURED_AT="$(iso_utc_milliseconds "$FIXTURE_CAPTURE_EPOCH")"
MAC_ASC_EXPIRES_AT="$(iso_utc_milliseconds "$FIXTURE_EXPIRES_EPOCH")"
MAC_ASC_BUILD_ID="fixture-mac-build-id"
MAC_BUNDLE_ID="com.agentisland.release"
MAC_MARKETING_VERSION="1.0.0"
MAC_BUILD_NUMBER="1"
/usr/bin/jq -n \
  --arg appID "$MAC_APP_RESOURCE_ID" \
  --arg sku "$MAC_APP_SKU" \
  --arg locale "$APP_PRIMARY_LOCALE" \
  --arg bundleID "$MAC_BUNDLE_ID" \
  --arg version "$MAC_MARKETING_VERSION" \
  --arg build "$MAC_BUILD_NUMBER" \
  --arg buildID "$MAC_ASC_BUILD_ID" \
  --arg evidenceSHA "$MAC_ASC_EVIDENCE_SHA256" \
  --arg identityPath "$IDENTITY_LOCK" \
  --arg identitySHA "$IDENTITY_LOCK_SHA256" \
  --arg capturedAt "$MAC_ASC_CAPTURED_AT" \
  --arg expiresAt "$MAC_ASC_EXPIRES_AT" '{
  schemaVersion: 1,
  kind: "app-store-connect-build-snapshot",
  readOnly: true,
  capturedAt: $capturedAt,
  expiresAt: $expiresAt,
  evidenceSHA256: $evidenceSHA,
  candidate: {
    releaseIdentityLockPath: $identityPath,
    releaseIdentityLockSHA256: $identitySHA
  },
  query: {bundleID: $bundleID, platform: "MAC_OS", version: $version, build: $build},
  resourceIDs: {
    app: $appID,
    preReleaseVersion: "fixture-mac-prerelease-id",
    build: $buildID,
    buildUpload: "fixture-mac-upload-id"
  },
  app: {resourceID: $appID, bundleID: $bundleID, sku: $sku, primaryLocale: $locale},
  preReleaseVersion: {
    resourceID: "fixture-mac-prerelease-id",
    version: $version,
    platform: "MAC_OS"
  },
  build: {
    resourceID: $buildID,
    buildNumber: $build,
    processingState: "VALID",
    expired: false,
    buildAudienceType: "APP_STORE_ELIGIBLE",
    usesNonExemptEncryption: false,
    exportComplianceRequired: false
  },
  buildUpload: {
    resourceID: "fixture-mac-upload-id",
    cfBundleShortVersionString: $version,
    cfBundleVersion: $build,
    platform: "MAC_OS",
    state: "COMPLETE",
    errors: [],
    warnings: [],
    warningsPresent: false,
    infos: []
  },
  readiness: {
    candidateBindingsVerified: true,
    appResourceUnique: true,
    preReleaseVersionExact: true,
    buildResourceUnique: true,
    buildProcessingValid: true,
    buildNotExpired: true,
    appStoreEligible: true,
    encryptionDeclarationResolved: true,
    exportComplianceRequired: false,
    buildUploadComplete: true,
    buildUploadErrorFree: true,
    warningsPresent: false,
    snapshotReady: true
  }
}' >"$MAC_ASC_SNAPSHOT"
/bin/chmod 0444 "$MAC_ASC_SNAPSHOT"
MAC_ASC_SNAPSHOT_SHA256="$(sha256_file "$MAC_ASC_SNAPSHOT")"

MAC_APP_STORE_REVIEW_REPORT="$TEST_ROOT/mac-app-store-review-ready.json"
/usr/bin/jq \
  --arg deliveryPath "$TEST_ROOT/mac-app-store-delivery.json" \
  --arg processingPath "$TEST_ROOT/mac-app-store-processing.json" \
  --arg manifestPath "$SUBMISSION_MANIFEST" \
  --arg manifestSHA "$SUBMISSION_MANIFEST_SHA256" \
  --arg publicPath "$PUBLIC_PAGES_EVIDENCE" \
  --arg publicSHA "$PUBLIC_PAGES_EVIDENCE_SHA256" \
  --arg publicOldest "$PUBLIC_OLDEST_CHECKED_AT" \
  --arg publicNewest "$PUBLIC_NEWEST_CHECKED_AT" \
  --arg appResourceID "$MAC_APP_RESOURCE_ID" \
  --arg appSKU "$MAC_APP_SKU" \
  --arg primaryLocale "$APP_PRIMARY_LOCALE" \
  --arg ascPath "$MAC_ASC_SNAPSHOT" \
  --arg ascSHA "$MAC_ASC_SNAPSHOT_SHA256" \
  --arg ascEvidenceSHA "$MAC_ASC_EVIDENCE_SHA256" \
  --arg ascCapturedAt "$MAC_ASC_CAPTURED_AT" \
  --arg ascExpiresAt "$MAC_ASC_EXPIRES_AT" \
  --arg ascBuildID "$MAC_ASC_BUILD_ID" \
  --arg uploadSubmittedAt "$MAC_UPLOAD_SUBMITTED_AT" \
  --arg processingVerifiedAt "$MAC_PROCESSING_VERIFIED_AT" '. + {
  productionBundleID: "com.agentisland.release",
  macMarketingVersion: "1.0.0",
  macBuildNumber: "1",
  appStoreRecordModeConfigured: true,
  appStoreRecordModeBundleIDsValid: true,
  macAppStoreDeliveryEvidenceConfigured: true,
  macAppStoreDeliveryEvidenceReady: true,
  macAppStoreDeliveryBoundToCandidate: true,
  macAppStoreDeliveryEvidencePath: $deliveryPath,
  macAppStoreDeliveryEvidenceSHA256: ("d" * 64),
  macAppStoreUploadAccepted: true,
  macAppStoreUploadSubmittedAt: $uploadSubmittedAt,
  macAppStoreProcessingEvidenceConfigured: true,
  macAppStoreProcessingEvidenceReady: true,
  macAppStoreProcessingBoundToDelivery: true,
  macAppStoreProcessingEvidencePath: $processingPath,
  macAppStoreProcessingEvidenceSHA256: ("e" * 64),
  macAppStoreProcessingState: "Complete",
  macAppStoreProcessingVerified: true,
  macAppStoreProcessingVerifiedAt: $processingVerifiedAt,
  macAppStoreWarningsReviewed: true,
  macAppStoreWarningsReviewedAt: $processingVerifiedAt,
  macAppStoreConnectBuildID: $ascBuildID,
  appStoreSubmissionManifestConfigured: true,
  appStoreSubmissionManifestReady: true,
  macAppStoreSubmissionManifestReady: true,
  appStoreSubmissionManifestPath: $manifestPath,
  appStoreSubmissionManifestSHA256: $manifestSHA,
  macAppStoreExpectedAppResourceID: $appResourceID,
  macAppStoreExpectedSKU: $appSKU,
  macAppStoreExpectedPrimaryLocale: $primaryLocale,
  publicPagesEvidenceConfigured: true,
  publicPagesEvidenceReady: true,
  publicPagesEvidenceBoundToSubmissionManifest: true,
  publicPagesEvidencePath: $publicPath,
  publicPagesEvidenceSHA256: $publicSHA,
  publicPagesEvidenceBindingType: "submission-manifest",
  publicPagesEvidenceBindingPath: $manifestPath,
  publicPagesEvidenceBindingSHA256: $manifestSHA,
  publicPagesEvidenceOldestCheckedAt: $publicOldest,
  publicPagesEvidenceNewestCheckedAt: $publicNewest,
  publicPagesEvidenceMaxAgeSeconds: 86400,
  appStoreConnectSnapshotMaxAgeValid: true,
  appStoreConnectSnapshotMaxAgeSeconds: 900,
  macAppStoreConnectBuildSnapshotConfigured: true,
  macAppStoreConnectBuildSnapshotReady: true,
  macAppStoreConnectBuildSnapshotPath: $ascPath,
  macAppStoreConnectBuildSnapshotSHA256: $ascSHA,
  macAppStoreConnectEvidenceSHA256: $ascEvidenceSHA,
  macAppStoreConnectBuildSnapshotCapturedAt: $ascCapturedAt,
  macAppStoreConnectBuildSnapshotExpiresAt: $ascExpiresAt,
  macAppStoreConnectBuildSnapshotAppResourceID: $appResourceID,
  macAppStoreConnectBuildSnapshotBuildResourceID: $ascBuildID,
  macAppStoreConnectBuildSnapshotWarningsPresent: false,
  macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity: true,
  macAppStoreConnectBuildSnapshotMatchesOperatorEvidence: true,
  macAppStoreConnectBuildSnapshotWarningReviewCurrent: true,
  macAppStoreConnectRemoteMetadataComparisonComplete: true,
  macAppStoreConnectBuildSnapshotExportComplianceRequired: false,
  macAppStoreConnectBuildSnapshotBuildUploadErrorFree: true,
  macAppStoreAppReviewSubmissionRecorded: false,
  readyForMacAppStoreReviewSelection: true
}' "$MAC_APP_STORE_UPLOAD_REPORT" >"$MAC_APP_STORE_REVIEW_REPORT"
"$PREFLIGHT" mac-app-store-review "$MAC_APP_STORE_REVIEW_REPORT"

/bin/chmod 0644 "$SUBMISSION_MANIFEST"
expect_rejected "Mac App Store review with writable submission manifest" \
  "$PREFLIGHT" mac-app-store-review "$MAC_APP_STORE_REVIEW_REPORT"
/bin/chmod 0444 "$SUBMISSION_MANIFEST"
/bin/chmod 0644 "$PUBLIC_PAGES_EVIDENCE"
expect_rejected "Mac App Store review with writable public-pages evidence" \
  "$PREFLIGHT" mac-app-store-review "$MAC_APP_STORE_REVIEW_REPORT"
/bin/chmod 0444 "$PUBLIC_PAGES_EVIDENCE"
/bin/chmod 0644 "$MAC_ASC_SNAPSHOT"
expect_rejected "Mac App Store review with writable ASC snapshot" \
  "$PREFLIGHT" mac-app-store-review "$MAC_APP_STORE_REVIEW_REPORT"
/bin/chmod 0444 "$MAC_ASC_SNAPSHOT"

INVALID_PUBLIC_EVIDENCE="$RELEASE_FIXTURE_ROOT/.release/public-pages-invalid.json"
/usr/bin/jq '.pages[0].validations.productName = false' \
  "$PUBLIC_PAGES_EVIDENCE" >"$INVALID_PUBLIC_EVIDENCE"
/bin/chmod 0444 "$INVALID_PUBLIC_EVIDENCE"
INVALID_PUBLIC_SHA="$(sha256_file "$INVALID_PUBLIC_EVIDENCE")"
INVALID_REPORT="$TEST_ROOT/mac-app-store-review-invalid-public-semantics.json"
/usr/bin/jq --arg path "$INVALID_PUBLIC_EVIDENCE" --arg sha "$INVALID_PUBLIC_SHA" '
  .publicPagesEvidencePath = $path |
  .publicPagesEvidenceSHA256 = $sha
' "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "Mac App Store review with false public-page validation" \
  "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"

HIDDEN_ERROR_ASC="$RELEASE_FIXTURE_ROOT/.release/mac-asc-hidden-error.json"
/usr/bin/jq '.buildUpload.errors = [{message: "hidden fixture error"}]' \
  "$MAC_ASC_SNAPSHOT" >"$HIDDEN_ERROR_ASC"
/bin/chmod 0444 "$HIDDEN_ERROR_ASC"
HIDDEN_ERROR_ASC_SHA="$(sha256_file "$HIDDEN_ERROR_ASC")"
INVALID_REPORT="$TEST_ROOT/mac-app-store-review-hidden-asc-error.json"
/usr/bin/jq --arg path "$HIDDEN_ERROR_ASC" --arg sha "$HIDDEN_ERROR_ASC_SHA" '
  .macAppStoreConnectBuildSnapshotPath = $path |
  .macAppStoreConnectBuildSnapshotSHA256 = $sha
' "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "Mac App Store review with a hidden ASC upload error" \
  "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"

HIDDEN_WARNING_ASC="$RELEASE_FIXTURE_ROOT/.release/mac-asc-hidden-warning.json"
/usr/bin/jq '.buildUpload.warnings = [{message: "hidden fixture warning"}]' \
  "$MAC_ASC_SNAPSHOT" >"$HIDDEN_WARNING_ASC"
/bin/chmod 0444 "$HIDDEN_WARNING_ASC"
HIDDEN_WARNING_ASC_SHA="$(sha256_file "$HIDDEN_WARNING_ASC")"
INVALID_REPORT="$TEST_ROOT/mac-app-store-review-hidden-asc-warning.json"
/usr/bin/jq --arg path "$HIDDEN_WARNING_ASC" --arg sha "$HIDDEN_WARNING_ASC_SHA" '
  .macAppStoreConnectBuildSnapshotPath = $path |
  .macAppStoreConnectBuildSnapshotSHA256 = $sha
' "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "Mac App Store review with a hidden ASC warning" \
  "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"

MISMATCHED_ENCRYPTION_ASC="$RELEASE_FIXTURE_ROOT/.release/mac-asc-encryption-mismatch.json"
/usr/bin/jq '.build.usesNonExemptEncryption = true' \
  "$MAC_ASC_SNAPSHOT" >"$MISMATCHED_ENCRYPTION_ASC"
/bin/chmod 0444 "$MISMATCHED_ENCRYPTION_ASC"
MISMATCHED_ENCRYPTION_ASC_SHA="$(sha256_file "$MISMATCHED_ENCRYPTION_ASC")"
INVALID_REPORT="$TEST_ROOT/mac-app-store-review-asc-encryption-mismatch.json"
/usr/bin/jq --arg path "$MISMATCHED_ENCRYPTION_ASC" \
  --arg sha "$MISMATCHED_ENCRYPTION_ASC_SHA" '
  .macAppStoreConnectBuildSnapshotPath = $path |
  .macAppStoreConnectBuildSnapshotSHA256 = $sha
' "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "Mac App Store review with mismatched ASC encryption state" \
  "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"

for field in \
    releaseIdentityReady \
    readyForMacAppStoreArchive \
    macAppStoreExactCandidateEvidenceReady \
    macAppStoreLocalPreflightPassed \
    macAppStoreFunctionalQAEvidenceReady \
    macAppStoreFunctionalEvidenceBoundToCandidate \
    cloudKitProductionSchemaVerified \
    macPrivacyReleaseEvidenceReady \
    macStoreSubmissionAssetsReady \
    appStoreRecordModeConfigured \
    appStoreRecordModeBundleIDsValid \
    readyForMacAppStoreUpload \
    macAppStoreDeliveryEvidenceConfigured \
    macAppStoreDeliveryEvidenceReady \
    macAppStoreDeliveryBoundToCandidate \
    macAppStoreUploadAccepted \
    macAppStoreProcessingEvidenceConfigured \
    macAppStoreProcessingEvidenceReady \
    macAppStoreProcessingBoundToDelivery \
    macAppStoreProcessingVerified \
    macAppStoreWarningsReviewed \
    appStoreSubmissionManifestConfigured \
    appStoreSubmissionManifestReady \
    macAppStoreSubmissionManifestReady \
    publicPagesEvidenceConfigured \
    publicPagesEvidenceReady \
    publicPagesEvidenceBoundToSubmissionManifest \
    appStoreConnectSnapshotMaxAgeValid \
    macAppStoreConnectBuildSnapshotConfigured \
    macAppStoreConnectBuildSnapshotReady \
    macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity \
    macAppStoreConnectBuildSnapshotMatchesOperatorEvidence \
    macAppStoreConnectBuildSnapshotWarningReviewCurrent \
    macAppStoreConnectRemoteMetadataComparisonComplete \
    macAppStoreConnectBuildSnapshotBuildUploadErrorFree \
    readyForMacAppStoreReviewSelection; do
  INVALID_REPORT="$TEST_ROOT/mac-app-store-review-$field-false.json"
  /usr/bin/jq --arg field "$field" '.[$field] = false' \
    "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
  expect_rejected "Mac App Store review report with $field=false" \
    "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"
done

for expression in \
    '.macAppStoreProcessingState = "PROCESSING"' \
    '.macAppStoreConnectBuildID = ""' \
    '.macAppStoreConnectBuildID = "bad build id"' \
    '.macAppStoreDeliveryEvidencePath = "relative.json"' \
    '.macAppStoreDeliveryEvidenceSHA256 = "bad-sha"' \
    '.macAppStoreProcessingEvidencePath = "relative.json"' \
    '.macAppStoreProcessingEvidenceSHA256 = "bad-sha"' \
    '.macAppStoreUploadSubmittedAt = "not-a-time"' \
    '.macAppStoreProcessingVerifiedAt = "not-a-time"' \
    '.macAppStoreWarningsReviewedAt = "not-a-time"' \
    '.appStoreSubmissionManifestPath = "relative.json"' \
    '.appStoreSubmissionManifestSHA256 = ("0" * 64)' \
    '.macAppStoreExpectedAppResourceID = "1234567899" | .macAppStoreConnectBuildSnapshotAppResourceID = "1234567899"' \
    '.macAppStoreExpectedSKU = "other-sku"' \
    '.macAppStoreExpectedPrimaryLocale = "en-US"' \
    '.publicPagesEvidencePath = "relative.json"' \
    '.publicPagesEvidenceSHA256 = ("0" * 64)' \
    '.publicPagesEvidenceBindingType = "identity-lock"' \
    '.publicPagesEvidenceBindingPath = "/wrong/app-store-submission.json"' \
    '.publicPagesEvidenceBindingSHA256 = ("0" * 64)' \
    '.publicPagesEvidenceOldestCheckedAt = "not-a-time"' \
    '.publicPagesEvidenceNewestCheckedAt = "not-a-time"' \
    '.publicPagesEvidenceMaxAgeSeconds = 1' \
    '.appStoreConnectSnapshotMaxAgeValid = false' \
    '.appStoreConnectSnapshotMaxAgeSeconds = 30' \
    '.macAppStoreConnectBuildSnapshotPath = "relative.json"' \
    '.macAppStoreConnectBuildSnapshotSHA256 = ("0" * 64)' \
    '.macAppStoreConnectEvidenceSHA256 = ("0" * 64)' \
    '.macAppStoreConnectBuildSnapshotAppResourceID = "1234567899"' \
    '.macAppStoreConnectBuildSnapshotBuildResourceID = "other-build-id"' \
    '.macAppStoreConnectBuildSnapshotWarningsPresent = true' \
    '.macAppStoreConnectBuildSnapshotCapturedAt = "not-a-time"' \
    '.macAppStoreConnectBuildSnapshotExpiresAt = "not-a-time"' \
    '.macAppStoreConnectBuildSnapshotExpiresAt = .macAppStoreConnectBuildSnapshotCapturedAt' \
    '.macAppStoreConnectBuildSnapshotExportComplianceRequired = true' \
    '.macAppStoreUploadSubmittedAt = ((.macAppStoreProcessingVerifiedAt | fromdateiso8601) + 60 | todateiso8601)' \
    '.macAppStoreWarningsReviewedAt = .macAppStoreUploadSubmittedAt' \
    '.macAppStoreAppReviewSubmissionRecorded = true'; do
  INVALID_REPORT="$TEST_ROOT/mac-app-store-review-$RANDOM.json"
  /usr/bin/jq "$expression" "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
  expect_rejected "Mac App Store review report mutation: $expression" \
    "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"
done

SUBMISSION_MANIFEST_BASELINE="$TEST_ROOT/app-store-submission.baseline.json"
/bin/cp "$SUBMISSION_MANIFEST" "$SUBMISSION_MANIFEST_BASELINE"
/bin/chmod 0644 "$SUBMISSION_MANIFEST"
print -r -- 'changed after readiness' >>"$SUBMISSION_MANIFEST"
expect_rejected "Mac App Store review with changed submission manifest" \
  "$PREFLIGHT" mac-app-store-review "$MAC_APP_STORE_REVIEW_REPORT"
/bin/cp "$SUBMISSION_MANIFEST_BASELINE" "$SUBMISSION_MANIFEST"
/bin/chmod 0444 "$SUBMISSION_MANIFEST"

PUBLIC_PAGES_SYMLINK="$RELEASE_FIXTURE_ROOT/.release/public-pages-evidence-link.json"
/bin/ln -s "$PUBLIC_PAGES_EVIDENCE" "$PUBLIC_PAGES_SYMLINK"
INVALID_REPORT="$TEST_ROOT/mac-app-store-review-public-symlink.json"
/usr/bin/jq --arg path "$PUBLIC_PAGES_SYMLINK" \
  '.publicPagesEvidencePath = $path' "$MAC_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
expect_rejected "Mac App Store review with symlink public-pages evidence" \
  "$PREFLIGHT" mac-app-store-review "$INVALID_REPORT"

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

IOS_ASC_SNAPSHOT="$RELEASE_FIXTURE_ROOT/.release/ios-asc-build-snapshot.json"
IOS_ASC_EVIDENCE_SHA256="$(printf 'b%.0s' {1..64})"
IOS_ASC_CAPTURED_AT="$(iso_utc_milliseconds "$FIXTURE_CAPTURE_EPOCH")"
IOS_ASC_EXPIRES_AT="$(iso_utc_milliseconds "$FIXTURE_EXPIRES_EPOCH")"
IOS_WARNINGS_REVIEWED_AT="$(iso_utc_seconds "$FIXTURE_REVIEW_EPOCH")"
IOS_ASC_BUILD_ID="fixture-ios-build-id"
/usr/bin/jq -n \
  --arg appID "$IOS_APP_RESOURCE_ID" \
  --arg sku "$IOS_APP_SKU" \
  --arg locale "$APP_PRIMARY_LOCALE" \
  --arg bundleID "com.agentisland.release" \
  --arg version "1.0.0" \
  --arg build "1" \
  --arg buildID "$IOS_ASC_BUILD_ID" \
  --arg evidenceSHA "$IOS_ASC_EVIDENCE_SHA256" \
  --arg identityPath "$IDENTITY_LOCK" \
  --arg identitySHA "$IDENTITY_LOCK_SHA256" \
  --arg capturedAt "$IOS_ASC_CAPTURED_AT" \
  --arg expiresAt "$IOS_ASC_EXPIRES_AT" '{
  schemaVersion: 1,
  kind: "app-store-connect-build-snapshot",
  readOnly: true,
  capturedAt: $capturedAt,
  expiresAt: $expiresAt,
  evidenceSHA256: $evidenceSHA,
  candidate: {
    releaseIdentityLockPath: $identityPath,
    releaseIdentityLockSHA256: $identitySHA
  },
  query: {bundleID: $bundleID, platform: "IOS", version: $version, build: $build},
  resourceIDs: {
    app: $appID,
    preReleaseVersion: "fixture-ios-prerelease-id",
    build: $buildID,
    buildUpload: "fixture-ios-upload-id"
  },
  app: {resourceID: $appID, bundleID: $bundleID, sku: $sku, primaryLocale: $locale},
  preReleaseVersion: {
    resourceID: "fixture-ios-prerelease-id",
    version: $version,
    platform: "IOS"
  },
  build: {
    resourceID: $buildID,
    buildNumber: $build,
    processingState: "VALID",
    expired: false,
    buildAudienceType: "APP_STORE_ELIGIBLE",
    usesNonExemptEncryption: false,
    exportComplianceRequired: false
  },
  buildUpload: {
    resourceID: "fixture-ios-upload-id",
    cfBundleShortVersionString: $version,
    cfBundleVersion: $build,
    platform: "IOS",
    state: "COMPLETE",
    errors: [],
    warnings: [{message: "fixture warning"}],
    warningsPresent: true,
    infos: []
  },
  readiness: {
    candidateBindingsVerified: true,
    appResourceUnique: true,
    preReleaseVersionExact: true,
    buildResourceUnique: true,
    buildProcessingValid: true,
    buildNotExpired: true,
    appStoreEligible: true,
    encryptionDeclarationResolved: true,
    exportComplianceRequired: false,
    buildUploadComplete: true,
    buildUploadErrorFree: true,
    warningsPresent: true,
    snapshotReady: true
  }
}' >"$IOS_ASC_SNAPSHOT"
/bin/chmod 0444 "$IOS_ASC_SNAPSHOT"
IOS_ASC_SNAPSHOT_SHA256="$(sha256_file "$IOS_ASC_SNAPSHOT")"

IOS_APP_STORE_REVIEW_REPORT="$TEST_ROOT/ios-app-store-review-ready.json"
/usr/bin/jq \
  --arg manifestPath "$SUBMISSION_MANIFEST" \
  --arg manifestSHA "$SUBMISSION_MANIFEST_SHA256" \
  --arg publicPath "$PUBLIC_PAGES_EVIDENCE" \
  --arg publicSHA "$PUBLIC_PAGES_EVIDENCE_SHA256" \
  --arg publicOldest "$PUBLIC_OLDEST_CHECKED_AT" \
  --arg publicNewest "$PUBLIC_NEWEST_CHECKED_AT" \
  --arg appResourceID "$IOS_APP_RESOURCE_ID" \
  --arg appSKU "$IOS_APP_SKU" \
  --arg primaryLocale "$APP_PRIMARY_LOCALE" \
  --arg ascPath "$IOS_ASC_SNAPSHOT" \
  --arg ascSHA "$IOS_ASC_SNAPSHOT_SHA256" \
  --arg ascEvidenceSHA "$IOS_ASC_EVIDENCE_SHA256" \
  --arg ascCapturedAt "$IOS_ASC_CAPTURED_AT" \
  --arg ascExpiresAt "$IOS_ASC_EXPIRES_AT" \
  --arg ascBuildID "$IOS_ASC_BUILD_ID" \
  --arg warningsReviewedAt "$IOS_WARNINGS_REVIEWED_AT" '. + {
  iosTestFlightExactBuildEvidenceReady: true,
  iosFunctionalQAEvidenceReady: true,
  iosFunctionalEvidenceBoundToCandidate: true,
  iosTestFlightUploadVerified: true,
  iosTestFlightProcessingVerified: true,
  iosTestFlightProcessingState: "VALID",
  iosTestFlightInstallVerified: true,
  iosTestFlightWarningsReviewed: true,
  iosTestFlightWarningsReviewedAt: $warningsReviewedAt,
  iosPrivacyReleaseEvidenceReady: true,
  iosStoreSubmissionAssetsReady: true,
  macStoreSubmissionAssetsReady: false,
  storeSubmissionAssetsReady: false,
  appStoreRecordModeConfigured: true,
  appStoreRecordModeBundleIDsValid: true,
  iosTestFlightAppStoreConnectBuildID: $ascBuildID,
  appStoreSubmissionManifestConfigured: true,
  appStoreSubmissionManifestReady: true,
  iosAppStoreSubmissionManifestReady: true,
  appStoreSubmissionManifestPath: $manifestPath,
  appStoreSubmissionManifestSHA256: $manifestSHA,
  iosAppStoreExpectedAppResourceID: $appResourceID,
  iosAppStoreExpectedSKU: $appSKU,
  iosAppStoreExpectedPrimaryLocale: $primaryLocale,
  publicPagesEvidenceConfigured: true,
  publicPagesEvidenceReady: true,
  publicPagesEvidenceBoundToSubmissionManifest: true,
  publicPagesEvidencePath: $publicPath,
  publicPagesEvidenceSHA256: $publicSHA,
  publicPagesEvidenceBindingType: "submission-manifest",
  publicPagesEvidenceBindingPath: $manifestPath,
  publicPagesEvidenceBindingSHA256: $manifestSHA,
  publicPagesEvidenceOldestCheckedAt: $publicOldest,
  publicPagesEvidenceNewestCheckedAt: $publicNewest,
  publicPagesEvidenceMaxAgeSeconds: 86400,
  appStoreConnectSnapshotMaxAgeValid: true,
  appStoreConnectSnapshotMaxAgeSeconds: 900,
  iosAppStoreConnectBuildSnapshotConfigured: true,
  iosAppStoreConnectBuildSnapshotReady: true,
  iosAppStoreConnectBuildSnapshotPath: $ascPath,
  iosAppStoreConnectBuildSnapshotSHA256: $ascSHA,
  iosAppStoreConnectEvidenceSHA256: $ascEvidenceSHA,
  iosAppStoreConnectBuildSnapshotCapturedAt: $ascCapturedAt,
  iosAppStoreConnectBuildSnapshotExpiresAt: $ascExpiresAt,
  iosAppStoreConnectBuildSnapshotAppResourceID: $appResourceID,
  iosAppStoreConnectBuildSnapshotBuildResourceID: $ascBuildID,
  iosAppStoreConnectBuildSnapshotWarningsPresent: true,
  iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity: true,
  iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence: true,
  iosAppStoreConnectBuildSnapshotWarningReviewCurrent: true,
  iosAppStoreConnectRemoteMetadataComparisonComplete: true,
  iosAppStoreConnectBuildSnapshotExportComplianceRequired: false,
  iosAppStoreConnectBuildSnapshotBuildUploadErrorFree: true,
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
    appStoreSubmissionManifestConfigured \
    appStoreSubmissionManifestReady \
    iosAppStoreSubmissionManifestReady \
    publicPagesEvidenceConfigured \
    publicPagesEvidenceReady \
    publicPagesEvidenceBoundToSubmissionManifest \
    appStoreConnectSnapshotMaxAgeValid \
    iosAppStoreConnectBuildSnapshotConfigured \
    iosAppStoreConnectBuildSnapshotReady \
    iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity \
    iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence \
    iosAppStoreConnectBuildSnapshotWarningReviewCurrent \
    iosAppStoreConnectRemoteMetadataComparisonComplete \
    iosAppStoreConnectBuildSnapshotBuildUploadErrorFree \
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

for expression in \
    '.appStoreSubmissionManifestPath = "relative.json"' \
    '.appStoreSubmissionManifestSHA256 = ("0" * 64)' \
    '.iosAppStoreExpectedAppResourceID = "1234567899" | .iosAppStoreConnectBuildSnapshotAppResourceID = "1234567899"' \
    '.iosAppStoreExpectedSKU = "other-sku"' \
    '.iosAppStoreExpectedPrimaryLocale = "en-US"' \
    '.publicPagesEvidencePath = "relative.json"' \
    '.publicPagesEvidenceSHA256 = ("0" * 64)' \
    '.publicPagesEvidenceBindingType = "identity-lock"' \
    '.publicPagesEvidenceBindingPath = "/wrong/app-store-submission.json"' \
    '.publicPagesEvidenceBindingSHA256 = ("0" * 64)' \
    '.publicPagesEvidenceOldestCheckedAt = "not-a-time"' \
    '.publicPagesEvidenceNewestCheckedAt = "not-a-time"' \
    '.publicPagesEvidenceMaxAgeSeconds = 1' \
    '.appStoreConnectSnapshotMaxAgeValid = false' \
    '.appStoreConnectSnapshotMaxAgeSeconds = 30' \
    '.iosAppStoreConnectBuildSnapshotPath = "relative.json"' \
    '.iosAppStoreConnectBuildSnapshotSHA256 = ("0" * 64)' \
    '.iosAppStoreConnectEvidenceSHA256 = ("0" * 64)' \
    '.iosAppStoreConnectBuildSnapshotAppResourceID = "1234567899"' \
    '.iosAppStoreConnectBuildSnapshotBuildResourceID = "other-build-id"' \
    '.iosAppStoreConnectBuildSnapshotWarningsPresent = false' \
    '.iosAppStoreConnectBuildSnapshotCapturedAt = "not-a-time"' \
    '.iosAppStoreConnectBuildSnapshotExpiresAt = "not-a-time"' \
    '.iosAppStoreConnectBuildSnapshotExpiresAt = .iosAppStoreConnectBuildSnapshotCapturedAt' \
    '.iosAppStoreConnectBuildSnapshotExportComplianceRequired = true' \
    '.iosTestFlightWarningsReviewedAt = "2000-01-01T00:00:00Z"'; do
  INVALID_REPORT="$TEST_ROOT/ios-app-store-review-new-evidence-$RANDOM.json"
  /usr/bin/jq "$expression" "$IOS_APP_STORE_REVIEW_REPORT" >"$INVALID_REPORT"
  expect_rejected "iOS App Store review report evidence mutation: $expression" \
    "$PREFLIGHT" ios-app-store-review "$INVALID_REPORT"
done

IOS_ASC_BASELINE="$TEST_ROOT/ios-asc-build-snapshot.baseline.json"
/bin/cp "$IOS_ASC_SNAPSHOT" "$IOS_ASC_BASELINE"
/bin/chmod 0644 "$IOS_ASC_SNAPSHOT"
print -r -- 'changed after readiness' >>"$IOS_ASC_SNAPSHOT"
expect_rejected "iOS App Store review with changed ASC snapshot" \
  "$PREFLIGHT" ios-app-store-review "$IOS_APP_STORE_REVIEW_REPORT"
/bin/cp "$IOS_ASC_BASELINE" "$IOS_ASC_SNAPSHOT"
/bin/chmod 0444 "$IOS_ASC_SNAPSHOT"

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
/bin/mkdir "$TEST_ROOT/readiness-parent"
/bin/cp "$IOS_REPORT" "$TEST_ROOT/readiness-parent/ios-ready.json"
/bin/ln -s "$TEST_ROOT/readiness-parent" "$TEST_ROOT/readiness-parent-link"
expect_rejected "readiness report path traversing a symlink" \
  "$PREFLIGHT" ios "$TEST_ROOT/readiness-parent-link/ios-ready.json"
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

contains 'ApplicationIdentifierPrefix.0' "$MAC_RELEASE"
contains '"$PROFILE_APP_IDENTIFIER" == "$PROFILE_APP_ID_PREFIX.$BUNDLE_ID"' \
  "$MAC_RELEASE"
if /usr/bin/grep -Fq '"$SOURCE_APP_IDENTIFIER" == "$TEAM_ID.$BUNDLE_ID"' \
    "$MAC_RELEASE"; then
  fail "Developer ID entrypoint still assumes App ID prefix equals TeamIdentifier"
fi

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
    'TEMPORARY_ROOT="${TEMPORARY_ROOT_INPUT:A}"' \
    'WORK_DIR="$(mktemp -d "$TEMPORARY_ROOT/agentisland-ios-release.XXXXXX")"' \
    'WORK_DIR="${WORK_DIR:A}"' \
    '"$WORK_DIR" == "$TEMPORARY_ROOT"/agentisland-ios-release.*' \
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
