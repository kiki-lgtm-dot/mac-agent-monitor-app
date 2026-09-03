#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-identity-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

sha256_file() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

write_v2_identity() {
  local source="$1"
  local destination="$2"
  local record_mode="${3:-universal-purchase}"
  local mac_bundle="${4:-com.agentisland.release}"
  local ios_bundle="${5:-com.agentisland.release}"
  /usr/bin/jq \
    --arg recordMode "$record_mode" \
    --arg macBundle "$mac_bundle" \
    --arg iosBundle "$ios_bundle" '{
      schemaVersion: 2,
      appStoreRecordMode: $recordMode,
      macOSAppBundleIdentifier: $macBundle,
      iOSAppBundleIdentifier: $iosBundle,
      iOSWidgetBundleIdentifier: ($iosBundle + ".liveactivity"),
      teamIdentifier,
      iCloudContainerIdentifier,
      cloudKit
    }' "$source" > "$destination"
}

new_sandbox() {
  local name="$1"
  local schema="${2:-v2}"
  local root="$TEST_ROOT/$name"
  /bin/mkdir -p "$root/scripts" "$root/Config" "$root/Resources" \
    "$root/ApplePlatforms/iOS/Config" "$root/ApplePlatforms/macOS/Config" \
    "$root/Tests/Fixtures"
  /bin/cp "$PROJECT_DIR/scripts/apply-release-identity.sh" "$root/scripts/apply-release-identity.sh"
  /bin/cp "$PROJECT_DIR/scripts/release-readiness.sh" "$root/scripts/release-readiness.sh"
  /bin/chmod 755 "$root/scripts/apply-release-identity.sh" \
    "$root/scripts/release-readiness.sh"
  /bin/cp "$PROJECT_DIR/Resources/Info.plist" "$root/Resources/Info.plist"
  /bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" \
    "$root/ApplePlatforms/iOS/Config/Project.xcconfig"
  /bin/cp "$PROJECT_DIR/ApplePlatforms/macOS/Config/Project.xcconfig" \
    "$root/ApplePlatforms/macOS/Config/Project.xcconfig"
  if [[ "$schema" == "v1" ]]; then
    /bin/cp "$PROJECT_DIR/Tests/Fixtures/release-identity.valid.json" \
      "$root/Config/ReleaseIdentity.json"
  else
    write_v2_identity "$PROJECT_DIR/Tests/Fixtures/release-identity.valid.json" \
      "$root/Config/ReleaseIdentity.json"
  fi
  print -r -- "$root"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  output="$("$@" 2>&1 || true)"
  [[ "$output" == *"$expected"* ]] || {
    print -u2 -- "Expected failure containing: $expected"
    print -u2 -- "$output"
    exit 1
  }
}

release_identity_report() {
  local root="$1"
  local profile_path="${2:-}"
  local entitlements_path="${3:-}"
  local decoded_profile_path="${4:-}"
  local ios_bundle_id="${5:-}"
  local ios_widget_bundle_id="${6:-}"
  local -a environment
  environment=(
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "DEVELOPER_DIR=/nonexistent"
    "AGENT_ISLAND_BUNDLE_ID=com.agentisland.release"
    "AGENT_ISLAND_DEVELOPER_ID_APPLICATION=Developer ID Application: AgentIsland Fixture (ABCDE12345)"
    "AGENT_ISLAND_DEVELOPMENT_TEAM=ABCDE12345"
    "AGENT_ISLAND_DISPLAY_NAME=MAC版灵动岛--Agent运行监测"
    "AGENT_ISLAND_ICLOUD_CONTAINER_ID=iCloud.com.agentisland.releasefixture"
    "AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE=fixture-notary-profile"
    "AGENT_ISLAND_PRIVACY_POLICY_URL=https://agentisland.app/privacy"
    "AGENT_ISLAND_SUPPORT_URL=https://agentisland.app/support"
    "AGENT_ISLAND_APP_STORE_RECORD_MODE=universal-purchase"
  )
  if [[ -n "$profile_path" ]]; then
    environment+=("AGENT_ISLAND_PROVISIONING_PROFILE=$profile_path")
  fi
  if [[ -n "$entitlements_path" ]]; then
    environment+=("AGENT_ISLAND_ENTITLEMENTS=$entitlements_path")
  fi
  if [[ -n "$decoded_profile_path" ]]; then
    environment+=("AGENT_ISLAND_TEST_DECODED_PROFILE=$decoded_profile_path")
  fi
  if [[ -n "$ios_bundle_id" ]]; then
    environment+=("AGENT_ISLAND_IOS_BUNDLE_ID=$ios_bundle_id")
  fi
  if [[ -n "$ios_widget_bundle_id" ]]; then
    environment+=("AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID=$ios_widget_bundle_id")
  fi
  /usr/bin/env -i "${environment[@]}" "$root/scripts/release-readiness.sh" --json
}

install_security_stub() {
  local root="$1"
  local stub="$root/Tests/security-stub"
  local xcrun_stub="$root/Tests/xcrun-stub"
  /bin/mkdir -p "$root/Tests"
  /bin/cat > "$stub" <<'STUB'
#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "find-identity" ]]; then
  print -r -- '  1) C053ECF9ED41DF0311B9DF13CC6C3B6078D2D3C2 "Developer ID Application: AgentIsland Fixture (ABCDE12345)"'
  print -r -- '     1 valid identities found'
  exit 0
fi
if [[ "${1:-}" == "cms" && "${2:-}" == "-D" ]]; then
  output_path=""
  shift 2
  while (( $# > 0 )); do
    case "$1" in
      -i)
        shift 2
        ;;
      -o)
        output_path="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "$output_path" && -f "${AGENT_ISLAND_TEST_DECODED_PROFILE:-}" ]]
  /bin/cp "$AGENT_ISLAND_TEST_DECODED_PROFILE" "$output_path"
  exit 0
fi
exit 1
STUB
  /bin/cat > "$xcrun_stub" <<'STUB'
#!/bin/zsh
set -euo pipefail
if [[ "$*" == "--sdk macosx --show-sdk-path" ]]; then
  print -r -- "/"
  exit 0
fi
if [[ "${1:-}" == "--find" && -n "${2:-}" ]]; then
  print -r -- "/usr/bin/true"
  exit 0
fi
exit 1
STUB
  /bin/chmod 755 "$stub" "$xcrun_stub"
  /usr/bin/sed -i '' \
    -e "s#/usr/bin/security#$stub#g" \
    -e "s#/usr/bin/xcrun#$xcrun_stub#g" \
    "$root/scripts/apply-release-identity.sh" \
    "$root/scripts/release-readiness.sh"
}

# Default --check validates and describes changes but cannot touch the tree.
CHECK_ROOT="$(new_sandbox check)"
CHECK_MAC_BEFORE="$(sha256_file "$CHECK_ROOT/Resources/Info.plist")"
CHECK_IOS_BEFORE="$(sha256_file "$CHECK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
CHECK_MAC_CONFIG_BEFORE="$(sha256_file "$CHECK_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
CHECK_OUTPUT="$($CHECK_ROOT/scripts/apply-release-identity.sh)"
print -r -- "$CHECK_OUTPUT" | /usr/bin/jq -e '
  .mode == "check" and .valid == true and .writesPerformed == false and
  .inputSchemaVersion == 2 and .legacySchemaMigrated == false and
  .identity.schemaVersion == 2 and
  .identity.appStoreRecordMode == "universal-purchase" and
  .identity.macOSAppBundleIdentifier == .identity.iOSAppBundleIdentifier and
  .identity.iOSWidgetBundleIdentifier == (.identity.iOSAppBundleIdentifier + ".liveactivity") and
  .lock.exists == false and
  .provisioningProfile.supplied == false and
  .finalEntitlements.wouldGenerate == false and
  .finalEntitlements.appIDPrefixGuessed == false and
  (.changes | index("Resources/Info.plist:CFBundleIdentifier") != null)
' >/dev/null
[[ ! -e "$CHECK_ROOT/.release" ]]
[[ "$CHECK_MAC_BEFORE" == "$(sha256_file "$CHECK_ROOT/Resources/Info.plist")" ]]
[[ "$CHECK_IOS_BEFORE" == "$(sha256_file "$CHECK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$CHECK_MAC_CONFIG_BEFORE" == \
  "$(sha256_file "$CHECK_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]

# First apply updates only the identity-bearing plist/xcconfig, creates a
# permanent baseline backup and lock, and does not invent final entitlements.
APPLY_ROOT="$(new_sandbox apply)"
ORIGINAL_MAC_SHA="$(sha256_file "$APPLY_ROOT/Resources/Info.plist")"
ORIGINAL_IOS_SHA="$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
ORIGINAL_MAC_CONFIG_SHA="$(sha256_file "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
APPLY_OUTPUT="$($APPLY_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$APPLY_OUTPUT" | /usr/bin/jq -e '
  .mode == "apply" and .valid == true and
  .backup.recoverable == true and
  .provisioningProfile.supplied == false and
  .finalEntitlements.generated == false and
  .finalEntitlements.appIDPrefixGuessed == false
' >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APPLY_ROOT/Resources/Info.plist")" == "com.agentisland.release" ]]
/usr/bin/grep -Fqx 'AGENT_ISLAND_APP_BUNDLE_ID = com.agentisland.release' \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/grep -Fqx 'AGENT_ISLAND_WIDGET_BUNDLE_ID = $(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/grep -Fqx 'AGENT_ISLAND_ICLOUD_CONTAINER_ID = iCloud.com.agentisland.releasefixture' \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/grep -Fqx 'AGENT_ISLAND_DEVELOPMENT_TEAM = ABCDE12345' \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/grep -Fqx 'AGENT_ISLAND_MAC_APP_BUNDLE_ID = com.agentisland.release' \
  "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"
[[ -f "$APPLY_ROOT/.release/identity.lock.json" ]]
[[ -f "$APPLY_ROOT/.release/identity-backup/manifest.json" ]]
[[ -f "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/macOS/Config/Project.xcconfig" ]]
[[ ! -e "$APPLY_ROOT/.release/CloudKit.entitlements" ]]
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .identity.schemaVersion == 2 and
  .identity.appStoreRecordMode == "universal-purchase" and
  .identity.macOSAppBundleIdentifier == .identity.iOSAppBundleIdentifier and
  .identity.iOSWidgetBundleIdentifier == (.identity.iOSAppBundleIdentifier + ".liveactivity") and
  .identity.cloudKit == {
    databaseScope: "private",
    environment: "Production",
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON"
  } and
  .provisioningProfile == null and .generatedEntitlements == null and
  (.appliedFiles | any(.path == "ApplePlatforms/macOS/Config/Project.xcconfig"))
' "$APPLY_ROOT/.release/identity.lock.json" >/dev/null
/usr/bin/jq -e '
  .schemaVersion == 2 and
  (.files | any(.path == "ApplePlatforms/macOS/Config/Project.xcconfig"))
' "$APPLY_ROOT/.release/identity-backup/manifest.json" >/dev/null
[[ "$ORIGINAL_MAC_SHA" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/Resources/Info.plist")" ]]
[[ "$ORIGINAL_IOS_SHA" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$ORIGINAL_MAC_CONFIG_SHA" == \
  "$(sha256_file "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]

# Reapplying the same identity is a true no-op at the content/lock level and
# preserves the one-time baseline backup.
LOCK_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/.release/identity.lock.json")"
BACKUP_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/.release/identity-backup/manifest.json")"
MAC_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/Resources/Info.plist")"
IOS_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
MAC_CONFIG_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
MAC_INODE_BEFORE="$(/usr/bin/stat -f %i "$APPLY_ROOT/Resources/Info.plist")"
IOS_INODE_BEFORE="$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
MAC_CONFIG_INODE_BEFORE="$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
SECOND_OUTPUT="$($APPLY_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$SECOND_OUTPUT" | /usr/bin/jq -e '.changesApplied == [] and .lock.written == false' >/dev/null
[[ "$LOCK_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/.release/identity.lock.json")" ]]
[[ "$BACKUP_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/manifest.json")" ]]
[[ "$MAC_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$IOS_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$MAC_CONFIG_SHA_BEFORE" == \
  "$(sha256_file "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]
[[ "$MAC_INODE_BEFORE" == "$(/usr/bin/stat -f %i "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$IOS_INODE_BEFORE" == "$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$MAC_CONFIG_INODE_BEFORE" == \
  "$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]

# The baseline is actually usable for manual recovery.
/bin/cp "$APPLY_ROOT/.release/identity-backup/Resources/Info.plist" "$APPLY_ROOT/Resources/Info.plist"
/bin/cp "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig" \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/bin/cp "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/macOS/Config/Project.xcconfig" \
  "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"
[[ "$ORIGINAL_MAC_SHA" == "$(sha256_file "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$ORIGINAL_IOS_SHA" == "$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$ORIGINAL_MAC_CONFIG_SHA" == \
  "$(sha256_file "$APPLY_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]

# A later target write failure rolls back earlier atomic replacements. The
# durable baseline remains available, but no lock or partial identity survives.
ROLLBACK_ROOT="$(new_sandbox rollback)"
ROLLBACK_MAC_SHA="$(sha256_file "$ROLLBACK_ROOT/Resources/Info.plist")"
ROLLBACK_IOS_SHA="$(sha256_file "$ROLLBACK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
ROLLBACK_MAC_CONFIG_SHA="$(sha256_file "$ROLLBACK_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
/bin/chmod 500 "$ROLLBACK_ROOT/ApplePlatforms/macOS/Config"
expect_failure 'restored every identity file already replaced in this transaction' \
  "$ROLLBACK_ROOT/scripts/apply-release-identity.sh" --apply
/bin/chmod 700 "$ROLLBACK_ROOT/ApplePlatforms/macOS/Config"
[[ "$ROLLBACK_MAC_SHA" == "$(sha256_file "$ROLLBACK_ROOT/Resources/Info.plist")" ]]
[[ "$ROLLBACK_IOS_SHA" == \
  "$(sha256_file "$ROLLBACK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$ROLLBACK_MAC_CONFIG_SHA" == \
  "$(sha256_file "$ROLLBACK_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")" ]]
[[ ! -e "$ROLLBACK_ROOT/.release/identity.lock.json" ]]
[[ -f "$ROLLBACK_ROOT/.release/identity-backup/manifest.json" ]]

# The lock prevents accidental mutation of irreversible identifiers.
LOCK_ROOT="$(new_sandbox lock)"
$LOCK_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
/usr/bin/jq -S '
  .macOSAppBundleIdentifier = "com.agentisland.changed" |
  .iOSAppBundleIdentifier = "com.agentisland.changed" |
  .iOSWidgetBundleIdentifier = "com.agentisland.changed.liveactivity"
' \
  "$LOCK_ROOT/Config/ReleaseIdentity.json" > "$LOCK_ROOT/Config/Changed.json"
expect_failure 'identity differs from .release/identity.lock.json' \
  "$LOCK_ROOT/scripts/apply-release-identity.sh" --apply "$LOCK_ROOT/Config/Changed.json"

# The whitelist rejects both obvious credentials and arbitrary extra fields.
SECRET_ROOT="$(new_sandbox secret)"
/usr/bin/jq '.apiToken = "fixture-not-a-secret"' \
  "$SECRET_ROOT/Config/ReleaseIdentity.json" > "$SECRET_ROOT/Config/Secret.json"
expect_failure 'secret-bearing field is forbidden: apiToken' \
  "$SECRET_ROOT/scripts/apply-release-identity.sh" "$SECRET_ROOT/Config/Secret.json"
[[ ! -e "$SECRET_ROOT/.release" ]]
/usr/bin/jq '.marketingName = "Unreviewed Name"' \
  "$SECRET_ROOT/Config/ReleaseIdentity.json" > "$SECRET_ROOT/Config/Unknown.json"
expect_failure 'unknown top-level field(s): marketingName' \
  "$SECRET_ROOT/scripts/apply-release-identity.sh" "$SECRET_ROOT/Config/Unknown.json"

# Cross-target identifier and CloudKit wire-contract drift are hard failures.
DRIFT_ROOT="$(new_sandbox drift)"
/usr/bin/jq '.iOSWidgetBundleIdentifier = "com.agentisland.release.widget"' \
  "$DRIFT_ROOT/Config/ReleaseIdentity.json" > "$DRIFT_ROOT/Config/Widget.json"
expect_failure 'iOSWidgetBundleIdentifier must equal iOSAppBundleIdentifier + .liveactivity' \
  "$DRIFT_ROOT/scripts/apply-release-identity.sh" "$DRIFT_ROOT/Config/Widget.json"
/usr/bin/jq '.cloudKit.recordName = "newest"' \
  "$DRIFT_ROOT/Config/ReleaseIdentity.json" > "$DRIFT_ROOT/Config/CloudKit.json"
expect_failure 'must exactly match the private Production AgentIslandSnapshot/latest/payloadJSON contract' \
  "$DRIFT_ROOT/scripts/apply-release-identity.sh" "$DRIFT_ROOT/Config/CloudKit.json"

# Record mode is a real identity constraint, not documentation-only metadata.
# Universal Purchase shares the App identifier; separate records must not.
MODE_ROOT="$(new_sandbox modes)"
/usr/bin/jq '
  .appStoreRecordMode = "universal-purchase" |
  .iOSAppBundleIdentifier = "com.agentisland.mobile" |
  .iOSWidgetBundleIdentifier = "com.agentisland.mobile.liveactivity"
' "$MODE_ROOT/Config/ReleaseIdentity.json" > "$MODE_ROOT/Config/InvalidUniversal.json"
expect_failure 'universal-purchase requires macOSAppBundleIdentifier and iOSAppBundleIdentifier to match' \
  "$MODE_ROOT/scripts/apply-release-identity.sh" "$MODE_ROOT/Config/InvalidUniversal.json"
/usr/bin/jq '.appStoreRecordMode = "separate-records"' \
  "$MODE_ROOT/Config/ReleaseIdentity.json" > "$MODE_ROOT/Config/InvalidSeparate.json"
expect_failure 'separate-records requires macOSAppBundleIdentifier and iOSAppBundleIdentifier to differ' \
  "$MODE_ROOT/scripts/apply-release-identity.sh" "$MODE_ROOT/Config/InvalidSeparate.json"
/usr/bin/jq '.appStoreRecordMode = "one-record-per-platform"' \
  "$MODE_ROOT/Config/ReleaseIdentity.json" > "$MODE_ROOT/Config/InvalidMode.json"
expect_failure 'appStoreRecordMode must be universal-purchase or separate-records' \
  "$MODE_ROOT/scripts/apply-release-identity.sh" "$MODE_ROOT/Config/InvalidMode.json"

SEPARATE_ROOT="$(new_sandbox separate)"
write_v2_identity "$PROJECT_DIR/Tests/Fixtures/release-identity.valid.json" \
  "$SEPARATE_ROOT/Config/ReleaseIdentity.json" \
  separate-records com.agentisland.macosrelease com.agentisland.release
SEPARATE_OUTPUT="$($SEPARATE_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$SEPARATE_OUTPUT" | /usr/bin/jq -e '
  .identity.schemaVersion == 2 and
  .identity.appStoreRecordMode == "separate-records" and
  .identity.macOSAppBundleIdentifier == "com.agentisland.macosrelease" and
  .identity.iOSAppBundleIdentifier == "com.agentisland.release" and
  .identity.iOSWidgetBundleIdentifier == "com.agentisland.release.liveactivity"
' >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SEPARATE_ROOT/Resources/Info.plist")" == \
  "com.agentisland.macosrelease" ]]
/usr/bin/grep -Fqx 'AGENT_ISLAND_APP_BUNDLE_ID = com.agentisland.release' \
  "$SEPARATE_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/grep -Fqx 'AGENT_ISLAND_MAC_APP_BUNDLE_ID = com.agentisland.macosrelease' \
  "$SEPARATE_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"

# Schema v1 has one unambiguous meaning: shared Mac/iOS App ID. The checker
# reports the migration and a first apply records canonical schema v2.
LEGACY_ROOT="$(new_sandbox legacy v1)"
LEGACY_CHECK_OUTPUT="$($LEGACY_ROOT/scripts/apply-release-identity.sh --check)"
print -r -- "$LEGACY_CHECK_OUTPUT" | /usr/bin/jq -e '
  .inputSchemaVersion == 1 and .legacySchemaMigrated == true and
  .identity.schemaVersion == 2 and
  .identity.appStoreRecordMode == "universal-purchase" and
  .identity.macOSAppBundleIdentifier == .identity.iOSAppBundleIdentifier
' >/dev/null
$LEGACY_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
/usr/bin/jq -e '
  .identity.schemaVersion == 2 and
  .identity.appStoreRecordMode == "universal-purchase"
' "$LEGACY_ROOT/.release/identity.lock.json" >/dev/null

# A legacy schema-v1 identity payload with the same normalized identity remains
# a byte-for-byte no-op, preserving its original audit record.
LEGACY_LOCK_ROOT="$(new_sandbox legacy-lock)"
$LEGACY_LOCK_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
/usr/bin/jq -S '
  .identity = {
    schemaVersion: 1,
    primaryBundleIdentifier: .identity.macOSAppBundleIdentifier,
    widgetBundleIdentifier: .identity.iOSWidgetBundleIdentifier,
    teamIdentifier: .identity.teamIdentifier,
    iCloudContainerIdentifier: .identity.iCloudContainerIdentifier,
    cloudKit: .identity.cloudKit
  }
' "$LEGACY_LOCK_ROOT/.release/identity.lock.json" > \
  "$LEGACY_LOCK_ROOT/.release/identity.lock.legacy.json"
/bin/mv "$LEGACY_LOCK_ROOT/.release/identity.lock.legacy.json" \
  "$LEGACY_LOCK_ROOT/.release/identity.lock.json"
LEGACY_LOCK_SHA="$(sha256_file "$LEGACY_LOCK_ROOT/.release/identity.lock.json")"
LEGACY_LOCK_OUTPUT="$($LEGACY_LOCK_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$LEGACY_LOCK_OUTPUT" | /usr/bin/jq -e \
  '.changesApplied == [] and .lock.written == false' >/dev/null
[[ "$LEGACY_LOCK_SHA" == "$(sha256_file "$LEGACY_LOCK_ROOT/.release/identity.lock.json")" ]]
/bin/chmod 600 "$LEGACY_LOCK_ROOT/.release/identity.lock.json"
LEGACY_LOCK_READINESS="$(release_identity_report "$LEGACY_LOCK_ROOT")"
print -r -- "$LEGACY_LOCK_READINESS" | /usr/bin/jq -e '
  .releaseIdentityLockValid == true and
  .releaseIdentityInputSchemaVersion == 1 and
  .releaseIdentityNormalizedSchemaVersion == 2 and
  .releaseIdentityRecordMode == "universal-purchase" and
  .releaseIdentityMatchesConfiguration == true and
  .releaseIdentityReady == true
' >/dev/null

# A pre-v2 lock/backup is upgraded without overwriting its original baseline:
# the newly managed Mac config receives a separate recoverable supplement.
LEGACY_BACKUP_ROOT="$(new_sandbox legacy-backup v1)"
$LEGACY_BACKUP_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
/bin/mv \
  "$LEGACY_BACKUP_ROOT/.release/identity-backup/ApplePlatforms/macOS/Config/Project.xcconfig" \
  "$TEST_ROOT/pre-v2-mac-config.backup"
/usr/bin/jq -S '
  .identity = {
    schemaVersion: 1,
    primaryBundleIdentifier: .identity.macOSAppBundleIdentifier,
    widgetBundleIdentifier: .identity.iOSWidgetBundleIdentifier,
    teamIdentifier: .identity.teamIdentifier,
    iCloudContainerIdentifier: .identity.iCloudContainerIdentifier,
    cloudKit: .identity.cloudKit
  } |
  .appliedFiles = [.appliedFiles[] |
    select(.path != "ApplePlatforms/macOS/Config/Project.xcconfig")]
' "$LEGACY_BACKUP_ROOT/.release/identity.lock.json" > \
  "$LEGACY_BACKUP_ROOT/.release/identity.lock.pre-v2.json"
/bin/mv "$LEGACY_BACKUP_ROOT/.release/identity.lock.pre-v2.json" \
  "$LEGACY_BACKUP_ROOT/.release/identity.lock.json"
LEGACY_BACKUP_CHECK="$($LEGACY_BACKUP_ROOT/scripts/apply-release-identity.sh --check)"
print -r -- "$LEGACY_BACKUP_CHECK" | /usr/bin/jq -e '
  .writesPerformed == false and
  (.changes | index("identity-backup:schemaV2MacConfig") != null) and
  (.changes | index("identity.lock:macOSConfigBinding") != null)
' >/dev/null
[[ ! -e "$LEGACY_BACKUP_ROOT/.release/identity-backup/schema-v2-macos-config" ]]
LEGACY_BACKUP_APPLY="$($LEGACY_BACKUP_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$LEGACY_BACKUP_APPLY" | /usr/bin/jq -e '.lock.written == true' >/dev/null
[[ -f "$LEGACY_BACKUP_ROOT/.release/identity-backup/schema-v2-macos-config/ApplePlatforms/macOS/Config/Project.xcconfig" ]]
/usr/bin/jq -e '
  .identity.schemaVersion == 1 and
  (.appliedFiles | any(.path == "ApplePlatforms/macOS/Config/Project.xcconfig"))
' "$LEGACY_BACKUP_ROOT/.release/identity.lock.json" >/dev/null
LEGACY_BACKUP_SECOND="$($LEGACY_BACKUP_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$LEGACY_BACKUP_SECOND" | /usr/bin/jq -e \
  '.changesApplied == [] and .lock.written == false' >/dev/null

# Unknown schema versions fail with an actionable migration path.
/usr/bin/jq '.schemaVersion = 3' \
  "$MODE_ROOT/Config/ReleaseIdentity.json" > "$MODE_ROOT/Config/FutureSchema.json"
expect_failure 'use schemaVersion 2 from Config/ReleaseIdentity.example.json' \
  "$MODE_ROOT/scripts/apply-release-identity.sh" "$MODE_ROOT/Config/FutureSchema.json"

# A profile is never treated as a plist fixture or trusted path. Until an
# Apple-signed CMS profile validates, no final entitlements can be produced.
PROFILE_ROOT="$(new_sandbox profile)"
expect_failure 'not a decodable Apple-signed CMS profile' \
  "$PROFILE_ROOT/scripts/apply-release-identity.sh" --apply --profile \
  "$PROFILE_ROOT/Config/ReleaseIdentity.json"
[[ ! -e "$PROFILE_ROOT/.release" ]]
[[ ! -e "$PROFILE_ROOT/.release/CloudKit.entitlements" ]]

# Readiness accepts an identity applied without Developer ID material only when
# the lock records both profile-derived assets as null and no orphan generated
# entitlements exist. This preserves the safe first-apply workflow for the App
# Store targets without letting Developer ID readiness borrow unlocked files.
READINESS_NULL_ROOT="$(new_sandbox readiness-null)"
$READINESS_NULL_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
READINESS_NULL_REPORT="$(release_identity_report "$READINESS_NULL_ROOT")"
print -r -- "$READINESS_NULL_REPORT" | /usr/bin/jq -e '
  .releaseIdentityLockValid == true and
  .releaseIdentityAuxiliaryFilesMatch == true and
  .releaseIdentityProfileRecordsPresent == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true
' >/dev/null

# Explicit iOS environment identifiers are part of the current identity. A
# value that differs from the locked and applied configuration closes the core
# identity gate even when the lock and all three file hashes remain valid.
READINESS_WRONG_IOS_APP_REPORT="$(release_identity_report \
  "$READINESS_NULL_ROOT" "" "" "" \
  "com.agentisland.other" "com.agentisland.release.liveactivity")"
print -r -- "$READINESS_WRONG_IOS_APP_REPORT" | /usr/bin/jq -e '
  .releaseIdentityLockValid == true and
  .releaseIdentityAppliedFilesMatch == true and
  .releaseIdentityMatchesConfiguration == false and
  .releaseIdentityReady == false
' >/dev/null
READINESS_WRONG_IOS_WIDGET_REPORT="$(release_identity_report \
  "$READINESS_NULL_ROOT" "" "" "" \
  "com.agentisland.release" "com.agentisland.other.liveactivity")"
print -r -- "$READINESS_WRONG_IOS_WIDGET_REPORT" | /usr/bin/jq -e '
  .releaseIdentityLockValid == true and
  .releaseIdentityAppliedFilesMatch == true and
  .releaseIdentityMatchesConfiguration == false and
  .releaseIdentityReady == false
' >/dev/null

# Build a deterministic profile fixture and replace security(1) and xcrun(1)
# only inside these disposable script copies. The production scripts remain
# pinned to the system tools; the stubs exercise both the real profile apply
# path and the complete positive Developer ID gate without an Apple account.
PROFILE_BIND_ROOT="$(new_sandbox readiness-profile-binding)"
$PROFILE_BIND_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
install_security_stub "$PROFILE_BIND_ROOT"
PROFILE_DECODED_JSON="$PROFILE_BIND_ROOT/Tests/Fixtures/profile-decoded.json"
PROFILE_DECODED_GOOD="$PROFILE_BIND_ROOT/Tests/Fixtures/profile-decoded.plist"
PROFILE_FILE="$PROFILE_BIND_ROOT/Tests/Fixtures/DeveloperID.provisionprofile"
PROFILE_FILE_GOOD="$PROFILE_BIND_ROOT/Tests/Fixtures/DeveloperID.good.provisionprofile"
LOCKED_ENTITLEMENTS="$PROFILE_BIND_ROOT/.release/CloudKit.entitlements"
LOCKED_ENTITLEMENTS_GOOD="$PROFILE_BIND_ROOT/Tests/Fixtures/CloudKit.good.entitlements"
LOCK_BASELINE="$PROFILE_BIND_ROOT/Tests/Fixtures/identity.lock.profile-bound.json"
/usr/bin/jq -n '{
  Name: "AgentIsland Developer ID Fixture",
  UUID: "11111111-2222-3333-4444-555555555555",
  ExpirationDate: "2035-01-01T00:00:00Z",
  ApplicationIdentifierPrefix: ["LEGACY1234"],
  TeamIdentifier: ["ABCDE12345"],
  Platform: ["OSX"],
  ProvisionsAllDevices: true,
  DeveloperCertificates: ["ZmFrZQ=="],
  Entitlements: {
    "com.apple.application-identifier":
      "LEGACY1234.com.agentisland.release",
    "com.apple.developer.team-identifier": "ABCDE12345",
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-identifiers":
      ["iCloud.com.agentisland.releasefixture"],
    "com.apple.developer.icloud-container-environment": "Production"
  }
}' > "$PROFILE_DECODED_JSON"
/usr/bin/plutil -convert xml1 -o "$PROFILE_DECODED_GOOD" "$PROFILE_DECODED_JSON"
/bin/cp "$PROFILE_DECODED_GOOD" "$PROFILE_FILE"
/bin/cp "$PROFILE_FILE" "$PROFILE_FILE_GOOD"

# The check path performs the complete CMS/profile validation but cannot write
# either generated entitlements or new profile records into the existing lock.
PROFILE_CHECK_LOCK_SHA="$(sha256_file \
  "$PROFILE_BIND_ROOT/.release/identity.lock.json")"
PROFILE_CHECK_OUTPUT="$(AGENT_ISLAND_TEST_DECODED_PROFILE="$PROFILE_DECODED_GOOD" \
  "$PROFILE_BIND_ROOT/scripts/apply-release-identity.sh" --check --profile \
  "$PROFILE_FILE")"
print -r -- "$PROFILE_CHECK_OUTPUT" | /usr/bin/jq -e '
  .mode == "check" and .valid == true and .writesPerformed == false and
  .lock.exists == true and
  .provisioningProfile == {
    supplied: true,
    validated: true,
    applicationIdentifier: "LEGACY1234.com.agentisland.release",
    appIDPrefix: "LEGACY1234"
  } and
  .finalEntitlements == {
    path: ".release/CloudKit.entitlements",
    wouldGenerate: true,
    appIDPrefixGuessed: false
  } and
  (.changes | index(".release/CloudKit.entitlements") != null)
' >/dev/null
[[ ! -e "$LOCKED_ENTITLEMENTS" ]]
[[ "$PROFILE_CHECK_LOCK_SHA" == "$(sha256_file \
  "$PROFILE_BIND_ROOT/.release/identity.lock.json")" ]]

# The apply path itself now produces the profile-bound lock and entitlement
# fixture consumed by every readiness and drift assertion below.
PROFILE_APPLY_OUTPUT="$(AGENT_ISLAND_TEST_DECODED_PROFILE="$PROFILE_DECODED_GOOD" \
  "$PROFILE_BIND_ROOT/scripts/apply-release-identity.sh" --apply --profile \
  "$PROFILE_FILE")"
print -r -- "$PROFILE_APPLY_OUTPUT" | /usr/bin/jq -e '
  .mode == "apply" and .valid == true and
  .lock == {path: ".release/identity.lock.json", written: true} and
  .provisioningProfile == {
    supplied: true,
    validated: true,
    applicationIdentifier: "LEGACY1234.com.agentisland.release"
  } and
  .finalEntitlements == {
    path: ".release/CloudKit.entitlements",
    generated: true,
    appIDPrefixGuessed: false
  } and
  (.changesApplied | index(".release/CloudKit.entitlements") != null)
' >/dev/null
[[ -f "$LOCKED_ENTITLEMENTS" && ! -L "$LOCKED_ENTITLEMENTS" ]]
PROFILE_SHA="$(sha256_file "$PROFILE_FILE")"
ENTITLEMENTS_SHA="$(sha256_file "$LOCKED_ENTITLEMENTS")"
/usr/bin/jq -e \
  --arg profileSHA "$PROFILE_SHA" \
  --arg entitlementsSHA "$ENTITLEMENTS_SHA" '
  .provisioningProfile == {
    sha256: $profileSHA,
    uuid: "11111111-2222-3333-4444-555555555555",
    name: "AgentIsland Developer ID Fixture",
    expiration: "2035-01-01T00:00:00Z",
    applicationIdentifier: "LEGACY1234.com.agentisland.release",
    appIDPrefix: "LEGACY1234"
  } and
  .generatedEntitlements == {
    path: ".release/CloudKit.entitlements",
    sha256: $entitlementsSHA
  } and
  (.appliedFiles | length) == 3
' "$PROFILE_BIND_ROOT/.release/identity.lock.json" >/dev/null
/usr/bin/plutil -convert json -o - "$LOCKED_ENTITLEMENTS" | /usr/bin/jq -e '
  . == {
    "com.apple.application-identifier":
      "LEGACY1234.com.agentisland.release",
    "com.apple.developer.team-identifier": "ABCDE12345",
    "com.apple.developer.icloud-container-identifiers":
      ["iCloud.com.agentisland.releasefixture"],
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-services": ["CloudKit"]
  }
' >/dev/null
/bin/cp "$LOCKED_ENTITLEMENTS" "$LOCKED_ENTITLEMENTS_GOOD"
/bin/cp "$PROFILE_BIND_ROOT/.release/identity.lock.json" "$LOCK_BASELINE"

PROFILE_LOCK_SHA="$(sha256_file "$PROFILE_BIND_ROOT/.release/identity.lock.json")"
PROFILE_SECOND_OUTPUT="$(AGENT_ISLAND_TEST_DECODED_PROFILE="$PROFILE_DECODED_GOOD" \
  "$PROFILE_BIND_ROOT/scripts/apply-release-identity.sh" --apply --profile \
  "$PROFILE_FILE")"
print -r -- "$PROFILE_SECOND_OUTPUT" | /usr/bin/jq -e '
  .mode == "apply" and .valid == true and
  .changesApplied == [] and .lock.written == false
' >/dev/null
[[ "$PROFILE_SHA" == "$(sha256_file "$PROFILE_FILE")" ]]
[[ "$ENTITLEMENTS_SHA" == "$(sha256_file "$LOCKED_ENTITLEMENTS")" ]]
[[ "$PROFILE_LOCK_SHA" == "$(sha256_file \
  "$PROFILE_BIND_ROOT/.release/identity.lock.json")" ]]

# Profile-bound Developer ID material is an independent channel gate. The core
# identity remains ready without machine-local profile/entitlement arguments,
# while Developer ID readiness stays closed.
PROFILE_BOUND_WITHOUT_ASSETS_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT")"
print -r -- "$PROFILE_BOUND_WITHOUT_ASSETS_REPORT" | /usr/bin/jq -e '
  .releaseIdentityLockValid == true and
  .releaseIdentityAppliedFilesMatch == true and
  .releaseIdentityMatchesConfiguration == true and
  .releaseIdentityProfileRecordsPresent == true and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null

PROFILE_BOUND_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$PROFILE_BOUND_REPORT" | /usr/bin/jq -e '
  .cloudKitEntitlementsConfigured == true and
  .provisioningProfileConfigured == true and
  .releaseIdentityLockValid == true and
  .releaseIdentityProfileRecordsPresent == true and
  .releaseIdentityAuxiliaryFilesMatch == true and
  .releaseIdentityProfileAssetsMatch == true and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == true
' >/dev/null

# The profile bytes and generated entitlement bytes are both content-addressed.
# Semantically valid replacements with different bytes cannot satisfy the lock.
/usr/bin/printf '\n' >> "$PROFILE_FILE"
PROFILE_HASH_DRIFT_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$PROFILE_HASH_DRIFT_REPORT" | /usr/bin/jq -e '
  .provisioningProfileConfigured == true and
  .releaseIdentityLockValid == true and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null
/bin/cp "$PROFILE_FILE_GOOD" "$PROFILE_FILE"
/usr/bin/printf '\n' >> "$LOCKED_ENTITLEMENTS"
ENTITLEMENTS_HASH_DRIFT_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$ENTITLEMENTS_HASH_DRIFT_REPORT" | /usr/bin/jq -e '
  .cloudKitEntitlementsConfigured == true and
  .releaseIdentityLockValid == true and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null
/bin/cp "$LOCKED_ENTITLEMENTS_GOOD" "$LOCKED_ENTITLEMENTS"

# A copied entitlement file is not the locked project path, and neither the
# profile nor generated entitlement may reach readiness through a symlink.
ENTITLEMENTS_COPY="$PROFILE_BIND_ROOT/Tests/Fixtures/CloudKit.copy.entitlements"
/bin/cp "$LOCKED_ENTITLEMENTS" "$ENTITLEMENTS_COPY"
ENTITLEMENTS_PATH_DRIFT_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$ENTITLEMENTS_COPY" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$ENTITLEMENTS_PATH_DRIFT_REPORT" | /usr/bin/jq -e '
  .cloudKitEntitlementsConfigured == true and
  .provisioningProfileConfigured == true and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null
/bin/mv "$LOCKED_ENTITLEMENTS" "$PROFILE_BIND_ROOT/Tests/Fixtures/CloudKit.real.entitlements"
/bin/ln -s "$PROFILE_BIND_ROOT/Tests/Fixtures/CloudKit.real.entitlements" \
  "$LOCKED_ENTITLEMENTS"
ENTITLEMENTS_SYMLINK_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$ENTITLEMENTS_SYMLINK_REPORT" | /usr/bin/jq -e '
  .cloudKitEntitlementsConfigured == false and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null
/bin/rm -f "$LOCKED_ENTITLEMENTS"
/bin/mv "$PROFILE_BIND_ROOT/Tests/Fixtures/CloudKit.real.entitlements" \
  "$LOCKED_ENTITLEMENTS"
/bin/mv "$PROFILE_FILE" "$PROFILE_BIND_ROOT/Tests/Fixtures/DeveloperID.real.provisionprofile"
/bin/ln -s "$PROFILE_BIND_ROOT/Tests/Fixtures/DeveloperID.real.provisionprofile" \
  "$PROFILE_FILE"
PROFILE_SYMLINK_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$PROFILE_SYMLINK_REPORT" | /usr/bin/jq -e '
  .provisioningProfileConfigured == false and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null
/bin/rm -f "$PROFILE_FILE"
/bin/mv "$PROFILE_BIND_ROOT/Tests/Fixtures/DeveloperID.real.provisionprofile" \
  "$PROFILE_FILE"

# The decoded profile's authoritative top-level prefix must be the same prefix
# recorded in the lock and used by its exact macOS application identifier.
PROFILE_DECODED_WRONG_PREFIX="$PROFILE_BIND_ROOT/Tests/Fixtures/profile-wrong-prefix.plist"
/bin/cp "$PROFILE_DECODED_GOOD" "$PROFILE_DECODED_WRONG_PREFIX"
/usr/bin/plutil -replace ApplicationIdentifierPrefix.0 -string WRONGP1234 \
  "$PROFILE_DECODED_WRONG_PREFIX"
PROFILE_PREFIX_DRIFT_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_WRONG_PREFIX")"
print -r -- "$PROFILE_PREFIX_DRIFT_REPORT" | /usr/bin/jq -e '
  .provisioningProfileConfigured == false and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityProfileAssetsMatch == false and
  .releaseIdentityReady == true and
  .readyForDeveloperIDRelease == false
' >/dev/null

# The lock cannot redirect generated entitlements through a normalized-looking
# traversal, even when the target bytes and environment remain otherwise valid.
/usr/bin/jq -S '
  .generatedEntitlements.path =
    ".release/../.release/CloudKit.entitlements"
' "$LOCK_BASELINE" > "$PROFILE_BIND_ROOT/.release/identity.lock.json"
/bin/chmod 600 "$PROFILE_BIND_ROOT/.release/identity.lock.json"
ENTITLEMENTS_ESCAPE_REPORT="$(release_identity_report \
  "$PROFILE_BIND_ROOT" "$PROFILE_FILE" "$LOCKED_ENTITLEMENTS" \
  "$PROFILE_DECODED_GOOD")"
print -r -- "$ENTITLEMENTS_ESCAPE_REPORT" | /usr/bin/jq -e '
  .releaseIdentityLockValid == false and
  .releaseIdentityAuxiliaryFilesMatch == false and
  .releaseIdentityReady == false
' >/dev/null
/bin/cp "$LOCK_BASELINE" "$PROFILE_BIND_ROOT/.release/identity.lock.json"
/bin/chmod 600 "$PROFILE_BIND_ROOT/.release/identity.lock.json"

for profile_marker in \
  'ApplicationIdentifierPrefix.0' \
  'PROFILE_APP_IDENTIFIER" == "$PROFILE_APP_ID_PREFIX.$MAC_BUNDLE_ID' \
  'exactly identify macOSAppBundleIdentifier'; do
  /usr/bin/grep -Fq -- "$profile_marker" "$PROJECT_DIR/scripts/apply-release-identity.sh" \
    || { print -u2 -- "Missing strict macOS profile marker: $profile_marker"; exit 1; }
done

[[ "$(/usr/bin/grep -Fc 'PRODUCT_BUNDLE_IDENTIFIER = "$(AGENT_ISLAND_MAC_APP_BUNDLE_ID)";' \
  "$PROJECT_DIR/ApplePlatforms/macOS/AgentIslandMac.xcodeproj/project.pbxproj")" == 2 ]]
if /usr/bin/grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = "$(AGENT_ISLAND_APP_BUNDLE_ID)";' \
    "$PROJECT_DIR/ApplePlatforms/macOS/AgentIslandMac.xcodeproj/project.pbxproj"; then
  print -u2 -- "macOS target still points at the iOS App bundle identifier"
  exit 1
fi

print -- "Release identity tests passed"
