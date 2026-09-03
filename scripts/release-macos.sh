#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

PROJECT_DIR="${0:A:h:h}"
DIST_DIR="$PROJECT_DIR/dist"
PUBLIC_APP_NAME="MAC版灵动岛--Agent运行监测"
SOURCE_ARCHIVE="$DIST_DIR/$PUBLIC_APP_NAME-macOS-universal.zip"
FINAL_ARCHIVE="$DIST_DIR/$PUBLIC_APP_NAME-macOS-notarized.zip"
FINAL_CHECKSUM="$FINAL_ARCHIVE.sha256"
METADATA_DIR="$DIST_DIR/release-metadata"
SIGN_IDENTITY="${AGENT_ISLAND_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE:-}"
BUNDLE_ID="${AGENT_ISLAND_BUNDLE_ID:-}"
TEAM_ID="${AGENT_ISLAND_DEVELOPMENT_TEAM:-}"
RELEASE_VERSION="${AGENT_ISLAND_VERSION:-}"
RELEASE_BUILD="${AGENT_ISLAND_BUILD_NUMBER:-}"
DISPLAY_NAME="${AGENT_ISLAND_DISPLAY_NAME:-}"
ENTITLEMENTS_PATH="${AGENT_ISLAND_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${AGENT_ISLAND_PROVISIONING_PROFILE:-}"
CLOUDKIT_CONTAINER_ID="${AGENT_ISLAND_ICLOUD_CONTAINER_ID:-}"
PRIVACY_POLICY_URL="${AGENT_ISLAND_PRIVACY_POLICY_URL:-}"
SUPPORT_URL="${AGENT_ISLAND_SUPPORT_URL:-}"
RELEASE_ROOT="$(mktemp -d /private/tmp/agentisland-release.XXXXXX)"
EXTRACT_ROOT="$RELEASE_ROOT/extracted"
CANONICAL_APP="$EXTRACT_ROOT/$PUBLIC_APP_NAME.app"
FINAL_VERIFY_ROOT="$RELEASE_ROOT/final-verify"
FINAL_VERIFY_APP="$FINAL_VERIFY_ROOT/$PUBLIC_APP_NAME.app"
NOTARY_RESULT="$RELEASE_ROOT/notary-result.json"
NOTARY_LOG="$RELEASE_ROOT/notary-log.json"
PROFILE_CERTIFICATES_ROOT="$RELEASE_ROOT/profile-certificates"
PUBLISH_ROOT=""
BACKUP_ROOT=""
PENDING_ARCHIVE=""
PENDING_CHECKSUM=""
PENDING_METADATA_DIR=""
PENDING_MANIFEST=""
METADATA_STEM="AgentIsland-${RELEASE_VERSION}-${RELEASE_BUILD}"
COMMIT_STARTED=0
COMMIT_DONE=0
typeset -a PUBLISH_TARGETS PUBLISH_SOURCES BACKUP_PATHS HAD_OLD_TARGETS
PUBLISH_TARGETS=()
PUBLISH_SOURCES=()
BACKUP_PATHS=()
HAD_OLD_TARGETS=()

remove_publication_target() {
  local target="$1"
  case "$target" in
    "$FINAL_ARCHIVE"|"$FINAL_CHECKSUM")
      /bin/rm -f "$target"
      ;;
    "$METADATA_DIR")
      /bin/rm -rf "$target"
      ;;
    *)
      echo "Refusing to remove unexpected publication target: $target" >&2
      return 1
      ;;
  esac
}

restore_published_outputs() {
  set +e
  local index target backup
  local restore_failed=0

  for (( index = ${#PUBLISH_TARGETS[@]}; index >= 1; index-- )); do
    target="${PUBLISH_TARGETS[$index]}"
    backup="${BACKUP_PATHS[$index]}"
    if [[ -e "$backup" || -L "$backup" ]]; then
      remove_publication_target "$target" || { restore_failed=1; continue; }
      /bin/mv "$backup" "$target" || restore_failed=1
    elif [[ "${HAD_OLD_TARGETS[$index]:-0}" == "0" ]]; then
      remove_publication_target "$target" || restore_failed=1
    fi
  done

  (( restore_failed == 0 ))
}

cleanup() {
  local exit_code=$?
  local rollback_failed=0
  trap - EXIT HUP INT TERM

  if (( COMMIT_STARTED && ! COMMIT_DONE )); then
    restore_published_outputs || rollback_failed=1
  fi

  if (( rollback_failed )); then
    echo "Publication rollback was incomplete; recovery data was preserved at:" >&2
    [[ -n "$BACKUP_ROOT" ]] && echo "  $BACKUP_ROOT" >&2
    [[ -n "$PUBLISH_ROOT" ]] && echo "  $PUBLISH_ROOT" >&2
    echo "  $RELEASE_ROOT" >&2
  else
    [[ "$RELEASE_ROOT" == /private/tmp/agentisland-release.* ]] && /bin/rm -rf "$RELEASE_ROOT"
    [[ -n "$PUBLISH_ROOT" && "$PUBLISH_ROOT" == "$DIST_DIR"/.agentisland-release-publish.* ]] && \
      /bin/rm -rf "$PUBLISH_ROOT"
    [[ -n "$BACKUP_ROOT" && "$BACKUP_ROOT" == "$DIST_DIR"/.agentisland-release-backup.* ]] && \
      /bin/rm -rf "$BACKUP_ROOT"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

production_https_url() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == https://* && "$value" != *[[:space:]]* && \
    "$normalized" != *localhost* && "$normalized" != *127.0.0.1* && \
    "$normalized" != *example* && "$normalized" != *placeholder* && \
    "$normalized" != *yourdomain* && "$normalized" != *.invalid/* && "$normalized" != *.test/* ]]
}

production_container_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == iCloud.* && "$value" != *[[:space:]]* && \
    "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *placeholder* ]]
}

production_bundle_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == [A-Za-z0-9.-]## && "$value" == *.* && "$value" != *..* && \
    "$value" != .* && "$value" != *. && "$normalized" != local.* && \
    "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *yourdomain* && "$normalized" != *placeholder* ]]
}

production_team_id() {
  [[ "$1" == [A-Z0-9]## && ${#1} -eq 10 && "${1:l}" != *placeholder* ]]
}

utf8_character_count() {
  printf '%s' "$1" | LC_ALL= LC_CTYPE=UTF-8 /usr/bin/wc -m | /usr/bin/tr -d '[:space:]'
}

production_display_name() {
  local value="$1"
  local comparison
  local character_count
  character_count="$(utf8_character_count "$value")"
  (( character_count >= 2 && character_count <= 30 )) || return 1
  [[ "$value" != [[:space:]]* && "$value" != *[[:space:]] && "$value" != *[[:cntrl:]]* ]] || return 1
  comparison="$(print -rn -- "$value" | /usr/bin/tr -cd '[:alnum:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$comparison" != "agentisland" && "$comparison" != "tasklume" ]]
}

[[ -n "$SIGN_IDENTITY" ]] || { echo "Set AGENT_ISLAND_DEVELOPER_ID_APPLICATION" >&2; exit 2; }
[[ -n "$NOTARY_PROFILE" ]] || { echo "Set AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE" >&2; exit 2; }
[[ -n "$BUNDLE_ID" ]] || { echo "Set AGENT_ISLAND_BUNDLE_ID" >&2; exit 2; }
[[ -n "$TEAM_ID" ]] || { echo "Set AGENT_ISLAND_DEVELOPMENT_TEAM" >&2; exit 2; }
[[ -n "$RELEASE_VERSION" ]] || { echo "Set AGENT_ISLAND_VERSION" >&2; exit 2; }
[[ -n "$RELEASE_BUILD" ]] || { echo "Set AGENT_ISLAND_BUILD_NUMBER" >&2; exit 2; }
[[ -n "$DISPLAY_NAME" ]] || { echo "Set AGENT_ISLAND_DISPLAY_NAME after clearing the final product name" >&2; exit 2; }
[[ -n "$ENTITLEMENTS_PATH" ]] || { echo "Set AGENT_ISLAND_ENTITLEMENTS for the production CloudKit release" >&2; exit 2; }
[[ -n "$PROVISIONING_PROFILE" ]] || { echo "Set AGENT_ISLAND_PROVISIONING_PROFILE for the production CloudKit release" >&2; exit 2; }
[[ -n "$CLOUDKIT_CONTAINER_ID" ]] || { echo "Set AGENT_ISLAND_ICLOUD_CONTAINER_ID for the production CloudKit release" >&2; exit 2; }
[[ -n "$PRIVACY_POLICY_URL" ]] || { echo "Set AGENT_ISLAND_PRIVACY_POLICY_URL" >&2; exit 2; }
[[ -n "$SUPPORT_URL" ]] || { echo "Set AGENT_ISLAND_SUPPORT_URL" >&2; exit 2; }
production_https_url "$PRIVACY_POLICY_URL" || { echo "AGENT_ISLAND_PRIVACY_POLICY_URL must be a production HTTPS URL" >&2; exit 2; }
production_https_url "$SUPPORT_URL" || { echo "AGENT_ISLAND_SUPPORT_URL must be a production HTTPS URL" >&2; exit 2; }
production_container_id "$CLOUDKIT_CONTAINER_ID" || { echo "AGENT_ISLAND_ICLOUD_CONTAINER_ID must be a production iCloud container identifier" >&2; exit 2; }
production_bundle_id "$BUNDLE_ID" || { echo "AGENT_ISLAND_BUNDLE_ID must be a production bundle identifier" >&2; exit 2; }
production_team_id "$TEAM_ID" || { echo "AGENT_ISLAND_DEVELOPMENT_TEAM must be the 10-character Apple Team ID" >&2; exit 2; }
production_display_name "$DISPLAY_NAME" || {
  echo "AGENT_ISLAND_DISPLAY_NAME must be a cleared 2-30 character name, with no surrounding/control whitespace, and must not equal Agent Island or TaskLume" >&2
  exit 2
}
[[ "$DISPLAY_NAME" == "$PUBLIC_APP_NAME" ]] || {
  echo "AGENT_ISLAND_DISPLAY_NAME must equal the public artifact name: $PUBLIC_APP_NAME" >&2
  exit 2
}
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || { echo "AGENT_ISLAND_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity" >&2; exit 2; }
[[ -f "$ENTITLEMENTS_PATH" ]] || { echo "AGENT_ISLAND_ENTITLEMENTS must name an existing file" >&2; exit 2; }
[[ -f "$PROVISIONING_PROFILE" ]] || { echo "AGENT_ISLAND_PROVISIONING_PROFILE must name an existing file" >&2; exit 2; }
/usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null
if /usr/bin/grep -Eqi 'yourname|yourdomain|example|placeholder' "$ENTITLEMENTS_PATH"; then
  echo "AGENT_ISLAND_ENTITLEMENTS contains placeholder values" >&2
  exit 2
fi
SOURCE_ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - "$ENTITLEMENTS_PATH")"
print -r -- "$SOURCE_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
  --arg container "$CLOUDKIT_CONTAINER_ID" --arg bundle "$BUNDLE_ID" --arg team "$TEAM_ID" '
  (."com.apple.application-identifier" | type == "string" and endswith("." + $bundle)) and
  (."com.apple.developer.team-identifier" == $team) and
  ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
  ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
  (."com.apple.developer.icloud-container-environment" == "Production") and
  ((."com.apple.security.get-task-allow" // false) == false)
' >/dev/null || { echo "AGENT_ISLAND_ENTITLEMENTS must contain the release App ID/team and authorize exactly AGENT_ISLAND_ICLOUD_CONTAINER_ID for production CloudKit" >&2; exit 2; }
SOURCE_APP_IDENTIFIER="$(print -r -- "$SOURCE_ENTITLEMENTS_JSON" | /usr/bin/jq -r '."com.apple.application-identifier"')"

PROFILE_PLIST="$RELEASE_ROOT/provisioning-profile.plist"
if ! /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST" >/dev/null 2>&1; then
  echo "AGENT_ISLAND_PROVISIONING_PROFILE is not a decodable signed provisioning profile" >&2
  exit 2
fi
/usr/bin/plutil -lint "$PROFILE_PLIST" >/dev/null
PROFILE_ENTITLEMENTS_PLIST="$RELEASE_ROOT/provisioning-profile-entitlements.plist"
PROFILE_ENTITLEMENTS_JSON="$RELEASE_ROOT/provisioning-profile-entitlements.json"
# A real profile contains Date and Data objects, so converting the whole plist
# to JSON fails. Isolate the JSON-compatible Entitlements dictionary first.
/usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST"
/usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON" "$PROFILE_ENTITLEMENTS_PLIST"
/usr/bin/jq -e \
  --arg container "$CLOUDKIT_CONTAINER_ID" --arg sourceAppIdentifier "$SOURCE_APP_IDENTIFIER" --arg team "$TEAM_ID" '
  ( ."com.apple.application-identifier" == $sourceAppIdentifier ) and
  ( ."com.apple.developer.team-identifier" == $team ) and
  ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
  ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
  (."com.apple.developer.icloud-container-environment" == "Production") and
  ((."com.apple.security.get-task-allow" // false) == false)
' "$PROFILE_ENTITLEMENTS_JSON" >/dev/null || {
  echo "Provisioning profile entitlements do not match the release App ID/team or exact production CloudKit container" >&2
  exit 2
}
PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
[[ "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TEAM" == "$TEAM_ID" && \
  "$PROFILE_PLATFORM_COUNT" == "1" && "$PROFILE_PLATFORM" == "OSX" && \
  "$PROFILE_CERTIFICATE_COUNT" == <-> && "$PROFILE_CERTIFICATE_COUNT" -gt 0 && \
  "$PROFILE_PROVISIONS_ALL_DEVICES" == "true" && "$PROFILE_EXPIRATION_EPOCH" == <-> && \
  "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]] || {
  echo "Provisioning profile must be an unexpired all-device OSX profile for the release Team with at least one signing certificate" >&2
  exit 2
}

[[ "$SIGN_IDENTITY" == *"($TEAM_ID)" ]] || { echo "Developer ID identity does not belong to AGENT_ISLAND_DEVELOPMENT_TEAM" >&2; exit 2; }
IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning)"
IDENTITY_MATCH_COUNT="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$SIGN_IDENTITY\"" || true)"
[[ "$IDENTITY_MATCH_COUNT" == "1" ]] || { echo "Expected exactly one matching Developer ID identity in the login keychain" >&2; exit 2; }
IDENTITY_SHA1="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -F "\"$SIGN_IDENTITY\"" | /usr/bin/awk '{print toupper($2); exit}')"
[[ "$IDENTITY_SHA1" == [0-9A-F]## && ${#IDENTITY_SHA1} -eq 40 ]] || {
  echo "Could not resolve the SHA-1 fingerprint for AGENT_ISLAND_DEVELOPER_ID_APPLICATION" >&2
  exit 2
}

# A Developer ID provisioning profile authorizes only the certificates listed
# in DeveloperCertificates. Matching only the team/name can produce an app that
# passes codesign yet loses its restricted CloudKit entitlement at launch.
/bin/mkdir -p "$PROFILE_CERTIFICATES_ROOT"
PROFILE_SIGNING_CERTIFICATE_MATCH=false
for (( PROFILE_CERTIFICATE_INDEX = 0; PROFILE_CERTIFICATE_INDEX < PROFILE_CERTIFICATE_COUNT; PROFILE_CERTIFICATE_INDEX++ )); do
  PROFILE_CERTIFICATE_PATH="$PROFILE_CERTIFICATES_ROOT/$PROFILE_CERTIFICATE_INDEX.cer"
  PROFILE_CERTIFICATE_BASE64="$(/usr/bin/plutil -extract "DeveloperCertificates.$PROFILE_CERTIFICATE_INDEX" raw -o - "$PROFILE_PLIST")"
  if ! print -rn -- "$PROFILE_CERTIFICATE_BASE64" | /usr/bin/base64 -D >"$PROFILE_CERTIFICATE_PATH"; then
    echo "Provisioning profile contains an invalid DeveloperCertificates entry" >&2
    exit 2
  fi
  PROFILE_CERTIFICATE_SHA1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$PROFILE_CERTIFICATE_PATH" | /usr/bin/awk '{print toupper($1)}')"
  if [[ "$PROFILE_CERTIFICATE_SHA1" == "$IDENTITY_SHA1" ]]; then
    PROFILE_SIGNING_CERTIFICATE_MATCH=true
    break
  fi
done
[[ "$PROFILE_SIGNING_CERTIFICATE_MATCH" == true ]] || {
  echo "Developer ID signing certificate is not authorized by AGENT_ISLAND_PROVISIONING_PROFILE" >&2
  exit 2
}

typeset -a AMBIGUOUS_SOURCE_ARCHIVES
AMBIGUOUS_SOURCE_ARCHIVES=()
for ARCHIVE_CANDIDATE in "$DIST_DIR"/*macOS-universal*.zip(N); do
  [[ "$ARCHIVE_CANDIDATE" == "$SOURCE_ARCHIVE" ]] || AMBIGUOUS_SOURCE_ARCHIVES+=("$ARCHIVE_CANDIDATE")
done
if (( ${#AMBIGUOUS_SOURCE_ARCHIVES[@]} > 0 )); then
  echo "Refusing release while non-canonical macOS universal archives exist:" >&2
  print -rl -- "${AMBIGUOUS_SOURCE_ARCHIVES[@]}" >&2
  echo "Move or explicitly archive the stale copies, then rerun the release" >&2
  exit 2
fi

export AGENT_ISLAND_CODESIGN_IDENTITY="$SIGN_IDENTITY"
export AGENT_ISLAND_BUNDLE_ID="$BUNDLE_ID"
export AGENT_ISLAND_VERSION="$RELEASE_VERSION"
export AGENT_ISLAND_BUILD_NUMBER="$RELEASE_BUILD"
export AGENT_ISLAND_DISPLAY_NAME="$DISPLAY_NAME"

"$PROJECT_DIR/scripts/build-app.sh" >/dev/null
/bin/mkdir -p "$EXTRACT_ROOT"
/usr/bin/ditto -x -k "$SOURCE_ARCHIVE" "$EXTRACT_ROOT"
[[ -d "$CANONICAL_APP" ]] || { echo "Release archive does not contain $PUBLIC_APP_NAME.app" >&2; exit 2; }
/usr/bin/xattr -cr "$CANONICAL_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$CANONICAL_APP"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$CANONICAL_APP" 2>&1)"
if ! print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -q 'flags=.*runtime'; then
  echo "Hardened Runtime is missing from the release signature" >&2
  exit 2
fi
print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -q '^Timestamp=' || {
  echo "Secure timestamp is missing from the release signature" >&2; exit 2;
}
print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -Fqx "TeamIdentifier=$TEAM_ID" || {
  echo "Signed app TeamIdentifier does not match AGENT_ISLAND_DEVELOPMENT_TEAM" >&2; exit 2;
}
print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -Fqx "Authority=$SIGN_IDENTITY" || {
  echo "Signed app authority does not match AGENT_ISLAND_DEVELOPER_ID_APPLICATION" >&2; exit 2;
}

SIGNED_ENTITLEMENTS="$RELEASE_ROOT/signed-entitlements.plist"
/usr/bin/codesign -d --entitlements - "$CANONICAL_APP" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
SIGNED_ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - "$SIGNED_ENTITLEMENTS")"
print -r -- "$SIGNED_ENTITLEMENTS_JSON" | /usr/bin/jq -e \
  --arg container "$CLOUDKIT_CONTAINER_ID" --arg appIdentifier "$SOURCE_APP_IDENTIFIER" --arg team "$TEAM_ID" '
  (."com.apple.application-identifier" == $appIdentifier) and
  (."com.apple.developer.team-identifier" == $team) and
  ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
  ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
  (."com.apple.developer.icloud-container-environment" == "Production") and
  ((."com.apple.security.get-task-allow" // false) == false)
' >/dev/null || { echo "Signed app does not contain the expected release App ID/team and production CloudKit entitlement" >&2; exit 2; }

ACTUAL_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$CANONICAL_APP/Contents/Info.plist")"
ACTUAL_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$CANONICAL_APP/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$CANONICAL_APP/Contents/Info.plist")"
ACTUAL_DISPLAY_NAME="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$CANONICAL_APP/Contents/Info.plist")"
[[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || { echo "Release bundle identifier mismatch" >&2; exit 2; }
[[ "$ACTUAL_VERSION" == "$RELEASE_VERSION" ]] || { echo "Release version mismatch" >&2; exit 2; }
[[ "$ACTUAL_BUILD" == "$RELEASE_BUILD" ]] || { echo "Release build number mismatch" >&2; exit 2; }
[[ "$ACTUAL_DISPLAY_NAME" == "$DISPLAY_NAME" ]] || { echo "Release display name mismatch" >&2; exit 2; }
[[ -f "$CANONICAL_APP/Contents/embedded.provisionprofile" ]] || {
  echo "Release app is missing embedded.provisionprofile" >&2; exit 2;
}
/usr/bin/cmp -s "$CANONICAL_APP/Contents/embedded.provisionprofile" "$PROVISIONING_PROFILE" || {
  echo "Release app does not embed the exact validated provisioning profile" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$CANONICAL_APP/Contents/Info.plist")" == "$PRIVACY_POLICY_URL" ]] || {
  echo "Release privacy policy URL mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$CANONICAL_APP/Contents/Info.plist")" == "$SUPPORT_URL" ]] || {
  echo "Release support URL mismatch" >&2; exit 2;
}

/usr/bin/xcrun notarytool submit "$SOURCE_ARCHIVE" \
  --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h --output-format json >"$NOTARY_RESULT"
[[ "$(/usr/bin/jq -r '.status // empty' "$NOTARY_RESULT")" == "Accepted" ]] || {
  /bin/cat "$NOTARY_RESULT" >&2
  exit 2
}
NOTARY_SUBMISSION_ID="$(/usr/bin/jq -r '.id // empty' "$NOTARY_RESULT")"
[[ "$NOTARY_SUBMISSION_ID" == [0-9A-Fa-f-]## && ${#NOTARY_SUBMISSION_ID} -eq 36 ]] || {
  echo "Notary service returned Accepted without a valid submission ID" >&2
  exit 2
}

# Apple recommends checking the detailed log even for an Accepted submission.
# Preserve it as release evidence and fail closed on any reported issue so an
# Accepted build with warnings cannot silently become the published artifact.
/usr/bin/xcrun notarytool log "$NOTARY_SUBMISSION_ID" \
  --keychain-profile "$NOTARY_PROFILE" "$NOTARY_LOG"
/usr/bin/jq -e --arg submissionID "$NOTARY_SUBMISSION_ID" '
  (.status == "Accepted") and
  (((.jobId // .id // "") | ascii_downcase) == ($submissionID | ascii_downcase)) and
  (((.issues // []) | type) == "array")
' "$NOTARY_LOG" >/dev/null || {
  echo "Detailed notarization log does not match the Accepted submission" >&2
  /bin/cat "$NOTARY_LOG" >&2
  exit 2
}
NOTARY_ISSUE_COUNT="$(/usr/bin/jq -r '(.issues // []) | length' "$NOTARY_LOG")"
(( NOTARY_ISSUE_COUNT == 0 )) || {
  echo "Detailed notarization log contains $NOTARY_ISSUE_COUNT issue(s); refusing to publish" >&2
  /bin/cat "$NOTARY_LOG" >&2
  exit 2
}

/usr/bin/xcrun stapler staple "$CANONICAL_APP"
/usr/bin/xcrun stapler validate "$CANONICAL_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$CANONICAL_APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$CANONICAL_APP"

# Stage every public release output on the destination filesystem. The final
# commit can then use same-volume renames and restore the complete previous set
# if any rename, verification, or handled signal fails.
/bin/mkdir -p "$DIST_DIR"
PUBLISH_ROOT="$(mktemp -d "$DIST_DIR/.agentisland-release-publish.XXXXXX")"
PENDING_ARCHIVE="$PUBLISH_ROOT/${FINAL_ARCHIVE:t}"
PENDING_CHECKSUM="$PUBLISH_ROOT/${FINAL_CHECKSUM:t}"
PENDING_METADATA_DIR="$PUBLISH_ROOT/release-metadata"
PENDING_MANIFEST="$PENDING_METADATA_DIR/$METADATA_STEM-build.json"
PENDING_METADATA_NOTARY="$PENDING_METADATA_DIR/$METADATA_STEM-notary.json"
PENDING_METADATA_NOTARY_LOG="$PENDING_METADATA_DIR/$METADATA_STEM-notary-log.json"
PENDING_METADATA_CHECKSUM="$PENDING_METADATA_DIR/$METADATA_STEM.sha256"
if [[ -L "$METADATA_DIR" || ( -e "$METADATA_DIR" && ! -d "$METADATA_DIR" ) ]]; then
  echo "Refusing release because $METADATA_DIR is not a regular directory" >&2
  exit 2
fi
if [[ -d "$METADATA_DIR" ]]; then
  /usr/bin/ditto --noextattr --norsrc "$METADATA_DIR" "$PENDING_METADATA_DIR"
else
  /bin/mkdir -p "$PENDING_METADATA_DIR"
fi
# Do not overwrite a copied symlink or hard link from an older metadata set.
# Recreate this release's four records as new regular files inside staging.
for PENDING_METADATA_TARGET in \
    "$PENDING_MANIFEST" "$PENDING_METADATA_NOTARY" \
    "$PENDING_METADATA_NOTARY_LOG" "$PENDING_METADATA_CHECKSUM"; do
  if [[ -d "$PENDING_METADATA_TARGET" && ! -L "$PENDING_METADATA_TARGET" ]]; then
    echo "Refusing to replace invalid staged metadata target: $PENDING_METADATA_TARGET" >&2
    exit 2
  fi
  /bin/rm -f "$PENDING_METADATA_TARGET"
done

/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$CANONICAL_APP" "$PENDING_ARCHIVE"

# Verify the exact ZIP that will be delivered, not only the app immediately
# before compression. This catches packaging-time metadata, ticket, signature,
# entitlement, Info.plist, or architecture drift before publication.
/bin/mkdir -p "$FINAL_VERIFY_ROOT"
/usr/bin/ditto -x -k "$PENDING_ARCHIVE" "$FINAL_VERIFY_ROOT"
[[ -d "$FINAL_VERIFY_APP" ]] || { echo "Final release archive does not contain $PUBLIC_APP_NAME.app" >&2; exit 2; }
/usr/bin/xcrun stapler validate "$FINAL_VERIFY_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$FINAL_VERIFY_APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$FINAL_VERIFY_APP"
FINAL_SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$FINAL_VERIFY_APP" 2>&1)"
print -r -- "$FINAL_SIGNATURE_DETAILS" | /usr/bin/grep -q 'flags=.*runtime' || {
  echo "Final archive lost Hardened Runtime" >&2; exit 2;
}
print -r -- "$FINAL_SIGNATURE_DETAILS" | /usr/bin/grep -q '^Timestamp=' || {
  echo "Final archive lost its secure timestamp" >&2; exit 2;
}
print -r -- "$FINAL_SIGNATURE_DETAILS" | /usr/bin/grep -Fqx "TeamIdentifier=$TEAM_ID" || {
  echo "Final archive TeamIdentifier mismatch" >&2; exit 2;
}
print -r -- "$FINAL_SIGNATURE_DETAILS" | /usr/bin/grep -Fqx "Authority=$SIGN_IDENTITY" || {
  echo "Final archive signing authority mismatch" >&2; exit 2;
}

FINAL_SIGNED_ENTITLEMENTS="$RELEASE_ROOT/final-signed-entitlements.plist"
/usr/bin/codesign -d --entitlements - "$FINAL_VERIFY_APP" >"$FINAL_SIGNED_ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -lint "$FINAL_SIGNED_ENTITLEMENTS" >/dev/null
/usr/bin/plutil -convert json -o - "$FINAL_SIGNED_ENTITLEMENTS" | /usr/bin/jq -e \
  --arg container "$CLOUDKIT_CONTAINER_ID" --arg appIdentifier "$SOURCE_APP_IDENTIFIER" --arg team "$TEAM_ID" '
  (."com.apple.application-identifier" == $appIdentifier) and
  (."com.apple.developer.team-identifier" == $team) and
  ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
  ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
  (."com.apple.developer.icloud-container-environment" == "Production") and
  ((."com.apple.security.get-task-allow" // false) == false)
' >/dev/null || { echo "Final archive release entitlements mismatch" >&2; exit 2; }

[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$ACTUAL_BUNDLE_ID" ]] || {
  echo "Final archive bundle identifier mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$ACTUAL_VERSION" ]] || {
  echo "Final archive version mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$ACTUAL_BUILD" ]] || {
  echo "Final archive build number mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$ACTUAL_DISPLAY_NAME" ]] || {
  echo "Final archive display name mismatch" >&2; exit 2;
}
[[ -f "$FINAL_VERIFY_APP/Contents/embedded.provisionprofile" ]] || {
  echo "Final archive is missing embedded.provisionprofile" >&2; exit 2;
}
/usr/bin/cmp -s "$FINAL_VERIFY_APP/Contents/embedded.provisionprofile" "$PROVISIONING_PROFILE" || {
  echo "Final archive provisioning profile mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$PRIVACY_POLICY_URL" ]] || {
  echo "Final archive privacy policy URL mismatch" >&2; exit 2;
}
[[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$FINAL_VERIFY_APP/Contents/Info.plist")" == "$SUPPORT_URL" ]] || {
  echo "Final archive support URL mismatch" >&2; exit 2;
}

ARCHITECTURES="$(/usr/bin/lipo -archs "$FINAL_VERIFY_APP/Contents/MacOS/AgentIsland")"
ARCHITECTURE_SET="$(print -r -- "$ARCHITECTURES" | /usr/bin/tr ' ' '\n' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
[[ "$ARCHITECTURE_SET" == "arm64 x86_64" ]] || {
  echo "Final release must contain exactly arm64 and x86_64 architectures" >&2; exit 2;
}
ARCHITECTURES="$ARCHITECTURE_SET"

ARCHIVE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PENDING_ARCHIVE" | /usr/bin/awk '{print $1}')"
ARCHIVE_NAME="${FINAL_ARCHIVE:t}"
print -r -- "$ARCHIVE_SHA256  $ARCHIVE_NAME" >"$PENDING_CHECKSUM"

NOTARY_LOG_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$NOTARY_LOG" | /usr/bin/awk '{print $1}')"
PROVISIONING_PROFILE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PROVISIONING_PROFILE" | /usr/bin/awk '{print $1}')"
PROVISIONING_PROFILE_UUID="$(/usr/bin/plutil -extract UUID raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
PROVISIONING_PROFILE_EXPIRATION="$PROFILE_EXPIRATION"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n \
  --arg product "$ACTUAL_DISPLAY_NAME" \
  --arg bundleID "$ACTUAL_BUNDLE_ID" \
  --arg version "$ACTUAL_VERSION" \
  --arg build "$ACTUAL_BUILD" \
  --arg archive "$ARCHIVE_NAME" \
  --arg sha256 "$ARCHIVE_SHA256" \
  --arg architectures "$ARCHITECTURES" \
  --arg sdkVersion "$SDK_VERSION" \
  --arg developerPath "$(/usr/bin/xcode-select -p)" \
  --arg signingIdentity "$SIGN_IDENTITY" \
  --arg teamID "$TEAM_ID" \
  --arg applicationIdentifier "$SOURCE_APP_IDENTIFIER" \
  --arg cloudKitContainer "$CLOUDKIT_CONTAINER_ID" \
  --arg notarySubmissionID "$NOTARY_SUBMISSION_ID" \
  --arg notaryLogSHA256 "$NOTARY_LOG_SHA256" \
  --argjson notaryIssueCount "$NOTARY_ISSUE_COUNT" \
  --arg provisioningProfileSHA256 "$PROVISIONING_PROFILE_SHA256" \
  --arg provisioningProfileUUID "$PROVISIONING_PROFILE_UUID" \
  --arg provisioningProfileExpiration "$PROVISIONING_PROFILE_EXPIRATION" \
  --arg signingCertificateSHA1 "$IDENTITY_SHA1" \
  --arg createdAt "$CREATED_AT" \
  '{
    product: $product,
    bundleID: $bundleID,
    version: $version,
    build: $build,
    archive: $archive,
    sha256: $sha256,
    architectures: ($architectures | split(" ")),
    macOSSDK: $sdkVersion,
    developerPath: $developerPath,
    signingIdentity: $signingIdentity,
    teamID: $teamID,
    applicationIdentifier: $applicationIdentifier,
    cloudKitContainer: $cloudKitContainer,
    hardenedRuntime: true,
    notarizationStatus: "Accepted",
    notarySubmissionID: $notarySubmissionID,
    notaryLogSHA256: $notaryLogSHA256,
    notaryIssueCount: $notaryIssueCount,
    provisioningProfileSHA256: $provisioningProfileSHA256,
    provisioningProfileUUID: $provisioningProfileUUID,
    provisioningProfileExpiration: $provisioningProfileExpiration,
    signingCertificateSHA1: $signingCertificateSHA1,
    createdAt: $createdAt
  }' >"$PENDING_MANIFEST"

/bin/cp "$NOTARY_RESULT" "$PENDING_METADATA_NOTARY"
/bin/cp "$NOTARY_LOG" "$PENDING_METADATA_NOTARY_LOG"
/bin/cp "$PENDING_CHECKSUM" "$PENDING_METADATA_CHECKSUM"

# Validate the complete staged publication set before moving any current public
# file aside. Metadata is committed as one directory so earlier release records
# remain consistent with the final ZIP and checksum.
/usr/bin/cmp -s "$NOTARY_RESULT" "$PENDING_METADATA_NOTARY" || {
  echo "Staged notarization result metadata mismatch" >&2; exit 2;
}
/usr/bin/cmp -s "$NOTARY_LOG" "$PENDING_METADATA_NOTARY_LOG" || {
  echo "Staged notarization log metadata mismatch" >&2; exit 2;
}
/usr/bin/cmp -s "$PENDING_CHECKSUM" "$PENDING_METADATA_CHECKSUM" || {
  echo "Staged checksum metadata mismatch" >&2; exit 2;
}
/usr/bin/jq -e --arg archive "$ARCHIVE_NAME" --arg sha256 "$ARCHIVE_SHA256" '
  .archive == $archive and .sha256 == $sha256 and
  .notarizationStatus == "Accepted" and .notaryIssueCount == 0
' "$PENDING_MANIFEST" >/dev/null || {
  echo "Staged build manifest does not describe the final archive" >&2; exit 2;
}

BACKUP_ROOT="$(mktemp -d "$DIST_DIR/.agentisland-release-backup.XXXXXX")"
PUBLISH_TARGETS=("$FINAL_ARCHIVE" "$FINAL_CHECKSUM" "$METADATA_DIR")
PUBLISH_SOURCES=("$PENDING_ARCHIVE" "$PENDING_CHECKSUM" "$PENDING_METADATA_DIR")
BACKUP_PATHS=(
  "$BACKUP_ROOT/final-archive"
  "$BACKUP_ROOT/final-checksum"
  "$BACKUP_ROOT/release-metadata"
)
for (( PUBLISH_INDEX = 1; PUBLISH_INDEX <= ${#PUBLISH_TARGETS[@]}; PUBLISH_INDEX++ )); do
  PUBLISH_TARGET="${PUBLISH_TARGETS[$PUBLISH_INDEX]}"
  if [[ -e "$PUBLISH_TARGET" || -L "$PUBLISH_TARGET" ]]; then
    if [[ "$PUBLISH_TARGET" == "$METADATA_DIR" ]]; then
      [[ -d "$PUBLISH_TARGET" && ! -L "$PUBLISH_TARGET" ]] || {
        echo "Refusing to replace invalid release metadata target: $PUBLISH_TARGET" >&2
        exit 2
      }
    else
      [[ -f "$PUBLISH_TARGET" || -L "$PUBLISH_TARGET" ]] || {
        echo "Refusing to replace invalid release artifact target: $PUBLISH_TARGET" >&2
        exit 2
      }
    fi
    HAD_OLD_TARGETS[$PUBLISH_INDEX]=1
  else
    HAD_OLD_TARGETS[$PUBLISH_INDEX]=0
  fi
done

COMMIT_STARTED=1
for (( PUBLISH_INDEX = 1; PUBLISH_INDEX <= ${#PUBLISH_TARGETS[@]}; PUBLISH_INDEX++ )); do
  if [[ "${HAD_OLD_TARGETS[$PUBLISH_INDEX]}" == "1" ]]; then
    /bin/mv "${PUBLISH_TARGETS[$PUBLISH_INDEX]}" "${BACKUP_PATHS[$PUBLISH_INDEX]}"
  fi
done
for (( PUBLISH_INDEX = 1; PUBLISH_INDEX <= ${#PUBLISH_TARGETS[@]}; PUBLISH_INDEX++ )); do
  /bin/mv "${PUBLISH_SOURCES[$PUBLISH_INDEX]}" "${PUBLISH_TARGETS[$PUBLISH_INDEX]}"
done

PUBLISHED_ARCHIVE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FINAL_ARCHIVE" | /usr/bin/awk '{print $1}')"
[[ "$PUBLISHED_ARCHIVE_SHA256" == "$ARCHIVE_SHA256" ]] || {
  echo "Published release archive checksum changed while committing to dist" >&2
  exit 2
}
/usr/bin/cmp -s "$FINAL_CHECKSUM" "$METADATA_DIR/$METADATA_STEM.sha256" || {
  echo "Published checksum and release metadata diverged while committing to dist" >&2
  exit 2
}
/usr/bin/cmp -s "$NOTARY_RESULT" "$METADATA_DIR/$METADATA_STEM-notary.json" || {
  echo "Published notarization result metadata changed while committing to dist" >&2
  exit 2
}
/usr/bin/cmp -s "$NOTARY_LOG" "$METADATA_DIR/$METADATA_STEM-notary-log.json" || {
  echo "Published notarization log metadata changed while committing to dist" >&2
  exit 2
}
/usr/bin/jq -e --arg archive "$ARCHIVE_NAME" --arg sha256 "$ARCHIVE_SHA256" '
  .archive == $archive and .sha256 == $sha256 and
  .notarizationStatus == "Accepted" and .notaryIssueCount == 0
' "$METADATA_DIR/$METADATA_STEM-build.json" >/dev/null || {
  echo "Published build metadata changed while committing to dist" >&2
  exit 2
}

[[ "$BACKUP_ROOT" == "$DIST_DIR"/.agentisland-release-backup.* ]] || {
  echo "Refusing to remove unexpected publication backup path: $BACKUP_ROOT" >&2
  exit 2
}
COMMIT_DONE=1
/bin/rm -rf "$BACKUP_ROOT"
BACKUP_ROOT=""

echo "$FINAL_ARCHIVE"
echo "$FINAL_CHECKSUM"
echo "$METADATA_DIR/$METADATA_STEM-build.json"
echo "$METADATA_DIR/$METADATA_STEM-notary-log.json"
