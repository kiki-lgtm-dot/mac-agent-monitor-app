#!/bin/zsh
set -euo pipefail

MAC_ROOT="${0:A:h:h}"
VALIDATOR="$MAC_ROOT/scripts/validate-functional-qa-evidence.sh"
METADATA_INPUT=""
MAC_MODEL=""
MACOS_VERSION=""
TESTED_AT=""
OUTPUT_INPUT=""
SANDBOX_RESULT=""
SANDBOX_EVIDENCE_INPUT=""
ARCHIVE_RESULT=""
ARCHIVE_EVIDENCE_INPUT=""
PROFILE_RESULT=""
PROFILE_EVIDENCE_INPUT=""
PRIVACY_RESULT=""
PRIVACY_EVIDENCE_INPUT=""
REVIEW_RESULT=""
REVIEW_EVIDENCE_INPUT=""

usage() {
  /bin/cat <<'EOF'
Usage:
  AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA=\
'<bundle:version:build:Archive-ZIP-SHA256:PKG-SHA256>' \
    ./confirm-functional-qa-evidence.sh \
      --mac-model 'MacBook Pro 14-inch (2024)' \
      --macos-version '15.6.1' \
      --tested-at 'YYYY-MM-DDTHH:MM:SSZ' \
      --sandbox-flow-result passed \
      --sandbox-flow-evidence /absolute/path/to/sandbox-report \
      --archive-install-launch-quit-result passed \
      --archive-install-launch-quit-evidence /absolute/path/to/install-report \
      --profile-certificate-result passed \
      --profile-certificate-evidence /absolute/path/to/profile-report \
      --privacy-report-result passed \
      --privacy-report-evidence /absolute/path/to/privacy-report \
      --review-path-result passed \
      --review-path-evidence /absolute/path/to/review-path-report \
      [--output /absolute/path/to/macos-functional-verification-NAME.json] \
      RELEASE_DIRECTORY/release-metadata.json

Creates one read-only, no-overwrite functional-QA record for an exact exported
Mac App Store candidate. All five results must be the literal "passed" and
each requires a distinct non-empty report attachment inside the release
directory. Attachment paths, sizes, and SHA-256 values are recorded.

This command performs local checks only. It never uploads, queries Apple,
selects a build, or claims App Store Connect processing/review status.
EOF
}

fail() {
  print -u2 -r -- "macOS functional QA evidence confirmation failed: $*"
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
    --mac-model)
      (( $# >= 2 )) || fail "--mac-model requires a value"
      [[ -z "$MAC_MODEL" ]] || fail "--mac-model may be supplied only once"
      MAC_MODEL="$2"
      shift 2
      ;;
    --macos-version)
      (( $# >= 2 )) || fail "--macos-version requires a value"
      [[ -z "$MACOS_VERSION" ]] || fail "--macos-version may be supplied only once"
      MACOS_VERSION="$2"
      shift 2
      ;;
    --tested-at)
      (( $# >= 2 )) || fail "--tested-at requires a UTC timestamp"
      [[ -z "$TESTED_AT" ]] || fail "--tested-at may be supplied only once"
      TESTED_AT="$2"
      shift 2
      ;;
    --sandbox-flow-result)
      (( $# >= 2 )) || fail "--sandbox-flow-result requires passed"
      [[ -z "$SANDBOX_RESULT" ]] || fail "--sandbox-flow-result may be supplied only once"
      SANDBOX_RESULT="$2"
      shift 2
      ;;
    --sandbox-flow-evidence)
      (( $# >= 2 )) || fail "--sandbox-flow-evidence requires an absolute file path"
      [[ -z "$SANDBOX_EVIDENCE_INPUT" ]] \
        || fail "--sandbox-flow-evidence may be supplied only once"
      SANDBOX_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --archive-install-launch-quit-result)
      (( $# >= 2 )) || fail "--archive-install-launch-quit-result requires passed"
      [[ -z "$ARCHIVE_RESULT" ]] \
        || fail "--archive-install-launch-quit-result may be supplied only once"
      ARCHIVE_RESULT="$2"
      shift 2
      ;;
    --archive-install-launch-quit-evidence)
      (( $# >= 2 )) \
        || fail "--archive-install-launch-quit-evidence requires an absolute file path"
      [[ -z "$ARCHIVE_EVIDENCE_INPUT" ]] \
        || fail "--archive-install-launch-quit-evidence may be supplied only once"
      ARCHIVE_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --profile-certificate-result)
      (( $# >= 2 )) || fail "--profile-certificate-result requires passed"
      [[ -z "$PROFILE_RESULT" ]] \
        || fail "--profile-certificate-result may be supplied only once"
      PROFILE_RESULT="$2"
      shift 2
      ;;
    --profile-certificate-evidence)
      (( $# >= 2 )) || fail "--profile-certificate-evidence requires an absolute file path"
      [[ -z "$PROFILE_EVIDENCE_INPUT" ]] \
        || fail "--profile-certificate-evidence may be supplied only once"
      PROFILE_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --privacy-report-result)
      (( $# >= 2 )) || fail "--privacy-report-result requires passed"
      [[ -z "$PRIVACY_RESULT" ]] \
        || fail "--privacy-report-result may be supplied only once"
      PRIVACY_RESULT="$2"
      shift 2
      ;;
    --privacy-report-evidence)
      (( $# >= 2 )) || fail "--privacy-report-evidence requires an absolute file path"
      [[ -z "$PRIVACY_EVIDENCE_INPUT" ]] \
        || fail "--privacy-report-evidence may be supplied only once"
      PRIVACY_EVIDENCE_INPUT="$2"
      shift 2
      ;;
    --review-path-result)
      (( $# >= 2 )) || fail "--review-path-result requires passed"
      [[ -z "$REVIEW_RESULT" ]] \
        || fail "--review-path-result may be supplied only once"
      REVIEW_RESULT="$2"
      shift 2
      ;;
    --review-path-evidence)
      (( $# >= 2 )) || fail "--review-path-evidence requires an absolute file path"
      [[ -z "$REVIEW_EVIDENCE_INPUT" ]] \
        || fail "--review-path-evidence may be supplied only once"
      REVIEW_EVIDENCE_INPUT="$2"
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
      [[ -z "$METADATA_INPUT" ]] || fail "only one release metadata file may be supplied"
      METADATA_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$METADATA_INPUT" ]] || fail "release-metadata.json is required"
[[ -x "$VALIDATOR" ]] || fail "validate-functional-qa-evidence.sh is missing or not executable"
for tool in /usr/bin/jq /usr/bin/shasum /usr/bin/stat; do
  [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done

for result_name in SANDBOX_RESULT ARCHIVE_RESULT PROFILE_RESULT PRIVACY_RESULT REVIEW_RESULT; do
  result_value="${(P)result_name}"
  [[ "$result_value" == "passed" ]] \
    || fail "all five functional QA results must be exactly passed; false, failed, and placeholders are rejected"
done
[[ -n "$SANDBOX_EVIDENCE_INPUT" && -n "$ARCHIVE_EVIDENCE_INPUT" \
    && -n "$PROFILE_EVIDENCE_INPUT" && -n "$PRIVACY_EVIDENCE_INPUT" \
    && -n "$REVIEW_EVIDENCE_INPUT" ]] \
  || fail "all five functional QA evidence attachments are required"
placeholder_text "$MAC_MODEL" && fail "--mac-model is missing or a placeholder"
placeholder_text "$MACOS_VERSION" && fail "--macos-version is missing or a placeholder"
[[ ${#MAC_MODEL} -le 128 && ${#MACOS_VERSION} -le 64 ]] \
  || fail "Mac model or macOS version is unreasonably long"
[[ "$MACOS_VERSION" != *$'\n'* && "$MACOS_VERSION" != *$'\r'* ]] \
  || fail "--macos-version must contain 2 or 3 numeric components"
print -r -- "$MACOS_VERSION" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' \
  || fail "--macos-version must contain 2 or 3 numeric components"
valid_utc_timestamp "$TESTED_AT" \
  || fail "--tested-at must be a real UTC timestamp ending in Z"

CANDIDATE_JSON="$("$VALIDATOR" --inspect-release-metadata "$METADATA_INPUT")" \
  || fail "the supplied Mac App Store release metadata is not a valid exact candidate"
APP_BUNDLE_ID="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.appBundleID')"
VERSION="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.version')"
BUILD_NUMBER="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.build')"
ARCHIVE_PATH="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.archivePath')"
ARCHIVE_ZIP_PATH="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.archiveZipPath')"
ARCHIVE_ZIP_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.archiveZipSHA256')"
PACKAGE_PATH="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.packagePath')"
PACKAGE_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.packageSHA256')"
RELEASE_DIRECTORY="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.releaseDirectory')"
METADATA_PATH="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.metadataPath')"
METADATA_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.metadataSHA256')"
CANDIDATE_CREATED_AT="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.candidateCreatedAt')"

TESTED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$TESTED_AT" '+%s')"
CANDIDATE_CREATED_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$CANDIDATE_CREATED_AT" '+%s')"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( CANDIDATE_CREATED_EPOCH <= TESTED_EPOCH )) \
  || fail "--tested-at must not precede creation of the exact Mac App Store candidate"
(( TESTED_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "--tested-at must not be more than five minutes in the future"

CONFIRMATION_VALUE="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$ARCHIVE_ZIP_SHA256:$PACKAGE_SHA256"
[[ "${AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA:-}" == "$CONFIRMATION_VALUE" ]] \
  || fail "AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA does not match this exact Archive ZIP and package"

require_attachment() {
  local raw_path="$1"
  local label="$2"
  [[ "$raw_path" == /* && -f "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink file"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and contain no symlink traversal"
  [[ "$canonical_path" == "$RELEASE_DIRECTORY"/* ]] \
    || fail "$label must be stored inside the exact candidate release directory"
  for release_artifact in "$METADATA_PATH" "$ARCHIVE_ZIP_PATH" "$PACKAGE_PATH"; do
    [[ "$canonical_path" != "$release_artifact" ]] \
      || fail "$label cannot reuse a core release artifact"
  done
  [[ "$canonical_path" != "$ARCHIVE_PATH"/* ]] \
    || fail "$label cannot be stored inside the Archive"
  case "${canonical_path:t}" in
    *.sha256|mac-app-store-*.json|macos-functional-verification-*.json)
      fail "$label cannot reuse a core release artifact"
      ;;
  esac
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

SANDBOX_EVIDENCE_PATH="$(require_attachment "$SANDBOX_EVIDENCE_INPUT" \
  "sandbox authorization/denial/revocation/recovery evidence")"
ARCHIVE_EVIDENCE_PATH="$(require_attachment "$ARCHIVE_EVIDENCE_INPUT" \
  "Archive/install/launch/quit evidence")"
PROFILE_EVIDENCE_PATH="$(require_attachment "$PROFILE_EVIDENCE_INPUT" \
  "profile and certificate evidence")"
PRIVACY_EVIDENCE_PATH="$(require_attachment "$PRIVACY_EVIDENCE_INPUT" \
  "Xcode Privacy Report evidence")"
REVIEW_EVIDENCE_PATH="$(require_attachment "$REVIEW_EVIDENCE_INPUT" \
  "review example/production path evidence")"
typeset -a ATTACHMENT_PATHS ATTACHMENT_IDENTITIES ATTACHMENT_HASHES
ATTACHMENT_PATHS=("$SANDBOX_EVIDENCE_PATH" "$ARCHIVE_EVIDENCE_PATH" \
  "$PROFILE_EVIDENCE_PATH" "$PRIVACY_EVIDENCE_PATH" "$REVIEW_EVIDENCE_PATH")
for attachment_path in "${ATTACHMENT_PATHS[@]}"; do
  ATTACHMENT_IDENTITIES+=("$(/usr/bin/stat -f '%d:%i' "$attachment_path")")
  attachment_sha256="$(file_sha256 "$attachment_path")"
  ATTACHMENT_HASHES+=("$attachment_sha256")
  for core_sha256 in "$METADATA_SHA256" "$ARCHIVE_ZIP_SHA256" "$PACKAGE_SHA256"; do
    [[ "$attachment_sha256" != "$core_sha256" ]] \
      || fail "QA attachment content cannot match a core release artifact"
  done
done
[[ "$(print -rl -- "${ATTACHMENT_PATHS[@]}" | /usr/bin/sort -u \
      | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "5" ]] \
  || fail "the five QA checks must use five distinct evidence attachments"
[[ "$(print -rl -- "${ATTACHMENT_IDENTITIES[@]}" | /usr/bin/sort -u \
      | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "5" ]] \
  || fail "the five QA checks cannot reuse one file through hard links"
[[ "$(print -rl -- "${ATTACHMENT_HASHES[@]}" | /usr/bin/sort -u \
      | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "5" ]] \
  || fail "the five QA checks must have five different content SHA-256 values"

if [[ -n "$OUTPUT_INPUT" ]]; then
  OUTPUT_PARENT="${OUTPUT_INPUT:h:A}"
  [[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
    || fail "--output parent must be an existing, non-symlink directory"
  EVIDENCE_PATH="$OUTPUT_PARENT/${OUTPUT_INPUT:t}"
else
  STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  EVIDENCE_PATH="$RELEASE_DIRECTORY/macos-functional-verification-$STAMP.json"
fi
[[ "${EVIDENCE_PATH:h}" == "$RELEASE_DIRECTORY" ]] \
  || fail "functional QA evidence must be created in the exact candidate release directory"
[[ "${EVIDENCE_PATH:t}" == macos-functional-verification-*.json ]] \
  || fail "functional QA evidence filename must match macos-functional-verification-*.json"
[[ ! -e "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" ]] \
  || fail "refusing to overwrite an existing macOS functional QA evidence file"

CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
TEMP_EVIDENCE_PATH="$(mktemp "$RELEASE_DIRECTORY/.macos-functional-verification.XXXXXX")"
PUBLISHED=false
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  [[ -n "${TEMP_EVIDENCE_PATH:-}" && -f "$TEMP_EVIDENCE_PATH" ]] \
    && /bin/rm -f "$TEMP_EVIDENCE_PATH"
  if [[ "$exit_code" -ne 0 && "$PUBLISHED" == true && -f "$EVIDENCE_PATH" ]]; then
    /bin/rm -f "$EVIDENCE_PATH"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/jq -n \
  --arg metadataPath "$METADATA_PATH" \
  --arg metadataSHA256 "$METADATA_SHA256" \
  --arg candidateCreatedAt "$CANDIDATE_CREATED_AT" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archiveZipPath "$ARCHIVE_ZIP_PATH" \
  --arg archiveZipSHA256 "$ARCHIVE_ZIP_SHA256" \
  --arg packagePath "$PACKAGE_PATH" \
  --arg packageSHA256 "$PACKAGE_SHA256" \
  --arg macModel "$MAC_MODEL" \
  --arg macosVersion "$MACOS_VERSION" \
  --arg testedAt "$TESTED_AT" \
  --arg createdAt "$CREATED_AT" \
  --arg sandboxPath "$SANDBOX_EVIDENCE_PATH" \
  --arg sandboxSHA256 "$(file_sha256 "$SANDBOX_EVIDENCE_PATH")" \
  --argjson sandboxSize "$(/usr/bin/stat -f '%z' "$SANDBOX_EVIDENCE_PATH")" \
  --arg archivePath "$ARCHIVE_EVIDENCE_PATH" \
  --arg archiveSHA256 "$(file_sha256 "$ARCHIVE_EVIDENCE_PATH")" \
  --argjson archiveSize "$(/usr/bin/stat -f '%z' "$ARCHIVE_EVIDENCE_PATH")" \
  --arg profilePath "$PROFILE_EVIDENCE_PATH" \
  --arg profileSHA256 "$(file_sha256 "$PROFILE_EVIDENCE_PATH")" \
  --argjson profileSize "$(/usr/bin/stat -f '%z' "$PROFILE_EVIDENCE_PATH")" \
  --arg privacyPath "$PRIVACY_EVIDENCE_PATH" \
  --arg privacySHA256 "$(file_sha256 "$PRIVACY_EVIDENCE_PATH")" \
  --argjson privacySize "$(/usr/bin/stat -f '%z' "$PRIVACY_EVIDENCE_PATH")" \
  --arg reviewPath "$REVIEW_EVIDENCE_PATH" \
  --arg reviewSHA256 "$(file_sha256 "$REVIEW_EVIDENCE_PATH")" \
  --argjson reviewSize "$(/usr/bin/stat -f '%z' "$REVIEW_EVIDENCE_PATH")" '{
    schemaVersion: 1,
    platform: "macOS",
    evidenceType: "exact-mac-app-store-functional-qa",
    releaseMetadata: {
      path: $metadataPath,
      sha256: $metadataSHA256,
      candidateCreatedAt: $candidateCreatedAt
    },
    candidate: {
      appBundleID: $appBundleID,
      version: $version,
      build: $build,
      archiveZipPath: $archiveZipPath,
      archiveZipSHA256: $archiveZipSHA256,
      packagePath: $packagePath,
      packageSHA256: $packageSHA256
    },
    testMachine: {
      model: $macModel,
      operatingSystem: "macOS",
      osVersion: $macosVersion
    },
    testedAt: $testedAt,
    qa: {
      sandboxAuthorizationFlow: {
        result: "passed",
        authorizationConfirmed: true,
        denialConfirmed: true,
        revocationConfirmed: true,
        recoveryConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $sandboxPath, sha256: $sandboxSHA256, sizeBytes: $sandboxSize}
      },
      archiveInstallLaunchQuit: {
        result: "passed",
        archiveInspected: true,
        packageInstalled: true,
        launchConfirmed: true,
        quitConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $archivePath, sha256: $archiveSHA256, sizeBytes: $archiveSize}
      },
      profileCertificate: {
        result: "passed",
        profileChecked: true,
        certificateMatchConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $profilePath, sha256: $profileSHA256, sizeBytes: $profileSize}
      },
      xcodePrivacyReport: {
        result: "passed",
        reportReviewed: true,
        testedAt: $testedAt,
        evidence: {path: $privacyPath, sha256: $privacySHA256, sizeBytes: $privacySize}
      },
      reviewPath: {
        result: "passed",
        exampleModeConfirmed: true,
        productionPathConfirmed: true,
        testedAt: $testedAt,
        evidence: {path: $reviewPath, sha256: $reviewSHA256, sizeBytes: $reviewSize}
      }
    },
    createdAt: $createdAt
  }' >"$TEMP_EVIDENCE_PATH"

# Publish atomically without overwrite, then remove write permissions before
# independent validation. The attachment hashes keep each claim candidate-
# specific without treating free-standing environment booleans as evidence.
/bin/ln "$TEMP_EVIDENCE_PATH" "$EVIDENCE_PATH" \
  || fail "could not publish functional QA evidence without overwriting a file"
PUBLISHED=true
/bin/chmod 0444 "$EVIDENCE_PATH" \
  || fail "could not make functional QA evidence read-only"
/bin/rm -f "$TEMP_EVIDENCE_PATH"
TEMP_EVIDENCE_PATH=""

"$VALIDATOR" \
  --expected-release-metadata "$METADATA_PATH" \
  --expected-archive-sha256 "$ARCHIVE_ZIP_SHA256" \
  --expected-package-sha256 "$PACKAGE_SHA256" \
  "$EVIDENCE_PATH" >/dev/null \
  || fail "generated functional QA evidence failed independent validation"
PUBLISHED=false

print -r -- "macOS functional QA evidence recorded: $EVIDENCE_PATH"
print -r -- "Candidate: $APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER"
print -r -- "Archive ZIP SHA-256: $ARCHIVE_ZIP_SHA256"
print -r -- "PKG SHA-256: $PACKAGE_SHA256"
print -r -- "This local record does not upload, query, or change Apple state."
