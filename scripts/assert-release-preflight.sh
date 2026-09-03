#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 -r -- "Usage: ${0:t} developer-id|mac-app-store|mac-app-store-upload|mac-app-store-review|ios|ios-upload|ios-app-store-review READINESS_JSON"
}

fail() {
  print -u2 -r -- "Release preflight failed: $*"
  exit 2
}

SHA256_PATTERN='^[0-9a-f]{64}$'
UTC_TIMESTAMP_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z$'

freeze_file_no_follow() {
  local source_path="$1"
  local snapshot_path="$2"
  command -v node >/dev/null 2>&1 \
    || fail "Node.js is required to freeze release evidence safely"
  node -e '
    const fs = require("fs");
    const [source, destination] = process.argv.slice(1);
    const noFollow = fs.constants.O_NOFOLLOW;
    if (!Number.isInteger(noFollow) || noFollow === 0) process.exit(2);
    let sourceFD;
    let destinationFD;
    try {
      sourceFD = fs.openSync(source, fs.constants.O_RDONLY | noFollow);
      const before = fs.fstatSync(sourceFD, { bigint: true });
      if (!before.isFile()) process.exit(3);
      const bytes = fs.readFileSync(sourceFD);
      const after = fs.fstatSync(sourceFD, { bigint: true });
      if (before.dev !== after.dev || before.ino !== after.ino ||
          before.mode !== after.mode || before.size !== after.size ||
          before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) {
        process.exit(4);
      }
      destinationFD = fs.openSync(
        destination,
        fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | noFollow,
        0o400,
      );
      let offset = 0;
      while (offset < bytes.length) {
        offset += fs.writeSync(destinationFD, bytes, offset, bytes.length - offset);
      }
      fs.fsyncSync(destinationFD);
      fs.fchmodSync(destinationFD, 0o400);
    } catch {
      process.exit(5);
    } finally {
      if (destinationFD !== undefined) fs.closeSync(destinationFD);
      if (sourceFD !== undefined) fs.closeSync(sourceFD);
    }
  ' "$source_path" "$snapshot_path" >/dev/null 2>&1 \
    || fail "could not safely freeze $source_path"
}

# Re-read each release record at the protected action boundary. The inode and
# hash checks make a replacement or edit after readiness fail closed; canonical
# path checks also reject a symlink in any parent component.
revalidate_evidence_file() {
  local label="$1"
  local evidence_path="$2"
  local expected_sha256="$3"
  local permission_policy="$4"
  local inode_before mode_before actual_sha256 inode_after mode_after
  local snapshot_path snapshot_sha256

  [[ "$evidence_path" == /* && -f "$evidence_path" && ! -L "$evidence_path" ]] \
    || fail "$label must be an absolute, regular, non-symlink file"
  [[ "${evidence_path:a}" == "$evidence_path" && \
    "${evidence_path:A}" == "$evidence_path" ]] \
    || fail "$label path is not canonical or traverses a symlink"
  print -r -- "$expected_sha256" | /usr/bin/grep -Eq "$SHA256_PATTERN" \
    || fail "$label has no valid readiness SHA-256"
  inode_before="$(/usr/bin/stat -f '%d:%i' "$evidence_path" 2>/dev/null || true)"
  mode_before="$(/usr/bin/stat -f '%Lp' "$evidence_path" 2>/dev/null || true)"
  [[ "$inode_before" == <->:<-> && "$mode_before" == <-> ]] \
    || fail "could not identify $label"
  case "$permission_policy" in
    no-write)
      (( (8#$mode_before & 8#0222) == 0 )) \
        || fail "$label must not be writable"
      ;;
    exact-0444)
      (( 8#$mode_before == 8#0444 )) \
        || fail "$label must have mode 0444"
      ;;
    *)
      fail "internal error: unknown $label permission policy"
      ;;
  esac
  actual_sha256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
    "$evidence_path" | /usr/bin/awk '{print $1}')"
  EVIDENCE_SNAPSHOT_INDEX=$(( EVIDENCE_SNAPSHOT_INDEX + 1 ))
  snapshot_path="$REPORT_SNAPSHOT_DIR/evidence-$EVIDENCE_SNAPSHOT_INDEX.json"
  freeze_file_no_follow "$evidence_path" "$snapshot_path"
  snapshot_sha256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
    "$snapshot_path" | /usr/bin/awk '{print $1}')"
  inode_after="$(/usr/bin/stat -f '%d:%i' "$evidence_path" 2>/dev/null || true)"
  mode_after="$(/usr/bin/stat -f '%Lp' "$evidence_path" 2>/dev/null || true)"
  [[ -f "$evidence_path" && ! -L "$evidence_path" && \
    "${evidence_path:a}" == "$evidence_path" && \
    "${evidence_path:A}" == "$evidence_path" && \
    "$inode_after" == "$inode_before" && "$mode_after" == "$mode_before" && \
    "$actual_sha256" == "$expected_sha256" && \
    "$snapshot_sha256" == "$expected_sha256" ]] \
    || fail "$label changed after the readiness report was generated"
  /usr/bin/jq -e 'type == "object"' "$snapshot_path" >/dev/null 2>&1 \
    || fail "$label is not valid JSON"
  REVALIDATED_EVIDENCE_SNAPSHOT="$snapshot_path"
}

verify_report_source_unchanged() {
  local inode_now mode_now sha256_now
  [[ "$REPORT_SOURCE_PATH" == /* && -f "$REPORT_SOURCE_PATH" && \
    ! -L "$REPORT_SOURCE_PATH" && \
    "${REPORT_SOURCE_PATH:a}" == "$REPORT_SOURCE_PATH" && \
    "${REPORT_SOURCE_PATH:A}" == "$REPORT_SOURCE_PATH" ]] \
    || fail "readiness report path changed during preflight"
  inode_now="$(/usr/bin/stat -f '%d:%i' "$REPORT_SOURCE_PATH" 2>/dev/null || true)"
  mode_now="$(/usr/bin/stat -f '%Lp' "$REPORT_SOURCE_PATH" 2>/dev/null || true)"
  sha256_now="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
    "$REPORT_SOURCE_PATH" | /usr/bin/awk '{print $1}')"
  [[ "$inode_now" == "$REPORT_SOURCE_INODE" && \
    "$mode_now" == "$REPORT_SOURCE_MODE" && \
    "$sha256_now" == "$REPORT_SOURCE_SHA256" ]] \
    || fail "readiness report changed during preflight"
}

utc_timestamp_milliseconds() {
  local value="$1"
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    const value = process.argv[1];
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) process.exit(1);
    const milliseconds = Date.parse(value);
    if (!Number.isSafeInteger(milliseconds)) process.exit(1);
    const canonical = new Date(milliseconds).toISOString();
    if (value !== canonical && value !== canonical.replace(".000Z", "Z")) process.exit(1);
    process.stdout.write(String(milliseconds));
  ' "$value" 2>/dev/null
}

validate_utc_timestamp() {
  local label="$1"
  local value="$2"
  print -r -- "$value" | /usr/bin/grep -Eq "$UTC_TIMESTAMP_PATTERN" \
    || fail "$label is invalid"
  utc_timestamp_milliseconds "$value" >/dev/null \
    || fail "$label is not a real UTC timestamp"
}

revalidate_final_review_evidence() {
  local platform="$1"
  local manifest_source_path manifest_path manifest_sha256
  local expected_app_resource_id expected_sku
  local expected_primary_locale
  local public_source_path public_path public_sha256 public_binding_type
  local public_binding_path
  local public_binding_sha256 public_relative_binding public_oldest_checked_at
  local public_newest_checked_at public_max_age_seconds public_oldest_milliseconds
  local public_newest_milliseconds
  local asc_source_path asc_path asc_sha256 asc_evidence_sha256 asc_captured_at
  local asc_expires_at asc_max_age_seconds asc_max_age_valid
  local asc_app_resource_id asc_build_resource_id asc_warnings_present
  local operator_build_id warnings_reviewed_at record_key expected_platform
  local expected_bundle_id expected_version expected_build
  local now_milliseconds asc_captured_milliseconds asc_expires_milliseconds
  local warnings_reviewed_milliseconds

  manifest_source_path="$(/usr/bin/jq -er '.appStoreSubmissionManifestPath' "$REPORT_PATH")" \
    || fail "readiness report has no App Store submission manifest path"
  manifest_sha256="$(/usr/bin/jq -er '.appStoreSubmissionManifestSHA256' "$REPORT_PATH")" \
    || fail "readiness report has no App Store submission manifest SHA-256"
  [[ "$manifest_source_path" == */.release/app-store-submission.json ]] \
    || fail "App Store submission manifest must use the fixed release path"
  revalidate_evidence_file "App Store submission manifest" \
    "$manifest_source_path" "$manifest_sha256" no-write
  manifest_path="$REVALIDATED_EVIDENCE_SNAPSHOT"
  /usr/bin/jq -e --arg identitySHA "$EXPECTED_IDENTITY_LOCK_SHA256" \
    '.identityLockSHA256 == $identitySHA' "$manifest_path" >/dev/null 2>&1 \
    || fail "App Store submission manifest differs from the release identity lock"

  public_source_path="$(/usr/bin/jq -er '.publicPagesEvidencePath' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages evidence path"
  public_sha256="$(/usr/bin/jq -er '.publicPagesEvidenceSHA256' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages evidence SHA-256"
  public_binding_type="$(/usr/bin/jq -er '.publicPagesEvidenceBindingType' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages binding type"
  public_binding_path="$(/usr/bin/jq -er '.publicPagesEvidenceBindingPath' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages binding path"
  public_binding_sha256="$(/usr/bin/jq -er '.publicPagesEvidenceBindingSHA256' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages binding SHA-256"
  public_oldest_checked_at="$(/usr/bin/jq -er '.publicPagesEvidenceOldestCheckedAt' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages oldest check time"
  public_newest_checked_at="$(/usr/bin/jq -er '.publicPagesEvidenceNewestCheckedAt' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages newest check time"
  public_max_age_seconds="$(/usr/bin/jq -er '.publicPagesEvidenceMaxAgeSeconds' "$REPORT_PATH")" \
    || fail "readiness report has no public-pages maximum age"
  [[ "$public_binding_type" == "submission-manifest" && \
    "$public_binding_path" == "$manifest_source_path" && \
    "$public_binding_sha256" == "$manifest_sha256" ]] \
    || fail "public-pages evidence is not bound to the current submission manifest"
  revalidate_evidence_file "public-pages evidence" \
    "$public_source_path" "$public_sha256" exact-0444
  public_path="$REVALIDATED_EVIDENCE_SNAPSHOT"
  public_relative_binding="$(/usr/bin/jq -er '.binding.path' "$public_path")" \
    || fail "public-pages evidence has no binding path"
  [[ "$public_relative_binding" == ".release/app-store-submission.json" && \
    "$manifest_source_path" == */"$public_relative_binding" ]] \
    || fail "public-pages evidence binding path differs from the submission manifest"
  /usr/bin/jq -e --arg sha "$manifest_sha256" '
    .evidenceType == "public-pages" and
    .binding.type == "submission-manifest" and
    .binding.sha256 == $sha
  ' "$public_path" >/dev/null 2>&1 \
    || fail "public-pages evidence binding content differs from the submission manifest"
  validate_utc_timestamp "public-pages oldest check time" "$public_oldest_checked_at"
  validate_utc_timestamp "public-pages newest check time" "$public_newest_checked_at"
  [[ "$public_max_age_seconds" == "86400" ]] \
    || fail "public-pages evidence maximum age must be 86400 seconds"
  /usr/bin/jq -e \
    --arg oldest "$public_oldest_checked_at" \
    --arg newest "$public_newest_checked_at" '
      .schemaVersion == 1 and
      .productName == "MAC版灵动岛--Agent运行监测" and
      (.configuredURLs | type == "object") and
      (.configuredURLs.privacy | type == "string" and startswith("https://")) and
      (.configuredURLs.support | type == "string" and startswith("https://")) and
      .configuredURLs.privacy != .configuredURLs.support and
      (.allowedOrigins | type == "array" and length >= 1) and
      (.pages | type == "array" and length == 2) and
      [.pages[].kind] == ["privacy", "support"] and
      .pages[0].configuredURL == .configuredURLs.privacy and
      .pages[1].configuredURL == .configuredURLs.support and
      all(.pages[];
        ((.configuredURL | type) == "string" and
          (.configuredURL | startswith("https://"))) and
        ((.finalURL | type) == "string" and
          (.finalURL | startswith("https://"))) and
        ((.status | type) == "number" and
          (.status | floor) == .status and .status >= 200 and .status <= 299) and
        ((.contentType | type) == "string" and
          (.contentType | ascii_downcase | startswith("text/html"))) and
        ((.bodySizeBytes | type) == "number" and
          (.bodySizeBytes | floor) == .bodySizeBytes and
          .bodySizeBytes >= 1 and .bodySizeBytes <= 1048576) and
        ((.bodySHA256 | type) == "string" and
          (.bodySHA256 | test("^[0-9a-f]{64}$"))) and
        ((.redirectCount | type) == "number" and
          (.redirectCount | floor) == .redirectCount and
          .redirectCount >= 0 and .redirectCount <= 5) and
        .validations.productName == true and
        .validations.bilingualLanguages == true and
        .validations.pagePurpose == true and
        .validations.contactOrDeletionPath == true
      ) and
      ([.pages[].checkedAt] | min) == $oldest and
      ([.pages[].checkedAt] | max) == $newest
    ' "$public_path" >/dev/null 2>&1 \
    || fail "public-pages check times differ from the evidence content"

  now_milliseconds="$(node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null || true)"
  public_oldest_milliseconds="$(utc_timestamp_milliseconds \
    "$public_oldest_checked_at" || true)"
  public_newest_milliseconds="$(utc_timestamp_milliseconds \
    "$public_newest_checked_at" || true)"
  [[ "$now_milliseconds" == <-> && "$public_oldest_milliseconds" == <-> && \
    "$public_newest_milliseconds" == <-> ]] \
    || fail "could not compare public-pages evidence freshness"
  (( public_oldest_milliseconds <= public_newest_milliseconds && \
    public_newest_milliseconds <= now_milliseconds + 300000 && \
    now_milliseconds - public_oldest_milliseconds <= \
      public_max_age_seconds * 1000 )) \
    || fail "public-pages evidence is stale or not yet valid"

  if [[ "$platform" == "macos" ]]; then
    record_key="macos"
    expected_platform="MAC_OS"
    expected_bundle_id="$(/usr/bin/jq -er '.productionBundleID' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS bundle ID"
    expected_version="$(/usr/bin/jq -er '.macMarketingVersion' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS version"
    expected_build="$(/usr/bin/jq -er '.macBuildNumber' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS build number"
    expected_app_resource_id="$(/usr/bin/jq -er '.macAppStoreExpectedAppResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS App resource ID"
    expected_sku="$(/usr/bin/jq -er '.macAppStoreExpectedSKU' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS App SKU"
    expected_primary_locale="$(/usr/bin/jq -er '.macAppStoreExpectedPrimaryLocale' "$REPORT_PATH")" \
      || fail "readiness report has no expected macOS primary locale"
    asc_source_path="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotPath' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect snapshot path"
    asc_sha256="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotSHA256' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect snapshot SHA-256"
    asc_evidence_sha256="$(/usr/bin/jq -er '.macAppStoreConnectEvidenceSHA256' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect evidence SHA-256"
    asc_captured_at="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotCapturedAt' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect capture time"
    asc_expires_at="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotExpiresAt' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect expiry time"
    asc_app_resource_id="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotAppResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect App resource ID"
    asc_build_resource_id="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotBuildResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect build resource ID"
    asc_warnings_present="$(/usr/bin/jq -er '.macAppStoreConnectBuildSnapshotWarningsPresent | tostring' "$REPORT_PATH")" \
      || fail "readiness report has no macOS App Store Connect warning state"
    operator_build_id="$(/usr/bin/jq -er '.macAppStoreConnectBuildID' "$REPORT_PATH")" \
      || fail "readiness report has no macOS operator build ID"
    warnings_reviewed_at="$(/usr/bin/jq -er '.macAppStoreWarningsReviewedAt' "$REPORT_PATH")" \
      || fail "readiness report has no macOS warning-review time"
  else
    record_key="ios"
    expected_platform="IOS"
    expected_bundle_id="$(/usr/bin/jq -er '.iosAppBundleID' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS bundle ID"
    expected_version="$(/usr/bin/jq -er '.iosMarketingVersion' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS version"
    expected_build="$(/usr/bin/jq -er '.iosBuildNumber' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS build number"
    expected_app_resource_id="$(/usr/bin/jq -er '.iosAppStoreExpectedAppResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS App resource ID"
    expected_sku="$(/usr/bin/jq -er '.iosAppStoreExpectedSKU' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS App SKU"
    expected_primary_locale="$(/usr/bin/jq -er '.iosAppStoreExpectedPrimaryLocale' "$REPORT_PATH")" \
      || fail "readiness report has no expected iOS primary locale"
    asc_source_path="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotPath' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect snapshot path"
    asc_sha256="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotSHA256' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect snapshot SHA-256"
    asc_evidence_sha256="$(/usr/bin/jq -er '.iosAppStoreConnectEvidenceSHA256' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect evidence SHA-256"
    asc_captured_at="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotCapturedAt' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect capture time"
    asc_expires_at="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotExpiresAt' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect expiry time"
    asc_app_resource_id="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotAppResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect App resource ID"
    asc_build_resource_id="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotBuildResourceID' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect build resource ID"
    asc_warnings_present="$(/usr/bin/jq -er '.iosAppStoreConnectBuildSnapshotWarningsPresent | tostring' "$REPORT_PATH")" \
      || fail "readiness report has no iOS App Store Connect warning state"
    operator_build_id="$(/usr/bin/jq -er '.iosTestFlightAppStoreConnectBuildID' "$REPORT_PATH")" \
      || fail "readiness report has no iOS operator build ID"
    warnings_reviewed_at="$(/usr/bin/jq -er '.iosTestFlightWarningsReviewedAt' "$REPORT_PATH")" \
      || fail "readiness report has no iOS warning-review time"
  fi

  asc_max_age_valid="$(/usr/bin/jq -er \
    '.appStoreConnectSnapshotMaxAgeValid | tostring' "$REPORT_PATH")" \
    || fail "readiness report has no App Store Connect maximum-age validity"
  asc_max_age_seconds="$(/usr/bin/jq -er '
    .appStoreConnectSnapshotMaxAgeSeconds |
    select(type == "number" and isfinite and floor == . and . >= 1 and . <= 900) |
    tostring
  ' "$REPORT_PATH")" \
    || fail "readiness report has no valid App Store Connect maximum age"
  [[ "$asc_max_age_valid" == true ]] \
    || fail "App Store Connect maximum-age policy is invalid"

  print -r -- "$expected_app_resource_id" | /usr/bin/grep -Eq '^[0-9]{8,20}$' \
    || fail "$platform expected App resource ID is invalid"
  [[ -n "$expected_sku" && ${#expected_sku} -le 64 && \
    -n "$expected_primary_locale" && ${#expected_primary_locale} -le 35 && \
    -n "$expected_bundle_id" && -n "$expected_version" && -n "$expected_build" ]] \
    || fail "$platform expected App identity or build tuple is invalid"
  print -r -- "$asc_evidence_sha256" | /usr/bin/grep -Eq "$SHA256_PATTERN" \
    || fail "$platform App Store Connect evidence SHA-256 is invalid"
  validate_utc_timestamp "$platform App Store Connect capture time" "$asc_captured_at"
  validate_utc_timestamp "$platform App Store Connect expiry time" "$asc_expires_at"
  validate_utc_timestamp "$platform warning-review time" "$warnings_reviewed_at"
  asc_captured_milliseconds="$(utc_timestamp_milliseconds "$asc_captured_at" || true)"
  asc_expires_milliseconds="$(utc_timestamp_milliseconds "$asc_expires_at" || true)"
  warnings_reviewed_milliseconds="$(utc_timestamp_milliseconds \
    "$warnings_reviewed_at" || true)"
  [[ "$now_milliseconds" == <-> && "$asc_captured_milliseconds" == <-> && \
    "$asc_expires_milliseconds" == <-> && \
    "$warnings_reviewed_milliseconds" == <-> ]] \
    || fail "could not compare $platform App Store Connect evidence times"
  (( asc_captured_milliseconds < asc_expires_milliseconds && \
    asc_expires_milliseconds - asc_captured_milliseconds == 900000 && \
    asc_captured_milliseconds <= now_milliseconds + 60000 && \
    now_milliseconds <= asc_expires_milliseconds && \
    now_milliseconds - asc_captured_milliseconds <= \
      asc_max_age_seconds * 1000 && \
    warnings_reviewed_milliseconds <= now_milliseconds + 60000 )) \
    || fail "$platform App Store Connect snapshot is stale or not yet valid"
  if [[ "$asc_warnings_present" == true ]]; then
    (( warnings_reviewed_milliseconds >= asc_captured_milliseconds )) \
      || fail "$platform warning review predates the App Store Connect snapshot"
  fi
  [[ "$asc_app_resource_id" == "$expected_app_resource_id" && \
    "$asc_build_resource_id" == "$operator_build_id" ]] \
    || fail "$platform App Store Connect resource IDs differ from the selected submission"

  /usr/bin/jq -e \
    --arg record "$record_key" \
    --arg id "$expected_app_resource_id" \
    --arg sku "$expected_sku" \
    --arg locale "$expected_primary_locale" '
      .records[$record].appResourceId == $id and
      .records[$record].sku == $sku and
      .records[$record].primaryLocale == $locale
    ' "$manifest_path" >/dev/null 2>&1 \
    || fail "$platform expected App identity differs from the submission manifest"
  revalidate_evidence_file "$platform App Store Connect build snapshot" \
    "$asc_source_path" "$asc_sha256" exact-0444
  asc_path="$REVALIDATED_EVIDENCE_SNAPSHOT"
  /usr/bin/jq -e \
    --arg platform "$expected_platform" \
    --arg bundleID "$expected_bundle_id" \
    --arg version "$expected_version" \
    --arg build "$expected_build" \
    --arg appID "$expected_app_resource_id" \
    --arg buildID "$operator_build_id" \
    --arg sku "$expected_sku" \
    --arg locale "$expected_primary_locale" \
    --arg evidenceSHA "$asc_evidence_sha256" \
    --arg capturedAt "$asc_captured_at" \
    --arg expiresAt "$asc_expires_at" \
    --arg identityPath "$IDENTITY_LOCK_PATH" \
    --arg identitySHA "$EXPECTED_IDENTITY_LOCK_SHA256" \
    --argjson warningsPresent "$asc_warnings_present" '
    .kind == "app-store-connect-build-snapshot" and
    .readOnly == true and
    .query.bundleID == $bundleID and
    .query.platform == $platform and
    .query.version == $version and
    .query.build == $build and
    .resourceIDs.app == $appID and
    .resourceIDs.build == $buildID and
    .app.resourceID == $appID and
    .app.bundleID == $bundleID and
    .app.sku == $sku and
    .app.primaryLocale == $locale and
    .preReleaseVersion.resourceID == .resourceIDs.preReleaseVersion and
    .preReleaseVersion.version == $version and
    .preReleaseVersion.platform == $platform and
    .build.resourceID == $buildID and
    .build.buildNumber == $build and
    .build.processingState == "VALID" and
    .build.expired == false and
    .build.buildAudienceType == "APP_STORE_ELIGIBLE" and
    (.build.usesNonExemptEncryption | type == "boolean") and
    .build.exportComplianceRequired == .build.usesNonExemptEncryption and
    .buildUpload.resourceID == .resourceIDs.buildUpload and
    .buildUpload.cfBundleShortVersionString == $version and
    .buildUpload.cfBundleVersion == $build and
    .buildUpload.platform == $platform and
    .buildUpload.state == "COMPLETE" and
    (.buildUpload.errors | type == "array" and length == 0) and
    (.buildUpload.warnings | type == "array") and
    (.buildUpload.infos | type == "array") and
    .buildUpload.warningsPresent == (.buildUpload.warnings | length > 0) and
    .evidenceSHA256 == $evidenceSHA and
    .capturedAt == $capturedAt and
    .expiresAt == $expiresAt and
    .candidate.releaseIdentityLockPath == $identityPath and
    .candidate.releaseIdentityLockSHA256 == $identitySHA and
    .buildUpload.warningsPresent == $warningsPresent and
    .readiness.candidateBindingsVerified == true and
    .readiness.appResourceUnique == true and
    .readiness.preReleaseVersionExact == true and
    .readiness.buildResourceUnique == true and
    .readiness.buildProcessingValid == true and
    .readiness.buildNotExpired == true and
    .readiness.appStoreEligible == true and
    .readiness.encryptionDeclarationResolved == true and
    .readiness.exportComplianceRequired == .build.exportComplianceRequired and
    .readiness.exportComplianceRequired == false and
    .readiness.buildUploadComplete == true and
    .readiness.buildUploadErrorFree == (.buildUpload.errors | length == 0) and
    .readiness.buildUploadErrorFree == true and
    .readiness.warningsPresent == (.buildUpload.warnings | length > 0) and
    .readiness.warningsPresent == $warningsPresent and
    .readiness.snapshotReady == true
  ' "$asc_path" >/dev/null 2>&1 \
    || fail "$platform App Store Connect snapshot content is inconsistent"

  # Confirm the original sealed records still match after every semantic read.
  revalidate_evidence_file "App Store submission manifest" \
    "$manifest_source_path" "$manifest_sha256" no-write
  revalidate_evidence_file "public-pages evidence" \
    "$public_source_path" "$public_sha256" exact-0444
  revalidate_evidence_file "$platform App Store Connect build snapshot" \
    "$asc_source_path" "$asc_sha256" exact-0444
}

(( $# == 2 )) || { usage; exit 64; }
CHANNEL="$1"
REPORT_SOURCE_PATH="$2"

[[ "$REPORT_SOURCE_PATH" == /* && -f "$REPORT_SOURCE_PATH" && \
  ! -L "$REPORT_SOURCE_PATH" ]] \
  || fail "readiness report must be an absolute, regular, non-symlink file"
[[ "${REPORT_SOURCE_PATH:a}" == "$REPORT_SOURCE_PATH" && \
  "${REPORT_SOURCE_PATH:A}" == "$REPORT_SOURCE_PATH" ]] \
  || fail "readiness report path is not canonical or traverses a symlink"
REPORT_SOURCE_INODE="$(/usr/bin/stat -f '%d:%i' \
  "$REPORT_SOURCE_PATH" 2>/dev/null || true)"
REPORT_SOURCE_MODE="$(/usr/bin/stat -f '%Lp' \
  "$REPORT_SOURCE_PATH" 2>/dev/null || true)"
[[ "$REPORT_SOURCE_INODE" == <->:<-> && "$REPORT_SOURCE_MODE" == <-> ]] \
  || fail "could not identify readiness report"
REPORT_SOURCE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$REPORT_SOURCE_PATH" | /usr/bin/awk '{print $1}')"
umask 077
REPORT_SNAPSHOT_DIR="$(mktemp -d /private/tmp/agentisland-preflight.XXXXXX)" \
  || fail "could not create a private readiness snapshot directory"
cleanup_preflight_snapshot() {
  local snapshot_dir="${REPORT_SNAPSHOT_DIR:-}"
  if [[ -n "$snapshot_dir" && -d "$snapshot_dir" && \
      "$snapshot_dir" == /private/tmp/agentisland-preflight.* ]]; then
    /bin/rm -rf "$snapshot_dir"
  fi
}
trap cleanup_preflight_snapshot EXIT HUP INT TERM
REPORT_PATH="$REPORT_SNAPSHOT_DIR/readiness.json"
freeze_file_no_follow "$REPORT_SOURCE_PATH" "$REPORT_PATH"
REPORT_SNAPSHOT_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$REPORT_PATH" | /usr/bin/awk '{print $1}')"
EVIDENCE_SNAPSHOT_INDEX=0
REVALIDATED_EVIDENCE_SNAPSHOT=""
[[ "$REPORT_SNAPSHOT_SHA256" == "$REPORT_SOURCE_SHA256" ]] \
  || fail "readiness report changed while it was being frozen"
verify_report_source_unchanged
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
      .appStoreSubmissionManifestConfigured == true and
      .appStoreSubmissionManifestReady == true and
      .macAppStoreSubmissionManifestReady == true and
      (.appStoreSubmissionManifestPath | type == "string" and startswith("/") and length > 1) and
      (.appStoreSubmissionManifestSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.macAppStoreExpectedAppResourceID | type == "string" and test("^[0-9]{8,20}$")) and
      (.macAppStoreExpectedSKU | type == "string" and length >= 2 and length <= 64) and
      (.macAppStoreExpectedPrimaryLocale | type == "string" and length > 0 and length <= 35) and
      .publicPagesEvidenceConfigured == true and
      .publicPagesEvidenceReady == true and
      .publicPagesEvidenceBoundToSubmissionManifest == true and
      (.publicPagesEvidencePath | type == "string" and startswith("/") and length > 1) and
      (.publicPagesEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .publicPagesEvidenceBindingType == "submission-manifest" and
      .publicPagesEvidenceBindingPath == .appStoreSubmissionManifestPath and
      .publicPagesEvidenceBindingSHA256 == .appStoreSubmissionManifestSHA256 and
      (.publicPagesEvidenceOldestCheckedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.publicPagesEvidenceNewestCheckedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      .publicPagesEvidenceMaxAgeSeconds == 86400 and
      .appStoreConnectSnapshotMaxAgeValid == true and
      (.appStoreConnectSnapshotMaxAgeSeconds | type == "number" and
        isfinite and floor == . and . >= 1 and . <= 900) and
      .macAppStoreConnectBuildSnapshotConfigured == true and
      .macAppStoreConnectBuildSnapshotReady == true and
      (.macAppStoreConnectBuildSnapshotPath | type == "string" and startswith("/") and length > 1) and
      (.macAppStoreConnectBuildSnapshotSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.macAppStoreConnectEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.macAppStoreConnectBuildSnapshotCapturedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.macAppStoreConnectBuildSnapshotExpiresAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.macAppStoreConnectBuildSnapshotAppResourceID | type == "string" and length > 0) and
      (.macAppStoreConnectBuildSnapshotBuildResourceID | type == "string" and length > 0) and
      (.macAppStoreConnectBuildSnapshotWarningsPresent | type == "boolean") and
      .macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity == true and
      .macAppStoreConnectBuildSnapshotMatchesOperatorEvidence == true and
      .macAppStoreConnectBuildSnapshotWarningReviewCurrent == true and
      .macAppStoreConnectRemoteMetadataComparisonComplete == true and
      .macAppStoreConnectBuildSnapshotExportComplianceRequired == false and
      .macAppStoreConnectBuildSnapshotBuildUploadErrorFree == true and
      .macAppStoreConnectBuildSnapshotAppResourceID == .macAppStoreExpectedAppResourceID and
      .macAppStoreConnectBuildSnapshotBuildResourceID == .macAppStoreConnectBuildID and
      .macAppStoreConnectBuildSnapshotCapturedAt < .macAppStoreConnectBuildSnapshotExpiresAt and
      (.macAppStoreConnectBuildSnapshotWarningsPresent == false or
        .macAppStoreWarningsReviewedAt >= .macAppStoreConnectBuildSnapshotCapturedAt) and
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
      .appStoreSubmissionManifestConfigured == true and
      .appStoreSubmissionManifestReady == true and
      .iosAppStoreSubmissionManifestReady == true and
      (.appStoreSubmissionManifestPath | type == "string" and startswith("/") and length > 1) and
      (.appStoreSubmissionManifestSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.iosAppStoreExpectedAppResourceID | type == "string" and test("^[0-9]{8,20}$")) and
      (.iosAppStoreExpectedSKU | type == "string" and length >= 2 and length <= 64) and
      (.iosAppStoreExpectedPrimaryLocale | type == "string" and length > 0 and length <= 35) and
      .publicPagesEvidenceConfigured == true and
      .publicPagesEvidenceReady == true and
      .publicPagesEvidenceBoundToSubmissionManifest == true and
      (.publicPagesEvidencePath | type == "string" and startswith("/") and length > 1) and
      (.publicPagesEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .publicPagesEvidenceBindingType == "submission-manifest" and
      .publicPagesEvidenceBindingPath == .appStoreSubmissionManifestPath and
      .publicPagesEvidenceBindingSHA256 == .appStoreSubmissionManifestSHA256 and
      (.publicPagesEvidenceOldestCheckedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.publicPagesEvidenceNewestCheckedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      .publicPagesEvidenceMaxAgeSeconds == 86400 and
      .appStoreConnectSnapshotMaxAgeValid == true and
      (.appStoreConnectSnapshotMaxAgeSeconds | type == "number" and
        isfinite and floor == . and . >= 1 and . <= 900) and
      .iosAppStoreConnectBuildSnapshotConfigured == true and
      .iosAppStoreConnectBuildSnapshotReady == true and
      (.iosAppStoreConnectBuildSnapshotPath | type == "string" and startswith("/") and length > 1) and
      (.iosAppStoreConnectBuildSnapshotSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.iosAppStoreConnectEvidenceSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.iosAppStoreConnectBuildSnapshotCapturedAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.iosAppStoreConnectBuildSnapshotExpiresAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$")) and
      (.iosAppStoreConnectBuildSnapshotAppResourceID | type == "string" and length > 0) and
      (.iosAppStoreConnectBuildSnapshotBuildResourceID | type == "string" and length > 0) and
      (.iosAppStoreConnectBuildSnapshotWarningsPresent | type == "boolean") and
      .iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity == true and
      .iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence == true and
      .iosAppStoreConnectBuildSnapshotWarningReviewCurrent == true and
      .iosAppStoreConnectRemoteMetadataComparisonComplete == true and
      .iosAppStoreConnectBuildSnapshotExportComplianceRequired == false and
      .iosAppStoreConnectBuildSnapshotBuildUploadErrorFree == true and
      .iosAppStoreConnectBuildSnapshotAppResourceID == .iosAppStoreExpectedAppResourceID and
      .iosAppStoreConnectBuildSnapshotBuildResourceID == .iosTestFlightAppStoreConnectBuildID and
      .iosAppStoreConnectBuildSnapshotCapturedAt < .iosAppStoreConnectBuildSnapshotExpiresAt and
      (.iosAppStoreConnectBuildSnapshotWarningsPresent == false or
        .iosTestFlightWarningsReviewedAt >= .iosAppStoreConnectBuildSnapshotCapturedAt) and
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
  case "$CHANNEL" in
    mac-app-store-review)
      revalidate_final_review_evidence macos
      ;;
    ios-app-store-review)
      revalidate_final_review_evidence ios
      ;;
  esac
  verify_report_source_unchanged
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
  appStoreSubmissionManifestConfigured,
  appStoreSubmissionManifestReady,
  macAppStoreSubmissionManifestReady,
  iosAppStoreSubmissionManifestReady,
  appStoreSubmissionManifestPath,
  appStoreSubmissionManifestSHA256,
  macAppStoreExpectedAppResourceID,
  macAppStoreExpectedSKU,
  macAppStoreExpectedPrimaryLocale,
  iosAppStoreExpectedAppResourceID,
  iosAppStoreExpectedSKU,
  iosAppStoreExpectedPrimaryLocale,
  publicPagesEvidenceConfigured,
  publicPagesEvidenceReady,
  publicPagesEvidenceBoundToSubmissionManifest,
  publicPagesEvidencePath,
  publicPagesEvidenceSHA256,
  publicPagesEvidenceBindingType,
  publicPagesEvidenceBindingPath,
  publicPagesEvidenceBindingSHA256,
  publicPagesEvidenceOldestCheckedAt,
  publicPagesEvidenceNewestCheckedAt,
  publicPagesEvidenceMaxAgeSeconds,
  appStoreConnectSnapshotMaxAgeValid,
  appStoreConnectSnapshotMaxAgeSeconds,
  macAppStoreConnectBuildSnapshotConfigured,
  macAppStoreConnectBuildSnapshotReady,
  macAppStoreConnectBuildSnapshotPath,
  macAppStoreConnectBuildSnapshotSHA256,
  macAppStoreConnectEvidenceSHA256,
  macAppStoreConnectBuildSnapshotCapturedAt,
  macAppStoreConnectBuildSnapshotExpiresAt,
  macAppStoreConnectBuildSnapshotAppResourceID,
  macAppStoreConnectBuildSnapshotBuildResourceID,
  macAppStoreConnectBuildSnapshotWarningsPresent,
  macAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity,
  macAppStoreConnectBuildSnapshotMatchesOperatorEvidence,
  macAppStoreConnectBuildSnapshotWarningReviewCurrent,
  macAppStoreConnectRemoteMetadataComparisonComplete,
  macAppStoreConnectBuildSnapshotExportComplianceRequired,
  macAppStoreConnectBuildSnapshotBuildUploadErrorFree,
  iosAppStoreConnectBuildSnapshotConfigured,
  iosAppStoreConnectBuildSnapshotReady,
  iosAppStoreConnectBuildSnapshotPath,
  iosAppStoreConnectBuildSnapshotSHA256,
  iosAppStoreConnectEvidenceSHA256,
  iosAppStoreConnectBuildSnapshotCapturedAt,
  iosAppStoreConnectBuildSnapshotExpiresAt,
  iosAppStoreConnectBuildSnapshotAppResourceID,
  iosAppStoreConnectBuildSnapshotBuildResourceID,
  iosAppStoreConnectBuildSnapshotWarningsPresent,
  iosAppStoreConnectBuildSnapshotMatchesSubmissionAppIdentity,
  iosAppStoreConnectBuildSnapshotMatchesOperatorEvidence,
  iosAppStoreConnectBuildSnapshotWarningReviewCurrent,
  iosAppStoreConnectRemoteMetadataComparisonComplete,
  iosAppStoreConnectBuildSnapshotExportComplianceRequired,
  iosAppStoreConnectBuildSnapshotBuildUploadErrorFree,
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
