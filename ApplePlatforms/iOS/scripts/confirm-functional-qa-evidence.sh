#!/bin/zsh
set -euo pipefail

IOS_ROOT="${0:A:h:h}"
VALIDATOR="$IOS_ROOT/scripts/validate-functional-qa-evidence.sh"
TESTFLIGHT_VERIFICATION_INPUT=""
DEVICE_MODEL=""
IOS_VERSION=""
TESTED_AT=""
OUTPUT_INPUT=""
CLOUDKIT_RESULT=""
CLOUDKIT_EVIDENCE_INPUT=""
SYNC_RESULT=""
SYNC_EVIDENCE_INPUT=""
LIVE_ACTIVITY_RESULT=""
LIVE_ACTIVITY_EVIDENCE_INPUT=""
REVIEW_PATH_RESULT=""
REVIEW_PATH_EVIDENCE_INPUT=""

usage() {
  /bin/cat <<'EOF'
Usage:
  AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA='<bundle:version:build:IPA-SHA256>' \
    ./scripts/confirm-functional-qa-evidence.sh \
      --device-model 'iPhone 16 Pro' \
      --ios-version '18.6.2' \
      --tested-at 'YYYY-MM-DDTHH:MM:SSZ' \
      --cloudkit-production-schema-result passed \
      --cloudkit-evidence /absolute/path/to/cloudkit-report \
      --same-account-sync-result passed \
      --sync-evidence /absolute/path/to/sync-report \
      --live-activity-result passed \
      --live-activity-evidence /absolute/path/to/live-activity-report \
      --review-path-result passed \
      --review-path-evidence /absolute/path/to/review-path-report \
      [--output /absolute/path/to/ios-functional-verification-NAME.json] \
      TESTFLIGHT_VERIFICATION.json

Creates one read-only, no-overwrite functional-QA record beside the exact
TestFlight verification record. Each of the four checks must be explicitly
"passed" and must have a distinct, non-empty attachment in the same release
directory. Attachments may be redacted text, JSON, or images; their paths,
sizes, and SHA-256 values are bound into the record.

This tool validates local artifacts only. It neither queries nor changes App
Store Connect, and it does not turn an operator assertion into Apple evidence.
EOF
}

fail() {
  print -u2 -r -- "iOS functional QA evidence confirmation failed: $*"
  exit 2
}

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
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

while (( $# > 0 )); do
  case "$1" in
    --device-model)
      (( $# >= 2 )) || fail "--device-model requires a value"
      [[ -z "$DEVICE_MODEL" ]] || fail "--device-model may be supplied only once"
      DEVICE_MODEL="$2"
      shift 2
      ;;
    --ios-version)
      (( $# >= 2 )) || fail "--ios-version requires a value"
      [[ -z "$IOS_VERSION" ]] || fail "--ios-version may be supplied only once"
      IOS_VERSION="$2"
      shift 2
      ;;
    --tested-at)
      (( $# >= 2 )) || fail "--tested-at requires a UTC timestamp"
      [[ -z "$TESTED_AT" ]] || fail "--tested-at may be supplied only once"
      TESTED_AT="$2"
      shift 2
      ;;
    --cloudkit-production-schema-result)
      (( $# >= 2 )) || fail "--cloudkit-production-schema-result requires passed"
      [[ -z "$CLOUDKIT_RESULT" ]] \
        || fail "--cloudkit-production-schema-result may be supplied only once"
      CLOUDKIT_RESULT="$2"
      shift 2
      ;;
    --cloudkit-evidence)
      (( $# >= 2 )) || fail "--cloudkit-evidence requires an absolute file path"
      [[ -z "$CLOUDKIT_EVIDENCE_INPUT" ]] \
        || fail "--cloudkit-evidence may be supplied only once"
      CLOUDKIT_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --same-account-sync-result)
      (( $# >= 2 )) || fail "--same-account-sync-result requires passed"
      [[ -z "$SYNC_RESULT" ]] \
        || fail "--same-account-sync-result may be supplied only once"
      SYNC_RESULT="$2"
      shift 2
      ;;
    --sync-evidence)
      (( $# >= 2 )) || fail "--sync-evidence requires an absolute file path"
      [[ -z "$SYNC_EVIDENCE_INPUT" ]] \
        || fail "--sync-evidence may be supplied only once"
      SYNC_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --live-activity-result)
      (( $# >= 2 )) || fail "--live-activity-result requires passed"
      [[ -z "$LIVE_ACTIVITY_RESULT" ]] \
        || fail "--live-activity-result may be supplied only once"
      LIVE_ACTIVITY_RESULT="$2"
      shift 2
      ;;
    --live-activity-evidence)
      (( $# >= 2 )) || fail "--live-activity-evidence requires an absolute file path"
      [[ -z "$LIVE_ACTIVITY_EVIDENCE_INPUT" ]] \
        || fail "--live-activity-evidence may be supplied only once"
      LIVE_ACTIVITY_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --review-path-result)
      (( $# >= 2 )) || fail "--review-path-result requires passed"
      [[ -z "$REVIEW_PATH_RESULT" ]] \
        || fail "--review-path-result may be supplied only once"
      REVIEW_PATH_RESULT="$2"
      shift 2
      ;;
    --review-path-evidence)
      (( $# >= 2 )) || fail "--review-path-evidence requires an absolute file path"
      [[ -z "$REVIEW_PATH_EVIDENCE_INPUT" ]] \
        || fail "--review-path-evidence may be supplied only once"
      REVIEW_PATH_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || fail "--output requires a path"
      [[ -z "$OUTPUT_INPUT" ]] || fail "--output may be supplied only once"
      OUTPUT_INPUT="$2"
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
      [[ -z "$TESTFLIGHT_VERIFICATION_INPUT" ]] \
        || fail "only one TestFlight verification record may be supplied"
      TESTFLIGHT_VERIFICATION_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$TESTFLIGHT_VERIFICATION_INPUT" ]] \
  || fail "a TestFlight verification evidence file is required"
[[ -x "$VALIDATOR" ]] || fail "validate-functional-qa-evidence.sh is missing or not executable"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"

for result_name in CLOUDKIT_RESULT SYNC_RESULT LIVE_ACTIVITY_RESULT REVIEW_PATH_RESULT; do
  result_value="${(P)result_name}"
  [[ "$result_value" == "passed" ]] \
    || fail "all four functional QA results must be exactly passed; false, failed, and placeholders are rejected"
done
[[ -n "$CLOUDKIT_EVIDENCE_INPUT" && -n "$SYNC_EVIDENCE_INPUT" \
    && -n "$LIVE_ACTIVITY_EVIDENCE_INPUT" && -n "$REVIEW_PATH_EVIDENCE_INPUT" ]] \
  || fail "all four functional QA evidence attachments are required"
placeholder_text "$DEVICE_MODEL" && fail "--device-model is missing or a placeholder"
placeholder_text "$IOS_VERSION" && fail "--ios-version is missing or a placeholder"
[[ ${#DEVICE_MODEL} -le 128 && ${#IOS_VERSION} -le 64 ]] \
  || fail "device model or iOS version is unreasonably long"
print -r -- "$DEVICE_MODEL$IOS_VERSION" | LC_ALL=C /usr/bin/grep -Eq '[0-9]' \
  || fail "device model and iOS version must include a concrete version or model number"
valid_utc_timestamp "$TESTED_AT" \
  || fail "--tested-at must be a real UTC timestamp ending in Z"

CANDIDATE_JSON="$("$VALIDATOR" --inspect-testflight-verification \
  "$TESTFLIGHT_VERIFICATION_INPUT")" \
  || fail "the supplied TestFlight verification evidence is not valid"
APP_BUNDLE_ID="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.appBundleID')"
VERSION="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.version')"
BUILD_NUMBER="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.build')"
IPA_PATH="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.ipaPath')"
IPA_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.ipaSHA256')"
APP_STORE_CONNECT_BUILD_ID="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.appStoreConnectBuildID')"
RELEASE_METADATA_PATH="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.releaseMetadataPath')"
RELEASE_METADATA_SHA256="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.releaseMetadataSHA256')"
DELIVERY_RECORD_PATH="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.deliveryRecordPath')"
DELIVERY_RECORD_SHA256="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.deliveryRecordSHA256')"
VALIDATION_RESULT_PATH="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.validationResultPath')"
VALIDATION_RESULT_SHA256="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.validationResultSHA256')"
UPLOAD_RESULT_PATH="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.uploadResultPath')"
UPLOAD_RESULT_SHA256="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.uploadResultSHA256')"
RELEASE_DIRECTORY="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.releaseDirectory')"
TESTFLIGHT_VERIFICATION_PATH="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.verificationPath')"
TESTFLIGHT_VERIFICATION_SHA256="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.verificationSHA256')"
TESTFLIGHT_TESTED_AT="$(print -r -- "$CANDIDATE_JSON" \
  | /usr/bin/jq -r '.verificationTestedAt')"

TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$TESTED_AT" '+%s')"
TESTFLIGHT_TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$TESTFLIGHT_TESTED_AT" '+%s')"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( TESTFLIGHT_TESTED_EPOCH <= TESTED_EPOCH )) \
  || fail "--tested-at must not precede the recorded TestFlight installation test"
(( TESTED_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "--tested-at must not be more than five minutes in the future"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$IPA_SHA256"
[[ "${AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA:-}" == "$CONFIRMATION_VALUE" ]] \
  || fail "AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA does not match this exact TestFlight IPA"

require_attachment() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and contain no symlink traversal"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label must be stored inside the exact TestFlight release directory"
  for release_artifact in "$IPA_PATH" "$RELEASE_METADATA_PATH" \
      "$DELIVERY_RECORD_PATH" "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH" \
      "$TESTFLIGHT_VERIFICATION_PATH"; do
    [[ "$canonical_path" != "$release_artifact" ]] \
      || fail "$label cannot reuse a release artifact"
  done
  local attachment_extension="${${canonical_path:e}:l}"
  case "$attachment_extension" in
    txt|md|json|png|jpg|jpeg|heic|pdf|mov|mp4) ;;
    *) fail "$label has an unsupported report format" ;;
  esac
  local size_bytes="$(/usr/bin/stat -f '%z' "$canonical_path")"
  [[ "$size_bytes" -gt 0 && "$size_bytes" -le 26214400 ]] \
    || fail "$label must be non-empty and no larger than 25 MiB"
  print -r -- "$canonical_path"
}

CLOUDKIT_EVIDENCE_PATH="$(require_attachment "$CLOUDKIT_EVIDENCE_INPUT" \
  "CloudKit Production schema evidence")"
SYNC_EVIDENCE_PATH="$(require_attachment "$SYNC_EVIDENCE_INPUT" \
  "same-iCloud-account sync evidence")"
LIVE_ACTIVITY_EVIDENCE_PATH="$(require_attachment "$LIVE_ACTIVITY_EVIDENCE_INPUT" \
  "Live Activity evidence")"
REVIEW_PATH_EVIDENCE_PATH="$(require_attachment "$REVIEW_PATH_EVIDENCE_INPUT" \
  "review-path evidence")"
typeset -a ATTACHMENT_PATHS ATTACHMENT_FILE_IDENTITIES ATTACHMENT_SHA256S ATTACHMENT_SIZES
ATTACHMENT_PATHS=("$CLOUDKIT_EVIDENCE_PATH" "$SYNC_EVIDENCE_PATH" \
  "$LIVE_ACTIVITY_EVIDENCE_PATH" "$REVIEW_PATH_EVIDENCE_PATH")
for attachment_path in "${ATTACHMENT_PATHS[@]}"; do
  attachment_sha256="$(file_sha256 "$attachment_path")"
  for core_sha256 in "$IPA_SHA256" "$RELEASE_METADATA_SHA256" \
      "$DELIVERY_RECORD_SHA256" "$VALIDATION_RESULT_SHA256" \
      "$UPLOAD_RESULT_SHA256" "$TESTFLIGHT_VERIFICATION_SHA256"; do
    [[ "$attachment_sha256" != "$core_sha256" ]] \
      || fail "QA attachment content cannot duplicate a core release artifact or evidence record"
  done
  ATTACHMENT_FILE_IDENTITIES+=("$(/usr/bin/stat -f '%d:%i' "$attachment_path")")
  ATTACHMENT_SHA256S+=("$attachment_sha256")
  ATTACHMENT_SIZES+=("$(/usr/bin/stat -f '%z' "$attachment_path")")
done
[[ "$(print -rl -- "${ATTACHMENT_PATHS[@]}" \
      | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA checks must use four distinct evidence attachments"
[[ "$(print -rl -- "${ATTACHMENT_FILE_IDENTITIES[@]}" \
      | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA attachments must have four distinct device:inode identities"
[[ "$(print -rl -- "${ATTACHMENT_SHA256S[@]}" \
      | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] \
  || fail "the four QA attachments must have four distinct content SHA-256 values"

if [[ -n "$OUTPUT_INPUT" ]]; then
  OUTPUT_PARENT="${OUTPUT_INPUT:h:A}"
  [[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
    || fail "--output parent must be an existing, non-symlink directory"
  EVIDENCE_PATH="$OUTPUT_PARENT/${OUTPUT_INPUT:t}"
else
  STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  EVIDENCE_PATH="$RELEASE_DIRECTORY/ios-functional-verification-$STAMP.json"
fi
[[ "${EVIDENCE_PATH:h}" == "$RELEASE_DIRECTORY" ]] \
  || fail "functional QA evidence must be created in the exact TestFlight release directory"
[[ "${EVIDENCE_PATH:t}" == ios-functional-verification-*.json ]] \
  || fail "functional QA evidence filename must match ios-functional-verification-*.json"
[[ ! -e "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" ]] \
  || fail "refusing to overwrite an existing iOS functional QA evidence file"

CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
TEMP_EVIDENCE_PATH="$(mktemp "$RELEASE_DIRECTORY/.ios-functional-verification.XXXXXX")"
PUBLISHED=false
PUBLISHED_IDENTITY=""
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  [[ -n "${TEMP_EVIDENCE_PATH:-}" && -f "$TEMP_EVIDENCE_PATH" ]] \
    && /bin/rm -f "$TEMP_EVIDENCE_PATH"
  if [[ "$exit_code" -ne 0 && "$PUBLISHED" == true && -n "$PUBLISHED_IDENTITY" \
      && -f "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" \
      && "$(/usr/bin/stat -f '%d:%i' "$EVIDENCE_PATH")" == "$PUBLISHED_IDENTITY" ]]; then
    /bin/rm -f "$EVIDENCE_PATH"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/jq -n \
  --arg testFlightPath "$TESTFLIGHT_VERIFICATION_PATH" \
  --arg testFlightSHA256 "$TESTFLIGHT_VERIFICATION_SHA256" \
  --arg testFlightTestedAt "$TESTFLIGHT_TESTED_AT" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg ipaPath "$IPA_PATH" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg appStoreConnectBuildID "$APP_STORE_CONNECT_BUILD_ID" \
  --arg deviceModel "$DEVICE_MODEL" \
  --arg iosVersion "$IOS_VERSION" \
  --arg testedAt "$TESTED_AT" \
  --arg createdAt "$CREATED_AT" \
  --arg cloudKitPath "$CLOUDKIT_EVIDENCE_PATH" \
  --arg cloudKitSHA256 "${ATTACHMENT_SHA256S[1]}" \
  --argjson cloudKitSize "${ATTACHMENT_SIZES[1]}" \
  --arg syncPath "$SYNC_EVIDENCE_PATH" \
  --arg syncSHA256 "${ATTACHMENT_SHA256S[2]}" \
  --argjson syncSize "${ATTACHMENT_SIZES[2]}" \
  --arg liveActivityPath "$LIVE_ACTIVITY_EVIDENCE_PATH" \
  --arg liveActivitySHA256 "${ATTACHMENT_SHA256S[3]}" \
  --argjson liveActivitySize "${ATTACHMENT_SIZES[3]}" \
  --arg reviewPathPath "$REVIEW_PATH_EVIDENCE_PATH" \
  --arg reviewPathSHA256 "${ATTACHMENT_SHA256S[4]}" \
  --argjson reviewPathSize "${ATTACHMENT_SIZES[4]}" '{
    schemaVersion: 1,
    platform: "iOS",
    evidenceType: "exact-testflight-functional-qa",
    testFlightVerification: {
      path: $testFlightPath,
      sha256: $testFlightSHA256,
      testedAt: $testFlightTestedAt
    },
    candidate: {
      appBundleID: $appBundleID,
      version: $version,
      build: $build,
      ipaPath: $ipaPath,
      ipaSHA256: $ipaSHA256,
      appStoreConnectBuildID: $appStoreConnectBuildID
    },
    testDevice: {
      model: $deviceModel,
      operatingSystem: "iOS",
      osVersion: $iosVersion
    },
    testedAt: $testedAt,
    qa: {
      cloudKitProductionSchema: {
        result: "passed",
        environment: "Production",
        schemaDeployed: true,
        testedAt: $testedAt,
        evidence: {path: $cloudKitPath, sha256: $cloudKitSHA256, sizeBytes: $cloudKitSize}
      },
      sameICloudAccountSync: {
        result: "passed",
        sameICloudAccountConfirmed: true,
        macToIPhoneSyncConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $syncPath, sha256: $syncSHA256, sizeBytes: $syncSize}
      },
      liveActivity: {
        result: "passed",
        realDeviceConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $liveActivityPath, sha256: $liveActivitySHA256, sizeBytes: $liveActivitySize}
      },
      reviewPath: {
        result: "passed",
        exampleModeConfirmed: true,
        productionPathConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $reviewPathPath, sha256: $reviewPathSHA256, sizeBytes: $reviewPathSize}
      }
    },
    createdAt: $createdAt
  }' >"$TEMP_EVIDENCE_PATH"

# Seal and validate the temporary inode before link(2) makes it visible at the
# destination. The published name therefore never has a writable window.
/bin/chmod 0444 "$TEMP_EVIDENCE_PATH" \
  || fail "could not seal functional QA evidence before publication"
/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "iOS" and
  .evidenceType == "exact-testflight-functional-qa" and
  all(.qa[]; .result == "passed")
' "$TEMP_EVIDENCE_PATH" >/dev/null \
  || fail "generated functional QA evidence failed its schema contract"
PUBLISHED_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$TEMP_EVIDENCE_PATH")"
/bin/ln -h "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH" \
  || fail "could not publish functional QA evidence without overwriting a file"
if [[ ! -f "$EVIDENCE_PATH" || -L "$EVIDENCE_PATH" \
    || "$(/usr/bin/stat -f '%d:%i' "$EVIDENCE_PATH")" != "$PUBLISHED_IDENTITY" ]]; then
  MISPLACED_EVIDENCE_PATH="$EVIDENCE_PATH/${TEMP_EVIDENCE_PATH:t}"
  if [[ -f "$MISPLACED_EVIDENCE_PATH" && ! -L "$MISPLACED_EVIDENCE_PATH" \
      && "$(/usr/bin/stat -f '%d:%i' "$MISPLACED_EVIDENCE_PATH")" == \
        "$PUBLISHED_IDENTITY" ]]; then
    /bin/rm -f "$MISPLACED_EVIDENCE_PATH" \
      || fail "could not remove misplaced functional QA evidence after a destination-directory race"
  fi
  fail "functional QA evidence destination did not resolve to the sealed temporary inode"
fi
PUBLISHED=true
/bin/rm -f "$TEMP_EVIDENCE_PATH" \
  || fail "could not remove functional QA evidence temporary name after publication"
TEMP_EVIDENCE_PATH=""

"$VALIDATOR" \
  --expected-testflight-verification "$TESTFLIGHT_VERIFICATION_PATH" \
  --expected-ipa-sha256 "$IPA_SHA256" \
  "$EVIDENCE_PATH" >/dev/null \
  || fail "generated functional QA evidence failed independent validation"
PUBLISHED=false

print -r -- "iOS functional QA evidence recorded: $EVIDENCE_PATH"
print -r -- "Candidate: $APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER"
print -r -- "IPA SHA-256: $IPA_SHA256"
print -r -- "This local record does not modify or re-query App Store Connect."
