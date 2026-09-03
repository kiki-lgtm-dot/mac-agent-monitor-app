#!/bin/zsh
set -euo pipefail

# Keep CI failures actionable even when a command intentionally writes its
# result to a temporary file (for example a jq contract check). GitHub's job
# summary otherwise reports only an opaque exit code.
trap 'rc=$?; print -u2 -- "test.sh failed at line $LINENO (exit $rc)"; trap - ZERR; exit $rc' ZERR

# GitHub's macOS runners do not include ripgrep by default. Keep local runs fast
# when it is available, while making the release checks portable to stock macOS.
if ! command -v rg >/dev/null 2>&1; then
  rg() {
    /usr/bin/grep -E "$@"
  }
fi

PROJECT_DIR="${0:A:h:h}"
PUBLIC_DISPLAY_NAME="MAC版灵动岛--Agent运行监测"
APP_PATH="$(LC_ALL=C AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" "$PROJECT_DIR/scripts/build-app.sh")"
EXPECTED_APP_PATH="$PROJECT_DIR/dist/$PUBLIC_DISPLAY_NAME.app"
ARCHIVE_PATH="$PROJECT_DIR/dist/$PUBLIC_DISPLAY_NAME-macOS-universal.zip"
BINARY="$APP_PATH/Contents/MacOS/AgentIsland"
FIXTURE="$PROJECT_DIR/Tests/Fixtures/custom-agent.jsonl"
CODEX_FIXTURE="$PROJECT_DIR/Tests/Fixtures/codex-token-events.jsonl"
CLAUDE_FIXTURE_ROOT="$PROJECT_DIR/Tests/Fixtures/claude-cross-file"
HEARTBEAT_FIXTURE="$PROJECT_DIR/Tests/Fixtures/custom-heartbeat-metadata.jsonl"
WORKSPACE_ENVELOPE_FIXTURE="$PROJECT_DIR/Tests/Fixtures/workspace-envelope.json"
WORKSPACE_LEGACY_FIXTURE="$PROJECT_DIR/Tests/Fixtures/workspace-legacy.json"
WORKSPACE_CORRUPT_FIXTURE="$PROJECT_DIR/Tests/Fixtures/workspace-corrupt.json"
TRANSLATION_RESPONSE_FIXTURE="$PROJECT_DIR/Tests/Fixtures/openai-translation-response.json"
MOBILE_TOOL_FIXTURE="$PROJECT_DIR/Tests/Fixtures/mobile-tool-snapshot.json"
VERIFY_ROOT="$(mktemp -d /private/tmp/agentisland-test.XXXXXX)"
PRIVACY_TEST_ROOT="$(mktemp -d "$PROJECT_DIR/dist/.privacy-evidence-test.XXXXXX")"
trap 'rm -rf "$VERIFY_ROOT" "$PRIVACY_TEST_ROOT"' EXIT

[[ "$APP_PATH" == "$EXPECTED_APP_PATH" ]] || {
  echo "Build returned a non-canonical public app path: $APP_PATH" >&2
  exit 1
}
[[ "$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Resources/Info.plist")" == "0.6.1" ]]
[[ "$(plutil -extract CFBundleVersion raw "$PROJECT_DIR/Resources/Info.plist")" == "8" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" == "0.6.1" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")" == "8" ]]
[[ "$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")" == "$PUBLIC_DISPLAY_NAME" ]]
[[ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw "$PROJECT_DIR/Resources/Info.plist")" == "true" ]]
[[ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw "$APP_PATH/Contents/Info.plist")" == "true" ]]
[[ "$(plutil -extract AgentIslandPrivacyPolicyURL raw "$PROJECT_DIR/Resources/Info.plist")" == "" ]]
[[ "$(plutil -extract AgentIslandSupportURL raw "$PROJECT_DIR/Resources/Info.plist")" == "" ]]
[[ "$(plutil -extract AgentIslandPrivacyPolicyURL raw "$APP_PATH/Contents/Info.plist")" == "" ]]
[[ "$(plutil -extract AgentIslandSupportURL raw "$APP_PATH/Contents/Info.plist")" == "" ]]
if ARBITRARY_LOADS="$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null)"; then
  [[ "$ARBITRARY_LOADS" == "false" ]]
fi
/bin/zsh -n "$PROJECT_DIR/scripts/build-app.sh" "$PROJECT_DIR/scripts/release-macos.sh" \
  "$PROJECT_DIR/scripts/release-readiness.sh" "$PROJECT_DIR/scripts/render-app-icons.sh" \
  "$PROJECT_DIR/scripts/apply-release-identity.sh" "$PROJECT_DIR/Tests/test-release-identity.sh"
[[ -x "$PROJECT_DIR/scripts/release-macos.sh" ]]
[[ -x "$PROJECT_DIR/scripts/release-readiness.sh" ]]
[[ -x "$PROJECT_DIR/scripts/apply-release-identity.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-release-identity.sh" ]]
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .widgetBundleIdentifier == (.primaryBundleIdentifier + ".liveactivity") and
  .cloudKit == {
    databaseScope: "private",
    environment: "Production",
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON"
  }
' "$PROJECT_DIR/Config/ReleaseIdentity.example.json" >/dev/null
for marker in '--check' '--apply' 'identity.lock.json' 'identity-backup' \
  'com.apple.application-identifier' 'ProvisionsAllDevices' \
  'appIDPrefixGuessed: false' 'widgetBundleIdentifier must equal primaryBundleIdentifier + .liveactivity' \
  'private Production AgentIslandSnapshot/latest/payloadJSON contract'; do
  rg -q --fixed-strings -- "$marker" "$PROJECT_DIR/scripts/apply-release-identity.sh"
done
"$PROJECT_DIR/Tests/test-release-identity.sh"
"$PROJECT_DIR/Tests/test-store-submission.sh"
[[ -f "$PROJECT_DIR/scripts/validate-app-privacy.mjs" ]]
[[ -f "$PROJECT_DIR/docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md" ]]
APP_PRIVACY_RESULT="$VERIFY_ROOT/app-privacy-validation.json"
node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" >"$APP_PRIVACY_RESULT"
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .mode == "draft" and
  .draftValid == true and
  (.sourcePrivacyReady | type == "boolean") and
  (.releaseEvidenceReady | type == "boolean") and
  (.releaseReady | type == "boolean") and
  (.releaseEvidencePath | type == "string") and
  (.validatorSelfTests.evidenceContract == true) and
  (.macOS.timestampAPIUsed | type == "boolean") and
  (.macOS.automaticHomeScanPresent | type == "boolean") and
  (.macOS.securityScopedBookmarkMarkersPresent | type == "boolean") and
  (.macOS.sandboxAuthorizationIsSeparateGate == true) and
  (.structuralErrors | type == "array") and
  (.releaseBlockers | type == "array")
' "$APP_PRIVACY_RESULT" >/dev/null
if /usr/bin/jq -e '.releaseReady == true' "$APP_PRIVACY_RESULT" >/dev/null; then
  node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" --release >/dev/null
elif node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" --release >/dev/null 2>&1; then
  echo "App Privacy validator accepted a release without complete archive-bound evidence" >&2
  exit 1
fi

PRIVACY_CANDIDATE="$PRIVACY_TEST_ROOT/candidate.zip"
PRIVACY_FIXTURE_APP="$VERIFY_ROOT/PrivacyFixture.app"
/bin/mkdir -p "$PRIVACY_FIXTURE_APP/Contents/MacOS" "$PRIVACY_FIXTURE_APP/Contents/Resources"
/bin/cp "$APP_PATH/Contents/Info.plist" "$PRIVACY_FIXTURE_APP/Contents/Info.plist"
/bin/cp "$APP_PATH/Contents/MacOS/AgentIsland" "$PRIVACY_FIXTURE_APP/Contents/MacOS/AgentIsland"
/bin/cp "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" \
  "$PRIVACY_FIXTURE_APP/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/plutil -replace CFBundleIdentifier -string 'com.agentisland.privacyfixture' \
  "$PRIVACY_FIXTURE_APP/Contents/Info.plist"
COPYFILE_DISABLE=1 /usr/bin/ditto --noextattr --norsrc -c -k --keepParent \
  "$PRIVACY_FIXTURE_APP" "$PRIVACY_CANDIDATE"
PRIVACY_CANDIDATE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PRIVACY_CANDIDATE" | /usr/bin/awk '{print $1}')"
PRIVACY_CANDIDATE_RELATIVE="${PRIVACY_CANDIDATE#$PROJECT_DIR/}"
PRIVACY_CANDIDATE_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$PRIVACY_FIXTURE_APP/Contents/Info.plist")"
PRIVACY_CANDIDATE_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PRIVACY_FIXTURE_APP/Contents/Info.plist")"
PRIVACY_CANDIDATE_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIVACY_FIXTURE_APP/Contents/Info.plist")"
PRIVACY_EVIDENCE_RECORDS="$PRIVACY_TEST_ROOT/evidence-records.jsonl"
/usr/bin/touch "$PRIVACY_EVIDENCE_RECORDS"
for PRIVACY_EVIDENCE_KIND in \
    privacyManifests xcodePrivacyReport networkAudit cloudKitVerification \
    titleSyncVerification translationProviderDecision publicPagesVerification \
    appStoreConnectPublication; do
  PRIVACY_EVIDENCE_FILE="$PRIVACY_TEST_ROOT/$PRIVACY_EVIDENCE_KIND.txt"
  print -r -- "candidateArchiveSHA256=$PRIVACY_CANDIDATE_SHA evidence=$PRIVACY_EVIDENCE_KIND" \
    >"$PRIVACY_EVIDENCE_FILE"
  PRIVACY_EVIDENCE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PRIVACY_EVIDENCE_FILE" | /usr/bin/awk '{print $1}')"
  PRIVACY_EVIDENCE_RELATIVE="${PRIVACY_EVIDENCE_FILE#$PROJECT_DIR/}"
  /usr/bin/jq -cn \
    --arg key "$PRIVACY_EVIDENCE_KIND" \
    --arg path "$PRIVACY_EVIDENCE_RELATIVE" \
    --arg sha256 "$PRIVACY_EVIDENCE_SHA" \
    --arg candidateSHA "$PRIVACY_CANDIDATE_SHA" \
    '{key: $key, value: {path: $path, sha256: $sha256, candidateArchiveSHA256s: [$candidateSHA]}}' \
    >>"$PRIVACY_EVIDENCE_RECORDS"
done
PRIVACY_EVIDENCE_OBJECT="$(/usr/bin/jq -sc 'from_entries' "$PRIVACY_EVIDENCE_RECORDS")"
PRIVACY_EVIDENCE_CONFIG="$PRIVACY_TEST_ROOT/app-privacy-evidence.json"
/usr/bin/jq -n \
  --arg candidatePath "$PRIVACY_CANDIDATE_RELATIVE" \
  --arg candidateSHA "$PRIVACY_CANDIDATE_SHA" \
  --arg bundleID "$PRIVACY_CANDIDATE_BUNDLE_ID" \
  --arg version "$PRIVACY_CANDIDATE_VERSION" \
  --arg build "$PRIVACY_CANDIDATE_BUILD" \
  --argjson evidence "$PRIVACY_EVIDENCE_OBJECT" \
  '{
    schemaVersion: 1,
    recordScope: "macOS",
    reviewedAt: "2026-09-03T12:00:00Z",
    archives: [{
      platform: "macOS",
      distribution: "mac-app-store",
      path: $candidatePath,
      sha256: $candidateSHA,
      bundleID: $bundleID,
      version: $version,
      build: $build
    }],
    evidence: $evidence
  }' >"$PRIVACY_EVIDENCE_CONFIG"
PRIVACY_EVIDENCE_CONFIG_RELATIVE="${PRIVACY_EVIDENCE_CONFIG#$PROJECT_DIR/}"
VALID_PRIVACY_RESULT="$VERIFY_ROOT/app-privacy-valid-evidence.json"
AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$PRIVACY_EVIDENCE_CONFIG_RELATIVE" \
  node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" --release >"$VALID_PRIVACY_RESULT"
/usr/bin/jq -e '
  .draftValid == true and .sourcePrivacyReady == true and
  .releaseEvidenceReady == true and .releaseReady == true and
  (.releaseEvidence.archives | length == 1) and
  .releaseEvidence.archives[0].sha256 != null and
  (.releaseEvidence.evidenceKinds | length == 8)
' "$VALID_PRIVACY_RESULT" >/dev/null

print -r -- 'tampered after evidence capture' >>"$PRIVACY_CANDIDATE"
TAMPERED_PRIVACY_RESULT="$VERIFY_ROOT/app-privacy-tampered-evidence.json"
AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$PRIVACY_EVIDENCE_CONFIG_RELATIVE" \
  node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" >"$TAMPERED_PRIVACY_RESULT"
/usr/bin/jq -e '
  .releaseReady == false and .releaseEvidenceReady == false and
  (.releaseBlockers | any(contains("sha256 does not match the candidate archive file")))
' "$TAMPERED_PRIVACY_RESULT" >/dev/null
if AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$PRIVACY_EVIDENCE_CONFIG_RELATIVE" \
    node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" --release >/dev/null 2>&1; then
  echo "App Privacy validator accepted evidence after the candidate archive changed" >&2
  exit 1
fi

FAKE_PRIVACY_PACKAGE="$PRIVACY_TEST_ROOT/not-a-package.pkg"
print -r -- 'not an installer package' >"$FAKE_PRIVACY_PACKAGE"
FAKE_PRIVACY_PACKAGE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FAKE_PRIVACY_PACKAGE" | /usr/bin/awk '{print $1}')"
FAKE_PRIVACY_PACKAGE_RELATIVE="${FAKE_PRIVACY_PACKAGE#$PROJECT_DIR/}"
FAKE_PRIVACY_CONFIG="$PRIVACY_TEST_ROOT/fake-package-evidence.json"
/usr/bin/jq \
  --arg path "$FAKE_PRIVACY_PACKAGE_RELATIVE" \
  --arg sha256 "$FAKE_PRIVACY_PACKAGE_SHA" \
  '.archives[0].path = $path
    | .archives[0].sha256 = $sha256
    | .evidence[].candidateArchiveSHA256s = [$sha256]' \
  "$PRIVACY_EVIDENCE_CONFIG" >"$FAKE_PRIVACY_CONFIG"
FAKE_PRIVACY_CONFIG_RELATIVE="${FAKE_PRIVACY_CONFIG#$PROJECT_DIR/}"
FAKE_PRIVACY_RESULT="$VERIFY_ROOT/app-privacy-fake-package.json"
AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$FAKE_PRIVACY_CONFIG_RELATIVE" \
  node "$PROJECT_DIR/scripts/validate-app-privacy.mjs" >"$FAKE_PRIVACY_RESULT"
/usr/bin/jq -e '
  .releaseReady == false and
  (.releaseBlockers | any(contains("has a .pkg name but is not an XAR package")))
' "$FAKE_PRIVACY_RESULT" >/dev/null
for marker in 'notarytool submit' 'stapler staple' 'stapler validate' 'spctl --assess' \
  'AGENT_ISLAND_DEVELOPER_ID_APPLICATION' 'release-metadata' 'shasum -a 256' 'notarySubmissionID' \
  'AGENT_ISLAND_DISPLAY_NAME' 'DeveloperCertificates' 'notarytool log' 'notaryIssueCount' \
  'provisioningProfileSHA256' 'signingCertificateSHA1' 'Refusing release while non-canonical macOS universal archives exist' \
  'Set AGENT_ISLAND_ENTITLEMENTS' 'Set AGENT_ISLAND_PROVISIONING_PROFILE' \
  'Set AGENT_ISLAND_ICLOUD_CONTAINER_ID' \
  'Set AGENT_ISLAND_PRIVACY_POLICY_URL' 'Set AGENT_ISLAND_SUPPORT_URL' \
  'Signed app does not contain the expected release App ID/team and production CloudKit entitlement' \
  'AGENT_ISLAND_DISPLAY_NAME must equal the public artifact name' \
  '.agentisland-release-publish.' '.agentisland-release-backup.' \
  'restore_published_outputs' 'PUBLISH_TARGETS=("$FINAL_ARCHIVE" "$FINAL_CHECKSUM" "$METADATA_DIR")'; do
  rg -q --fixed-strings "$marker" "$PROJECT_DIR/scripts/release-macos.sh"
done
rg -q --fixed-strings 'CANONICAL_APP="$EXTRACT_ROOT/$PUBLIC_APP_NAME.app"' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'FINAL_VERIFY_APP="$FINAL_VERIFY_ROOT/$PUBLIC_APP_NAME.app"' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Secure timestamp is missing from the release signature' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Final release must contain exactly arm64 and x86_64 architectures' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Final archive release entitlements mismatch' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Final archive display name mismatch' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Final archive provisioning profile mismatch' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'Published release archive checksum changed while committing to dist' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PENDING_ARCHIVE"' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$EXPORTED_IPA"' "$PROJECT_DIR/ApplePlatforms/iOS/scripts/release-ios.sh"
if rg -q --fixed-strings '"$DIST_DIR/$PUBLIC_APP_NAME.app"' "$PROJECT_DIR/scripts/release-macos.sh"; then
  echo "macOS release verification still trusts the Desktop-visible app instead of the canonical archive" >&2
  exit 1
fi
if rg -q --fixed-strings -- '--entitlements :-' "$PROJECT_DIR/scripts/release-macos.sh" "$PROJECT_DIR/ApplePlatforms/iOS/scripts/release-ios.sh"; then
  echo "Release scripts still use deprecated codesign --entitlements :- syntax" >&2
  exit 1
fi
rg -q --fixed-strings 'sign_args+=(--options runtime --timestamp)' "$PROJECT_DIR/scripts/build-app.sh"
rg -q --fixed-strings 'sign_args+=(--entitlements "$ENTITLEMENTS_PATH")' "$PROJECT_DIR/scripts/build-app.sh"
rg -q --fixed-strings 'embedded.provisionprofile' "$PROJECT_DIR/scripts/build-app.sh"
rg -q --fixed-strings 'com.apple.application-identifier' "$PROJECT_DIR/scripts/build-app.sh"
rg -q --fixed-strings 'com.apple.application-identifier' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'com.apple.application-identifier' "$PROJECT_DIR/scripts/release-readiness.sh"
rg -q --fixed-strings 'com.apple.developer.team-identifier' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'com.apple.security.get-task-allow' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings 'ProvisionsAllDevices' "$PROJECT_DIR/scripts/release-macos.sh"
rg -q --fixed-strings "date -j -u -f '%Y-%m-%dT%H:%M:%SZ'" "$PROJECT_DIR/scripts/release-macos.sh"
if rg -q --fixed-strings 'plutil -convert json -o - "$PROFILE_PLIST"' \
    "$PROJECT_DIR/scripts/release-macos.sh" "$PROJECT_DIR/scripts/build-app.sh" "$PROJECT_DIR/scripts/release-readiness.sh"; then
  echo "macOS release tooling still converts a full provisioning profile with Date/Data objects to JSON" >&2
  exit 1
fi
if rg -q --fixed-strings 'plutil -convert json -o "$PROFILE_JSON" "$PROFILE_PLIST"' \
    "$PROJECT_DIR/scripts/apply-release-identity.sh"; then
  echo "Release identity tooling still converts a full provisioning profile with Date/Data objects to JSON" >&2
  exit 1
fi
rg -q --fixed-strings 'TeamIdentifier=$TEAM_ID' "$PROJECT_DIR/scripts/release-macos.sh"
/usr/bin/plutil -lint "$PROJECT_DIR/Config/CloudKit.entitlements.example" >/dev/null
/usr/bin/plutil -lint "$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" >/dev/null
/usr/bin/plutil -lint "$PROJECT_DIR/Tests/Fixtures/developer-id-profile-decoded.plist" >/dev/null
PROFILE_ENTITLEMENTS_FIXTURE="$VERIFY_ROOT/developer-id-profile-entitlements.plist"
PROFILE_ENTITLEMENTS_JSON_FIXTURE="$VERIFY_ROOT/developer-id-profile-entitlements.json"
/usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_FIXTURE" \
  "$PROJECT_DIR/Tests/Fixtures/developer-id-profile-decoded.plist"
/usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON_FIXTURE" "$PROFILE_ENTITLEMENTS_FIXTURE"
/usr/bin/jq -e '
  ."com.apple.application-identifier" == "ABCDE12345.com.agentisland.release" and
  ."com.apple.developer.team-identifier" == "ABCDE12345" and
  ."com.apple.developer.icloud-container-identifiers" == ["iCloud.com.agentisland.releasefixture"] and
  ."com.apple.developer.icloud-container-environment" == "Production" and
  ."com.apple.developer.icloud-services" == ["CloudKit"]
' "$PROFILE_ENTITLEMENTS_JSON_FIXTURE" >/dev/null
[[ "$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROJECT_DIR/Tests/Fixtures/developer-id-profile-decoded.plist")" == "1" ]]
[[ "$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROJECT_DIR/Tests/Fixtures/developer-id-profile-decoded.plist")" == "2041-01-01T00:00:00Z" ]]
if AGENT_ISLAND_PRIVACY_POLICY_URL='http://example.test/privacy' "$PROJECT_DIR/scripts/build-app.sh" >/dev/null 2>&1; then
  echo "Build accepted a non-HTTPS privacy policy URL" >&2
  exit 1
fi
if AGENT_ISLAND_SUPPORT_URL='http://example.test/support' "$PROJECT_DIR/scripts/build-app.sh" >/dev/null 2>&1; then
  echo "Build accepted a non-HTTPS support URL" >&2
  exit 1
fi
if AGENT_ISLAND_BUNDLE_ID='invalid/bundle' "$PROJECT_DIR/scripts/build-app.sh" >/dev/null 2>&1; then
  echo "Build accepted an invalid production bundle identifier" >&2
  exit 1
fi
if AGENT_ISLAND_DISPLAY_NAME='Agent Island' "$PROJECT_DIR/scripts/build-app.sh" >/dev/null 2>&1; then
  echo "Build accepted the conflicting Agent Island release display name" >&2
  exit 1
fi
if AGENT_ISLAND_DISPLAY_NAME='TaskLume' "$PROJECT_DIR/scripts/build-app.sh" >/dev/null 2>&1; then
  echo "Build accepted the conflicting TaskLume release display name" >&2
  exit 1
fi
if /usr/bin/env \
  -u AGENT_ISLAND_DEVELOPER_ID_APPLICATION \
  -u AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE \
  -u AGENT_ISLAND_BUNDLE_ID \
  -u AGENT_ISLAND_DEVELOPMENT_TEAM \
  -u AGENT_ISLAND_VERSION \
  -u AGENT_ISLAND_BUILD_NUMBER \
  -u AGENT_ISLAND_DISPLAY_NAME \
  -u AGENT_ISLAND_ENTITLEMENTS \
  -u AGENT_ISLAND_PROVISIONING_PROFILE \
  -u AGENT_ISLAND_ICLOUD_CONTAINER_ID \
  -u AGENT_ISLAND_PRIVACY_POLICY_URL \
  -u AGENT_ISLAND_SUPPORT_URL \
  "$PROJECT_DIR/scripts/release-macos.sh" >/dev/null 2>&1; then
  echo "Release script accepted missing signing and notarization configuration" >&2
  exit 1
fi
if /usr/bin/env \
  AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Test (ABCDE12345)' \
  AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='test-profile' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_VERSION='1.0.0' \
  AGENT_ISLAND_BUILD_NUMBER='1' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_ENTITLEMENTS='/nonexistent/test.entitlements' \
  AGENT_ISLAND_PROVISIONING_PROFILE='/nonexistent/test.provisionprofile' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.release' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='http://agentisland.app/privacy' \
  AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
  "$PROJECT_DIR/scripts/release-macos.sh" >/dev/null 2>&1; then
  echo "Release script accepted a non-production privacy URL" >&2
  exit 1
fi
DISPLAY_NAME_OUTPUT="$(/usr/bin/env \
  AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Test (ABCDE12345)' \
  AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='test-profile' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_VERSION='1.0.0' \
  AGENT_ISLAND_BUILD_NUMBER='1' \
  AGENT_ISLAND_DISPLAY_NAME='Release Fixture' \
  AGENT_ISLAND_ENTITLEMENTS='/nonexistent/test.entitlements' \
  AGENT_ISLAND_PROVISIONING_PROFILE='/nonexistent/test.provisionprofile' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.release' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
  AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
  "$PROJECT_DIR/scripts/release-macos.sh" 2>&1 || true)"
[[ "$DISPLAY_NAME_OUTPUT" == *'must equal the public artifact name'* ]]
MISMATCH_OUTPUT="$(/usr/bin/env \
  AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Test (ABCDE12345)' \
  AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='test-profile' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_VERSION='1.0.0' \
  AGENT_ISLAND_BUILD_NUMBER='1' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_ENTITLEMENTS="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_PROVISIONING_PROFILE="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.wrong' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
  AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
  "$PROJECT_DIR/scripts/release-macos.sh" 2>&1 || true)"
[[ "$MISMATCH_OUTPUT" == *'authorize exactly AGENT_ISLAND_ICLOUD_CONTAINER_ID for production CloudKit'* ]]
PROFILE_OUTPUT="$(/usr/bin/env \
  AGENT_ISLAND_DEVELOPER_ID_APPLICATION='Developer ID Application: Test (ABCDE12345)' \
  AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE='test-profile' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_VERSION='1.0.0' \
  AGENT_ISLAND_BUILD_NUMBER='1' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_ENTITLEMENTS="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_PROVISIONING_PROFILE="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.releasefixture' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
  AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
  "$PROJECT_DIR/scripts/release-macos.sh" 2>&1 || true)"
[[ "$PROFILE_OUTPUT" == *'AGENT_ISLAND_PROVISIONING_PROFILE is not a decodable signed provisioning profile'* ]]
RELEASE_GATE_LINE="$(rg -n 'Set AGENT_ISLAND_ENTITLEMENTS' "$PROJECT_DIR/scripts/release-macos.sh" | head -1 | cut -d: -f1)"
NOTARY_SUBMIT_LINE="$(rg -n 'notarytool submit' "$PROJECT_DIR/scripts/release-macos.sh" | head -1 | cut -d: -f1)"
(( RELEASE_GATE_LINE < NOTARY_SUBMIT_LINE ))
for READINESS_GATE in \
  'cloudKitEntitlementsConfigured' 'cloudKitContainerConfigured' 'provisioningProfileConfigured' \
  'privacyPolicyURLConfigured' 'supportURLConfigured' \
  'productionDisplayNameConfigured' 'provisioningProfileSigningCertificateConfigured' \
  'iosDevelopmentTeamConfigured' 'iosCloudKitContainerConfigured' \
  'iosPrivacyPolicyURLConfigured' 'iosSupportURLConfigured' \
  'cloudKitProductionSchemaVerified' 'iosRealDeviceSyncVerified' \
  'iosLiveActivityVerified' 'iosReviewPathVerified' \
  'appleDistributionTeamIdentityConfigured' \
  'macAppStoreXcodeProjectConfigured' 'macAppStoreTargetMembershipConfigured' \
  'macAppStoreRuntimeResourcesInTarget' 'macAppStoreBuildSettingsMatch' \
  'macPrivacyManifestInAppTarget' 'macAppStoreInfoPlistConfigured' \
  'macAppSandboxEntitlementConfigured' 'macUserSelectedReadOnlyEntitlementConfigured' \
  'macAppScopeBookmarkEntitlementConfigured' 'macNetworkClientEntitlementConfigured' \
  'macAppStoreCloudKitEntitlementConfigured' 'macAppStoreEntitlementsConfigured' \
  'macSecurityScopedBookmarkMarkersPresent' 'macAutomaticHomeScanMarkersPresent' \
  'macPrivacySourceReady' 'macPrivacyReleaseEvidenceReady' 'storeSubmissionAssetsReady' \
  'appStoreRecordModeConfigured' 'universalPurchaseBundleIDsMatch' \
  'appStoreRecordModeBundleIDsValid' \
  'macAppStoreSandboxFlowVerified' 'macAppStoreArchiveVerified' \
  'macAppStoreProfileCertificateVerified' 'macAppStorePrivacyReportVerified' \
  'macAppStoreReviewPathVerified' 'readyForMacAppStoreArchive' \
  'readyForFunctionalMacAppStoreSubmission' \
  'macDeveloperIDToolchainConfigured' '$MAC_DEVELOPER_ID_TOOLCHAIN' \
  '$ENTITLEMENTS_READY' '$CLOUDKIT_CONTAINER_READY' '$PROVISIONING_PROFILE_READY' '$RELEASE_PRIVACY_READY' '$RELEASE_SUPPORT_READY' \
  '$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY' \
  '$MAC_APP_STORE_XCODE_PROJECT' '$MAC_APP_STORE_TARGET_MEMBERSHIP' \
  '$MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET' '$MAC_APP_STORE_BUILD_SETTINGS_MATCH' \
  '$MAC_APP_STORE_INFO_PLIST_CONFIGURED' '$MAC_APP_STORE_ENTITLEMENTS_READY' \
  '$MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID' \
  '$MAC_PRIVACY_SOURCE_READY' '$STORE_SUBMISSION_ASSETS_READY' \
  '$cloudKitProductionSchemaVerified and $iosRealDeviceSyncVerified' \
  '$iosLiveActivityVerified and $iosReviewPathVerified'; do
  rg -q --fixed-strings "$READINESS_GATE" "$PROJECT_DIR/scripts/release-readiness.sh"
done

/usr/bin/env \
  -u AGENT_ISLAND_BUNDLE_ID \
  -u AGENT_ISLAND_IOS_BUNDLE_ID \
  -u AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID \
  -u AGENT_ISLAND_ENTITLEMENTS \
  -u AGENT_ISLAND_PROVISIONING_PROFILE \
  -u AGENT_ISLAND_DISPLAY_NAME \
  -u AGENT_ISLAND_PRIVACY_POLICY_URL \
  -u AGENT_ISLAND_SUPPORT_URL \
  -u AGENT_ISLAND_DEVELOPMENT_TEAM \
  -u AGENT_ISLAND_ICLOUD_CONTAINER_ID \
  -u AGENT_ISLAND_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED \
  -u AGENT_ISLAND_IOS_REAL_DEVICE_SYNC_VERIFIED \
  -u AGENT_ISLAND_IOS_LIVE_ACTIVITY_VERIFIED \
  -u AGENT_ISLAND_IOS_REVIEW_PATH_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PROJECT \
  -u AGENT_ISLAND_MAC_APP_STORE_SCHEME \
  -u AGENT_ISLAND_APP_STORE_RECORD_MODE \
  -u AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED \
  "$PROJECT_DIR/scripts/release-readiness.sh" | jq -e '
  (.fullXcode | type == "boolean") and
  (.macDeveloperIDToolchainConfigured | type == "boolean") and
  (.developerPath | type == "string") and
  ((.xcodeVersion == null) or (.xcodeVersion | type == "string")) and
  ((.iphoneSDK == null) or (.iphoneSDK | type == "string")) and
  (.currentUploadToolchain | type == "boolean") and
  (.currentMacAppStoreToolchain | type == "boolean") and
  (.validSigningIdentities | type == "number") and
  (.developerIDApplicationIdentities | type == "number") and
  (.developerIDIdentityConfigured | type == "boolean") and
  (.appleDevelopmentIdentities | type == "number") and
  (.appleDistributionIdentities | type == "number") and
  (.appleDistributionTeamIdentities | type == "number") and
  (.appleDistributionTeamIdentityConfigured | type == "boolean") and
  (.availableDiskGiB | type == "number") and
  (.enoughDiskForXcode | type == "boolean") and
  (.macDistributionArchiveSetClean | type == "boolean") and
  (.ambiguousMacDistributionArchives | type == "array") and
  (.macDistributionArchiveSetClean == ((.ambiguousMacDistributionArchives | length) == 0)) and
  (.productionBundleIDConfigured | type == "boolean") and
  (.productionDisplayNameConfigured | type == "boolean") and
  ((.productionDisplayName == null) or (.productionDisplayName | type == "string")) and
  (.iosAppBundleIDConfigured | type == "boolean") and
  (.iosWidgetBundleIDConfigured | type == "boolean") and
  (.notaryProfileConfigured | type == "boolean") and
  (.cloudKitEntitlementsConfigured | type == "boolean") and
  (.cloudKitContainerConfigured | type == "boolean") and
  (.provisioningProfileConfigured | type == "boolean") and
  (.provisioningProfileSigningCertificateConfigured | type == "boolean") and
  (.privacyPolicyURLConfigured | type == "boolean") and
  (.supportURLConfigured | type == "boolean") and
  (.iosDevelopmentTeamConfigured | type == "boolean") and
  (.iosCloudKitContainerConfigured | type == "boolean") and
  (.iosPrivacyPolicyURLConfigured | type == "boolean") and
  (.iosSupportURLConfigured | type == "boolean") and
  (.cloudKitProductionSchemaVerified | type == "boolean") and
  (.iosRealDeviceSyncVerified | type == "boolean") and
  (.iosLiveActivityVerified | type == "boolean") and
  (.iosReviewPathVerified | type == "boolean") and
  (.iosProjectConfigured | type == "boolean") and
  (.iosPrivacyManifestPresent | type == "boolean") and
  (.iosAppIconPresent | type == "boolean") and
  (.iosSyncTransportImplemented | type == "boolean") and
  (.macAppStoreProjectPath | type == "string") and
  (.macAppStoreScheme | type == "string") and
  ((.macAppStoreTargetName == null) or (.macAppStoreTargetName | type == "string")) and
  ((.macAppStoreEntitlementsPath == null) or (.macAppStoreEntitlementsPath | type == "string")) and
  ((.macAppStoreInfoPlistPath == null) or (.macAppStoreInfoPlistPath | type == "string")) and
  (.macAppStoreXcodeProjectConfigured | type == "boolean") and
  (.macAppStoreTargetMembershipConfigured | type == "boolean") and
  (.macAppStoreRuntimeResourcesInTarget | type == "boolean") and
  (.macAppStoreBuildSettingsMatch | type == "boolean") and
  (.macPrivacyManifestInAppTarget | type == "boolean") and
  (.macAppStoreInfoPlistConfigured | type == "boolean") and
  (.macAppSandboxEntitlementConfigured | type == "boolean") and
  (.macUserSelectedReadOnlyEntitlementConfigured | type == "boolean") and
  (.macAppScopeBookmarkEntitlementConfigured | type == "boolean") and
  (.macNetworkClientEntitlementConfigured | type == "boolean") and
  (.macAppStoreCloudKitEntitlementConfigured | type == "boolean") and
  (.macAppStoreEntitlementsConfigured | type == "boolean") and
  (.macSecurityScopedBookmarkMarkersPresent | type == "boolean") and
  (.macAutomaticHomeScanMarkersPresent | type == "boolean") and
  (.macPrivacySourceReady | type == "boolean") and
  (.macPrivacyReleaseEvidenceReady | type == "boolean") and
  (.storeSubmissionAssetsReady | type == "boolean") and
  (.appStoreRecordModeConfigured | type == "boolean") and
  ((.appStoreRecordMode == null) or (.appStoreRecordMode | type == "string")) and
  (.universalPurchaseBundleIDsMatch | type == "boolean") and
  (.appStoreRecordModeBundleIDsValid | type == "boolean") and
  (.macAppStoreSandboxFlowVerified | type == "boolean") and
  (.macAppStoreArchiveVerified | type == "boolean") and
  (.macAppStoreProfileCertificateVerified | type == "boolean") and
  (.macAppStorePrivacyReportVerified | type == "boolean") and
  (.macAppStoreReviewPathVerified | type == "boolean") and
  (.readyForDeveloperIDRelease | type == "boolean") and
  (.readyForMacAppStoreArchive | type == "boolean") and
  (.readyForFunctionalMacAppStoreSubmission | type == "boolean") and
  (.readyForIOSArchive | type == "boolean") and
  (.readyForFunctionalIOSTestFlight | type == "boolean") and
  (.iosDevelopmentTeamConfigured == false) and
  (.developerIDIdentityConfigured == false) and
  (.productionDisplayNameConfigured == false) and
  (.provisioningProfileSigningCertificateConfigured == false) and
  (.cloudKitContainerConfigured == false) and
  (.iosCloudKitContainerConfigured == false) and
  (.iosPrivacyPolicyURLConfigured == false) and
  (.iosSupportURLConfigured == false) and
  (.cloudKitProductionSchemaVerified == false) and
  (.iosRealDeviceSyncVerified == false) and
  (.iosLiveActivityVerified == false) and
  (.iosReviewPathVerified == false) and
  (.appleDistributionTeamIdentityConfigured == false) and
  (.appStoreRecordModeConfigured == false) and
  (.appStoreRecordMode == null) and
  (.universalPurchaseBundleIDsMatch == false) and
  (.appStoreRecordModeBundleIDsValid == false) and
  (.macAppStoreSandboxFlowVerified == false) and
  (.macAppStoreArchiveVerified == false) and
  (.macAppStoreProfileCertificateVerified == false) and
  (.macAppStorePrivacyReportVerified == false) and
  (.macAppStoreReviewPathVerified == false) and
  (.readyForMacAppStoreArchive == false) and
  (.readyForFunctionalMacAppStoreSubmission == false) and
  (.readyForFunctionalIOSTestFlight == false)
' >/dev/null

/usr/bin/env \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  "$PROJECT_DIR/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == true and
    .appStoreRecordModeBundleIDsValid == true
  ' >/dev/null
/usr/bin/env \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='separate-records' \
  "$PROJECT_DIR/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == true and
    .appStoreRecordModeBundleIDsValid == false
  ' >/dev/null
/usr/bin/env \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mac' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.ios' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='separate-records' \
  "$PROJECT_DIR/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == false and
    .appStoreRecordModeBundleIDsValid == true
  ' >/dev/null

DEVELOPER_ID_READINESS_BLOCK="$(/usr/bin/sed -n \
  '/^READY_DEVELOPER_ID=false$/,/^READY_IOS_ARCHIVE=false$/p' \
  "$PROJECT_DIR/scripts/release-readiness.sh")"
if [[ "$DEVELOPER_ID_READINESS_BLOCK" == *'MAC_APP_STORE'* ]]; then
  echo "Mac App Store gates leaked into Developer ID readiness" >&2
  exit 1
fi

/usr/bin/env \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.release' \
  AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID='com.agentisland.release.liveactivity' \
  AGENT_ISLAND_ENTITLEMENTS="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_PROVISIONING_PROFILE="$PROJECT_DIR/Tests/Fixtures/release-cloudkit.entitlements" \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://agentisland.app/privacy' \
  AGENT_ISLAND_SUPPORT_URL='https://agentisland.app/support' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.releasefixture' \
  "$PROJECT_DIR/scripts/release-readiness.sh" | jq -e '
    (.cloudKitEntitlementsConfigured == true) and
    (.productionDisplayNameConfigured == true) and
    (.productionDisplayName == "MAC版灵动岛--Agent运行监测") and
    (.cloudKitContainerConfigured == true) and
    (.provisioningProfileConfigured == false) and
    (.provisioningProfileSigningCertificateConfigured == false) and
    (.privacyPolicyURLConfigured == true) and
    (.supportURLConfigured == true) and
    (.iosDevelopmentTeamConfigured == true) and
    (.iosCloudKitContainerConfigured == true) and
    (.iosPrivacyPolicyURLConfigured == true) and
    (.iosSupportURLConfigured == true)
  ' >/dev/null
[[ -f "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -f "$APP_PATH/Contents/Resources/AgentIsland.icns" ]]
[[ -f "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" ]]
[[ "$(plutil -extract CFBundleIconFile raw "$APP_PATH/Contents/Info.plist")" == "AgentIsland" ]]
/usr/bin/plutil -lint "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" >/dev/null
[[ "$(plutil -extract NSPrivacyTracking raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "false" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataType raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "NSPrivacyCollectedDataTypeOtherUsageData" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeLinked raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "true" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeTracking raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "false" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.1.NSPrivacyCollectedDataType raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "NSPrivacyCollectedDataTypeOtherUserContent" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.1.NSPrivacyCollectedDataTypeLinked raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "true" ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes.1.NSPrivacyCollectedDataTypeTracking raw "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy")" == "false" ]]
for SENSITIVE_PERMISSION_KEY in NSCameraUsageDescription NSMicrophoneUsageDescription NSScreenCaptureUsageDescription NSAppleEventsUsageDescription; do
  if /usr/bin/plutil -extract "$SENSITIVE_PERMISSION_KEY" raw "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Desktop build unexpectedly requests $SENSITIVE_PERMISSION_KEY" >&2
    exit 1
  fi
done
cmp -s "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy"
cmp -s "$PROJECT_DIR/Resources/AgentIsland.icns" "$APP_PATH/Contents/Resources/AgentIsland.icns"
cmp -s "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
rg -q 'TO-DO Panel.*v1\.0\.5' "$PROJECT_DIR/THIRD_PARTY_NOTICES.md"
rg -q 'e69cccaa27dd13333f6eeee483ac9187bade2299' "$PROJECT_DIR/THIRD_PARTY_NOTICES.md"
rg -q 'Copyright \(c\) 2026 TO-DO Panel contributors' "$PROJECT_DIR/THIRD_PARTY_NOTICES.md"
rg -q 'THE SOFTWARE IS PROVIDED "AS IS"' "$PROJECT_DIR/THIRD_PARTY_NOTICES.md"
rg -q -- '-framework Security' "$PROJECT_DIR/scripts/build-app.sh"
rg -q -- '-framework CloudKit' "$PROJECT_DIR/scripts/build-app.sh"
otool -L "$BINARY" | rg -q '/Security.framework/'
otool -L "$BINARY" | rg -q '/CloudKit.framework/'
EDIT_SHORTCUT_AUDIT="$($BINARY --self-test-edit-shortcuts)"
print -r -- "$EDIT_SHORTCUT_AUDIT" | /usr/bin/jq -e '
  .ok == true and .menuValid == true and .fallbackValid == true and
  .usesResponderActions == true and .readsPasteboard == false and
  .requiresAccessibility == false and
  (.actions | sort) == ["copy:", "cut:", "paste:", "redo:", "selectAll:", "undo:"]
' >/dev/null
for EDIT_MARKER in 'AIInstallApplicationMainMenu();' '- (BOOL)performKeyEquivalent:(NSEvent *)event' \
  '@selector(undo:)' '@selector(redo:)' '@selector(cut:)' '@selector(copy:)' \
  '@selector(paste:)' '@selector(selectAll:)' '[NSApp sendAction:action to:nil from:self]'; do
  rg -q --fixed-strings -- "$EDIT_MARKER" "$PROJECT_DIR/Native/AgentIsland.m"
done
if rg -q 'NSPasteboard|AXUIElement|CGEventTap' "$PROJECT_DIR/Native/AgentIsland.m"; then
  echo "Standard editing shortcuts must not use pasteboard polling, Accessibility, or event taps" >&2
  exit 1
fi
for CLOUDKIT_CONTRACT in \
  'AGENT_ISLAND_CLOUDKIT_RECORD_TYPE = AgentIslandSnapshot' \
  'AGENT_ISLAND_CLOUDKIT_RECORD_NAME = latest' \
  'AGENT_ISLAND_CLOUDKIT_PAYLOAD_FIELD = payloadJSON'; do
  rg -q --fixed-strings "$CLOUDKIT_CONTRACT" "$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
done

/usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation")
function run(argv) {
  const value = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null)
  const html = ObjC.unwrap(value)
  const nativeValue = $.NSString.stringWithContentsOfFileEncodingError(argv[1], $.NSUTF8StringEncoding, null)
  const nativeSource = ObjC.unwrap(nativeValue)
  const match = html.match(/<script>([\s\S]*)<\/script>/)
  if (!match) throw new Error("Web/index.html is missing its inline script")
  const source = match[1]
  const styleMatch = html.match(/<style>([\s\S]*?)<\/style>/)
  if (!styleMatch) throw new Error("Web/index.html is missing its stylesheet")
  const stylesheet = styleMatch[1]
  if (!/Content-Security-Policy[^>]*connect-src\s+\x27none\x27/.test(html)) throw new Error("WKWebView must not make network requests directly")
  Function(source)
  const dictionary = source.match(/(?:const|let|var)\s+messages\s*=\s*(\{[\s\S]*?\})\s*;\s*\n\s*function\s+\$\s*\(/)
  if (!dictionary) throw new Error("Web language dictionaries are missing")
  const messages = Function("return (" + dictionary[1] + ")")()
  const zhKeys = Object.keys(messages.zh).sort()
  const enKeys = Object.keys(messages.en).sort()
  if (JSON.stringify(zhKeys) !== JSON.stringify(enKeys)) throw new Error("zh/en dictionary keys differ")
  if (/[\u3400-\u9fff]/.test(JSON.stringify(messages.en))) throw new Error("English dictionary contains Chinese text")
  const variables = text => {
    const found = [], expression = /\{(\w+)\}/g
    let item
    while ((item = expression.exec(String(text)))) found.push(item[1])
    return [...new Set(found)].sort().join(",")
  }
  for (const key of zhKeys) {
    if (variables(messages.zh[key]) !== variables(messages.en[key])) throw new Error("Template variables differ for " + key)
  }
  const referenced = new Set()
  const attribute = /data-i18n(?:-(?:title|aria-label|placeholder))?="([^"]+)"/g
  let item
  while ((item = attribute.exec(html))) referenced.add(item[1])
  for (const key of referenced) {
    if (!(key in messages.zh) || !(key in messages.en)) throw new Error("Missing translation for " + key)
  }
  const requiredCopy = ["monitor", "workspace", "translateLearn", "settings", "favoriteSites", "notes", "quickTranslator",
    "agentComponents", "runningTools", "executingAgents", "activeConversations", "activeTokens", "usageHistory",
    "readableHistoryTotal", "historyBreakdown", "historyRecords", "localHistoryDisclaimer", "cloudSyncTitle",
    "staysOnMac", "sentToPrivateCloud", "enableCloudSync", "includeConversationTitles", "privacyAndSupport",
    "cloudAccountBindingDetail", "confirmRebindCloud", "dataAccessTitle", "readOnlyMonitoring",
    "contentExcluded", "noSensitivePermissions", "monitoringControl", "reviewDataAccess", "checkUpdates", "safeUpdateHint",
    "translationTransferNoticeDeepSeek", "translationConsentEyebrow", "translationConsentTitle",
    "translationConsentDeepSeek", "translationConsentCustom", "translationConsentAuthority",
    "translationConsentCancel", "translationConsentContinue", "studySearchRegion", "searchStudy",
    "studyStatusFilter", "studyFilterAll", "studyFilterLearning", "studyResultSummary", "noMatchingStudy"]
  for (const key of requiredCopy) {
    if (!(key in messages.zh) || !(key in messages.en)) throw new Error("Missing workspace translation for " + key)
    if (!/[\u3400-\u9fff]/.test(messages.zh[key])) throw new Error("Chinese copy is not localized for " + key)
    if (String(messages.zh[key]) === String(messages.en[key])) throw new Error("Chinese and English copy are identical for " + key)
  }
  for (const id of ["view-monitor", "view-workspace", "view-translator", "view-settings", "monitorStats", "toolGrid",
    "activeTasks", "sitesGrid", "siteEditor", "notesGrid", "translationInput", "translationResult", "studyList",
    "studySearch", "studyStatusFilter", "studyResultCount",
    "translatorBaseURL", "translatorModel", "translatorAPIKey", "monitor-live", "monitor-history", "historyStats",
    "historyBreakdown", "historyToolTotals", "historySearch", "historyToolFilter", "historyRecords", "historyMore",
    "cloudSyncCard", "cloudSyncSwitch", "cloudTitlesSwitch", "syncCloudNowButton", "cloudSyncStatus",
    "dataAccessCard", "monitoringSwitch", "reviewDataAccessButton", "dataAccessStatus",
    "privacyPolicyButton", "supportButton", "checkUpdatesButton", "releaseLinksStatus",
    "translationConsentDialog", "translationConsentBody", "deepSeekPolicyLinks", "deepSeekPrivacyButton",
    "deepSeekTermsButton", "translationAppPrivacyButton"]) {
    if (!html.includes(`id="${id}"`)) throw new Error("Missing workspace DOM node: " + id)
  }
  for (const required of ["document.documentElement.lang", "agentIsland.language", "bridge(", "setLanguage",
    "snapshot.tools", "snapshot.workspace", "snapshot.translator", "snapshot.usageHistory", "toolName", "agentExtensions", "taskSummary",
    "conversationTitle", "sessionConversationTitle",
    "workspaceSave", "openURL", "configureTranslator", "translate", "translationResult", "snapshot.cloudSync",
    "configureCloudSync", "syncCloudNow", "openReleaseLink", "cloudSyncResult", "releaseLinkResult",
    "reviewDataAccess", "setMonitoringEnabled", "dataAccessResult"]) {
    if (!source.includes(required)) throw new Error("Missing Web integration: " + required)
  }
  for (const consentMarker of ["translationTransferNotice", "translationTransferNoticeDeepSeek",
    "translationConsentDeepSeek", "translationConsentCustom", "showTranslationConsent",
    "confirmTranslationTransfer", "agentIsland.translationConsentDestination.v2",
    "https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html",
    "https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html"]) {
    if (!source.includes(consentMarker)) throw new Error("Missing explicit translation transfer consent: " + consentMarker)
  }
  for (const consentMarker of ["confirmEnableCloud", "confirmDisableCloud", "confirmIncludeTitles",
    "consentConfirmed", "titleConsentConfirmed", "accountChangeConfirmed", "confirmRebindCloud",
    "sentToPrivateCloudDetail", "staysOnMacDetail", "cloudAccountBindingDetail"]) {
    if (!source.includes(consentMarker)) throw new Error("Missing explicit CloudKit privacy consent: " + consentMarker)
  }
  if (!/return\s*\{sites:sites,notes:notes,study:study\}/.test(source)) throw new Error("Workspace must normalize sites, notes, and study arrays")
  for (const bridgeContract of [
    /bridge\("workspaceSave",\{workspace:workspace,requestId:requestId,revision:state\.workspaceRevision\}\)/,
    /bridge\("openURL",\{url:[^}]+\}\)/,
    /bridge\("configureTranslator",\{requestId:configRequestId,baseURL:baseURL,model:model,apiKey:apiKey\}\)/,
    /bridge\("configureTranslator",\{requestId:clearRequestId,clearAPIKey:true\}\)/,
    /bridge\("translate",\{requestId:requestId,text:text,mode:mode,sourceLanguage:state\.sourceLanguage\}\)/,
    /bridge\("syncCloudNow",\{requestId:id\("cloud-sync-now"\)\}\)/,
    /bridge\("setMonitoringEnabled",\{enabled:enableMonitoring\}\)/,
    /bridge\("reviewDataAccess"\)/,
    /bridge\("openReleaseLink",\{kind:actionButton\.dataset\.kind\|\|""\}\)/
  ]) {
    if (!bridgeContract.test(source)) throw new Error("Missing or malformed Web bridge contract: " + bridgeContract)
  }
  for (const marker of ["workspaceHydrated", "workspaceRecoveryDirty", "workspaceRevision", "workspacePendingRequestId", "workspaceNativeRevision", "workspaceLoadStatus"]) {
    if (!source.includes(marker)) throw new Error("Missing versioned workspace protection: " + marker)
  }
  for (const field of ["translation", "definition", "breakdown", "keywords", "examples", "error", "usage"]) {
    if (!source.includes(field)) throw new Error("Translation result field is not consumed: " + field)
  }
  const studyHelpersMatch = source.match(/function normalizedStudySearchText\(value\)[\s\S]*?function studyMatchesStatus\(item,status\)[\s\S]*?\n\s*}/)
  if (!studyHelpersMatch) throw new Error("Study search/status helpers are missing")
  const normalizeFixtureList = value => Array.isArray(value) ? value : (value ? [String(value)] : [])
  const studyHelpers = Function("normalizedList", "normalizedBreakdown",
    studyHelpersMatch[0] + ";return {query:studyMatchesQuery,status:studyMatchesStatus}")(
      normalizeFixtureList, normalizeFixtureList)
  const studyFixture = {
    original:"中文原文", translation:"Hello world", definition:"A greeting",
    keywords:["welcome"], breakdown:["interjection"], examples:["not indexed"], mastered:false
  }
  for (const query of ["中文原文", "HELLO", "greeting", "welcome", "interjection", "welcome interjection"]) {
    if (!studyHelpers.query(studyFixture, query)) throw new Error("Study search misses a required field: " + query)
  }
  if (studyHelpers.query(studyFixture, "absent")) throw new Error("Study search accepts unrelated text")
  if (!studyHelpers.status(studyFixture, "all") || !studyHelpers.status(studyFixture, "learning") ||
      studyHelpers.status(studyFixture, "mastered")) throw new Error("Study learning-status filter is incorrect")
  studyFixture.mastered = true
  if (!studyHelpers.status(studyFixture, "mastered") || studyHelpers.status(studyFixture, "learning"))
    throw new Error("Study mastered-status filter is incorrect")
  for (const marker of ["state.studyQuery=event.target.value", "state.studyStatus=[\"all\",\"learning\",\"mastered\"]",
    "studyMatchesStatus(item,state.studyStatus)&&studyMatchesQuery(item,state.studyQuery)",
    "t(\"studyResultSummary\",{shown:list.length,total:allItems.length})", "event.stopPropagation()"])
    if (!source.includes(marker)) throw new Error("Study search integration is missing: " + marker)
  if (!/if\(!allItems\.length\)[\s\S]{0,220}noStudyItems[\s\S]{0,220}if\(!list\.length\)[\s\S]{0,220}noMatchingStudy/.test(source))
    throw new Error("Study empty and no-result states must remain distinct")
  if (!/\.study-toolbar\s*\{[^}]*display\s*:\s*grid/.test(stylesheet) ||
      !/@media\s*\(max-width\s*:\s*480px\)[\s\S]*?\.study-toolbar\s*\{[^}]*grid-template-columns\s*:\s*1fr/.test(stylesheet))
    throw new Error("Study search controls must use the responsive large-type layout")
  if (!/<input[^>]+id="studySearch"[^>]+aria-controls="studyList"/.test(html) ||
      !/<select[^>]+id="studyStatusFilter"[^>]+aria-controls="studyList"/.test(html) ||
      !/<output[^>]+id="studyResultCount"[^>]+aria-live="polite"/.test(html))
    throw new Error("Study search controls must expose their result relationship accessibly")
  for (const field of ["data.definitions", "data.structure", "data.alternatives", "data.notes"]) {
    if (!source.includes(field)) throw new Error("Native translation structure is not mapped by Web: " + field)
  }
  for (const token of ["--fs-caption:14px", "--fs-body:16px", "--fs-emphasis:18px", "--fs-section:22px",
    "--fs-title:30px", "--fs-metric:34px", "min-height:44px"]) {
    if (!stylesheet.replace(/\s+/g, "").includes(token)) throw new Error("Missing large-type CSS contract: " + token)
  }
  const fontSizes = [...stylesheet.matchAll(/font-size\s*:\s*([0-9.]+)px/g)].map(match => Number(match[1]))
  if (fontSizes.some(size => size < 14)) throw new Error("Expanded interface contains text smaller than 14px")
  for (const width of [940, 700, 480]) {
    if (!(new RegExp(`@media\\s*\\(max-width\\s*:\\s*${width}px\\)`).test(stylesheet)))
      throw new Error("Missing responsive breakpoint: " + width)
  }
  if (!/@media\s*\(max-width\s*:\s*700px\)[\s\S]*?#dashboard\s*\{[^}]*grid-template-columns\s*:\s*1fr/.test(stylesheet))
    throw new Error("Narrow layouts must become a single-column dashboard")
  if (!/\.task-title\s*\{[^}]*white-space\s*:\s*nowrap[^}]*text-overflow\s*:\s*ellipsis/.test(stylesheet))
    throw new Error("Conversation titles must stay on one ellipsized line")
  if (!/\.site-grid\s*\{[^}]*grid-template-columns\s*:\s*repeat\(auto-fill,minmax\(320px,1fr\)\)/.test(stylesheet) ||
      !/\.site-card \.card-actions\s*\{[^}]*display\s*:\s*grid[^}]*grid-template-columns/.test(stylesheet) ||
      !source.includes("class=\"site-main\""))
    throw new Error("Favorite-site cards must keep identity and all actions in a stable responsive layout")
  if (!/\.form-message:empty\s*\{[^}]*display\s*:\s*none/.test(stylesheet) ||
      !/@media\s*\(max-width\s*:\s*700px\)[\s\S]*?\.site-grid\s*\{[^}]*grid-template-columns\s*:\s*repeat\(2,minmax\(0,1fr\)\)/.test(stylesheet) ||
      !/@media\s*\(max-width\s*:\s*620px\)[\s\S]*?\.site-grid\s*\{[^}]*grid-template-columns\s*:\s*1fr/.test(stylesheet))
    throw new Error("Favorite-site cards must remove empty status gaps and adapt from two columns to one")
  if (!/return String\(item\.conversationTitle\|\|item\.taskSummary\|\|item\.currentTask\|\|item\.name/.test(source))
    throw new Error("Conversation title fallback order is incorrect")
  if (!nativeSource.includes("@\"conversationTitle\"") || !nativeSource.includes("@\"titleSource\""))
    throw new Error("Native collectors must expose conversation title provenance")
  if (!/if \(includeTitles && AIMobileTitleSourceIsExplicit\(session\[@"titleSource"\]\)\)/.test(nativeSource))
    throw new Error("CloudKit titles must come only from an explicit title field")
  for (const secretGuard of ["api key", "api_key", "authorization:", "bearer ", "token=", "sk-"])
    if (!nativeSource.includes(secretGuard)) throw new Error("CloudKit title sanitizer is missing secret guard: " + secretGuard)
  if (!/sourceDevice": @\{@"id": @"mac", @"name": @"Mac", @"platform": @"macOS"\}/.test(nativeSource))
    throw new Error("Mobile snapshots must use a non-identifying constant device descriptor")
  if (!/cloudSyncSwitch"\)\.disabled=state\.cloudSyncPending\|\|\(!cloudCapable&&!cloudEnabled\)/.test(source))
    throw new Error("An already-enabled sync preference must remain possible to turn off")
  if (!/accountReconfirmation=enableCloud&&!!state\.cloudSync\.requiresAccountReconfirmation/.test(source) ||
      !/accountChangeConfirmed:accountReconfirmation/.test(source))
    throw new Error("Cloud account changes must require a fresh Web confirmation")
  if (!/function usageHistoryModel\(\)/.test(source) || !/function renderUsageHistory\(\)/.test(source) ||
      !/data-monitor-mode="history"/.test(html))
    throw new Error("Usage history view is incomplete")
  if (!/state\.historyQuery=event\.target\.value/.test(source) || !/state\.historyTool=event\.target\.value/.test(source))
    throw new Error("Usage history must support conversation and tool filtering")
  if (!nativeSource.includes("@\"dailyAvailable\": @NO") ||
      !nativeSource.includes("@\"attribution\": @\"sessionLifetime\""))
    throw new Error("Native history must not present session lifetime totals as daily usage")

  const translationFixtures = [
    {requestId:"nested",ok:true,result:{translation:"Hello",definition:"greeting",breakdown:["hello"],keywords:["hello"],examples:["Hello world"]},usage:{total:7},error:""},
    {requestId:"flat",ok:false,translation:"",definition:"",breakdown:[],keywords:[],examples:[],usage:null,error:"offline fixture"}
  ]
  for (const fixture of translationFixtures) {
    if (typeof fixture.requestId !== "string" || typeof fixture.ok !== "boolean") throw new Error("Invalid translation fixture envelope")
    const result = fixture.result || fixture
    for (const field of ["translation", "definition", "breakdown", "keywords", "examples"])
      if (!(field in result)) throw new Error("Translation fixture is missing " + field)
    if (!("usage" in fixture) || !("error" in fixture)) throw new Error("Translation fixture is missing usage/error")
  }
  const nativeFixture={requestId:"native",ok:true,result:{translation:"你好",definitions:[{term:"hello",meaning:"a greeting"}],structure:{summary:"greeting",segments:[{text:"hello",role:"interjection",explanation:"used when meeting"}],grammarPoints:["interjection"]},alternatives:["Hi"],notes:["informal"]},usage:{total:9},error:""}
  if (!nativeFixture.result.definitions[0].meaning || !nativeFixture.result.structure.segments[0].explanation ||
      !nativeFixture.result.structure.grammarPoints.length || !nativeFixture.result.alternatives.length)
    throw new Error("Native translation fixture cannot populate learning sections")
  if (/localStorage\.setItem\([^;\n]*apiKey/i.test(source)) throw new Error("Web UI must not persist the translator API key")
  if (!source.includes("$(\"#translatorAPIKey\").value=\"\"")) throw new Error("Web UI must clear the API key input after submission")
  if (!/-\s*\(void\)openExternalURL:[\s\S]{0,2400}AIValidatedExternalURL/.test(nativeSource))
    throw new Error("openURL must pass through AIValidatedExternalURL")
  if (!/AITranslatorPublicConfig\([\s\S]{0,1000}@"hasAPIKey"/.test(nativeSource))
    throw new Error("Translator snapshot must expose only hasAPIKey")
  if (!/AITranslatorKeychainService\(void\)[\s\S]{0,500}NSBundle\.mainBundle\.bundleIdentifier/.test(nativeSource) ||
      !/kSecAttrService:\s*AITranslatorKeychainService\(\)/.test(nativeSource))
    throw new Error("Translator Keychain service must follow the release bundle identifier")
  if (!/<button id="compact"[^>]*aria-controls="dashboard"[^>]*aria-expanded="false"/.test(html))
    throw new Error("Compact island must expose its expanded state accessibly")
  if (!/<span class="compact-status" id="compactStatus" aria-live="polite">/.test(html) ||
      !/compactWorking:"\{agents\} 个 Agent 工作中"/.test(source) ||
      !/compactIdle:"暂无 Agent 工作"/.test(source) ||
      !/compactWorking:"\{agents\} Agents active"/.test(source) ||
      !/compactIdle:"No Agents active"/.test(source))
    throw new Error("Compact island must show only a localized one-line Agent activity status")
  const compactMarkup=(html.match(/<button id="compact"[\s\S]*?<\/button>/)||[])[0]||""
  if ((compactMarkup.match(/<span\b/g)||[]).length!==1 || /compact-(?:title|sub|usage|chevron|spacer|copy)|status-orb/.test(compactMarkup))
    throw new Error("Compact island must contain exactly one visible status line")
  for (const removedCompactNode of ["compactOrb", "compactTitle", "compactSub", "compactTokens", "compactUsageLabel"])
    if (html.includes(`id="${removedCompactNode}"`)) throw new Error("Compact island still exposes unrelated content: " + removedCompactNode)
  if (!/\.compact-status\s*\{[^}]*font-size\s*:\s*14px[^}]*white-space\s*:\s*nowrap[^}]*overflow\s*:\s*hidden[^}]*text-overflow\s*:\s*ellipsis/.test(stylesheet))
    throw new Error("Compact Agent status must remain a single readable line")
  if (!/#compact\s*\{[^}]*border\s*:\s*0[^}]*border-radius\s*:\s*17px[^}]*box-shadow\s*:\s*none[^}]*overflow\s*:\s*hidden/.test(stylesheet) ||
      /#compact\s*:\s*after/.test(stylesheet))
    throw new Error("Compact island must be a clean four-corner pill without translucent decorations")
  if (!/function renderCompact\(\)\{[\s\S]{0,900}status=t\("compactWorking",\{agents:active\.length\}\)[\s\S]{0,500}\$\("#compactStatus"\)\.textContent=status/.test(source))
    throw new Error("Compact island activity count is not wired to the one-line status")
  if (!/var live=state\.dataAccess\.monitoringEnabled&&!!state\.snapshot\.scannedAt&&active\.length>0/.test(source))
    throw new Error("Stale Agent activity must not appear live while monitoring is off or before the first scan")
  if (!/AICompactIslandWidth\s*=\s*220\.0/.test(nativeSource) ||
      !/AICompactIslandHeight\s*=\s*34\.0/.test(nativeSource) ||
      !/NSMakeRect\(0, 0,\s*AICompactIslandWidth, AICompactIslandHeight\)/.test(nativeSource) ||
      !/MIN\(AICompactIslandHeight, MAX\(1, anchor\.size\.height\)\)/.test(nativeSource))
    throw new Error("Native compact island must remain at the reduced 220-by-34-point size")
  if ((nativeSource.match(/self\.panel\.hasShadow = NO;/g)||[]).length < 2 ||
      !/_expanded = expanded;\s*self\.panel\.hasShadow = NO;\s*\[self\.panel invalidateShadow\];/.test(nativeSource) ||
      /self\.panel\.hasShadow = (?:YES|expanded);/.test(nativeSource))
    throw new Error("Native window shadow must stay disabled in both compact and expanded states")
  for (const nativeClipMarker of ["AIIslandClipView", "- (BOOL)isOpaque { return NO; }",
    "self.panel.contentView = self.panelClipView;", "self.panelClipView.layer.cornerRadius = radius;",
    "self.panelClipView.layer.cornerCurve = kCACornerCurveContinuous;",
    "self.panelClipView.layer.masksToBounds = YES;", "[self updatePanelClipShape];"]) {
    if (!nativeSource.includes(nativeClipMarker)) throw new Error("Native rounded-window clipping is incomplete: " + nativeClipMarker)
  }
  if (/setValue:[^\n]*drawsBackground|forKey:[^\n]*drawsBackground/.test(nativeSource))
    throw new Error("Rounded clipping must not rely on private WKWebView drawsBackground KVC")
  if (!/#dashboard\s*\{[^}]*border-radius\s*:\s*30px/.test(stylesheet))
    throw new Error("Expanded dashboard and native clip must share a full rounded shape")
  if (!/setExpanded:function\(value,shouldFocus\)/.test(source) ||
      !/if\(shouldFocus!==false\)requestAnimationFrame/.test(source))
    throw new Error("Hover expansion must not move Web focus")
  const hoverMethod = nativeSource.match(/- \(void\)handlePanelHover:\(BOOL\)inside[\s\S]*?\n}\n\n- \(void\)windowDidBecomeKey:/)
  if (!hoverMethod || !/activate:NO fromHover:YES/.test(hoverMethod[0]))
    throw new Error("Native hover path must use non-activating expansion")
  if (/activateIgnoringOtherApps|makeKeyAndOrderFront/.test(hoverMethod[0]))
    throw new Error("Hover tracking must not steal the current app focus")
  const launchMethod = nativeSource.match(/- \(void\)applicationDidFinishLaunching:[\s\S]*?\n}\n\n- \(BOOL\)applicationShouldTerminateAfterLastWindowClosed:/)
  if (!launchMethod || !/AIDataAccessConsentDefaultsKey/.test(launchMethod[0]) ||
      !/if \(self\.monitoringEnabled\)[\s\S]*?\[self startMonitoring\]/.test(launchMethod[0]) ||
      !/presentDataAccessDisclosureAllowingStart:YES/.test(launchMethod[0]))
    throw new Error("GUI launch must obtain data-access consent before starting monitoring")
  if (/timerWithTimeInterval|\[self refreshSnapshot\]/.test(launchMethod[0]))
    throw new Error("GUI launch must not directly schedule or run a scan before consent")
  const startMonitoringMethod = nativeSource.match(/- \(void\)startMonitoring[\s\S]*?\n}\n\n- \(void\)stopMonitoring/)
  if (!startMonitoringMethod || !/!self\.dataAccessConsented \|\| !self\.monitoringEnabled/.test(startMonitoringMethod[0]) ||
      !/timerWithTimeInterval:8\.0/.test(startMonitoringMethod[0]) || !/\[self refreshSnapshot\]/.test(startMonitoringMethod[0]))
    throw new Error("Periodic refresh must be created only by the consent-gated monitoring starter")
  const refreshMethod = nativeSource.match(/- \(void\)refreshSnapshot[\s\S]*?\n}\n\n- \(void\)pushSnapshot:/)
  if (!refreshMethod || refreshMethod[0].indexOf("!self.dataAccessConsented || !self.monitoringEnabled") < 0 ||
      refreshMethod[0].indexOf("!self.dataAccessConsented || !self.monitoringEnabled") > refreshMethod[0].indexOf("AISnapshot()"))
    throw new Error("Every GUI snapshot read must be guarded by current monitoring consent")
  const disclosureMethod = nativeSource.match(/- \(void\)presentDataAccessDisclosureAllowingStart:[\s\S]*?\n}\n\n- \(void\)setMonitoringEnabledFromBody:/)
  for (const marker of ["Codex", "Claude", "IDE Agent", "prompt", "response bodies", "iPhone/iCloud sync",
    "Camera", "Microphone", "Screen Recording", "Accessibility", "AIDataAccessConsentVersion"]) {
    if (!disclosureMethod || !disclosureMethod[0].includes(marker)) throw new Error("Data-access notice is incomplete: " + marker)
  }
  if (!/data-kind="update"/.test(html) || !/safeUpdateHint/.test(source) ||
      !/\[kind isEqual:@"update"\][\s\S]{0,500}@"AgentIslandSupportURL"/.test(nativeSource))
    throw new Error("Check for updates must open only the configured HTTPS support/download page")
  if (/SUUpdater|SPUStandardUpdaterController|Sparkle/.test(nativeSource + source))
    throw new Error("An unreviewed automatic updater must not be embedded")
  if (/AVCaptureDevice|CGRequestScreenCaptureAccess|CGPreflightScreenCaptureAccess|AXIsProcessTrusted|AXUIElementCreateApplication/.test(nativeSource))
    throw new Error("The desktop app must not request camera, microphone, screen-recording, or Accessibility access")
  return "ok"
}
' "$PROJECT_DIR/Web/index.html" "$PROJECT_DIR/Native/AgentIsland.m" >/dev/null

for NATIVE_MARKER in \
  'AIWorkspaceLoad' \
  'AIWorkspaceSave' \
  'AIWorkspaceWriteQueue' \
  'AIWorkspaceLoadAtURL' \
  '@"schemaVersion": @1' \
  '@"workspaceLoadStatus"' \
  '@"requestedRevision"' \
  '@"currentRevision"' \
  '@"saveStatus"' \
  '@"idempotent"' \
  '@"conflict"' \
  'workspace.json' \
  'NSDataWritingAtomic' \
  'AIValidatedExternalURL' \
  'AIValidatedTranslatorBaseURL' \
  'AIIsLoopbackHost' \
  'components.user.length' \
  'components.password.length' \
  'components.fragment.length' \
  'SecItemCopyMatching' \
  'SecItemAdd' \
  'SecItemUpdate' \
  'SecItemDelete' \
  'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' \
  'AICompactIslandWidth = 220.0' \
  'AICompactIslandHeight = 34.0' \
  'AICompactIslandWidth, AICompactIslandHeight' \
  'AIHoverWebView' \
  'NSTrackingMouseEnteredAndExited' \
  'NSTrackingActiveAlways' \
  'NSTrackingInVisibleRect' \
  'AIHoverExpandDelay = 0.15' \
  'AIHoverCollapseDelay = 0.45' \
  'expandedFromHover' \
  'pointerIsInsidePanelWithMargin:4' \
  'activate:NO fromHover:YES' \
  'hoverSuppressedUntil' \
  'AIUsageHistory' \
  '@"scope": @"availableLocalHistory"' \
  '@"dailyAvailable": @NO' \
  '@"attribution": @"sessionLifetime"' \
  'workspaceDelivered' \
  '@"workspaceSave"' \
  '@"openURL"' \
  '@"configureTranslator"' \
  '@"translate"' \
  '- (void)saveWorkspace:' \
  '- (void)openExternalURL:' \
  '- (void)configureTranslator:' \
  '- (void)translate:' \
  'NSURLSessionDataDelegate' \
  'AITranslatorMaximumResponseBytes' \
  'didReceiveResponse:' \
  'didReceiveData:' \
  'didCompleteWithError:' \
  'response_too_large' \
  'AISameURLOrigin' \
  '@"keyOperation"' \
  '@"setAPIKey"' \
  '@"clearAPIKey"' \
  'translationResult' \
  'AICloudSyncMaximumPayloadBytes' \
  'AICloudSyncMinimumUploadInterval = 60.0' \
  'AICloudSyncRecordType = @"AgentIslandSnapshot"' \
  'AICloudSyncRecordName = @"latest"' \
  'AICloudSyncPayloadField = @"payloadJSON"' \
  'AICloudSyncCapabilityConfigured' \
  'AIMobileSnapshotJSONData' \
  'AIValidateMobileSnapshotPayload' \
  'AIMobileTitleSourceIsExplicit' \
  'CKContainer defaultContainer' \
  'privateCloudDatabase' \
  'CKRecordSaveAllKeys' \
  'deleteRecordWithID' \
  'cloudSyncDeleteAfterUploadRequestID' \
  'CKAccountChangedNotification' \
  'fetchUserRecordIDWithCompletionHandler' \
  'AICloudAccountKeyForRecordName' \
  'CC_SHA256' \
  'accountReconfirmationRequired' \
  'stopCloudSyncForAccountChange' \
  'AIMobileSupportedToolKey' \
  'snapshot[@"tools"]' \
  '--self-test-cloud-account-binding' \
  '@"configureCloudSync"' \
  '@"syncCloudNow"' \
  '@"openReleaseLink"' \
  '@"cloudSyncResult"' \
  '@"releaseLinkResult"' \
  '--export-mobile-snapshot'; do
  rg -F -q -- "$NATIVE_MARKER" "$PROJECT_DIR/Native/AgentIsland.m"
done
if rg -q 'dataTaskWithRequest:request[[:space:]]+completionHandler:' "$PROJECT_DIR/Native/AgentIsland.m"; then
  echo "Translator must use bounded NSURLSessionDataDelegate streaming, not a completion-handler buffer" >&2
  exit 1
fi

"$BINARY" --snapshot | jq -e '
  (.sessions | type == "array") and
  (.tools | type == "array") and
  (.workspace | type == "object") and
  ((.workspace.sites // []) | type == "array") and
  ((.workspace.notes // []) | type == "array") and
  ((.workspace.study // []) | type == "array") and
  (.workspaceRevision | type == "number") and
  (.workspaceUpdatedAt | type == "number") and
  (.workspaceLoadStatus as $status | ["ok", "missing", "legacy", "corrupt", "io-error"] | index($status) != null) and
  (.workspaceMeta | type == "object") and
  (.workspaceMeta.revision == .workspaceRevision) and
  (.workspaceMeta.updatedAt == .workspaceUpdatedAt) and
  (.workspaceMeta.loadStatus == .workspaceLoadStatus) and
  (.translator | type == "object") and
  (.translator.baseURL | type == "string") and
  (.translator.model | type == "string") and
  (.translator.hasAPIKey | type == "boolean") and
  (.translator.networkMode == "explicit-only") and
  (.translator | has("apiKey") | not) and
  ([.translator | paths | select(.[-1] == "apiKey")] | length == 0) and
  (.cloudSync | type == "object") and
  (.cloudSync.enabled | type == "boolean") and
  (.cloudSync.includeTitles | type == "boolean") and
  (.cloudSync.capabilityConfigured | type == "boolean") and
  (.cloudSync.accountBound | type == "boolean") and
  (.cloudSync.requiresAccountReconfirmation | type == "boolean") and
  (.cloudSync | has("accountKey") | not) and
  ([paths as $path | select(($path[-1] | tostring) == "accountKey")] | length == 0) and
  (.cloudSync.database == "private") and
  (.cloudSync.container == "default") and
  (.cloudSync.recordType == "AgentIslandSnapshot") and
  (.cloudSync.recordName == "latest") and
  (.cloudSync.payloadField == "payloadJSON") and
  (.cloudSync.maximumPayloadBytes == 524288) and
  (.releaseLinks | type == "object") and
  (.releaseLinks.privacyPolicyConfigured == false) and
  (.releaseLinks.supportConfigured == false) and
  (.releaseLinks.updateConfigured == false) and
  (.warnings | type == "array") and
  (.scannedAt | type == "number") and
  (.language as $value | ["zh", "en"] | index($value) != null) and
  (.languagePreference as $value | ["system", "zh", "en"] | index($value) != null) and
  (.privacy.displaysPromptText == false) and
  (.privacy.storesPromptText == false) and
  (.privacy.automaticNetworkRequests == .cloudSync.enabled) and
  (.privacy.cloudSyncDefaultEnabled == false) and
  (.privacy.cloudSyncRequiresExplicitConsent == true) and
  (.privacy.translationTextStored == false) and
  (.privacy.workspaceStoredOnExplicitSave == true) and
  (.usageHistory | type == "object") and
  (.usageHistory.schemaVersion == 1) and
  (.usageHistory.scope == "availableLocalHistory") and
  (.usageHistory.attribution == "sessionLifetime") and
  (.usageHistory.dailyAvailable == false) and
  (.usageHistory.timeZone | type == "string") and
  (.usageHistory.sessionCount == ([.sessions[] | select(.total > 0)] | length)) and
  (.usageHistory.earliestAvailableAt | type == "number") and
  (.usageHistory.lastRecordedAt | type == "number") and
  (.usageHistory.totals.total == (([.sessions[] | .total] | add) // 0)) and
  (.usageHistory.totals.input == (([.sessions[] | .input] | add) // 0)) and
  (.usageHistory.totals.cached == (([.sessions[] | .cached] | add) // 0)) and
  (.usageHistory.totals.output == (([.sessions[] | .output] | add) // 0)) and
  (.usageHistory.totals.unknown == (([.sessions[] | .unknown] | add) // 0)) and
  (.usageHistory.totals.reasoning == (([.sessions[] | .reasoning] | add) // 0)) and
  (.usageHistory.totals.cached <= .usageHistory.totals.input) and
  (.usageHistory.byTool | type == "array") and
  (all(.usageHistory.byTool[];
    (.toolKey | type == "string") and (.toolName | type == "string") and
    (.sessionCount | type == "number") and (.total | type == "number")
  )) and
  ((([.usageHistory.byTool[] | .total] | add) // 0) == .usageHistory.totals.total) and
  ([.warnings[] | select(contains("数据结构与当前适配器不兼容") or test("schema.*incompatible"; "i"))] | length == 0) and
  (all(.tools[];
    (.id | type == "string") and
    (.name | type == "string") and
    (.kind as $kind | ["host", "agent", "extension"] | index($kind) != null) and
    (.installed | type == "boolean") and
    (.running | type == "boolean") and
    (.hostRunning | type == "boolean") and
    (.runtimeMs | type == "number") and
    (.sessionCount | type == "number") and
    (.activeSessionCount | type == "number") and
    (has("totalTokens")) and ((.totalTokens | type) as $type | $type == "number" or $type == "null") and
    (has("durationMs")) and ((.durationMs | type) as $type | $type == "number" or $type == "null") and
    (.telemetry as $telemetry | ["available", "shared", "unavailable"] | index($telemetry) != null) and
    (.locations | type == "array") and (all(.locations[]; type == "string")) and
    (.agentExtensions | type == "array") and
    (all(.agentExtensions[];
      (.id | type == "string") and
      (.name | type == "string") and
      (.version | type == "string") and
      (.telemetry | type == "string")
    )) and
    (if .telemetry == "unavailable"
      then .totalTokens == null and .durationMs == null
      else (.totalTokens | type == "number") and (.durationMs | type == "number")
    end)
  )) and
  (all(.sessions[];
    (.id | type == "string") and
    (.toolKey | type == "string") and
    (.toolName | type == "string") and
    (.conversationTitle | type == "string") and
    (.titleSource | type == "string") and
    (.taskSummary | type == "string") and
    (.total | type == "number") and
    (.durationMs | type == "number") and
    (.status as $status | ["working", "idle", "finished", "failed"] | index($status) != null) and
    (has("installed") | not) and
    (has("hostRunning") | not) and
    (has("agentExtensions") | not)
  ))
' >/dev/null

MOBILE_SNAPSHOT_PATH="$VERIFY_ROOT/mobile-snapshot.json"
"$BINARY" --export-mobile-snapshot >"$MOBILE_SNAPSHOT_PATH"
MOBILE_SNAPSHOT_BYTES="$(wc -c <"$MOBILE_SNAPSHOT_PATH" | tr -d '[:space:]')"
(( MOBILE_SNAPSHOT_BYTES > 1 && MOBILE_SNAPSHOT_BYTES <= 524289 ))
jq -e '
  def validUsage:
    (type == "object") and
    ((keys | sort) == (["total", "input", "cachedInput", "output", "reasoning", "unclassified"] | sort)) and
    (all(.[]; (type == "number") and . >= 0 and floor == .)) and
    (.cachedInput <= .input);
  def validState: . as $value | ["working", "idle", "completed", "failed"] | index($value) != null;
  ((keys | sort) == (["schemaVersion", "generatedAt", "sourceDevice", "usage", "agents", "sync"] | sort)) and
  (.schemaVersion == 1) and
  (.generatedAt | type == "number") and
  (.sourceDevice == {id:"mac", name:"Mac", platform:"macOS"}) and
  (.usage | validUsage) and
  (.agents | type == "array" and length <= 32) and
  (all(.agents[];
    ((keys | sort) == (["id", "displayName", "toolName", "state", "activeDurationSeconds", "usage", "conversations", "updatedAt"] | sort)) and
    (.id | test("^agent-[1-9][0-9]*$")) and
    (.displayName | type == "string") and (.toolName | type == "string") and
    (.state | validState) and
    (.activeDurationSeconds | type == "number" and . >= 0 and floor == .) and
    (.usage | validUsage) and
    (.conversations | type == "array" and length <= 25) and
    (.updatedAt | type == "number")
  )) and
  (([.agents[].id] | unique | length) == (.agents | length)) and
  ([.agents[].conversations[]] as $conversations |
    ($conversations | length <= 100) and
    (all($conversations[];
      ((keys | sort) == (["id", "safeSummary", "state", "activeDurationSeconds", "usage"] | sort)) and
      (.id | test("^conversation-[1-9][0-9]*-[1-9][0-9]*$")) and
      (.safeSummary == "") and (.state | validState) and
      (.activeDurationSeconds | type == "number" and . >= 0 and floor == .) and
      (.usage | validUsage) and (has("title") | not)
    )) and
    (([$conversations[].id] | unique | length) == ($conversations | length))
  ) and
  (.sync == {includesFullConversationTitles:false, receivedAt:.sync.receivedAt, transport:"cloudKit"}) and
  (.sync.receivedAt | type == "number") and
  ([paths as $path | ($path[-1] | tostring) |
    select(test("^(prompt|taskSummary|project|path|model|apiKey|notes?|workspace|translation|source|toolKey|parentThreadId)$"; "i"))] | length == 0) and
  ([.. | strings | select(test("(/Users/|/private/|/var/|~/|\\\\|API[ _-]?Key)"; "i"))] | length == 0)
' "$MOBILE_SNAPSHOT_PATH" >/dev/null

"$BINARY" --self-test-cloud-account-binding | jq -e '
  ((keys | sort) == (["sha256Fixture", "sameAccountMatches", "differentAccountMatches"] | sort)) and
  (.sha256Fixture == "ffc0636737cbd6545ab0543ef83ebe3e212f7d17389354b9c29c614fd874f8c5") and
  (.sha256Fixture | test("^[0-9a-f]{64}$")) and
  (.sameAccountMatches == true) and (.differentAccountMatches == false)
' >/dev/null

MOBILE_TOOL_RESULT="$VERIFY_ROOT/mobile-tool-snapshot.json"
"$BINARY" --export-mobile-snapshot "$MOBILE_TOOL_FIXTURE" >"$MOBILE_TOOL_RESULT"
jq -e '
  (.agents | length == 3) and
  (.agents[0].displayName == "Codex") and (.agents[0].state == "working") and
  (.agents[0].activeDurationSeconds == 3) and
  (.agents[0].conversations | length == 2) and
  (.agents[0].conversations[1].state == "completed") and
  (.agents[1].displayName == "Cursor") and (.agents[1].state == "completed") and
  (.agents[1].conversations == []) and (.agents[1].usage.total == 0) and
  (.agents[2].displayName == "Windsurf") and (.agents[2].state == "idle") and
  (.agents[2].conversations == []) and
  ([.agents[].displayName] | index("Agent Tool") == null) and
  ([.. | strings | select(contains("raw-session-id") or contains("/Users/example") or contains("secret-model"))] | length == 0)
' "$MOBILE_TOOL_RESULT" >/dev/null

"$BINARY" --validate-workspace-file "$WORKSPACE_ENVELOPE_FIXTURE" | jq -e '
  (.loadStatus == "ok") and (.revision == 7) and (.updatedAt == 1767225600000) and
  (.workspace.sites[0].id == "docs") and (.workspace.notes | type == "array") and
  (.workspace.study | type == "array")
' >/dev/null

"$BINARY" --validate-workspace-file "$WORKSPACE_LEGACY_FIXTURE" | jq -e '
  (.loadStatus == "legacy") and (.revision == 0) and (.updatedAt | type == "number") and
  (.workspace.notes[0].id == "legacy-note")
' >/dev/null

"$BINARY" --validate-workspace-file "$VERIFY_ROOT/missing-workspace.json" | jq -e '
  (.loadStatus == "missing") and (.revision == 0) and (.updatedAt == 0) and (.workspace == {})
' >/dev/null

if "$BINARY" --validate-workspace-file "$WORKSPACE_CORRUPT_FIXTURE" >"$VERIFY_ROOT/corrupt-workspace.json"; then
  echo "An incompatible workspace envelope was accepted" >&2
  exit 1
fi
jq -e '(.loadStatus == "corrupt") and (.revision == 0) and (.workspace == {})' \
  "$VERIFY_ROOT/corrupt-workspace.json" >/dev/null

"$BINARY" --validate-translator-url 'https://example.test/v1' | jq -e '
  (.valid == true) and (.endpoint == "https://example.test/v1/chat/completions")
' >/dev/null
"$BINARY" --validate-translator-url 'https://example.test/v1/chat/completions' | jq -e '
  (.valid == true) and (.endpoint == "https://example.test/v1/chat/completions")
' >/dev/null
if "$BINARY" --validate-translator-url 'http://example.test/v1' >"$VERIFY_ROOT/unsafe-translator-url.json"; then
  echo "A non-loopback HTTP translator URL was accepted" >&2
  exit 1
fi
jq -e '.valid == false and .endpoint == ""' "$VERIFY_ROOT/unsafe-translator-url.json" >/dev/null

"$BINARY" --validate-translation-response "$TRANSLATION_RESPONSE_FIXTURE" 'fixture request' | jq -e '
  (.requestId == "fixture request") and (.ok == true) and (.success == true) and
  (.result.translation == "你好") and (.result.definition == "用于见面问候") and
  (.result.breakdown[0].label == "hello · interjection") and
  (.result.breakdown[0].value == "见面时使用") and
  (.result.keywords[0].meaning == "问候语") and (.result.examples[0] == "嗨") and
  (.usage.input == 12) and (.usage.output == 8) and (.usage.total == 20)
' >/dev/null

dd if=/dev/zero of="$VERIFY_ROOT/oversize-translation-response.json" bs=1024 count=513 2>/dev/null
if "$BINARY" --validate-translation-response "$VERIFY_ROOT/oversize-translation-response.json" \
    'oversize request' >"$VERIFY_ROOT/oversize-translation-result.json"; then
  echo "A translation response larger than 512 KB was accepted" >&2
  exit 1
fi
jq -e '
  (.requestId == "oversize request") and (.ok == false) and (.errorCode == "response_too_large")
' "$VERIFY_ROOT/oversize-translation-result.json" >/dev/null

"$BINARY" --validate-jsonl "$FIXTURE" | jq -e '
  (.warnings | length == 0) and
  (.sessions | length == 1) and
  (.sessions[0].name == "Research Agent") and
  (.sessions[0].conversationTitle == "Weekly research brief") and
  (.sessions[0].titleSource == "custom.conversation_title") and
  (.sessions[0].toolKey | type == "string") and
  (.sessions[0].toolName | type == "string") and
  (.sessions[0].taskSummary | type == "string") and
  (.sessions[0] | has("installed") | not) and
  (.sessions[0] | has("hostRunning") | not) and
  (.sessions[0] | has("agentExtensions") | not) and
  (.sessions[0].model == "test-model") and
  (.sessions[0].project == "/tmp/demo-project") and
  (.sessions[0].status == "finished") and
  (.sessions[0].input == 210) and
  (.sessions[0].cached == 80) and
  (.sessions[0].output == 30) and
  (.sessions[0].unknown == 100) and
  (.sessions[0].total == 340) and
  (.sessions[0].durationMs == 3000) and
  (.sessions[0].quality == "reported")
' >/dev/null

"$BINARY" --validate-codex-rollout "$CODEX_FIXTURE" | jq -e '
  (.input == 310) and
  (.cached == 180) and
  (.output == 60) and
  (.reasoning == 15) and
  (.unknown == 0) and
  (.total == 370) and
  (.quality == "exact")
' >/dev/null

"$BINARY" --validate-jsonl "$HEARTBEAT_FIXTURE" | jq -e '
  (.warnings | length == 0) and
  (.sessions | length == 1) and
  (.sessions[0].name == "New") and
  (.sessions[0].model == "new") and
  (.sessions[0].project == "/new")
' >/dev/null

"$BINARY" --validate-claude-root "$CLAUDE_FIXTURE_ROOT" | jq -e '
  (.warnings | length == 0) and
  (.sessions | length == 1) and
  (.sessions[0].id == "claude:shared") and
  (.sessions[0].name == "Merged Claude Session") and
  (.sessions[0].conversationTitle == "Merged Claude Session") and
  (.sessions[0].titleSource == "claude.aiTitle") and
  (.sessions[0].input == 23) and
  (.sessions[0].cached == 5) and
  (.sessions[0].output == 7) and
  (.sessions[0].total == 30)
' >/dev/null

"$BINARY" --validate-source-path "$FIXTURE" | jq -e '
  (.valid == true) and (.directory == false)
' >/dev/null

ROOT_LINK="$VERIFY_ROOT/root-link"
ln -s / "$ROOT_LINK"
if "$BINARY" --validate-source-path "$ROOT_LINK" >"$VERIFY_ROOT/root-validation.json"; then
  echo "Root-directory symlink was accepted as a custom source" >&2
  exit 1
fi
jq -e '
  (.valid == false) and
  ((.code // "") == "root_target" or ((.error // "") | contains("磁盘根目录")))
' "$VERIFY_ROOT/root-validation.json" >/dev/null

for LANGUAGE_CODE in zh en; do
  RESULT_PATH="$VERIFY_ROOT/root-$LANGUAGE_CODE.json"
  if "$BINARY" --validate-source-path / -AgentIslandLanguageV1 "$LANGUAGE_CODE" >"$RESULT_PATH"; then
    echo "Disk root was accepted for language $LANGUAGE_CODE" >&2
    exit 1
  fi
  jq -e '.valid == false and .code == "root_target"' "$RESULT_PATH" >/dev/null
done
jq -e '(.error | contains("磁盘根目录"))' "$VERIFY_ROOT/root-zh.json" >/dev/null
jq -e '(.error | test("root"; "i")) and (.error | test("[\u3400-\u9fff]") | not)' \
  "$VERIFY_ROOT/root-en.json" >/dev/null

ARCHIVE_VERIFY_ROOT="$VERIFY_ROOT/archive"
mkdir -p "$ARCHIVE_VERIFY_ROOT"
ditto -x -k "$ARCHIVE_PATH" "$ARCHIVE_VERIFY_ROOT"
typeset -a ARCHIVED_APPS
ARCHIVED_APPS=("$ARCHIVE_VERIFY_ROOT"/*.app(N))
[[ ${#ARCHIVED_APPS[@]} -eq 1 && "${ARCHIVED_APPS[1]}" == "$ARCHIVE_VERIFY_ROOT/$PUBLIC_DISPLAY_NAME.app" ]] || {
  echo "Archive does not contain exactly the canonical public app name" >&2
  exit 1
}
xattr -cr "$ARCHIVED_APPS[1]"
codesign --verify --deep --strict --verbose=2 "$ARCHIVED_APPS[1]"

echo "MAC版灵动岛--Agent运行监测 tests passed"
