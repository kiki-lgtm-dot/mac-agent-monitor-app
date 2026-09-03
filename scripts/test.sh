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
# The Desktop directory may be managed by File Provider, which can move or
# replace a visible .app bundle while this long suite is running. The ZIP is the
# canonical distributable, so extract it once to a private temporary directory
# and use that immutable copy for every subsequent content/runtime assertion.
CANONICAL_APP_ROOT="$VERIFY_ROOT/canonical-app"
/bin/mkdir -p "$CANONICAL_APP_ROOT"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$CANONICAL_APP_ROOT"
APP_PATH="$CANONICAL_APP_ROOT/$PUBLIC_DISPLAY_NAME.app"
BINARY="$APP_PATH/Contents/MacOS/AgentIsland"
[[ -f "$APP_PATH/Contents/Info.plist" && -x "$BINARY" ]]
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
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
  "$PROJECT_DIR/scripts/apply-release-identity.sh" "$PROJECT_DIR/Tests/test-release-identity.sh" \
  "$PROJECT_DIR/ApplePlatforms/iOS/scripts/confirm-functional-qa-evidence.sh" \
  "$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-functional-qa-evidence.sh" \
  "$PROJECT_DIR/Tests/test-ios-functional-qa-evidence.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/release-macos-app-store.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh" \
  "$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh" \
  "$PROJECT_DIR/Tests/test-macos-app-store-release.sh" \
  "$PROJECT_DIR/Tests/test-macos-app-store-delivery.sh" \
  "$PROJECT_DIR/Tests/test-macos-functional-qa-evidence.sh"
/bin/bash -n "$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-project.sh"
[[ -x "$PROJECT_DIR/scripts/release-macos.sh" ]]
[[ -x "$PROJECT_DIR/scripts/release-readiness.sh" ]]
[[ -x "$PROJECT_DIR/scripts/apply-release-identity.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-release-identity.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/iOS/scripts/confirm-functional-qa-evidence.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/iOS/scripts/validate-functional-qa-evidence.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-ios-functional-qa-evidence.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-project.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/release-macos-app-store.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh" ]]
[[ -x "$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-macos-app-store-release.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-macos-app-store-delivery.sh" ]]
[[ -x "$PROJECT_DIR/Tests/test-macos-functional-qa-evidence.sh" ]]
READINESS_HELP="$("$PROJECT_DIR/scripts/release-readiness.sh" --help)"
[[ "$READINESS_HELP" == *'Usage: release-readiness.sh [--json]'* ]]
[[ "$READINESS_HELP" == *'never archives, signs, uploads, or changes Apple services'* ]]
if "$PROJECT_DIR/scripts/release-readiness.sh" --unknown \
    >"$VERIFY_ROOT/release-readiness-unknown.out" \
    2>"$VERIFY_ROOT/release-readiness-unknown.err"; then
  echo "release-readiness.sh accepted an unknown argument" >&2
  exit 1
fi
rg -q --fixed-strings 'Unknown argument: --unknown' \
  "$VERIFY_ROOT/release-readiness-unknown.err"
if "$PROJECT_DIR/scripts/release-readiness.sh" --json extra \
    >"$VERIFY_ROOT/release-readiness-extra.out" \
    2>"$VERIFY_ROOT/release-readiness-extra.err"; then
  echo "release-readiness.sh accepted multiple arguments" >&2
  exit 1
fi
rg -q --fixed-strings 'Unexpected arguments: --json extra' \
  "$VERIFY_ROOT/release-readiness-extra.err"
"$PROJECT_DIR/ApplePlatforms/macOS/scripts/validate-project.sh"
"$PROJECT_DIR/Tests/test-macos-app-store-release.sh"
"$PROJECT_DIR/Tests/test-macos-app-store-delivery.sh"
"$PROJECT_DIR/Tests/test-macos-functional-qa-evidence.sh"
/usr/bin/jq -e '
  .schemaVersion == 2 and
  .appStoreRecordMode == "universal-purchase" and
  .macOSAppBundleIdentifier == .iOSAppBundleIdentifier and
  .iOSWidgetBundleIdentifier == (.iOSAppBundleIdentifier + ".liveactivity") and
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
  'appIDPrefixGuessed: false' \
  'iOSWidgetBundleIdentifier must equal iOSAppBundleIdentifier + .liveactivity' \
  'separate-records requires macOSAppBundleIdentifier and iOSAppBundleIdentifier to differ' \
  'private Production AgentIslandSnapshot/latest/payloadJSON contract'; do
  rg -q --fixed-strings -- "$marker" "$PROJECT_DIR/scripts/apply-release-identity.sh"
done
"$PROJECT_DIR/Tests/test-release-identity.sh"
"$PROJECT_DIR/Tests/test-store-submission.sh"
"$PROJECT_DIR/Tests/test-ios-functional-qa-evidence.sh"
node "$PROJECT_DIR/Tests/test-ios-build-settings.mjs"
rg -q --fixed-strings 'MARKETING_VERSION = 0.6.1' \
  "$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
rg -q --fixed-strings 'CURRENT_PROJECT_VERSION = 8' \
  "$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
for IOS_CI_MARKER in \
  'runs-on: macos-15' \
  'Select Xcode 26 with the iOS 26 SDK' \
  'xcode_major >= 26 && sdk_major >= 26' \
  'simctl list devices available -j' \
  'AGENT_ISLAND_IOS_TEST_DESTINATION=' \
  'validate-project.sh --test' \
  'validate-project.sh --build'; do
  rg -q --fixed-strings -- "$IOS_CI_MARKER" "$PROJECT_DIR/.github/workflows/verify.yml"
done
[[ -f "$PROJECT_DIR/scripts/validate-pages-site.mjs" ]]
[[ -f "$PROJECT_DIR/.github/workflows/pages.yml" ]]
PUBLIC_SITE_RESULT="$VERIFY_ROOT/public-site-validation.json"
node "$PROJECT_DIR/scripts/validate-pages-site.mjs" >"$PUBLIC_SITE_RESULT"
/usr/bin/jq -e '
  .ok == true and
  .productName == "MAC版灵动岛--Agent运行监测" and
  .privacyURL == "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/" and
  .supportURL == "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/" and
  .languages == ["zh-CN", "en"]
' "$PUBLIC_SITE_RESULT" >/dev/null
for PAGES_MARKER in \
  'name: Publish support site' \
  'actions/configure-pages@v6' \
  'actions/upload-pages-artifact@v5' \
  'actions/deploy-pages@v5'; do
  rg -q --fixed-strings -- "$PAGES_MARKER" "$PROJECT_DIR/.github/workflows/pages.yml"
done
[[ -f "$PROJECT_DIR/scripts/validate-app-privacy.mjs" ]]
[[ -f "$PROJECT_DIR/docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md" ]]
/bin/zsh "$PROJECT_DIR/Tests/test-app-privacy-path-safety.sh"
/bin/zsh "$PROJECT_DIR/Tests/test-privacy-record-scope.sh"
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
  'iosProjectReleaseValidationPassed' 'iosBuildSettingsResolved' \
  'iosTargetBuildSettingsConfigured' 'iosProductionBuildSettingsConfigured' \
  'iosBuildSettingsMatchEnvironment' 'iosBuildSettingsMismatches' \
  'cloudKitProductionSchemaVerified' 'iosRealDeviceSyncVerified' \
  'iosLiveActivityVerified' 'iosReviewPathVerified' \
  'iosTestFlightUploadVerified' 'iosTestFlightProcessingVerified' \
  'iosTestFlightInstallVerified' 'iosTestFlightEvidenceConfigured' \
  'iosLocalIPAPreflightPassed' \
  'iosTestFlightExactBuildEvidenceReady' \
  'iosFunctionalQAEvidenceConfigured' 'iosFunctionalQAEvidenceReady' \
  'iosFunctionalQAEvidencePath' 'iosFunctionalQAEvidenceSHA256' \
  'iosFunctionalQADeviceModel' 'iosFunctionalQAOSVersion' 'iosFunctionalQATestedAt' \
  'iosFunctionalEvidenceBoundToCandidate' \
  'iosTestFlightIPASHA256' 'iosTestFlightAppStoreConnectBuildID' \
  'AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE' \
  'AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE' \
  'validate-functional-qa-evidence.sh' \
  'testflight-verification-*.json' 'deliveryRecordSHA256' \
  '--check "$IOS_EVIDENCE_DIRECTORY"' \
  '"$IOS_EVIDENCE_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID"' \
  '"$IOS_EVIDENCE_VERSION" == "$IOS_MARKETING_VERSION"' \
  '"$IOS_EVIDENCE_BUILD" == "$IOS_BUILD_NUMBER"' \
  'appleDistributionTeamIdentityConfigured' \
  'macAppStoreStaticProjectValidationPassed' \
  'macAppStoreXcodeProjectConfigured' 'macAppStoreTargetMembershipConfigured' \
  'macAppStoreRuntimeResourcesInTarget' 'macAppStoreBuildSettingsMatch' \
  'macPrivacyManifestInAppTarget' 'macAppStoreInfoPlistConfigured' \
  'macAppSandboxEntitlementConfigured' 'macUserSelectedReadOnlyEntitlementConfigured' \
  'macAppScopeBookmarkEntitlementConfigured' 'macNetworkClientEntitlementConfigured' \
  'macAppStoreCloudKitEntitlementConfigured' 'macAppStoreEntitlementsConfigured' \
  'macSecurityScopedBookmarkMarkersPresent' 'macAutomaticHomeScanMarkersPresent' \
  'macPrivacySourceReady' 'appPrivacyReleaseEvidenceReady' \
  'macPrivacyReleaseEvidenceReady' 'iosPrivacyReleaseEvidenceReady' \
  '.releaseEvidence.recordScope == $recordScope' \
  'storeSubmissionAssetsReady' 'storeSubmissionBlockers' \
  'storeSubmissionStructuralErrors' 'iosProjectReleaseValidationMessages' \
  'macAppStoreReleaseMetadataConfigured' 'macAppStoreExactCandidateEvidenceReady' \
  'releaseIdentityLockConfigured' 'releaseIdentityLockValid' \
  'releaseIdentityAppliedFilesMatch' 'releaseIdentityMatchesConfiguration' \
  'releaseIdentityReady' 'releaseIdentityLockPath' 'releaseIdentityLockSHA256' \
  'releaseIdentityInputSchemaVersion' 'releaseIdentityNormalizedSchemaVersion' \
  'releaseIdentityRecordMode' \
  'macMarketingVersion' 'macBuildNumber' \
  'macAppStoreLocalPreflightPassed' \
  'macAppStoreFunctionalQAEvidenceConfigured' 'macAppStoreFunctionalQAEvidenceReady' \
  'macAppStoreFunctionalQAEvidenceInputPath' 'macAppStoreFunctionalQAEvidencePath' \
  'macAppStoreFunctionalQAEvidenceSHA256' \
  'macAppStoreFunctionalQAMacModel' 'macAppStoreFunctionalQAOSVersion' \
  'macAppStoreFunctionalQATestedAt' \
  'macAppStoreArchiveZipSHA256' 'macAppStorePackageSHA256' \
  'macAppStoreFunctionalEvidenceArchiveSHA256' \
  'macAppStoreFunctionalEvidencePackageSHA256' \
  'macAppStoreFunctionalEvidenceBoundToCandidate' \
  'AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE' \
  'validate-functional-qa-evidence.sh' \
  'macAppStoreDeliveryEvidenceConfigured' 'macAppStoreDeliveryEvidenceReady' \
  'macAppStoreDeliveryEvidenceInputPath' 'macAppStoreDeliveryEvidencePath' \
  'macAppStoreDeliveryEvidenceSHA256' 'macAppStoreDeliveryBoundToCandidate' \
  'macAppStoreUploadAccepted' 'macAppStoreUploadSubmittedAt' \
  'macAppStoreProcessingEvidenceConfigured' 'macAppStoreProcessingEvidenceReady' \
  'macAppStoreProcessingEvidenceInputPath' 'macAppStoreProcessingEvidencePath' \
  'macAppStoreProcessingEvidenceSHA256' 'macAppStoreProcessingBoundToDelivery' \
  'macAppStoreProcessingState' 'macAppStoreProcessingVerified' \
  'macAppStoreProcessingVerifiedAt' 'macAppStoreWarningsReviewed' \
  'macAppStoreWarningsReviewedAt' 'macAppStoreConnectBuildID' \
  'macAppStoreAppReviewSubmissionRecorded' \
  'AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE' \
  'AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE' \
  '.version == $version and .build == $build' \
  'appStoreRecordModeConfigured' 'universalPurchaseBundleIDsMatch' \
  'appStoreRecordModeBundleIDsValid' \
  'macAppStoreSandboxFlowVerified' 'macAppStoreArchiveVerified' \
  'macAppStoreProfileCertificateVerified' 'macAppStorePrivacyReportVerified' \
  'macAppStoreReviewPathVerified' 'readyForMacAppStoreArchive' \
  'readyForMacAppStoreUpload' 'readyForMacAppStoreReviewSelection' \
  'readyForFunctionalMacAppStoreSubmissionDeprecated' \
  'readyForFunctionalMacAppStoreSubmission' \
  'macDeveloperIDToolchainConfigured' '$MAC_DEVELOPER_ID_TOOLCHAIN' \
  '$ENTITLEMENTS_READY' '$CLOUDKIT_CONTAINER_READY' '$PROVISIONING_PROFILE_READY' '$RELEASE_PRIVACY_READY' '$RELEASE_SUPPORT_READY' \
  '$APPLE_DISTRIBUTION_TEAM_IDENTITY_READY' \
  '$IOS_PROJECT_RELEASE_VALIDATION' '$IOS_BUILD_SETTINGS_RESOLVED' \
  '$IOS_TARGET_BUILD_SETTINGS_CONFIGURED' '$IOS_PRODUCTION_BUILD_SETTINGS_CONFIGURED' \
  '$IOS_BUILD_SETTINGS_MATCH_ENVIRONMENT' \
  '$MAC_APP_STORE_STATIC_PROJECT_VALIDATION' \
  '$MAC_APP_STORE_XCODE_PROJECT' '$MAC_APP_STORE_TARGET_MEMBERSHIP' \
  '$MAC_APP_STORE_RUNTIME_RESOURCES_IN_TARGET' '$MAC_APP_STORE_BUILD_SETTINGS_MATCH' \
  '$MAC_APP_STORE_INFO_PLIST_CONFIGURED' '$MAC_APP_STORE_ENTITLEMENTS_READY' \
  '$RELEASE_IDENTITY_LOCK_READY' '$MAC_APP_STORE_EXACT_CANDIDATE_EVIDENCE_READY' \
  '$MAC_APP_STORE_LOCAL_PREFLIGHT_PASSED' '$MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE_READY' \
  '$MAC_APP_STORE_FUNCTIONAL_EVIDENCE_BOUND_TO_CANDIDATE' \
  '$MAC_APP_STORE_DELIVERY_EVIDENCE_READY' '$MAC_APP_STORE_PROCESSING_EVIDENCE_READY' \
  '$MAC_APP_STORE_PROCESSING_BOUND_TO_DELIVERY' \
  '$MAC_APP_STORE_RECORD_MODE_BUNDLE_IDS_VALID' \
  '$MAC_PRIVACY_SOURCE_READY' '$MAC_PRIVACY_RELEASE_EVIDENCE_READY' '$STORE_SUBMISSION_ASSETS_READY' \
  '$cloudKitProductionSchemaVerified and $iosRealDeviceSyncVerified' \
  '$iosLiveActivityVerified and $iosReviewPathVerified' \
  '$iosTestFlightExactBuildEvidenceReady and $iosFunctionalQAEvidenceReady' \
  '$iosFunctionalEvidenceBoundToCandidate and' \
  '$iosTestFlightUploadVerified and $iosTestFlightProcessingVerified' \
  '$iosTestFlightInstallVerified and $iosPrivacyReleaseEvidenceReady'; do
  if ! rg -q --fixed-strings -- "$READINESS_GATE" \
      "$PROJECT_DIR/scripts/release-readiness.sh"; then
    echo "release readiness is missing contract marker $READINESS_GATE" >&2
    exit 1
  fi
done
for UNSAFE_RELEASE_BOOLEAN in \
  AGENT_ISLAND_IOS_TESTFLIGHT_UPLOAD_VERIFIED \
  AGENT_ISLAND_IOS_TESTFLIGHT_PROCESSING_VERIFIED \
  AGENT_ISLAND_IOS_TESTFLIGHT_INSTALL_VERIFIED \
  AGENT_ISLAND_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED \
  AGENT_ISLAND_IOS_REAL_DEVICE_SYNC_VERIFIED \
  AGENT_ISLAND_IOS_LIVE_ACTIVITY_VERIFIED \
  AGENT_ISLAND_IOS_REVIEW_PATH_VERIFIED \
  AGENT_ISLAND_IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256 \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256 \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256 \
  AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED \
  AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED \
  AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED \
  AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED \
  AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED; do
  if rg -q --fixed-strings -- "$UNSAFE_RELEASE_BOOLEAN" \
      "$PROJECT_DIR/scripts/release-readiness.sh"; then
    echo "release readiness still accepts unbound release switch $UNSAFE_RELEASE_BOOLEAN" >&2
    exit 1
  fi
done

/usr/bin/env \
  -u AGENT_ISLAND_BUNDLE_ID \
  -u AGENT_ISLAND_IOS_BUNDLE_ID \
  -u AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID \
  -u AGENT_ISLAND_ENTITLEMENTS \
  -u AGENT_ISLAND_PROVISIONING_PROFILE \
  -u AGENT_ISLAND_DISPLAY_NAME \
  -u AGENT_ISLAND_VERSION \
  -u AGENT_ISLAND_BUILD_NUMBER \
  -u AGENT_ISLAND_PRIVACY_POLICY_URL \
  -u AGENT_ISLAND_SUPPORT_URL \
  -u AGENT_ISLAND_DEVELOPMENT_TEAM \
  -u AGENT_ISLAND_ICLOUD_CONTAINER_ID \
  -u AGENT_ISLAND_CLOUDKIT_PRODUCTION_SCHEMA_VERIFIED \
  -u AGENT_ISLAND_IOS_REAL_DEVICE_SYNC_VERIFIED \
  -u AGENT_ISLAND_IOS_LIVE_ACTIVITY_VERIFIED \
  -u AGENT_ISLAND_IOS_REVIEW_PATH_VERIFIED \
  -u AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE \
  -u AGENT_ISLAND_IOS_FUNCTIONAL_EVIDENCE_IPA_SHA256 \
  -u AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE \
  -u AGENT_ISLAND_APP_PRIVACY_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_PROJECT \
  -u AGENT_ISLAND_MAC_APP_STORE_SCHEME \
  -u AGENT_ISLAND_APP_STORE_RECORD_MODE \
  -u AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256 \
  -u AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256 \
  -u AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED \
  -u AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED \
  "$PROJECT_DIR/scripts/release-readiness.sh" | jq -e '
  ((.hostMacOSVersion == null) or (.hostMacOSVersion | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$"))) and
  (.minimumHostMacOSForXcode26 == "15.6") and
  (.minimumRequiredXcodeMajor == 26) and
  (.minimumRequiredIOSSDKMajor == 26) and
  (.xcode26HostCompatible | type == "boolean") and
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
  (.releaseIdentityLockConfigured | type == "boolean") and
  (.releaseIdentityLockValid | type == "boolean") and
  (.releaseIdentityAppliedFilesMatch | type == "boolean") and
  (.releaseIdentityMatchesConfiguration | type == "boolean") and
  (.releaseIdentityReady | type == "boolean") and
  (.releaseIdentityLockPath | type == "string" and startswith("/") and endswith("/.release/identity.lock.json")) and
  ((.releaseIdentityLockSHA256 == null) or (.releaseIdentityLockSHA256 | type == "string" and test("^[0-9a-f]{64}$"))) and
  ((.releaseIdentityInputSchemaVersion == null) or (.releaseIdentityInputSchemaVersion == 1 or .releaseIdentityInputSchemaVersion == 2)) and
  ((.releaseIdentityNormalizedSchemaVersion == null) or .releaseIdentityNormalizedSchemaVersion == 2) and
  ((.releaseIdentityRecordMode == null) or
    (.releaseIdentityRecordMode == "universal-purchase" or .releaseIdentityRecordMode == "separate-records")) and
  ((.releaseIdentityReady | not) or (
    .releaseIdentityLockConfigured and .releaseIdentityLockValid and
    .releaseIdentityAppliedFilesMatch and .releaseIdentityMatchesConfiguration and
    .releaseIdentityNormalizedSchemaVersion == 2
  )) and
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
  (.iosTestFlightUploadVerified | type == "boolean") and
  (.iosTestFlightProcessingVerified | type == "boolean") and
  (.iosTestFlightInstallVerified | type == "boolean") and
  (.iosTestFlightEvidenceConfigured | type == "boolean") and
  (.iosLocalIPAPreflightPassed | type == "boolean") and
  (.iosTestFlightExactBuildEvidenceReady | type == "boolean") and
  (.iosFunctionalQAEvidenceConfigured | type == "boolean") and
  (.iosFunctionalQAEvidenceReady | type == "boolean") and
  ((.iosFunctionalQAEvidenceInputPath == null) or (.iosFunctionalQAEvidenceInputPath | type == "string")) and
  ((.iosFunctionalQAEvidencePath == null) or (.iosFunctionalQAEvidencePath | type == "string")) and
  ((.iosFunctionalQAEvidenceSHA256 == null) or (.iosFunctionalQAEvidenceSHA256 | test("^[0-9a-f]{64}$"))) and
  ((.iosFunctionalQADeviceModel == null) or (.iosFunctionalQADeviceModel | type == "string" and length > 0)) and
  ((.iosFunctionalQAOSVersion == null) or (.iosFunctionalQAOSVersion | type == "string" and length > 0)) and
  ((.iosFunctionalQATestedAt == null) or (.iosFunctionalQATestedAt | type == "string" and test("Z$"))) and
  (.iosFunctionalEvidenceBoundToCandidate | type == "boolean") and
  ((.iosTestFlightVerificationEvidencePath == null) or (.iosTestFlightVerificationEvidencePath | type == "string")) and
  ((.iosTestFlightIPASHA256 == null) or (.iosTestFlightIPASHA256 | test("^[0-9a-f]{64}$"))) and
  ((.iosTestFlightAppStoreConnectBuildID == null) or (.iosTestFlightAppStoreConnectBuildID | type == "string" and length > 0)) and
  (.iosProjectConfigured | type == "boolean") and
  (.iosProjectPath | type == "string") and
  (.iosScheme == "AgentIslandMobile") and
  (.iosProjectReleaseValidationPassed | type == "boolean") and
  (.iosProjectReleaseValidationMessages | type == "array") and
  (.iosBuildSettingsResolved | type == "boolean") and
  (.iosTargetBuildSettingsConfigured | type == "boolean") and
  (.iosProductionBuildSettingsConfigured | type == "boolean") and
  (.iosBuildSettingsMatchEnvironment | type == "boolean") and
  (.iosBuildSettingsMismatches | type == "array") and
  ((.iosDisplayName == null) or (.iosDisplayName | type == "string")) and
  ((.iosMarketingVersion == null) or (.iosMarketingVersion | type == "string")) and
  ((.iosBuildNumber == null) or (.iosBuildNumber | type == "string")) and
  ((.iosTargetBuildSettingsConfigured | not) or .iosBuildSettingsResolved) and
  ((.iosProductionBuildSettingsConfigured | not) or .iosTargetBuildSettingsConfigured) and
  ((.readyForIOSArchive | not) or (
    .fullXcode and
    .xcode26HostCompatible and
    .currentUploadToolchain and
    .appleDistributionTeamIdentityConfigured and
    .iosProjectConfigured and
    .iosProjectReleaseValidationPassed and
    .iosBuildSettingsResolved and
    .iosTargetBuildSettingsConfigured and
    .iosProductionBuildSettingsConfigured and
    .iosBuildSettingsMatchEnvironment and
    .iosPrivacyManifestPresent and
    .iosAppIconPresent and
    .iosAppBundleIDConfigured and
    .iosWidgetBundleIDConfigured and
    .iosDevelopmentTeamConfigured and
    .iosCloudKitContainerConfigured and
    .iosPrivacyPolicyURLConfigured and
    .iosSupportURLConfigured
  )) and
  (.iosPrivacyManifestPresent | type == "boolean") and
  (.iosAppIconPresent | type == "boolean") and
  (.iosSyncTransportImplemented | type == "boolean") and
  (.macAppStoreProjectPath | type == "string") and
  (.macAppStoreScheme | type == "string") and
  ((.macAppStoreTargetName == null) or (.macAppStoreTargetName | type == "string")) and
  ((.macAppStoreEntitlementsPath == null) or (.macAppStoreEntitlementsPath | type == "string")) and
  ((.macAppStoreInfoPlistPath == null) or (.macAppStoreInfoPlistPath | type == "string")) and
  (.macAppStoreStaticProjectValidationPassed == true) and
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
  (.appPrivacyReleaseEvidenceReady | type == "boolean") and
  (.macPrivacyReleaseEvidenceReady | type == "boolean") and
  (.iosPrivacyReleaseEvidenceReady | type == "boolean") and
  (.storeSubmissionAssetsReady | type == "boolean") and
  (.storeSubmissionBlockerCount | type == "number") and
  (.storeSubmissionBlockers | type == "array") and
  (.storeSubmissionStructuralErrors | type == "array") and
  (.storeSubmissionBlockerCount == (.storeSubmissionBlockers | length)) and
  (.macAppStoreReleaseMetadataConfigured | type == "boolean") and
  (.macAppStoreExactCandidateEvidenceReady | type == "boolean") and
  (.macAppStoreLocalPreflightPassed | type == "boolean") and
  ((.macMarketingVersion == null) or (.macMarketingVersion | type == "string")) and
  ((.macBuildNumber == null) or (.macBuildNumber | type == "string")) and
  ((.macAppStoreReleaseMetadataPath == null) or (.macAppStoreReleaseMetadataPath | type == "string")) and
  ((.macAppStoreArchiveZipSHA256 == null) or (.macAppStoreArchiveZipSHA256 | test("^[0-9a-f]{64}$"))) and
  ((.macAppStorePackageSHA256 == null) or (.macAppStorePackageSHA256 | test("^[0-9a-f]{64}$"))) and
  (.macAppStoreFunctionalQAEvidenceConfigured | type == "boolean") and
  (.macAppStoreFunctionalQAEvidenceReady | type == "boolean") and
  ((.macAppStoreFunctionalQAEvidenceInputPath == null) or (.macAppStoreFunctionalQAEvidenceInputPath | type == "string")) and
  ((.macAppStoreFunctionalQAEvidencePath == null) or (.macAppStoreFunctionalQAEvidencePath | type == "string")) and
  ((.macAppStoreFunctionalQAEvidenceSHA256 == null) or (.macAppStoreFunctionalQAEvidenceSHA256 | test("^[0-9a-f]{64}$"))) and
  ((.macAppStoreFunctionalQAMacModel == null) or (.macAppStoreFunctionalQAMacModel | type == "string" and length > 0)) and
  ((.macAppStoreFunctionalQAOSVersion == null) or (.macAppStoreFunctionalQAOSVersion | type == "string" and length > 0)) and
  ((.macAppStoreFunctionalQATestedAt == null) or (.macAppStoreFunctionalQATestedAt | type == "string" and test("Z$"))) and
  ((.macAppStoreFunctionalEvidenceArchiveSHA256 == null) or (.macAppStoreFunctionalEvidenceArchiveSHA256 | test("^[0-9a-f]{64}$"))) and
  ((.macAppStoreFunctionalEvidencePackageSHA256 == null) or (.macAppStoreFunctionalEvidencePackageSHA256 | test("^[0-9a-f]{64}$"))) and
  (.macAppStoreFunctionalEvidenceBoundToCandidate | type == "boolean") and
  (.macAppStoreDeliveryEvidenceConfigured | type == "boolean") and
  (.macAppStoreDeliveryEvidenceReady | type == "boolean") and
  ((.macAppStoreDeliveryEvidenceInputPath == null) or (.macAppStoreDeliveryEvidenceInputPath | type == "string")) and
  ((.macAppStoreDeliveryEvidencePath == null) or (.macAppStoreDeliveryEvidencePath | type == "string")) and
  ((.macAppStoreDeliveryEvidenceSHA256 == null) or (.macAppStoreDeliveryEvidenceSHA256 | test("^[0-9a-f]{64}$"))) and
  (.macAppStoreDeliveryBoundToCandidate | type == "boolean") and
  (.macAppStoreUploadAccepted | type == "boolean") and
  ((.macAppStoreUploadSubmittedAt == null) or (.macAppStoreUploadSubmittedAt | type == "string" and test("Z$"))) and
  (.macAppStoreProcessingEvidenceConfigured | type == "boolean") and
  (.macAppStoreProcessingEvidenceReady | type == "boolean") and
  ((.macAppStoreProcessingEvidenceInputPath == null) or (.macAppStoreProcessingEvidenceInputPath | type == "string")) and
  ((.macAppStoreProcessingEvidencePath == null) or (.macAppStoreProcessingEvidencePath | type == "string")) and
  ((.macAppStoreProcessingEvidenceSHA256 == null) or (.macAppStoreProcessingEvidenceSHA256 | test("^[0-9a-f]{64}$"))) and
  (.macAppStoreProcessingBoundToDelivery | type == "boolean") and
  ((.macAppStoreProcessingState == null) or .macAppStoreProcessingState == "Complete") and
  (.macAppStoreProcessingVerified | type == "boolean") and
  ((.macAppStoreProcessingVerifiedAt == null) or (.macAppStoreProcessingVerifiedAt | type == "string" and test("Z$"))) and
  (.macAppStoreWarningsReviewed | type == "boolean") and
  ((.macAppStoreWarningsReviewedAt == null) or (.macAppStoreWarningsReviewedAt | type == "string" and test("Z$"))) and
  ((.macAppStoreConnectBuildID == null) or (.macAppStoreConnectBuildID | type == "string" and length > 0)) and
  (.macAppStoreAppReviewSubmissionRecorded | type == "boolean") and
  ((.macAppStoreFunctionalQAEvidenceReady | not) or (
    .macAppStoreExactCandidateEvidenceReady and .macAppStoreLocalPreflightPassed and
    .macAppStoreFunctionalEvidenceBoundToCandidate
  )) and
  ((.macAppStoreDeliveryEvidenceReady | not) or (
    .macAppStoreExactCandidateEvidenceReady and .macAppStoreLocalPreflightPassed and
    .macAppStoreDeliveryBoundToCandidate and .macAppStoreUploadAccepted and
    (.macAppStoreAppReviewSubmissionRecorded | not)
  )) and
  ((.macAppStoreProcessingEvidenceReady | not) or (
    .macAppStoreDeliveryEvidenceReady and .macAppStoreProcessingBoundToDelivery and
    .macAppStoreUploadAccepted and .macAppStoreProcessingState == "Complete" and
    .macAppStoreProcessingVerified and .macAppStoreWarningsReviewed and
    (.macAppStoreAppReviewSubmissionRecorded | not)
  )) and
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
  (.readyForMacAppStoreUpload | type == "boolean") and
  (.readyForMacAppStoreReviewSelection | type == "boolean") and
  (.readyForFunctionalMacAppStoreSubmissionDeprecated == true) and
  (.readyForFunctionalMacAppStoreSubmission | type == "boolean") and
  (.readyForIOSArchive | type == "boolean") and
  (.readyForFunctionalIOSTestFlight | type == "boolean") and
  ((.readyForMacAppStoreArchive | not) or .xcode26HostCompatible) and
  ((.readyForMacAppStoreUpload | not) or (
    .releaseIdentityReady and
    .macAppStoreExactCandidateEvidenceReady and
    .macAppStoreLocalPreflightPassed and
    .macAppStoreFunctionalQAEvidenceReady and
    .macAppStoreFunctionalEvidenceBoundToCandidate and
    .macPrivacyReleaseEvidenceReady and .storeSubmissionAssetsReady
  )) and
  ((.readyForMacAppStoreReviewSelection | not) or (
    .readyForMacAppStoreUpload and .macAppStoreDeliveryEvidenceReady and
    .macAppStoreDeliveryBoundToCandidate and .macAppStoreUploadAccepted and
    .macAppStoreProcessingEvidenceReady and .macAppStoreProcessingBoundToDelivery and
    .macAppStoreProcessingVerified and .macAppStoreProcessingState == "Complete" and
    .macAppStoreWarningsReviewed and (.macAppStoreAppReviewSubmissionRecorded | not)
  )) and
  (.readyForFunctionalMacAppStoreSubmission == false) and
  ((.readyForFunctionalIOSTestFlight | not) or (
    .readyForIOSArchive and .iosTestFlightExactBuildEvidenceReady and
    .iosFunctionalQAEvidenceReady and .iosFunctionalEvidenceBoundToCandidate and
    .iosTestFlightUploadVerified and
    .iosTestFlightProcessingVerified and .iosTestFlightInstallVerified and
    .iosPrivacyReleaseEvidenceReady
  )) and
  (.iosDevelopmentTeamConfigured == false) and
  (.developerIDIdentityConfigured == false) and
  (.productionDisplayNameConfigured == false) and
  (.provisioningProfileSigningCertificateConfigured == false) and
  (.cloudKitContainerConfigured == false) and
  (.iosCloudKitContainerConfigured == false) and
  (.iosPrivacyPolicyURLConfigured == true) and
  (.iosSupportURLConfigured == true) and
  (.cloudKitProductionSchemaVerified == false) and
  (.iosRealDeviceSyncVerified == false) and
  (.iosLiveActivityVerified == false) and
  (.iosReviewPathVerified == false) and
  (.iosTestFlightUploadVerified == false) and
  (.iosTestFlightProcessingVerified == false) and
  (.iosTestFlightInstallVerified == false) and
  (.iosTestFlightEvidenceConfigured == false) and
  (.iosLocalIPAPreflightPassed == false) and
  (.iosTestFlightExactBuildEvidenceReady == false) and
  (.iosFunctionalQAEvidenceConfigured == false) and
  (.iosFunctionalQAEvidenceReady == false) and
  (.iosFunctionalQAEvidenceInputPath == null) and
  (.iosFunctionalQAEvidencePath == null) and
  (.iosFunctionalQAEvidenceSHA256 == null) and
  (.iosFunctionalQADeviceModel == null) and
  (.iosFunctionalQAOSVersion == null) and
  (.iosFunctionalQATestedAt == null) and
  (.iosFunctionalEvidenceBoundToCandidate == false) and
  (.appleDistributionTeamIdentityConfigured == false) and
  (.releaseIdentityLockConfigured == false) and
  (.releaseIdentityLockValid == false) and
  (.releaseIdentityAppliedFilesMatch == false) and
  (.releaseIdentityMatchesConfiguration == false) and
  (.releaseIdentityReady == false) and
  (.releaseIdentityLockSHA256 == null) and
  (.releaseIdentityInputSchemaVersion == null) and
  (.releaseIdentityNormalizedSchemaVersion == null) and
  (.releaseIdentityRecordMode == null) and
  (.appStoreRecordModeConfigured == false) and
  (.appStoreRecordMode == null) and
  (.appStoreRecordModeBundleIDsValid == false) and
  (.macAppStoreSandboxFlowVerified == false) and
  (.macAppStoreArchiveVerified == false) and
  (.macAppStoreProfileCertificateVerified == false) and
  (.macAppStorePrivacyReportVerified == false) and
  (.macAppStoreReviewPathVerified == false) and
  (.macAppStoreReleaseMetadataConfigured == false) and
  (.macAppStoreExactCandidateEvidenceReady == false) and
  (.macAppStoreLocalPreflightPassed == false) and
  (.macAppStoreFunctionalQAEvidenceConfigured == false) and
  (.macAppStoreFunctionalQAEvidenceReady == false) and
  (.macAppStoreFunctionalQAEvidenceInputPath == null) and
  (.macAppStoreFunctionalQAEvidencePath == null) and
  (.macAppStoreFunctionalQAEvidenceSHA256 == null) and
  (.macAppStoreFunctionalQAMacModel == null) and
  (.macAppStoreFunctionalQAOSVersion == null) and
  (.macAppStoreFunctionalQATestedAt == null) and
  (.macAppStoreFunctionalEvidenceArchiveSHA256 == null) and
  (.macAppStoreFunctionalEvidencePackageSHA256 == null) and
  (.macAppStoreFunctionalEvidenceBoundToCandidate == false) and
  (.macAppStoreDeliveryEvidenceConfigured == false) and
  (.macAppStoreDeliveryEvidenceReady == false) and
  (.macAppStoreDeliveryEvidenceInputPath == null) and
  (.macAppStoreDeliveryEvidencePath == null) and
  (.macAppStoreDeliveryEvidenceSHA256 == null) and
  (.macAppStoreDeliveryBoundToCandidate == false) and
  (.macAppStoreUploadAccepted == false) and
  (.macAppStoreUploadSubmittedAt == null) and
  (.macAppStoreProcessingEvidenceConfigured == false) and
  (.macAppStoreProcessingEvidenceReady == false) and
  (.macAppStoreProcessingEvidenceInputPath == null) and
  (.macAppStoreProcessingEvidencePath == null) and
  (.macAppStoreProcessingEvidenceSHA256 == null) and
  (.macAppStoreProcessingBoundToDelivery == false) and
  (.macAppStoreProcessingState == null) and
  (.macAppStoreProcessingVerified == false) and
  (.macAppStoreProcessingVerifiedAt == null) and
  (.macAppStoreWarningsReviewed == false) and
  (.macAppStoreWarningsReviewedAt == null) and
  (.macAppStoreConnectBuildID == null) and
  (.macAppStoreAppReviewSubmissionRecorded == false) and
  (.readyForMacAppStoreArchive == false) and
  (.readyForMacAppStoreUpload == false) and
  (.readyForMacAppStoreReviewSelection == false) and
  (.readyForFunctionalMacAppStoreSubmission == false) and
  (.readyForFunctionalIOSTestFlight == false)
' >/dev/null

RECORD_FIXTURE_ROOT="$VERIFY_ROOT/release-readiness-record-fixture"
/bin/mkdir -p "$RECORD_FIXTURE_ROOT/scripts" "$RECORD_FIXTURE_ROOT/ApplePlatforms" \
  "$RECORD_FIXTURE_ROOT/.release"
/bin/cp "$PROJECT_DIR/scripts/release-readiness.sh" "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh"
/bin/cp -R "$PROJECT_DIR/ApplePlatforms/iOS" "$RECORD_FIXTURE_ROOT/ApplePlatforms/iOS"
/bin/cp -R "$PROJECT_DIR/ApplePlatforms/macOS" "$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS"
/bin/cp -R "$PROJECT_DIR/Resources" "$RECORD_FIXTURE_ROOT/Resources"
for RECORD_FIXTURE_ITEM in Native docs Web Config; do
  /bin/ln -s "$PROJECT_DIR/$RECORD_FIXTURE_ITEM" "$RECORD_FIXTURE_ROOT/$RECORD_FIXTURE_ITEM"
done
/bin/mkdir -p "$RECORD_FIXTURE_ROOT/dist"
# Keep the privacy validator physically inside the fixture so its repository
# root (and immutable candidate paths) are the fixture, not this checkout.
/bin/cp "$PROJECT_DIR/scripts/validate-app-privacy.mjs" \
  "$RECORD_FIXTURE_ROOT/scripts/validate-app-privacy.mjs"
/bin/ln -s "$PROJECT_DIR/scripts/validate-store-submission.mjs" \
  "$RECORD_FIXTURE_ROOT/scripts/validate-store-submission.mjs"
RECORD_FIXTURE_XCCONFIG="$RECORD_FIXTURE_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
RECORD_FIXTURE_MAC_XCCONFIG="$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"
RECORD_FIXTURE_INFO_PLIST="$RECORD_FIXTURE_ROOT/Resources/Info.plist"
/usr/bin/sed -i '' \
  -e 's/com\.example\.agentisland/com.agentisland.mobile/g' \
  -e 's/^AGENT_ISLAND_DEVELOPMENT_TEAM =.*$/AGENT_ISLAND_DEVELOPMENT_TEAM = ABCDE12345/' \
  "$RECORD_FIXTURE_XCCONFIG"
/usr/bin/sed -i '' \
  -e 's/com\.example\.agentisland/com.agentisland.mobile/g' \
  "$RECORD_FIXTURE_MAC_XCCONFIG"
/usr/bin/plutil -replace CFBundleIdentifier -string 'com.agentisland.mobile' \
  "$RECORD_FIXTURE_INFO_PLIST"

# release-readiness must require the schema-v2 identity payload and exact hashes
# of all three identity-bearing project files. The fixture lock is intentionally
# local to VERIFY_ROOT so the suite never mutates a developer's real lock.
RECORD_FIXTURE_INFO_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$RECORD_FIXTURE_INFO_PLIST" | /usr/bin/awk '{print $1}')"
RECORD_FIXTURE_IOS_CONFIG_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$RECORD_FIXTURE_XCCONFIG" | /usr/bin/awk '{print $1}')"
RECORD_FIXTURE_MAC_CONFIG_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$RECORD_FIXTURE_MAC_XCCONFIG" | /usr/bin/awk '{print $1}')"
RECORD_FIXTURE_IDENTITY_LOCK="$RECORD_FIXTURE_ROOT/.release/identity.lock.json"
/usr/bin/jq -n -S \
  --arg infoSHA "$RECORD_FIXTURE_INFO_SHA" \
  --arg iosSHA "$RECORD_FIXTURE_IOS_CONFIG_SHA" \
  --arg macSHA "$RECORD_FIXTURE_MAC_CONFIG_SHA" '{
    schemaVersion: 1,
    firstAppliedAt: "2026-09-04T00:00:00Z",
    identity: {
      schemaVersion: 2,
      appStoreRecordMode: "universal-purchase",
      macOSAppBundleIdentifier: "com.agentisland.mobile",
      iOSAppBundleIdentifier: "com.agentisland.mobile",
      iOSWidgetBundleIdentifier: "com.agentisland.mobile.liveactivity",
      teamIdentifier: "ABCDE12345",
      iCloudContainerIdentifier: "iCloud.com.agentisland.mobile",
      cloudKit: {
        databaseScope: "private",
        environment: "Production",
        recordType: "AgentIslandSnapshot",
        recordName: "latest",
        payloadField: "payloadJSON"
      }
    },
    provisioningProfile: null,
    generatedEntitlements: null,
    appliedFiles: [
      {path: "Resources/Info.plist", sha256: $infoSHA},
      {path: "ApplePlatforms/iOS/Config/Project.xcconfig", sha256: $iosSHA},
      {path: "ApplePlatforms/macOS/Config/Project.xcconfig", sha256: $macSHA}
    ]
  }' >"$RECORD_FIXTURE_IDENTITY_LOCK"
/bin/chmod 0600 "$RECORD_FIXTURE_IDENTITY_LOCK"

run_release_state_readiness() {
  /usr/bin/env \
    DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
    AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
    AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.mobile' \
    AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID='com.agentisland.mobile.liveactivity' \
    AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
    AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
    AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
    AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
    AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
    AGENT_ISLAND_VERSION='0.6.1' \
    AGENT_ISLAND_BUILD_NUMBER='8' \
    AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
    "$@" \
    "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh"
}

run_release_state_readiness | /usr/bin/jq -e \
  --arg lockPath "$RECORD_FIXTURE_IDENTITY_LOCK" '
    .releaseIdentityLockConfigured == true and
    .releaseIdentityLockValid == true and
    .releaseIdentityAppliedFilesMatch == true and
    .releaseIdentityMatchesConfiguration == true and
    .releaseIdentityReady == true and
    .releaseIdentityLockPath == $lockPath and
    (.releaseIdentityLockSHA256 | test("^[0-9a-f]{64}$")) and
    .releaseIdentityInputSchemaVersion == 2 and
    .releaseIdentityNormalizedSchemaVersion == 2 and
    .releaseIdentityRecordMode == "universal-purchase"
  ' >/dev/null

# A valid lock is not ready when its record model differs from the requested
# App Store topology, even though the lock and all applied-file hashes remain
# internally valid.
run_release_state_readiness \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='separate-records' | /usr/bin/jq -e '
    .releaseIdentityLockConfigured == true and
    .releaseIdentityLockValid == true and
    .releaseIdentityAppliedFilesMatch == true and
    .releaseIdentityMatchesConfiguration == false and
    .releaseIdentityReady == false and
    .readyForMacAppStoreArchive == false and
    .readyForMacAppStoreUpload == false and
    .readyForMacAppStoreReviewSelection == false
  ' >/dev/null

# Applied project files are part of the lock, not advisory metadata. Restore
# the physical fixture immediately after proving a one-byte drift closes every
# downstream release gate.
/bin/cp "$RECORD_FIXTURE_MAC_XCCONFIG" \
  "$VERIFY_ROOT/record-fixture-mac-xcconfig.saved"
print -r -- '// identity drift fixture' >>"$RECORD_FIXTURE_MAC_XCCONFIG"
run_release_state_readiness | /usr/bin/jq -e '
    .releaseIdentityLockValid == true and
    .releaseIdentityAppliedFilesMatch == false and
    .releaseIdentityMatchesConfiguration == true and
    .releaseIdentityReady == false and
    .readyForMacAppStoreArchive == false and
    .readyForMacAppStoreUpload == false and
    .readyForMacAppStoreReviewSelection == false
  ' >/dev/null
/bin/cp "$VERIFY_ROOT/record-fixture-mac-xcconfig.saved" \
  "$RECORD_FIXTURE_MAC_XCCONFIG"

/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID='com.agentisland.mobile.liveactivity' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_VERSION='0.6.1' \
  AGENT_ISLAND_BUILD_NUMBER='8' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == true and
    .appStoreRecordModeBundleIDsValid == true
  ' >/dev/null
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID='com.agentisland.mobile.liveactivity' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_VERSION='0.6.1' \
  AGENT_ISLAND_BUILD_NUMBER='8' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='separate-records' \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == true and
    .appStoreRecordModeBundleIDsValid == false
  ' >/dev/null
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mac' \
  AGENT_ISLAND_IOS_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID='com.agentisland.mobile.liveactivity' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_VERSION='0.6.1' \
  AGENT_ISLAND_BUILD_NUMBER='8' \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='separate-records' \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .appStoreRecordModeConfigured == true and
    .universalPurchaseBundleIDsMatch == false and
    .appStoreRecordModeBundleIDsValid == true
  ' >/dev/null

MAC_EVIDENCE_RELEASE_DIR="$RECORD_FIXTURE_ROOT/dist/macos-app-store/0.6.1-8-evidence"
MAC_EVIDENCE_ARCHIVE="$MAC_EVIDENCE_RELEASE_DIR/AgentIslandMac.xcarchive"
/bin/mkdir -p "$MAC_EVIDENCE_ARCHIVE" "$MAC_EVIDENCE_RELEASE_DIR/export"
MAC_EVIDENCE_ARCHIVE_ZIP="$MAC_EVIDENCE_RELEASE_DIR/AgentIslandMac.xcarchive.zip"
MAC_EVIDENCE_PACKAGE="$MAC_EVIDENCE_RELEASE_DIR/export/AgentIslandMac.pkg"
MAC_EVIDENCE_METADATA="$MAC_EVIDENCE_RELEASE_DIR/release-metadata.json"
printf 'synthetic Mac archive fixture\n' >"$MAC_EVIDENCE_ARCHIVE_ZIP"
printf 'synthetic Mac package fixture\n' >"$MAC_EVIDENCE_PACKAGE"
MAC_EVIDENCE_ARCHIVE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$MAC_EVIDENCE_ARCHIVE_ZIP" | /usr/bin/awk '{print $1}')"
MAC_EVIDENCE_PACKAGE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$MAC_EVIDENCE_PACKAGE" | /usr/bin/awk '{print $1}')"
MAC_EVIDENCE_CREATED_AT="$(/bin/date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n \
  --arg archivePath "$MAC_EVIDENCE_ARCHIVE" \
  --arg archive "$MAC_EVIDENCE_ARCHIVE_ZIP" --arg archiveSHA "$MAC_EVIDENCE_ARCHIVE_SHA" \
  --arg package "$MAC_EVIDENCE_PACKAGE" --arg packageSHA "$MAC_EVIDENCE_PACKAGE_SHA" \
  --arg displayName "$PUBLIC_DISPLAY_NAME" --arg createdAt "$MAC_EVIDENCE_CREATED_AT" '{
    schemaVersion: 1,
    product: $displayName,
    platform: "macOS",
    distribution: "mac-app-store",
    appBundleID: "com.agentisland.mobile",
    teamID: "ABCDE12345",
    displayName: $displayName,
    applicationCategory: "public.app-category.developer-tools",
    version: "0.6.1",
    build: "8",
    cloudContainerID: "iCloud.com.agentisland.mobile",
    cloudKitEnvironment: "Production",
    privacyPolicyURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/",
    supportURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/",
    archivePath: $archivePath,
    archiveZip: $archive,
    archiveZipSHA256: $archiveSHA,
    resultBundle: null,
    exportedPackage: $package,
    packageSHA256: $packageSHA,
    exportMethod: "app-store-connect",
    exportDestination: "export",
    signingCertificateSHA1: ("A" * 40),
    provisioningProfile: {certificateMatches: true},
    installerSigningIdentity: "Mac Installer Distribution: Fixture (ABCDE12345)",
    uploaded: false,
    createdAt: $createdAt
  }' >"$MAC_EVIDENCE_METADATA"

# The exact-package preflight has its own focused tests. Here a strict stub
# isolates release-readiness state integration from Xcode and signing assets.
/bin/cat >"$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "--check" &&
    "$2" == "$AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY" ]] || exit 64
[[ -f "$2/release-metadata.json" ]] || exit 65
EOF
/bin/chmod 0755 \
  "$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh"

# State 1: an exact local candidate has passed the credential-free package
# preflight, but it has no functional, delivery, or processing evidence.
run_release_state_readiness \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  | /usr/bin/jq -e \
  --arg archiveSHA "$MAC_EVIDENCE_ARCHIVE_SHA" --arg packageSHA "$MAC_EVIDENCE_PACKAGE_SHA" '
    .releaseIdentityReady == true and
    .macAppStoreReleaseMetadataConfigured == true and
    .macAppStoreExactCandidateEvidenceReady == true and
    .macAppStoreLocalPreflightPassed == true and
    .macMarketingVersion == "0.6.1" and
    .macBuildNumber == "8" and
    .macAppStoreArchiveZipSHA256 == $archiveSHA and
    .macAppStorePackageSHA256 == $packageSHA and
    .macAppStoreFunctionalEvidenceArchiveSHA256 == null and
    .macAppStoreFunctionalEvidencePackageSHA256 == null and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreSandboxFlowVerified == false and
    .macAppStoreFunctionalQAEvidenceConfigured == false and
    .macAppStoreFunctionalQAEvidenceReady == false and
    .macAppStoreFunctionalQAEvidenceInputPath == null and
    .macAppStoreDeliveryEvidenceConfigured == false and
    .macAppStoreDeliveryEvidenceReady == false and
    .macAppStoreUploadAccepted == false and
    .macAppStoreProcessingEvidenceConfigured == false and
    .macAppStoreProcessingEvidenceReady == false and
    .macAppStoreProcessingState == null and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreUpload == false and
    .readyForMacAppStoreReviewSelection == false and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null

# The category embedded in the exact candidate must agree with the Developer
# Tools category selected for App Store Connect.
/usr/bin/jq '.applicationCategory = "public.app-category.productivity"' \
  "$MAC_EVIDENCE_METADATA" >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .macAppStoreReleaseMetadataConfigured == true and
    .macAppStoreExactCandidateEvidenceReady == false and
    .readyForMacAppStoreUpload == false
  ' >/dev/null
/usr/bin/jq '.applicationCategory = "public.app-category.developer-tools"' \
  "$MAC_EVIDENCE_METADATA" >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"

# Bare QA booleans must not survive into the report without exact candidate
# fingerprints. They may have been left in a shell from an older build.
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED='true' \
  AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED='true' \
  AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED='true' \
  AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED='true' \
  AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED='true' \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .macAppStoreExactCandidateEvidenceReady == true and
    .macAppStoreLocalPreflightPassed == true and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreSandboxFlowVerified == false and
    .macAppStoreArchiveVerified == false and
    .macAppStoreProfileCertificateVerified == false and
    .macAppStorePrivacyReportVerified == false and
    .macAppStoreReviewPathVerified == false and
    .readyForMacAppStoreUpload == false and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null

# State 2: only an immutable functional-QA record may activate the five manual
# claims. The generator and validator are the production tools; only their
# credential-free exact-package preflight is stubbed above.
MAC_FUNCTIONAL_EVIDENCE="$MAC_EVIDENCE_RELEASE_DIR/macos-functional-verification-readiness.json"
MAC_FUNCTIONAL_TESTED_AT="$(/bin/date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ')"
MAC_SANDBOX_QA="$MAC_EVIDENCE_RELEASE_DIR/sandbox-flow-report.txt"
MAC_ARCHIVE_QA="$MAC_EVIDENCE_RELEASE_DIR/archive-install-report.txt"
MAC_PROFILE_QA="$MAC_EVIDENCE_RELEASE_DIR/profile-certificate-report.txt"
MAC_PRIVACY_QA="$MAC_EVIDENCE_RELEASE_DIR/xcode-privacy-report.txt"
MAC_REVIEW_QA="$MAC_EVIDENCE_RELEASE_DIR/review-path-report.txt"
print -n -r -- 'sandbox authorization, denial, revocation, recovery' >"$MAC_SANDBOX_QA"
print -n -r -- 'archive install, launch, and quit' >"$MAC_ARCHIVE_QA"
print -n -r -- 'profile and certificate binding' >"$MAC_PROFILE_QA"
print -n -r -- 'privacy report reviewed' >"$MAC_PRIVACY_QA"
print -n -r -- 'example and production review paths' >"$MAC_REVIEW_QA"
MAC_FUNCTIONAL_CONFIRMATION="com.agentisland.mobile:0.6.1:8:$MAC_EVIDENCE_ARCHIVE_SHA:$MAC_EVIDENCE_PACKAGE_SHA"
AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA="$MAC_FUNCTIONAL_CONFIRMATION" \
  "$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh" \
    --mac-model 'MacBook Pro 14-inch (2024)' \
    --macos-version '15.6.1' \
    --tested-at "$MAC_FUNCTIONAL_TESTED_AT" \
    --sandbox-flow-result passed \
    --sandbox-flow-evidence "$MAC_SANDBOX_QA" \
    --archive-install-launch-quit-result passed \
    --archive-install-launch-quit-evidence "$MAC_ARCHIVE_QA" \
    --profile-certificate-result passed \
    --profile-certificate-evidence "$MAC_PROFILE_QA" \
    --privacy-report-result passed \
    --privacy-report-evidence "$MAC_PRIVACY_QA" \
    --review-path-result passed \
    --review-path-evidence "$MAC_REVIEW_QA" \
    --output "$MAC_FUNCTIONAL_EVIDENCE" \
    "$MAC_EVIDENCE_METADATA" >/dev/null
MAC_FUNCTIONAL_EVIDENCE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_FUNCTIONAL_EVIDENCE" | /usr/bin/awk '{print $1}')"

run_release_state_readiness \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="$MAC_FUNCTIONAL_EVIDENCE" \
  | /usr/bin/jq -e \
  --arg input "$MAC_FUNCTIONAL_EVIDENCE" \
  --arg evidenceSHA "$MAC_FUNCTIONAL_EVIDENCE_SHA" \
  --arg archiveSHA "$MAC_EVIDENCE_ARCHIVE_SHA" \
  --arg packageSHA "$MAC_EVIDENCE_PACKAGE_SHA" \
  --arg testedAt "$MAC_FUNCTIONAL_TESTED_AT" '
    .macAppStoreLocalPreflightPassed == true and
    .macAppStoreFunctionalQAEvidenceConfigured == true and
    .macAppStoreFunctionalQAEvidenceReady == true and
    .macAppStoreFunctionalQAEvidenceInputPath == $input and
    .macAppStoreFunctionalQAEvidencePath == $input and
    .macAppStoreFunctionalQAEvidenceSHA256 == $evidenceSHA and
    .macAppStoreFunctionalQAMacModel == "MacBook Pro 14-inch (2024)" and
    .macAppStoreFunctionalQAOSVersion == "15.6.1" and
    .macAppStoreFunctionalQATestedAt == $testedAt and
    .macAppStoreFunctionalEvidenceArchiveSHA256 == $archiveSHA and
    .macAppStoreFunctionalEvidencePackageSHA256 == $packageSHA and
    .macAppStoreFunctionalEvidenceBoundToCandidate == true and
    .macAppStoreSandboxFlowVerified == true and
    .macAppStoreArchiveVerified == true and
    .macAppStoreProfileCertificateVerified == true and
    .macAppStorePrivacyReportVerified == true and
    .macAppStoreReviewPathVerified == true and
    .macAppStoreDeliveryEvidenceConfigured == false and
    .macAppStoreDeliveryEvidenceReady == false and
    .macAppStoreUploadAccepted == false and
    .macAppStoreProcessingEvidenceConfigured == false and
    .macAppStoreProcessingEvidenceReady == false and
    .macAppStoreProcessingState == null and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreReviewSelection == false and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null

# State 3: an accepted upload is a delivery fact only. Its record intentionally
# contains null/false processing and App Review fields.
MAC_DELIVERY_STAMP="$(/bin/date -u -v-5M '+%Y%m%dT%H%M%SZ')"
MAC_DELIVERY_SUBMITTED_AT="$(/bin/date -u -v-4M '+%Y-%m-%dT%H:%M:%SZ')"
MAC_DELIVERY_VALIDATION="$MAC_EVIDENCE_RELEASE_DIR/mac-app-store-validation-$MAC_DELIVERY_STAMP.json"
MAC_DELIVERY_UPLOAD="$MAC_EVIDENCE_RELEASE_DIR/mac-app-store-upload-$MAC_DELIVERY_STAMP.json"
MAC_DELIVERY_EVIDENCE="$MAC_EVIDENCE_RELEASE_DIR/mac-app-store-delivery-$MAC_DELIVERY_STAMP.json"
print -r -- '{"success-message":"No errors validating the readiness fixture."}' \
  >"$MAC_DELIVERY_VALIDATION"
print -r -- '{"success-message":"Successfully uploaded the readiness fixture."}' \
  >"$MAC_DELIVERY_UPLOAD"
MAC_DELIVERY_METADATA_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_EVIDENCE_METADATA" | /usr/bin/awk '{print $1}')"
MAC_DELIVERY_VALIDATION_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_DELIVERY_VALIDATION" | /usr/bin/awk '{print $1}')"
MAC_DELIVERY_UPLOAD_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_DELIVERY_UPLOAD" | /usr/bin/awk '{print $1}')"
/usr/bin/jq -n \
  --arg submittedAt "$MAC_DELIVERY_SUBMITTED_AT" \
  --arg archive "$MAC_EVIDENCE_ARCHIVE_ZIP" \
  --arg archiveSHA "$MAC_EVIDENCE_ARCHIVE_SHA" \
  --arg package "$MAC_EVIDENCE_PACKAGE" \
  --arg packageSHA "$MAC_EVIDENCE_PACKAGE_SHA" \
  --arg metadata "$MAC_EVIDENCE_METADATA" \
  --arg metadataSHA "$MAC_DELIVERY_METADATA_SHA" \
  --arg validation "$MAC_DELIVERY_VALIDATION" \
  --arg validationSHA "$MAC_DELIVERY_VALIDATION_SHA" \
  --arg upload "$MAC_DELIVERY_UPLOAD" \
  --arg uploadSHA "$MAC_DELIVERY_UPLOAD_SHA" '{
    schemaVersion: 1,
    platform: "macOS",
    destination: "App Store Connect / Mac App Store",
    submittedAt: $submittedAt,
    appBundleID: "com.agentisland.mobile",
    version: "0.6.1",
    build: "8",
    archiveZipPath: $archive,
    archiveZipSHA256: $archiveSHA,
    packagePath: $package,
    packageSHA256: $packageSHA,
    releaseMetadataPath: $metadata,
    releaseMetadataSHA256: $metadataSHA,
    validationResultPath: $validation,
    validationResultSHA256: $validationSHA,
    uploadResultPath: $upload,
    uploadResultSHA256: $uploadSHA,
    uploadAccepted: true,
    processingState: null,
    appStoreConnectBuildID: null,
    processingVerified: false,
    processingVerifiedAt: null,
    warningsReviewed: false,
    warningsReviewedAt: null,
    submittedForAppReview: false
  }' >"$MAC_DELIVERY_EVIDENCE"
/bin/chmod 0444 "$MAC_DELIVERY_VALIDATION" "$MAC_DELIVERY_UPLOAD" \
  "$MAC_DELIVERY_EVIDENCE"
MAC_DELIVERY_EVIDENCE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_DELIVERY_EVIDENCE" | /usr/bin/awk '{print $1}')"

run_release_state_readiness \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="$MAC_FUNCTIONAL_EVIDENCE" \
  AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE="$MAC_DELIVERY_EVIDENCE" \
  | /usr/bin/jq -e \
  --arg input "$MAC_DELIVERY_EVIDENCE" \
  --arg evidenceSHA "$MAC_DELIVERY_EVIDENCE_SHA" \
  --arg submittedAt "$MAC_DELIVERY_SUBMITTED_AT" '
    .macAppStoreFunctionalQAEvidenceReady == true and
    .macAppStoreDeliveryEvidenceConfigured == true and
    .macAppStoreDeliveryEvidenceReady == true and
    .macAppStoreDeliveryEvidenceInputPath == $input and
    .macAppStoreDeliveryEvidencePath == $input and
    .macAppStoreDeliveryEvidenceSHA256 == $evidenceSHA and
    .macAppStoreDeliveryBoundToCandidate == true and
    .macAppStoreUploadAccepted == true and
    .macAppStoreUploadSubmittedAt == $submittedAt and
    .macAppStoreProcessingEvidenceConfigured == false and
    .macAppStoreProcessingEvidenceReady == false and
    .macAppStoreProcessingEvidenceInputPath == null and
    .macAppStoreProcessingEvidencePath == null and
    .macAppStoreProcessingEvidenceSHA256 == null and
    .macAppStoreProcessingBoundToDelivery == false and
    .macAppStoreProcessingState == null and
    .macAppStoreProcessingVerified == false and
    .macAppStoreWarningsReviewed == false and
    .macAppStoreConnectBuildID == null and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreReviewSelection == false
  ' >/dev/null

# State 4: processing Complete is independently confirmed and cross-bound to
# the immutable delivery record. It still must not claim App Review submission.
MAC_PROCESSING_AT="$(/bin/date -u -v-2M '+%Y-%m-%dT%H:%M:%SZ')"
MAC_APP_STORE_CONNECT_BUILD_ID='123456789042'
MAC_PROCESSING_CONFIRMATION="com.agentisland.mobile:0.6.1:8:$MAC_EVIDENCE_PACKAGE_SHA:$MAC_APP_STORE_CONNECT_BUILD_ID"
AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING="$MAC_PROCESSING_CONFIRMATION" \
  "$RECORD_FIXTURE_ROOT/ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh" \
    --processing-state Complete \
    --app-store-connect-build-id "$MAC_APP_STORE_CONNECT_BUILD_ID" \
    --processing-verified-at "$MAC_PROCESSING_AT" \
    --warnings-reviewed \
    "$MAC_DELIVERY_EVIDENCE" >/dev/null
MAC_PROCESSING_RECORDS=(
  "$MAC_EVIDENCE_RELEASE_DIR"/mac-app-store-processing-verification-*.json(.N)
)
(( ${#MAC_PROCESSING_RECORDS} == 1 ))
MAC_PROCESSING_EVIDENCE="${MAC_PROCESSING_RECORDS[1]}"
MAC_PROCESSING_EVIDENCE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$MAC_PROCESSING_EVIDENCE" | /usr/bin/awk '{print $1}')"

# A processing record cannot leapfrog its independently supplied delivery
# record, even if that processing file is itself valid.
run_release_state_readiness \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="$MAC_FUNCTIONAL_EVIDENCE" \
  AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE="$MAC_PROCESSING_EVIDENCE" \
  | /usr/bin/jq -e --arg input "$MAC_PROCESSING_EVIDENCE" '
    .macAppStoreProcessingEvidenceConfigured == true and
    .macAppStoreProcessingEvidenceInputPath == $input and
    .macAppStoreProcessingEvidenceReady == false and
    .macAppStoreProcessingEvidencePath == null and
    .macAppStoreProcessingBoundToDelivery == false and
    .macAppStoreUploadAccepted == false and
    .macAppStoreProcessingState == null and
    .macAppStoreProcessingVerified == false and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreReviewSelection == false
  ' >/dev/null

run_release_state_readiness \
  AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="$MAC_FUNCTIONAL_EVIDENCE" \
  AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE="$MAC_DELIVERY_EVIDENCE" \
  AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE="$MAC_PROCESSING_EVIDENCE" \
  | /usr/bin/jq -e \
  --arg input "$MAC_PROCESSING_EVIDENCE" \
  --arg evidenceSHA "$MAC_PROCESSING_EVIDENCE_SHA" \
  --arg processedAt "$MAC_PROCESSING_AT" \
  --arg buildID "$MAC_APP_STORE_CONNECT_BUILD_ID" '
    .releaseIdentityReady == true and
    .macAppStoreLocalPreflightPassed == true and
    .macAppStoreFunctionalQAEvidenceReady == true and
    .macAppStoreDeliveryEvidenceReady == true and
    .macAppStoreUploadAccepted == true and
    .macAppStoreProcessingEvidenceConfigured == true and
    .macAppStoreProcessingEvidenceReady == true and
    .macAppStoreProcessingEvidenceInputPath == $input and
    .macAppStoreProcessingEvidencePath == $input and
    .macAppStoreProcessingEvidenceSHA256 == $evidenceSHA and
    .macAppStoreProcessingBoundToDelivery == true and
    .macAppStoreProcessingState == "Complete" and
    .macAppStoreProcessingVerified == true and
    .macAppStoreProcessingVerifiedAt == $processedAt and
    .macAppStoreWarningsReviewed == true and
    .macAppStoreWarningsReviewedAt == $processedAt and
    .macAppStoreConnectBuildID == $buildID and
    .macAppStoreAppReviewSubmissionRecorded == false and
    .readyForMacAppStoreReviewSelection == false and
    .readyForFunctionalMacAppStoreSubmissionDeprecated == true and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null

# An otherwise intact candidate from a different version is not exact evidence.
/usr/bin/jq '.version = "0.6.2"' "$MAC_EVIDENCE_METADATA" \
  >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .macAppStoreExactCandidateEvidenceReady == false and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreSandboxFlowVerified == false and
    .readyForMacAppStoreUpload == false and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null
/usr/bin/jq '.version = "0.6.1"' "$MAC_EVIDENCE_METADATA" \
  >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"

# The build number is independently part of the exact candidate identity.
/usr/bin/jq '.build = "9"' "$MAC_EVIDENCE_METADATA" \
  >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .macAppStoreExactCandidateEvidenceReady == false and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreArchiveVerified == false and
    .readyForMacAppStoreUpload == false and
    .readyForFunctionalMacAppStoreSubmissionDeprecated == true and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null
/usr/bin/jq '.build = "8"' "$MAC_EVIDENCE_METADATA" \
  >"$MAC_EVIDENCE_METADATA.tmp"
/bin/mv "$MAC_EVIDENCE_METADATA.tmp" "$MAC_EVIDENCE_METADATA"

printf 'changed Mac package fixture\n' >"$MAC_EVIDENCE_PACKAGE"
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
  AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
  AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
  AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
  AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .macAppStoreReleaseMetadataConfigured == true and
    .macAppStoreExactCandidateEvidenceReady == false and
    .macAppStoreFunctionalEvidenceBoundToCandidate == false and
    .macAppStoreSandboxFlowVerified == false and
    .macAppStoreArchiveZipSHA256 == null and
    .macAppStorePackageSHA256 == null and
    .readyForMacAppStoreUpload == false and
    .readyForFunctionalMacAppStoreSubmission == false
  ' >/dev/null

IOS_EVIDENCE_RELEASE_DIR="$RECORD_FIXTURE_ROOT/dist/ios/0.6.1-8-evidence"
/bin/mkdir -p "$IOS_EVIDENCE_RELEASE_DIR/AgentIslandMobile.xcarchive"
IOS_EVIDENCE_IPA="$IOS_EVIDENCE_RELEASE_DIR/MAC-Agent-Monitor.ipa"
IOS_EVIDENCE_METADATA="$IOS_EVIDENCE_RELEASE_DIR/release-metadata.json"
IOS_EVIDENCE_DELIVERY_STAMP="$(/bin/date -u -v-40M '+%Y%m%dT%H%M%SZ')"
IOS_EVIDENCE_VALIDATION="$IOS_EVIDENCE_RELEASE_DIR/testflight-validation-$IOS_EVIDENCE_DELIVERY_STAMP.json"
IOS_EVIDENCE_UPLOAD="$IOS_EVIDENCE_RELEASE_DIR/testflight-upload-$IOS_EVIDENCE_DELIVERY_STAMP.json"
IOS_EVIDENCE_DELIVERY="$IOS_EVIDENCE_RELEASE_DIR/testflight-delivery-$IOS_EVIDENCE_DELIVERY_STAMP.json"
IOS_EVIDENCE_RECORD="$IOS_EVIDENCE_RELEASE_DIR/testflight-verification-evidence.json"
IOS_FUNCTIONAL_QA_EVIDENCE="$IOS_EVIDENCE_RELEASE_DIR/ios-functional-verification-evidence.json"
IOS_EVIDENCE_PAYLOAD="$VERIFY_ROOT/ios-evidence-payload/Payload"
IOS_EVIDENCE_APP="$IOS_EVIDENCE_PAYLOAD/MACAgentMonitor.app"
IOS_EVIDENCE_WIDGET="$IOS_EVIDENCE_APP/PlugIns/AgentIslandLiveActivityExtension.appex"
/bin/mkdir -p "$IOS_EVIDENCE_WIDGET"
/bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/Config/App-Info.plist" "$IOS_EVIDENCE_APP/Info.plist"
/bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/Config/Widget-Info.plist" "$IOS_EVIDENCE_WIDGET/Info.plist"
/bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy" \
  "$IOS_EVIDENCE_APP/PrivacyInfo.xcprivacy"
/bin/cp "$PROJECT_DIR/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy" \
  "$IOS_EVIDENCE_WIDGET/PrivacyInfo.xcprivacy"
for IOS_FIXTURE_PLIST in "$IOS_EVIDENCE_APP/Info.plist" "$IOS_EVIDENCE_WIDGET/Info.plist"; do
  /usr/bin/plutil -replace CFBundleShortVersionString -string '0.6.1' "$IOS_FIXTURE_PLIST"
  /usr/bin/plutil -replace CFBundleVersion -string '8' "$IOS_FIXTURE_PLIST"
done
/usr/bin/plutil -replace CFBundleIdentifier -string 'com.agentisland.mobile' \
  "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string 'MACAgentMonitor' \
  "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace AgentIslandCloudKitContainerIdentifier \
  -string 'iCloud.com.agentisland.mobile' "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace AgentIslandCloudKitRecordType \
  -string 'AgentIslandSnapshot' "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace AgentIslandCloudKitRecordName -string 'latest' \
  "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace AgentIslandCloudKitPayloadField -string 'payloadJSON' \
  "$IOS_EVIDENCE_APP/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier \
  -string 'com.agentisland.mobile.liveactivity' "$IOS_EVIDENCE_WIDGET/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable \
  -string 'AgentIslandLiveActivityExtension' "$IOS_EVIDENCE_WIDGET/Info.plist"
printf 'unsigned arm64-lookalike fixture\n' >"$IOS_EVIDENCE_APP/MACAgentMonitor"
printf 'unsigned arm64-lookalike fixture\n' \
  >"$IOS_EVIDENCE_WIDGET/AgentIslandLiveActivityExtension"
/bin/chmod +x "$IOS_EVIDENCE_APP/MACAgentMonitor" \
  "$IOS_EVIDENCE_WIDGET/AgentIslandLiveActivityExtension"
COPYFILE_DISABLE=1 /usr/bin/ditto --noextattr --norsrc -c -k --keepParent \
  "$IOS_EVIDENCE_PAYLOAD" "$IOS_EVIDENCE_IPA"
printf '{"success-message":"No errors validating the readiness fixture."}\n' \
  >"$IOS_EVIDENCE_VALIDATION"
printf '{"success-message":"Successfully uploaded the readiness fixture."}\n' \
  >"$IOS_EVIDENCE_UPLOAD"
IOS_EVIDENCE_IPA_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_IPA" | /usr/bin/awk '{print $1}')"
IOS_EVIDENCE_VALIDATION_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_VALIDATION" | /usr/bin/awk '{print $1}')"
IOS_EVIDENCE_UPLOAD_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_UPLOAD" | /usr/bin/awk '{print $1}')"
IOS_EVIDENCE_APP_PRIVACY_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_APP/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
IOS_EVIDENCE_WIDGET_PRIVACY_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_WIDGET/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
print -rn -- "$IOS_EVIDENCE_IPA_SHA  ${IOS_EVIDENCE_IPA:t}" >"$IOS_EVIDENCE_IPA.sha256"
/usr/bin/jq -n \
  --arg ipa "$IOS_EVIDENCE_IPA" --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" \
  --arg archive "$IOS_EVIDENCE_RELEASE_DIR/AgentIslandMobile.xcarchive" \
  --arg appPrivacySHA "$IOS_EVIDENCE_APP_PRIVACY_SHA" \
  --arg widgetPrivacySHA "$IOS_EVIDENCE_WIDGET_PRIVACY_SHA" \
  --arg displayName "$PUBLIC_DISPLAY_NAME" '{
    schemaVersion: 1,
    product: $displayName,
    version: "0.6.1",
    build: "8",
    archivePath: $archive,
    exportedIPA: $ipa,
    ipaSHA256: $ipaSHA,
    teamID: "ABCDE12345",
    appBundleID: "com.agentisland.mobile",
    widgetBundleID: "com.agentisland.mobile.liveactivity",
    appIdentifier: "ABCDE12345.com.agentisland.mobile",
    widgetIdentifier: "ABCDE12345.com.agentisland.mobile.liveactivity",
    displayName: $displayName,
    cloudContainerID: "iCloud.com.agentisland.mobile",
    cloudKitEnvironment: "Production",
    cloudKitRecordContract: {
      recordType: "AgentIslandSnapshot",
      recordName: "latest",
      payloadField: "payloadJSON"
    },
    privacyManifestSHA256: {app: $appPrivacySHA, widget: $widgetPrivacySHA},
    signingIdentity: "Apple Distribution: Fixture (ABCDE12345)",
    signingCertificateSHA1: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    privacyPolicyURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/",
    supportURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/",
    allowProvisioningUpdates: false,
    uploaded: false
  }' >"$IOS_EVIDENCE_METADATA"
IOS_EVIDENCE_METADATA_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_METADATA" | /usr/bin/awk '{print $1}')"
IOS_EVIDENCE_SUBMITTED_AT="$(/bin/date -u -v-40M '+%Y-%m-%dT%H:%M:%SZ')"
IOS_EVIDENCE_PROCESSING_AT="$(/bin/date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')"
IOS_EVIDENCE_TESTED_AT="$(/bin/date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
IOS_EVIDENCE_CREATED_AT="$(/bin/date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ')"
IOS_FUNCTIONAL_QA_TESTED_AT="$(/bin/date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n \
  --arg submittedAt "$IOS_EVIDENCE_SUBMITTED_AT" \
  --arg ipa "$IOS_EVIDENCE_IPA" --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" \
  --arg metadata "$IOS_EVIDENCE_METADATA" --arg metadataSHA "$IOS_EVIDENCE_METADATA_SHA" \
  --arg validation "$IOS_EVIDENCE_VALIDATION" --arg validationSHA "$IOS_EVIDENCE_VALIDATION_SHA" \
  --arg upload "$IOS_EVIDENCE_UPLOAD" --arg uploadSHA "$IOS_EVIDENCE_UPLOAD_SHA" '{
    schemaVersion: 1,
    platform: "iOS",
    destination: "App Store Connect / TestFlight",
    submittedAt: $submittedAt,
    appBundleID: "com.agentisland.mobile",
    version: "0.6.1",
    build: "8",
    ipaPath: $ipa,
    ipaSHA256: $ipaSHA,
    releaseMetadataPath: $metadata,
    releaseMetadataSHA256: $metadataSHA,
    validationResultPath: $validation,
    validationResultSHA256: $validationSHA,
    uploadResultPath: $upload,
    uploadResultSHA256: $uploadSHA,
    uploadAccepted: true,
    processingState: null,
    appStoreConnectBuildID: null,
    processingVerified: false,
    processingVerifiedAt: null,
    distributedToTesters: false,
    installedFromTestFlight: false,
    testedAt: null,
    submittedForAppReview: false
  }' >"$IOS_EVIDENCE_DELIVERY"
/bin/chmod 0444 "$IOS_EVIDENCE_VALIDATION" "$IOS_EVIDENCE_UPLOAD" \
  "$IOS_EVIDENCE_DELIVERY"
IOS_EVIDENCE_DELIVERY_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IOS_EVIDENCE_DELIVERY" | /usr/bin/awk '{print $1}')"
/usr/bin/jq -n \
  --arg processingAt "$IOS_EVIDENCE_PROCESSING_AT" \
  --arg testedAt "$IOS_EVIDENCE_TESTED_AT" \
  --arg createdAt "$IOS_EVIDENCE_CREATED_AT" \
  --arg ipa "$IOS_EVIDENCE_IPA" --arg ipaSHA "$IOS_EVIDENCE_IPA_SHA" \
  --arg metadata "$IOS_EVIDENCE_METADATA" --arg metadataSHA "$IOS_EVIDENCE_METADATA_SHA" \
  --arg delivery "$IOS_EVIDENCE_DELIVERY" --arg deliverySHA "$IOS_EVIDENCE_DELIVERY_SHA" '{
    schemaVersion: 1,
    platform: "iOS",
    appBundleID: "com.agentisland.mobile",
    version: "0.6.1",
    build: "8",
    ipaPath: $ipa,
    ipaSHA256: $ipaSHA,
    releaseMetadataPath: $metadata,
    releaseMetadataSHA256: $metadataSHA,
    deliveryRecordPath: $delivery,
    deliveryRecordSHA256: $deliverySHA,
    uploadAccepted: true,
    appStoreConnectBuildID: "fixture-build-id",
    processingState: "VALID",
    processingVerifiedAt: $processingAt,
    distributedToTesters: true,
    installedFromTestFlight: true,
    testedAt: $testedAt,
    createdAt: $createdAt
  }' >"$IOS_EVIDENCE_RECORD"
/bin/chmod 0444 "$IOS_EVIDENCE_RECORD"

# The real credential-free preflight must reject an unsigned ZIP even when all
# hand-written metadata and evidence hashes agree.
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE="$IOS_EVIDENCE_RECORD" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e \
  --arg sha "$IOS_EVIDENCE_IPA_SHA" '
    .iosTestFlightEvidenceConfigured == true and
    .iosLocalIPAPreflightPassed == false and
    .iosTestFlightExactBuildEvidenceReady == false and
    .iosTestFlightUploadVerified == false and
    .iosFunctionalQAEvidenceConfigured == false and
    .iosFunctionalQAEvidenceReady == false and
    .iosFunctionalEvidenceBoundToCandidate == false and
    .iosTestFlightIPASHA256 == null
  ' >/dev/null

# Once the real preflight rejection above is proven, isolate the remaining
# readiness contract with a fixture-local successful preflight executable.
# Production readiness always invokes the repository's full --check script.
/bin/cp /usr/bin/true \
  "$RECORD_FIXTURE_ROOT/ApplePlatforms/iOS/scripts/submit-testflight.sh"
IOS_FUNCTIONAL_QA_CLOUDKIT="$IOS_EVIDENCE_RELEASE_DIR/cloudkit-production-report.txt"
IOS_FUNCTIONAL_QA_SYNC="$IOS_EVIDENCE_RELEASE_DIR/same-account-sync-report.txt"
IOS_FUNCTIONAL_QA_LIVE="$IOS_EVIDENCE_RELEASE_DIR/live-activity-report.txt"
IOS_FUNCTIONAL_QA_REVIEW="$IOS_EVIDENCE_RELEASE_DIR/review-path-report.txt"
print -r -- 'Production CloudKit schema inspected for this release container.' \
  >"$IOS_FUNCTIONAL_QA_CLOUDKIT"
print -r -- 'Same-account Mac-to-iPhone refresh observed on the installed build.' \
  >"$IOS_FUNCTIONAL_QA_SYNC"
print -r -- 'Live Activity observed on the named physical iPhone.' \
  >"$IOS_FUNCTIONAL_QA_LIVE"
print -r -- 'Example and production review paths completed on the installed build.' \
  >"$IOS_FUNCTIONAL_QA_REVIEW"
AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA="com.agentisland.mobile:0.6.1:8:$IOS_EVIDENCE_IPA_SHA" \
  "$RECORD_FIXTURE_ROOT/ApplePlatforms/iOS/scripts/confirm-functional-qa-evidence.sh" \
    --device-model 'iPhone 16 Pro' \
    --ios-version '18.6.2' \
    --tested-at "$IOS_FUNCTIONAL_QA_TESTED_AT" \
    --cloudkit-production-schema-result passed \
    --cloudkit-evidence "$IOS_FUNCTIONAL_QA_CLOUDKIT" \
    --same-account-sync-result passed \
    --sync-evidence "$IOS_FUNCTIONAL_QA_SYNC" \
    --live-activity-result passed \
    --live-activity-evidence "$IOS_FUNCTIONAL_QA_LIVE" \
    --review-path-result passed \
    --review-path-evidence "$IOS_FUNCTIONAL_QA_REVIEW" \
    --output "$IOS_FUNCTIONAL_QA_EVIDENCE" \
    "$IOS_EVIDENCE_RECORD" >/dev/null
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE="$IOS_EVIDENCE_RECORD" \
  AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE="$IOS_FUNCTIONAL_QA_EVIDENCE" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e \
  --arg sha "$IOS_EVIDENCE_IPA_SHA" \
  --arg qaPath "$IOS_FUNCTIONAL_QA_EVIDENCE" '
    .iosLocalIPAPreflightPassed == true and
    .iosTestFlightExactBuildEvidenceReady == true and
    .iosTestFlightUploadVerified == true and
    .iosTestFlightProcessingVerified == true and
    .iosTestFlightInstallVerified == true and
    .iosFunctionalQAEvidenceConfigured == true and
    .iosFunctionalQAEvidenceReady == true and
    .iosFunctionalQAEvidencePath == $qaPath and
    (.iosFunctionalQAEvidenceSHA256 | test("^[0-9a-f]{64}$")) and
    .iosFunctionalQADeviceModel == "iPhone 16 Pro" and
    .iosFunctionalQAOSVersion == "18.6.2" and
    .cloudKitProductionSchemaVerified == true and
    .iosRealDeviceSyncVerified == true and
    .iosLiveActivityVerified == true and
    .iosReviewPathVerified == true and
    .iosFunctionalEvidenceBoundToCandidate == true and
    .iosTestFlightIPASHA256 == $sha and
    .iosTestFlightAppStoreConnectBuildID == "fixture-build-id" and
    .appPrivacyReleaseEvidenceReady == false and
    .iosPrivacyReleaseEvidenceReady == false and
    .readyForFunctionalIOSTestFlight == false
  ' >/dev/null

# Build a valid Mac package and one privacy-evidence set that can be narrowed to
# either store record. This verifies that global evidence validity cannot leak
# across platforms, while an exact platform/build/artifact match can pass.
MAC_PRIVACY_COMPONENT="$VERIFY_ROOT/MACPrivacyFixture.app"
/bin/cp -R "$APP_PATH" "$MAC_PRIVACY_COMPONENT"
/usr/bin/plutil -replace CFBundleIdentifier -string 'com.agentisland.mobile' \
  "$MAC_PRIVACY_COMPONENT/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string '0.6.1' \
  "$MAC_PRIVACY_COMPONENT/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string '8' \
  "$MAC_PRIVACY_COMPONENT/Contents/Info.plist"
/usr/bin/pkgbuild --component "$MAC_PRIVACY_COMPONENT" \
  --identifier 'com.agentisland.mobile' --version '0.6.1' \
  --install-location '/Applications' "$MAC_EVIDENCE_PACKAGE" >/dev/null
MAC_EVIDENCE_PACKAGE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$MAC_EVIDENCE_PACKAGE" | /usr/bin/awk '{print $1}')"
/usr/bin/jq --arg packageSHA "$MAC_EVIDENCE_PACKAGE_SHA" '
  .version = "0.6.1" | .build = "8" | .packageSHA256 = $packageSHA
' "$MAC_EVIDENCE_METADATA" >"$VERIFY_ROOT/mac-evidence-metadata.json"
/bin/mv "$VERIFY_ROOT/mac-evidence-metadata.json" "$MAC_EVIDENCE_METADATA"

PLATFORM_PRIVACY_ROOT="$RECORD_FIXTURE_ROOT/dist/privacy-platform-binding"
/bin/mkdir -p "$PLATFORM_PRIVACY_ROOT"
PLATFORM_PRIVACY_RECORDS="$PLATFORM_PRIVACY_ROOT/evidence-records.jsonl"
/usr/bin/touch "$PLATFORM_PRIVACY_RECORDS"
for PRIVACY_EVIDENCE_KIND in \
    privacyManifests xcodePrivacyReport networkAudit cloudKitVerification \
    titleSyncVerification translationProviderDecision publicPagesVerification \
    appStoreConnectPublication; do
  PLATFORM_PRIVACY_FILE="$PLATFORM_PRIVACY_ROOT/$PRIVACY_EVIDENCE_KIND.txt"
  print -r -- \
    "macOSCandidateSHA256=$MAC_EVIDENCE_PACKAGE_SHA iOSCandidateSHA256=$IOS_EVIDENCE_IPA_SHA" \
    >"$PLATFORM_PRIVACY_FILE"
  PLATFORM_PRIVACY_FILE_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PLATFORM_PRIVACY_FILE" | /usr/bin/awk '{print $1}')"
  PLATFORM_PRIVACY_FILE_RELATIVE="${PLATFORM_PRIVACY_FILE#$RECORD_FIXTURE_ROOT/}"
  /usr/bin/jq -cn \
    --arg key "$PRIVACY_EVIDENCE_KIND" \
    --arg path "$PLATFORM_PRIVACY_FILE_RELATIVE" \
    --arg sha256 "$PLATFORM_PRIVACY_FILE_SHA" \
    --arg macSHA "$MAC_EVIDENCE_PACKAGE_SHA" \
    --arg iosSHA "$IOS_EVIDENCE_IPA_SHA" \
    '{key: $key, value: {
      path: $path,
      sha256: $sha256,
      candidateArchiveSHA256s: [$macSHA, $iosSHA]
    }}' >>"$PLATFORM_PRIVACY_RECORDS"
done
PLATFORM_PRIVACY_EVIDENCE_OBJECT="$(/usr/bin/jq -sc 'from_entries' "$PLATFORM_PRIVACY_RECORDS")"
COMBINED_PRIVACY_CONFIG="$PLATFORM_PRIVACY_ROOT/combined.json"
MAC_ONLY_PRIVACY_CONFIG="$PLATFORM_PRIVACY_ROOT/mac-only.json"
IOS_ONLY_PRIVACY_CONFIG="$PLATFORM_PRIVACY_ROOT/ios-only.json"
MAC_EVIDENCE_PACKAGE_RELATIVE="${MAC_EVIDENCE_PACKAGE#$RECORD_FIXTURE_ROOT/}"
IOS_EVIDENCE_IPA_RELATIVE="${IOS_EVIDENCE_IPA#$RECORD_FIXTURE_ROOT/}"
/usr/bin/jq -n \
  --arg macPath "$MAC_EVIDENCE_PACKAGE_RELATIVE" \
  --arg macSHA "$MAC_EVIDENCE_PACKAGE_SHA" \
  --arg iosPath "$IOS_EVIDENCE_IPA_RELATIVE" \
  --arg iosSHA "$IOS_EVIDENCE_IPA_SHA" \
  --argjson evidence "$PLATFORM_PRIVACY_EVIDENCE_OBJECT" '{
    schemaVersion: 1,
    recordScope: "universal-purchase",
    reviewedAt: "2026-09-04T01:12:00Z",
    archives: [
      {
        platform: "macOS", distribution: "mac-app-store", path: $macPath,
        sha256: $macSHA, bundleID: "com.agentisland.mobile",
        version: "0.6.1", build: "8"
      },
      {
        platform: "iOS", distribution: "app-store", path: $iosPath,
        sha256: $iosSHA, bundleID: "com.agentisland.mobile",
        version: "0.6.1", build: "8"
      }
    ],
    evidence: $evidence
  }' >"$COMBINED_PRIVACY_CONFIG"
/usr/bin/jq --arg macSHA "$MAC_EVIDENCE_PACKAGE_SHA" '
  .recordScope = "macOS"
  | .archives = [.archives[] | select(.platform == "macOS")]
  | .evidence[].candidateArchiveSHA256s = [$macSHA]
' "$COMBINED_PRIVACY_CONFIG" >"$MAC_ONLY_PRIVACY_CONFIG"
/usr/bin/jq --arg iosSHA "$IOS_EVIDENCE_IPA_SHA" '
  .recordScope = "iOS"
  | .archives = [.archives[] | select(.platform == "iOS")]
  | .evidence[].candidateArchiveSHA256s = [$iosSHA]
' "$COMBINED_PRIVACY_CONFIG" >"$IOS_ONLY_PRIVACY_CONFIG"

COMBINED_PRIVACY_CONFIG_RELATIVE="${COMBINED_PRIVACY_CONFIG#$RECORD_FIXTURE_ROOT/}"
MAC_ONLY_PRIVACY_CONFIG_RELATIVE="${MAC_ONLY_PRIVACY_CONFIG#$RECORD_FIXTURE_ROOT/}"
IOS_ONLY_PRIVACY_CONFIG_RELATIVE="${IOS_ONLY_PRIVACY_CONFIG#$RECORD_FIXTURE_ROOT/}"
AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$COMBINED_PRIVACY_CONFIG_RELATIVE" \
  node "$RECORD_FIXTURE_ROOT/scripts/validate-app-privacy.mjs" --release \
  | /usr/bin/jq -e '.releaseEvidenceReady == true and .releaseReady == true' >/dev/null

record_fixture_readiness() {
  local privacy_evidence="$1"
  /usr/bin/env \
    DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
    AGENT_ISLAND_TEST_EXPECTED_RELEASE_DIRECTORY="$MAC_EVIDENCE_RELEASE_DIR" \
    AGENT_ISLAND_BUNDLE_ID='com.agentisland.mobile' \
    AGENT_ISLAND_DEVELOPMENT_TEAM='ABCDE12345' \
    AGENT_ISLAND_ICLOUD_CONTAINER_ID='iCloud.com.agentisland.mobile' \
    AGENT_ISLAND_PRIVACY_POLICY_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
    AGENT_ISLAND_SUPPORT_URL='https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
    AGENT_ISLAND_DISPLAY_NAME="$PUBLIC_DISPLAY_NAME" \
    AGENT_ISLAND_APP_STORE_RECORD_MODE='universal-purchase' \
    AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$MAC_EVIDENCE_METADATA" \
    AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE="$IOS_EVIDENCE_RECORD" \
    AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE="$IOS_FUNCTIONAL_QA_EVIDENCE" \
    AGENT_ISLAND_APP_PRIVACY_EVIDENCE="$privacy_evidence" \
    "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh"
}

record_fixture_readiness "$MAC_ONLY_PRIVACY_CONFIG_RELATIVE" | /usr/bin/jq -e '
  .iosTestFlightExactBuildEvidenceReady == true and
  .appPrivacyReleaseEvidenceReady == true and
  .macPrivacyReleaseEvidenceReady == false and
  .iosPrivacyReleaseEvidenceReady == false
' >/dev/null
record_fixture_readiness "$IOS_ONLY_PRIVACY_CONFIG_RELATIVE" | /usr/bin/jq -e '
  .iosTestFlightExactBuildEvidenceReady == true and
  .appPrivacyReleaseEvidenceReady == true and
  .macPrivacyReleaseEvidenceReady == false and
  .iosPrivacyReleaseEvidenceReady == false
' >/dev/null
record_fixture_readiness "$COMBINED_PRIVACY_CONFIG_RELATIVE" | /usr/bin/jq -e '
  .iosTestFlightExactBuildEvidenceReady == true and
  .appPrivacyReleaseEvidenceReady == true and
  .macPrivacyReleaseEvidenceReady == true and
  .iosPrivacyReleaseEvidenceReady == true
' >/dev/null

/bin/chmod 0644 "$IOS_EVIDENCE_UPLOAD"
printf '{"uploaded":false}\n' >"$IOS_EVIDENCE_UPLOAD"
/usr/bin/env \
  DEVELOPER_DIR='/Library/Developer/CommandLineTools' \
  AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE="$IOS_EVIDENCE_RECORD" \
  AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE="$IOS_FUNCTIONAL_QA_EVIDENCE" \
  "$RECORD_FIXTURE_ROOT/scripts/release-readiness.sh" | /usr/bin/jq -e '
    .iosTestFlightEvidenceConfigured == true and
    .iosLocalIPAPreflightPassed == true and
    .iosTestFlightExactBuildEvidenceReady == false and
    .iosTestFlightUploadVerified == false and
    .iosTestFlightProcessingVerified == false and
    .iosTestFlightInstallVerified == false and
    .iosFunctionalEvidenceBoundToCandidate == false and
    .iosPrivacyReleaseEvidenceReady == false
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
  AGENT_ISLAND_VERSION='0.6.1' \
  AGENT_ISLAND_BUILD_NUMBER='8' \
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
    (.iosAppBundleID == "com.example.agentisland") and
    (.iosWidgetBundleID == "com.example.agentisland.liveactivity") and
    (.iosAppBundleIDConfigured == false) and
    (.iosWidgetBundleIDConfigured == false) and
    (.iosDevelopmentTeamConfigured == false) and
    (.iosCloudKitContainerConfigured == false) and
    (.iosPrivacyPolicyURLConfigured == true) and
    (.iosSupportURLConfigured == true) and
    (.iosBuildSettingsMatchEnvironment == false) and
    (.readyForIOSArchive == false)
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
for SANDBOX_ACCESS_MARKER in \
  'AgentIslandHomeAccessBookmarkV1' \
  'NSURLBookmarkCreationWithSecurityScope' \
  'NSURLBookmarkResolutionWithSecurityScope' \
  'NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess' \
  'startAccessingSecurityScopedResource' \
  'stopAccessingSecurityScopedResource' \
  'AIUserHomeDirectory()' \
  'AIPathIsInsideDirectory' \
  'homeAccessAuthorized' \
  'homeAccessStored' \
  'activeHomeSecurityScope'; do
  rg -q --fixed-strings -- "$SANDBOX_ACCESS_MARKER" "$PROJECT_DIR/Native/AgentIsland.m"
done
for SANDBOX_UI_MARKER in \
  'data-action="authorizeHomeAccess"' \
  'data-action="revokeHomeAccess"' \
  'homeAccessRequired' \
  'homeAccessAuthorized' \
  'homeAccessStored'; do
  rg -q --fixed-strings -- "$SANDBOX_UI_MARKER" "$PROJECT_DIR/Web/index.html"
done
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
    "contentExcluded", "noSensitivePermissions", "monitoringControl", "reviewDataAccess", "homeFolderAccess",
    "homeFolderAccessHint", "authorizeHomeFolder", "reauthorizeHomeFolder", "revokeHomeFolder",
    "homeAuthorizationRequired", "checkUpdates", "safeUpdateHint",
    "translationTransferNoticeDeepSeek", "translationConsentEyebrow", "translationConsentTitle",
    "translationConsentDeepSeek", "translationConsentCustom", "translationConsentAuthority",
    "translationConsentCancel", "translationConsentContinue", "studySearchRegion", "searchStudy",
    "studyStatusFilter", "studyFilterAll", "studyFilterLearning", "studyResultSummary", "noMatchingStudy",
    "exampleBanner", "exampleModeTitle", "exampleModeIntro", "exampleModeControl", "exampleModeControlHint",
    "enterExampleMode", "exitExampleMode", "exampleModeOn", "exampleActionBlocked", "exampleHistoryDisclaimer"]
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
    "dataAccessCard", "monitoringSwitch", "homeAccessRow", "authorizeHomeAccessButton",
    "revokeHomeAccessButton", "reviewDataAccessButton", "dataAccessStatus",
    "exampleBanner", "exampleModeCard", "exampleModeButton", "exampleModeStatus", "advancedSourcesDetails",
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
    "reviewDataAccess", "authorizeHomeAccess", "revokeHomeAccess", "homeAccessStored",
    "setMonitoringEnabled", "dataAccessResult", "setExampleMode", "bundledOfflineExample", "exampleDataOnly"]) {
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
    /bridge\("setExampleMode",\{enabled:enableExample\}\)/,
    /bridge\("reviewDataAccess"\)/,
    /bridge\("authorizeHomeAccess"\)/,
    /bridge\("revokeHomeAccess"\)/,
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
  if (!/cloudSyncSwitch"\)\.disabled=example\|\|state\.cloudSyncPending\|\|\(!cloudCapable&&!cloudEnabled\)/.test(source))
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
      !/compactIdle:"No Agents active"/.test(source) ||
      !/compactExample:"示例 · \{agents\} 个 Agent 工作中"/.test(source) ||
      !/compactExample:"Example · \{agents\} Agents active"/.test(source))
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
  if (!/var live=!state\.exampleMode&&state\.dataAccess\.monitoringEnabled&&!!state\.snapshot\.scannedAt&&active\.length>0/.test(source))
    throw new Error("Stale Agent activity must not appear live while monitoring is off or before the first scan")
  if (!/if\(state\.exampleMode\)[\s\S]{0,180}status=t\("compactExample",\{agents:active\.length\}\)/.test(source) ||
      !/#compact\.example \.compact-status\s*\{[^}]*color\s*:\s*#c4b5fd/.test(stylesheet))
    throw new Error("Compact island must identify example data on its existing single status line")
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
  if (!refreshMethod || refreshMethod[0].indexOf("if (self.exampleModeEnabled)") < 0 ||
      refreshMethod[0].indexOf("if (self.exampleModeEnabled)") > refreshMethod[0].indexOf("!self.dataAccessConsented || !self.monitoringEnabled") ||
      !/if \(self\.exampleModeEnabled\)[\s\S]{0,220}AIOfflineExampleSnapshot\(\)[\s\S]{0,80}return;/.test(refreshMethod[0]))
    throw new Error("Offline example refresh must return bundled data before every real-log access gate")
  const exampleBuilder = nativeSource.match(/static NSDictionary \*AIOfflineExampleSnapshot\(void\)[\s\S]*?\n}\n\nstatic NSDictionary \*AISnapshot/)
  if (!exampleBuilder) throw new Error("Native offline example snapshot builder is missing")
  for (const forbidden of ["AIScanCodex", "AIScanClaude", "AIScanCustom", "NSFileManager", "CKContainer", "NSURLSession", "AIWorkspaceLoad", "AITranslatorConfig"])
    if (exampleBuilder[0].includes(forbidden)) throw new Error("Offline example builder performs a forbidden operation: " + forbidden)
  for (const marker of ["@\"exampleMode\": @YES", "@\"exampleDataOnly\": @YES", "@\"dataOrigin\": @\"bundledOfflineExample\"",
    "@\"networkRequests\": @NO", "@\"automaticNetworkRequests\": @NO", "@\"project\": @\"\""])
    if (!exampleBuilder[0].includes(marker)) throw new Error("Offline example snapshot is missing safety marker: " + marker)
  const exampleToggle = nativeSource.match(/- \(void\)setExampleModeEnabledFromBody:[\s\S]*?\n}\n\n- \(void\)toggleExampleModeFromMenu:/)
  for (const marker of ["self.refreshing || self.translatorTask", "self.cloudSyncUploading", "self.cloudSyncDeleting",
    "self.cloudSyncAccountChecking", "self.localDataOperationInFlight", "self.monitoringEnabled = NO", "AIExampleModeDefaultsKey", "monitoringGeneration += 1",
    "self.cloudSyncForceAfterRefresh = NO", "self.cloudSyncUploadAfterCurrent = NO"])
    if (!exampleToggle || !exampleToggle[0].includes(marker)) throw new Error("Offline example transition is missing fail-closed behavior: " + marker)
  const syncMethod = nativeSource.match(/- \(void\)synchronizeSnapshotIfNeeded:[\s\S]*?\n}\n\n- \(void\)refreshSnapshot/)
  if (!syncMethod || !/self\.exampleModeEnabled \|\| \[snapshot\[@"exampleMode"\] boolValue\]/.test(syncMethod[0]))
    throw new Error("CloudKit synchronization must reject both example mode and marked example snapshots")
  const pushSnapshotMethod = nativeSource.match(/- \(void\)pushSnapshot:[\s\S]*?\n}\n\n@end/)
  for (const marker of ["claimsExample", "validExample", "self.exampleModeEnabled && !validExample", "!self.exampleModeEnabled && claimsExample"])
    if (!pushSnapshotMethod || !pushSnapshotMethod[0].includes(marker))
      throw new Error("Native snapshot delivery must reject real/example provenance mismatches: " + marker)
  if (!/if\(\(claimsExample\|\|expectsExample\)&&!validExample\)\{[\s\S]{0,160}render\(\);\s*return;/.test(source))
    throw new Error("Web snapshot delivery must discard, not consume, provenance-mismatched payloads")
  const disclosureMethod = nativeSource.match(/- \(void\)presentDataAccessDisclosureAllowingStart:[\s\S]*?\n}\n\n- \(void\)setMonitoringEnabledFromBody:/)
  if (!disclosureMethod || !disclosureMethod[0].includes("allowingStart = allowingStart && !self.exampleModeEnabled"))
    throw new Error("Reviewing the local-data disclosure in example mode must not enable real monitoring")
  if (!disclosureMethod || !disclosureMethod[0].includes("self.localDataOperationInFlight = YES") ||
      !disclosureMethod[0].includes("self.localDataOperationInFlight = NO") ||
      (disclosureMethod[0].match(/if \(self\.exampleModeEnabled\)/g)||[]).length < 1)
    throw new Error("The modal data-access review must block example entry and re-check mode before mutating consent")
  for (const marker of ["Codex", "Claude", "IDE Agent", "prompt", "response bodies", "iPhone/iCloud sync",
    "Agent/tool/provider names", "model names", "project paths", "source-attribution metadata",
    "Camera", "Microphone", "Screen Recording", "Accessibility", "AIDataAccessConsentVersion"]) {
    if (!disclosureMethod || !disclosureMethod[0].includes(marker)) throw new Error("Data-access notice is incomplete: " + marker)
  }
  const dataAccessStateMethod = nativeSource.match(/- \(NSDictionary \*\)dataAccessPublicState[\s\S]*?\n}\n\n- \(void\)pushDataAccessStateWithMessage:/)
  if (!dataAccessStateMethod || !dataAccessStateMethod[0].includes("self.exampleModeEnabled ? NO : AIHomeAccessAuthorized()") ||
      !dataAccessStateMethod[0].includes("self.exampleModeEnabled ? NO : AIHomeAccessBookmarkStored()"))
    throw new Error("Offline example state must not resolve or expose a real Home-folder authorization")
  const pushDataAccessMethod = nativeSource.match(/- \(void\)pushDataAccessStateWithMessage:[\s\S]*?\n}\n\n- \(void\)startMonitoring/)
  if (!pushDataAccessMethod || !pushDataAccessMethod[0].includes("self.exampleModeEnabled ? @[] : AICustomSources()"))
    throw new Error("Offline example state must not expose saved custom-source paths")
  const configureCloudMethod = nativeSource.match(/- \(void\)configureCloudSync:[\s\S]*?\n}\n\n- \(void\)syncCloudNow:/)
  for (const marker of ["self.cloudSyncAccountChecking || self.cloudSyncDeleting", "self.cloudSyncDeleteAfterUploadRequestID.length", "if (self.cloudSyncUploading)"])
    if (!configureCloudMethod || !configureCloudMethod[0].includes(marker))
      throw new Error("Cloud sync configuration must serialize asynchronous operations: " + marker)
  const fetchCloudAccountMethod = nativeSource.match(/- \(void\)fetchCurrentCloudAccountKey:[\s\S]*?\n}\n\n- \(void\)stopCloudSyncForAccountChange:/)
  if (!fetchCloudAccountMethod || (fetchCloudAccountMethod[0].match(/if \(self\.exampleModeEnabled\)/g)||[]).length < 3)
    throw new Error("Every asynchronous CloudKit account step must fail closed in offline example mode")
  if (!fetchCloudAccountMethod || (fetchCloudAccountMethod[0].match(/dispatch_async\(dispatch_get_main_queue\(\)/g)||[]).length < 2)
    throw new Error("CloudKit account callbacks must move state decisions to the main thread")
  const cloudAccountChangedMethod = nativeSource.match(/- \(void\)cloudAccountChanged:[\s\S]*?\n}\n\n- \(void\)configureCloudSync:/)
  if (!cloudAccountChangedMethod || !cloudAccountChangedMethod[0].includes("if (!NSThread.isMainThread)") ||
      !cloudAccountChangedMethod[0].includes("dispatch_get_main_queue()"))
    throw new Error("CloudKit account-change notifications must serialize state on the main thread")
  const translateMethod = nativeSource.match(/- \(void\)translate:[\s\S]*?\n}\n\n- \(void\)URLSession:\(NSURLSession \*\)session task:/)
  if (!translateMethod || !translateMethod[0].includes("if (self.translatorTask)") || translateMethod[0].includes("previousTask"))
    throw new Error("Native translation requests must be single-flight")
  const redirectMethod = nativeSource.match(/willPerformHTTPRedirection:[\s\S]*?\n}\n\n- \(void\)URLSession:\(NSURLSession \*\)session dataTask:/)
  if (!redirectMethod || !redirectMethod[0].includes("session != self.translatorSession") ||
      !redirectMethod[0].includes("task != self.translatorTask") || !redirectMethod[0].includes("self.exampleModeEnabled"))
    throw new Error("Translation redirects must validate the active task and offline-example state")
  const translatorSessionMethod = nativeSource.match(/- \(NSURLSession \*\)translatorRequestSession[\s\S]*?\n}\n\n- \(void\)pushTranslationErrorForRequestID:/)
  if (!translatorSessionMethod || !translatorSessionMethod[0].includes("delegateQueue:NSOperationQueue.mainQueue"))
    throw new Error("Translation task state must be confined to the main thread")
  const authorizeHomeMethod = nativeSource.match(/- \(void\)authorizeHomeAccessStartingMonitoring:[\s\S]*?\n}\n\n- \(void\)revokeHomeAccess/)
  const revokeHomeMethod = nativeSource.match(/- \(void\)revokeHomeAccess[\s\S]*?\n}\n\n- \(void\)checkForUpdatesFromMenu:/)
  const chooseSourceMethod = nativeSource.match(/- \(void\)chooseSource[\s\S]*?\n}\n\n- \(void\)addConnectionCode:/)
  for (const [name, method] of [["Home-folder authorization",authorizeHomeMethod],["Home-folder revocation",revokeHomeMethod],["custom-source picker",chooseSourceMethod]]) {
    if (!method || !method[0].includes("self.localDataOperationInFlight") ||
        (method[0].match(/self\.exampleModeEnabled/g)||[]).length < 2)
      throw new Error(name + " must serialize its modal operation and re-check offline-example mode")
  }
  if (!/AIDataAccessConsentVersion\s*=\s*2/.test(nativeSource))
    throw new Error("Expanded local-data disclosure must force existing users to consent again")
  for (const marker of ["tool/Agent/provider names", "conversation titles", "models", "project paths", "source attribution"]) {
    if (!source.includes(marker)) throw new Error("Web local-data disclosure is incomplete: " + marker)
  }
  const codexCollector = nativeSource.match(/static NSArray<NSDictionary \*> \*AIScanCodex[\s\S]*?\n}\n\nstatic NSArray<NSDictionary \*> \*AIScanClaudeAtRoot/)
  for (const marker of ["sessionsRoot", "archivedSessionsRoot", "trustedRolloutPath", "canonicalRolloutPath",
    "Ignored a log path outside known Codex session directories"]) {
    if (!codexCollector || !codexCollector[0].includes(marker)) throw new Error("Codex rollout path trust boundary is missing: " + marker)
  }
  const customSourceList = nativeSource.match(/static NSArray<NSDictionary \*> \*AICustomSources\(void\)[\s\S]*?\n}\n\nstatic NSString \*AICustomStatus/)
  for (const forbidden of ["AIResolvedHomeAccessURL", "AIValidatedCustomSourcePath", "attributesOfItemAtPath",
    "startAccessingSecurityScopedResource", "stringByResolvingSymlinksInPath"]) {
    if (!customSourceList || customSourceList[0].includes(forbidden))
      throw new Error("Listing saved custom sources must not access the filesystem: " + forbidden)
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
  'AIExampleModeDefaultsKey' \
  'AIOfflineExampleSnapshot' \
  '--offline-example-snapshot' \
  '--allow-local-agent-data' \
  '--export-mobile-snapshot'; do
  rg -F -q -- "$NATIVE_MARKER" "$PROJECT_DIR/Native/AgentIsland.m"
done
if rg -q 'dataTaskWithRequest:request[[:space:]]+completionHandler:' "$PROJECT_DIR/Native/AgentIsland.m"; then
  echo "Translator must use bounded NSURLSessionDataDelegate streaming, not a completion-handler buffer" >&2
  exit 1
fi

if "$BINARY" --snapshot >"$VERIFY_ROOT/unapproved-snapshot.json" 2>"$VERIFY_ROOT/unapproved-snapshot.err"; then
  echo "CLI snapshot must require explicit local-Agent-data authorization" >&2
  exit 1
fi
rg -q -- '--allow-local-agent-data' "$VERIFY_ROOT/unapproved-snapshot.err"
"$BINARY" --snapshot --allow-local-agent-data | jq -e '
  (.exampleMode == false) and
  (.exampleDataOnly == false) and
  (.dataOrigin == "localAgentLogs") and
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

EXAMPLE_SNAPSHOT_PATH="$VERIFY_ROOT/offline-example-snapshot.json"
"$BINARY" --offline-example-snapshot >"$EXAMPLE_SNAPSHOT_PATH"
jq -e '
  (.exampleMode == true) and
  (.exampleDataOnly == true) and
  (.dataOrigin == "bundledOfflineExample") and
  (.sessions | type == "array" and length == 4) and
  ([.sessions[] | select(.status == "working")] | length == 3) and
  ([.sessions[] | select(.status == "working" and (.isSubagent | not))] | length == 2) and
  (all(.sessions[];
    (.id | startswith("example:")) and
    (.source == "Bundled offline example") and
    (.project == "") and (.model == "") and
    (.total == (.input + .output + .unknown)) and
    (.tokenCoverage == "bundledExample") and
    (.activityBasis == "bundledExample")
  )) and
  (.tools | type == "array" and length == 2) and
  (.usageHistory.totals.total == ([.sessions[].total] | add)) and
  (.privacy.localOnly == true) and
  (.privacy.networkRequests == false) and
  (.privacy.automaticNetworkRequests == false) and
  (has("cloudSync") | not) and
  (has("workspace") | not) and
  (has("translator") | not) and
  ([.. | strings | select(startswith("/Users/") or startswith("/home/") or
    test("(^|[^A-Za-z])(sk-[A-Za-z0-9]|bearer[ ]|api[_ -]?key|authorization:|token=)"; "i"))] | length == 0)
' "$EXAMPLE_SNAPSHOT_PATH" >/dev/null

MOBILE_SNAPSHOT_PATH="$VERIFY_ROOT/mobile-snapshot.json"
if "$BINARY" --export-mobile-snapshot >"$VERIFY_ROOT/unapproved-mobile-snapshot.json" 2>"$VERIFY_ROOT/unapproved-mobile-snapshot.err"; then
  echo "CLI mobile export must require explicit local-Agent-data authorization or a fixture" >&2
  exit 1
fi
rg -q -- '--allow-local-agent-data' "$VERIFY_ROOT/unapproved-mobile-snapshot.err"
"$BINARY" --export-mobile-snapshot --allow-local-agent-data >"$MOBILE_SNAPSHOT_PATH"
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
