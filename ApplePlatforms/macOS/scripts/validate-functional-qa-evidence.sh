#!/bin/zsh
set -euo pipefail

MAC_ROOT="${0:A:h:h}"
MODE="validate"
OUTPUT_JSON=false
EXPECTED_RELEASE_METADATA=""
EXPECTED_ARCHIVE_SHA256=""
EXPECTED_PACKAGE_SHA256=""
INPUT_PATH=""

usage() {
  /bin/cat <<'EOF'
Usage:
  ./validate-functional-qa-evidence.sh [--json] \
    [--expected-release-metadata FILE] \
    [--expected-archive-sha256 SHA256] \
    [--expected-package-sha256 SHA256] \
    MACOS_FUNCTIONAL_QA_EVIDENCE.json

  ./validate-functional-qa-evidence.sh \
    --inspect-release-metadata RELEASE_DIRECTORY/release-metadata.json

Validates a read-only, no-overwrite macOS App Store functional-QA record and
every local
artifact it binds. Five passed checks and their five distinct attachments must
match the exact release metadata, Archive ZIP, and App Store package. The exact
candidate is rechecked through submit-macos-app-store.sh --check.

This command is credential-free and local. It does not upload, query Apple,
select a build, or claim App Store Connect processing/review state.
EOF
}

fail() {
  print -u2 -r -- "macOS functional QA evidence validation failed: $*"
  exit 2
}

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

valid_sha256() {
  print -r -- "$1" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'
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

require_read_only() {
  local path="$1"
  local label="$2"
  local mode
  mode="$(/usr/bin/stat -f '%Lp' "$path")"
  [[ "$mode" == <-> ]] || fail "$label permissions are unreadable"
  (( (8#$mode & 8#222) == 0 )) || fail "$label must be read-only (no write permission bits)"
}

require_release_file() {
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

require_release_directory() {
  local raw_path="$1"
  local release_directory="$2"
  local label="$3"
  [[ "$raw_path" == /* && -d "$raw_path" && ! -L "$raw_path" ]] \
    || fail "$label must be an existing, absolute, non-symlink directory"
  local canonical_path="${raw_path:A}"
  [[ "$raw_path" == "$canonical_path" ]] \
    || fail "$label path must already be canonical and contain no symlink traversal"
  [[ "$canonical_path" == "$release_directory"/* ]] \
    || fail "$label escapes the release directory"
  print -r -- "$canonical_path"
}

inspect_release_metadata() {
  local input="$1"
  [[ -f "$input" && ! -L "$input" ]] \
    || fail "release metadata must be an existing, non-symlink file"
  local metadata_path="${input:A}"
  local release_directory="${metadata_path:h}"
  [[ "${metadata_path:t}" == "release-metadata.json" ]] \
    || fail "candidate metadata filename must be release-metadata.json"
  [[ -d "$release_directory" && ! -L "$release_directory" ]] \
    || fail "release metadata parent must be a non-symlink release directory"

  /usr/bin/jq -e '
    type == "object" and
    .schemaVersion == 1 and
    .platform == "macOS" and
    .distribution == "mac-app-store" and
    (.version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$")) and
    (.build | type == "string" and test("^[1-9][0-9]*$")) and
    (.archivePath | type == "string" and length > 0) and
    (.archiveZip | type == "string" and length > 0) and
    (.archiveZipSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.exportedPackage | type == "string" and endswith(".pkg")) and
    (.packageSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    .exportMethod == "app-store-connect" and
    .exportDestination == "export" and
    (.appBundleID | type == "string" and test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")) and
    .applicationCategory == "public.app-category.developer-tools" and
    (.signingCertificateSHA1 | type == "string" and test("^[0-9A-F]{40}$")) and
    .provisioningProfile.certificateMatches == true and
    (.installerSigningIdentity | type == "string" and length > 0) and
    .uploaded == false and
    (.createdAt | type == "string" and length > 0)
  ' "$metadata_path" >/dev/null \
    || fail "release metadata is incomplete, unexported, or unsupported"

  local app_bundle_id version build_number archive_path archive_zip_path
  local archive_zip_sha256 package_path package_sha256 candidate_created_at
  app_bundle_id="$(/usr/bin/jq -r '.appBundleID' "$metadata_path")"
  version="$(/usr/bin/jq -r '.version' "$metadata_path")"
  build_number="$(/usr/bin/jq -r '.build' "$metadata_path")"
  archive_path="$(/usr/bin/jq -r '.archivePath' "$metadata_path")"
  archive_zip_path="$(/usr/bin/jq -r '.archiveZip' "$metadata_path")"
  archive_zip_sha256="$(/usr/bin/jq -r '.archiveZipSHA256' "$metadata_path")"
  package_path="$(/usr/bin/jq -r '.exportedPackage' "$metadata_path")"
  package_sha256="$(/usr/bin/jq -r '.packageSHA256' "$metadata_path")"
  candidate_created_at="$(/usr/bin/jq -r '.createdAt' "$metadata_path")"

  placeholder_text "$app_bundle_id" && fail "release metadata app bundle ID is a placeholder"
  placeholder_text "$version" && fail "release metadata version is a placeholder"
  placeholder_text "$build_number" && fail "release metadata build is a placeholder"
  [[ ${#app_bundle_id} -le 255 && ${#version} -le 64 && ${#build_number} -le 64 ]] \
    || fail "candidate identity is unreasonably long"
  print -r -- "$app_bundle_id$version$build_number" \
    | LC_ALL=C /usr/bin/grep -Eq '^[[:graph:]]+$' \
    || fail "candidate identity contains whitespace or control characters"

  archive_path="$(require_release_directory \
    "$archive_path" "$release_directory" "Archive")"
  archive_zip_path="$(require_release_file \
    "$archive_zip_path" "$release_directory" "Archive ZIP")"
  package_path="$(require_release_file \
    "$package_path" "$release_directory" "App Store package")"
  [[ "${archive_path:t}" == "AgentIslandMac.xcarchive" ]] \
    || fail "Archive has an unexpected name"
  [[ "${archive_zip_path:t}" == "AgentIslandMac.xcarchive.zip" ]] \
    || fail "Archive ZIP has an unexpected name"
  [[ "${package_path:e:l}" == "pkg" ]] \
    || fail "App Store package must be a .pkg"
  [[ "$(file_sha256 "$archive_zip_path")" == "$archive_zip_sha256" ]] \
    || fail "Archive ZIP SHA-256 differs from release metadata"
  [[ "$(file_sha256 "$package_path")" == "$package_sha256" ]] \
    || fail "App Store package SHA-256 differs from release metadata"

  valid_utc_timestamp "$candidate_created_at" \
    || fail "release metadata createdAt is not a valid UTC timestamp"
  (( $(timestamp_epoch "$candidate_created_at") <= $(/bin/date -u '+%s') + 300 )) \
    || fail "release metadata createdAt is in the future"

  [[ -x "$MAC_ROOT/scripts/submit-macos-app-store.sh" ]] \
    || fail "submit-macos-app-store.sh is missing or not executable"
  "$MAC_ROOT/scripts/submit-macos-app-store.sh" --check "$release_directory" >/dev/null \
    || fail "the exact Mac App Store candidate no longer passes local submission preflight"

  /usr/bin/jq -n \
    --arg appBundleID "$app_bundle_id" \
    --arg version "$version" \
    --arg build "$build_number" \
    --arg archivePath "$archive_path" \
    --arg archiveZipPath "$archive_zip_path" \
    --arg archiveZipSHA256 "$archive_zip_sha256" \
    --arg packagePath "$package_path" \
    --arg packageSHA256 "$package_sha256" \
    --arg releaseDirectory "$release_directory" \
    --arg metadataPath "$metadata_path" \
    --arg metadataSHA256 "$(file_sha256 "$metadata_path")" \
    --arg candidateCreatedAt "$candidate_created_at" '{
      appBundleID: $appBundleID,
      version: $version,
      build: $build,
      archivePath: $archivePath,
      archiveZipPath: $archiveZipPath,
      archiveZipSHA256: $archiveZipSHA256,
      packagePath: $packagePath,
      packageSHA256: $packageSHA256,
      releaseDirectory: $releaseDirectory,
      metadataPath: $metadataPath,
      metadataSHA256: $metadataSHA256,
      candidateCreatedAt: $candidateCreatedAt
    }'
}

while (( $# > 0 )); do
  case "$1" in
    --json)
      [[ "$MODE" == "validate" ]] || fail "--json is not valid with inspection mode"
      OUTPUT_JSON=true
      shift
      ;;
    --expected-release-metadata)
      (( $# >= 2 )) || fail "--expected-release-metadata requires a file"
      EXPECTED_RELEASE_METADATA="$2"
      shift 2
      ;;
    --expected-archive-sha256)
      (( $# >= 2 )) || fail "--expected-archive-sha256 requires a SHA-256 value"
      EXPECTED_ARCHIVE_SHA256="$2"
      shift 2
      ;;
    --expected-package-sha256)
      (( $# >= 2 )) || fail "--expected-package-sha256 requires a SHA-256 value"
      EXPECTED_PACKAGE_SHA256="$2"
      shift 2
      ;;
    --inspect-release-metadata)
      [[ "$MODE" == "validate" && -z "$INPUT_PATH" ]] \
        || fail "choose exactly one validation mode"
      MODE="inspect-metadata"
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
for tool in /usr/bin/jq /usr/bin/shasum /usr/bin/stat; do
  [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done

if [[ "$MODE" == "inspect-metadata" ]]; then
  [[ -z "$EXPECTED_RELEASE_METADATA" && -z "$EXPECTED_ARCHIVE_SHA256" \
      && -z "$EXPECTED_PACKAGE_SHA256" && "$OUTPUT_JSON" == false ]] \
    || fail "inspection mode does not accept expected-candidate options"
  inspect_release_metadata "$INPUT_PATH"
  exit 0
fi

[[ -f "$INPUT_PATH" && ! -L "$INPUT_PATH" ]] \
  || fail "functional QA evidence must be an existing, non-symlink file"
EVIDENCE_PATH="${INPUT_PATH:A}"
RELEASE_DIRECTORY="${EVIDENCE_PATH:h}"
[[ "${EVIDENCE_PATH:t}" == macos-functional-verification-*.json ]] \
  || fail "functional QA evidence filename is not a generated evidence record"
[[ -d "$RELEASE_DIRECTORY" && ! -L "$RELEASE_DIRECTORY" ]] \
  || fail "functional QA evidence parent must be a non-symlink release directory"
require_read_only "$EVIDENCE_PATH" "functional QA evidence"

/usr/bin/jq -e '
  type == "object" and
  .schemaVersion == 1 and
  .platform == "macOS" and
  .evidenceType == "exact-mac-app-store-functional-qa" and
  (.releaseMetadata.path | type == "string" and length > 0) and
  (.releaseMetadata.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.releaseMetadata.candidateCreatedAt | type == "string" and length > 0) and
  (.candidate.appBundleID | type == "string" and length > 0) and
  (.candidate.version | type == "string" and length > 0) and
  (.candidate.build | type == "string" and length > 0) and
  (.candidate.archiveZipPath | type == "string" and length > 0) and
  (.candidate.archiveZipSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.candidate.packagePath | type == "string" and length > 0) and
  (.candidate.packageSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.testMachine.model | type == "string" and length > 0) and
  .testMachine.operatingSystem == "macOS" and
  (.testMachine.osVersion | type == "string" and length > 0) and
  (.testedAt | type == "string" and length > 0) and
  (.createdAt | type == "string" and length > 0) and
  .qa.sandboxAuthorizationFlow.result == "passed" and
  .qa.sandboxAuthorizationFlow.authorizationConfirmed == true and
  .qa.sandboxAuthorizationFlow.denialConfirmed == true and
  .qa.sandboxAuthorizationFlow.revocationConfirmed == true and
  .qa.sandboxAuthorizationFlow.recoveryConfirmed == true and
  .qa.archiveInstallLaunchQuit.result == "passed" and
  .qa.archiveInstallLaunchQuit.archiveInspected == true and
  .qa.archiveInstallLaunchQuit.packageInstalled == true and
  .qa.archiveInstallLaunchQuit.launchConfirmed == true and
  .qa.archiveInstallLaunchQuit.quitConfirmed == true and
  .qa.profileCertificate.result == "passed" and
  .qa.profileCertificate.profileChecked == true and
  .qa.profileCertificate.certificateMatchConfirmed == true and
  .qa.xcodePrivacyReport.result == "passed" and
  .qa.xcodePrivacyReport.reportReviewed == true and
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

METADATA_PATH="$(/usr/bin/jq -r '.releaseMetadata.path' "$EVIDENCE_PATH")"
METADATA_PATH="$(require_release_file \
  "$METADATA_PATH" "$RELEASE_DIRECTORY" "release metadata")"
[[ "$METADATA_PATH" == "$RELEASE_DIRECTORY/release-metadata.json" ]] \
  || fail "functional QA evidence references the wrong release metadata"
[[ "$(file_sha256 "$METADATA_PATH")" == \
    "$(/usr/bin/jq -r '.releaseMetadata.sha256' "$EVIDENCE_PATH")" ]] \
  || fail "release metadata SHA-256 does not match the functional QA record"

if [[ -n "$EXPECTED_RELEASE_METADATA" ]]; then
  [[ -f "$EXPECTED_RELEASE_METADATA" && ! -L "$EXPECTED_RELEASE_METADATA" ]] \
    || fail "expected release metadata is not a regular non-symlink file"
  [[ "${EXPECTED_RELEASE_METADATA:A}" == "$METADATA_PATH" ]] \
    || fail "functional QA evidence is not bound to the expected release metadata"
fi
if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
  valid_sha256 "$EXPECTED_ARCHIVE_SHA256" || fail "expected Archive ZIP SHA-256 is malformed"
fi
if [[ -n "$EXPECTED_PACKAGE_SHA256" ]]; then
  valid_sha256 "$EXPECTED_PACKAGE_SHA256" || fail "expected package SHA-256 is malformed"
fi

CANDIDATE_JSON="$(inspect_release_metadata "$METADATA_PATH")"
/usr/bin/jq -e --argjson actual "$CANDIDATE_JSON" '
  .releaseMetadata.path == $actual.metadataPath and
  .releaseMetadata.sha256 == $actual.metadataSHA256 and
  .releaseMetadata.candidateCreatedAt == $actual.candidateCreatedAt and
  .candidate.appBundleID == $actual.appBundleID and
  .candidate.version == $actual.version and
  .candidate.build == $actual.build and
  .candidate.archiveZipPath == $actual.archiveZipPath and
  .candidate.archiveZipSHA256 == $actual.archiveZipSHA256 and
  .candidate.packagePath == $actual.packagePath and
  .candidate.packageSHA256 == $actual.packageSHA256
' "$EVIDENCE_PATH" >/dev/null \
  || fail "functional QA evidence candidate does not match the exact Archive ZIP and package"
[[ -z "$EXPECTED_ARCHIVE_SHA256" || \
    "$(/usr/bin/jq -r '.candidate.archiveZipSHA256' "$EVIDENCE_PATH")" == "$EXPECTED_ARCHIVE_SHA256" ]] \
  || fail "functional QA evidence is not bound to the expected Archive ZIP SHA-256"
[[ -z "$EXPECTED_PACKAGE_SHA256" || \
    "$(/usr/bin/jq -r '.candidate.packageSHA256' "$EVIDENCE_PATH")" == "$EXPECTED_PACKAGE_SHA256" ]] \
  || fail "functional QA evidence is not bound to the expected package SHA-256"

MAC_MODEL="$(/usr/bin/jq -r '.testMachine.model' "$EVIDENCE_PATH")"
MACOS_VERSION="$(/usr/bin/jq -r '.testMachine.osVersion' "$EVIDENCE_PATH")"
placeholder_text "$MAC_MODEL" && fail "Mac model is a placeholder"
placeholder_text "$MACOS_VERSION" && fail "macOS version is a placeholder"
[[ ${#MAC_MODEL} -le 128 && ${#MACOS_VERSION} -le 64 ]] \
  || fail "Mac model or macOS version is unreasonably long"
[[ "$MACOS_VERSION" != *$'\n'* && "$MACOS_VERSION" != *$'\r'* ]] \
  || fail "macOS version must contain 2 or 3 numeric components"
print -r -- "$MACOS_VERSION" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' \
  || fail "macOS version must contain 2 or 3 numeric components"

TESTED_AT="$(/usr/bin/jq -r '.testedAt' "$EVIDENCE_PATH")"
CREATED_AT="$(/usr/bin/jq -r '.createdAt' "$EVIDENCE_PATH")"
CANDIDATE_CREATED_AT="$(/usr/bin/jq -r '.releaseMetadata.candidateCreatedAt' "$EVIDENCE_PATH")"
for timestamp in "$CANDIDATE_CREATED_AT" "$TESTED_AT" "$CREATED_AT"; do
  valid_utc_timestamp "$timestamp" \
    || fail "functional QA evidence contains an invalid UTC timestamp"
done
[[ "$(/usr/bin/jq -r '[.qa[].testedAt] | unique | length' "$EVIDENCE_PATH")" == "1" ]] \
  || fail "all five QA checks must record the exact functional test timestamp"
[[ "$(/usr/bin/jq -r '.qa[].testedAt' "$EVIDENCE_PATH" | /usr/bin/head -n 1)" == "$TESTED_AT" ]] \
  || fail "per-check test timestamps do not match the functional QA test timestamp"
CANDIDATE_CREATED_EPOCH="$(timestamp_epoch "$CANDIDATE_CREATED_AT")"
TESTED_EPOCH="$(timestamp_epoch "$TESTED_AT")"
CREATED_EPOCH="$(timestamp_epoch "$CREATED_AT")"
NOW_EPOCH="$(/bin/date -u '+%s')"
(( CANDIDATE_CREATED_EPOCH <= TESTED_EPOCH \
  && TESTED_EPOCH <= CREATED_EPOCH \
  && CREATED_EPOCH <= NOW_EPOCH + 300 )) \
  || fail "functional QA timestamps precede candidate creation or are in the future"

typeset -a ATTACHMENT_PATHS ATTACHMENT_IDENTITIES ATTACHMENT_HASHES
for check_name in sandboxAuthorizationFlow archiveInstallLaunchQuit \
    profileCertificate xcodePrivacyReport reviewPath; do
  attachment_path="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.path' "$EVIDENCE_PATH")"
  attachment_sha256="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.sha256' "$EVIDENCE_PATH")"
  attachment_size="$(/usr/bin/jq -r --arg check "$check_name" \
    '.qa[$check].evidence.sizeBytes' "$EVIDENCE_PATH")"
  attachment_path="$(require_release_file \
    "$attachment_path" "$RELEASE_DIRECTORY" "$check_name QA attachment")"
  [[ "$attachment_path" != "$EVIDENCE_PATH" && "$attachment_path" != "$METADATA_PATH" ]] \
    || fail "$check_name QA attachment cannot be an evidence record or release metadata"
  for artifact_key in archiveZipPath packagePath; do
    [[ "$attachment_path" != "$(print -r -- "$CANDIDATE_JSON" \
        | /usr/bin/jq -r --arg key "$artifact_key" '.[$key]')" ]] \
      || fail "$check_name QA attachment cannot reuse a core release artifact"
  done
  case "${attachment_path:t}" in
    *.sha256|mac-app-store-*.json|macos-functional-verification-*.json)
      fail "$check_name QA attachment cannot reuse a core release artifact"
      ;;
  esac
  attachment_extension="${${attachment_path:e}:l}"
  case "$attachment_extension" in
    txt|md|json|png|jpg|jpeg|heic|pdf|mov|mp4) ;;
    *) fail "$check_name QA attachment has an unsupported report format" ;;
  esac
  actual_size="$(/usr/bin/stat -f '%z' "$attachment_path")"
  [[ "$actual_size" == "$attachment_size" && "$actual_size" -gt 0 \
      && "$actual_size" -le 26214400 ]] \
    || fail "$check_name QA attachment size does not match the functional QA record"
  [[ "$(file_sha256 "$attachment_path")" == "$attachment_sha256" ]] \
    || fail "$check_name QA attachment SHA-256 does not match the functional QA record"
  ATTACHMENT_PATHS+=("$attachment_path")
  ATTACHMENT_IDENTITIES+=("$(/usr/bin/stat -f '%d:%i' "$attachment_path")")
  ATTACHMENT_HASHES+=("$attachment_sha256")
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
EVIDENCE_SHA256="$(file_sha256 "$EVIDENCE_PATH")"
METADATA_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.metadataSHA256')"
ARCHIVE_ZIP_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.archiveZipSHA256')"
PACKAGE_SHA256="$(print -r -- "$CANDIDATE_JSON" | /usr/bin/jq -r '.packageSHA256')"
for attachment_sha256 in "${ATTACHMENT_HASHES[@]}"; do
  for core_sha256 in "$METADATA_SHA256" "$ARCHIVE_ZIP_SHA256" \
      "$PACKAGE_SHA256" "$EVIDENCE_SHA256"; do
    [[ "$attachment_sha256" != "$core_sha256" ]] \
      || fail "QA attachment content cannot match metadata, Archive ZIP, package, or evidence"
  done
done

if [[ "$OUTPUT_JSON" == true ]]; then
  /usr/bin/jq -n \
    --arg path "$EVIDENCE_PATH" \
    --arg sha256 "$EVIDENCE_SHA256" \
    --arg macModel "$MAC_MODEL" \
    --arg macosVersion "$MACOS_VERSION" \
    --arg testedAt "$TESTED_AT" \
    --argjson candidate "$CANDIDATE_JSON" '{
      evidenceReady: true,
      evidencePath: $path,
      evidenceSHA256: $sha256,
      testMachine: {model: $macModel, operatingSystem: "macOS", osVersion: $macosVersion},
      testedAt: $testedAt,
      candidate: {
        appBundleID: $candidate.appBundleID,
        version: $candidate.version,
        build: $candidate.build,
        archiveZipPath: $candidate.archiveZipPath,
        archiveZipSHA256: $candidate.archiveZipSHA256,
        packagePath: $candidate.packagePath,
        packageSHA256: $candidate.packageSHA256
      },
      sandboxFlowVerified: true,
      archiveInstallLaunchQuitVerified: true,
      profileCertificateVerified: true,
      privacyReportVerified: true,
      reviewPathVerified: true
    }'
else
  print -r -- "macOS functional QA evidence is valid: $EVIDENCE_PATH"
  print -r -- "Candidate: $(/usr/bin/jq -r '.candidate.appBundleID + ":" + .candidate.version + ":" + .candidate.build' "$EVIDENCE_PATH")"
  print -r -- "Archive ZIP SHA-256: $(/usr/bin/jq -r '.candidate.archiveZipSHA256' "$EVIDENCE_PATH")"
  print -r -- "PKG SHA-256: $(/usr/bin/jq -r '.candidate.packageSHA256' "$EVIDENCE_PATH")"
  print -r -- "This validation is local and does not query or change Apple state."
fi
