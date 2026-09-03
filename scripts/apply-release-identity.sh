#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

PROJECT_DIR="${0:A:h:h}"
DEFAULT_IDENTITY_FILE="$PROJECT_DIR/Config/ReleaseIdentity.json"
IDENTITY_FILE=""
PROFILE_PATH="${AGENT_ISLAND_PROVISIONING_PROFILE:-}"
MODE="check"
RELEASE_DIR="$PROJECT_DIR/.release"
LOCK_PATH="$RELEASE_DIR/identity.lock.json"
ENTITLEMENTS_PATH="$RELEASE_DIR/CloudKit.entitlements"
BACKUP_DIR="$RELEASE_DIR/identity-backup"
MAC_INFO_PATH="$PROJECT_DIR/Resources/Info.plist"
IOS_CONFIG_PATH="$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
MAC_CONFIG_PATH="$PROJECT_DIR/ApplePlatforms/macOS/Config/Project.xcconfig"
STAGING_DIR=""
BACKUP_STAGING_DIR=""
LEGACY_MAC_BACKUP_STAGE=""
WRITE_TRANSACTION_ACTIVE=false
MAC_INFO_REPLACED=false
IOS_CONFIG_REPLACED=false
MAC_CONFIG_REPLACED=false
ENTITLEMENTS_REPLACED=false
LOCK_REPLACED=false
ENTITLEMENTS_EXISTED_BEFORE=false
LOCK_EXISTED_BEFORE=false

fail() {
  print -u2 -- "release identity: $*"
  exit 2
}

sha256_file() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/apply-release-identity.sh [--check] [--profile FILE] [IDENTITY.json]
  ./scripts/apply-release-identity.sh --apply [--profile FILE] [IDENTITY.json]

The default mode is --check and never writes. --apply is the only mode that
writes project identity files. If IDENTITY.json is omitted, the script reads
Config/ReleaseIdentity.json.

A signed Developer ID provisioning profile is optional for the first identity
application. Without one, the script does not guess the App ID prefix and does
not create final macOS entitlements. Supply the registered profile later with
--profile to validate it and create .release/CloudKit.entitlements.

Schema v2 records the App Store record mode plus distinct macOS, iOS App, and
iOS Widget bundle identifiers. Legacy schema v1 remains accepted only as its
unambiguous original meaning: one shared Mac/iOS App identifier (Universal
Purchase). It is normalized to schema v2 before comparison or a new lock.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --profile)
      (( $# >= 2 )) || fail "--profile requires a file path"
      PROFILE_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$IDENTITY_FILE" ]] || fail "only one identity JSON file may be supplied"
      IDENTITY_FILE="$1"
      shift
      ;;
  esac
done

IDENTITY_FILE="${IDENTITY_FILE:-$DEFAULT_IDENTITY_FILE}"
[[ -f "$IDENTITY_FILE" && ! -L "$IDENTITY_FILE" ]] || fail "identity JSON must be an existing regular, non-symlink file: $IDENTITY_FILE"
[[ -f "$MAC_INFO_PATH" && ! -L "$MAC_INFO_PATH" ]] || fail "missing or unsafe Resources/Info.plist"
[[ -f "$IOS_CONFIG_PATH" && ! -L "$IOS_CONFIG_PATH" ]] || fail "missing or unsafe iOS Project.xcconfig"
[[ -f "$MAC_CONFIG_PATH" && ! -L "$MAC_CONFIG_PATH" ]] || fail "missing or unsafe macOS Project.xcconfig"
command -v /usr/bin/jq >/dev/null || fail "jq is required"
command -v /usr/bin/plutil >/dev/null || fail "plutil is required"

STAGING_DIR="$(mktemp -d /private/tmp/agentisland-identity.XXXXXX)"
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  if [[ "$WRITE_TRANSACTION_ACTIVE" == true && -n "$STAGING_DIR" ]]; then
    set +e
    if [[ "$LOCK_REPLACED" == true ]]; then
      if [[ "$LOCK_EXISTED_BEFORE" == true ]]; then
        /bin/cp -p "$STAGING_DIR/original-identity.lock.json" \
          "$RELEASE_DIR/.identity.lock.json.rollback"
        /bin/mv -f "$RELEASE_DIR/.identity.lock.json.rollback" "$LOCK_PATH"
      else
        /bin/rm -f "$LOCK_PATH"
      fi
    fi
    if [[ "$ENTITLEMENTS_REPLACED" == true ]]; then
      if [[ "$ENTITLEMENTS_EXISTED_BEFORE" == true ]]; then
        /bin/cp -p "$STAGING_DIR/original-CloudKit.entitlements" \
          "$RELEASE_DIR/.CloudKit.entitlements.rollback"
        /bin/mv -f "$RELEASE_DIR/.CloudKit.entitlements.rollback" "$ENTITLEMENTS_PATH"
      else
        /bin/rm -f "$ENTITLEMENTS_PATH"
      fi
    fi
    if [[ "$MAC_CONFIG_REPLACED" == true ]]; then
      /bin/cp -p "$STAGING_DIR/original-macOS-Project.xcconfig" \
        "$PROJECT_DIR/ApplePlatforms/macOS/Config/.Project.xcconfig.identity-rollback"
      /bin/mv -f "$PROJECT_DIR/ApplePlatforms/macOS/Config/.Project.xcconfig.identity-rollback" \
        "$MAC_CONFIG_PATH"
    fi
    if [[ "$IOS_CONFIG_REPLACED" == true ]]; then
      /bin/cp -p "$STAGING_DIR/original-iOS-Project.xcconfig" \
        "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-rollback"
      /bin/mv -f "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-rollback" \
        "$IOS_CONFIG_PATH"
    fi
    if [[ "$MAC_INFO_REPLACED" == true ]]; then
      /bin/cp -p "$STAGING_DIR/original-Info.plist" \
        "$PROJECT_DIR/Resources/.Info.plist.identity-rollback"
      /bin/mv -f "$PROJECT_DIR/Resources/.Info.plist.identity-rollback" "$MAC_INFO_PATH"
    fi
    /bin/rm -f \
      "$PROJECT_DIR/Resources/.Info.plist.identity-new" \
      "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-new" \
      "$PROJECT_DIR/ApplePlatforms/macOS/Config/.Project.xcconfig.identity-new" \
      "$RELEASE_DIR/.CloudKit.entitlements.identity-new" \
      "$RELEASE_DIR/.identity.lock.json.identity-new"
    print -u2 -- "release identity: apply failed; restored every identity file already replaced in this transaction"
    set -e
  fi
  if [[ -n "$BACKUP_STAGING_DIR" && "$BACKUP_STAGING_DIR" == \
    "$RELEASE_DIR"/.identity-backup.identity-new.* ]]; then
    /bin/rm -rf "$BACKUP_STAGING_DIR"
  fi
  if [[ -n "$LEGACY_MAC_BACKUP_STAGE" && "$LEGACY_MAC_BACKUP_STAGE" == \
    "$BACKUP_DIR"/.schema-v2-macos-config.identity-new.* ]]; then
    /bin/rm -rf "$LEGACY_MAC_BACKUP_STAGE"
  fi
  [[ -n "$STAGING_DIR" && "$STAGING_DIR" == /private/tmp/agentisland-identity.* ]] \
    && /bin/rm -rf "$STAGING_DIR"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/jq -e . "$IDENTITY_FILE" >/dev/null 2>&1 || fail "identity file is not valid JSON"

# Report secret-shaped input before the whitelist error so credentials are
# never normalized into, printed from, or persisted by this workflow.
SECRET_KEY_PATH="$(/usr/bin/jq -r '
  paths as $path
  | select(($path[-1] | type) == "string")
  | select(($path[-1] | test("password|passwd|secret|token|api.?key|private.?key|credential|apple.?id|notary|p12|certificate"; "i")))
  | ($path | map(tostring) | join("."))
' "$IDENTITY_FILE" | /usr/bin/head -n 1)"
[[ -z "$SECRET_KEY_PATH" ]] || fail "secret-bearing field is forbidden: $SECRET_KEY_PATH"

/usr/bin/jq -e '
  [.. | strings
    | select(test("-----BEGIN[[:space:]]+([A-Z0-9]+[[:space:]]+)*PRIVATE KEY-----|-----BEGIN CERTIFICATE-----|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"; "i"))]
  | length == 0
' "$IDENTITY_FILE" >/dev/null || fail "identity JSON contains secret or certificate material"

INPUT_SCHEMA_VERSION="$(/usr/bin/jq -r '.schemaVersion // empty' "$IDENTITY_FILE")"
LEGACY_SCHEMA_MIGRATED=false
case "$INPUT_SCHEMA_VERSION" in
  1)
    UNKNOWN_TOP_LEVEL="$(/usr/bin/jq -r '
      (keys - ["schemaVersion", "primaryBundleIdentifier", "widgetBundleIdentifier",
        "teamIdentifier", "iCloudContainerIdentifier", "cloudKit"]) | join(", ")
    ' "$IDENTITY_FILE")"
    [[ -z "$UNKNOWN_TOP_LEVEL" ]] || fail "unknown top-level field(s): $UNKNOWN_TOP_LEVEL"
    /usr/bin/jq -e '
      type == "object" and
      (.schemaVersion == 1) and
      (.primaryBundleIdentifier | type == "string") and
      (.widgetBundleIdentifier | type == "string") and
      (.teamIdentifier | type == "string") and
      (.iCloudContainerIdentifier | type == "string") and
      (.cloudKit | type == "object")
    ' "$IDENTITY_FILE" >/dev/null \
      || fail "schema v1 identity JSON is missing a required field; migrate it using Config/ReleaseIdentity.example.json"
    APP_STORE_RECORD_MODE="universal-purchase"
    MAC_BUNDLE_ID="$(/usr/bin/jq -r '.primaryBundleIdentifier' "$IDENTITY_FILE")"
    IOS_APP_BUNDLE_ID="$MAC_BUNDLE_ID"
    IOS_WIDGET_BUNDLE_ID="$(/usr/bin/jq -r '.widgetBundleIdentifier' "$IDENTITY_FILE")"
    LEGACY_SCHEMA_MIGRATED=true
    ;;
  2)
    UNKNOWN_TOP_LEVEL="$(/usr/bin/jq -r '
      (keys - ["schemaVersion", "appStoreRecordMode", "macOSAppBundleIdentifier",
        "iOSAppBundleIdentifier", "iOSWidgetBundleIdentifier", "teamIdentifier",
        "iCloudContainerIdentifier", "cloudKit"]) | join(", ")
    ' "$IDENTITY_FILE")"
    [[ -z "$UNKNOWN_TOP_LEVEL" ]] || fail "unknown top-level field(s): $UNKNOWN_TOP_LEVEL"
    /usr/bin/jq -e '
      type == "object" and
      (.schemaVersion == 2) and
      (.appStoreRecordMode | type == "string") and
      (.macOSAppBundleIdentifier | type == "string") and
      (.iOSAppBundleIdentifier | type == "string") and
      (.iOSWidgetBundleIdentifier | type == "string") and
      (.teamIdentifier | type == "string") and
      (.iCloudContainerIdentifier | type == "string") and
      (.cloudKit | type == "object")
    ' "$IDENTITY_FILE" >/dev/null \
      || fail "schema v2 identity JSON is missing a required field; start from Config/ReleaseIdentity.example.json"
    APP_STORE_RECORD_MODE="$(/usr/bin/jq -r '.appStoreRecordMode' "$IDENTITY_FILE")"
    MAC_BUNDLE_ID="$(/usr/bin/jq -r '.macOSAppBundleIdentifier' "$IDENTITY_FILE")"
    IOS_APP_BUNDLE_ID="$(/usr/bin/jq -r '.iOSAppBundleIdentifier' "$IDENTITY_FILE")"
    IOS_WIDGET_BUNDLE_ID="$(/usr/bin/jq -r '.iOSWidgetBundleIdentifier' "$IDENTITY_FILE")"
    ;;
  *)
    fail "unsupported schemaVersion; use schemaVersion 2 from Config/ReleaseIdentity.example.json (legacy schemaVersion 1 is accepted only for Universal Purchase)"
    ;;
esac

UNKNOWN_CLOUDKIT="$(/usr/bin/jq -r '
  (.cloudKit | keys) - ["databaseScope", "environment", "recordType", "recordName", "payloadField"]
  | join(", ")
' "$IDENTITY_FILE")"
[[ -z "$UNKNOWN_CLOUDKIT" ]] || fail "unknown cloudKit field(s): $UNKNOWN_CLOUDKIT"

TEAM_ID="$(/usr/bin/jq -r '.teamIdentifier' "$IDENTITY_FILE")"
CLOUDKIT_CONTAINER_ID="$(/usr/bin/jq -r '.iCloudContainerIdentifier' "$IDENTITY_FILE")"

production_bundle_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ ${#value} -le 255 && "$normalized" != local.* && "$normalized" != *example* && \
    "$normalized" != *yourname* && "$normalized" != *yourdomain* && \
    "$normalized" != *placeholder* && "$normalized" != *.invalid ]] || return 1
  print -r -- "$value" | /usr/bin/jq -R -e \
    'test("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")' \
    >/dev/null
}

production_container_id() {
  local value="$1"
  local suffix="${value#iCloud.}"
  local normalized="${value:l}"
  [[ "$value" == iCloud.* && "$suffix" != "$value" && ${#value} -le 255 ]] || return 1
  production_bundle_id "$suffix" || return 1
  [[ "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *yourdomain* && "$normalized" != *placeholder* ]]
}

[[ "$TEAM_ID" == [A-Z0-9]## && ${#TEAM_ID} -eq 10 ]] \
  || fail "teamIdentifier must be the 10-character uppercase Apple Team ID"
[[ "${TEAM_ID:l}" != *placeholder* && "$TEAM_ID" != "YOURTEAMID" ]] \
  || fail "teamIdentifier still contains a placeholder"
[[ "$APP_STORE_RECORD_MODE" == "universal-purchase" || \
  "$APP_STORE_RECORD_MODE" == "separate-records" ]] \
  || fail "appStoreRecordMode must be universal-purchase or separate-records"
production_bundle_id "$MAC_BUNDLE_ID" \
  || fail "macOSAppBundleIdentifier must be a production reverse-DNS bundle identifier"
production_bundle_id "$IOS_APP_BUNDLE_ID" \
  || fail "iOSAppBundleIdentifier must be a production reverse-DNS bundle identifier"
production_bundle_id "$IOS_WIDGET_BUNDLE_ID" \
  || fail "iOSWidgetBundleIdentifier must be a production reverse-DNS bundle identifier"
[[ "$IOS_WIDGET_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID.liveactivity" ]] \
  || fail "iOSWidgetBundleIdentifier must equal iOSAppBundleIdentifier + .liveactivity"
if [[ "$APP_STORE_RECORD_MODE" == "universal-purchase" ]]; then
  [[ "$MAC_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID" ]] \
    || fail "universal-purchase requires macOSAppBundleIdentifier and iOSAppBundleIdentifier to match"
else
  [[ "$MAC_BUNDLE_ID" != "$IOS_APP_BUNDLE_ID" ]] \
    || fail "separate-records requires macOSAppBundleIdentifier and iOSAppBundleIdentifier to differ"
fi
production_container_id "$CLOUDKIT_CONTAINER_ID" \
  || fail "iCloudContainerIdentifier must be a production iCloud container identifier"

# This is a cross-platform wire contract, not user-configurable product text.
# Rejecting any drift prevents the producer and receiver from silently using
# different databases, records, fields, or deployment environments.
/usr/bin/jq -e '
  .cloudKit == {
    databaseScope: "private",
    environment: "Production",
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON"
  }
' "$IDENTITY_FILE" >/dev/null || fail "cloudKit must exactly match the private Production AgentIslandSnapshot/latest/payloadJSON contract"

CANONICAL_IDENTITY="$STAGING_DIR/identity.json"
/usr/bin/jq -n -S \
  --arg recordMode "$APP_STORE_RECORD_MODE" \
  --arg macBundle "$MAC_BUNDLE_ID" \
  --arg iosBundle "$IOS_APP_BUNDLE_ID" \
  --arg widgetBundle "$IOS_WIDGET_BUNDLE_ID" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUDKIT_CONTAINER_ID" \
  --argjson cloudKit "$(/usr/bin/jq -c '.cloudKit' "$IDENTITY_FILE")" '{
    schemaVersion: 2,
    appStoreRecordMode: $recordMode,
    macOSAppBundleIdentifier: $macBundle,
    iOSAppBundleIdentifier: $iosBundle,
    iOSWidgetBundleIdentifier: $widgetBundle,
    teamIdentifier: $team,
    iCloudContainerIdentifier: $container,
    cloudKit: $cloudKit
  }' > "$CANONICAL_IDENTITY"

if [[ -e "$RELEASE_DIR" ]]; then
  [[ -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] \
    || fail ".release must be a real directory, not a symlink or other file type"
fi

LEGACY_MAC_BACKUP_REQUIRED=false
if [[ -e "$BACKUP_DIR" ]]; then
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" && \
    -f "$BACKUP_DIR/manifest.json" && ! -L "$BACKUP_DIR/manifest.json" && \
    -f "$BACKUP_DIR/Resources/Info.plist" && ! -L "$BACKUP_DIR/Resources/Info.plist" && \
    -f "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" && \
    ! -L "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" ]] \
    || fail "existing identity backup is incomplete or unsafe; refusing to use it"
  if [[ ! -f "$BACKUP_DIR/ApplePlatforms/macOS/Config/Project.xcconfig" && \
    ! -f "$BACKUP_DIR/schema-v2-macos-config/ApplePlatforms/macOS/Config/Project.xcconfig" ]]; then
    LEGACY_MAC_BACKUP_REQUIRED=true
  elif [[ -L "$BACKUP_DIR/ApplePlatforms/macOS/Config/Project.xcconfig" || \
    -L "$BACKUP_DIR/schema-v2-macos-config/ApplePlatforms/macOS/Config/Project.xcconfig" ]]; then
    fail "macOS config identity backup must not be a symlink"
  fi
fi
if [[ -e "$LOCK_PATH" ]]; then
  [[ -f "$LOCK_PATH" && ! -L "$LOCK_PATH" ]] || fail "identity lock is not a regular, non-symlink file"
  /usr/bin/jq -e '
    .schemaVersion == 1 and
    (.firstAppliedAt | type == "string" and length > 0) and
    (.identity | type == "object") and
    (((.provisioningProfile == null) and (.generatedEntitlements == null)) or
      ((.provisioningProfile | type == "object") and
       (.generatedEntitlements | type == "object") and
       (.provisioningProfile.sha256 | type == "string" and length == 64) and
       (.provisioningProfile.applicationIdentifier | type == "string" and length > 0) and
       (.generatedEntitlements.path == ".release/CloudKit.entitlements") and
       (.generatedEntitlements.sha256 | type == "string" and length == 64))) and
    (.appliedFiles | type == "array")
  ' "$LOCK_PATH" >/dev/null 2>&1 \
    || fail "existing identity lock is invalid"
  [[ -d "$BACKUP_DIR" ]] \
    || fail "existing identity lock has no complete recoverable baseline backup"
  if [[ "$LEGACY_MAC_BACKUP_REQUIRED" == true ]]; then
    if /usr/bin/jq -e \
      '.appliedFiles | any(.path == "ApplePlatforms/macOS/Config/Project.xcconfig")' \
      "$LOCK_PATH" >/dev/null; then
      fail "identity lock claims the macOS Project.xcconfig but its recoverable backup is missing"
    fi
    LEGACY_MAC_BACKUP_REQUIRED=true
  fi
  LOCKED_IDENTITY="$STAGING_DIR/locked-identity.json"
  /usr/bin/jq -e -S '
    .identity |
    if .schemaVersion == 1 then
      if ((keys - ["schemaVersion", "primaryBundleIdentifier", "widgetBundleIdentifier",
          "teamIdentifier", "iCloudContainerIdentifier", "cloudKit"]) | length) != 0 or
         (.primaryBundleIdentifier | type) != "string" or
         (.widgetBundleIdentifier != (.primaryBundleIdentifier + ".liveactivity")) then
        error("unsafe legacy identity lock")
      else
        {
          schemaVersion: 2,
          appStoreRecordMode: "universal-purchase",
          macOSAppBundleIdentifier: .primaryBundleIdentifier,
          iOSAppBundleIdentifier: .primaryBundleIdentifier,
          iOSWidgetBundleIdentifier: .widgetBundleIdentifier,
          teamIdentifier,
          iCloudContainerIdentifier,
          cloudKit
        }
      end
    elif .schemaVersion == 2 then
      if ((keys - ["schemaVersion", "appStoreRecordMode", "macOSAppBundleIdentifier",
          "iOSAppBundleIdentifier", "iOSWidgetBundleIdentifier", "teamIdentifier",
          "iCloudContainerIdentifier", "cloudKit"]) | length) != 0 or
         (.appStoreRecordMode != "universal-purchase" and
          .appStoreRecordMode != "separate-records") or
         (.macOSAppBundleIdentifier | type) != "string" or
         (.iOSAppBundleIdentifier | type) != "string" or
         (.iOSWidgetBundleIdentifier != (.iOSAppBundleIdentifier + ".liveactivity")) or
         (.appStoreRecordMode == "universal-purchase" and
          .macOSAppBundleIdentifier != .iOSAppBundleIdentifier) or
         (.appStoreRecordMode == "separate-records" and
          .macOSAppBundleIdentifier == .iOSAppBundleIdentifier) then
        error("unsafe schema-v2 identity lock")
      else
        {
          schemaVersion,
          appStoreRecordMode,
          macOSAppBundleIdentifier,
          iOSAppBundleIdentifier,
          iOSWidgetBundleIdentifier,
          teamIdentifier,
          iCloudContainerIdentifier,
          cloudKit
        }
      end
    else
      error("unsupported identity schema in lock")
    end
  ' "$LOCK_PATH" > "$LOCKED_IDENTITY" 2>/dev/null \
    || fail "existing identity lock uses an unsupported or unsafe identity schema; restore the baseline backup and inspect the lock before retrying"
  /usr/bin/cmp -s "$CANONICAL_IDENTITY" "$LOCKED_IDENTITY" \
    || fail "identity differs from .release/identity.lock.json; restore the pre-apply backup before intentionally changing immutable identifiers"
fi
if [[ ! -e "$LOCK_PATH" && -e "$ENTITLEMENTS_PATH" ]]; then
  fail ".release/CloudKit.entitlements exists without an identity lock; move it aside and supply the signed profile before generating final entitlements"
fi

PROFILE_SUPPLIED=false
PROFILE_APP_IDENTIFIER=""
PROFILE_PREFIX=""
PROFILE_UUID=""
PROFILE_NAME=""
PROFILE_EXPIRATION=""
PROFILE_SHA256=""
GENERATED_ENTITLEMENTS="$STAGING_DIR/CloudKit.entitlements"

if [[ -n "$PROFILE_PATH" ]]; then
  PROFILE_SUPPLIED=true
  [[ -f "$PROFILE_PATH" && ! -L "$PROFILE_PATH" ]] \
    || fail "--profile must name an existing regular, non-symlink signed provisioning profile"
  PROFILE_PLIST="$STAGING_DIR/profile.plist"
  /usr/bin/security cms -D -i "$PROFILE_PATH" -o "$PROFILE_PLIST" >/dev/null 2>&1 \
    || fail "the provisioning profile is not a decodable Apple-signed CMS profile"
  /usr/bin/plutil -lint "$PROFILE_PLIST" >/dev/null
  PROFILE_ENTITLEMENTS_PLIST="$STAGING_DIR/profile-entitlements.plist"
  PROFILE_JSON="$STAGING_DIR/profile-entitlements.json"
  # Provisioning profiles contain Date and certificate Data values that cannot
  # be represented by plutil's JSON format. Extract the Entitlements subtree
  # first; read profile metadata directly from the decoded plist below.
  /usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST"
  /usr/bin/plutil -convert json -o "$PROFILE_JSON" "$PROFILE_ENTITLEMENTS_PLIST"
  /usr/bin/jq -e \
    --arg bundle "$MAC_BUNDLE_ID" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUDKIT_CONTAINER_ID" '
    ."com.apple.application-identifier" as $appIdentifier |
    (($appIdentifier | type) == "string") and
    ($appIdentifier | endswith("." + $bundle)) and
    (."com.apple.developer.team-identifier" == $team) and
    ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
    ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
    (."com.apple.developer.icloud-container-environment" == "Production") and
    ((."com.apple.security.get-task-allow" // false) == false)
  ' "$PROFILE_JSON" >/dev/null \
    || fail "profile entitlements must authorize the exact App ID, Team, and sole Production CloudKit container"

  PROFILE_APP_IDENTIFIER="$(/usr/bin/jq -r '."com.apple.application-identifier"' "$PROFILE_JSON")"
  PROFILE_APP_ID_PREFIX_COUNT="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_APP_ID_PREFIX="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
  [[ "$PROFILE_APP_ID_PREFIX_COUNT" == "1" && -n "$PROFILE_APP_ID_PREFIX" && \
    "$PROFILE_APP_IDENTIFIER" == "$PROFILE_APP_ID_PREFIX.$MAC_BUNDLE_ID" && \
    "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TEAM" == "$TEAM_ID" && \
    "$PROFILE_PLATFORM_COUNT" == "1" && "$PROFILE_PLATFORM" == "OSX" && \
    "$PROFILE_CERTIFICATE_COUNT" == <-> && "$PROFILE_CERTIFICATE_COUNT" -gt 0 && \
    "$PROFILE_PROVISIONS_ALL_DEVICES" == "true" && "$PROFILE_EXPIRATION_EPOCH" == <-> && \
    "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]] \
    || fail "profile must be an unexpired all-device OSX Developer ID profile whose authoritative App ID prefix and application-identifier exactly identify macOSAppBundleIdentifier for the release Team"
  PROFILE_PREFIX="$PROFILE_APP_ID_PREFIX"
  PROFILE_UUID="$(/usr/bin/plutil -extract UUID raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_NAME="$(/usr/bin/plutil -extract Name raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_SHA256="$(sha256_file "$PROFILE_PATH")"

  /usr/bin/jq -n \
    --arg appIdentifier "$PROFILE_APP_IDENTIFIER" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUDKIT_CONTAINER_ID" '{
      "com.apple.application-identifier": $appIdentifier,
      "com.apple.developer.team-identifier": $team,
      "com.apple.developer.icloud-container-identifiers": [$container],
      "com.apple.developer.icloud-container-environment": "Production",
      "com.apple.developer.icloud-services": ["CloudKit"]
    }' > "$STAGING_DIR/CloudKit.entitlements.json"
  /usr/bin/plutil -convert xml1 -o "$GENERATED_ENTITLEMENTS" "$STAGING_DIR/CloudKit.entitlements.json"
  /usr/bin/plutil -lint "$GENERATED_ENTITLEMENTS" >/dev/null
else
  if [[ -e "$LOCK_PATH" ]]; then
    LOCK_ENTITLEMENTS_SHA="$(/usr/bin/jq -r '.generatedEntitlements.sha256 // ""' "$LOCK_PATH")"
    if [[ -n "$LOCK_ENTITLEMENTS_SHA" ]]; then
      [[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] \
        || fail "locked generated entitlements are missing"
      CURRENT_ENTITLEMENTS_SHA="$(sha256_file "$ENTITLEMENTS_PATH")"
      [[ "$CURRENT_ENTITLEMENTS_SHA" == "$LOCK_ENTITLEMENTS_SHA" ]] \
        || fail "locked generated entitlements have changed; re-run with the signed profile"
    elif [[ -e "$ENTITLEMENTS_PATH" ]]; then
      fail "final entitlements exist but are not backed by a validated provisioning profile in the identity lock"
    fi
  fi
fi

MAC_CURRENT_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$MAC_INFO_PATH")"
XC_APP_COUNT="$(/usr/bin/grep -Ec '^[[:space:]]*AGENT_ISLAND_APP_BUNDLE_ID[[:space:]]*=' "$IOS_CONFIG_PATH")"
XC_WIDGET_COUNT="$(/usr/bin/grep -Ec '^[[:space:]]*AGENT_ISLAND_WIDGET_BUNDLE_ID[[:space:]]*=' "$IOS_CONFIG_PATH")"
XC_CONTAINER_COUNT="$(/usr/bin/grep -Ec '^[[:space:]]*AGENT_ISLAND_ICLOUD_CONTAINER_ID[[:space:]]*=' "$IOS_CONFIG_PATH")"
XC_TEAM_COUNT="$(/usr/bin/grep -Ec '^[[:space:]]*AGENT_ISLAND_DEVELOPMENT_TEAM[[:space:]]*=' "$IOS_CONFIG_PATH")"
MAC_XC_APP_COUNT="$(/usr/bin/grep -Ec '^[[:space:]]*AGENT_ISLAND_MAC_APP_BUNDLE_ID[[:space:]]*=' "$MAC_CONFIG_PATH")"
[[ "$XC_APP_COUNT" == 1 && "$XC_WIDGET_COUNT" == 1 && "$XC_CONTAINER_COUNT" == 1 && "$XC_TEAM_COUNT" == 1 ]] \
  || fail "Project.xcconfig must contain exactly one app, widget, container, and team identity setting"
[[ "$MAC_XC_APP_COUNT" == 1 ]] \
  || fail "macOS Project.xcconfig must contain exactly one AGENT_ISLAND_MAC_APP_BUNDLE_ID setting"

XC_CURRENT_APP="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_APP_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_WIDGET="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_WIDGET_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_CONTAINER="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_ICLOUD_CONTAINER_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_TEAM="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
MAC_XC_CURRENT_APP="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_MAC_APP_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$MAC_CONFIG_PATH")"

CHANGES=()
[[ "$MAC_CURRENT_BUNDLE_ID" == "$MAC_BUNDLE_ID" ]] || CHANGES+=("Resources/Info.plist:CFBundleIdentifier")
[[ "$XC_CURRENT_APP" == "$IOS_APP_BUNDLE_ID" ]] || CHANGES+=("Project.xcconfig:appBundleIdentifier")
[[ "$XC_CURRENT_WIDGET" == '$(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' ]] || CHANGES+=("Project.xcconfig:widgetBundleIdentifier")
[[ "$XC_CURRENT_CONTAINER" == "$CLOUDKIT_CONTAINER_ID" ]] || CHANGES+=("Project.xcconfig:iCloudContainerIdentifier")
[[ "$XC_CURRENT_TEAM" == "$TEAM_ID" ]] || CHANGES+=("Project.xcconfig:teamIdentifier")
[[ "$MAC_XC_CURRENT_APP" == "$MAC_BUNDLE_ID" ]] || CHANGES+=("macOS Project.xcconfig:appBundleIdentifier")
if [[ "$LEGACY_MAC_BACKUP_REQUIRED" == true ]]; then
  CHANGES+=("identity-backup:schemaV2MacConfig" "identity.lock:macOSConfigBinding")
fi
if [[ "$PROFILE_SUPPLIED" == true ]]; then
  if [[ ! -f "$ENTITLEMENTS_PATH" ]] || ! /usr/bin/cmp -s "$GENERATED_ENTITLEMENTS" "$ENTITLEMENTS_PATH"; then
    CHANGES+=(".release/CloudKit.entitlements")
  fi
fi

CHANGES_JSON="$(printf '%s\n' "${CHANGES[@]:-}" | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
if [[ "$MODE" == "check" ]]; then
  /usr/bin/jq -n \
    --arg identityFile "$IDENTITY_FILE" \
    --argjson identity "$(/bin/cat "$CANONICAL_IDENTITY")" \
    --argjson inputSchemaVersion "$INPUT_SCHEMA_VERSION" \
    --argjson legacySchemaMigrated "$LEGACY_SCHEMA_MIGRATED" \
    --argjson changes "$CHANGES_JSON" \
    --argjson profileSupplied "$PROFILE_SUPPLIED" \
    --arg appIdentifier "$PROFILE_APP_IDENTIFIER" \
    --arg prefix "$PROFILE_PREFIX" \
    --arg lockPath ".release/identity.lock.json" \
    --arg entitlementsPath ".release/CloudKit.entitlements" \
    --argjson lockExists "$([[ -f "$LOCK_PATH" ]] && print true || print false)" '{
      mode: "check",
      valid: true,
      identityFile: $identityFile,
      identity: $identity,
      inputSchemaVersion: $inputSchemaVersion,
      legacySchemaMigrated: $legacySchemaMigrated,
      changes: $changes,
      lock: {path: $lockPath, exists: $lockExists},
      provisioningProfile: {
        supplied: $profileSupplied,
        validated: $profileSupplied,
        applicationIdentifier: (if $profileSupplied then $appIdentifier else null end),
        appIDPrefix: (if $profileSupplied then $prefix else null end)
      },
      finalEntitlements: {
        path: $entitlementsPath,
        wouldGenerate: $profileSupplied,
        appIDPrefixGuessed: false
      },
      writesPerformed: false
    }'
  exit 0
fi

[[ "$MODE" == "apply" ]] || fail "internal mode error"
mkdir -p "$RELEASE_DIR"
chmod 700 "$RELEASE_DIR"

# Build all target files fully before the permanent baseline backup and before
# replacing anything in the source tree.
STAGED_MAC_INFO="$STAGING_DIR/Info.plist"
STAGED_IOS_CONFIG="$STAGING_DIR/iOS-Project.xcconfig"
STAGED_MAC_CONFIG="$STAGING_DIR/macOS-Project.xcconfig"
/bin/cp -p "$MAC_INFO_PATH" "$STAGED_MAC_INFO"
/usr/bin/plutil -replace CFBundleIdentifier -string "$MAC_BUNDLE_ID" "$STAGED_MAC_INFO"
/usr/bin/plutil -lint "$STAGED_MAC_INFO" >/dev/null
/usr/bin/awk \
  -v app="$IOS_APP_BUNDLE_ID" \
  -v container="$CLOUDKIT_CONTAINER_ID" \
  -v team="$TEAM_ID" '
  /^[[:space:]]*AGENT_ISLAND_APP_BUNDLE_ID[[:space:]]*=/ {
    print "AGENT_ISLAND_APP_BUNDLE_ID = " app; next
  }
  /^[[:space:]]*AGENT_ISLAND_WIDGET_BUNDLE_ID[[:space:]]*=/ {
    print "AGENT_ISLAND_WIDGET_BUNDLE_ID = $(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity"; next
  }
  /^[[:space:]]*AGENT_ISLAND_ICLOUD_CONTAINER_ID[[:space:]]*=/ {
    print "AGENT_ISLAND_ICLOUD_CONTAINER_ID = " container; next
  }
  /^[[:space:]]*AGENT_ISLAND_DEVELOPMENT_TEAM[[:space:]]*=/ {
    print "AGENT_ISLAND_DEVELOPMENT_TEAM = " team; next
  }
  { print }
' "$IOS_CONFIG_PATH" > "$STAGED_IOS_CONFIG"

/usr/bin/awk \
  -v app="$MAC_BUNDLE_ID" '
  /^[[:space:]]*AGENT_ISLAND_MAC_APP_BUNDLE_ID[[:space:]]*=/ {
    print "AGENT_ISLAND_MAC_APP_BUNDLE_ID = " app; next
  }
  { print }
' "$MAC_CONFIG_PATH" > "$STAGED_MAC_CONFIG"

if [[ ! -e "$BACKUP_DIR" ]]; then
  BACKUP_STAGING_DIR="$RELEASE_DIR/.identity-backup.identity-new.$$"
  [[ ! -e "$BACKUP_STAGING_DIR" ]] || fail "temporary identity backup path already exists"
  mkdir -p "$BACKUP_STAGING_DIR/Resources" \
    "$BACKUP_STAGING_DIR/ApplePlatforms/iOS/Config" \
    "$BACKUP_STAGING_DIR/ApplePlatforms/macOS/Config"
  chmod 700 "$BACKUP_STAGING_DIR"
  /bin/cp -p "$MAC_INFO_PATH" "$BACKUP_STAGING_DIR/Resources/Info.plist"
  /bin/cp -p "$IOS_CONFIG_PATH" \
    "$BACKUP_STAGING_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
  /bin/cp -p "$MAC_CONFIG_PATH" \
    "$BACKUP_STAGING_DIR/ApplePlatforms/macOS/Config/Project.xcconfig"
  BACKUP_CREATED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  /usr/bin/jq -n \
    --arg createdAt "$BACKUP_CREATED_AT" \
    --arg macSha "$(sha256_file "$MAC_INFO_PATH")" \
    --arg iosSha "$(sha256_file "$IOS_CONFIG_PATH")" \
    --arg macConfigSha "$(sha256_file "$MAC_CONFIG_PATH")" '{
      schemaVersion: 2,
      createdAt: $createdAt,
      purpose: "Recover the workspace state from immediately before the first release-identity apply.",
      files: [
        {path: "Resources/Info.plist", existed: true, sha256: $macSha},
        {path: "ApplePlatforms/iOS/Config/Project.xcconfig", existed: true, sha256: $iosSha},
        {path: "ApplePlatforms/macOS/Config/Project.xcconfig", existed: true, sha256: $macConfigSha},
        {path: ".release/CloudKit.entitlements", existed: false, sha256: null},
        {path: ".release/identity.lock.json", existed: false, sha256: null}
      ]
    }' > "$BACKUP_STAGING_DIR/manifest.json"
  /bin/mv "$BACKUP_STAGING_DIR" "$BACKUP_DIR"
  BACKUP_STAGING_DIR=""
else
  [[ -f "$BACKUP_DIR/manifest.json" && -f "$BACKUP_DIR/Resources/Info.plist" && \
    -f "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" ]] \
    || fail "existing identity backup is incomplete; refusing to overwrite it"
  if [[ "$LEGACY_MAC_BACKUP_REQUIRED" == true ]]; then
    LEGACY_MAC_BACKUP_STAGE="$BACKUP_DIR/.schema-v2-macos-config.identity-new.$$"
    LEGACY_MAC_BACKUP_DESTINATION="$BACKUP_DIR/schema-v2-macos-config"
    [[ ! -e "$LEGACY_MAC_BACKUP_STAGE" && ! -e "$LEGACY_MAC_BACKUP_DESTINATION" ]] \
      || fail "legacy macOS config backup migration path already exists"
    mkdir -p "$LEGACY_MAC_BACKUP_STAGE/ApplePlatforms/macOS/Config"
    /bin/cp -p "$MAC_CONFIG_PATH" \
      "$LEGACY_MAC_BACKUP_STAGE/ApplePlatforms/macOS/Config/Project.xcconfig"
    /usr/bin/jq -n \
      --arg capturedAt "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg sha256 "$(sha256_file "$MAC_CONFIG_PATH")" '{
        schemaVersion: 1,
        capturedAt: $capturedAt,
        purpose: "Recover macOS Project.xcconfig from before schema-v2 identity management.",
        files: [{
          path: "ApplePlatforms/macOS/Config/Project.xcconfig",
          existed: true,
          sha256: $sha256
        }]
      }' > "$LEGACY_MAC_BACKUP_STAGE/manifest.json"
    /bin/mv "$LEGACY_MAC_BACKUP_STAGE" "$LEGACY_MAC_BACKUP_DESTINATION"
    LEGACY_MAC_BACKUP_STAGE=""
  fi
fi

# Preserve immediate originals for automatic transaction rollback. Each target
# replacement is itself a same-directory atomic rename; if a later replacement
# fails, the EXIT trap restores every earlier replacement in reverse order.
/bin/cp -p "$MAC_INFO_PATH" "$STAGING_DIR/original-Info.plist"
/bin/cp -p "$IOS_CONFIG_PATH" "$STAGING_DIR/original-iOS-Project.xcconfig"
/bin/cp -p "$MAC_CONFIG_PATH" "$STAGING_DIR/original-macOS-Project.xcconfig"
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  ENTITLEMENTS_EXISTED_BEFORE=true
  /bin/cp -p "$ENTITLEMENTS_PATH" "$STAGING_DIR/original-CloudKit.entitlements"
fi
if [[ -f "$LOCK_PATH" ]]; then
  LOCK_EXISTED_BEFORE=true
  /bin/cp -p "$LOCK_PATH" "$STAGING_DIR/original-identity.lock.json"
fi
WRITE_TRANSACTION_ACTIVE=true

if ! /usr/bin/cmp -s "$STAGED_MAC_INFO" "$MAC_INFO_PATH"; then
  /bin/cp -p "$STAGED_MAC_INFO" "$PROJECT_DIR/Resources/.Info.plist.identity-new"
  /bin/mv -f "$PROJECT_DIR/Resources/.Info.plist.identity-new" "$MAC_INFO_PATH"
  MAC_INFO_REPLACED=true
fi
if ! /usr/bin/cmp -s "$STAGED_IOS_CONFIG" "$IOS_CONFIG_PATH"; then
  /bin/cp -p "$STAGED_IOS_CONFIG" "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-new"
  /bin/mv -f "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-new" "$IOS_CONFIG_PATH"
  IOS_CONFIG_REPLACED=true
fi
if ! /usr/bin/cmp -s "$STAGED_MAC_CONFIG" "$MAC_CONFIG_PATH"; then
  /bin/cp -p "$STAGED_MAC_CONFIG" "$PROJECT_DIR/ApplePlatforms/macOS/Config/.Project.xcconfig.identity-new"
  /bin/mv -f "$PROJECT_DIR/ApplePlatforms/macOS/Config/.Project.xcconfig.identity-new" "$MAC_CONFIG_PATH"
  MAC_CONFIG_REPLACED=true
fi

if [[ "$PROFILE_SUPPLIED" == true ]]; then
  if [[ ! -f "$ENTITLEMENTS_PATH" ]] || ! /usr/bin/cmp -s "$GENERATED_ENTITLEMENTS" "$ENTITLEMENTS_PATH"; then
    /bin/cp -p "$GENERATED_ENTITLEMENTS" "$RELEASE_DIR/.CloudKit.entitlements.identity-new"
    /bin/mv -f "$RELEASE_DIR/.CloudKit.entitlements.identity-new" "$ENTITLEMENTS_PATH"
    ENTITLEMENTS_REPLACED=true
  fi
  chmod 600 "$ENTITLEMENTS_PATH"
fi

MAC_SHA="$(sha256_file "$MAC_INFO_PATH")"
IOS_SHA="$(sha256_file "$IOS_CONFIG_PATH")"
MAC_CONFIG_SHA="$(sha256_file "$MAC_CONFIG_PATH")"
FIRST_APPLIED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -f "$LOCK_PATH" ]]; then
  FIRST_APPLIED_AT="$(/usr/bin/jq -r '.firstAppliedAt // empty' "$LOCK_PATH")"
  [[ -n "$FIRST_APPLIED_AT" ]] || fail "existing identity lock has no firstAppliedAt"
fi

if [[ "$PROFILE_SUPPLIED" == true ]]; then
  ENTITLEMENTS_SHA="$(sha256_file "$ENTITLEMENTS_PATH")"
  PROFILE_JSON_FOR_LOCK="$(/usr/bin/jq -n \
    --arg sha256 "$PROFILE_SHA256" \
    --arg uuid "$PROFILE_UUID" \
    --arg name "$PROFILE_NAME" \
    --arg expiration "$PROFILE_EXPIRATION" \
    --arg appIdentifier "$PROFILE_APP_IDENTIFIER" \
    --arg appIDPrefix "$PROFILE_PREFIX" '{
      sha256: $sha256,
      uuid: $uuid,
      name: $name,
      expiration: $expiration,
      applicationIdentifier: $appIdentifier,
      appIDPrefix: $appIDPrefix
    }')"
  ENTITLEMENTS_JSON_FOR_LOCK="$(/usr/bin/jq -n \
    --arg path ".release/CloudKit.entitlements" \
    --arg sha256 "$ENTITLEMENTS_SHA" '{path: $path, sha256: $sha256}')"
elif [[ -f "$LOCK_PATH" ]]; then
  PROFILE_JSON_FOR_LOCK="$(/usr/bin/jq -c '.provisioningProfile // null' "$LOCK_PATH")"
  ENTITLEMENTS_JSON_FOR_LOCK="$(/usr/bin/jq -c '.generatedEntitlements // null' "$LOCK_PATH")"
else
  PROFILE_JSON_FOR_LOCK="null"
  ENTITLEMENTS_JSON_FOR_LOCK="null"
fi

# Preserve an existing lock's identity encoding after semantic comparison.
# New locks always record schema v2; compatible schema-v1 locks retain their
# original identity payload while the envelope may receive the one-time macOS
# config binding introduced by schema v2.
if [[ -f "$LOCK_PATH" ]]; then
  IDENTITY_JSON_FOR_LOCK="$(/usr/bin/jq -c '.identity' "$LOCK_PATH")"
else
  IDENTITY_JSON_FOR_LOCK="$(/bin/cat "$CANONICAL_IDENTITY")"
fi

NEW_LOCK="$STAGING_DIR/identity.lock.json"
/usr/bin/jq -n -S \
  --arg firstAppliedAt "$FIRST_APPLIED_AT" \
  --argjson identity "$IDENTITY_JSON_FOR_LOCK" \
  --argjson profile "$PROFILE_JSON_FOR_LOCK" \
  --argjson entitlements "$ENTITLEMENTS_JSON_FOR_LOCK" \
  --arg macSha "$MAC_SHA" \
  --arg iosSha "$IOS_SHA" \
  --arg macConfigSha "$MAC_CONFIG_SHA" '{
    schemaVersion: 1,
    firstAppliedAt: $firstAppliedAt,
    identity: $identity,
    provisioningProfile: $profile,
    generatedEntitlements: $entitlements,
    appliedFiles: [
      {path: "Resources/Info.plist", sha256: $macSha},
      {path: "ApplePlatforms/iOS/Config/Project.xcconfig", sha256: $iosSha},
      {path: "ApplePlatforms/macOS/Config/Project.xcconfig", sha256: $macConfigSha}
    ]
  }' > "$NEW_LOCK"

LOCK_WRITTEN=false
if [[ ! -f "$LOCK_PATH" ]] || ! /usr/bin/cmp -s "$NEW_LOCK" "$LOCK_PATH"; then
  /bin/cp -p "$NEW_LOCK" "$RELEASE_DIR/.identity.lock.json.identity-new"
  /bin/mv -f "$RELEASE_DIR/.identity.lock.json.identity-new" "$LOCK_PATH"
  LOCK_REPLACED=true
  chmod 600 "$LOCK_PATH"
  LOCK_WRITTEN=true
fi

WRITE_TRANSACTION_ACTIVE=false

/usr/bin/jq -n \
  --argjson identity "$(/bin/cat "$CANONICAL_IDENTITY")" \
  --argjson inputSchemaVersion "$INPUT_SCHEMA_VERSION" \
  --argjson legacySchemaMigrated "$LEGACY_SCHEMA_MIGRATED" \
  --argjson changes "$CHANGES_JSON" \
  --argjson profileSupplied "$PROFILE_SUPPLIED" \
  --argjson lockWritten "$LOCK_WRITTEN" \
  --arg appIdentifier "$PROFILE_APP_IDENTIFIER" \
  --arg lockPath ".release/identity.lock.json" \
  --arg backupPath ".release/identity-backup" \
  --arg entitlementsPath ".release/CloudKit.entitlements" '{
    mode: "apply",
    valid: true,
    identity: $identity,
    inputSchemaVersion: $inputSchemaVersion,
    legacySchemaMigrated: $legacySchemaMigrated,
    changesApplied: $changes,
    lock: {path: $lockPath, written: $lockWritten},
    backup: {path: $backupPath, recoverable: true},
    provisioningProfile: {
      supplied: $profileSupplied,
      validated: $profileSupplied,
      applicationIdentifier: (if $profileSupplied then $appIdentifier else null end)
    },
    finalEntitlements: {
      path: (if $profileSupplied then $entitlementsPath else null end),
      generated: $profileSupplied,
      appIDPrefixGuessed: false
    }
  }'
