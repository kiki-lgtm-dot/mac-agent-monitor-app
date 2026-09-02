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
STAGING_DIR=""

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
command -v /usr/bin/jq >/dev/null || fail "jq is required"
command -v /usr/bin/plutil >/dev/null || fail "plutil is required"

STAGING_DIR="$(mktemp -d /private/tmp/agentisland-identity.XXXXXX)"
cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
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
' "$IDENTITY_FILE" >/dev/null || fail "identity JSON is missing a required field or uses an unsupported schemaVersion"

UNKNOWN_CLOUDKIT="$(/usr/bin/jq -r '
  (.cloudKit | keys) - ["databaseScope", "environment", "recordType", "recordName", "payloadField"]
  | join(", ")
' "$IDENTITY_FILE")"
[[ -z "$UNKNOWN_CLOUDKIT" ]] || fail "unknown cloudKit field(s): $UNKNOWN_CLOUDKIT"

PRIMARY_BUNDLE_ID="$(/usr/bin/jq -r '.primaryBundleIdentifier' "$IDENTITY_FILE")"
WIDGET_BUNDLE_ID="$(/usr/bin/jq -r '.widgetBundleIdentifier' "$IDENTITY_FILE")"
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
production_bundle_id "$PRIMARY_BUNDLE_ID" \
  || fail "primaryBundleIdentifier must be a production reverse-DNS bundle identifier"
[[ "$WIDGET_BUNDLE_ID" == "$PRIMARY_BUNDLE_ID.liveactivity" ]] \
  || fail "widgetBundleIdentifier must equal primaryBundleIdentifier + .liveactivity"
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
/usr/bin/jq -S '{
  schemaVersion,
  primaryBundleIdentifier,
  widgetBundleIdentifier,
  teamIdentifier,
  iCloudContainerIdentifier,
  cloudKit
}' "$IDENTITY_FILE" > "$CANONICAL_IDENTITY"

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
  [[ -f "$BACKUP_DIR/manifest.json" && -f "$BACKUP_DIR/Resources/Info.plist" && \
    -f "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" ]] \
    || fail "existing identity lock has no complete recoverable baseline backup"
  LOCKED_IDENTITY="$STAGING_DIR/locked-identity.json"
  /usr/bin/jq -S '.identity' "$LOCK_PATH" > "$LOCKED_IDENTITY"
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
    --arg bundle "$PRIMARY_BUNDLE_ID" \
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
    "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]] \
    || fail "profile must be an unexpired all-device OSX Developer ID profile for the release Team with at least one signing certificate"
  local_suffix=".$PRIMARY_BUNDLE_ID"
  PROFILE_PREFIX="${PROFILE_APP_IDENTIFIER%$local_suffix}"
  [[ -n "$PROFILE_PREFIX" && "$PROFILE_PREFIX" != "$PROFILE_APP_IDENTIFIER" ]] \
    || fail "profile does not expose an authoritative App ID prefix"
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
[[ "$XC_APP_COUNT" == 1 && "$XC_WIDGET_COUNT" == 1 && "$XC_CONTAINER_COUNT" == 1 && "$XC_TEAM_COUNT" == 1 ]] \
  || fail "Project.xcconfig must contain exactly one app, widget, container, and team identity setting"

XC_CURRENT_APP="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_APP_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_WIDGET="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_WIDGET_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_CONTAINER="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_ICLOUD_CONTAINER_ID[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"
XC_CURRENT_TEAM="$(/usr/bin/sed -n 's/^[[:space:]]*AGENT_ISLAND_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$IOS_CONFIG_PATH")"

CHANGES=()
[[ "$MAC_CURRENT_BUNDLE_ID" == "$PRIMARY_BUNDLE_ID" ]] || CHANGES+=("Resources/Info.plist:CFBundleIdentifier")
[[ "$XC_CURRENT_APP" == "$PRIMARY_BUNDLE_ID" ]] || CHANGES+=("Project.xcconfig:appBundleIdentifier")
[[ "$XC_CURRENT_WIDGET" == '$(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' ]] || CHANGES+=("Project.xcconfig:widgetBundleIdentifier")
[[ "$XC_CURRENT_CONTAINER" == "$CLOUDKIT_CONTAINER_ID" ]] || CHANGES+=("Project.xcconfig:iCloudContainerIdentifier")
[[ "$XC_CURRENT_TEAM" == "$TEAM_ID" ]] || CHANGES+=("Project.xcconfig:teamIdentifier")
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

# Build both target files fully before the permanent baseline backup and before
# replacing anything in the source tree.
STAGED_MAC_INFO="$STAGING_DIR/Info.plist"
STAGED_IOS_CONFIG="$STAGING_DIR/Project.xcconfig"
/bin/cp -p "$MAC_INFO_PATH" "$STAGED_MAC_INFO"
/usr/bin/plutil -replace CFBundleIdentifier -string "$PRIMARY_BUNDLE_ID" "$STAGED_MAC_INFO"
/usr/bin/plutil -lint "$STAGED_MAC_INFO" >/dev/null
/usr/bin/awk \
  -v app="$PRIMARY_BUNDLE_ID" \
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

if [[ ! -e "$BACKUP_DIR" ]]; then
  mkdir -p "$BACKUP_DIR/Resources" "$BACKUP_DIR/ApplePlatforms/iOS/Config"
  chmod 700 "$BACKUP_DIR"
  /bin/cp -p "$MAC_INFO_PATH" "$BACKUP_DIR/Resources/Info.plist"
  /bin/cp -p "$IOS_CONFIG_PATH" "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
  BACKUP_CREATED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  /usr/bin/jq -n \
    --arg createdAt "$BACKUP_CREATED_AT" \
    --arg macSha "$(sha256_file "$MAC_INFO_PATH")" \
    --arg iosSha "$(sha256_file "$IOS_CONFIG_PATH")" '{
      schemaVersion: 1,
      createdAt: $createdAt,
      purpose: "Recover the workspace state from immediately before the first release-identity apply.",
      files: [
        {path: "Resources/Info.plist", existed: true, sha256: $macSha},
        {path: "ApplePlatforms/iOS/Config/Project.xcconfig", existed: true, sha256: $iosSha},
        {path: ".release/CloudKit.entitlements", existed: false, sha256: null},
        {path: ".release/identity.lock.json", existed: false, sha256: null}
      ]
    }' > "$BACKUP_DIR/manifest.json"
else
  [[ -f "$BACKUP_DIR/manifest.json" && -f "$BACKUP_DIR/Resources/Info.plist" && \
    -f "$BACKUP_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" ]] \
    || fail "existing identity backup is incomplete; refusing to overwrite it"
fi

# Copy-to-hidden-file then rename keeps each target update atomic on its own
# filesystem. All semantic validation has already completed at this point.
if ! /usr/bin/cmp -s "$STAGED_MAC_INFO" "$MAC_INFO_PATH"; then
  /bin/cp -p "$STAGED_MAC_INFO" "$PROJECT_DIR/Resources/.Info.plist.identity-new"
  /bin/mv -f "$PROJECT_DIR/Resources/.Info.plist.identity-new" "$MAC_INFO_PATH"
fi
if ! /usr/bin/cmp -s "$STAGED_IOS_CONFIG" "$IOS_CONFIG_PATH"; then
  /bin/cp -p "$STAGED_IOS_CONFIG" "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-new"
  /bin/mv -f "$PROJECT_DIR/ApplePlatforms/iOS/Config/.Project.xcconfig.identity-new" "$IOS_CONFIG_PATH"
fi

if [[ "$PROFILE_SUPPLIED" == true ]]; then
  if [[ ! -f "$ENTITLEMENTS_PATH" ]] || ! /usr/bin/cmp -s "$GENERATED_ENTITLEMENTS" "$ENTITLEMENTS_PATH"; then
    /bin/cp -p "$GENERATED_ENTITLEMENTS" "$RELEASE_DIR/.CloudKit.entitlements.identity-new"
    /bin/mv -f "$RELEASE_DIR/.CloudKit.entitlements.identity-new" "$ENTITLEMENTS_PATH"
  fi
  chmod 600 "$ENTITLEMENTS_PATH"
fi

MAC_SHA="$(sha256_file "$MAC_INFO_PATH")"
IOS_SHA="$(sha256_file "$IOS_CONFIG_PATH")"
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

NEW_LOCK="$STAGING_DIR/identity.lock.json"
/usr/bin/jq -n -S \
  --arg firstAppliedAt "$FIRST_APPLIED_AT" \
  --argjson identity "$(/bin/cat "$CANONICAL_IDENTITY")" \
  --argjson profile "$PROFILE_JSON_FOR_LOCK" \
  --argjson entitlements "$ENTITLEMENTS_JSON_FOR_LOCK" \
  --arg macSha "$MAC_SHA" \
  --arg iosSha "$IOS_SHA" '{
    schemaVersion: 1,
    firstAppliedAt: $firstAppliedAt,
    identity: $identity,
    provisioningProfile: $profile,
    generatedEntitlements: $entitlements,
    appliedFiles: [
      {path: "Resources/Info.plist", sha256: $macSha},
      {path: "ApplePlatforms/iOS/Config/Project.xcconfig", sha256: $iosSha}
    ]
  }' > "$NEW_LOCK"

LOCK_WRITTEN=false
if [[ ! -f "$LOCK_PATH" ]] || ! /usr/bin/cmp -s "$NEW_LOCK" "$LOCK_PATH"; then
  /bin/cp -p "$NEW_LOCK" "$RELEASE_DIR/.identity.lock.json.identity-new"
  /bin/mv -f "$RELEASE_DIR/.identity.lock.json.identity-new" "$LOCK_PATH"
  chmod 600 "$LOCK_PATH"
  LOCK_WRITTEN=true
fi

/usr/bin/jq -n \
  --argjson identity "$(/bin/cat "$CANONICAL_IDENTITY")" \
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
