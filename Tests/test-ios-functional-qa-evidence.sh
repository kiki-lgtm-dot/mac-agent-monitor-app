#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
GENERATOR_SOURCE="$PROJECT_ROOT/ApplePlatforms/iOS/scripts/confirm-functional-qa-evidence.sh"
VALIDATOR_SOURCE="$PROJECT_ROOT/ApplePlatforms/iOS/scripts/validate-functional-qa-evidence.sh"
TESTFLIGHT_CONFIRM_SOURCE="$PROJECT_ROOT/ApplePlatforms/iOS/scripts/confirm-testflight-evidence.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-ios-functional-evidence-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "iOS functional QA evidence test failed: $*"
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
[[ -x "$TESTFLIGHT_CONFIRM_SOURCE" ]] \
  || fail "TestFlight evidence confirmation script is missing or not executable"
/bin/zsh -n "$GENERATOR_SOURCE"
/bin/zsh -n "$VALIDATOR_SOURCE"
/bin/zsh -n "$TESTFLIGHT_CONFIRM_SOURCE"

for marker in \
  'AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA' \
  'all four functional QA results must be exactly passed' \
  'four distinct evidence attachments' \
  'refusing to overwrite an existing iOS functional QA evidence file' \
  '/bin/ln -h "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH"' \
  '/bin/chmod 0444 "$TEMP_EVIDENCE_PATH"' \
  'device:inode identities' \
  'distinct content SHA-256 values' \
  'content cannot duplicate a core release artifact' \
  'testFlightVerification' \
  'sameICloudAccountConfirmed: true' \
  'macToIPhoneSyncConfirmed: true' \
  'realDeviceConfirmed: true' \
  'exampleModeConfirmed: true' \
  'productionPathConfirmed: true'; do
  contains "$marker" "$GENERATOR_SOURCE"
done
for marker in \
  'submit-testflight.sh" --check' \
  'current IPA SHA-256 differs from the TestFlight verification evidence' \
  'functional QA evidence must be read-only' \
  'functional QA evidence candidate does not match the exact TestFlight IPA' \
  'functional QA timestamps precede TestFlight installation or are in the future' \
  'QA attachment SHA-256 does not match the functional QA record' \
  'verify_app_store_result_success_json' \
  'require_shared_delivery_stamp' \
  'device:inode identities' \
  'distinct content SHA-256 values' \
  'cloudKitProductionSchemaVerified: true' \
  'realDeviceSyncVerified: true' \
  'liveActivityVerified: true' \
  'reviewPathVerified: true'; do
  contains "$marker" "$VALIDATOR_SOURCE"
done
for marker in \
  'verify_app_store_result_success_json' \
  'require_shared_delivery_stamp' \
  'stored App Store Connect $operation result is not an unambiguous success response' \
  '/bin/chmod 0444 "$TEMP_EVIDENCE_PATH"' \
  'publish_readonly_no_overwrite "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH"'; do
  contains "$marker" "$TESTFLIGHT_CONFIRM_SOURCE"
done
for script in "$GENERATOR_SOURCE" "$VALIDATOR_SOURCE" "$TESTFLIGHT_CONFIRM_SOURCE"; do
  for forbidden_marker in '/usr/bin/xcrun' 'altool' 'iTMSTransporter' '/usr/bin/curl'; do
    if /usr/bin/grep -Fq -- "$forbidden_marker" "$script"; then
      fail "${script:t} must remain local-only and contains $forbidden_marker"
    fi
  done
done

INSTRUMENTED_ROOT="$TEST_ROOT/ApplePlatforms/iOS"
INSTRUMENTED_SCRIPTS="$INSTRUMENTED_ROOT/scripts"
GENERATOR="$INSTRUMENTED_SCRIPTS/confirm-functional-qa-evidence.sh"
VALIDATOR="$INSTRUMENTED_SCRIPTS/validate-functional-qa-evidence.sh"
TESTFLIGHT_CONFIRM="$INSTRUMENTED_SCRIPTS/confirm-testflight-evidence.sh"
/bin/mkdir -p "$INSTRUMENTED_SCRIPTS"
/bin/cp "$GENERATOR_SOURCE" "$GENERATOR"
/bin/cp "$VALIDATOR_SOURCE" "$VALIDATOR"
/bin/cp "$TESTFLIGHT_CONFIRM_SOURCE" "$TESTFLIGHT_CONFIRM"

# The evidence tools must only invoke submit-testflight.sh in local --check
# mode. A strict stub keeps this unit test independent of Xcode/signing while
# still verifying that the exact release directory is passed through.
/bin/cat >"$INSTRUMENTED_SCRIPTS/submit-testflight.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "--check" \
    && "$2" == "$AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY" ]] || exit 64
[[ -f "$2/release-metadata.json" ]] || exit 65
EOF
/bin/chmod 0755 "$GENERATOR" "$VALIDATOR" "$TESTFLIGHT_CONFIRM" \
  "$INSTRUMENTED_SCRIPTS/submit-testflight.sh"

RELEASE_DIRECTORY="$TEST_ROOT/release"
/bin/mkdir -p "$RELEASE_DIRECTORY"
export AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$RELEASE_DIRECTORY"

APP_BUNDLE_ID="com.agentisland.release"
VERSION="1.2.3"
BUILD_NUMBER="42"
ASC_BUILD_ID="1234567890"
IPA_PATH="$RELEASE_DIRECTORY/AgentIsland.ipa"
METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"
DELIVERY_STAMP="20260904T000000Z"
VALIDATION_RESULT_PATH="$RELEASE_DIRECTORY/testflight-validation-$DELIVERY_STAMP.json"
UPLOAD_RESULT_PATH="$RELEASE_DIRECTORY/testflight-upload-$DELIVERY_STAMP.json"
DELIVERY_RECORD_PATH="$RELEASE_DIRECTORY/testflight-delivery-$DELIVERY_STAMP.json"
FUNCTIONAL_EVIDENCE_PATH="$RELEASE_DIRECTORY/ios-functional-verification-test.json"

print -n -r -- 'exact signed IPA fixture' >"$IPA_PATH"
IPA_SHA256="$(file_sha256 "$IPA_PATH")"
/usr/bin/jq -n '{"success-message": "validation accepted", "product-errors": null}' \
  >"$VALIDATION_RESULT_PATH"
/usr/bin/jq -n '{"success-message": "upload accepted", errors: []}' \
  >"$UPLOAD_RESULT_PATH"
/bin/chmod 0444 "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH"
VALIDATION_RESULT_SHA256="$(file_sha256 "$VALIDATION_RESULT_PATH")"
UPLOAD_RESULT_SHA256="$(file_sha256 "$UPLOAD_RESULT_PATH")"

/usr/bin/jq -n \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$IPA_SHA256" '{
    schemaVersion: 1,
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    exportedIPA: $ipaPath,
    ipaSHA256: $ipaSHA256,
    uploaded: false
  }' >"$METADATA_PATH"
METADATA_SHA256="$(file_sha256 "$METADATA_PATH")"

SUBMITTED_AT="$(/bin/date -u -v-40M '+%Y-%m-%dT%H:%M:%SZ')"
PROCESSING_VERIFIED_AT="$(/bin/date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')"
TESTFLIGHT_TESTED_AT="$(/bin/date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
FUNCTIONAL_TESTED_AT="$(/bin/date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/jq -n \
  --arg submittedAt "$SUBMITTED_AT" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg metadataPath "$METADATA_PATH" \
  --arg metadataSHA256 "$METADATA_SHA256" \
  --arg validationPath "$VALIDATION_RESULT_PATH" \
  --arg validationSHA256 "$VALIDATION_RESULT_SHA256" \
  --arg uploadPath "$UPLOAD_RESULT_PATH" \
  --arg uploadSHA256 "$UPLOAD_RESULT_SHA256" '{
    schemaVersion: 1,
    platform: "iOS",
    destination: "App Store Connect / TestFlight",
    submittedAt: $submittedAt,
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    ipaPath: $ipaPath,
    ipaSHA256: $ipaSHA256,
    releaseMetadataPath: $metadataPath,
    releaseMetadataSHA256: $metadataSHA256,
    validationResultPath: $validationPath,
    validationResultSHA256: $validationSHA256,
    uploadResultPath: $uploadPath,
    uploadResultSHA256: $uploadSHA256,
    uploadAccepted: true,
    processingState: null,
    appStoreConnectBuildID: null,
    processingVerified: false,
    processingVerifiedAt: null,
    distributedToTesters: false,
    installedFromTestFlight: false,
    testedAt: null,
    submittedForAppReview: false
  }' >"$DELIVERY_RECORD_PATH"
/bin/chmod 0444 "$DELIVERY_RECORD_PATH"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$IPA_SHA256"

run_testflight_confirmation() {
  local delivery_path="${1:-$DELIVERY_RECORD_PATH}"
  AGENT_ISLAND_CONFIRM_TESTFLIGHT_VERIFICATION="$CONFIRMATION_VALUE" \
    "$TESTFLIGHT_CONFIRM" \
      --processing-state VALID \
      --app-store-connect-build-id "$ASC_BUILD_ID" \
      --processing-verified-at "$PROCESSING_VERIFIED_AT" \
      --distributed-to-testers \
      --installed-from-testflight \
      --tested-at "$TESTFLIGHT_TESTED_AT" \
      "$delivery_path"
}

expect_testflight_confirmation_rejected() {
  local marker="$1"
  shift
  local output="$TEST_ROOT/testflight-confirm-rejected.txt"
  if run_testflight_confirmation "$@" >"$output" 2>&1; then
    fail "TestFlight confirmation accepted fixture expected to fail with: $marker"
  fi
  /usr/bin/grep -Fq -- "$marker" "$output" \
    || fail "TestFlight confirmation rejection did not contain '$marker': $(/bin/cat "$output")"
}

VALID_VALIDATION_RESULT="$TEST_ROOT/valid-validation-result.json"
/bin/cp "$VALIDATION_RESULT_PATH" "$VALID_VALIDATION_RESULT"
/bin/chmod 0644 "$VALIDATION_RESULT_PATH" "$DELIVERY_RECORD_PATH"
/usr/bin/jq -n '{"success-message": "ambiguous", errors: false}' \
  >"$VALIDATION_RESULT_PATH"
INVALID_VALIDATION_SHA256="$(file_sha256 "$VALIDATION_RESULT_PATH")"
/usr/bin/jq --arg sha "$INVALID_VALIDATION_SHA256" \
  '.validationResultSHA256 = $sha' "$DELIVERY_RECORD_PATH" \
  >"$TEST_ROOT/delivery-invalid-validation.json"
/bin/mv "$TEST_ROOT/delivery-invalid-validation.json" "$DELIVERY_RECORD_PATH"
/bin/chmod 0444 "$VALIDATION_RESULT_PATH" "$DELIVERY_RECORD_PATH"
expect_testflight_confirmation_rejected \
  'stored App Store Connect validation result is not an unambiguous success response'

/bin/chmod 0644 "$VALIDATION_RESULT_PATH" "$DELIVERY_RECORD_PATH"
/bin/cp "$VALID_VALIDATION_RESULT" "$VALIDATION_RESULT_PATH"
VALIDATION_RESULT_SHA256="$(file_sha256 "$VALIDATION_RESULT_PATH")"
/usr/bin/jq --arg sha "$VALIDATION_RESULT_SHA256" \
  '.validationResultSHA256 = $sha' "$DELIVERY_RECORD_PATH" \
  >"$TEST_ROOT/delivery-valid-validation.json"
/bin/mv "$TEST_ROOT/delivery-valid-validation.json" "$DELIVERY_RECORD_PATH"
/bin/chmod 0444 "$VALIDATION_RESULT_PATH" "$DELIVERY_RECORD_PATH"

MISMATCHED_VALIDATION_PATH="$RELEASE_DIRECTORY/testflight-validation-20260904T000001Z.json"
/bin/cp "$VALIDATION_RESULT_PATH" "$MISMATCHED_VALIDATION_PATH"
/bin/chmod 0444 "$MISMATCHED_VALIDATION_PATH"
/usr/bin/jq --arg path "$MISMATCHED_VALIDATION_PATH" \
  '.validationResultPath = $path' "$DELIVERY_RECORD_PATH" \
  >"$TEST_ROOT/delivery-mismatched-stamp.json"
/bin/mv -f "$TEST_ROOT/delivery-mismatched-stamp.json" "$DELIVERY_RECORD_PATH"
/bin/chmod 0444 "$DELIVERY_RECORD_PATH"
expect_testflight_confirmation_rejected \
  'delivery, validation, and upload filenames must share one UTC stamp'
/usr/bin/jq --arg path "$VALIDATION_RESULT_PATH" \
  '.validationResultPath = $path' "$DELIVERY_RECORD_PATH" \
  >"$TEST_ROOT/delivery-restored-stamp.json"
/bin/mv -f "$TEST_ROOT/delivery-restored-stamp.json" "$DELIVERY_RECORD_PATH"
/bin/chmod 0444 "$DELIVERY_RECORD_PATH"

RELEASE_DIRECTORY_ALIAS="$TEST_ROOT/release-parent-symlink"
/bin/ln -s "$RELEASE_DIRECTORY" "$RELEASE_DIRECTORY_ALIAS"
expect_testflight_confirmation_rejected \
  'delivery record path must not traverse symlink parents' \
  "$RELEASE_DIRECTORY_ALIAS/${DELIVERY_RECORD_PATH:t}"

run_testflight_confirmation >"$TEST_ROOT/testflight-confirm-valid.txt" 2>&1 \
  || fail "valid TestFlight confirmation fixture was rejected: $(/bin/cat "$TEST_ROOT/testflight-confirm-valid.txt")"
TESTFLIGHT_VERIFICATION_PATH="$(/usr/bin/sed -n \
  's/^TestFlight verification evidence recorded: //p' \
  "$TEST_ROOT/testflight-confirm-valid.txt")"
[[ -f "$TESTFLIGHT_VERIFICATION_PATH" && \
    "$(/usr/bin/stat -f '%Lp' "$TESTFLIGHT_VERIFICATION_PATH")" == "444" ]] \
  || fail "TestFlight confirmation did not publish mode-0444 evidence"

CLOUDKIT_EVIDENCE="$RELEASE_DIRECTORY/cloudkit-production-report.txt"
SYNC_EVIDENCE="$RELEASE_DIRECTORY/same-account-sync-report.txt"
LIVE_ACTIVITY_EVIDENCE="$RELEASE_DIRECTORY/live-activity-report.txt"
REVIEW_PATH_EVIDENCE="$RELEASE_DIRECTORY/review-path-report.txt"
print -n -r -- 'Production schema inspected for the release container.' >"$CLOUDKIT_EVIDENCE"
print -n -r -- 'Same iCloud account Mac-to-iPhone refresh observed.' >"$SYNC_EVIDENCE"
print -n -r -- 'Live Activity observed on the real device.' >"$LIVE_ACTIVITY_EVIDENCE"
print -n -r -- 'Example and production review paths completed.' >"$REVIEW_PATH_EVIDENCE"

run_generator() {
  local cloudkit_result="$1"
  local device_model="$2"
  local output_path="$3"
  local confirmation_value="$4"
  local cloudkit_attachment="${5:-$CLOUDKIT_EVIDENCE}"
  local sync_attachment="${6:-$SYNC_EVIDENCE}"
  AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA="$confirmation_value" \
    "$GENERATOR" \
      --device-model "$device_model" \
      --ios-version '18.6.2' \
      --tested-at "$FUNCTIONAL_TESTED_AT" \
      --cloudkit-production-schema-result "$cloudkit_result" \
      --cloudkit-evidence "$cloudkit_attachment" \
      --same-account-sync-result passed \
      --sync-evidence "$sync_attachment" \
      --live-activity-result passed \
      --live-activity-evidence "$LIVE_ACTIVITY_EVIDENCE" \
      --review-path-result passed \
      --review-path-evidence "$REVIEW_PATH_EVIDENCE" \
      --output "$output_path" \
      "$TESTFLIGHT_VERIFICATION_PATH"
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
  local output="$TEST_ROOT/validator-rejected.txt"
  if "$VALIDATOR" "$evidence_path" >"$output" 2>&1; then
    fail "validator accepted fixture expected to fail with: $marker"
  fi
  /usr/bin/grep -Fq -- "$marker" "$output" \
    || fail "validator rejection did not contain '$marker': $(/bin/cat "$output")"
}

expect_generator_rejected \
  'all four functional QA results must be exactly passed' \
  false 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-false.json" \
  "$CONFIRMATION_VALUE"
expect_generator_rejected \
  '--device-model is missing or a placeholder' \
  passed '<DEVICE MODEL>' "$RELEASE_DIRECTORY/ios-functional-verification-placeholder.json" \
  "$CONFIRMATION_VALUE"
expect_generator_rejected \
  'does not match this exact TestFlight IPA' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-wrong-confirmation.json" \
  'wrong:confirmation:value'
expect_generator_rejected \
  'cannot reuse a release artifact' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-artifact.json" \
  "$CONFIRMATION_VALUE" "$IPA_PATH"

SYMLINK_ATTACHMENT="$RELEASE_DIRECTORY/cloudkit-symlink.txt"
/bin/ln -s "$CLOUDKIT_EVIDENCE" "$SYMLINK_ATTACHMENT"
expect_generator_rejected \
  'must be an existing, absolute, non-symlink file' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-symlink.json" \
  "$CONFIRMATION_VALUE" "$SYMLINK_ATTACHMENT"

HARDLINK_ATTACHMENT="$RELEASE_DIRECTORY/sync-hardlink.txt"
/bin/ln "$CLOUDKIT_EVIDENCE" "$HARDLINK_ATTACHMENT"
expect_generator_rejected \
  'four distinct device:inode identities' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-hardlink.json" \
  "$CONFIRMATION_VALUE" "$CLOUDKIT_EVIDENCE" "$HARDLINK_ATTACHMENT"

SAME_CONTENT_ATTACHMENT="$RELEASE_DIRECTORY/sync-same-content.txt"
/bin/cp "$CLOUDKIT_EVIDENCE" "$SAME_CONTENT_ATTACHMENT"
expect_generator_rejected \
  'four distinct content SHA-256 values' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-same-content.json" \
  "$CONFIRMATION_VALUE" "$CLOUDKIT_EVIDENCE" "$SAME_CONTENT_ATTACHMENT"

CORE_CONTENT_ATTACHMENT="$RELEASE_DIRECTORY/core-content-copy.txt"
/bin/cp "$IPA_PATH" "$CORE_CONTENT_ATTACHMENT"
expect_generator_rejected \
  'content cannot duplicate a core release artifact or evidence record' \
  passed 'iPhone 16 Pro' "$RELEASE_DIRECTORY/ios-functional-verification-core-content.json" \
  "$CONFIRMATION_VALUE" "$CORE_CONTENT_ATTACHMENT"

OUTPUT_SYMLINK="$RELEASE_DIRECTORY/ios-functional-verification-output-symlink.json"
/bin/ln -s "$TEST_ROOT/nonexistent-output-target" "$OUTPUT_SYMLINK"
expect_generator_rejected \
  'refusing to overwrite an existing iOS functional QA evidence file' \
  passed 'iPhone 16 Pro' "$OUTPUT_SYMLINK" "$CONFIRMATION_VALUE"

run_generator passed 'iPhone 16 Pro' "$FUNCTIONAL_EVIDENCE_PATH" \
  "$CONFIRMATION_VALUE" >"$TEST_ROOT/generator-valid.txt" 2>&1 \
  || fail "valid exact-build QA fixture was rejected: $(/bin/cat "$TEST_ROOT/generator-valid.txt")"
contains 'iOS functional QA evidence recorded:' "$TEST_ROOT/generator-valid.txt"
[[ "$(/usr/bin/stat -f '%Lp' "$FUNCTIONAL_EVIDENCE_PATH")" == "444" ]] \
  || fail "generated functional QA evidence is not mode 0444"

expect_validator_rejected \
  'functional QA evidence path must not traverse symlink parents' \
  "$RELEASE_DIRECTORY_ALIAS/${FUNCTIONAL_EVIDENCE_PATH:t}"
if "$VALIDATOR" --inspect-testflight-verification \
    "$RELEASE_DIRECTORY_ALIAS/${TESTFLIGHT_VERIFICATION_PATH:t}" \
    >"$TEST_ROOT/inspection-parent-symlink.txt" 2>&1; then
  fail "TestFlight inspection accepted an input path through a symlink parent"
fi
contains 'TestFlight verification path must not traverse symlink parents' \
  "$TEST_ROOT/inspection-parent-symlink.txt"

VALID_JSON="$TEST_ROOT/validator-valid.json"
"$VALIDATOR" --json \
  --expected-testflight-verification "$TESTFLIGHT_VERIFICATION_PATH" \
  --expected-ipa-sha256 "$IPA_SHA256" \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$VALID_JSON" \
  || fail "validator rejected generated exact-build QA evidence"
/usr/bin/jq -e \
  --arg sha "$IPA_SHA256" '
    .evidenceReady == true and
    .candidate.ipaSHA256 == $sha and
    .testDevice == {
      model: "iPhone 16 Pro",
      operatingSystem: "iOS",
      osVersion: "18.6.2"
    } and
    (.testedAt | type == "string" and endswith("Z")) and
    .cloudKitProductionSchemaVerified == true and
    .realDeviceSyncVerified == true and
    .liveActivityVerified == true and
    .reviewPathVerified == true
  ' "$VALID_JSON" >/dev/null \
  || fail "validator JSON did not expose all four exact-build gates"

VALIDATOR_HARDLINK_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-hardlink-alias.json"
/usr/bin/jq \
  --arg path "$HARDLINK_ATTACHMENT" \
  --arg sha "$(file_sha256 "$HARDLINK_ATTACHMENT")" \
  --argjson size "$(/usr/bin/stat -f '%z' "$HARDLINK_ATTACHMENT")" \
  '.qa.reviewPath.evidence = {path: $path, sha256: $sha, sizeBytes: $size}' \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$VALIDATOR_HARDLINK_EVIDENCE"
/bin/chmod 0444 "$VALIDATOR_HARDLINK_EVIDENCE"
expect_validator_rejected \
  'four distinct device:inode identities' "$VALIDATOR_HARDLINK_EVIDENCE"

VALIDATOR_SAME_CONTENT_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-same-content-alias.json"
/usr/bin/jq \
  --arg path "$SAME_CONTENT_ATTACHMENT" \
  --arg sha "$(file_sha256 "$SAME_CONTENT_ATTACHMENT")" \
  --argjson size "$(/usr/bin/stat -f '%z' "$SAME_CONTENT_ATTACHMENT")" \
  '.qa.reviewPath.evidence = {path: $path, sha256: $sha, sizeBytes: $size}' \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$VALIDATOR_SAME_CONTENT_EVIDENCE"
/bin/chmod 0444 "$VALIDATOR_SAME_CONTENT_EVIDENCE"
expect_validator_rejected \
  'four distinct content SHA-256 values' "$VALIDATOR_SAME_CONTENT_EVIDENCE"

VALIDATOR_CORE_CONTENT_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-core-content-alias.json"
/usr/bin/jq \
  --arg path "$CORE_CONTENT_ATTACHMENT" \
  --arg sha "$(file_sha256 "$CORE_CONTENT_ATTACHMENT")" \
  --argjson size "$(/usr/bin/stat -f '%z' "$CORE_CONTENT_ATTACHMENT")" \
  '.qa.cloudKitProductionSchema.evidence = {path: $path, sha256: $sha, sizeBytes: $size}' \
  "$FUNCTIONAL_EVIDENCE_PATH" >"$VALIDATOR_CORE_CONTENT_EVIDENCE"
/bin/chmod 0444 "$VALIDATOR_CORE_CONTENT_EVIDENCE"
expect_validator_rejected \
  'content duplicates a core release artifact or evidence record' \
  "$VALIDATOR_CORE_CONTENT_EVIDENCE"

# Recompute every downstream hash after replacing a stored upload response
# with an error-shaped object. Hash consistency alone must never turn that
# response into accepted-upload or functional-QA evidence.
/bin/cp "$UPLOAD_RESULT_PATH" "$TEST_ROOT/upload-result.backup"
/bin/cp "$DELIVERY_RECORD_PATH" "$TEST_ROOT/delivery-record.backup"
/bin/cp "$TESTFLIGHT_VERIFICATION_PATH" "$TEST_ROOT/testflight-verification.backup"
/usr/bin/jq -n '{"success-message": "ambiguous", "product-errors": false}' \
  >"$TEST_ROOT/upload-result-tampered.json"
/bin/chmod 0444 "$TEST_ROOT/upload-result-tampered.json"
/bin/mv -f "$TEST_ROOT/upload-result-tampered.json" "$UPLOAD_RESULT_PATH"
TAMPERED_UPLOAD_SHA256="$(file_sha256 "$UPLOAD_RESULT_PATH")"
/usr/bin/jq --arg sha "$TAMPERED_UPLOAD_SHA256" \
  '.uploadResultSHA256 = $sha' "$TEST_ROOT/delivery-record.backup" \
  >"$TEST_ROOT/delivery-record-tampered.json"
/bin/chmod 0444 "$TEST_ROOT/delivery-record-tampered.json"
/bin/mv -f "$TEST_ROOT/delivery-record-tampered.json" "$DELIVERY_RECORD_PATH"
TAMPERED_DELIVERY_SHA256="$(file_sha256 "$DELIVERY_RECORD_PATH")"
/usr/bin/jq --arg sha "$TAMPERED_DELIVERY_SHA256" \
  '.deliveryRecordSHA256 = $sha' "$TEST_ROOT/testflight-verification.backup" \
  >"$TEST_ROOT/testflight-verification-tampered.json"
/bin/chmod 0444 "$TEST_ROOT/testflight-verification-tampered.json"
/bin/mv -f "$TEST_ROOT/testflight-verification-tampered.json" \
  "$TESTFLIGHT_VERIFICATION_PATH"
TAMPERED_TESTFLIGHT_SHA256="$(file_sha256 "$TESTFLIGHT_VERIFICATION_PATH")"
SYNCHRONIZED_HASH_TAMPER_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-synchronized-hash-tamper.json"
/usr/bin/jq --arg sha "$TAMPERED_TESTFLIGHT_SHA256" \
  '.testFlightVerification.sha256 = $sha' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$SYNCHRONIZED_HASH_TAMPER_EVIDENCE"
/bin/chmod 0444 "$SYNCHRONIZED_HASH_TAMPER_EVIDENCE"
expect_validator_rejected \
  'stored App Store Connect upload result is not an unambiguous success response' \
  "$SYNCHRONIZED_HASH_TAMPER_EVIDENCE"

/bin/cp "$TEST_ROOT/upload-result.backup" "$TEST_ROOT/upload-result-restored.json"
/bin/chmod 0444 "$TEST_ROOT/upload-result-restored.json"
/bin/mv -f "$TEST_ROOT/upload-result-restored.json" "$UPLOAD_RESULT_PATH"
/bin/cp "$TEST_ROOT/delivery-record.backup" "$TEST_ROOT/delivery-record-restored.json"
/bin/chmod 0444 "$TEST_ROOT/delivery-record-restored.json"
/bin/mv -f "$TEST_ROOT/delivery-record-restored.json" "$DELIVERY_RECORD_PATH"
/bin/cp "$TEST_ROOT/testflight-verification.backup" \
  "$TEST_ROOT/testflight-verification-restored.json"
/bin/chmod 0444 "$TEST_ROOT/testflight-verification-restored.json"
/bin/mv -f "$TEST_ROOT/testflight-verification-restored.json" \
  "$TESTFLIGHT_VERIFICATION_PATH"

expect_generator_rejected \
  'refusing to overwrite an existing iOS functional QA evidence file' \
  passed 'iPhone 16 Pro' "$FUNCTIONAL_EVIDENCE_PATH" "$CONFIRMATION_VALUE"

print -n -r -- 'tampered CloudKit evidence' >>"$CLOUDKIT_EVIDENCE"
expect_validator_rejected \
  'cloudKitProductionSchema QA attachment size does not match the functional QA record' \
  "$FUNCTIONAL_EVIDENCE_PATH"
print -n -r -- 'Production schema inspected for the release container.' >"$CLOUDKIT_EVIDENCE"

print -n -r -- 'tamper' >>"$IPA_PATH"
expect_validator_rejected \
  'current IPA SHA-256 differs from the TestFlight verification evidence' \
  "$FUNCTIONAL_EVIDENCE_PATH"
print -n -r -- 'exact signed IPA fixture' >"$IPA_PATH"

FALSE_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-false-field.json"
/usr/bin/jq '.qa.liveActivity.result = "failed"' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$FALSE_EVIDENCE"
/bin/chmod 0444 "$FALSE_EVIDENCE"
expect_validator_rejected \
  'contains false results' "$FALSE_EVIDENCE"

MISMATCH_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-hash-mismatch.json"
/usr/bin/jq '.candidate.ipaSHA256 = ("0" * 64)' "$FUNCTIONAL_EVIDENCE_PATH" \
  >"$MISMATCH_EVIDENCE"
/bin/chmod 0444 "$MISMATCH_EVIDENCE"
expect_validator_rejected \
  'candidate does not match the exact TestFlight IPA' "$MISMATCH_EVIDENCE"

MUTABLE_EVIDENCE="$RELEASE_DIRECTORY/ios-functional-verification-mutable.json"
/bin/cp "$FUNCTIONAL_EVIDENCE_PATH" "$MUTABLE_EVIDENCE"
/bin/chmod 0644 "$MUTABLE_EVIDENCE"
expect_validator_rejected \
  'must be read-only' "$MUTABLE_EVIDENCE"

print -r -- 'iOS exact-TestFlight functional QA evidence tests passed'
