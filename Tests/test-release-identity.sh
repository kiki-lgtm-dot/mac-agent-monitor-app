#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-identity-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

sha256_file() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

new_sandbox() {
  local name="$1"
  local root="$TEST_ROOT/$name"
  /bin/mkdir -p "$root/scripts" "$root/Config" "$root/Resources" \
    "$root/ApplePlatforms/iOS/Config" "$root/Tests/Fixtures"
  /bin/cp "$PROJECT_DIR/scripts/apply-release-identity.sh" "$root/scripts/apply-release-identity.sh"
  /bin/chmod 755 "$root/scripts/apply-release-identity.sh"
  /bin/cp "$PROJECT_DIR/Resources/Info.plist" "$root/Resources/Info.plist"
  /bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig" \
    "$root/ApplePlatforms/iOS/Config/Project.xcconfig"
  /bin/cp "$PROJECT_DIR/Tests/Fixtures/release-identity.valid.json" \
    "$root/Config/ReleaseIdentity.json"
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

# Default --check validates and describes changes but cannot touch the tree.
CHECK_ROOT="$(new_sandbox check)"
CHECK_MAC_BEFORE="$(sha256_file "$CHECK_ROOT/Resources/Info.plist")"
CHECK_IOS_BEFORE="$(sha256_file "$CHECK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
CHECK_OUTPUT="$($CHECK_ROOT/scripts/apply-release-identity.sh)"
print -r -- "$CHECK_OUTPUT" | /usr/bin/jq -e '
  .mode == "check" and .valid == true and .writesPerformed == false and
  .lock.exists == false and
  .provisioningProfile.supplied == false and
  .finalEntitlements.wouldGenerate == false and
  .finalEntitlements.appIDPrefixGuessed == false and
  (.changes | index("Resources/Info.plist:CFBundleIdentifier") != null)
' >/dev/null
[[ ! -e "$CHECK_ROOT/.release" ]]
[[ "$CHECK_MAC_BEFORE" == "$(sha256_file "$CHECK_ROOT/Resources/Info.plist")" ]]
[[ "$CHECK_IOS_BEFORE" == "$(sha256_file "$CHECK_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]

# First apply updates only the identity-bearing plist/xcconfig, creates a
# permanent baseline backup and lock, and does not invent final entitlements.
APPLY_ROOT="$(new_sandbox apply)"
ORIGINAL_MAC_SHA="$(sha256_file "$APPLY_ROOT/Resources/Info.plist")"
ORIGINAL_IOS_SHA="$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
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
[[ -f "$APPLY_ROOT/.release/identity.lock.json" ]]
[[ -f "$APPLY_ROOT/.release/identity-backup/manifest.json" ]]
[[ ! -e "$APPLY_ROOT/.release/CloudKit.entitlements" ]]
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .identity.widgetBundleIdentifier == (.identity.primaryBundleIdentifier + ".liveactivity") and
  .identity.cloudKit == {
    databaseScope: "private",
    environment: "Production",
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON"
  } and
  .provisioningProfile == null and .generatedEntitlements == null
' "$APPLY_ROOT/.release/identity.lock.json" >/dev/null
[[ "$ORIGINAL_MAC_SHA" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/Resources/Info.plist")" ]]
[[ "$ORIGINAL_IOS_SHA" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]

# Reapplying the same identity is a true no-op at the content/lock level and
# preserves the one-time baseline backup.
LOCK_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/.release/identity.lock.json")"
BACKUP_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/.release/identity-backup/manifest.json")"
MAC_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/Resources/Info.plist")"
IOS_SHA_BEFORE="$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
MAC_INODE_BEFORE="$(/usr/bin/stat -f %i "$APPLY_ROOT/Resources/Info.plist")"
IOS_INODE_BEFORE="$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
SECOND_OUTPUT="$($APPLY_ROOT/scripts/apply-release-identity.sh --apply)"
print -r -- "$SECOND_OUTPUT" | /usr/bin/jq -e '.changesApplied == [] and .lock.written == false' >/dev/null
[[ "$LOCK_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/.release/identity.lock.json")" ]]
[[ "$BACKUP_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/.release/identity-backup/manifest.json")" ]]
[[ "$MAC_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$IOS_SHA_BEFORE" == "$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]
[[ "$MAC_INODE_BEFORE" == "$(/usr/bin/stat -f %i "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$IOS_INODE_BEFORE" == "$(/usr/bin/stat -f %i "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]

# The baseline is actually usable for manual recovery.
/bin/cp "$APPLY_ROOT/.release/identity-backup/Resources/Info.plist" "$APPLY_ROOT/Resources/Info.plist"
/bin/cp "$APPLY_ROOT/.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig" \
  "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
[[ "$ORIGINAL_MAC_SHA" == "$(sha256_file "$APPLY_ROOT/Resources/Info.plist")" ]]
[[ "$ORIGINAL_IOS_SHA" == "$(sha256_file "$APPLY_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")" ]]

# The lock prevents accidental mutation of irreversible identifiers.
LOCK_ROOT="$(new_sandbox lock)"
$LOCK_ROOT/scripts/apply-release-identity.sh --apply >/dev/null
/usr/bin/jq '.primaryBundleIdentifier = "com.agentisland.changed" | .widgetBundleIdentifier = "com.agentisland.changed.liveactivity"' \
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
/usr/bin/jq '.widgetBundleIdentifier = "com.agentisland.release.widget"' \
  "$DRIFT_ROOT/Config/ReleaseIdentity.json" > "$DRIFT_ROOT/Config/Widget.json"
expect_failure 'widgetBundleIdentifier must equal primaryBundleIdentifier + .liveactivity' \
  "$DRIFT_ROOT/scripts/apply-release-identity.sh" "$DRIFT_ROOT/Config/Widget.json"
/usr/bin/jq '.cloudKit.recordName = "newest"' \
  "$DRIFT_ROOT/Config/ReleaseIdentity.json" > "$DRIFT_ROOT/Config/CloudKit.json"
expect_failure 'must exactly match the private Production AgentIslandSnapshot/latest/payloadJSON contract' \
  "$DRIFT_ROOT/scripts/apply-release-identity.sh" "$DRIFT_ROOT/Config/CloudKit.json"

# A profile is never treated as a plist fixture or trusted path. Until an
# Apple-signed CMS profile validates, no final entitlements can be produced.
PROFILE_ROOT="$(new_sandbox profile)"
expect_failure 'not a decodable Apple-signed CMS profile' \
  "$PROFILE_ROOT/scripts/apply-release-identity.sh" --apply --profile \
  "$PROFILE_ROOT/Config/ReleaseIdentity.json"
[[ ! -e "$PROFILE_ROOT/.release" ]]
[[ ! -e "$PROFILE_ROOT/.release/CloudKit.entitlements" ]]

print -- "Release identity tests passed"
