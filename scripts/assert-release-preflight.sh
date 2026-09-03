#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 -r -- "Usage: ${0:t} developer-id|mac-app-store|mac-app-store-upload|mac-app-store-review|ios|ios-upload|ios-app-store-review READINESS_JSON"
}

fail() {
  print -u2 -r -- "Release preflight failed: $*"
  exit 2
}

(( $# == 2 )) || { usage; exit 64; }
CHANNEL="$1"
REPORT_PATH="$2"

[[ "$REPORT_PATH" == /* && -f "$REPORT_PATH" && ! -L "$REPORT_PATH" ]] \
  || fail "readiness report must be an absolute, regular, non-symlink file"
/usr/bin/jq -e 'type == "object"' "$REPORT_PATH" >/dev/null 2>&1 \
  || fail "readiness report is not valid JSON"

# This helper validates the channel predicate recorded in one readiness
# snapshot, then revalidates only that snapshot's immutable identity lock at
# each later action boundary. It does not claim that every mutable readiness
# input is unchanged. The inode check catches replacement while hashing; a
# byte-identical replacement is harmless, while path/link/content drift fails
# closed.
IDENTITY_LOCK_PATH="$(/usr/bin/jq -r \
  '.releaseIdentityLockPath // ""' "$REPORT_PATH")"
EXPECTED_IDENTITY_LOCK_SHA256="$(/usr/bin/jq -r \
  '.releaseIdentityLockSHA256 // ""' "$REPORT_PATH")"
[[ "$IDENTITY_LOCK_PATH" == /* && -f "$IDENTITY_LOCK_PATH" && \
  ! -L "$IDENTITY_LOCK_PATH" ]] \
  || fail "release identity lock is missing, non-absolute, or a symlink"
[[ "${IDENTITY_LOCK_PATH:a}" == "$IDENTITY_LOCK_PATH" && \
  "${IDENTITY_LOCK_PATH:A}" == "$IDENTITY_LOCK_PATH" ]] \
  || fail "release identity lock path is not canonical or traverses a symlink"
print -r -- "$EXPECTED_IDENTITY_LOCK_SHA256" | /usr/bin/grep -Eq \
  '^[0-9a-f]{64}$' \
  || fail "readiness report has no valid release identity lock SHA-256"
IDENTITY_LOCK_INODE_BEFORE="$(/usr/bin/stat -f '%d:%i' \
  "$IDENTITY_LOCK_PATH" 2>/dev/null || true)"
[[ "$IDENTITY_LOCK_INODE_BEFORE" == <->:<-> ]] \
  || fail "could not identify the release identity lock inode"
IDENTITY_LOCK_MODE_BEFORE="$(/usr/bin/stat -f '%Lp' \
  "$IDENTITY_LOCK_PATH" 2>/dev/null || true)"
[[ "$IDENTITY_LOCK_MODE_BEFORE" == <-> ]] \
  || fail "could not identify the release identity lock permissions"
(( (8#$IDENTITY_LOCK_MODE_BEFORE & 8#077) == 0 )) \
  || fail "release identity lock must not be accessible by group or other users"
ACTUAL_IDENTITY_LOCK_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$IDENTITY_LOCK_PATH" | /usr/bin/awk '{print $1}')"
IDENTITY_LOCK_MODE_AFTER="$(/usr/bin/stat -f '%Lp' \
  "$IDENTITY_LOCK_PATH" 2>/dev/null || true)"
[[ -f "$IDENTITY_LOCK_PATH" && ! -L "$IDENTITY_LOCK_PATH" && \
  "${IDENTITY_LOCK_PATH:a}" == "$IDENTITY_LOCK_PATH" && \
  "${IDENTITY_LOCK_PATH:A}" == "$IDENTITY_LOCK_PATH" && \
  "$IDENTITY_LOCK_INODE_BEFORE" == \
    "$(/usr/bin/stat -f '%d:%i' "$IDENTITY_LOCK_PATH" 2>/dev/null || true)" && \
  "$IDENTITY_LOCK_MODE_AFTER" == "$IDENTITY_LOCK_MODE_BEFORE" && \
  "$ACTUAL_IDENTITY_LOCK_SHA256" == "$EXPECTED_IDENTITY_LOCK_SHA256" ]] \
  || fail "release identity lock changed after the readiness report was generated"

case "$CHANNEL" in
  developer-id)
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityProfileRecordsPresent == true and
      .releaseIdentityAuxiliaryFilesMatch == true and
      .releaseIdentityProfileAssetsMatch == true and
      .releaseIdentityReady == true and
      .readyForDeveloperIDRelease == true
    '
    ;;
  mac-app-store)
    # Store candidate evidence is produced only after archive/export. Keep this
    # entrypoint bound to the locked identity and static target configuration,
    # without making candidate creation depend on its own future evidence.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .currentMacAppStoreToolchain == true and
      .macAppStoreStaticProjectValidationPassed == true and
      .macAppStoreXcodeProjectConfigured == true and
      .macAppStoreTargetMembershipConfigured == true and
      .macAppStoreRuntimeResourcesInTarget == true and
      .macAppStoreBuildSettingsMatch == true and
      .macPrivacyManifestInAppTarget == true and
      .macAppStoreInfoPlistConfigured == true and
      .macAppStoreEntitlementsConfigured == true and
      .readyForMacAppStoreArchive == true
    '
    ;;
  mac-app-store-upload)
    # Upload is allowed only for the exact locally verified package and its
    # candidate-bound QA/privacy evidence. Delivery acceptance, processing,
    # build selection, and App Review submission are necessarily later gates.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .readyForMacAppStoreArchive == true and
      .macAppStoreExactCandidateEvidenceReady == true and
      .macAppStoreLocalPreflightPassed == true and
      .macAppStoreFunctionalQAEvidenceReady == true and
      .macAppStoreFunctionalEvidenceBoundToCandidate == true and
      .macAppStoreSandboxFlowVerified == true and
      .macAppStoreArchiveVerified == true and
      .macAppStoreProfileCertificateVerified == true and
      .macAppStorePrivacyReportVerified == true and
      .macAppStoreReviewPathVerified == true and
      .cloudKitProductionSchemaVerified == true and
      .macPrivacyReleaseEvidenceReady == true and
      .macStoreSubmissionAssetsReady == true and
      .readyForMacAppStoreUpload == true
    '
    ;;
  mac-app-store-review)
    # Final local/operator gate before selecting the exact processed macOS
    # build in App Store Connect. This proves neither remote build selection
    # nor either of Apple's later Add for Review / Submit for Review actions.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .readyForMacAppStoreArchive == true and
      .macAppStoreExactCandidateEvidenceReady == true and
      .macAppStoreLocalPreflightPassed == true and
      .macAppStoreFunctionalQAEvidenceReady == true and
      .macAppStoreFunctionalEvidenceBoundToCandidate == true and
      .macAppStoreSandboxFlowVerified == true and
      .macAppStoreArchiveVerified == true and
      .macAppStoreProfileCertificateVerified == true and
      .macAppStorePrivacyReportVerified == true and
      .macAppStoreReviewPathVerified == true and
      .cloudKitProductionSchemaVerified == true and
      .macPrivacyReleaseEvidenceReady == true and
      .macStoreSubmissionAssetsReady == true and
      .appStoreRecordModeConfigured == true and
      .appStoreRecordModeBundleIDsValid == true and
      .readyForMacAppStoreUpload == true and
      .macAppStoreDeliveryEvidenceConfigured == true and
      .macAppStoreDeliveryEvidenceReady == true and
      .macAppStoreDeliveryBoundToCandidate == true and
      .macAppStoreUploadAccepted == true and
      (.macAppStoreDeliveryEvidencePath | type == "string" and startswith("/") and length > 1) and
      (.macAppStoreDeliveryEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.macAppStoreUploadSubmittedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .macAppStoreProcessingEvidenceConfigured == true and
      .macAppStoreProcessingEvidenceReady == true and
      .macAppStoreProcessingBoundToDelivery == true and
      .macAppStoreProcessingVerified == true and
      .macAppStoreProcessingState == "Complete" and
      (.macAppStoreProcessingEvidencePath | type == "string" and startswith("/") and length > 1) and
      (.macAppStoreProcessingEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.macAppStoreProcessingVerifiedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .macAppStoreWarningsReviewed == true and
      (.macAppStoreWarningsReviewedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .macAppStoreUploadSubmittedAt <= .macAppStoreProcessingVerifiedAt and
      .macAppStoreProcessingVerifiedAt == .macAppStoreWarningsReviewedAt and
      (.macAppStoreConnectBuildID | type == "string" and
        length > 0 and length <= 256 and test("^[^[:space:][:cntrl:]]+$")) and
      .macAppStoreAppReviewSubmissionRecorded == false and
      .readyForMacAppStoreReviewSelection == true
    '
    ;;
  ios)
    # readyForIOSArchive is intentionally an archive-time gate. It contains no
    # upload, processing, TestFlight-install, review, or candidate QA evidence.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .iosProjectReleaseValidationPassed == true and
      .iosBuildSettingsResolved == true and
      .iosTargetBuildSettingsConfigured == true and
      .iosProductionBuildSettingsConfigured == true and
      .iosBuildSettingsMatchEnvironment == true and
      .readyForIOSArchive == true
    '
    ;;
  ios-upload)
    # The caller adds iosUploadCandidate only after completing the exact local
    # IPA/profile/signature/privacy preflight. Compare that sealed candidate to
    # the current locked project identity; do not require later TestFlight
    # processing, distribution, installation, QA, or App Review evidence.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .readyForIOSArchive == true and
      .iosUploadCandidateLocalPreflightPassed == true and
      (.iosUploadCandidate | type == "object") and
      (.iosUploadCandidate.releaseDirectory | type == "string" and startswith("/") and length > 1) and
      (.iosUploadCandidate.metadataPath | type == "string" and startswith("/") and length > 1) and
      (.iosUploadCandidate.metadataSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.iosUploadCandidate.ipaPath | type == "string" and startswith("/") and length > 1) and
      (.iosUploadCandidate.ipaSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .iosUploadCandidate.releaseIdentityLockSHA256 == .releaseIdentityLockSHA256 and
      .iosUploadCandidate.appBundleID == .iosAppBundleID and
      .iosUploadCandidate.widgetBundleID == .iosWidgetBundleID and
      .iosUploadCandidate.teamID == .iosDevelopmentTeam and
      .iosUploadCandidate.cloudContainerID == .iosCloudKitContainer and
      .iosUploadCandidate.displayName == .iosDisplayName and
      .iosUploadCandidate.version == .iosMarketingVersion and
      .iosUploadCandidate.build == .iosBuildNumber
    '
    ;;
  ios-app-store-review)
    # This is a final local/operator gate before selecting the exact processed
    # build in App Store Connect. It intentionally does not claim that the build
    # has been selected, added for review, or submitted for review.
    PREDICATE='
      .releaseIdentityLockConfigured == true and
      .releaseIdentityLockValid == true and
      .releaseIdentityAppliedFilesMatch == true and
      .releaseIdentityMatchesConfiguration == true and
      (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .releaseIdentityReady == true and
      .readyForIOSArchive == true and
      .iosTestFlightExactBuildEvidenceReady == true and
      .iosFunctionalQAEvidenceReady == true and
      .iosFunctionalEvidenceBoundToCandidate == true and
      .iosTestFlightUploadVerified == true and
      .iosTestFlightProcessingVerified == true and
      (.iosTestFlightProcessingState == "VALID" or
        .iosTestFlightProcessingState == "Complete") and
      .iosTestFlightInstallVerified == true and
      .iosTestFlightWarningsReviewed == true and
      (.iosTestFlightWarningsReviewedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .iosPrivacyReleaseEvidenceReady == true and
      .iosStoreSubmissionAssetsReady == true and
      .appStoreRecordModeConfigured == true and
      .appStoreRecordModeBundleIDsValid == true and
      (.iosTestFlightAppStoreConnectBuildID | type == "string" and length > 0) and
      .readyForFunctionalIOSTestFlight == true and
      .readyForIOSAppStoreReviewSelection == true
    '
    ;;
  *)
    usage
    exit 64
    ;;
esac

if /usr/bin/jq -e "$PREDICATE" "$REPORT_PATH" >/dev/null 2>&1; then
  exit 0
fi

print -u2 -r -- "Release preflight failed: $CHANNEL prerequisites are not satisfied"
/usr/bin/jq '{
  releaseIdentityLockConfigured,
  releaseIdentityLockValid,
  releaseIdentityAppliedFilesMatch,
  releaseIdentityMatchesConfiguration,
  releaseIdentityLockPath,
  releaseIdentityLockSHA256,
  releaseIdentityProfileRecordsPresent,
  releaseIdentityAuxiliaryFilesMatch,
  releaseIdentityProfileAssetsMatch,
  releaseIdentityReady,
  iosProjectReleaseValidationPassed,
  iosBuildSettingsResolved,
  iosTargetBuildSettingsConfigured,
  iosProductionBuildSettingsConfigured,
  iosBuildSettingsMatchEnvironment,
  readyForDeveloperIDRelease,
  currentMacAppStoreToolchain,
  macAppStoreStaticProjectValidationPassed,
  macAppStoreXcodeProjectConfigured,
  macAppStoreTargetMembershipConfigured,
  macAppStoreRuntimeResourcesInTarget,
  macAppStoreBuildSettingsMatch,
  macPrivacyManifestInAppTarget,
  macAppStoreInfoPlistConfigured,
  macAppStoreEntitlementsConfigured,
  readyForMacAppStoreArchive,
  macAppStoreExactCandidateEvidenceReady,
  macAppStoreLocalPreflightPassed,
  macAppStoreFunctionalQAEvidenceReady,
  macAppStoreFunctionalEvidenceBoundToCandidate,
  macAppStoreSandboxFlowVerified,
  macAppStoreArchiveVerified,
  macAppStoreProfileCertificateVerified,
  macAppStorePrivacyReportVerified,
  macAppStoreReviewPathVerified,
  cloudKitProductionSchemaVerified,
  macPrivacyReleaseEvidenceReady,
  macStoreSubmissionAssetsReady,
  macStoreSubmissionBlockers,
  macStoreSubmissionStructuralErrors,
  iosStoreSubmissionAssetsReady,
  iosStoreSubmissionBlockers,
  iosStoreSubmissionStructuralErrors,
  storeSubmissionAssetsReady,
  readyForMacAppStoreUpload,
  macAppStoreDeliveryEvidenceConfigured,
  macAppStoreDeliveryEvidenceReady,
  macAppStoreDeliveryBoundToCandidate,
  macAppStoreDeliveryEvidencePath,
  macAppStoreDeliveryEvidenceSHA256,
  macAppStoreUploadAccepted,
  macAppStoreUploadSubmittedAt,
  macAppStoreProcessingEvidenceConfigured,
  macAppStoreProcessingEvidenceReady,
  macAppStoreProcessingBoundToDelivery,
  macAppStoreProcessingEvidencePath,
  macAppStoreProcessingEvidenceSHA256,
  macAppStoreProcessingState,
  macAppStoreProcessingVerified,
  macAppStoreProcessingVerifiedAt,
  macAppStoreWarningsReviewed,
  macAppStoreWarningsReviewedAt,
  macAppStoreConnectBuildID,
  macAppStoreAppReviewSubmissionRecorded,
  appStoreRecordModeConfigured,
  appStoreRecordModeBundleIDsValid,
  readyForMacAppStoreReviewSelection,
  readyForIOSArchive,
  iosTestFlightExactBuildEvidenceReady,
  iosTestFlightUploadVerified,
  iosTestFlightProcessingVerified,
  iosTestFlightProcessingState,
  iosTestFlightWarningsReviewed,
  iosTestFlightWarningsReviewedAt,
  iosTestFlightInstallVerified,
  iosTestFlightAppStoreConnectBuildID,
  iosFunctionalQAEvidenceReady,
  iosFunctionalEvidenceBoundToCandidate,
  iosPrivacyReleaseEvidenceReady,
  readyForFunctionalIOSTestFlight,
  readyForIOSAppStoreReviewSelection,
  iosUploadCandidateLocalPreflightPassed,
  iosUploadCandidate
}' "$REPORT_PATH" >&2 || true
exit 2
