#!/bin/zsh
set -euo pipefail

IOS_ROOT="${0:A:h:h}"
MODE="validate"
OUTPUT_JSON=false
EXPECTED_TESTFLIGHT_VERIFICATION=""
EXPECTED_IPA_SHA256=""
INPUT_PATH=""

usage() {
  /bin/cat <<'EOF'
Usage:
  ./scripts/validate-functional-qa-evidence.sh [--json] \
    [--expected-testflight-verification FILE] \
    [--expected-ipa-sha256 SHA256] \
    IOS_FUNCTIONAL_QA_EVIDENCE.json

  ./scripts/validate-functional-qa-evidence.sh \
    --inspect-testflight-verification TESTFLIGHT_VERIFICATION.json

Validates a read-only, no-overwrite iOS functional-QA record and its complete local evidence
chain. The record must bind four passed checks and their attachments to the
exact IPA recorded by an existing TestFlight verification record. Validation
is local and never contacts or changes App Store Connect.

--json emits a machine-readable success object. The two --expected options
bind a caller's already-selected TestFlight candidate to the same evidence.
--inspect-testflight-verification is used by the confirmation script to obtain
a locally revalidated exact-candidate identity.
EOF
}

fail() {
  print -u2 -r -- "iOS functional QA evidence validation failed: $*"
  exit 2
}

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_app_store_result_success_json() {
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
    || fail "stored App Store Connect $operation result is not an unambiguous success response"
}

require_readonly_file() {
  local path="$1"
  local label="$2"
  [[ "$(/usr/bin/stat -f '%Sp' "$path")" != *w* ]] \
    || fail "$label must be read-only (no write permission bits)"
}

require_shared_delivery_stamp() {
  local delivery_path="$1"
  local validation_path="$2"
  local upload_path="$3"
  local delivery_name="${delivery_path:t}"
  local stamp="${delivery_name#testflight-delivery-}"
  stamp="${stamp%.json}"
  print -r -- "$stamp" | /usr/bin/grep -Eq '^[0-9]{8}T[0-9]{6}Z$' \
    || fail "delivery record filename does not contain a strict UTC stamp"
  /bin/date -j -u -f '%Y%m%dT%H%M%SZ' "$stamp" '+%s' >/dev/null 2>&1 \
    || fail "delivery record filename contains an impossible UTC stamp"
  [[ "${validation_path:t}" == "testflight-validation-$stamp.json" \
      && "${upload_path:t}" == "testflight-upload-$stamp.json" ]] \
    || fail "delivery, validation, and upload filenames must share one UTC stamp"
}

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
}

timestamp_epoch() {
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s'
}

placeholder_text() {
  local lowered="${1:l}"
  [[ -z "$1" || "$1" == *'<'* || "$1" == *'>'* ]] && return 0
  print -r -- "$lowered" | /usr/bin/grep -Eq \
    '(com\.example|example\.com|yourname|yourteam|change[-_ ]?me|replace[-_ ]?me|x{5,})' \
    && return 0
  print -r -- "$lowered" | /usr/bin/grep -Eq \
    '(^|[^[:alpha:]])(todo|tbd|placeholder|unknown|example|your)([^[:alpha:]]|$)'
}

require_safe_release_file() {
  local raw_path="$1"
  local release_directory="$2"
  local label="$3"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and contain no symlink traversal"
  [[ "$canonical_path" == "$release_directory"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

inspect_testflight_verification() {
  local input="$1"
  [[ -f "$input" && ! -L "$input" ]] \
    || fail "TestFlight verification evidence must be an existing, non-symlink file"
  local verification_absolute="${input:a}"
  local verification_path="${input:A}"
  [[ "$verification_absolute" == "$verification_path" ]] \
    || fail "TestFlight verification path must not traverse symlink parents"
  [[ -d "${verification_absolute:h}" && ! -L "${verification_absolute:h}" ]] \
    || fail "TestFlight verification parent must be a non-symlink release directory"
  local release_directory="${verification_path:h}"
  [[ "${verification_path:t}" == testflight-verification-*.json ]] \
    || fail "TestFlight verification filename is not a generated evidence record"
  [[ -d "$release_directory" && ! -L "$release_directory" ]] \
    || fail "TestFlight verification parent must be a non-symlink release directory"
  [[ "$(/usr/bin/stat -f '%Sp' "$verification_path")" != *w* ]] \
    || fail "TestFlight verification evidence must be read-only (no write permission bits)"

  /usr/bin/jq -e '
    type == "object" and
    .schemaVersion == 1 and
    .platform == "iOS" and
    (.appBundleID | type == "string" and length > 0) and
    (.version | type == "string" and length > 0) and
    (.build | type == "string" and length > 0) and
    (.ipaPath | type == "string" and length > 0) and
    (.ipaSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.releaseMetadataPath | type == "string" and length > 0) and
    (.releaseMetadataSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.deliveryRecordPath | type == "string" and length > 0) and
    (.deliveryRecordSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    .uploadAccepted == true and
    (.appStoreConnectBuildID | type == "string" and length > 0) and
    (.processingState == "VALID" or .processingState == "Complete") and
    (.processingVerifiedAt | type == "string" and length > 0) and
    .warningsReviewed == true and
    (.warningsReviewedAt | type == "string" and length > 0) and
    .distributedToTesters == true and
    .installedFromTestFlight == true and
    (.testedAt | type == "string" and length > 0) and
    (.createdAt | type == "string" and length > 0)
  ' "$verification_path" >/dev/null \
    || fail "TestFlight verification evidence is incomplete or unsupported"

  local app_bundle_id version build_number ipa_path ipa_sha256
  local release_metadata_path release_metadata_sha256
  local delivery_record_path delivery_record_sha256 app_store_connect_build_id
  local processing_verified_at warnings_reviewed_at verification_tested_at
  local verification_created_at
  app_bundle_id="$(/usr/bin/jq -r '.appBundleID' "$verification_path")"
  version="$(/usr/bin/jq -r '.version' "$verification_path")"
  build_number="$(/usr/bin/jq -r '.build' "$verification_path")"
  ipa_path="$(/usr/bin/jq -r '.ipaPath' "$verification_path")"
  ipa_sha256="$(/usr/bin/jq -r '.ipaSHA256' "$verification_path")"
  release_metadata_path="$(/usr/bin/jq -r '.releaseMetadataPath' "$verification_path")"
  release_metadata_sha256="$(/usr/bin/jq -r '.releaseMetadataSHA256' "$verification_path")"
  delivery_record_path="$(/usr/bin/jq -r '.deliveryRecordPath' "$verification_path")"
  delivery_record_sha256="$(/usr/bin/jq -r '.deliveryRecordSHA256' "$verification_path")"
  app_store_connect_build_id="$(/usr/bin/jq -r '.appStoreConnectBuildID' "$verification_path")"
  processing_verified_at="$(/usr/bin/jq -r '.processingVerifiedAt' "$verification_path")"
  warnings_reviewed_at="$(/usr/bin/jq -r '.warningsReviewedAt' "$verification_path")"
  verification_tested_at="$(/usr/bin/jq -r '.testedAt' "$verification_path")"
  verification_created_at="$(/usr/bin/jq -r '.createdAt' "$verification_path")"

  placeholder_text "$app_bundle_id" \
    && fail "TestFlight verification app bundle ID is a placeholder"
  placeholder_text "$version" \
    && fail "TestFlight verification version is a placeholder"
  placeholder_text "$build_number" \
    && fail "TestFlight verification build is a placeholder"
  placeholder_text "$app_store_connect_build_id" \
    && fail "TestFlight verification App Store Connect build ID is a placeholder"
  [[ ${#app_bundle_id} -le 255 && ${#version} -le 64 && ${#build_number} -le 64 ]] \
    || fail "TestFlight verification candidate identity is unreasonably long"
  print -r -- "$app_bundle_id$version$build_number$app_store_connect_build_id" \
    | LC_ALL=C /usr/bin/grep -Eq '^[[:graph:]]+$' \
    || fail "TestFlight verification candidate identity contains whitespace or control characters"

  ipa_path="$(require_safe_release_file "$ipa_path" "$release_directory" "IPA")"
  release_metadata_path="$(require_safe_release_file \
    "$release_metadata_path" "$release_directory" "release metadata")"
  delivery_record_path="$(require_safe_release_file \
    "$delivery_record_path" "$release_directory" "TestFlight delivery record")"
  [[ "$release_metadata_path" == "$release_directory/release-metadata.json" ]] \
    || fail "TestFlight verification does not reference this release directory's metadata"
  require_readonly_file "$delivery_record_path" "TestFlight delivery record"

  [[ "$(file_sha256 "$ipa_path")" == "$ipa_sha256" ]] \
    || fail "current IPA SHA-256 differs from the TestFlight verification evidence"
  [[ "$(file_sha256 "$release_metadata_path")" == "$release_metadata_sha256" ]] \
    || fail "current release metadata SHA-256 differs from the TestFlight verification evidence"
  [[ "$(file_sha256 "$delivery_record_path")" == "$delivery_record_sha256" ]] \
    || fail "current delivery record SHA-256 differs from the TestFlight verification evidence"

  /usr/bin/jq -e \
    --arg appBundleID "$app_bundle_id" \
    --arg version "$version" \
    --arg build "$build_number" \
    --arg ipaPath "$ipa_path" \
    --arg ipaSHA256 "$ipa_sha256" '
      .schemaVersion == 1 and
      .appBundleID == $appBundleID and
      .version == $version and
      .build == $build and
      .exportedIPA == $ipaPath and
      .ipaSHA256 == $ipaSHA256 and
      .uploaded == false
    ' "$release_metadata_path" >/dev/null \
    || fail "release metadata and TestFlight verification do not identify the same IPA"

  /usr/bin/jq -e \
    --arg appBundleID "$app_bundle_id" \
    --arg version "$version" \
    --arg build "$build_number" \
    --arg ipaPath "$ipa_path" \
    --arg ipaSHA256 "$ipa_sha256" \
    --arg releaseMetadataPath "$release_metadata_path" \
    --arg releaseMetadataSHA256 "$release_metadata_sha256" '
      .schemaVersion == 1 and
      .platform == "iOS" and
      .destination == "App Store Connect / TestFlight" and
      (.submittedAt | type == "string" and length > 0) and
      .appBundleID == $appBundleID and
      .version == $version and
      .build == $build and
      .ipaPath == $ipaPath and
      .ipaSHA256 == $ipaSHA256 and
      .releaseMetadataPath == $releaseMetadataPath and
      .releaseMetadataSHA256 == $releaseMetadataSHA256 and
      .uploadAccepted == true and
      .processingState == null and
      .appStoreConnectBuildID == null and
      .processingVerified == false and
      .processingVerifiedAt == null and
      ((.warningsReviewed // false) == false) and
      .warningsReviewedAt == null and
      .distributedToTesters == false and
      .installedFromTestFlight == false and
      .testedAt == null and
      .submittedForAppReview == false
    ' "$delivery_record_path" >/dev/null \
    || fail "delivery record and TestFlight verification do not identify the same accepted upload"

  local validation_result_path validation_result_sha256
  local upload_result_path upload_result_sha256
  validation_result_path="$(/usr/bin/jq -r '.validationResultPath // empty' "$delivery_record_path")"
  validation_result_sha256="$(/usr/bin/jq -r '.validationResultSHA256 // empty' "$delivery_record_path")"
  upload_result_path="$(/usr/bin/jq -r '.uploadResultPath // empty' "$delivery_record_path")"
  upload_result_sha256="$(/usr/bin/jq -r '.uploadResultSHA256 // empty' "$delivery_record_path")"
  print -r -- "$validation_result_sha256" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || fail "delivery record validation-result SHA-256 is missing or malformed"
  print -r -- "$upload_result_sha256" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || fail "delivery record upload-result SHA-256 is missing or malformed"
  validation_result_path="$(require_safe_release_file \
    "$validation_result_path" "$release_directory" "validation result")"
  upload_result_path="$(require_safe_release_file \
    "$upload_result_path" "$release_directory" "upload result")"
  require_readonly_file "$validation_result_path" "validation result"
  require_readonly_file "$upload_result_path" "upload result"
  require_shared_delivery_stamp "$delivery_record_path" \
    "$validation_result_path" "$upload_result_path"
  [[ "$(file_sha256 "$validation_result_path")" == "$validation_result_sha256" ]] \
    || fail "current validation result differs from the accepted delivery record"
  [[ "$(file_sha256 "$upload_result_path")" == "$upload_result_sha256" ]] \
    || fail "current upload result differs from the accepted delivery record"
  verify_app_store_result_success_json "$validation_result_path" "validation"
  verify_app_store_result_success_json "$upload_result_path" "upload"

  local submitted_at
  submitted_at="$(/usr/bin/jq -r '.submittedAt' "$delivery_record_path")"
  for timestamp in "$submitted_at" "$processing_verified_at" "$warnings_reviewed_at" \
      "$verification_tested_at" "$verification_created_at"; do
    valid_utc_timestamp "$timestamp" \
      || fail "TestFlight verification contains an invalid UTC timestamp"
  done
  local submitted_epoch processing_epoch warnings_reviewed_epoch
  local verification_tested_epoch verification_created_epoch now_epoch
  submitted_epoch="$(timestamp_epoch "$submitted_at")"
  processing_epoch="$(timestamp_epoch "$processing_verified_at")"
  warnings_reviewed_epoch="$(timestamp_epoch "$warnings_reviewed_at")"
  verification_tested_epoch="$(timestamp_epoch "$verification_tested_at")"
  verification_created_epoch="$(timestamp_epoch "$verification_created_at")"
  now_epoch="$(/bin/date -u '+%s')"
  (( submitted_epoch <= processing_epoch \
    && processing_epoch <= warnings_reviewed_epoch \
    && warnings_reviewed_epoch <= verification_tested_epoch \
    && verification_tested_epoch <= verification_created_epoch \
    && verification_created_epoch <= now_epoch + 300 )) \
    || fail "TestFlight verification timestamps are inconsistent or in the future"

  "$IOS_ROOT/scripts/submit-testflight.sh" --check "$release_directory" >/dev/null \
    || fail "the exact IPA no longer passes the local TestFlight preflight"

  /usr/bin/jq -n \
    --arg appBundleID "$app_bundle_id" \
    --arg version "$version" \
    --arg build "$build_number" \
    --arg ipaPath "$ipa_path" \
    --arg ipaSHA256 "$ipa_sha256" \
    --arg appStoreConnectBuildID "$app_store_connect_build_id" \
    --arg releaseMetadataPath "$release_metadata_path" \
    --arg releaseMetadataSHA256 "$release_metadata_sha256" \
    --arg deliveryRecordPath "$delivery_record_path" \
    --arg deliveryRecordSHA256 "$delivery_record_sha256" \
    --arg validationResultPath "$validation_result_path" \
    --arg validationResultSHA256 "$validation_result_sha256" \
    --arg uploadResultPath "$upload_result_path" \
    --arg uploadResultSHA256 "$upload_result_sha256" \
    --arg releaseDirectory "$release_directory" \
    --arg verificationPath "$verification_path" \
    --arg verificationSHA256 "$(file_sha256 "$verification_path")" \
    --arg warningsReviewedAt "$warnings_reviewed_at" \
    --arg verificationTestedAt "$verification_tested_at" '{
      appBundleID: $appBundleID,
      version: $version,
      build: $build,
      ipaPath: $ipaPath,
      ipaSHA256: $ipaSHA256,
      appStoreConnectBuildID: $appStoreConnectBuildID,
      releaseMetadataPath: $releaseMetadataPath,
      releaseMetadataSHA256: $releaseMetadataSHA256,
      deliveryRecordPath: $deliveryRecordPath,
      deliveryRecordSHA256: $deliveryRecordSHA256,
      validationResultPath: $validationResultPath,
      validationResultSHA256: $validationResultSHA256,
      uploadResultPath: $uploadResultPath,
      uploadResultSHA256: $uploadResultSHA256,
      releaseDirectory: $releaseDirectory,
      verificationPath: $verificationPath,
      verificationSHA256: $verificationSHA256,
      warningsReviewed: true,
      warningsReviewedAt: $warningsReviewedAt,
      verificationTestedAt: $verificationTestedAt
    }'
}

while (( $# > 0 )); do
  case "$1" in
    --json)
      [[ "$MODE" == "validate" ]] || fail "--json is not valid with inspection mode"
      OUTPUT_JSON=true
      shift
      ;;
    --expected-testflight-verification)
      (( $# >= 2 )) || fail "--expected-testflight-verification requires a file"
      EXPECTED_TESTFLIGHT_VERIFICATION="$2"
      shift 2
      ;;
    --expected-ipa-sha256)
      (( $# >= 2 )) || fail "--expected-ipa-sha256 requires a SHA-256 value"
      EXPECTED_IPA_SHA256="$2"
      shift 2
      ;;
    --inspect-testflight-verification)
      [[ "$MODE" == "validate" && -z "$INPUT_PATH" ]] \
        || fail "choose exactly one validation mode"
      MODE="inspect-testflight"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$INPUT_PATH" ]] || fail "only one evidence file may be supplied"
      INPUT_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$INPUT_PATH" ]] || fail "an evidence file is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"

if [[ "$MODE" == "inspect-testflight" ]]; then
  [[ -z "$EXPECTED_TESTFLIGHT_VERIFICATION" && -z "$EXPECTED_IPA_SHA256" \
      && "$OUTPUT_JSON" == false ]] \
    || fail "inspection mode does not accept expected-candidate options"
  inspect_testflight_verification "$INPUT_PATH"
  exit 0
fi

[[ -f "$INPUT_PATH" && ! -L "$INPUT_PATH" ]] \
  || fail "functional QA evidence must be an existing, non-symlink file"
EVIDENCE_ABSOLUTE="${INPUT_PATH:a}"
EVIDENCE_PATH="${INPUT_PATH:A}"
[[ "$EVIDENCE_ABSOLUTE" == "$EVIDENCE_PATH" ]] \
  || fail "functional QA evidence path must not traverse symlink parents"
[[ -d "${EVIDENCE_ABSOLUTE:h}" && ! -L "${EVIDENCE_ABSOLUTE:h}" ]] \
  || fail "functional QA evidence parent must be a non-symlink release directory"
RELEASE_DIRECTORY="${EVIDENCE_PATH:h}"
[[ "${EVIDENCE_PATH:t}" == ios-functional-verification-*.json ]] \
  || fail "functional QA evidence filename is not a generated evidence record"
[[ -d "$RELEASE_DIRECTORY" && ! -L "$RELEASE_DIRECTORY" ]] \
  || fail "functional QA evidence parent must be a non-symlink release directory"
[[ "$(/usr/bin/stat -f '%Sp' "$EVIDENCE_PATH")" != *w* ]] \
  || fail "functional QA evidence must be read-only (no write permission bits)"

/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "iOS" and
  .evidenceType == "exact-testflight-functional-qa" and
  (.testFlightVerification.path | type == "string" and length > 0) and
  (.testFlightVerification.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.testFlightVerification.testedAt | type == "string" and length > 0) and
  (.candidate.appBundleID | type == "string" and length > 0) and
  (.candidate.version | type == "string" and length > 0) and
  (.candidate.build | type == "string" and length > 0) and
  (.candidate.ipaPath | type == "string" and length > 0) and
  (.candidate.ipaSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.candidate.appStoreConnectBuildID | type == "string" and length > 0) and
  (.testDevice.model | type == "string" and length > 0) and
  .testDevice.operatingSystem == "iOS" and
  (.testDevice.osVersion | type == "string" and length > 0) and
  (.testedAt | type == "string" and length > 0) and
  (.createdAt | type == "string" and length > 0) and
  .qa.cloudKitProductionSchema.result == "passed" and
  .qa.cloudKitProductionSchema.environment == "Production" and
  .qa.cloudKitProductionSchema.schemaDeployed == true and
  .qa.sameICloudAccountSync.result == "passed" and
  .qa.sameICloudAccountSync.sameICloudAccountConfirmed == true and
  .qa.sameICloudAccountSync.macToIPhoneSyncConfirmed == true and
  .qa.liveActivity.result == "passed" and
  .qa.liveActivity.realDeviceConfirmed == true and
  .qa.reviewPath.result == "passed" and
  .qa.reviewPath.exampleModeConfirmed == true and
  .qa.reviewPath.productionPathConfirmed == true and
  all(.qa[];
    (.testedAt | type == "string" and length > 0) and
    (.evidence.path | type == "string" and length > 0) and
    (.evidence.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.evidence.sizeBytes | type == "number" and . > 0 and . <= 26214400)
  )
' "$EVIDENCE_PATH" >/dev/null \
  || fail "functional QA evidence is incomplete, contains false results, or has an unsupported schema"

TESTFLIGHT_PATH="$(/usr/bin/jq -r '.testFlightVerification.path' "$EVIDENCE_PATH")"
TESTFLIGHT_PATH="$(require_safe_release_file \
  "$TESTFLIGHT_PATH" "$RELEASE_DIRECTORY" "TestFlight verification evidence")"
[[ "$(file_sha256 "$TESTFLIGHT_PATH")" == \
    "$(/usr/bin/jq -r '.testFlightVerification.sha256' "$EVIDENCE_PATH")" ]] \
  || fail "TestFlight verification evidence SHA-256 does not match the functional QA record"

if [[ -n "$EXPECTED_TESTFLIGHT_VERIFICATION" ]]; then
  [[ -f "$EXPECTED_TESTFLIGHT_VERIFICATION" && ! -L "$EXPECTED_TESTFLIGHT_VERIFICATION" ]] \
    || fail "expected TestFlight verification evidence is not a regular non-symlink file"
  [[ "${EXPECTED_TESTFLIGHT_VERIFICATION:a}" == \
      "${EXPECTED_TESTFLIGHT_VERIFICATION:A}" ]] \
    || fail "expected TestFlight verification path must not traverse symlink parents"
  [[ "${EXPECTED_TESTFLIGHT_VERIFICATION:A}" == "$TESTFLIGHT_PATH" ]] \
    || fail "functional QA evidence is not bound to the expected TestFlight verification record"
fi
if [[ -n "$EXPECTED_IPA_SHA256" ]]; then
  print -r -- "$EXPECTED_IPA_SHA256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || fail "expected IPA SHA-256 is malformed"
fi

CANDIDATE_JSON="$(inspect_testflight_verification "$TESTFLIGHT_PATH")"
/usr/bin/jq -e \
  --argjson actual "$CANDIDATE_JSON" '
    .testFlightVerification.path == $actual.verificationPath and
    .testFlightVerification.sha256 == $actual.verificationSHA256 and
    .testFlightVerification.testedAt == $actual.verificationTestedAt and
    .candidate.appBundleID == $actual.appBundleID and
    .candidate.version == $actual.version and
    .candidate.build == $actual.build and
    .candidate.ipaPath == $actual.ipaPath and
    .candidate.ipaSHA256 == $actual.ipaSHA256 and
    .candidate.appStoreConnectBuildID == $actual.appStoreConnectBuildID
  ' "$EVIDENCE_PATH" >/dev/null \
  || fail "functional QA evidence candidate does not match the exact TestFlight IPA"
[[ -z "$EXPECTED_IPA_SHA256" || \
    "$(/usr/bin/jq -r '.candidate.ipaSHA256' "$EVIDENCE_PATH")" == "$EXPECTED_IPA_SHA256" ]] \
  || fail "functional QA evidence is not bound to the expected IPA SHA-256"

DEVICE_MODEL="$(/usr/bin/jq -r '.testDevice.model' "$EVIDENCE_PATH")"
IOS_VERSION="$(/usr/bin/jq -r '.testDevice.osVersion' "$EVIDENCE_PATH")"
placeholder_text "$DEVICE_MODEL" && fail "test device model is a placeholder"
placeholder_text "$IOS_VERSION" && fail "iOS version is a placeholder"
[[ ${#DEVICE_MODEL} -le 128 && ${#IOS_VERSION} -le 64 ]] \
  || fail "test device model or iOS version is unreasonably long"
print -r -- "$DEVICE_MODEL$IOS_VERSION" | LC_ALL=C /usr/bin/grep -Eq '[0-9]' \
  || fail "test device model and iOS version must include a concrete version or model number"

TESTED_AT="$(/usr/bin/jq -r '.testedAt' "$EVIDENCE_PATH")"
CREATED_AT="$(/usr/bin/jq -r '.createdAt' "$EVIDENCE_PATH")"
TESTFLIGHT_TESTED_AT="$(/usr/bin/jq -r '.testFlightVerification.testedAt' "$EVIDENCE_PATH")"
for timestamp in "$TESTED_AT" "$CREATED_AT" "$TESTFLIGHT_TESTED_AT"; do
  valid_utc_timestamp "$timestamp" \
    || fail "functional QA evidence contains an invalid UTC timestamp"
done
[[ "$(/usr/bin/jq -r '[.qa[].testedAt] | unique | length' "$EVIDENCE_PATH")" == "1" ]] \
  || fail "all four QA checks must record the exact functional test timestamp"
[[ "$(/usr/bin/jq -r '.qa[].testedAt' "$EVIDENCE_PATH" | /usr/bin/head -n 1)" == "$TESTED_AT" ]] \
  || fail "per-check test timestamps do not match the functional QA test timestamp"
TF_TESTED_EPOCH="$(timestamp_epoch "$TESTFLIGHT_TESTED_AT")"
TESTED_EPOCH="$(timestamp_epoch "$TESTED_AT")"
CREATED_EPOCH="$(timestamp_epoch "$CREATED_AT")"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( TF_TESTED_EPOCH <= TESTED_EPOCH \
  && TESTED_EPOCH <= CREATED_EPOCH \
  && CREATED_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "functional QA timestamps precede TestFlight installation or are in the future"

typeset -a ATTACHMENT_PATHS ATTACHMENT_FILE_IDENTITIES ATTACHMENT_SHA256S
FUNCTIONAL_EVIDENCE_SHA256="$(file_sha256 "$EVIDENCE_PATH")"
for check_name in cloudKitProductionSchema sameICloudAccountSync liveActivity reviewPath; do
  attachment_path="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.path' "$EVIDENCE_PATH")"
  attachment_sha256="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.sha256' "$EVIDENCE_PATH")"
  attachment_size="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.sizeBytes' "$EVIDENCE_PATH")"
  attachment_path="$(require_safe_release_file \
    "$attachment_path" "$RELEASE_DIRECTORY" "$check_name QA attachment")"
  [[ "$attachment_path" != "$EVIDENCE_PATH" && "$attachment_path" != "$TESTFLIGHT_PATH" ]] \
    || fail "$check_name QA attachment cannot be an evidence record"
  for artifact_key in ipaPath releaseMetadataPath deliveryRecordPath \
      validationResultPath uploadResultPath; do
    [[ "$attachment_path" != "$(print -r -- "$CANDIDATE_JSON" \
        | /usr/bin/jq -r --arg key "$artifact_key" '.[$key]')" ]] \
      || fail "$check_name QA attachment cannot reuse a release artifact"
  done
  attachment_extension="${${attachment_path:e}:l}"
  case "$attachment_extension" in
    txt|md|json|png|jpg|jpeg|heic|pdf|mov|mp4) ;;
    *) fail "$check_name QA attachment has an unsupported report format" ;;
  esac
  actual_size="$(/usr/bin/stat -f '%z' "$attachment_path")"
  [[ "$actual_size" == "$attachment_size" && "$actual_size" -gt 0 \
      && "$actual_size" -le 26214400 ]] \
    || fail "$check_name QA attachment size does not match the functional QA record"
  actual_attachment_sha256="$(file_sha256 "$attachment_path")"
  [[ "$actual_attachment_sha256" == "$attachment_sha256" ]] \
    || fail "$check_name QA attachment SHA-256 does not match the functional QA record"
  for core_hash_key in ipaSHA256 releaseMetadataSHA256 deliveryRecordSHA256 \
      validationResultSHA256 uploadResultSHA256 verificationSHA256; do
    core_hash="$(print -r -- "$CANDIDATE_JSON" \
      | /usr/bin/jq -r --arg key "$core_hash_key" '.[$key]')"
    [[ "$actual_attachment_sha256" != "$core_hash" ]] \
      || fail "$check_name QA attachment content duplicates a core release artifact or evidence record"
  done
  [[ "$actual_attachment_sha256" != "$FUNCTIONAL_EVIDENCE_SHA256" ]] \
    || fail "$check_name QA attachment content duplicates a core release artifact or evidence record"
  ATTACHMENT_PATHS+=("$attachment_path")
  ATTACHMENT_FILE_IDENTITIES+=("$(/usr/bin/stat -f '%d:%i' "$attachment_path")")
  ATTACHMENT_SHA256S+=("$actual_attachment_sha256")
done
[[ "$(print -rl -- "${ATTACHMENT_PATHS[@]}" | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA checks must use four distinct evidence attachments"
[[ "$(print -rl -- "${ATTACHMENT_FILE_IDENTITIES[@]}" | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA attachments must have four distinct device:inode identities"
[[ "$(print -rl -- "${ATTACHMENT_SHA256S[@]}" | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA attachments must have four distinct content SHA-256 values"

if [[ "$OUTPUT_JSON" == true ]]; then
  /usr/bin/jq -n \
    --arg path "$EVIDENCE_PATH" \
    --arg sha256 "$FUNCTIONAL_EVIDENCE_SHA256" \
    --arg deviceModel "$DEVICE_MODEL" \
    --arg osVersion "$IOS_VERSION" \
    --arg testedAt "$TESTED_AT" \
    --argjson candidate "$CANDIDATE_JSON" '{
      evidenceReady: true,
      evidencePath: $path,
      evidenceSHA256: $sha256,
      candidate: {
        appBundleID: $candidate.appBundleID,
        version: $candidate.version,
        build: $candidate.build,
        ipaPath: $candidate.ipaPath,
        ipaSHA256: $candidate.ipaSHA256,
        appStoreConnectBuildID: $candidate.appStoreConnectBuildID
      },
      testDevice: {
        model: $deviceModel,
        operatingSystem: "iOS",
        osVersion: $osVersion
      },
      testedAt: $testedAt,
      cloudKitProductionSchemaVerified: true,
      realDeviceSyncVerified: true,
      liveActivityVerified: true,
      reviewPathVerified: true
    }'
else
  print -r -- "iOS functional QA evidence is valid: $EVIDENCE_PATH"
  print -r -- "Candidate: $(/usr/bin/jq -r '.candidate.appBundleID + ":" + .candidate.version + ":" + .candidate.build' "$EVIDENCE_PATH")"
  print -r -- "IPA SHA-256: $(/usr/bin/jq -r '.candidate.ipaSHA256' "$EVIDENCE_PATH")"
  print -r -- "This validation is local and does not re-query App Store Connect."
fi
