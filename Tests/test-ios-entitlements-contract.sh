#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
CONTRACT="$PROJECT_ROOT/ApplePlatforms/iOS/scripts/ios-entitlements-contract.jq"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentisland-ios-entitlements.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "iOS entitlement contract test failed: $*"
  exit 1
}

[[ -f "$CONTRACT" && ! -L "$CONTRACT" ]] \
  || fail "shared entitlement contract is missing or is a symlink"
command -v jq >/dev/null 2>&1 || fail "jq is required"

TEAM_ID="ABCDE12345"
APP_IDENTIFIER="$TEAM_ID.com.agentisland.release"
WIDGET_IDENTIFIER="$APP_IDENTIFIER.liveactivity"
CLOUD_CONTAINER="iCloud.com.agentisland.release"
SOURCE_CONTAINER='$(AGENT_ISLAND_ICLOUD_CONTAINER_ID)'

contract_accepts() {
  local mode="$1"
  local input="$2"
  local identifier="$3"
  local team="$4"
  local container="$5"
  /usr/bin/jq -e \
    --arg mode "$mode" \
    --arg identifier "$identifier" \
    --arg team "$team" \
    --arg container "$container" \
    -f "$CONTRACT" "$input" >/dev/null
}

expect_accepted() {
  local label="$1"
  shift
  contract_accepts "$@" \
    || fail "$label should have been accepted"
}

expect_rejected() {
  local label="$1"
  shift
  if contract_accepts "$@" 2>/dev/null; then
    fail "$label should have been rejected"
  fi
}

mutate() {
  local source="$1"
  local filter="$2"
  local output="$3"
  /usr/bin/jq "$filter" "$source" >"$output"
}

SOURCE_APP="$TEST_ROOT/source-app.json"
/usr/bin/jq -n --arg container "$SOURCE_CONTAINER" '{
  "com.apple.developer.icloud-container-identifiers": [$container],
  "com.apple.developer.icloud-services": ["CloudKit"]
}' >"$SOURCE_APP"

SIGNED_APP="$TEST_ROOT/signed-app.json"
/usr/bin/jq -n \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER" '{
  "application-identifier": $identifier,
  "com.apple.developer.team-identifier": $team,
  "get-task-allow": false,
  "com.apple.developer.icloud-container-identifiers": [$container],
  "com.apple.developer.icloud-services": ["CloudKit"],
  "com.apple.developer.icloud-container-environment": "Production"
}' >"$SIGNED_APP"

SIGNED_APP_APPLE_FIELDS="$TEST_ROOT/signed-app-apple-fields.json"
/usr/bin/jq \
  --arg identifier "$APP_IDENTIFIER" \
  '. + {
    "beta-reports-active": true,
    "keychain-access-groups": [$identifier]
  }' "$SIGNED_APP" >"$SIGNED_APP_APPLE_FIELDS"

SIGNED_WIDGET="$TEST_ROOT/signed-widget.json"
/usr/bin/jq -n \
  --arg identifier "$WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '{
  "application-identifier": $identifier,
  "com.apple.developer.team-identifier": $team,
  "get-task-allow": false
}' >"$SIGNED_WIDGET"

SIGNED_WIDGET_APPLE_FIELDS="$TEST_ROOT/signed-widget-apple-fields.json"
/usr/bin/jq \
  --arg identifier "$WIDGET_IDENTIFIER" \
  '. + {
    "beta-reports-active": true,
    "keychain-access-groups": [$identifier]
  }' "$SIGNED_WIDGET" >"$SIGNED_WIDGET_APPLE_FIELDS"

PROFILE_APP="$TEST_ROOT/profile-app.json"
/usr/bin/jq -n \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER" '{
  "application-identifier": $identifier,
  "com.apple.developer.team-identifier": $team,
  "get-task-allow": false,
  "beta-reports-active": true,
  "keychain-access-groups": [($team + ".*"), "com.apple.token"],
  "com.apple.developer.icloud-container-identifiers": [$container],
  "com.apple.developer.icloud-services": ["CloudKit"],
  "com.apple.developer.icloud-container-environment": "Production"
}' >"$PROFILE_APP"

PROFILE_APP_BROAD="$TEST_ROOT/profile-app-broad.json"
/usr/bin/jq \
  --arg container "$CLOUD_CONTAINER" \
  '. + {
    "com.apple.developer.icloud-container-identifiers": [
      $container,
      "iCloud.com.agentisland.profile-only"
    ],
    "com.apple.developer.icloud-container-development-container-identifiers": [$container],
    "com.apple.developer.icloud-services": "*",
    "com.apple.developer.icloud-container-environment": ["Development", "Production"],
    "com.apple.developer.default-data-protection":
      "NSFileProtectionCompleteUntilFirstUserAuthentication"
  }' "$PROFILE_APP" >"$PROFILE_APP_BROAD"

PROFILE_WIDGET="$TEST_ROOT/profile-widget.json"
/usr/bin/jq -n \
  --arg identifier "$WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '{
  "application-identifier": $identifier,
  "com.apple.developer.team-identifier": $team,
  "get-task-allow": false,
  "beta-reports-active": true,
  "keychain-access-groups": [($team + ".*"), "com.apple.token"]
}' >"$PROFILE_WIDGET"

PROFILE_WIDGET_WITH_APPLE_MANAGED_EXTRA="$TEST_ROOT/profile-widget-extra.json"
/usr/bin/jq '. + {
  "com.apple.developer.default-data-protection":
    "NSFileProtectionCompleteUntilFirstUserAuthentication"
}' "$PROFILE_WIDGET" >"$PROFILE_WIDGET_WITH_APPLE_MANAGED_EXTRA"

expect_accepted "exact App source entitlements" \
  source-app "$SOURCE_APP" "" "" "$SOURCE_CONTAINER"
expect_accepted "minimal production App signature" \
  signed-app "$SIGNED_APP" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
expect_accepted "App signature with Apple-managed baseline fields" \
  signed-app "$SIGNED_APP_APPLE_FIELDS" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
expect_accepted "minimal Widget signature" \
  signed-widget "$SIGNED_WIDGET" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
expect_accepted "Widget signature with Apple-managed baseline fields" \
  signed-widget "$SIGNED_WIDGET_APPLE_FIELDS" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
expect_accepted "ordinary App Store App profile" \
  profile-app "$PROFILE_APP" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
expect_accepted "broader Apple-managed App profile authorization" \
  profile-app "$PROFILE_APP_BROAD" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
expect_accepted "ordinary App Store Widget profile" \
  profile-widget "$PROFILE_WIDGET" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
expect_accepted "Widget profile with unrelated Apple-managed authorization" \
  profile-widget "$PROFILE_WIDGET_WITH_APPLE_MANAGED_EXTRA" \
  "$WIDGET_IDENTIFIER" "$TEAM_ID" ""

CANDIDATE="$TEST_ROOT/candidate.json"

mutate "$SOURCE_APP" '.["aps-environment"] = "production"' "$CANDIDATE"
expect_rejected "source App APNs privilege" \
  source-app "$CANDIDATE" "" "" "$SOURCE_CONTAINER"
mutate "$SOURCE_APP" \
  '.["com.apple.security.application-groups"] = ["group.example"]' "$CANDIDATE"
expect_rejected "source App Group privilege" \
  source-app "$CANDIDATE" "" "" "$SOURCE_CONTAINER"
mutate "$SOURCE_APP" \
  '.["com.apple.developer.ubiquity-kvstore-identifier"] = "ABCDE12345.example"' \
  "$CANDIDATE"
expect_rejected "source App iCloud key-value privilege" \
  source-app "$CANDIDATE" "" "" "$SOURCE_CONTAINER"
mutate "$SOURCE_APP" \
  '.["com.apple.developer.icloud-services"] = ["CloudKit", "CloudDocuments"]' \
  "$CANDIDATE"
expect_rejected "source App extra iCloud service" \
  source-app "$CANDIDATE" "" "" "$SOURCE_CONTAINER"

mutate "$SIGNED_APP_APPLE_FIELDS" '.["aps-environment"] = "production"' "$CANDIDATE"
expect_rejected "signed App APNs privilege" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" \
  '.["com.apple.security.application-groups"] = ["group.example"]' "$CANDIDATE"
expect_rejected "signed App Group privilege" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" \
  '.["com.apple.developer.icloud-container-environment"] = "Development"' "$CANDIDATE"
expect_rejected "signed App development CloudKit environment" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" \
  '.["com.apple.developer.icloud-services"] += ["CloudDocuments"]' "$CANDIDATE"
expect_rejected "signed App extra iCloud service" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" \
  '.["com.apple.developer.icloud-container-identifiers"] += ["iCloud.extra"]' \
  "$CANDIDATE"
expect_rejected "signed App extra CloudKit container" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" \
  '.["keychain-access-groups"] = ["ABCDE12345.shared"]' "$CANDIDATE"
expect_rejected "signed App custom keychain group" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" '.["beta-reports-active"] = false' "$CANDIDATE"
expect_rejected "signed App false beta entitlement" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$SIGNED_APP_APPLE_FIELDS" '.["get-task-allow"] = true' "$CANDIDATE"
expect_rejected "signed App debugger entitlement" \
  signed-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"

mutate "$SIGNED_WIDGET_APPLE_FIELDS" \
  '.["com.apple.developer.icloud-services"] = ["CloudKit"]' "$CANDIDATE"
expect_rejected "signed Widget CloudKit privilege" \
  signed-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$SIGNED_WIDGET_APPLE_FIELDS" \
  '.["com.apple.developer.ubiquity-kvstore-identifier"] = "ABCDE12345.example"' \
  "$CANDIDATE"
expect_rejected "signed Widget iCloud key-value privilege" \
  signed-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$SIGNED_WIDGET_APPLE_FIELDS" '.["aps-environment"] = "production"' "$CANDIDATE"
expect_rejected "signed Widget APNs privilege" \
  signed-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$SIGNED_WIDGET_APPLE_FIELDS" \
  '.["com.apple.security.application-groups"] = ["group.example"]' "$CANDIDATE"
expect_rejected "signed Widget App Group privilege" \
  signed-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$SIGNED_WIDGET_APPLE_FIELDS" \
  '.["keychain-access-groups"] = ["ABCDE12345.shared"]' "$CANDIDATE"
expect_rejected "signed Widget custom keychain group" \
  signed-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""

mutate "$PROFILE_APP" 'del(.["beta-reports-active"])' "$CANDIDATE"
expect_rejected "App profile without App Store beta authorization" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" '.["get-task-allow"] = true' "$CANDIDATE"
expect_rejected "App development profile" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" \
  '.["application-identifier"] = "ABCDE12345.com.wrong.app"' "$CANDIDATE"
expect_rejected "App profile for another App ID" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" \
  '.["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other"]' \
  "$CANDIDATE"
expect_rejected "App profile missing expected CloudKit container" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" \
  '.["com.apple.developer.icloud-services"] = ["CloudDocuments"]' "$CANDIDATE"
expect_rejected "App profile missing CloudKit service authorization" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" \
  '.["com.apple.developer.icloud-container-environment"] = ["Development"]' \
  "$CANDIDATE"
expect_rejected "App profile missing Production environment authorization" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"
mutate "$PROFILE_APP" \
  '.["keychain-access-groups"] = ["ZZZZZ99999.*", "com.apple.token"]' \
  "$CANDIDATE"
expect_rejected "App profile that cannot authorize the default keychain group" \
  profile-app "$CANDIDATE" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"

mutate "$PROFILE_WIDGET" \
  '.["com.apple.developer.icloud-container-identifiers"] = ["iCloud.example"]' \
  "$CANDIDATE"
expect_rejected "Widget profile with iCloud authorization" \
  profile-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$PROFILE_WIDGET" \
  '.["com.apple.developer.ubiquity-kvstore-identifier"] = "ABCDE12345.example"' \
  "$CANDIDATE"
expect_rejected "Widget profile with ubiquity authorization" \
  profile-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$PROFILE_WIDGET" '.["get-task-allow"] = true' "$CANDIDATE"
expect_rejected "Widget development profile" \
  profile-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""
mutate "$PROFILE_WIDGET" \
  '.["com.apple.developer.team-identifier"] = "ZZZZZ99999"' "$CANDIDATE"
expect_rejected "Widget profile for another team" \
  profile-widget "$CANDIDATE" "$WIDGET_IDENTIFIER" "$TEAM_ID" ""

expect_rejected "unknown contract mode" \
  future-mode "$SIGNED_APP" "$APP_IDENTIFIER" "$TEAM_ID" "$CLOUD_CONTAINER"

print -r -- "iOS entitlement contract tests passed"
