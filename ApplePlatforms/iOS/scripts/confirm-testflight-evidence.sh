#!/bin/zsh
set -euo pipefail
umask 077

IOS_ROOT="${0:A:h:h}"
DELIVERY_RECORD_INPUT=""
PROCESSING_STATE=""
APP_STORE_CONNECT_BUILD_ID=""
PROCESSING_VERIFIED_AT=""
TESTED_AT=""
DISTRIBUTED_CONFIRMED=false
INSTALL_CONFIRMED=false

usage() {
  /bin/cat <<'EOF'
Usage:
  ./scripts/confirm-testflight-evidence.sh \
    --processing-state VALID|Complete \
    --app-store-connect-build-id BUILD_ID \
    --processing-verified-at YYYY-MM-DDTHH:MM:SSZ \
    --distributed-to-testers \
    --installed-from-testflight \
    --tested-at YYYY-MM-DDTHH:MM:SSZ \
    TESTFLIGHT_DELIVERY_RECORD.json

Records locally verified post-upload evidence for one exact iOS IPA. This
script never contacts Apple, uploads a build, distributes a build, or changes
App Store Connect. Before running it, independently inspect App Store Connect
and a real TestFlight installation.

Set AGENT_ISLAND_CONFIRM_TESTFLIGHT_VERIFICATION to the exact
bundle:version:build:IPA-SHA256 value printed by submit-testflight.sh --check.
The resulting testflight-verification-*.json is created beside the delivery
record and is never overwritten.
EOF
}

fail() {
  print -u2 -r -- "TestFlight evidence confirmation failed: $*"
  exit 2
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

while (( $# > 0 )); do
  case "$1" in
    --processing-state)
      (( $# >= 2 )) || fail "--processing-state requires VALID or Complete"
      PROCESSING_STATE="$2"
      shift 2
      ;;
    --app-store-connect-build-id)
      (( $# >= 2 )) || fail "--app-store-connect-build-id requires a value"
      APP_STORE_CONNECT_BUILD_ID="$2"
      shift 2
      ;;
    --processing-verified-at)
      (( $# >= 2 )) || fail "--processing-verified-at requires a UTC timestamp"
      PROCESSING_VERIFIED_AT="$2"
      shift 2
      ;;
    --distributed-to-testers)
      [[ "$DISTRIBUTED_CONFIRMED" == false ]] \
        || fail "--distributed-to-testers may be supplied only once"
      DISTRIBUTED_CONFIRMED=true
      shift
      ;;
    --installed-from-testflight)
      [[ "$INSTALL_CONFIRMED" == false ]] \
        || fail "--installed-from-testflight may be supplied only once"
      INSTALL_CONFIRMED=true
      shift
      ;;
    --tested-at)
      (( $# >= 2 )) || fail "--tested-at requires a UTC timestamp"
      TESTED_AT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$DELIVERY_RECORD_INPUT" ]] \
        || fail "only one delivery record may be supplied"
      DELIVERY_RECORD_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$DELIVERY_RECORD_INPUT" ]] || fail "a TestFlight delivery record is required"
[[ "$PROCESSING_STATE" == "VALID" || "$PROCESSING_STATE" == "Complete" ]] \
  || fail "--processing-state must be exactly VALID or Complete"
[[ -n "$APP_STORE_CONNECT_BUILD_ID" && ${#APP_STORE_CONNECT_BUILD_ID} -le 256 ]] \
  || fail "--app-store-connect-build-id must be a non-empty value of at most 256 characters"
print -r -- "$APP_STORE_CONNECT_BUILD_ID" | LC_ALL=C /usr/bin/grep -Eq '^[[:graph:]]+$' \
  || fail "--app-store-connect-build-id must not contain whitespace or control characters"
[[ "$DISTRIBUTED_CONFIRMED" == true ]] \
  || fail "--distributed-to-testers is required after verifying tester availability"
[[ "$INSTALL_CONFIRMED" == true ]] \
  || fail "--installed-from-testflight is required after a real-device installation"

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
}

valid_utc_timestamp "$PROCESSING_VERIFIED_AT" \
  || fail "--processing-verified-at must be a real UTC timestamp ending in Z"
valid_utc_timestamp "$TESTED_AT" \
  || fail "--tested-at must be a real UTC timestamp ending in Z"
PROCESSING_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$PROCESSING_VERIFIED_AT" '+%s')"
TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$TESTED_AT" '+%s')"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( PROCESSING_EPOCH <= TESTED_EPOCH )) \
  || fail "processingVerifiedAt must not be later than testedAt"
(( TESTED_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "testedAt must not be more than five minutes in the future"

[[ -f "$DELIVERY_RECORD_INPUT" && ! -L "$DELIVERY_RECORD_INPUT" ]] \
  || fail "delivery record must be an existing, non-symlink file"
DELIVERY_RECORD_ABSOLUTE="${DELIVERY_RECORD_INPUT:a}"
DELIVERY_RECORD_PATH="${DELIVERY_RECORD_INPUT:A}"
[[ "$DELIVERY_RECORD_ABSOLUTE" == "$DELIVERY_RECORD_PATH" ]] \
  || fail "delivery record path must not traverse symlink parents"
[[ -d "${DELIVERY_RECORD_ABSOLUTE:h}" && ! -L "${DELIVERY_RECORD_ABSOLUTE:h}" ]] \
  || fail "delivery record parent must be a non-symlink release directory"
RELEASE_DIRECTORY="${DELIVERY_RECORD_PATH:h}"
[[ -d "$RELEASE_DIRECTORY" && ! -L "$RELEASE_DIRECTORY" ]] \
  || fail "delivery record parent must be a non-symlink release directory"
[[ "${DELIVERY_RECORD_PATH:t}" == testflight-delivery-*.json ]] \
  || fail "delivery record filename is not a generated TestFlight delivery record"
require_readonly_file "$DELIVERY_RECORD_PATH" "delivery record"

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"

/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "iOS" and
  .destination == "App Store Connect / TestFlight" and
  (.submittedAt | type == "string" and length > 0) and
  (.appBundleID | type == "string" and length > 0) and
  (.version | type == "string" and length > 0) and
  (.build | type == "string" and length > 0) and
  (.ipaPath | type == "string" and length > 0) and
  (.ipaSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.releaseMetadataPath | type == "string" and length > 0) and
  (.releaseMetadataSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.validationResultPath | type == "string" and length > 0) and
  (.validationResultSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.uploadResultPath | type == "string" and length > 0) and
  (.uploadResultSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  .uploadAccepted == true and
  .processingState == null and
  .appStoreConnectBuildID == null and
  .processingVerified == false and
  .processingVerifiedAt == null and
  .distributedToTesters == false and
  .installedFromTestFlight == false and
  .testedAt == null and
  .submittedForAppReview == false
' "$DELIVERY_RECORD_PATH" >/dev/null \
  || fail "delivery record is incomplete, already post-processed, or has an unsupported schema"

APP_BUNDLE_ID="$(/usr/bin/jq -r '.appBundleID' "$DELIVERY_RECORD_PATH")"
VERSION="$(/usr/bin/jq -r '.version' "$DELIVERY_RECORD_PATH")"
BUILD_NUMBER="$(/usr/bin/jq -r '.build' "$DELIVERY_RECORD_PATH")"
IPA_PATH="$(/usr/bin/jq -r '.ipaPath' "$DELIVERY_RECORD_PATH")"
IPA_SHA256="$(/usr/bin/jq -r '.ipaSHA256' "$DELIVERY_RECORD_PATH")"
RELEASE_METADATA_PATH="$(/usr/bin/jq -r '.releaseMetadataPath' "$DELIVERY_RECORD_PATH")"
RELEASE_METADATA_SHA256="$(/usr/bin/jq -r '.releaseMetadataSHA256' "$DELIVERY_RECORD_PATH")"
VALIDATION_RESULT_PATH="$(/usr/bin/jq -r '.validationResultPath' "$DELIVERY_RECORD_PATH")"
VALIDATION_RESULT_SHA256="$(/usr/bin/jq -r '.validationResultSHA256' "$DELIVERY_RECORD_PATH")"
UPLOAD_RESULT_PATH="$(/usr/bin/jq -r '.uploadResultPath' "$DELIVERY_RECORD_PATH")"
UPLOAD_RESULT_SHA256="$(/usr/bin/jq -r '.uploadResultSHA256' "$DELIVERY_RECORD_PATH")"

require_safe_release_file() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and contain no symlink traversal"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

IPA_PATH="$(require_safe_release_file "$IPA_PATH" "IPA")"
RELEASE_METADATA_PATH="$(require_safe_release_file \
  "$RELEASE_METADATA_PATH" "release metadata")"
VALIDATION_RESULT_PATH="$(require_safe_release_file \
  "$VALIDATION_RESULT_PATH" "validation result")"
UPLOAD_RESULT_PATH="$(require_safe_release_file "$UPLOAD_RESULT_PATH" "upload result")"
[[ "$RELEASE_METADATA_PATH" == "$RELEASE_DIRECTORY/release-metadata.json" ]] \
  || fail "delivery record does not reference this release directory's metadata"
require_readonly_file "$VALIDATION_RESULT_PATH" "validation result"
require_readonly_file "$UPLOAD_RESULT_PATH" "upload result"
require_shared_delivery_stamp "$DELIVERY_RECORD_PATH" \
  "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH"

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

[[ "$(file_sha256 "$IPA_PATH")" == "$IPA_SHA256" ]] \
  || fail "current IPA SHA-256 differs from the delivery record"
[[ "$(file_sha256 "$RELEASE_METADATA_PATH")" == "$RELEASE_METADATA_SHA256" ]] \
  || fail "current release metadata SHA-256 differs from the delivery record"
[[ "$(file_sha256 "$VALIDATION_RESULT_PATH")" == "$VALIDATION_RESULT_SHA256" ]] \
  || fail "current validation result differs from the delivery record"
[[ "$(file_sha256 "$UPLOAD_RESULT_PATH")" == "$UPLOAD_RESULT_SHA256" ]] \
  || fail "current upload result differs from the delivery record"
verify_app_store_result_success_json "$VALIDATION_RESULT_PATH" "validation"
verify_app_store_result_success_json "$UPLOAD_RESULT_PATH" "upload"

/usr/bin/jq -e \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$IPA_SHA256" '
    .schemaVersion == 1 and
    .appBundleID == $appBundleID and
    .version == $version and
    .build == $build and
    .exportedIPA == $ipaPath and
    .ipaSHA256 == $ipaSHA256 and
    .uploaded == false
  ' "$RELEASE_METADATA_PATH" >/dev/null \
  || fail "release metadata and delivery record do not identify the same IPA"

"$IOS_ROOT/scripts/submit-testflight.sh" --check "$RELEASE_DIRECTORY" >/dev/null \
  || fail "the exact IPA no longer passes the local submission preflight"

SUBMITTED_AT="$(/usr/bin/jq -r '.submittedAt' "$DELIVERY_RECORD_PATH")"
valid_utc_timestamp "$SUBMITTED_AT" \
  || fail "delivery record submittedAt is not a valid UTC timestamp"
SUBMITTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$SUBMITTED_AT" '+%s')"
(( SUBMITTED_EPOCH <= PROCESSING_EPOCH )) \
  || fail "processingVerifiedAt must not be earlier than the recorded upload"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$IPA_SHA256"
[[ "${AGENT_ISLAND_CONFIRM_TESTFLIGHT_VERIFICATION:-}" == "$CONFIRMATION_VALUE" ]] \
  || fail "AGENT_ISLAND_CONFIRM_TESTFLIGHT_VERIFICATION does not match this exact IPA"

DELIVERY_RECORD_SHA256="$(file_sha256 "$DELIVERY_RECORD_PATH")"
CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_PATH="$RELEASE_DIRECTORY/testflight-verification-$STAMP.json"
[[ ! -e "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" ]] \
  || fail "refusing to overwrite an existing TestFlight verification evidence file"
TEMP_EVIDENCE_PATH="$(mktemp "$RELEASE_DIRECTORY/.testflight-verification.XXXXXX")"
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  [[ -n "$TEMP_EVIDENCE_PATH" && -f "$TEMP_EVIDENCE_PATH" ]] \
    && /bin/rm -f "$TEMP_EVIDENCE_PATH"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/jq -n \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg releaseMetadataPath "$RELEASE_METADATA_PATH" \
  --arg releaseMetadataSHA256 "$RELEASE_METADATA_SHA256" \
  --arg deliveryRecordPath "$DELIVERY_RECORD_PATH" \
  --arg deliveryRecordSHA256 "$DELIVERY_RECORD_SHA256" \
  --arg appStoreConnectBuildID "$APP_STORE_CONNECT_BUILD_ID" \
  --arg processingState "$PROCESSING_STATE" \
  --arg processingVerifiedAt "$PROCESSING_VERIFIED_AT" \
  --arg testedAt "$TESTED_AT" \
  --arg createdAt "$CREATED_AT" '{
    schemaVersion: 1,
    platform: "iOS",
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    ipaPath: $ipaPath,
    ipaSHA256: $ipaSHA256,
    releaseMetadataPath: $releaseMetadataPath,
    releaseMetadataSHA256: $releaseMetadataSHA256,
    deliveryRecordPath: $deliveryRecordPath,
    deliveryRecordSHA256: $deliveryRecordSHA256,
    uploadAccepted: true,
    appStoreConnectBuildID: $appStoreConnectBuildID,
    processingState: $processingState,
    processingVerifiedAt: $processingVerifiedAt,
    distributedToTesters: true,
    installedFromTestFlight: true,
    testedAt: $testedAt,
    createdAt: $createdAt
  }' >"$TEMP_EVIDENCE_PATH"
/bin/chmod 0444 "$TEMP_EVIDENCE_PATH" \
  || fail "could not seal verification evidence before publication"
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .platform == "iOS" and
  .uploadAccepted == true and
  (.appStoreConnectBuildID | type == "string" and length > 0) and
  (.processingState == "VALID" or .processingState == "Complete") and
  (.processingVerifiedAt | type == "string" and length > 0) and
  .distributedToTesters == true and
  .installedFromTestFlight == true and
  (.testedAt | type == "string" and length > 0) and
  (.createdAt | type == "string" and length > 0)
' "$TEMP_EVIDENCE_PATH" >/dev/null \
  || fail "generated verification evidence failed its schema contract"

# A hard link on the same release volume is an atomic no-overwrite publish.
# The temporary inode is already read-only and validated before the destination
# name becomes visible, including when an attacker pre-creates a symlink.
publish_readonly_no_overwrite "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH" \
  "TestFlight verification evidence"
TEMP_EVIDENCE_PATH=""

print -r -- "TestFlight verification evidence recorded: $EVIDENCE_PATH"
print -r -- "This local record does not modify or re-query App Store Connect."
