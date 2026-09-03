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
  'ios-entitlements-contract.jq' \
  'validate_entitlement_contract signed-app' \
  'validate_entitlement_contract profile-app' \
  'validate_entitlement_contract signed-widget' \
  'validate_entitlement_contract profile-widget' \
  'IPA App signature/profile failed exact production CloudKit entitlement validation' \
  'IPA Widget signature/profile identifiers are wrong or an iCloud entitlement leaked' \
  '"$PREFLIGHT_ASSERTION" ios-upload "$UPLOAD_PREFLIGHT_REPORT"' \
  'iosUploadCandidateLocalPreflightPassed: true'; do
  contains "$marker" "$SCRIPT"
done
for delivery_marker in \
  'verify_altool_success_json' \
  '/usr/bin/jq -s -e' \
  '["success-message"]' \
  'verify_core_candidate_unchanged' \
  'verify_staged_candidate_unchanged' \
  '.testflight-submit.lock' \
  'publish_readonly_no_overwrite' \
  '/bin/chmod 0444 "$VALIDATION_RESULT_TEMP"' \
  'release artifact paths must already be canonical'; do
  contains "$delivery_marker" "$SCRIPT"
done
[[ "$(/usr/bin/grep -Ec \
    '^[[:space:]]*assert_upload_identity_lock_unchanged$' "$SCRIPT")" == "3" ]] \
  || fail "TestFlight upload must check its identity lock initially and before validation/upload"

STUB_DIRECTORY="$TEST_ROOT/stubs"
INSTRUMENTED_ROOT="$TEST_ROOT/ApplePlatforms/iOS"
INSTRUMENTED_SCRIPT="$INSTRUMENTED_ROOT/scripts/submit-testflight.sh"
/bin/mkdir -p "$STUB_DIRECTORY" "$INSTRUMENTED_ROOT/scripts" \
  "$INSTRUMENTED_ROOT/Config" "$TEST_ROOT/scripts"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/scripts/privacy-manifest-contract.jq" \
  "$INSTRUMENTED_ROOT/scripts/privacy-manifest-contract.jq"
/bin/cp "$PROJECT_ROOT/ApplePlatforms/iOS/scripts/ios-entitlements-contract.jq" \
  "$INSTRUMENTED_ROOT/scripts/ios-entitlements-contract.jq"
/bin/cp "$PROJECT_ROOT/scripts/assert-release-preflight.sh" \
  "$TEST_ROOT/scripts/assert-release-preflight.sh"
/bin/chmod 0755 "$TEST_ROOT/scripts/assert-release-preflight.sh"
IDENTITY_LOCK_PATH="$TEST_ROOT/.release/identity.lock.json"
/bin/mkdir -p "$TEST_ROOT/.release"
/usr/bin/jq -n '{schemaVersion: 1, fixture: "TestFlight identity lock"}' \
  >"$IDENTITY_LOCK_PATH"
/bin/chmod 0600 "$IDENTITY_LOCK_PATH"
IDENTITY_LOCK_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$IDENTITY_LOCK_PATH" | /usr/bin/awk '{print $1}')"
export AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH="$IDENTITY_LOCK_PATH"
export AGENT_ISLAND_TEST_IDENTITY_LOCK_SHA256="$IDENTITY_LOCK_SHA256"

/bin/cat >"$TEST_ROOT/scripts/release-readiness.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" == 1 && "$1" == "--json" ]] || exit 64
ready="${AGENT_ISLAND_TEST_RELEASE_IDENTITY_READY:-true}"
/usr/bin/jq -n --argjson ready "$ready" \
  --arg lockPath "$AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH" \
  --arg lockSHA256 "$AGENT_ISLAND_TEST_IDENTITY_LOCK_SHA256" '{
  releaseIdentityLockConfigured: true,
  releaseIdentityLockValid: true,
  releaseIdentityAppliedFilesMatch: true,
  releaseIdentityMatchesConfiguration: true,
  releaseIdentityLockPath: $lockPath,
  releaseIdentityLockSHA256: $lockSHA256,
  releaseIdentityReady: $ready,
  readyForIOSArchive: $ready,
  iosAppBundleID: "com.agentisland.release",
  iosWidgetBundleID: "com.agentisland.release.liveactivity",
  iosDevelopmentTeam: "ABCDE12345",
  iosCloudKitContainer: "iCloud.com.agentisland.release",
  iosDisplayName: "Agent Island Release",
  iosMarketingVersion: "1.2.3",
  iosBuildNumber: "42"
}'
EOF
/bin/chmod 0755 "$TEST_ROOT/scripts/release-readiness.sh"

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

/bin/cat >"$STUB_DIRECTORY/xcodebuild" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "-version" ]] || exit 64
print -r -- "Xcode 26.1"
print -r -- "Build version 17A100"
EOF

/bin/cat >"$STUB_DIRECTORY/date" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$#" -eq 2 && "$1" == "-u" && "$2" == "+%Y%m%dT%H%M%SZ" ]]; then
  print -r -- "20990102T030405Z"
  exit 0
fi
exec /bin/date "$@"
EOF

/bin/cat >"$STUB_DIRECTORY/xcrun" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "altool" ]] || exit 64
operation=""
candidate_path=""
for (( index = 2; index <= $#; index++ )); do
  case "${argv[$index]}" in
    --validate-app) operation="validation" ;;
    --upload-app) operation="upload" ;;
    --file)
      (( index < $# )) || exit 65
      candidate_path="${argv[$(( index + 1 ))]}"
      ;;
  esac
done
[[ -n "$operation" && -f "$candidate_path" && ! -L "$candidate_path" ]] || exit 66
[[ "$candidate_path" != "$AGENT_ISLAND_TEST_ORIGINAL_IPA" ]] || exit 67
[[ "$(/usr/bin/stat -f '%Lp' "${candidate_path:h}")" == "700" ]] || exit 68
[[ "$(/usr/bin/stat -f '%Lp' "$candidate_path")" == "400" ]] || exit 69
actual_sha256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$candidate_path" \
  | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$AGENT_ISLAND_TEST_EXPECTED_IPA_SHA256" ]] || exit 70
print -r -- "$operation:$candidate_path" >>"$AGENT_ISLAND_TEST_XCRUN_LOG"
if [[ "$operation" == "${AGENT_ISLAND_TEST_RACE_OPERATION:-validation}" \
    && -n "${AGENT_ISLAND_TEST_RACE_DESTINATION:-}" ]]; then
  if [[ "${AGENT_ISLAND_TEST_RACE_KIND:-}" == "symlink" ]]; then
    /bin/ln -s "$AGENT_ISLAND_TEST_RACE_TARGET" \
      "$AGENT_ISLAND_TEST_RACE_DESTINATION"
  elif [[ "${AGENT_ISLAND_TEST_RACE_KIND:-}" == "directory" ]]; then
    /bin/mkdir "$AGENT_ISLAND_TEST_RACE_DESTINATION"
  else
    print -n -r -- 'racing writer sentinel' \
      >"$AGENT_ISLAND_TEST_RACE_DESTINATION"
  fi
fi
if [[ "$operation" == "validation" ]]; then
  /bin/cat "$AGENT_ISLAND_TEST_VALIDATION_RESPONSE"
  if [[ "${AGENT_ISLAND_TEST_MUTATE_IDENTITY_LOCK_AFTER_VALIDATE:-}" == true ]]; then
    print -n -r -- 'tampered after validation' \
      >>"$AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH"
  fi
else
  /bin/cat "$AGENT_ISLAND_TEST_UPLOAD_RESPONSE"
fi
EOF
/bin/chmod 0755 "$STUB_DIRECTORY/codesign" "$STUB_DIRECTORY/security" \
  "$STUB_DIRECTORY/lipo" "$STUB_DIRECTORY/xcodebuild" \
  "$STUB_DIRECTORY/date" "$STUB_DIRECTORY/xcrun"

/usr/bin/sed \
  -e "s#/usr/bin/codesign#$STUB_DIRECTORY/codesign#g" \
  -e "s#/usr/bin/security#$STUB_DIRECTORY/security#g" \
  -e "s#/usr/bin/lipo#$STUB_DIRECTORY/lipo#g" \
  -e "s#/usr/bin/xcodebuild#$STUB_DIRECTORY/xcodebuild#g" \
  -e "s#/usr/bin/xcrun#$STUB_DIRECTORY/xcrun#g" \
  -e "s#/bin/date#$STUB_DIRECTORY/date#g" \
  -e 's#\${HOME}/.appstoreconnect/private_keys#'"$TEST_ROOT/private_keys"'#g' \
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
APP_PROFILE_ENTITLEMENTS="$TEST_ROOT/app-profile-entitlements.json"
WIDGET_PROFILE_ENTITLEMENTS="$TEST_ROOT/widget-profile-entitlements.json"
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
/usr/bin/jq -n \
  --arg identifier "$APP_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER_ID" '{
    "application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "get-task-allow": false,
    "beta-reports-active": true,
    "keychain-access-groups": [($team + ".*"), "com.apple.token"],
    "com.apple.developer.icloud-container-identifiers": [
      $container,
      "iCloud.com.agentisland.profile-only"
    ],
    "com.apple.developer.icloud-services": "*",
    "com.apple.developer.icloud-container-environment": ["Development", "Production"]
  }' >"$APP_PROFILE_ENTITLEMENTS"
/usr/bin/jq -n \
  --arg identifier "$WIDGET_IDENTIFIER" \
  --arg team "$TEAM_ID" '{
    "application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "get-task-allow": false,
    "beta-reports-active": true,
    "keychain-access-groups": [($team + ".*"), "com.apple.token"]
  }' >"$WIDGET_PROFILE_ENTITLEMENTS"

write_profiles() {
  /usr/bin/jq -n \
    --arg prefix "$TEAM_ID" \
    --arg team "$TEAM_ID" \
    --arg expiration "$PROFILE_EXPIRATION" \
    --arg certificate "$LEAF_CERTIFICATE_BASE64" \
    --slurpfile entitlements "$APP_PROFILE_ENTITLEMENTS" '{
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
    --slurpfile entitlements "$WIDGET_PROFILE_ENTITLEMENTS" '{
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
  --arg releaseIdentityLockSHA256 "$IDENTITY_LOCK_SHA256" \
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
    releaseIdentityLockSHA256: $releaseIdentityLockSHA256,
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

VALID_APP_ENTITLEMENTS="$TEST_ROOT/valid-app-entitlements.json"
VALID_WIDGET_ENTITLEMENTS="$TEST_ROOT/valid-widget-entitlements.json"
/bin/cp "$APP_ENTITLEMENTS" "$VALID_APP_ENTITLEMENTS"
/bin/cp "$WIDGET_ENTITLEMENTS" "$VALID_WIDGET_ENTITLEMENTS"
/usr/bin/jq '. + {"aps-environment": "production"}' \
  "$VALID_APP_ENTITLEMENTS" >"$APP_ENTITLEMENTS"
refresh_artifact
expect_rejected 'signed entitlements exceed the release allowlist'
/bin/cp "$VALID_APP_ENTITLEMENTS" "$APP_ENTITLEMENTS"
/usr/bin/jq '. + {"com.apple.security.application-groups": ["group.example"]}' \
  "$VALID_WIDGET_ENTITLEMENTS" >"$WIDGET_ENTITLEMENTS"
refresh_artifact
expect_rejected 'signed entitlements exceed the Widget allowlist'
/bin/cp "$VALID_WIDGET_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"
refresh_artifact

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

write_profiles
refresh_artifact

API_KEY_ID="ZYXWV98765"
API_ISSUER_ID="12345678-1234-1234-1234-123456789abc"
PRIVATE_KEY_DIRECTORY="$TEST_ROOT/private_keys"
PRIVATE_KEY_PATH="$PRIVATE_KEY_DIRECTORY/AuthKey_${API_KEY_ID}.p8"
FAKE_DEVELOPER_PATH="$TEST_ROOT/Xcode26.app/Contents/Developer"
/bin/mkdir -p "$PRIVATE_KEY_DIRECTORY" "$FAKE_DEVELOPER_PATH/usr/bin"
print -n -r -- 'synthetic private key' >"$PRIVATE_KEY_PATH"
print -n -r -- 'synthetic altool executable' >"$FAKE_DEVELOPER_PATH/usr/bin/altool"
/bin/chmod 0600 "$PRIVATE_KEY_PATH"
/bin/chmod 0755 "$FAKE_DEVELOPER_PATH/usr/bin/altool"

VALIDATION_SUCCESS_RESPONSE="$TEST_ROOT/validation-success.json"
UPLOAD_SUCCESS_RESPONSE="$TEST_ROOT/upload-success.json"
MULTIPLE_TOP_LEVEL_RESPONSE="$TEST_ROOT/multiple-top-level.json"
FALSE_ERRORS_RESPONSE="$TEST_ROOT/false-errors.json"
FALSE_PRODUCT_ERRORS_RESPONSE="$TEST_ROOT/false-product-errors.json"
print -r -- '{"success-message":"validation accepted","product-errors":null}' \
  >"$VALIDATION_SUCCESS_RESPONSE"
print -r -- '{"success-message":"upload accepted","errors":[]}' \
  >"$UPLOAD_SUCCESS_RESPONSE"
print -r -- '{"product-errors":[{"message":"first object failed"}]}' \
  >"$MULTIPLE_TOP_LEVEL_RESPONSE"
print -r -- '{"success-message":"second object"}' >>"$MULTIPLE_TOP_LEVEL_RESPONSE"
print -r -- '{"success-message":"ambiguous","errors":false}' >"$FALSE_ERRORS_RESPONSE"
print -r -- '{"success-message":"ambiguous","product-errors":false}' \
  >"$FALSE_PRODUCT_ERRORS_RESPONSE"

FIXED_STAMP="20990102T030405Z"
VALIDATION_RESULT_PATH="$RELEASE_DIRECTORY/testflight-validation-$FIXED_STAMP.json"
UPLOAD_RESULT_PATH="$RELEASE_DIRECTORY/testflight-upload-$FIXED_STAMP.json"
DELIVERY_RECORD_PATH="$RELEASE_DIRECTORY/testflight-delivery-$FIXED_STAMP.json"
XCRUN_LOG="$TEST_ROOT/xcrun.log"
EXPECTED_IPA_SHA256="$(/usr/bin/jq -r '.ipaSHA256' "$METADATA_PATH")"
CONFIRMATION_VALUE="$APP_BUNDLE_ID:1.2.3:42:$EXPECTED_IPA_SHA256"
export AGENT_ISLAND_TEST_ORIGINAL_IPA="$IPA_PATH"
export AGENT_ISLAND_TEST_EXPECTED_IPA_SHA256="$EXPECTED_IPA_SHA256"
export AGENT_ISLAND_TEST_XCRUN_LOG="$XCRUN_LOG"
export AGENT_ISLAND_TEST_VALIDATION_RESPONSE="$VALIDATION_SUCCESS_RESPONSE"
export AGENT_ISLAND_TEST_UPLOAD_RESPONSE="$UPLOAD_SUCCESS_RESPONSE"

clear_remote_outputs() {
  /bin/rm -f "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH" "$DELIVERY_RECORD_PATH"
}

assert_no_transient_delivery_state() {
  local transient_count
  transient_count="$(/usr/bin/find "$RELEASE_DIRECTORY" -maxdepth 1 \
    -name '.testflight-*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "$transient_count" == "0" ]] \
    || fail "remote submission left a temporary file or collaboration lock"
}

run_remote() {
  local mode="$1"
  DEVELOPER_DIR="$FAKE_DEVELOPER_PATH" \
  AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
  AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
  AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD="$CONFIRMATION_VALUE" \
    "$INSTRUMENTED_SCRIPT" "$mode" "$RELEASE_DIRECTORY"
}

expect_remote_rejected() {
  local marker="$1"
  local mode="$2"
  local output="$TEST_ROOT/remote-rejected.txt"
  if run_remote "$mode" >"$output" 2>&1; then
    fail "remote mode accepted fixture expected to fail with: $marker"
  fi
  contains "$marker" "$output"
  assert_no_transient_delivery_state
}

clear_remote_outputs
: >"$XCRUN_LOG"
export AGENT_ISLAND_TEST_RELEASE_IDENTITY_READY=false
expect_remote_rejected \
  'ios-upload prerequisites are not satisfied' --upload
[[ ! -s "$XCRUN_LOG" ]] \
  || fail "identity-lock rejection contacted App Store Connect"
unset AGENT_ISLAND_TEST_RELEASE_IDENTITY_READY

IDENTITY_LOCK_BASELINE="$TEST_ROOT/identity-lock-baseline.json"
/bin/cp "$IDENTITY_LOCK_PATH" "$IDENTITY_LOCK_BASELINE"
print -r -- 'changed after the readiness snapshot' >>"$IDENTITY_LOCK_PATH"
expect_remote_rejected \
  'release identity lock changed after the readiness report was generated' --upload
[[ ! -s "$XCRUN_LOG" ]] \
  || fail "changed identity lock contacted App Store Connect"
/bin/mv "$IDENTITY_LOCK_BASELINE" "$IDENTITY_LOCK_PATH"
/bin/chmod 0600 "$IDENTITY_LOCK_PATH"

GATE_METADATA_BASELINE="$TEST_ROOT/gate-metadata-baseline.json"
/bin/cp "$METADATA_PATH" "$GATE_METADATA_BASELINE"
/usr/bin/jq '.releaseIdentityLockSHA256 = ("d" * 64)' \
  "$GATE_METADATA_BASELINE" >"$METADATA_PATH"
expect_remote_rejected \
  'ios-upload prerequisites are not satisfied' --upload
[[ ! -s "$XCRUN_LOG" ]] \
  || fail "candidate identity-lock mismatch contacted App Store Connect"
/bin/cp "$GATE_METADATA_BASELINE" "$METADATA_PATH"

export AGENT_ISLAND_TEST_VALIDATION_RESPONSE="$MULTIPLE_TOP_LEVEL_RESPONSE"
expect_remote_rejected \
  'does not contain an unambiguous altool success response' --validate
[[ ! -e "$VALIDATION_RESULT_PATH" ]] \
  || fail "multi-object validation response was published"

for false_response in "$FALSE_ERRORS_RESPONSE" "$FALSE_PRODUCT_ERRORS_RESPONSE"; do
  : >"$XCRUN_LOG"
  export AGENT_ISLAND_TEST_VALIDATION_RESPONSE="$false_response"
  expect_remote_rejected \
    'does not contain an unambiguous altool success response' --validate
  [[ ! -e "$VALIDATION_RESULT_PATH" ]] \
    || fail "boolean error field validation response was published"
done

export AGENT_ISLAND_TEST_VALIDATION_RESPONSE="$VALIDATION_SUCCESS_RESPONSE"
: >"$XCRUN_LOG"
run_remote --validate >"$TEST_ROOT/remote-validation-valid.txt" 2>&1 \
  || fail "valid remote validation fixture failed: $(/bin/cat "$TEST_ROOT/remote-validation-valid.txt")"
[[ -f "$VALIDATION_RESULT_PATH" && ! -L "$VALIDATION_RESULT_PATH" ]] \
  || fail "valid remote validation did not publish its result"
[[ "$(/usr/bin/stat -f '%Lp' "$VALIDATION_RESULT_PATH")" == "444" ]] \
  || fail "published validation result is not mode 0444"
[[ "$(/usr/bin/wc -l <"$XCRUN_LOG" | /usr/bin/tr -d ' ')" == "1" ]] \
  || fail "remote validation did not make exactly one staged-candidate request"
assert_no_transient_delivery_state
clear_remote_outputs

print -n -r -- 'do not overwrite this result' >"$VALIDATION_RESULT_PATH"
: >"$XCRUN_LOG"
expect_remote_rejected \
  'refusing to overwrite an existing App Store Connect validation result' --validate
[[ "$(/bin/cat "$VALIDATION_RESULT_PATH")" == 'do not overwrite this result' ]] \
  || fail "existing validation result was overwritten"
[[ ! -s "$XCRUN_LOG" ]] || fail "overwrite rejection contacted the remote service"
clear_remote_outputs

RACE_SYMLINK_TARGET="$TEST_ROOT/race-symlink-target"
/bin/mkdir "$RACE_SYMLINK_TARGET"
export AGENT_ISLAND_TEST_RACE_DESTINATION="$VALIDATION_RESULT_PATH"
export AGENT_ISLAND_TEST_RACE_KIND="symlink"
export AGENT_ISLAND_TEST_RACE_TARGET="$RACE_SYMLINK_TARGET"
: >"$XCRUN_LOG"
expect_remote_rejected \
  'could not publish App Store Connect validation result without overwriting a file' \
  --validate
[[ -L "$VALIDATION_RESULT_PATH" && \
    "$(/usr/bin/find "$RACE_SYMLINK_TARGET" -mindepth 1 -maxdepth 1 \
      -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "0" ]] \
  || fail "atomic publication followed a directory symlink created after its precheck"
unset AGENT_ISLAND_TEST_RACE_DESTINATION AGENT_ISLAND_TEST_RACE_KIND \
  AGENT_ISLAND_TEST_RACE_TARGET
clear_remote_outputs

SYMLINK_TARGET="$TEST_ROOT/delivery-symlink-target"
print -n -r -- 'symlink target sentinel' >"$SYMLINK_TARGET"
/bin/ln -s "$SYMLINK_TARGET" "$DELIVERY_RECORD_PATH"
: >"$XCRUN_LOG"
expect_remote_rejected \
  'refusing to overwrite an existing TestFlight delivery record' --upload
[[ -L "$DELIVERY_RECORD_PATH" && \
    "$(/bin/cat "$SYMLINK_TARGET")" == 'symlink target sentinel' ]] \
  || fail "delivery symlink or its target was overwritten"
[[ ! -s "$XCRUN_LOG" ]] || fail "symlink rejection contacted the remote service"
clear_remote_outputs

/bin/mkdir "$RELEASE_DIRECTORY/.testflight-submit.lock"
: >"$XCRUN_LOG"
if run_remote --validate >"$TEST_ROOT/lock-rejected.txt" 2>&1; then
  fail "remote validation ignored an existing release-directory collaboration lock"
fi
contains 'another TestFlight validation or upload is already active' \
  "$TEST_ROOT/lock-rejected.txt"
[[ -d "$RELEASE_DIRECTORY/.testflight-submit.lock" ]] \
  || fail "submission removed a collaboration lock it did not own"
[[ ! -s "$XCRUN_LOG" ]] || fail "locked submission contacted the remote service"
/bin/rmdir "$RELEASE_DIRECTORY/.testflight-submit.lock"

TOCTOU_IDENTITY_BASELINE="$TEST_ROOT/toctou-identity-baseline.json"
/bin/cp "$IDENTITY_LOCK_PATH" "$TOCTOU_IDENTITY_BASELINE"
: >"$XCRUN_LOG"
export AGENT_ISLAND_TEST_MUTATE_IDENTITY_LOCK_AFTER_VALIDATE=true
expect_remote_rejected \
  'release identity lock changed after the readiness report was generated' --upload
unset AGENT_ISLAND_TEST_MUTATE_IDENTITY_LOCK_AFTER_VALIDATE
contains 'validation:' "$XCRUN_LOG"
if /usr/bin/grep -Fq 'upload:' "$XCRUN_LOG"; then
  fail "identity-lock drift still reached the TestFlight upload operation"
fi
[[ -f "$VALIDATION_RESULT_PATH" && ! -L "$VALIDATION_RESULT_PATH" && \
    "$(/usr/bin/stat -f '%Lp' "$VALIDATION_RESULT_PATH")" == "444" ]] \
  || fail "identity-lock drift did not retain sealed validation evidence"
/bin/cp "$TOCTOU_IDENTITY_BASELINE" "$IDENTITY_LOCK_PATH"
/bin/chmod 0600 "$IDENTITY_LOCK_PATH"
[[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IDENTITY_LOCK_PATH" \
  | /usr/bin/awk '{print $1}')" == "$IDENTITY_LOCK_SHA256" ]] \
  || fail "identity-lock fixture could not be restored after the drift test"
clear_remote_outputs

export AGENT_ISLAND_TEST_UPLOAD_RESPONSE="$FALSE_PRODUCT_ERRORS_RESPONSE"
: >"$XCRUN_LOG"
expect_remote_rejected \
  'does not contain an unambiguous altool success response' --upload
[[ -f "$VALIDATION_RESULT_PATH" && \
    "$(/usr/bin/stat -f '%Lp' "$VALIDATION_RESULT_PATH")" == "444" ]] \
  || fail "successful validation result was not retained as read-only evidence"
[[ ! -e "$UPLOAD_RESULT_PATH" && ! -L "$UPLOAD_RESULT_PATH" \
    && ! -e "$DELIVERY_RECORD_PATH" && ! -L "$DELIVERY_RECORD_PATH" ]] \
  || fail "failed upload left a partial upload result or delivery record"
clear_remote_outputs

export AGENT_ISLAND_TEST_UPLOAD_RESPONSE="$UPLOAD_SUCCESS_RESPONSE"
export AGENT_ISLAND_TEST_RACE_OPERATION="upload"
export AGENT_ISLAND_TEST_RACE_DESTINATION="$DELIVERY_RECORD_PATH"
export AGENT_ISLAND_TEST_RACE_KIND="directory"
: >"$XCRUN_LOG"
expect_remote_rejected \
  'TestFlight delivery record destination did not resolve to the sealed temporary inode' \
  --upload
for retained_result in "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH"; do
  [[ -f "$retained_result" && ! -L "$retained_result" \
      && "$(/usr/bin/stat -f '%Lp' "$retained_result")" == "444" ]] \
    || fail "delivery publication race did not retain sealed remote results"
done
[[ -d "$DELIVERY_RECORD_PATH" && ! -L "$DELIVERY_RECORD_PATH" && \
    "$(/usr/bin/find "$DELIVERY_RECORD_PATH" -mindepth 1 -maxdepth 1 \
      -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "0" ]] \
  || fail "delivery publication accepted or leaked into a racing directory"
/bin/rmdir "$DELIVERY_RECORD_PATH"
unset AGENT_ISLAND_TEST_RACE_OPERATION AGENT_ISLAND_TEST_RACE_DESTINATION \
  AGENT_ISLAND_TEST_RACE_KIND
clear_remote_outputs

: >"$XCRUN_LOG"
run_remote --upload >"$TEST_ROOT/remote-upload-valid.txt" 2>&1 \
  || fail "valid remote upload fixture failed: $(/bin/cat "$TEST_ROOT/remote-upload-valid.txt")"
for published_path in "$VALIDATION_RESULT_PATH" "$UPLOAD_RESULT_PATH" \
    "$DELIVERY_RECORD_PATH"; do
  [[ -f "$published_path" && ! -L "$published_path" \
      && "$(/usr/bin/stat -f '%Lp' "$published_path")" == "444" ]] \
    || fail "remote upload output ${published_path:t} is not a mode-0444 regular file"
done
[[ "$(/usr/bin/wc -l <"$XCRUN_LOG" | /usr/bin/tr -d ' ')" == "2" ]] \
  || fail "upload mode did not make exactly one validation and one upload request"
/usr/bin/jq -e \
  --arg ipa "$IPA_PATH" \
  --arg sha "$EXPECTED_IPA_SHA256" '
    .ipaPath == $ipa and
    .ipaSHA256 == $sha and
    .uploadAccepted == true and
    .warningsReviewed == false and
    .warningsReviewedAt == null
  ' "$DELIVERY_RECORD_PATH" >/dev/null \
  || fail "delivery evidence does not remain bound to the original verified IPA"
assert_no_transient_delivery_state

print -r -- 'iOS TestFlight exact-IPA, remote-response, and atomic-publication tests passed'
