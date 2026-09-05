#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
PROFILE_CONTRACT="$PROJECT_ROOT/scripts/cloudkit-profile-authorization.jq"
SIGNED_CONTRACT="$PROJECT_ROOT/scripts/developer-id-entitlements-contract.jq"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-profile-authorization.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "CloudKit profile authorization test failed: $*"
  exit 1
}

[[ -f "$PROFILE_CONTRACT" && ! -L "$PROFILE_CONTRACT" ]] \
  || fail "profile authorization contract is missing or unsafe"
[[ -f "$SIGNED_CONTRACT" && ! -L "$SIGNED_CONTRACT" ]] \
  || fail "signed entitlement contract is missing or unsafe"

for release_script in \
    "$PROJECT_ROOT/scripts/apply-release-identity.sh" \
    "$PROJECT_ROOT/scripts/release-readiness.sh" \
    "$PROJECT_ROOT/scripts/release-macos.sh" \
    "$PROJECT_ROOT/ApplePlatforms/macOS/scripts/release-macos-app-store.sh" \
    "$PROJECT_ROOT/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh"; do
  /usr/bin/grep -Fq -- '-f "$CLOUDKIT_PROFILE_AUTHORIZATION"' \
    "$release_script" \
    || fail "${release_script#$PROJECT_ROOT/} does not use the shared profile authorization contract"
done

TEAM_ID="ABCDE12345"
APP_IDENTIFIER="$TEAM_ID.com.agentisland.release"
CLOUD_CONTAINER="iCloud.com.agentisland.release"

profile_authorized() {
  /usr/bin/jq -e \
    --arg applicationIdentifier "$APP_IDENTIFIER" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER" \
    -f "$PROFILE_CONTRACT" "$1" >/dev/null
}

expect_profile_accepted() {
  local label="$1"
  local input="$2"
  profile_authorized "$input" || fail "$label should have been accepted"
}

expect_profile_rejected() {
  local label="$1"
  local input="$2"
  if profile_authorized "$input" 2>/dev/null; then
    fail "$label should have been rejected"
  fi
}

EXACT_PROFILE="$TEST_ROOT/exact-profile.json"
/usr/bin/jq -n \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER" '{
    "com.apple.application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "com.apple.developer.icloud-container-identifiers": [$container],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production"
  }' >"$EXACT_PROFILE"

PORTAL_PROFILE="$TEST_ROOT/portal-profile.json"
/usr/bin/jq \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER" '. + {
    "com.apple.developer.icloud-services": "*",
    "com.apple.developer.icloud-container-environment":
      ["Production", "Development"],
    "com.apple.developer.icloud-container-identifiers":
      [$container, "iCloud.com.agentisland.profile-only"],
    "com.apple.developer.icloud-container-development-container-identifiers":
      [$container],
    "com.apple.developer.ubiquity-container-identifiers": [$container],
    "com.apple.developer.ubiquity-kvstore-identifier": ($team + ".*"),
    "keychain-access-groups": [($team + ".*"), "com.apple.token"]
  }' "$EXACT_PROFILE" >"$PORTAL_PROFILE"

ARRAY_SERVICE_PROFILE="$TEST_ROOT/array-service-profile.json"
/usr/bin/jq '."com.apple.developer.icloud-services" =
  ["CloudDocuments", "CloudKit"]' "$EXACT_PROFILE" \
  >"$ARRAY_SERVICE_PROFILE"

expect_profile_accepted "exact profile authorization" "$EXACT_PROFILE"
expect_profile_accepted \
  "Apple Portal wildcard/list and profile-only authorization" "$PORTAL_PROFILE"
expect_profile_accepted "service authorization list" "$ARRAY_SERVICE_PROFILE"

CANDIDATE="$TEST_ROOT/candidate.json"
reject_mutation() {
  local label="$1"
  local filter="$2"
  /usr/bin/jq "$filter" "$EXACT_PROFILE" >"$CANDIDATE"
  expect_profile_rejected "$label" "$CANDIDATE"
}

reject_mutation "wildcard App ID" \
  '."com.apple.application-identifier" = "ABCDE12345.*"'
reject_mutation "wrong Team" \
  '."com.apple.developer.team-identifier" = "ZZZZZ99999"'
reject_mutation "missing release container" \
  '."com.apple.developer.icloud-container-identifiers" = ["iCloud.other"]'
reject_mutation "missing CloudKit service" \
  '."com.apple.developer.icloud-services" = ["CloudDocuments"]'
reject_mutation "missing Production environment" \
  '."com.apple.developer.icloud-container-environment" = ["Development"]'
reject_mutation "development debugger authorization" \
  '."get-task-allow" = true'
reject_mutation "malformed service authorization" \
  '."com.apple.developer.icloud-services" = ["CloudKit", 7]'

# The same broader Portal dictionary is not a valid signed claim.  Final
# Developer ID entitlements remain the project's closed, exact minimal set.
/usr/bin/jq -e \
  --arg applicationIdentifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER" \
  -f "$SIGNED_CONTRACT" "$EXACT_PROFILE" >/dev/null \
  || fail "exact signed entitlement fixture should pass"
if /usr/bin/jq -e \
    --arg applicationIdentifier "$APP_IDENTIFIER" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER" \
    -f "$SIGNED_CONTRACT" "$PORTAL_PROFILE" >/dev/null 2>&1; then
  fail "broader profile-only authorization was accepted as signed entitlements"
fi

print -r -- "CloudKit profile authorization tests passed"
