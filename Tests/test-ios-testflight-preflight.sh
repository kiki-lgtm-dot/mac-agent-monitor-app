#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SCRIPT="$PROJECT_ROOT/ApplePlatforms/iOS/scripts/submit-testflight.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-ios-preflight-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "iOS TestFlight preflight test failed: $*"
  exit 1
}

contains() {
  local marker="$1"
  local path="$2"
  /usr/bin/grep -Fq -- "$marker" "$path" \
    || fail "missing '$marker' in ${path#$PROJECT_ROOT/}"
}

expect_rejected() {
  local marker="$1"
  local output="$TEST_ROOT/rejected.txt"
  if "$INSTRUMENTED_SCRIPT" --check "$RELEASE_DIRECTORY" >"$output" 2>&1; then
    fail "preflight accepted fixture expected to fail with: $marker"
  fi
  contains "$marker" "$output"
}

[[ -x "$SCRIPT" ]] || fail "submit-testflight.sh is missing or not executable"
/bin/zsh -n "$SCRIPT"

for marker in \
  '.displayName | type == "string" and length > 0' \
  '.widgetDisplayName | type == "string" and length > 0' \
  '.privacyPolicyURL | type == "string" and startswith("https://")' \
  '.supportURL | type == "string" and startswith("https://")' \
  'resolved_url_setting' \
  'release metadata display name does not match current Project.xcconfig' \
  'release metadata privacy policy URL does not match current Project.xcconfig' \
  'IPA App display name does not match release metadata' \
  'IPA Widget display name does not match release metadata' \
  'IPA App privacy policy URL does not match release metadata' \
  'IPA App support URL does not match release metadata' \
  'embedded.mobileprovision' \
  '/usr/bin/security cms -D -i' \
  'validate_app_store_profile_shape' \
  'ProvisionedDevices' \
  'ProvisionsAllDevices' \
  'ExpirationDate' \
  'profile_authorizes_certificate_sha1' \
  'DeveloperCertificates' \
  'ApplicationIdentifierPrefix.0' \
  'TeamIdentifier.0' \
  'IPA App signature/profile failed exact production CloudKit entitlement validation' \
  'IPA Widget signature/profile identifiers are wrong or an iCloud entitlement leaked'; do
  contains "$marker" "$SCRIPT"
done

STUB_DIRECTORY="$TEST_ROOT/stubs"
INSTRUMENTED_ROOT="$TEST_ROOT/ApplePlatforms/iOS"
INSTRUMENTED_SCRIPT="$INSTRUMENTED_ROOT/scripts/submit-testflight.sh"
/bin/mkdir -p "$STUB_DIRECTORY" "$INSTRUMENTED_ROOT/scripts" \
  "$INSTRUMENTED_ROOT/Config"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/scripts/privacy-manifest-contract.jq" \
  "$INSTRUMENTED_ROOT/scripts/privacy-manifest-contract.jq"

/bin/cat >"$STUB_DIRECTORY/codesign" <<'EOF'
#!/bin/zsh
set -euo pipefail

bundle_path="${argv[-1]}"
if [[ " $* " == *" --extract-certificates "* ]]; then
  /bin/cp "$AGENT_ISLAND_TEST_LEAF_CERTIFICATE" codesign0
elif [[ " $* " == *" --entitlements - "* ]]; then
  if [[ "$bundle_path" == *.appex ]]; then
    /bin/cat "$AGENT_ISLAND_TEST_WIDGET_ENTITLEMENTS"
  else
    /bin/cat "$AGENT_ISLAND_TEST_APP_ENTITLEMENTS"
  fi
elif [[ " $* " == *" --verbose=4 "* ]]; then
  print -u2 -r -- "Authority=$AGENT_ISLAND_TEST_SIGNING_IDENTITY"
  print -u2 -r -- "TeamIdentifier=$AGENT_ISLAND_TEST_TEAM_ID"
fi
EOF

/bin/cat >"$STUB_DIRECTORY/security" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "cms" && "$2" == "-D" && "$3" == "-i" ]] || exit 64
/bin/cat "$4"
EOF

/bin/cat >"$STUB_DIRECTORY/lipo" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "-archs" && -f "$2" ]] || exit 64
print -r -- "arm64"
EOF
/bin/chmod 0755 "$STUB_DIRECTORY/codesign" "$STUB_DIRECTORY/security" \
  "$STUB_DIRECTORY/lipo"

/usr/bin/sed \
  -e "s#/usr/bin/codesign#$STUB_DIRECTORY/codesign#g" \
  -e "s#/usr/bin/security#$STUB_DIRECTORY/security#g" \
  -e "s#/usr/bin/lipo#$STUB_DIRECTORY/lipo#g" \
  "$SCRIPT" >"$INSTRUMENTED_SCRIPT"
/bin/chmod 0755 "$INSTRUMENTED_SCRIPT"

TEAM_ID="ABCDE12345"
APP_BUNDLE_ID="com.agentisland.release"
WIDGET_BUNDLE_ID="$APP_BUNDLE_ID.liveactivity"
APP_IDENTIFIER="$TEAM_ID.$APP_BUNDLE_ID"
WIDGET_IDENTIFIER="$TEAM_ID.$WIDGET_BUNDLE_ID"
CLOUD_CONTAINER_ID="iCloud.com.agentisland.release"
DISPLAY_NAME="Agent Island Release"
WIDGET_DISPLAY_NAME="Agent Island Live"
PRIVACY_POLICY_URL="https://agentisland.test/privacy"
SUPPORT_URL="https://agentisland.test/support"
PROFILE_EXPIRATION="2099-01-01T00:00:00Z"
SIGNING_IDENTITY="Apple Distribution: Release Fixture ($TEAM_ID)"

/bin/cat >"$INSTRUMENTED_ROOT/Config/Project.xcconfig" <<EOF
AGENT_ISLAND_DISPLAY_NAME = $DISPLAY_NAME
AGENT_ISLAND_WIDGET_DISPLAY_NAME = $WIDGET_DISPLAY_NAME
AGENT_ISLAND_URL_SLASH = /
AGENT_ISLAND_PRIVACY_POLICY_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)agentisland.test/privacy
AGENT_ISLAND_SUPPORT_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)agentisland.test/support
EOF

RELEASE_DIRECTORY="$TEST_ROOT/release"
ARCHIVE_PATH="$RELEASE_DIRECTORY/fixture.xcarchive"
IPA_PATH="$RELEASE_DIRECTORY/AgentIsland.ipa"
PACKAGE_ROOT="$TEST_ROOT/package"
APP_PATH="$PACKAGE_ROOT/Payload/AgentIsland.app"
WIDGET_PATH="$APP_PATH/PlugIns/AgentIslandLiveActivityExtension.appex"
APP_PROFILE="$APP_PATH/embedded.mobileprovision"
WIDGET_PROFILE="$WIDGET_PATH/embedded.mobileprovision"
APP_ENTITLEMENTS="$TEST_ROOT/app-entitlements.json"
WIDGET_ENTITLEMENTS="$TEST_ROOT/widget-entitlements.json"
LEAF_CERTIFICATE="$TEST_ROOT/leaf-certificate.der"
METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"

/bin/mkdir -p "$ARCHIVE_PATH" "$WIDGET_PATH"
print -n -r -- 'synthetic Apple Distribution leaf' >"$LEAF_CERTIFICATE"
LEAF_CERTIFICATE_BASE64="$(/usr/bin/base64 <"$LEAF_CERTIFICATE" | /usr/bin/tr -d '\n')"
OTHER_CERTIFICATE_BASE64="$(print -n -r -- 'unauthorized leaf' | /usr/bin/base64 | /usr/bin/tr -d '\n')"
SIGNING_CERTIFICATE_SHA1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$LEAF_CERTIFICATE" \
  | /usr/bin/awk '{print toupper($1)}')"

/usr/bin/jq -n \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER_ID" '{
    "application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "get-task-allow": false,
    "com.apple.developer.icloud-container-identifiers": [$container],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production"
  }' >"$APP_ENTITLEMENTS"
/usr/bin/jq -n \
  --arg identifier "$WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '{
    "application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "get-task-allow": false
  }' >"$WIDGET_ENTITLEMENTS"

write_profiles() {
  /usr/bin/jq -n \
    --arg prefix "$TEAM_ID" \
    --arg team "$TEAM_ID" \
    --arg expiration "$PROFILE_EXPIRATION" \
    --arg certificate "$LEAF_CERTIFICATE_BASE64" \
    --slurpfile entitlements "$APP_ENTITLEMENTS" '{
      ApplicationIdentifierPrefix: [$prefix],
      TeamIdentifier: [$team],
      ExpirationDate: $expiration,
      DeveloperCertificates: [$certificate],
      Entitlements: $entitlements[0]
    }' >"$APP_PROFILE"
  /usr/bin/jq -n \
    --arg prefix "$TEAM_ID" \
    --arg team "$TEAM_ID" \
    --arg expiration "$PROFILE_EXPIRATION" \
    --arg certificate "$LEAF_CERTIFICATE_BASE64" \
    --slurpfile entitlements "$WIDGET_ENTITLEMENTS" '{
      ApplicationIdentifierPrefix: [$prefix],
      TeamIdentifier: [$team],
      ExpirationDate: $expiration,
      DeveloperCertificates: [$certificate],
      Entitlements: $entitlements[0]
    }' >"$WIDGET_PROFILE"
}

/usr/bin/jq -n \
  --arg bundle "$APP_BUNDLE_ID" \
  --arg display "$DISPLAY_NAME" \
  --arg privacy "$PRIVACY_POLICY_URL" \
  --arg support "$SUPPORT_URL" \
  --arg container "$CLOUD_CONTAINER_ID" '{
    CFBundleIdentifier: $bundle,
    CFBundleDisplayName: $display,
    CFBundleShortVersionString: "1.2.3",
    CFBundleVersion: "42",
    CFBundleExecutable: "AgentIsland",
    AgentIslandPrivacyPolicyURL: $privacy,
    AgentIslandSupportURL: $support,
    AgentIslandCloudKitContainerIdentifier: $container,
    AgentIslandCloudKitRecordType: "AgentIslandSnapshot",
    AgentIslandCloudKitRecordName: "latest",
    AgentIslandCloudKitPayloadField: "payloadJSON",
    ITSAppUsesNonExemptEncryption: false
  }' >"$APP_PATH/Info.plist"
/usr/bin/jq -n \
  --arg bundle "$WIDGET_BUNDLE_ID" \
  --arg display "$WIDGET_DISPLAY_NAME" '{
    CFBundleIdentifier: $bundle,
    CFBundleDisplayName: $display,
    CFBundleShortVersionString: "1.2.3",
    CFBundleVersion: "42",
    CFBundleExecutable: "AgentIslandLiveActivityExtension"
  }' >"$WIDGET_PATH/Info.plist"
print -n -r -- 'synthetic app executable' >"$APP_PATH/AgentIsland"
print -n -r -- 'synthetic widget executable' \
  >"$WIDGET_PATH/AgentIslandLiveActivityExtension"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy" \
  "$APP_PATH/PrivacyInfo.xcprivacy"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy" \
  "$WIDGET_PATH/PrivacyInfo.xcprivacy"
write_profiles

APP_PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$APP_PATH/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
WIDGET_PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$WIDGET_PATH/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"

/usr/bin/jq -n \
  --arg archive "$ARCHIVE_PATH" \
  --arg ipa "$IPA_PATH" \
  --arg team "$TEAM_ID" \
  --arg appBundle "$APP_BUNDLE_ID" \
  --arg widgetBundle "$WIDGET_BUNDLE_ID" \
  --arg display "$DISPLAY_NAME" \
  --arg widgetDisplay "$WIDGET_DISPLAY_NAME" \
  --arg appIdentifier "$APP_IDENTIFIER" \
  --arg widgetIdentifier "$WIDGET_IDENTIFIER" \
  --arg container "$CLOUD_CONTAINER_ID" \
  --arg privacyURL "$PRIVACY_POLICY_URL" \
  --arg supportURL "$SUPPORT_URL" \
  --arg appPrivacySHA "$APP_PRIVACY_SHA256" \
  --arg widgetPrivacySHA "$WIDGET_PRIVACY_SHA256" \
  --arg identity "$SIGNING_IDENTITY" \
  --arg certificateSHA1 "$SIGNING_CERTIFICATE_SHA1" \
  --arg expiration "$PROFILE_EXPIRATION" '{
    schemaVersion: 1,
    product: "Agent Island iOS fixture",
    version: "1.2.3",
    build: "42",
    archivePath: $archive,
    exportedIPA: $ipa,
    ipaSHA256: ("0" * 64),
    teamID: $team,
    appBundleID: $appBundle,
    widgetBundleID: $widgetBundle,
    displayName: $display,
    widgetDisplayName: $widgetDisplay,
    appIdentifier: $appIdentifier,
    widgetIdentifier: $widgetIdentifier,
    cloudContainerID: $container,
    privacyPolicyURL: $privacyURL,
    supportURL: $supportURL,
    privacyManifestSHA256: {app: $appPrivacySHA, widget: $widgetPrivacySHA},
    cloudKitRecordContract: {
      recordType: "AgentIslandSnapshot",
      recordName: "latest",
      payloadField: "payloadJSON"
    },
    cloudKitEnvironment: "Production",
    signingIdentity: $identity,
    signingCertificateSHA1: $certificateSHA1,
    exportedProvisioningProfileExpiration: {app: $expiration, widget: $expiration},
    allowProvisioningUpdates: false,
    uploaded: false
  }' >"$METADATA_PATH"

refresh_artifact() {
  local sha metadata_temp="$TEST_ROOT/metadata.tmp.json"
  /bin/rm -f "$IPA_PATH" "$IPA_PATH.sha256"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT/Payload" "$IPA_PATH"
  sha="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IPA_PATH" \
    | /usr/bin/awk '{print $1}')"
  /usr/bin/jq --arg sha "$sha" '.ipaSHA256 = $sha' "$METADATA_PATH" >"$metadata_temp"
  /bin/mv "$metadata_temp" "$METADATA_PATH"
  print -r -- "$sha  ${IPA_PATH:t}" >"$IPA_PATH.sha256"
}

export AGENT_ISLAND_TEST_LEAF_CERTIFICATE="$LEAF_CERTIFICATE"
export AGENT_ISLAND_TEST_APP_ENTITLEMENTS="$APP_ENTITLEMENTS"
export AGENT_ISLAND_TEST_WIDGET_ENTITLEMENTS="$WIDGET_ENTITLEMENTS"
export AGENT_ISLAND_TEST_SIGNING_IDENTITY="$SIGNING_IDENTITY"
export AGENT_ISLAND_TEST_TEAM_ID="$TEAM_ID"

refresh_artifact
VALID_METADATA="$TEST_ROOT/valid-metadata.json"
/bin/cp "$METADATA_PATH" "$VALID_METADATA"
VALID_OUTPUT="$TEST_ROOT/valid.txt"
"$INSTRUMENTED_SCRIPT" --check "$RELEASE_DIRECTORY" >"$VALID_OUTPUT" 2>&1 \
  || fail "valid synthetic IPA did not pass: $(/bin/cat "$VALID_OUTPUT")"
contains 'Local TestFlight preflight passed.' "$VALID_OUTPUT"

/usr/bin/sed 's/^AGENT_ISLAND_DISPLAY_NAME = .*/AGENT_ISLAND_DISPLAY_NAME = Changed current name/' \
  "$INSTRUMENTED_ROOT/Config/Project.xcconfig" >"$TEST_ROOT/config.tmp"
/bin/mv "$TEST_ROOT/config.tmp" "$INSTRUMENTED_ROOT/Config/Project.xcconfig"
expect_rejected 'release metadata display name does not match current Project.xcconfig'
/usr/bin/sed 's/^AGENT_ISLAND_DISPLAY_NAME = .*/AGENT_ISLAND_DISPLAY_NAME = Agent Island Release/' \
  "$INSTRUMENTED_ROOT/Config/Project.xcconfig" >"$TEST_ROOT/config.tmp"
/bin/mv "$TEST_ROOT/config.tmp" "$INSTRUMENTED_ROOT/Config/Project.xcconfig"

/usr/bin/sed 's#^AGENT_ISLAND_PRIVACY_POLICY_URL = .*#AGENT_ISLAND_PRIVACY_POLICY_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)changed.test/privacy#' \
  "$INSTRUMENTED_ROOT/Config/Project.xcconfig" >"$TEST_ROOT/config.tmp"
/bin/mv "$TEST_ROOT/config.tmp" "$INSTRUMENTED_ROOT/Config/Project.xcconfig"
expect_rejected 'release metadata privacy policy URL does not match current Project.xcconfig'
/usr/bin/sed 's#^AGENT_ISLAND_PRIVACY_POLICY_URL = .*#AGENT_ISLAND_PRIVACY_POLICY_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)agentisland.test/privacy#' \
  "$INSTRUMENTED_ROOT/Config/Project.xcconfig" >"$TEST_ROOT/config.tmp"
/bin/mv "$TEST_ROOT/config.tmp" "$INSTRUMENTED_ROOT/Config/Project.xcconfig"

for required_field in displayName widgetDisplayName privacyPolicyURL supportURL; do
  /usr/bin/jq --arg field "$required_field" 'del(.[$field])' \
    "$VALID_METADATA" >"$METADATA_PATH"
  expect_rejected 'release metadata is incomplete, unverified, or from an unsupported schema'
done
/bin/cp "$VALID_METADATA" "$METADATA_PATH"

/usr/bin/plutil -replace CFBundleDisplayName -string 'Tampered App Name' "$APP_PATH/Info.plist"
refresh_artifact
expect_rejected 'IPA App display name does not match release metadata'
/usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_PATH/Info.plist"

/usr/bin/plutil -replace CFBundleDisplayName -string 'Tampered Widget Name' "$WIDGET_PATH/Info.plist"
refresh_artifact
expect_rejected 'IPA Widget display name does not match release metadata'
/usr/bin/plutil -replace CFBundleDisplayName -string "$WIDGET_DISPLAY_NAME" "$WIDGET_PATH/Info.plist"

/usr/bin/plutil -replace AgentIslandPrivacyPolicyURL -string \
  'https://attacker.invalid/privacy' "$APP_PATH/Info.plist"
refresh_artifact
expect_rejected 'IPA App privacy policy URL does not match release metadata'
/usr/bin/plutil -replace AgentIslandPrivacyPolicyURL -string "$PRIVACY_POLICY_URL" \
  "$APP_PATH/Info.plist"

/usr/bin/plutil -replace AgentIslandSupportURL -string \
  'https://attacker.invalid/support' "$APP_PATH/Info.plist"
refresh_artifact
expect_rejected 'IPA App support URL does not match release metadata'
/usr/bin/plutil -replace AgentIslandSupportURL -string "$SUPPORT_URL" "$APP_PATH/Info.plist"

/usr/bin/jq '.ExpirationDate = "2020-01-01T00:00:00Z"' "$APP_PROFILE" \
  >"$TEST_ROOT/profile.tmp"
/bin/mv "$TEST_ROOT/profile.tmp" "$APP_PROFILE"
refresh_artifact
expect_rejected 'IPA App provisioning profile expired at 2020-01-01T00:00:00Z'
write_profiles

/usr/bin/jq '.ProvisionedDevices = ["fixture-device"]' "$APP_PROFILE" \
  >"$TEST_ROOT/profile.tmp"
/bin/mv "$TEST_ROOT/profile.tmp" "$APP_PROFILE"
refresh_artifact
expect_rejected 'IPA App provisioning profile is device-scoped, not an App Store profile'
write_profiles

/usr/bin/jq --arg certificate "$OTHER_CERTIFICATE_BASE64" \
  '.DeveloperCertificates = [$certificate]' "$APP_PROFILE" >"$TEST_ROOT/profile.tmp"
/bin/mv "$TEST_ROOT/profile.tmp" "$APP_PROFILE"
refresh_artifact
expect_rejected 'IPA App provisioning profile does not authorize the actual signing certificate'
write_profiles

/usr/bin/jq '.Entitlements["application-identifier"] = "ABCDE12345.com.wrong.app"' \
  "$APP_PROFILE" >"$TEST_ROOT/profile.tmp"
/bin/mv "$TEST_ROOT/profile.tmp" "$APP_PROFILE"
refresh_artifact
expect_rejected 'IPA App signature/profile failed exact production CloudKit entitlement validation'

print -r -- 'iOS TestFlight exact-IPA identity and provisioning-profile tests passed'
