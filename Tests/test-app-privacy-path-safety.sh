#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
VALIDATOR="$PROJECT_ROOT/scripts/validate-app-privacy.mjs"
FIXTURE_ROOT="$(mktemp -d /private/tmp/agentisland-privacy-path-test.XXXXXX)"
OUTSIDE_ROOT="$(mktemp -d /private/tmp/agentisland-privacy-outside.XXXXXX)"
trap '/bin/rm -rf "$FIXTURE_ROOT" "$OUTSIDE_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "App Privacy path-safety test failed: $*"
  exit 1
}

/bin/mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/Resources" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Config" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/WidgetExtension" \
  "$FIXTURE_ROOT/Native" \
  "$FIXTURE_ROOT/docs/release"
/bin/cp "$VALIDATOR" "$FIXTURE_ROOT/scripts/validate-app-privacy.mjs"
/bin/cp "$PROJECT_ROOT/Resources/PrivacyInfo.xcprivacy" \
  "$FIXTURE_ROOT/Resources/PrivacyInfo.xcprivacy"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy"
/bin/cp "$PROJECT_ROOT/Native/AgentIsland.m" "$FIXTURE_ROOT/Native/AgentIsland.m"
/bin/cp "$PROJECT_ROOT/docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md" \
  "$FIXTURE_ROOT/docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md"

print -r -- '{"schemaVersion":1}' >"$OUTSIDE_ROOT/evidence.json"
/bin/ln -s "$OUTSIDE_ROOT" "$FIXTURE_ROOT/evidence-link"

RESULT="$FIXTURE_ROOT/result.json"
AGENT_ISLAND_APP_PRIVACY_EVIDENCE='evidence-link/evidence.json' \
  node "$FIXTURE_ROOT/scripts/validate-app-privacy.mjs" >"$RESULT"
/usr/bin/jq -e '
  .releaseEvidenceReady == false and
  (.releaseBlockers | any(contains("path must not contain a symbolic-link component")))
' "$RESULT" >/dev/null \
  || fail "an evidence path crossing an intermediate symlink was not rejected"

print -r -- "App Privacy realpath and intermediate-symlink checks passed"
