#!/bin/zsh
set -euo pipefail

MAC_ROOT="${0:A:h:h}"
DELIVERY_RECORD_INPUT=""
PROCESSING_STATE=""
APP_STORE_CONNECT_BUILD_ID=""
PROCESSING_VERIFIED_AT=""
WARNINGS_REVIEWED=false
EVIDENCE_TEMP=""

usage() {
  /bin/cat <<'EOF'
Usage:
  ./confirm-macos-app-store-evidence.sh \
    --processing-state Complete \
    --app-store-connect-build-id BUILD_ID \
    --processing-verified-at YYYY-MM-DDTHH:MM:SSZ \
    --warnings-reviewed \
    MAC_APP_STORE_DELIVERY_RECORD.json

After independently inspecting App Store Connect, this records read-only,
no-overwrite local evidence that Apple finished processing the exact uploaded .pkg
and that all delivery warnings were reviewed. It does not contact Apple, alter
App Store Connect, select a build for a version, or submit anything for review.

Set AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING to the exact
Bundle-ID:Version:Build:PKG-SHA-256:ASC-Build-ID value for this candidate. The
generated mac-app-store-processing-verification-*.json is never overwritten.
EOF
}

fail() {
  print -u2 -r -- "macOS App Store processing evidence failed: $*"
  exit 2
}

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$EVIDENCE_TEMP" && -n "${RELEASE_DIRECTORY:-}" && \
      "$EVIDENCE_TEMP" == "$RELEASE_DIRECTORY"/.mac-app-store-processing-verification.?????? && \
      -f "$EVIDENCE_TEMP" && ! -L "$EVIDENCE_TEMP" ]]; then
    /bin/rm -f "$EVIDENCE_TEMP"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# > 0 )); do
  case "$1" in
    --processing-state)
      (( $# >= 2 )) || fail "--processing-state requires Complete"
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
    --warnings-reviewed)
      [[ "$WARNINGS_REVIEWED" == false ]] \
        || fail "--warnings-reviewed may be supplied only once"
      WARNINGS_REVIEWED=true
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
      [[ -z "$DELIVERY_RECORD_INPUT" ]] \
        || fail "only one delivery record may be supplied"
      DELIVERY_RECORD_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$DELIVERY_RECORD_INPUT" ]] || fail "a Mac App Store delivery record is required"
[[ "$PROCESSING_STATE" == "Complete" ]] \
  || fail "--processing-state must be exactly Complete"
[[ "$WARNINGS_REVIEWED" == true ]] \
  || fail "--warnings-reviewed is required after inspecting every delivery warning"
[[ -n "$APP_STORE_CONNECT_BUILD_ID" && ${#APP_STORE_CONNECT_BUILD_ID} -le 256 ]] \
  || fail "--app-store-connect-build-id must be 1-256 characters"
print -r -- "$APP_STORE_CONNECT_BUILD_ID" | LC_ALL=C /usr/bin/grep -Eq '^[[:graph:]]+$' \
  || fail "--app-store-connect-build-id must not contain whitespace or control characters"
case "${APP_STORE_CONNECT_BUILD_ID:l}" in
  *placeholder*|*example*|*your*|*build-id*|*build_id*|todo|tbd|unknown|null|none|\<*|*\>)
    fail "--app-store-connect-build-id is still a placeholder"
    ;;
esac

valid_utc_timestamp() {
  local value="$1"
  print -r -- "$value" | /usr/bin/grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' >/dev/null 2>&1
}

valid_utc_timestamp "$PROCESSING_VERIFIED_AT" \
  || fail "--processing-verified-at must be a real UTC timestamp ending in Z"
PROCESSING_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$PROCESSING_VERIFIED_AT" '+%s')"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( PROCESSING_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "processingVerifiedAt must not be more than five minutes in the future"

[[ -f "$DELIVERY_RECORD_INPUT" && ! -L "$DELIVERY_RECORD_INPUT" ]] \
  || fail "delivery record must be an existing, non-symlink file"
DELIVERY_RECORD_INPUT_ABSOLUTE="${DELIVERY_RECORD_INPUT:a}"
DELIVERY_RECORD_PATH="${DELIVERY_RECORD_INPUT:A}"
[[ "$DELIVERY_RECORD_INPUT_ABSOLUTE" == "$DELIVERY_RECORD_PATH" ]] \
  || fail "delivery record path must not traverse symlink parents"
DELIVERY_RECORD_MODE="$(/usr/bin/stat -f '%Lp' "$DELIVERY_RECORD_PATH")"
[[ "$DELIVERY_RECORD_MODE" == <-> ]] || fail "delivery record permissions are unreadable"
(( (8#$DELIVERY_RECORD_MODE & 8#222) == 0 )) \
  || fail "delivery record must be read-only before processing evidence is recorded"
RELEASE_DIRECTORY="${DELIVERY_RECORD_PATH:h}"
[[ -d "$RELEASE_DIRECTORY" && ! -L "$RELEASE_DIRECTORY" ]] \
  || fail "delivery record parent must be a non-symlink release directory"
[[ "$RELEASE_DIRECTORY" == "${RELEASE_DIRECTORY:A}" ]] \
  || fail "release directory must already be a canonical candidate root"
[[ "${DELIVERY_RECORD_PATH:t}" == mac-app-store-delivery-*.json ]] \
  || fail "delivery record filename is not a generated Mac App Store delivery record"

for tool in /usr/bin/jq /usr/bin/shasum /usr/bin/stat; do
  [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done
[[ -x "$MAC_ROOT/scripts/submit-macos-app-store.sh" ]] \
  || fail "submit-macos-app-store.sh is missing or not executable"
[[ -x "$MAC_ROOT/scripts/verify-macos-app-store-delivery.sh" ]] \
  || fail "verify-macos-app-store-delivery.sh is missing or not executable"

/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "macOS" and
  .destination == "App Store Connect / Mac App Store" and
  (.submittedAt | type == "string" and length > 0) and
  (.appBundleID | type == "string" and length > 0) and
  (.version | type == "string" and length > 0) and
  (.build | type == "string" and length > 0) and
  (.archiveZipPath | type == "string" and length > 0) and
  (.archiveZipSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.packagePath | type == "string" and length > 0) and
  (.packageSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
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
  .warningsReviewed == false and
  .warningsReviewedAt == null and
  .submittedForAppReview == false
' "$DELIVERY_RECORD_PATH" >/dev/null \
  || fail "delivery record is incomplete, already post-processed, or unsupported"

APP_BUNDLE_ID="$(/usr/bin/jq -r '.appBundleID' "$DELIVERY_RECORD_PATH")"
VERSION="$(/usr/bin/jq -r '.version' "$DELIVERY_RECORD_PATH")"
BUILD_NUMBER="$(/usr/bin/jq -r '.build' "$DELIVERY_RECORD_PATH")"
ARCHIVE_ZIP_PATH="$(/usr/bin/jq -r '.archiveZipPath' "$DELIVERY_RECORD_PATH")"
ARCHIVE_ZIP_SHA256="$(/usr/bin/jq -r '.archiveZipSHA256' "$DELIVERY_RECORD_PATH")"
PACKAGE_PATH="$(/usr/bin/jq -r '.packagePath' "$DELIVERY_RECORD_PATH")"
PACKAGE_SHA256="$(/usr/bin/jq -r '.packageSHA256' "$DELIVERY_RECORD_PATH")"
RELEASE_METADATA_PATH="$(/usr/bin/jq -r '.releaseMetadataPath' "$DELIVERY_RECORD_PATH")"
RELEASE_METADATA_SHA256="$(/usr/bin/jq -r '.releaseMetadataSHA256' "$DELIVERY_RECORD_PATH")"
VALIDATION_RESULT_PATH="$(/usr/bin/jq -r '.validationResultPath' "$DELIVERY_RECORD_PATH")"
VALIDATION_RESULT_SHA256="$(/usr/bin/jq -r '.validationResultSHA256' "$DELIVERY_RECORD_PATH")"
UPLOAD_RESULT_PATH="$(/usr/bin/jq -r '.uploadResultPath' "$DELIVERY_RECORD_PATH")"
UPLOAD_RESULT_SHA256="$(/usr/bin/jq -r '.uploadResultSHA256' "$DELIVERY_RECORD_PATH")"

require_release_file() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and must not traverse symlink parents"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

ARCHIVE_ZIP_PATH="$(require_release_file "$ARCHIVE_ZIP_PATH" "Archive ZIP")"
PACKAGE_PATH="$(require_release_file "$PACKAGE_PATH" "App Store package")"
RELEASE_METADATA_PATH="$(require_release_file \
  "$RELEASE_METADATA_PATH" "release metadata")"
VALIDATION_RESULT_PATH="$(require_release_file \
  "$VALIDATION_RESULT_PATH" "validation result")"
UPLOAD_RESULT_PATH="$(require_release_file "$UPLOAD_RESULT_PATH" "upload result")"
[[ "$RELEASE_METADATA_PATH" == "$RELEASE_DIRECTORY/release-metadata.json" ]] \
  || fail "delivery record does not reference this release directory's metadata"

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

[[ "$(file_sha256 "$ARCHIVE_ZIP_PATH")" == "$ARCHIVE_ZIP_SHA256" ]] \
  || fail "current Archive ZIP differs from the delivery record"
[[ "$(file_sha256 "$PACKAGE_PATH")" == "$PACKAGE_SHA256" ]] \
  || fail "current App Store package differs from the delivery record"
[[ "$(file_sha256 "$RELEASE_METADATA_PATH")" == "$RELEASE_METADATA_SHA256" ]] \
  || fail "current release metadata differs from the delivery record"
[[ "$(file_sha256 "$VALIDATION_RESULT_PATH")" == "$VALIDATION_RESULT_SHA256" ]] \
  || fail "current validation result differs from the delivery record"
[[ "$(file_sha256 "$UPLOAD_RESULT_PATH")" == "$UPLOAD_RESULT_SHA256" ]] \
  || fail "current upload result differs from the delivery record"
/usr/bin/jq -e . "$VALIDATION_RESULT_PATH" >/dev/null \
  || fail "validation result is no longer valid JSON"
/usr/bin/jq -e . "$UPLOAD_RESULT_PATH" >/dev/null \
  || fail "upload result is no longer valid JSON"

/usr/bin/jq -e \
  --arg bundle "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archiveZip "$ARCHIVE_ZIP_PATH" \
  --arg archiveSHA "$ARCHIVE_ZIP_SHA256" \
  --arg package "$PACKAGE_PATH" \
  --arg packageSHA "$PACKAGE_SHA256" '
    .schemaVersion == 1 and .platform == "macOS" and
    .distribution == "mac-app-store" and .appBundleID == $bundle and
    .version == $version and .build == $build and
    .archiveZip == $archiveZip and .archiveZipSHA256 == $archiveSHA and
    .exportedPackage == $package and .packageSHA256 == $packageSHA and
    .applicationCategory == "public.app-category.developer-tools" and
    .uploaded == false
  ' "$RELEASE_METADATA_PATH" >/dev/null \
  || fail "release metadata and delivery record do not identify the same package"

DELIVERY_VERIFICATION_JSON="$(
  "$MAC_ROOT/scripts/verify-macos-app-store-delivery.sh" \
    --json "$DELIVERY_RECORD_PATH"
)" || fail "delivery record no longer passes independent verification"
/usr/bin/jq -e \
  --arg delivery "$DELIVERY_RECORD_PATH" \
  --arg deliverySHA "$(file_sha256 "$DELIVERY_RECORD_PATH")" \
  --arg metadata "$RELEASE_METADATA_PATH" --arg metadataSHA "$RELEASE_METADATA_SHA256" \
  --arg archive "$ARCHIVE_ZIP_PATH" --arg archiveSHA "$ARCHIVE_ZIP_SHA256" \
  --arg package "$PACKAGE_PATH" --arg packageSHA "$PACKAGE_SHA256" \
  --arg validation "$VALIDATION_RESULT_PATH" --arg validationSHA "$VALIDATION_RESULT_SHA256" \
  --arg upload "$UPLOAD_RESULT_PATH" --arg uploadSHA "$UPLOAD_RESULT_SHA256" \
  --arg bundle "$APP_BUNDLE_ID" --arg version "$VERSION" --arg build "$BUILD_NUMBER" '
    .schemaVersion == 1 and .platform == "macOS" and
    .evidenceVerified == true and .uploadAccepted == true and
    .evidencePath == $delivery and .evidenceSHA256 == $deliverySHA and
    .deliveryRecordPath == $delivery and .deliveryRecordSHA256 == $deliverySHA and
    .releaseMetadataPath == $metadata and .releaseMetadataSHA256 == $metadataSHA and
    .archiveZipPath == $archive and .archiveZipSHA256 == $archiveSHA and
    .packagePath == $package and .packageSHA256 == $packageSHA and
    .validationResultPath == $validation and .validationResultSHA256 == $validationSHA and
    .uploadResultPath == $upload and .uploadResultSHA256 == $uploadSHA and
    .appBundleID == $bundle and .version == $version and .build == $build and
    .processingState == null and .processingVerified == false and
    .submittedForAppReview == false
  ' <<<"$DELIVERY_VERIFICATION_JSON" >/dev/null \
  || fail "independent delivery verification does not bind the same exact candidate"

SUBMITTED_AT="$(/usr/bin/jq -r '.submittedAt' "$DELIVERY_RECORD_PATH")"
valid_utc_timestamp "$SUBMITTED_AT" \
  || fail "delivery record submittedAt is not a valid UTC timestamp"
SUBMITTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$SUBMITTED_AT" '+%s')"
(( SUBMITTED_EPOCH <= PROCESSING_EPOCH )) \
  || fail "processingVerifiedAt must not be earlier than the recorded upload"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$PACKAGE_SHA256:$APP_STORE_CONNECT_BUILD_ID"
[[ "${AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING:-}" == "$CONFIRMATION_VALUE" ]] \
  || fail "AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING does not match this exact processed build"

DELIVERY_RECORD_SHA256="$(file_sha256 "$DELIVERY_RECORD_PATH")"
CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_PATH="$RELEASE_DIRECTORY/mac-app-store-processing-verification-$STAMP.json"
[[ ! -e "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" ]] \
  || fail "refusing to overwrite an existing processing evidence file"
EVIDENCE_TEMP="$(mktemp \
  "$RELEASE_DIRECTORY/.mac-app-store-processing-verification.XXXXXX")"

/usr/bin/jq -n \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archiveZipPath "$ARCHIVE_ZIP_PATH" \
  --arg archiveZipSHA256 "$ARCHIVE_ZIP_SHA256" \
  --arg packagePath "$PACKAGE_PATH" \
  --arg packageSHA256 "$PACKAGE_SHA256" \
  --arg releaseMetadataPath "$RELEASE_METADATA_PATH" \
  --arg releaseMetadataSHA256 "$RELEASE_METADATA_SHA256" \
  --arg deliveryRecordPath "$DELIVERY_RECORD_PATH" \
  --arg deliveryRecordSHA256 "$DELIVERY_RECORD_SHA256" \
  --arg validationResultPath "$VALIDATION_RESULT_PATH" \
  --arg validationResultSHA256 "$VALIDATION_RESULT_SHA256" \
  --arg uploadResultPath "$UPLOAD_RESULT_PATH" \
  --arg uploadResultSHA256 "$UPLOAD_RESULT_SHA256" \
  --arg appStoreConnectBuildID "$APP_STORE_CONNECT_BUILD_ID" \
  --arg processingState "$PROCESSING_STATE" \
  --arg processingVerifiedAt "$PROCESSING_VERIFIED_AT" \
  --arg createdAt "$CREATED_AT" '{
    schemaVersion: 1,
    platform: "macOS",
    destination: "App Store Connect / Mac App Store",
    appBundleID: $appBundleID,
    version: $version,
    build: $build,
    archiveZipPath: $archiveZipPath,
    archiveZipSHA256: $archiveZipSHA256,
    packagePath: $packagePath,
    packageSHA256: $packageSHA256,
    releaseMetadataPath: $releaseMetadataPath,
    releaseMetadataSHA256: $releaseMetadataSHA256,
    deliveryRecordPath: $deliveryRecordPath,
    deliveryRecordSHA256: $deliveryRecordSHA256,
    validationResultPath: $validationResultPath,
    validationResultSHA256: $validationResultSHA256,
    uploadResultPath: $uploadResultPath,
    uploadResultSHA256: $uploadResultSHA256,
    uploadAccepted: true,
    appStoreConnectBuildID: $appStoreConnectBuildID,
    processingState: $processingState,
    processingVerified: true,
    processingVerifiedAt: $processingVerifiedAt,
    warningsReviewed: true,
    warningsReviewedAt: $processingVerifiedAt,
    submittedForAppReview: false,
    createdAt: $createdAt
  }' >"$EVIDENCE_TEMP"
/usr/bin/jq -e '
  .schemaVersion == 1 and .platform == "macOS" and
  .destination == "App Store Connect / Mac App Store" and
  .uploadAccepted == true and
  (.appStoreConnectBuildID | type == "string" and length > 0) and
  .processingState == "Complete" and .processingVerified == true and
  (.processingVerifiedAt | type == "string" and length > 0) and
  .warningsReviewed == true and
  (.warningsReviewedAt | type == "string" and length > 0) and
  .submittedForAppReview == false and
  (.createdAt | type == "string" and length > 0)
' "$EVIDENCE_TEMP" >/dev/null \
  || fail "generated processing evidence failed its schema contract"

/bin/ln "$EVIDENCE_TEMP" "$EVIDENCE_PATH" \
  || fail "could not publish processing evidence without overwriting a file"
/bin/chmod 0444 "$EVIDENCE_PATH" || {
  /bin/rm -f "$EVIDENCE_PATH"
  fail "could not make processing evidence read-only"
}
/bin/rm -f "$EVIDENCE_TEMP"
EVIDENCE_TEMP=""

print -r -- "Mac App Store processing evidence recorded: $EVIDENCE_PATH"
print -r -- "This local evidence does not re-query Apple or submit the build for App Review."
