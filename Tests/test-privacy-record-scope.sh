#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
READINESS="$PROJECT_ROOT/scripts/release-readiness.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-privacy-scope-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "App Privacy record-scope test failed: $*"
  exit 1
}

FUNCTION_SOURCE="$(/usr/bin/awk '
  /^privacy_evidence_matches_candidate\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^}$/ { exit }
' "$READINESS")"
[[ "$FUNCTION_SOURCE" == *'.releaseEvidence.recordScope == $recordScope'* ]] \
  || fail "readiness helper is missing the exact recordScope comparison"
eval "$FUNCTION_SOURCE"

APP_PRIVACY_RELEASE_EVIDENCE_READY=true
MAC_PRIVACY_VALIDATION_JSON="$TEST_ROOT/privacy-validation.json"
CANDIDATE_SHA="$(printf 'a%.0s' {1..64})"

write_fixture() {
  local scope="$1"
  local platform="${2:-macOS}"
  local distribution="${3:-mac-app-store}"
  local bundle="${4:-com.agentisland.release}"
  /usr/bin/jq -n \
    --arg scope "$scope" \
    --arg platform "$platform" \
    --arg distribution "$distribution" \
    --arg bundle "$bundle" \
    --arg sha "$CANDIDATE_SHA" '{
      releaseEvidenceReady: true,
      releaseEvidence: {
        recordScope: $scope,
        archives: [{
          platform: $platform,
          distribution: $distribution,
          bundleID: $bundle,
          version: "0.6.1",
          build: "8",
          sha256: $sha
        }]
      }
    }' >"$MAC_PRIVACY_VALIDATION_JSON"
}

MAC_APP_STORE_RECORD_MODE='universal-purchase'
write_fixture 'macOS'
if privacy_evidence_matches_candidate \
    'macOS' 'mac-app-store' 'com.agentisland.release' '0.6.1' '8' \
    "$CANDIDATE_SHA"; then
  fail "Mac-only evidence opened a universal-purchase platform gate"
fi
write_fixture 'iOS' 'iOS' 'app-store' 'com.agentisland.release'
if privacy_evidence_matches_candidate \
    'iOS' 'app-store' 'com.agentisland.release' '0.6.1' '8' \
    "$CANDIDATE_SHA"; then
  fail "iOS-only evidence opened a universal-purchase platform gate"
fi
write_fixture 'universal-purchase'
privacy_evidence_matches_candidate \
  'macOS' 'mac-app-store' 'com.agentisland.release' '0.6.1' '8' \
  "$CANDIDATE_SHA" \
  || fail "matching universal-purchase evidence was rejected"

MAC_APP_STORE_RECORD_MODE='separate-records'
if privacy_evidence_matches_candidate \
    'macOS' 'mac-app-store' 'com.agentisland.release' '0.6.1' '8' \
    "$CANDIDATE_SHA"; then
  fail "universal-purchase evidence opened a separate-records platform gate"
fi
write_fixture 'separate-records'
privacy_evidence_matches_candidate \
  'macOS' 'mac-app-store' 'com.agentisland.release' '0.6.1' '8' \
  "$CANDIDATE_SHA" \
  || fail "matching separate-records evidence was rejected"

print -r -- "App Privacy record-scope binding checks passed"
