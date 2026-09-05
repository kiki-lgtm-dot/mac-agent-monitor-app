#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

PROJECT_ROOT="${0:A:h:h}"
SUBMIT_SCRIPT="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/submit-macos-app-store.sh"
CONFIRM_SCRIPT="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh"
DELIVERY_VERIFY_SCRIPT="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh"
VERIFY_SCRIPT="$PROJECT_ROOT/ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh"
PREFLIGHT_SOURCE="$PROJECT_ROOT/scripts/assert-release-preflight.sh"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-mac-delivery-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "macOS App Store delivery test failed: $*"
  exit 1
}

contains() {
  local marker="$1"
  local path="$2"
  /usr/bin/grep -Fq -- "$marker" "$path" \
    || fail "missing '$marker' in ${path#$PROJECT_ROOT/}"
}

[[ -x "$SUBMIT_SCRIPT" ]] || fail "submit-macos-app-store.sh is missing or not executable"
[[ -x "$CONFIRM_SCRIPT" ]] \
  || fail "confirm-macos-app-store-evidence.sh is missing or not executable"
[[ -x "$DELIVERY_VERIFY_SCRIPT" ]] \
  || fail "verify-macos-app-store-delivery.sh is missing or not executable"
[[ -x "$VERIFY_SCRIPT" ]] \
  || fail "verify-macos-app-store-evidence.sh is missing or not executable"
/bin/zsh -n "$SUBMIT_SCRIPT"
/bin/zsh -n "$CONFIRM_SCRIPT"
/bin/zsh -n "$DELIVERY_VERIFY_SCRIPT"
/bin/zsh -n "$VERIFY_SCRIPT"

for marker in '--check' '--validate' '--upload' '--type macos' \
  'MINIMUM_XCODE_MAJOR=14' \
  'export_method_matches_xcode' \
  'approved_signed_entitlement_key' \
  '"$PREFLIGHT_ASSERTION" mac-app-store-upload' \
  'assert_upload_identity_lock_unchanged' \
  'AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA="$METADATA_PATH"' \
  '.mac-app-store-submit.lock' \
  'CFBundleDevelopmentRegion raw "$info"' \
  'assert_no_quarantine_attributes "$app_path" "$label"' \
  'private App Store package snapshot' \
  'AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD' \
  'Upload acceptance is not processing completion' \
  'processingState: null' 'warningsReviewed: false' \
  '/bin/ln -h "$temporary_path" "$destination_path"' \
  '/bin/chmod 0444 "$temporary_path"' \
  '/usr/bin/stat -f '\''%d:%i'\'' "$destination_path"' \
  'length == 1' 'REMOTE_PACKAGE_PATH'; do
  contains "$marker" "$SUBMIT_SCRIPT"
done
for marker in '--processing-state Complete' '--warnings-reviewed' \
  'AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING' \
  'processingState: $processingState' 'warningsReviewed: true' \
  'submittedForAppReview: false' \
  'verify-macos-app-store-delivery.sh"'; do
  contains "$marker" "$CONFIRM_SCRIPT"
done
for marker in '--check' '--json' 'evidenceVerified: true' \
  'uploadAccepted: true' 'processingState: null' \
  'submittedForAppReview: false' 'submit-macos-app-store.sh" --check' \
  'verify_altool_success_json' 'length == 1'; do
  contains "$marker" "$DELIVERY_VERIFY_SCRIPT"
done
for marker in '--check' '--json' 'evidenceVerified: true' \
  'deliveryEvidenceVerified: true' 'deliveryRecordPath: $deliveryRecordPath' \
  'releaseMetadataPath: $releaseMetadataPath' 'archiveZipPath: $archiveZipPath' \
  'validationResultPath: $validationResultPath' 'uploadResultPath: $uploadResultPath' \
  'submittedAt: $submittedAt' 'processingState: "Complete"' \
  'warningsReviewed: true' 'verify-macos-app-store-delivery.sh"'; do
  contains "$marker" "$VERIFY_SCRIPT"
done

STUB_DIRECTORY="$TEST_ROOT/stubs"
INSTRUMENTED_PRODUCT_ROOT="$TEST_ROOT/project"
INSTRUMENTED_MAC_ROOT="$INSTRUMENTED_PRODUCT_ROOT/ApplePlatforms/macOS"
INSTRUMENTED_IOS_ROOT="$INSTRUMENTED_PRODUCT_ROOT/ApplePlatforms/iOS"
INSTRUMENTED_SUBMIT="$INSTRUMENTED_MAC_ROOT/scripts/submit-macos-app-store.sh"
INSTRUMENTED_CONFIRM="$INSTRUMENTED_MAC_ROOT/scripts/confirm-macos-app-store-evidence.sh"
INSTRUMENTED_DELIVERY_VERIFY="$INSTRUMENTED_MAC_ROOT/scripts/verify-macos-app-store-delivery.sh"
INSTRUMENTED_VERIFY="$INSTRUMENTED_MAC_ROOT/scripts/verify-macos-app-store-evidence.sh"
INSTRUMENTED_PREFLIGHT="$INSTRUMENTED_PRODUCT_ROOT/scripts/assert-release-preflight.sh"
INSTRUMENTED_READINESS="$INSTRUMENTED_PRODUCT_ROOT/scripts/release-readiness.sh"
TEST_USER_ROOT="$TEST_ROOT/test-user"
/bin/mkdir -p "$STUB_DIRECTORY" "$INSTRUMENTED_MAC_ROOT/scripts" \
  "$INSTRUMENTED_MAC_ROOT/Config" "$INSTRUMENTED_IOS_ROOT/Config" \
  "$INSTRUMENTED_PRODUCT_ROOT/Resources" "$INSTRUMENTED_PRODUCT_ROOT/scripts" \
  "$TEST_USER_ROOT"

/bin/cat >"$STUB_DIRECTORY/codesign" <<'EOF'
#!/bin/zsh
set -euo pipefail

if [[ " $* " == *" --extract-certificates "* ]]; then
  /bin/cp "$AGENT_ISLAND_TEST_LEAF_CERTIFICATE" codesign0
elif [[ " $* " == *" --entitlements - "* ]]; then
  /bin/cat "$AGENT_ISLAND_TEST_APP_ENTITLEMENTS"
elif [[ " $* " == *" --verbose=4 "* ]]; then
  print -u2 -r -- "Authority=$AGENT_ISLAND_TEST_SIGNING_IDENTITY"
  print -u2 -r -- "TeamIdentifier=$AGENT_ISLAND_TEST_TEAM_ID"
  print -u2 -r -- "CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded"
fi
EOF

/bin/cat >"$STUB_DIRECTORY/security" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "cms" && "$2" == "-D" ]] || exit 64
if [[ " $* " == *" -h 0 "* && " $* " == *" -n "* ]]; then
  print -r -- 'nsigners=1; signer0.id="Mac OS X Provisioning Profile Signing"; signer0.status=GoodSignature; '
  exit 0
fi
input_path=""
output_path=""
for (( index = 1; index <= $#; index++ )); do
  case "${argv[$index]}" in
    -i) input_path="${argv[$(( index + 1 ))]}" ;;
    -o) output_path="${argv[$(( index + 1 ))]}" ;;
  esac
done
[[ -n "$input_path" && -n "$output_path" ]] || exit 65
/bin/cp "$input_path" "$output_path"
EOF

/bin/cat >"$STUB_DIRECTORY/openssl" <<'EOF'
#!/bin/zsh
set -euo pipefail
case "${1:-}" in
  cms)
    signer_path=""
    while (( $# > 0 )); do
      if [[ "$1" == "-signer" ]]; then signer_path="$2"; break; fi
      shift
    done
    [[ -n "$signer_path" ]] || exit 64
    print -r -- '-----BEGIN CERTIFICATE-----' >"$signer_path"
    print -r -- 'QUJD' >>"$signer_path"
    print -r -- '-----END CERTIFICATE-----' >>"$signer_path"
    print -u2 -- 'Verification successful'
    ;;
  x509)
    print -r -- 'subject= C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing'
    print -r -- 'issuer= C=US,O=Apple Inc.,OU=G5,CN=Apple Worldwide Developer Relations Certification Authority'
    print -r -- 'SHA256 Fingerprint=08:84:FC:02:63:65:E1:4A:91:CE:C7:75:83:B5:B4:AE:04:1B:E4:9B:C9:90:E7:4F:4A:15:E2:B4:2B:50:DC:55'
    ;;
  *) exit 64 ;;
esac
EOF

/bin/cat >"$STUB_DIRECTORY/lipo" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "-archs" && -f "$2" ]] || exit 64
print -r -- "x86_64 arm64"
EOF

/bin/cat >"$STUB_DIRECTORY/pkgutil" <<'EOF'
#!/bin/zsh
set -euo pipefail
case "$1" in
  --check-signature)
    [[ "$2" == "$AGENT_ISLAND_TEST_PACKAGE_PATH" ]] || exit 64
    print -r -- "Status: signed by a certificate trusted by macOS"
    print -r -- "Certificate Chain:"
    print -r -- " 1. $AGENT_ISLAND_TEST_INSTALLER_IDENTITY"
    ;;
  --expand)
    [[ "$2" == "$AGENT_ISLAND_TEST_PACKAGE_PATH" ]] || exit 64
    /bin/mkdir -p "$3"
    /bin/cp -R "$AGENT_ISLAND_TEST_EXPANDED_PACKAGE"/. "$3"/
    ;;
  *)
    exit 64
    ;;
esac
EOF

/bin/cat >"$STUB_DIRECTORY/xcodebuild" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "-version" ]] || exit 64
print -r -- "Xcode ${AGENT_ISLAND_TEST_XCODE_VERSION:-26.0}"
print -r -- "Build version 17A000"
EOF

/bin/cat >"$STUB_DIRECTORY/date" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ -n "${AGENT_ISLAND_TEST_FIXED_STAMP:-}" && "$#" -eq 2 && \
    "$1" == "-u" && "$2" == "+%Y%m%dT%H%M%SZ" ]]; then
  print -r -- "$AGENT_ISLAND_TEST_FIXED_STAMP"
  exit 0
fi
exec /bin/date "$@"
EOF

/bin/cat >"$STUB_DIRECTORY/ln" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ -n "${AGENT_ISLAND_TEST_RACE_DIRECTORY:-}" && "$#" -eq 3 && \
    "$1" == "-h" && "$3" == "$AGENT_ISLAND_TEST_RACE_DIRECTORY" ]]; then
  /bin/mkdir "$AGENT_ISLAND_TEST_RACE_DIRECTORY"
fi
exec /bin/ln "$@"
EOF

/bin/cat >"$STUB_DIRECTORY/xcrun" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == "--find" && "$2" == "altool" ]]; then
  print -r -- "/fixture/altool"
  exit 0
fi
[[ "$1" == "altool" ]] || exit 64
print -r -- "$*" >>"$AGENT_ISLAND_TEST_ALTOOL_LOG"
candidate_path=""
for (( index = 1; index <= $#; index++ )); do
  if [[ "${argv[index]}" == "--file" && index -lt $# ]]; then
    candidate_path="${argv[index + 1]}"
    break
  fi
done
[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || exit 65
candidate_sha256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$candidate_path" \
  | /usr/bin/awk '{print $1}')"
[[ "$candidate_sha256" == "$AGENT_ISLAND_TEST_PACKAGE_SHA256" ]] || exit 65
[[ "${candidate_path:t}" == "AgentIslandMac-upload.pkg" ]] || exit 65
[[ " $* " == *" --type macos "* ]] || exit 66
if [[ " $* " == *" --validate-app "* ]]; then
  [[ "${AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE:-}" != "validate" ]] || exit 68
  case "${AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE:-}" in
    validate-json-error)
      print -r -- '{"product-errors":[{"message":"synthetic validation rejection"}]}'
      ;;
    validate-json-error-then-success)
      print -r -- '{"product-errors":[{"message":"synthetic validation rejection"}]}'
      print -r -- '{"success-message":"No errors validating the synthetic archive."}'
      ;;
    validate-json-product-errors-false)
      print -r -- '{"success-message":"No errors validating the synthetic archive.","product-errors":false}'
      ;;
    validate-json-errors-false)
      print -r -- '{"success-message":"No errors validating the synthetic archive.","errors":false}'
      ;;
    *)
      print -r -- '{"success-message":"No errors validating the synthetic archive."}'
      ;;
  esac
  if [[ "${AGENT_ISLAND_TEST_MUTATE_IDENTITY_LOCK_AFTER_VALIDATE:-}" == true ]]; then
    print -n -r -- 'tampered after validation' \
      >>"$AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH"
  fi
elif [[ " $* " == *" --upload-app "* ]]; then
  [[ "${AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE:-}" != "upload" ]] || exit 69
  print -r -- '{"success-message":"Successfully uploaded the synthetic package."}'
else
  exit 67
fi
EOF
/bin/chmod 0755 "$STUB_DIRECTORY"/*

/usr/bin/sed \
  -e "s#/usr/bin/codesign#$STUB_DIRECTORY/codesign#g" \
  -e "s#/usr/bin/security#$STUB_DIRECTORY/security#g" \
  -e "s#/usr/bin/lipo#$STUB_DIRECTORY/lipo#g" \
  -e "s#/usr/sbin/pkgutil#$STUB_DIRECTORY/pkgutil#g" \
  -e "s#/usr/bin/xcodebuild#$STUB_DIRECTORY/xcodebuild#g" \
  -e "s#/usr/bin/xcrun#$STUB_DIRECTORY/xcrun#g" \
  -e "s#/bin/date#$STUB_DIRECTORY/date#g" \
  -e "s#/bin/ln#$STUB_DIRECTORY/ln#g" \
  -e 's#${HOME}#'"$TEST_USER_ROOT"'#g' \
  "$SUBMIT_SCRIPT" >"$INSTRUMENTED_SUBMIT"
/usr/bin/sed \
  -e "s#/usr/bin/security#$STUB_DIRECTORY/security#g" \
  -e "s#/usr/bin/openssl#$STUB_DIRECTORY/openssl#g" \
  "$PROJECT_ROOT/scripts/apple-cms-profile.zsh" \
  >"$INSTRUMENTED_PRODUCT_ROOT/scripts/apple-cms-profile.zsh"
/bin/cp "$CONFIRM_SCRIPT" "$INSTRUMENTED_CONFIRM"
/bin/cp "$DELIVERY_VERIFY_SCRIPT" "$INSTRUMENTED_DELIVERY_VERIFY"
/bin/cp "$VERIFY_SCRIPT" "$INSTRUMENTED_VERIFY"
/bin/cp "$PREFLIGHT_SOURCE" "$INSTRUMENTED_PREFLIGHT"
/bin/cp "$PROJECT_ROOT/scripts/cloudkit-profile-authorization.jq" \
  "$INSTRUMENTED_PRODUCT_ROOT/scripts/cloudkit-profile-authorization.jq"
/bin/cat >"$INSTRUMENTED_READINESS" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" == 1 && "$1" == "--json" ]] || exit 64
[[ "${AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA:-}" == \
  "${AGENT_ISLAND_TEST_EXPECTED_RELEASE_METADATA:-}" ]] || exit 65
upload_ready=true
[[ "${AGENT_ISLAND_TEST_UPLOAD_READINESS_FAIL:-}" != true ]] \
  || upload_ready=false
/usr/bin/jq -n \
  --argjson uploadReady "$upload_ready" \
  --arg lockPath "$AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH" \
  --arg lockSHA "$AGENT_ISLAND_TEST_IDENTITY_LOCK_SHA256" '{
  releaseIdentityLockConfigured: true,
  releaseIdentityLockValid: true,
  releaseIdentityAppliedFilesMatch: true,
  releaseIdentityMatchesConfiguration: true,
  releaseIdentityLockPath: $lockPath,
  releaseIdentityLockSHA256: $lockSHA,
  releaseIdentityReady: true,
  readyForMacAppStoreArchive: true,
  macAppStoreExactCandidateEvidenceReady: true,
  macAppStoreLocalPreflightPassed: true,
  macAppStoreFunctionalQAEvidenceReady: true,
  macAppStoreFunctionalEvidenceBoundToCandidate: true,
  macAppStoreSandboxFlowVerified: true,
  macAppStoreArchiveVerified: true,
  macAppStoreProfileCertificateVerified: true,
  macAppStorePrivacyReportVerified: true,
  macAppStoreReviewPathVerified: true,
  cloudKitProductionSchemaVerified: true,
  macPrivacyReleaseEvidenceReady: true,
  macStoreSubmissionAssetsReady: true,
  iosStoreSubmissionAssetsReady: false,
  storeSubmissionAssetsReady: false,
  readyForMacAppStoreUpload: $uploadReady
}'
EOF
/bin/chmod 0755 "$INSTRUMENTED_SUBMIT" "$INSTRUMENTED_CONFIRM" \
  "$INSTRUMENTED_DELIVERY_VERIFY" "$INSTRUMENTED_VERIFY" \
  "$INSTRUMENTED_PREFLIGHT" "$INSTRUMENTED_READINESS"

TEAM_ID="ABCDE12345"
APP_BUNDLE_ID="com.agentisland.release"
APPLICATION_IDENTIFIER="$TEAM_ID.$APP_BUNDLE_ID"
CLOUD_CONTAINER_ID="iCloud.com.agentisland.release"
DISPLAY_NAME="MAC版灵动岛--Agent运行监测"
PRIVACY_POLICY_URL="https://agentisland.test/privacy"
SUPPORT_URL="https://agentisland.test/support"
COPYRIGHT="© 2026 Agent Island Release Test"
PROFILE_UUID="11111111-2222-3333-4444-555555555555"
PROFILE_NAME="Agent Island Mac App Store Fixture"
PROFILE_EXPIRATION="2099-01-01T00:00:00Z"
SIGNING_IDENTITY="Apple Distribution: Release Fixture ($TEAM_ID)"
INSTALLER_IDENTITY="Mac Installer Distribution: Release Fixture ($TEAM_ID)"
VERSION="1.2.3"
BUILD_NUMBER="42"
CMS_KEYCHAIN="$TEST_ROOT/cms-test.keychain-db"
print -n -r -- 'isolated CMS test keychain' >"$CMS_KEYCHAIN"
/bin/chmod 0600 "$CMS_KEYCHAIN"
export AGENT_ISLAND_CMS_KEYCHAIN="$CMS_KEYCHAIN"

/bin/cat >"$INSTRUMENTED_IOS_ROOT/Config/Project.xcconfig" <<EOF
AGENT_ISLAND_DISPLAY_NAME = $DISPLAY_NAME
AGENT_ISLAND_URL_SLASH = /
AGENT_ISLAND_APP_BUNDLE_ID = $APP_BUNDLE_ID
AGENT_ISLAND_DEVELOPMENT_TEAM = $TEAM_ID
AGENT_ISLAND_ICLOUD_CONTAINER_ID = $CLOUD_CONTAINER_ID
AGENT_ISLAND_PRIVACY_POLICY_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)agentisland.test/privacy
AGENT_ISLAND_SUPPORT_URL = https:\$(AGENT_ISLAND_URL_SLASH)\$(AGENT_ISLAND_URL_SLASH)agentisland.test/support
EOF
/bin/cat >"$INSTRUMENTED_MAC_ROOT/Config/Project.xcconfig" <<EOF
AGENT_ISLAND_MAC_APP_BUNDLE_ID = $APP_BUNDLE_ID
MARKETING_VERSION = $VERSION
CURRENT_PROJECT_VERSION = $BUILD_NUMBER
MACOSX_DEPLOYMENT_TARGET = 13.0
EOF
/bin/cp "$PROJECT_ROOT/Resources/PrivacyInfo.xcprivacy" \
  "$INSTRUMENTED_PRODUCT_ROOT/Resources/PrivacyInfo.xcprivacy"

RELEASE_DIRECTORY="$TEST_ROOT/release"
ARCHIVE_PATH="$RELEASE_DIRECTORY/AgentIslandMac.xcarchive"
ARCHIVE_ZIP_PATH="$RELEASE_DIRECTORY/AgentIslandMac.xcarchive.zip"
PACKAGE_PATH="$RELEASE_DIRECTORY/export/AgentIslandMac.pkg"
PAYLOAD_ROOT="$TEST_ROOT/payload-root"
APP_PATH="$PAYLOAD_ROOT/Applications/AgentIslandMac.app"
EXPANDED_PACKAGE="$TEST_ROOT/expanded-package"
PROFILE_PATH="$APP_PATH/Contents/embedded.provisionprofile"
APP_ENTITLEMENTS="$TEST_ROOT/app-entitlements.json"
LEAF_CERTIFICATE="$TEST_ROOT/leaf-certificate.der"
METADATA_PATH="$RELEASE_DIRECTORY/release-metadata.json"
/bin/mkdir -p "$ARCHIVE_PATH/Products/Applications/AgentIslandMac.app/Contents" \
  "${PACKAGE_PATH:h}" "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Resources/Web" "$EXPANDED_PACKAGE/Component.pkg"
print -n -r -- 'synthetic flat Mac App Store package' >"$PACKAGE_PATH"
print -n -r -- 'synthetic Apple Distribution leaf' >"$LEAF_CERTIFICATE"
LEAF_CERTIFICATE_BASE64="$(/usr/bin/base64 <"$LEAF_CERTIFICATE" | /usr/bin/tr -d '\n')"
SIGNING_CERTIFICATE_SHA1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 \
  "$LEAF_CERTIFICATE" | /usr/bin/awk '{print toupper($1)}')"

/usr/bin/jq -n \
  --arg identifier "$APPLICATION_IDENTIFIER" \
  --arg team "$TEAM_ID" \
  --arg container "$CLOUD_CONTAINER_ID" '{
    "com.apple.application-identifier": $identifier,
    "com.apple.developer.team-identifier": $team,
    "com.apple.security.get-task-allow": false,
    "com.apple.security.app-sandbox": true,
    "com.apple.security.files.user-selected.read-only": true,
    "com.apple.security.files.bookmarks.app-scope": true,
    "com.apple.security.network.client": true,
    "com.apple.developer.icloud-container-identifiers": [$container],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production"
  }' >"$APP_ENTITLEMENTS"
/bin/cp "$APP_ENTITLEMENTS" "$TEST_ROOT/valid-app-entitlements.json"
/usr/bin/jq -n \
  --arg prefix "$TEAM_ID" \
  --arg team "$TEAM_ID" \
  --arg expiration "$PROFILE_EXPIRATION" \
  --arg uuid "$PROFILE_UUID" \
  --arg name "$PROFILE_NAME" \
  --arg certificate "$LEAF_CERTIFICATE_BASE64" \
  --arg container "$CLOUD_CONTAINER_ID" \
  --slurpfile entitlements "$APP_ENTITLEMENTS" '{
    ApplicationIdentifierPrefix: [$prefix],
    TeamIdentifier: [$team],
    Platform: ["OSX"],
    ExpirationDate: $expiration,
    UUID: $uuid,
    Name: $name,
    DeveloperCertificates: [$certificate],
    Entitlements: ($entitlements[0] + {
      "com.apple.developer.icloud-services": "*",
      "com.apple.developer.icloud-container-environment":
        ["Production", "Development"],
      "com.apple.developer.icloud-container-development-container-identifiers":
        [$container],
      "com.apple.developer.ubiquity-container-identifiers": [$container],
      "com.apple.developer.ubiquity-kvstore-identifier": ($prefix + ".*"),
      "keychain-access-groups": [($team + ".*")]
    })
  }' >"$PROFILE_PATH"

/usr/bin/jq -n \
  --arg bundle "$APP_BUNDLE_ID" \
  --arg display "$DISPLAY_NAME" \
  --arg copyright "$COPYRIGHT" \
  --arg privacy "$PRIVACY_POLICY_URL" \
  --arg support "$SUPPORT_URL" '{
    CFBundleIdentifier: $bundle,
    CFBundleDisplayName: $display,
    CFBundleDevelopmentRegion: "en",
    CFBundleShortVersionString: "1.2.3",
    CFBundleVersion: "42",
    CFBundleExecutable: "AgentIsland",
    CFBundleIconFile: "AgentIsland",
    NSHumanReadableCopyright: $copyright,
    AgentIslandPrivacyPolicyURL: $privacy,
    AgentIslandSupportURL: $support,
    LSMinimumSystemVersion: "13.0",
    LSApplicationCategoryType: "public.app-category.developer-tools",
    LSUIElement: true,
    ITSAppUsesNonExemptEncryption: false,
    NSAppTransportSecurity: {NSAllowsLocalNetworking: true}
  }' >"$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -convert xml1 "$APP_PATH/Contents/Info.plist"
print -n -r -- 'synthetic universal executable' >"$APP_PATH/Contents/MacOS/AgentIsland"
/bin/chmod 0755 "$APP_PATH/Contents/MacOS/AgentIsland"
/bin/cp "$PROJECT_ROOT/Resources/PrivacyInfo.xcprivacy" \
  "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy"
print -n -r -- 'icon' >"$APP_PATH/Contents/Resources/AgentIsland.icns"
print -n -r -- 'notices' >"$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
print -n -r -- '<!doctype html>' >"$APP_PATH/Contents/Resources/Web/index.html"

refresh_payload() {
  /bin/rm -f "$EXPANDED_PACKAGE/Component.pkg/Payload"
  /usr/bin/ditto -c -z "$PAYLOAD_ROOT" "$EXPANDED_PACKAGE/Component.pkg/Payload"
}
refresh_payload

/bin/rm -rf "$ARCHIVE_PATH/Products/Applications/AgentIslandMac.app"
/bin/cp -R "$APP_PATH" "$ARCHIVE_PATH/Products/Applications/AgentIslandMac.app"
/usr/bin/jq -n \
  --arg bundle "$APP_BUNDLE_ID" '{
    ApplicationProperties: {
      CFBundleIdentifier: $bundle,
      ApplicationPath: "Applications/AgentIslandMac.app"
    }
  }' >"$ARCHIVE_PATH/Info.plist"
/usr/bin/plutil -convert xml1 "$ARCHIVE_PATH/Info.plist"
(cd "$RELEASE_DIRECTORY" && \
  /usr/bin/zip -qry "${ARCHIVE_ZIP_PATH:t}" "${ARCHIVE_PATH:t}")

ARCHIVE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$ARCHIVE_ZIP_PATH" \
  | /usr/bin/awk '{print $1}')"
PACKAGE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$PACKAGE_PATH" \
  | /usr/bin/awk '{print $1}')"
PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
print -r -- "$ARCHIVE_SHA256  ${ARCHIVE_ZIP_PATH:t}" >"$ARCHIVE_ZIP_PATH.sha256"
print -r -- "$PACKAGE_SHA256  ${PACKAGE_PATH:t}" >"$PACKAGE_PATH.sha256"

/usr/bin/jq -n \
  --arg archive "$ARCHIVE_PATH" \
  --arg archiveZip "$ARCHIVE_ZIP_PATH" \
  --arg archiveSHA "$ARCHIVE_SHA256" \
  --arg package "$PACKAGE_PATH" \
  --arg packageSHA "$PACKAGE_SHA256" \
  --arg team "$TEAM_ID" \
  --arg bundle "$APP_BUNDLE_ID" \
  --arg display "$DISPLAY_NAME" \
  --arg copyright "$COPYRIGHT" \
  --arg identifier "$APPLICATION_IDENTIFIER" \
  --arg container "$CLOUD_CONTAINER_ID" \
  --arg privacyURL "$PRIVACY_POLICY_URL" \
  --arg supportURL "$SUPPORT_URL" \
  --arg privacySHA "$PRIVACY_SHA256" \
  --arg identity "$SIGNING_IDENTITY" \
  --arg certificateSHA "$SIGNING_CERTIFICATE_SHA1" \
  --arg profileUUID "$PROFILE_UUID" \
  --arg profileName "$PROFILE_NAME" \
  --arg profileExpiration "$PROFILE_EXPIRATION" \
  --arg installerIdentity "$INSTALLER_IDENTITY" '{
    schemaVersion: 1,
    product: "MAC版灵动岛--Agent运行监测",
    platform: "macOS",
    distribution: "mac-app-store",
    version: "1.2.3",
    build: "42",
    archivePath: $archive,
    archiveZip: $archiveZip,
    archiveZipSHA256: $archiveSHA,
    resultBundle: "fixture.xcresult",
    exportedPackage: $package,
    packageSHA256: $packageSHA,
    exportMethod: "app-store-connect",
    exportDestination: "export",
    xcodeVersion: "26.0",
    macosSDK: "26.0",
    teamID: $team,
    appBundleID: $bundle,
    displayName: $display,
    applicationCategory: "public.app-category.developer-tools",
    copyright: $copyright,
    applicationIdentifier: $identifier,
    cloudContainerID: $container,
    cloudKitEnvironment: "Production",
    privacyPolicyURL: $privacyURL,
    supportURL: $supportURL,
    privacyManifestSHA256: $privacySHA,
    quarantineFree: true,
    signingIdentity: $identity,
    signingCertificateSHA1: $certificateSHA,
    provisioningProfile: {
      uuid: $profileUUID,
      name: $profileName,
      expiration: $profileExpiration,
      certificateMatches: true
    },
    installerSigningIdentity: $installerIdentity,
    exportedProvisioningProfileExpiration: $profileExpiration,
    allowProvisioningUpdates: false,
    uploaded: false,
    createdAt: "2026-01-01T00:00:00Z"
  }' >"$METADATA_PATH"
VALID_METADATA="$TEST_ROOT/valid-release-metadata.json"
/bin/cp "$METADATA_PATH" "$VALID_METADATA"
VALID_PACKAGE="$TEST_ROOT/valid-package.pkg"
/bin/cp "$PACKAGE_PATH" "$VALID_PACKAGE"
IDENTITY_LOCK_PATH="$TEST_ROOT/identity.lock.json"
print -n -r -- '{"schemaVersion":2}' >"$IDENTITY_LOCK_PATH"
/bin/chmod 0600 "$IDENTITY_LOCK_PATH"
IDENTITY_LOCK_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$IDENTITY_LOCK_PATH" | /usr/bin/awk '{print $1}')"

export AGENT_ISLAND_TEST_LEAF_CERTIFICATE="$LEAF_CERTIFICATE"
export AGENT_ISLAND_TEST_APP_ENTITLEMENTS="$APP_ENTITLEMENTS"
export AGENT_ISLAND_TEST_SIGNING_IDENTITY="$SIGNING_IDENTITY"
export AGENT_ISLAND_TEST_INSTALLER_IDENTITY="$INSTALLER_IDENTITY"
export AGENT_ISLAND_TEST_TEAM_ID="$TEAM_ID"
export AGENT_ISLAND_TEST_PACKAGE_PATH="$PACKAGE_PATH"
export AGENT_ISLAND_TEST_PACKAGE_SHA256="$PACKAGE_SHA256"
export AGENT_ISLAND_TEST_EXPANDED_PACKAGE="$EXPANDED_PACKAGE"
export AGENT_ISLAND_TEST_ALTOOL_LOG="$TEST_ROOT/altool.log"
export AGENT_ISLAND_TEST_EXPECTED_RELEASE_METADATA="$METADATA_PATH"
export AGENT_ISLAND_TEST_IDENTITY_LOCK_PATH="$IDENTITY_LOCK_PATH"
export AGENT_ISLAND_TEST_IDENTITY_LOCK_SHA256="$IDENTITY_LOCK_SHA256"

expect_check_rejected() {
  local marker="$1"
  local output="$TEST_ROOT/check-rejected.txt"
  if "$INSTRUMENTED_SUBMIT" --check "$RELEASE_DIRECTORY" >"$output" 2>&1; then
    fail "local preflight accepted fixture expected to fail with: $marker"
  fi
  contains "$marker" "$output"
}

VALID_OUTPUT="$TEST_ROOT/check-valid.txt"
"$INSTRUMENTED_SUBMIT" --check "$RELEASE_DIRECTORY" >"$VALID_OUTPUT" 2>&1 \
  || fail "valid synthetic package did not pass: $(/bin/cat "$VALID_OUTPUT")"
contains 'Local Mac App Store package preflight passed.' "$VALID_OUTPUT"
contains "Upload confirmation: $APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$PACKAGE_SHA256" \
  "$VALID_OUTPUT"

/usr/bin/jq '.xcodeVersion = "14.3.1" | .exportMethod = "app-store"' \
  "$VALID_METADATA" >"$METADATA_PATH"
XCODE14_OUTPUT="$TEST_ROOT/check-xcode14.txt"
"$INSTRUMENTED_SUBMIT" --check "$RELEASE_DIRECTORY" >"$XCODE14_OUTPUT" 2>&1 \
  || fail "valid Xcode 14/app-store metadata did not pass: $(/bin/cat "$XCODE14_OUTPUT")"
contains 'Local Mac App Store package preflight passed.' "$XCODE14_OUTPUT"

/usr/bin/jq '.xcodeVersion = "14.3.1"' "$VALID_METADATA" >"$METADATA_PATH"
expect_check_rejected 'release metadata is incomplete, unverified, or from an unsupported schema'
/usr/bin/jq '.xcodeVersion = "15.0" | .exportMethod = "app-store"' \
  "$VALID_METADATA" >"$METADATA_PATH"
expect_check_rejected 'release metadata is incomplete, unverified, or from an unsupported schema'
/bin/cp "$VALID_METADATA" "$METADATA_PATH"

ARCHIVE_WEB_INDEX="$ARCHIVE_PATH/Products/Applications/AgentIslandMac.app/Contents/Resources/Web/index.html"
/bin/cp "$ARCHIVE_WEB_INDEX" "$TEST_ROOT/valid-archive-index.html"
print -n -r -- 'tamper' >>"$ARCHIVE_WEB_INDEX"
expect_check_rejected 'current Archive differs from the SHA-256-bound Archive ZIP'
/bin/cp "$TEST_ROOT/valid-archive-index.html" "$ARCHIVE_WEB_INDEX"

print -n -r -- 'tamper' >>"$PACKAGE_PATH"
expect_check_rejected 'App Store package SHA-256 differs from release metadata'
/bin/cp "$VALID_PACKAGE" "$PACKAGE_PATH"

/usr/bin/jq 'del(.applicationCategory)' "$VALID_METADATA" >"$METADATA_PATH"
expect_check_rejected 'release metadata is incomplete, unverified, or from an unsupported schema'
/bin/cp "$VALID_METADATA" "$METADATA_PATH"

/usr/bin/xattr -w com.apple.quarantine \
  '0081;fixture;AgentIsland;' "$ARCHIVE_WEB_INDEX"
expect_check_rejected 'archived App contains com.apple.quarantine'
/usr/bin/xattr -d com.apple.quarantine "$ARCHIVE_WEB_INDEX"

PACKAGE_WEB_INDEX="$APP_PATH/Contents/Resources/Web/index.html"
/usr/bin/xattr -w com.apple.quarantine \
  '0081;fixture;AgentIsland;' "$PACKAGE_WEB_INDEX"
refresh_payload
expect_check_rejected 'packaged App contains com.apple.quarantine'
/usr/bin/xattr -d com.apple.quarantine "$PACKAGE_WEB_INDEX"
refresh_payload

/usr/bin/xattr -w com.apple.quarantine \
  '0081;fixture;AgentIsland;' "$PACKAGE_PATH"
expect_check_rejected 'App Store package contains com.apple.quarantine'
/usr/bin/xattr -d com.apple.quarantine "$PACKAGE_PATH"

/usr/bin/plutil -replace LSApplicationCategoryType -string \
  'public.app-category.utilities' "$APP_PATH/Contents/Info.plist"
refresh_payload
expect_check_rejected 'packaged App application category must remain public.app-category.developer-tools'
/usr/bin/plutil -replace LSApplicationCategoryType -string \
  'public.app-category.developer-tools' "$APP_PATH/Contents/Info.plist"
refresh_payload

/usr/bin/plutil -replace CFBundleDevelopmentRegion -string 'zh-Hans' \
  "$APP_PATH/Contents/Info.plist"
refresh_payload
expect_check_rejected 'packaged App development region must remain en'
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string 'en' \
  "$APP_PATH/Contents/Info.plist"
refresh_payload

/usr/bin/jq '. + {"com.apple.security.network.server": true}' \
  "$TEST_ROOT/valid-app-entitlements.json" >"$APP_ENTITLEMENTS"
expect_check_rejected 'signature/profile failed exact sandbox, identity, Team, or Production CloudKit validation'
/bin/cp "$TEST_ROOT/valid-app-entitlements.json" "$APP_ENTITLEMENTS"

FAKE_DEVELOPER="$TEST_ROOT/XcodeFixture.app/Contents/Developer"
/bin/mkdir -p "$FAKE_DEVELOPER/Platforms/MacOSX.platform" \
  "$TEST_USER_ROOT/.appstoreconnect/private_keys"
API_KEY_ID="ABCDEF1234"
API_ISSUER_ID="11111111-2222-3333-4444-555555555555"
PRIVATE_KEY="$TEST_USER_ROOT/.appstoreconnect/private_keys/AuthKey_$API_KEY_ID.p8"
print -n -r -- 'fixture private key' >"$PRIVATE_KEY"
/bin/chmod 0600 "$PRIVATE_KEY"
UPLOAD_CONFIRMATION="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$PACKAGE_SHA256"

OLD_XCODE_OUTPUT="$TEST_ROOT/old-xcode.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_TEST_XCODE_VERSION='13.4.1' \
    "$INSTRUMENTED_SUBMIT" --validate "$RELEASE_DIRECTORY" \
      >"$OLD_XCODE_OUTPUT" 2>&1; then
  fail "Xcode 13 was accepted for a 2026 Mac App Store delivery"
fi
contains 'Xcode 14 or newer is required for Mac App Store delivery' \
  "$OLD_XCODE_OUTPUT"

FAILED_VALIDATION_OUTPUT="$TEST_ROOT/failed-validation.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE=validate \
    "$INSTRUMENTED_SUBMIT" --validate "$RELEASE_DIRECTORY" \
      >"$FAILED_VALIDATION_OUTPUT" 2>&1; then
  fail "failed altool validation unexpectedly succeeded"
fi
failed_validation_results=("$RELEASE_DIRECTORY"/mac-app-store-validation-*.json(.N))
(( ${#failed_validation_results} == 0 )) \
  || fail "failed altool validation published a result file"

expect_altool_validation_json_rejected() {
  local fail_mode="$1"
  local label="$2"
  local output="$TEST_ROOT/failed-json-validation-$label.txt"
  if DEVELOPER_DIR="$FAKE_DEVELOPER" \
      AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
      AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
      AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE="$fail_mode" \
      "$INSTRUMENTED_SUBMIT" --validate "$RELEASE_DIRECTORY" \
        >"$output" 2>&1; then
    fail "$label altool JSON unexpectedly passed validation"
  fi
  contains 'does not contain an unambiguous altool success response' "$output"
  local results=("$RELEASE_DIRECTORY"/mac-app-store-validation-*.json(.N))
  (( ${#results} == 0 )) \
    || fail "$label altool JSON published a validation result"
}

expect_altool_validation_json_rejected validate-json-error single-error
expect_altool_validation_json_rejected \
  validate-json-error-then-success error-object-then-success-object
expect_altool_validation_json_rejected \
  validate-json-product-errors-false boolean-product-errors
expect_altool_validation_json_rejected \
  validate-json-errors-false boolean-errors

RACE_STAMP="20990102T030405Z"
RACE_DIRECTORY="$RELEASE_DIRECTORY/mac-app-store-validation-$RACE_STAMP.json"
RACE_OUTPUT="$TEST_ROOT/directory-race-validation.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_TEST_FIXED_STAMP="$RACE_STAMP" \
    AGENT_ISLAND_TEST_RACE_DIRECTORY="$RACE_DIRECTORY" \
    "$INSTRUMENTED_SUBMIT" --validate "$RELEASE_DIRECTORY" \
      >"$RACE_OUTPUT" 2>&1; then
  fail "validation reported success after its publication target became a directory"
fi
if ! /usr/bin/grep -Fq -- \
    'published delivery evidence does not match the sealed temporary inode' \
    "$RACE_OUTPUT"; then
  fail "directory publication race failed for the wrong reason: $(/bin/cat "$RACE_OUTPUT")"
fi
[[ -d "$RACE_DIRECTORY" && ! -L "$RACE_DIRECTORY" ]] \
  || fail "directory publication race did not preserve the competing target"
race_directory_entries=("$RACE_DIRECTORY"/*(DN))
(( ${#race_directory_entries} == 0 )) \
  || fail "directory publication race leaked a misplaced hard link"
race_temporary_results=("$RELEASE_DIRECTORY"/.mac-app-store-*(.N))
(( ${#race_temporary_results} == 0 )) \
  || fail "directory publication race leaked a temporary release-directory name"
/bin/mv "$RACE_DIRECTORY" "$TEST_ROOT/raced-validation-target"
/bin/rm -f "$AGENT_ISLAND_TEST_ALTOOL_LOG"

STANDALONE_VALIDATE_OUTPUT="$TEST_ROOT/standalone-validate.txt"
DEVELOPER_DIR="$FAKE_DEVELOPER" \
  AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
  AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
  AGENT_ISLAND_TEST_UPLOAD_READINESS_FAIL=true \
  "$INSTRUMENTED_SUBMIT" --validate "$RELEASE_DIRECTORY" \
    >"$STANDALONE_VALIDATE_OUTPUT" 2>&1 \
  || fail "standalone validation incorrectly depended on upload readiness"
contains 'App Store Connect validation passed:' "$STANDALONE_VALIDATE_OUTPUT"
standalone_validation_results=(
  "$RELEASE_DIRECTORY"/mac-app-store-validation-*.json(.N)
)
(( ${#standalone_validation_results} == 1 )) \
  || fail "standalone validation did not publish exactly one validation result"
/bin/mv "${standalone_validation_results[1]}" \
  "$TEST_ROOT/standalone-validation-result.json"
/bin/rm -f "$AGENT_ISLAND_TEST_ALTOOL_LOG"

WRONG_CONFIRM_OUTPUT="$TEST_ROOT/wrong-upload-confirmation.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD='wrong-candidate' \
    "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" \
      >"$WRONG_CONFIRM_OUTPUT" 2>&1; then
  fail "upload accepted the wrong exact-package confirmation"
fi
contains 'does not match this exact package' "$WRONG_CONFIRM_OUTPUT"
[[ ! -e "$AGENT_ISLAND_TEST_ALTOOL_LOG" ]] \
  || fail "wrong upload confirmation still contacted altool"

UPLOAD_GATE_OUTPUT="$TEST_ROOT/upload-readiness-rejected.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="$UPLOAD_CONFIRMATION" \
    AGENT_ISLAND_TEST_UPLOAD_READINESS_FAIL=true \
    "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" \
      >"$UPLOAD_GATE_OUTPUT" 2>&1; then
  fail "upload bypassed the fail-closed exact-candidate readiness gate"
fi
if ! /usr/bin/grep -Fq -- 'Release preflight failed: mac-app-store-upload' \
    "$UPLOAD_GATE_OUTPUT"; then
  fail "upload readiness failed for the wrong reason: $(/bin/cat "$UPLOAD_GATE_OUTPUT")"
fi
[[ ! -e "$AGENT_ISLAND_TEST_ALTOOL_LOG" ]] \
  || fail "rejected upload readiness still contacted altool"

REMOTE_LOCK="$RELEASE_DIRECTORY/.mac-app-store-submit.lock"
/bin/mkdir "$REMOTE_LOCK"
LOCKED_UPLOAD_OUTPUT="$TEST_ROOT/upload-lock-rejected.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="$UPLOAD_CONFIRMATION" \
    "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" \
      >"$LOCKED_UPLOAD_OUTPUT" 2>&1; then
  fail "concurrent upload bypassed the release-directory collaboration lock"
fi
contains 'another Mac App Store validation or upload is already active' \
  "$LOCKED_UPLOAD_OUTPUT"
[[ -d "$REMOTE_LOCK" && ! -L "$REMOTE_LOCK" ]] \
  || fail "rejected upload removed a collaboration lock it did not own"
[[ ! -e "$AGENT_ISLAND_TEST_ALTOOL_LOG" ]] \
  || fail "locked upload still contacted altool"
/bin/rmdir "$REMOTE_LOCK"

TOCTOU_OUTPUT="$TEST_ROOT/upload-identity-lock-drift.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="$UPLOAD_CONFIRMATION" \
    AGENT_ISLAND_TEST_MUTATE_IDENTITY_LOCK_AFTER_VALIDATE=true \
    "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" \
      >"$TOCTOU_OUTPUT" 2>&1; then
  fail "upload continued after the release identity lock changed during validation"
fi
contains 'release identity lock changed after the readiness report was generated' \
  "$TOCTOU_OUTPUT"
contains '--validate-app' "$AGENT_ISLAND_TEST_ALTOOL_LOG"
if /usr/bin/grep -Fq -- '--upload-app' "$AGENT_ISLAND_TEST_ALTOOL_LOG"; then
  fail "identity-lock drift still reached the remote upload operation"
fi
toctou_validation_results=(
  "$RELEASE_DIRECTORY"/mac-app-store-validation-*.json(.N)
)
(( ${#toctou_validation_results} == 1 )) \
  || fail "identity-lock drift did not leave exactly one validation result"
/bin/mv "${toctou_validation_results[1]}" \
  "$TEST_ROOT/toctou-validation-result.json"
print -n -r -- '{"schemaVersion":2}' >"$IDENTITY_LOCK_PATH"
[[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$IDENTITY_LOCK_PATH" \
  | /usr/bin/awk '{print $1}')" == "$IDENTITY_LOCK_SHA256" ]] \
  || fail "identity-lock fixture could not be restored after the drift test"
[[ ! -e "$REMOTE_LOCK" && ! -L "$REMOTE_LOCK" ]] \
  || fail "failed upload left its owned release-directory lock behind"
/bin/rm -f "$AGENT_ISLAND_TEST_ALTOOL_LOG"

UPLOAD_OUTPUT="$TEST_ROOT/upload-valid.txt"
DEVELOPER_DIR="$FAKE_DEVELOPER" \
  AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
  AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
  AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="$UPLOAD_CONFIRMATION" \
  "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" >"$UPLOAD_OUTPUT" 2>&1 \
  || fail "synthetic deliberate upload failed: $(/bin/cat "$UPLOAD_OUTPUT")"
contains 'Upload accepted by altool:' "$UPLOAD_OUTPUT"
contains 'Upload acceptance is not processing completion.' "$UPLOAD_OUTPUT"
contains '--validate-app' "$AGENT_ISLAND_TEST_ALTOOL_LOG"
contains '--upload-app' "$AGENT_ISLAND_TEST_ALTOOL_LOG"
contains '--type macos' "$AGENT_ISLAND_TEST_ALTOOL_LOG"
contains 'AgentIslandMac-upload.pkg' "$AGENT_ISLAND_TEST_ALTOOL_LOG"
if /usr/bin/grep -Fq -- "--file $PACKAGE_PATH" "$AGENT_ISLAND_TEST_ALTOOL_LOG"; then
  fail "altool reopened the mutable public package instead of the private snapshot"
fi

delivery_records=("$RELEASE_DIRECTORY"/mac-app-store-delivery-*.json(.N))
validation_results=("$RELEASE_DIRECTORY"/mac-app-store-validation-*.json(.N))
upload_results=("$RELEASE_DIRECTORY"/mac-app-store-upload-*.json(.N))
(( ${#delivery_records} == 1 && ${#validation_results} == 1 && \
  ${#upload_results} == 1 )) || fail "upload did not create one complete evidence set"
DELIVERY_RECORD="${delivery_records[1]}"
VALIDATION_RESULT="${validation_results[1]}"
UPLOAD_RESULT="${upload_results[1]}"
for immutable_file in "$DELIVERY_RECORD" "$VALIDATION_RESULT" "$UPLOAD_RESULT"; do
  [[ "$(/usr/bin/stat -f '%Lp' "$immutable_file")" == "444" ]] \
    || fail "${immutable_file:t} is not read-only"
done
/usr/bin/jq -e \
  --arg package "$PACKAGE_PATH" \
  --arg sha "$PACKAGE_SHA256" '
    .packagePath == $package and .packageSHA256 == $sha and
    .uploadAccepted == true and .processingState == null and
    .processingVerified == false and .warningsReviewed == false and
    .submittedForAppReview == false
  ' "$DELIVERY_RECORD" >/dev/null || fail "delivery record overstates upload state"
/usr/bin/jq -e '.uploaded == false' "$METADATA_PATH" >/dev/null \
  || fail "upload mutated local release metadata"

DELIVERY_VERIFY_OUTPUT="$TEST_ROOT/verify-delivery.txt"
"$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
  >"$DELIVERY_VERIFY_OUTPUT" 2>&1 \
  || fail "independent delivery verification failed: $(/bin/cat "$DELIVERY_VERIFY_OUTPUT")"
contains 'Mac App Store delivery evidence verified.' "$DELIVERY_VERIFY_OUTPUT"
contains 'Upload accepted; processing is not yet verified; App Review not submitted.' \
  "$DELIVERY_VERIFY_OUTPUT"

DELIVERY_RECORD_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$DELIVERY_RECORD" | /usr/bin/awk '{print $1}')"
METADATA_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$METADATA_PATH" | /usr/bin/awk '{print $1}')"
VALIDATION_RESULT_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$VALIDATION_RESULT" | /usr/bin/awk '{print $1}')"
UPLOAD_RESULT_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$UPLOAD_RESULT" | /usr/bin/awk '{print $1}')"
DELIVERY_VERIFY_JSON="$TEST_ROOT/verify-delivery.json"
"$INSTRUMENTED_DELIVERY_VERIFY" --json "$DELIVERY_RECORD" \
  >"$DELIVERY_VERIFY_JSON" \
  || fail "machine-readable delivery verification failed"
/usr/bin/jq -e \
  --arg delivery "$DELIVERY_RECORD" --arg deliverySHA "$DELIVERY_RECORD_SHA256" \
  --arg metadata "$METADATA_PATH" --arg metadataSHA "$METADATA_SHA256" \
  --arg archive "$ARCHIVE_ZIP_PATH" --arg archiveSHA "$ARCHIVE_SHA256" \
  --arg package "$PACKAGE_PATH" --arg packageSHA "$PACKAGE_SHA256" \
  --arg validation "$VALIDATION_RESULT" --arg validationSHA "$VALIDATION_RESULT_SHA256" \
  --arg upload "$UPLOAD_RESULT" --arg uploadSHA "$UPLOAD_RESULT_SHA256" \
  --arg bundle "$APP_BUNDLE_ID" --arg version "$VERSION" --arg build "$BUILD_NUMBER" '
    .schemaVersion == 1 and .platform == "macOS" and
    .evidenceVerified == true and .uploadAccepted == true and
    .evidencePath == $delivery and .evidenceSHA256 == $deliverySHA and
    .deliveryRecordPath == $delivery and .deliveryRecordSHA256 == $deliverySHA and
    .releaseMetadataPath == $metadata and .releaseMetadataSHA256 == $metadataSHA and
    .archiveZipPath == $archive and .archiveZipSHA256 == $archiveSHA and
    .packagePath == $package and .packageSHA256 == $packageSHA and
    .validationResultPath == $validation and .validationResultSHA256 == $validationSHA and
    .uploadResultPath == $upload and .uploadResultSHA256 == $uploadSHA and
    .appBundleID == $bundle and .version == $version and .build == $build and
    .processingState == null and .processingVerified == false and
    .submittedForAppReview == false
  ' "$DELIVERY_VERIFY_JSON" >/dev/null \
  || fail "machine-readable delivery result is incomplete or overstates remote state"

/bin/cp "$DELIVERY_RECORD" "$TEST_ROOT/valid-delivery-record.json"
/bin/cp "$VALIDATION_RESULT" "$TEST_ROOT/valid-validation-result.json"
/bin/cp "$UPLOAD_RESULT" "$TEST_ROOT/valid-upload-result.json"

expect_synchronized_error_result_rejected() {
  local result_path="$1"
  local sha_field="$2"
  local operation="$3"
  local error_key="$4"
  local output="$TEST_ROOT/synchronized-$operation-error-result.txt"
  local error_sha256

  /bin/chmod 0644 "$result_path" "$DELIVERY_RECORD"
  if [[ "$error_key" == "product-errors" ]]; then
    print -r -- '{"success-message":"synthetic apparent success","product-errors":[{"message":"synthetic synchronized rejection"}]}' \
      >"$result_path"
  else
    print -r -- '{"success-message":"synthetic apparent success","errors":[{"message":"synthetic synchronized rejection"}]}' \
      >"$result_path"
  fi
  error_sha256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$result_path" \
    | /usr/bin/awk '{print $1}')"
  /usr/bin/jq --arg key "$sha_field" --arg sha "$error_sha256" \
    '.[$key] = $sha' "$DELIVERY_RECORD" \
    >"$TEST_ROOT/synchronized-$operation-delivery.json"
  /bin/mv "$TEST_ROOT/synchronized-$operation-delivery.json" "$DELIVERY_RECORD"
  /bin/chmod 0444 "$result_path" "$DELIVERY_RECORD"

  if "$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
      >"$output" 2>&1; then
    fail "delivery verifier accepted synchronized $operation error JSON"
  fi
  contains "App Store Connect $operation result does not contain an unambiguous altool success response" \
    "$output"

  /bin/chmod 0644 "$result_path" "$DELIVERY_RECORD"
  /bin/cp "$TEST_ROOT/valid-$operation-result.json" "$result_path"
  /bin/cp "$TEST_ROOT/valid-delivery-record.json" "$DELIVERY_RECORD"
  /bin/chmod 0444 "$result_path" "$DELIVERY_RECORD"
}

expect_synchronized_error_result_rejected \
  "$VALIDATION_RESULT" validationResultSHA256 validation product-errors
expect_synchronized_error_result_rejected \
  "$UPLOAD_RESULT" uploadResultSHA256 upload errors

/bin/ln -s "$RELEASE_DIRECTORY" "$TEST_ROOT/release-parent-link"
SYMLINK_INPUT_OUTPUT="$TEST_ROOT/symlink-delivery-input.txt"
if "$INSTRUMENTED_DELIVERY_VERIFY" --check \
    "$TEST_ROOT/release-parent-link/${DELIVERY_RECORD:t}" \
    >"$SYMLINK_INPUT_OUTPUT" 2>&1; then
  fail "independent delivery verifier accepted an input through a symlink parent"
fi
contains 'delivery record path must not traverse symlink parents' \
  "$SYMLINK_INPUT_OUTPUT"
/bin/rm "$TEST_ROOT/release-parent-link"

/bin/ln -s "$RELEASE_DIRECTORY" "$RELEASE_DIRECTORY/candidate-parent-link"
/bin/chmod 0644 "$DELIVERY_RECORD"
/usr/bin/jq --arg package \
  "$RELEASE_DIRECTORY/candidate-parent-link/export/AgentIslandMac.pkg" \
  '.packagePath = $package' "$DELIVERY_RECORD" \
  >"$TEST_ROOT/symlink-delivery-record.json"
/bin/mv "$TEST_ROOT/symlink-delivery-record.json" "$DELIVERY_RECORD"
/bin/chmod 0444 "$DELIVERY_RECORD"
SYMLINK_ARTIFACT_OUTPUT="$TEST_ROOT/symlink-delivery-artifact.txt"
if "$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
    >"$SYMLINK_ARTIFACT_OUTPUT" 2>&1; then
  fail "independent delivery verifier accepted an artifact through a symlink parent"
fi
contains 'App Store package path must already be canonical' \
  "$SYMLINK_ARTIFACT_OUTPUT"
/bin/chmod 0644 "$DELIVERY_RECORD"
/bin/cp "$TEST_ROOT/valid-delivery-record.json" "$DELIVERY_RECORD"
/bin/chmod 0444 "$DELIVERY_RECORD"
/bin/rm "$RELEASE_DIRECTORY/candidate-parent-link"

/bin/chmod 0644 "$DELIVERY_RECORD"
/usr/bin/jq '.submittedAt = "2099-01-01T00:00:00Z"' "$DELIVERY_RECORD" \
  >"$TEST_ROOT/future-delivery-record.json"
/bin/mv "$TEST_ROOT/future-delivery-record.json" "$DELIVERY_RECORD"
/bin/chmod 0444 "$DELIVERY_RECORD"
FUTURE_DELIVERY_OUTPUT="$TEST_ROOT/future-delivery.txt"
if "$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
    >"$FUTURE_DELIVERY_OUTPUT" 2>&1; then
  fail "independent verifier accepted an out-of-order delivery timestamp"
fi
contains 'release and delivery timestamps are out of order' "$FUTURE_DELIVERY_OUTPUT"
/bin/chmod 0644 "$DELIVERY_RECORD"
/bin/cp "$TEST_ROOT/valid-delivery-record.json" "$DELIVERY_RECORD"
/bin/chmod 0444 "$DELIVERY_RECORD"

UPLOAD_COUNT_BEFORE="${#upload_results}"
DELIVERY_COUNT_BEFORE="${#delivery_records}"
/bin/sleep 1
FAILED_UPLOAD_OUTPUT="$TEST_ROOT/failed-upload.txt"
if DEVELOPER_DIR="$FAKE_DEVELOPER" \
    AGENT_ISLAND_ASC_API_KEY_ID="$API_KEY_ID" \
    AGENT_ISLAND_ASC_API_ISSUER_ID="$API_ISSUER_ID" \
    AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="$UPLOAD_CONFIRMATION" \
    AGENT_ISLAND_TEST_ALTOOL_FAIL_MODE=upload \
    "$INSTRUMENTED_SUBMIT" --upload "$RELEASE_DIRECTORY" \
      >"$FAILED_UPLOAD_OUTPUT" 2>&1; then
  fail "failed altool upload unexpectedly succeeded"
fi
upload_results_after_failure=("$RELEASE_DIRECTORY"/mac-app-store-upload-*.json(.N))
delivery_records_after_failure=("$RELEASE_DIRECTORY"/mac-app-store-delivery-*.json(.N))
temporary_results_after_failure=("$RELEASE_DIRECTORY"/.mac-app-store-*(.N))
(( ${#upload_results_after_failure} == UPLOAD_COUNT_BEFORE && \
  ${#delivery_records_after_failure} == DELIVERY_COUNT_BEFORE && \
  ${#temporary_results_after_failure} == 0 )) \
  || fail "failed altool upload published or leaked upload evidence"

PROCESSING_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
ASC_BUILD_ID="123456789042"
PROCESS_CONFIRMATION="$APP_BUNDLE_ID:$VERSION:$BUILD_NUMBER:$PACKAGE_SHA256:$ASC_BUILD_ID"

/bin/chmod 0644 "$DELIVERY_RECORD"
WRITABLE_DELIVERY_OUTPUT="$TEST_ROOT/writable-delivery.txt"
if "$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
    >"$WRITABLE_DELIVERY_OUTPUT" 2>&1; then
  fail "independent verifier accepted a writable delivery record"
fi
contains 'delivery record must be read-only' "$WRITABLE_DELIVERY_OUTPUT"
if AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING="$PROCESS_CONFIRMATION" \
    "$INSTRUMENTED_CONFIRM" \
      --processing-state Complete \
      --app-store-connect-build-id "$ASC_BUILD_ID" \
      --processing-verified-at "$PROCESSING_AT" \
      --warnings-reviewed \
      "$DELIVERY_RECORD" >"$WRITABLE_DELIVERY_OUTPUT" 2>&1; then
  fail "processing evidence accepted a writable delivery record"
fi
contains 'delivery record must be read-only' "$WRITABLE_DELIVERY_OUTPUT"
/bin/chmod 0444 "$DELIVERY_RECORD"

PLACEHOLDER_BUILD_OUTPUT="$TEST_ROOT/placeholder-build-id.txt"
if "$INSTRUMENTED_CONFIRM" \
    --processing-state Complete \
    --app-store-connect-build-id 'BUILD-ID-PLACEHOLDER' \
    --processing-verified-at "$PROCESSING_AT" \
    --warnings-reviewed \
    "$DELIVERY_RECORD" >"$PLACEHOLDER_BUILD_OUTPUT" 2>&1; then
  fail "processing evidence accepted a placeholder Build ID"
fi
contains 'build-id is still a placeholder' "$PLACEHOLDER_BUILD_OUTPUT"

MISSING_WARNINGS_OUTPUT="$TEST_ROOT/missing-warnings.txt"
if "$INSTRUMENTED_CONFIRM" \
    --processing-state Complete \
    --app-store-connect-build-id "$ASC_BUILD_ID" \
    --processing-verified-at "$PROCESSING_AT" \
    "$DELIVERY_RECORD" >"$MISSING_WARNINGS_OUTPUT" 2>&1; then
  fail "processing evidence omitted warning review"
fi
contains '--warnings-reviewed is required' "$MISSING_WARNINGS_OUTPUT"

PROCESSING_STATE_OUTPUT="$TEST_ROOT/wrong-processing-state.txt"
if "$INSTRUMENTED_CONFIRM" \
    --processing-state Processing \
    --app-store-connect-build-id "$ASC_BUILD_ID" \
    --processing-verified-at "$PROCESSING_AT" \
    --warnings-reviewed \
    "$DELIVERY_RECORD" >"$PROCESSING_STATE_OUTPUT" 2>&1; then
  fail "processing evidence accepted a non-Complete state"
fi
contains '--processing-state must be exactly Complete' "$PROCESSING_STATE_OUTPUT"

/bin/chmod 0644 "$UPLOAD_RESULT"
print -n -r -- 'tamper' >>"$UPLOAD_RESULT"
/bin/chmod 0444 "$UPLOAD_RESULT"
TAMPERED_DELIVERY_OUTPUT="$TEST_ROOT/tampered-delivery-upload-result.txt"
if "$INSTRUMENTED_DELIVERY_VERIFY" --check "$DELIVERY_RECORD" \
    >"$TAMPERED_DELIVERY_OUTPUT" 2>&1; then
  fail "independent verifier accepted a tampered upload result"
fi
contains 'upload result differs from delivery record' "$TAMPERED_DELIVERY_OUTPUT"
TAMPERED_RESULT_OUTPUT="$TEST_ROOT/tampered-upload-result.txt"
if AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING="$PROCESS_CONFIRMATION" \
    "$INSTRUMENTED_CONFIRM" \
      --processing-state Complete \
      --app-store-connect-build-id "$ASC_BUILD_ID" \
      --processing-verified-at "$PROCESSING_AT" \
      --warnings-reviewed \
      "$DELIVERY_RECORD" >"$TAMPERED_RESULT_OUTPUT" 2>&1; then
  fail "processing evidence accepted a tampered upload result"
fi
contains 'current upload result differs from the delivery record' "$TAMPERED_RESULT_OUTPUT"
/bin/chmod 0644 "$UPLOAD_RESULT"
/bin/cp "$TEST_ROOT/valid-upload-result.json" "$UPLOAD_RESULT"
/bin/chmod 0444 "$UPLOAD_RESULT"

WRONG_PROCESS_CONFIRM_OUTPUT="$TEST_ROOT/wrong-processing-confirmation.txt"
if AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING='wrong-processed-build' \
    "$INSTRUMENTED_CONFIRM" \
      --processing-state Complete \
      --app-store-connect-build-id "$ASC_BUILD_ID" \
      --processing-verified-at "$PROCESSING_AT" \
      --warnings-reviewed \
      "$DELIVERY_RECORD" >"$WRONG_PROCESS_CONFIRM_OUTPUT" 2>&1; then
  fail "processing evidence accepted the wrong exact-build confirmation"
fi
contains 'does not match this exact processed build' "$WRONG_PROCESS_CONFIRM_OUTPUT"

PROCESS_OUTPUT="$TEST_ROOT/processing-valid.txt"
AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING="$PROCESS_CONFIRMATION" \
  "$INSTRUMENTED_CONFIRM" \
    --processing-state Complete \
    --app-store-connect-build-id "$ASC_BUILD_ID" \
    --processing-verified-at "$PROCESSING_AT" \
    --warnings-reviewed \
    "$DELIVERY_RECORD" >"$PROCESS_OUTPUT" 2>&1 \
  || fail "valid processing evidence failed: $(/bin/cat "$PROCESS_OUTPUT")"
contains 'Mac App Store processing evidence recorded:' "$PROCESS_OUTPUT"
contains 'does not re-query Apple or submit the build for App Review' "$PROCESS_OUTPUT"

processing_evidence=(
  "$RELEASE_DIRECTORY"/mac-app-store-processing-verification-*.json(.N)
)
(( ${#processing_evidence} == 1 )) \
  || fail "processing confirmation did not create exactly one evidence file"
EVIDENCE_PATH="${processing_evidence[1]}"
[[ "$(/usr/bin/stat -f '%Lp' "$EVIDENCE_PATH")" == "444" ]] \
  || fail "processing evidence is not read-only"
/usr/bin/jq -e \
  --arg package "$PACKAGE_PATH" \
  --arg sha "$PACKAGE_SHA256" \
  --arg buildID "$ASC_BUILD_ID" '
    .packagePath == $package and .packageSHA256 == $sha and
    .appStoreConnectBuildID == $buildID and
    .uploadAccepted == true and .processingState == "Complete" and
    .processingVerified == true and .warningsReviewed == true and
    .submittedForAppReview == false
  ' "$EVIDENCE_PATH" >/dev/null \
  || fail "processing evidence does not bind the exact completed package"

VERIFY_JSON="$TEST_ROOT/verify-evidence.json"
"$INSTRUMENTED_VERIFY" --json "$EVIDENCE_PATH" >"$VERIFY_JSON" \
  || fail "independent evidence verification failed"
EVIDENCE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$EVIDENCE_PATH" | /usr/bin/awk '{print $1}')"
/usr/bin/jq -e -s \
  --arg evidence "$EVIDENCE_PATH" --arg evidenceSHA "$EVIDENCE_SHA256" \
  --arg buildID "$ASC_BUILD_ID" '
    .[0] as $delivery | .[1] as $processing |
    $processing.schemaVersion == 1 and $processing.platform == "macOS" and
    $processing.evidenceVerified == true and
    $processing.deliveryEvidenceVerified == true and
    $processing.evidencePath == $evidence and
    $processing.evidenceSHA256 == $evidenceSHA and
    $processing.deliveryRecordPath == $delivery.deliveryRecordPath and
    $processing.deliveryRecordSHA256 == $delivery.deliveryRecordSHA256 and
    $processing.releaseMetadataPath == $delivery.releaseMetadataPath and
    $processing.releaseMetadataSHA256 == $delivery.releaseMetadataSHA256 and
    $processing.archiveZipPath == $delivery.archiveZipPath and
    $processing.archiveZipSHA256 == $delivery.archiveZipSHA256 and
    $processing.packagePath == $delivery.packagePath and
    $processing.packageSHA256 == $delivery.packageSHA256 and
    $processing.validationResultPath == $delivery.validationResultPath and
    $processing.validationResultSHA256 == $delivery.validationResultSHA256 and
    $processing.uploadResultPath == $delivery.uploadResultPath and
    $processing.uploadResultSHA256 == $delivery.uploadResultSHA256 and
    $processing.appBundleID == $delivery.appBundleID and
    $processing.version == $delivery.version and
    $processing.build == $delivery.build and
    $processing.submittedAt == $delivery.submittedAt and
    $processing.appStoreConnectBuildID == $buildID and
    $processing.uploadAccepted == true and
    $processing.processingState == "Complete" and
    $processing.processingVerified == true and
    $processing.warningsReviewed == true and
    $processing.submittedForAppReview == false
  ' "$DELIVERY_VERIFY_JSON" "$VERIFY_JSON" >/dev/null \
  || fail "machine-readable processing result does not cross-bind the delivery chain"

/bin/ln -s "$RELEASE_DIRECTORY" "$TEST_ROOT/processing-parent-link"
SYMLINK_PROCESSING_INPUT_OUTPUT="$TEST_ROOT/symlink-processing-input.txt"
if "$INSTRUMENTED_VERIFY" --check \
    "$TEST_ROOT/processing-parent-link/${EVIDENCE_PATH:t}" \
    >"$SYMLINK_PROCESSING_INPUT_OUTPUT" 2>&1; then
  fail "processing verifier accepted evidence through a symlink parent"
fi
contains 'processing evidence path must not traverse symlink parents' \
  "$SYMLINK_PROCESSING_INPUT_OUTPUT"
/bin/rm "$TEST_ROOT/processing-parent-link"

/bin/cp "$EVIDENCE_PATH" "$TEST_ROOT/valid-processing-evidence.json"
/bin/ln -s "$RELEASE_DIRECTORY" "$RELEASE_DIRECTORY/candidate-parent-link"
/bin/chmod 0644 "$EVIDENCE_PATH"
/usr/bin/jq --arg package \
  "$RELEASE_DIRECTORY/candidate-parent-link/export/AgentIslandMac.pkg" \
  '.packagePath = $package' "$EVIDENCE_PATH" \
  >"$TEST_ROOT/symlink-processing-evidence.json"
/bin/mv "$TEST_ROOT/symlink-processing-evidence.json" "$EVIDENCE_PATH"
/bin/chmod 0444 "$EVIDENCE_PATH"
SYMLINK_PROCESSING_ARTIFACT_OUTPUT="$TEST_ROOT/symlink-processing-artifact.txt"
if "$INSTRUMENTED_VERIFY" --check "$EVIDENCE_PATH" \
    >"$SYMLINK_PROCESSING_ARTIFACT_OUTPUT" 2>&1; then
  fail "processing verifier accepted an artifact through a symlink parent"
fi
contains 'App Store package path must already be canonical' \
  "$SYMLINK_PROCESSING_ARTIFACT_OUTPUT"
/bin/chmod 0644 "$EVIDENCE_PATH"
/bin/cp "$TEST_ROOT/valid-processing-evidence.json" "$EVIDENCE_PATH"
/bin/chmod 0444 "$EVIDENCE_PATH"
/bin/rm "$RELEASE_DIRECTORY/candidate-parent-link"

/bin/chmod 0644 "$EVIDENCE_PATH"
WRITABLE_EVIDENCE_OUTPUT="$TEST_ROOT/writable-evidence.txt"
if "$INSTRUMENTED_VERIFY" --check "$EVIDENCE_PATH" \
    >"$WRITABLE_EVIDENCE_OUTPUT" 2>&1; then
  fail "independent verifier accepted writable processing evidence"
fi
contains 'processing evidence must be read-only' "$WRITABLE_EVIDENCE_OUTPUT"
/bin/chmod 0444 "$EVIDENCE_PATH"

print -r -- "macOS App Store exact-package delivery and processing-evidence tests passed"
