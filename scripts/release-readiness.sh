#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

PROJECT_DIR="${0:A:h:h}"
READINESS_ROOT="$(mktemp -d /private/tmp/agentisland-readiness.XXXXXX)"
trap '[[ "$READINESS_ROOT" == /private/tmp/agentisland-readiness.* ]] && /bin/rm -rf "$READINESS_ROOT"' EXIT HUP INT TERM
DEVELOPER_PATH="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
FULL_XCODE=false
[[ "$DEVELOPER_PATH" == */Xcode.app/Contents/Developer ]] && FULL_XCODE=true

valid_bundle_id() {
  local value="$1"
  [[ "$value" == [A-Za-z0-9.-]## && "$value" == *.* && "$value" != *..* && "$value" != .* && "$value" != *. ]]
}

production_bundle_id() {
  local value="$1"
  local normalized="${value:l}"
  valid_bundle_id "$value" || return 1
  [[ "$normalized" != local.* && "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *yourdomain* && "$normalized" != *placeholder* ]]
}

production_https_url() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == https://* && "$value" != *[[:space:]]* && \
    "$normalized" != *localhost* && "$normalized" != *127.0.0.1* && \
    "$normalized" != *example* && "$normalized" != *placeholder* && \
    "$normalized" != *yourdomain* && "$normalized" != *.invalid/* && "$normalized" != *.test/* ]]
}

production_team_id() {
  [[ "$1" == [A-Z0-9]## && ${#1} -eq 10 && "${1:l}" != *placeholder* ]]
}

production_display_name() {
  local value="$1"
  local comparison
  (( ${#value} >= 2 && ${#value} <= 30 )) || return 1
  [[ "$value" != [[:space:]]* && "$value" != *[[:space:]] && "$value" != *[[:cntrl:]]* ]] || return 1
  comparison="$(print -rn -- "$value" | /usr/bin/tr -cd '[:alnum:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$comparison" != "agentisland" && "$comparison" != "tasklume" ]]
}

production_container_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ "$value" == iCloud.* && "$normalized" != *example* && "$normalized" != *yourname* && \
    "$normalized" != *placeholder* ]]
}

IOS_XCCONFIG_PATH="$PROJECT_DIR/ApplePlatforms/iOS/Config/Project.xcconfig"
xcconfig_value() {
  local key="$1"
  [[ -f "$IOS_XCCONFIG_PATH" ]] || return 0
  /usr/bin/awk -v key="$key" '
    $1 == key && $2 == "=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*\/\/.*$/, "")
      gsub(/\$\(AGENT_ISLAND_URL_SLASH\)/, "/")
      print
      exit
    }
  ' "$IOS_XCCONFIG_PATH"
}

XCODE_VERSION=""
XCODE_MAJOR=0
IPHONE_SDK=""
IPHONE_SDK_MAJOR=0
if [[ "$FULL_XCODE" == true ]]; then
  XCODE_VERSION="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/awk '/^Xcode / {print $2; exit}')"
  [[ "$XCODE_VERSION" == <->* ]] && XCODE_MAJOR="${XCODE_VERSION%%.*}"
  IPHONE_SDK="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  [[ "$IPHONE_SDK" == <->* ]] && IPHONE_SDK_MAJOR="${IPHONE_SDK%%.*}"
fi

IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
VALID_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec '^[[:space:]]*[0-9]+\)' || true)"
DEVELOPER_ID_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -c 'Developer ID Application:' || true)"
APPLE_DEVELOPMENT_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec 'Apple Development:|iPhone Developer:' || true)"
APPLE_DISTRIBUTION_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Ec 'Apple Distribution:|iPhone Distribution:' || true)"

AVAILABLE_KIB="$(/bin/df -k /Applications | /usr/bin/awk 'NR==2 {print $4}')"
AVAILABLE_GIB="$(( AVAILABLE_KIB / 1024 / 1024 ))"

typeset -a AMBIGUOUS_MAC_ARCHIVE_NAMES
AMBIGUOUS_MAC_ARCHIVE_NAMES=()
CANONICAL_MAC_ARCHIVE="$PROJECT_DIR/dist/AgentIsland-macOS-universal.zip"
for ARCHIVE_CANDIDATE in "$PROJECT_DIR"/dist/AgentIsland-macOS-universal*.zip(N); do
  [[ "$ARCHIVE_CANDIDATE" == "$CANONICAL_MAC_ARCHIVE" ]] || AMBIGUOUS_MAC_ARCHIVE_NAMES+=("${ARCHIVE_CANDIDATE:t}")
done
MAC_ARCHIVE_SET_CLEAN=false
AMBIGUOUS_MAC_ARCHIVES_JSON="[]"
if (( ${#AMBIGUOUS_MAC_ARCHIVE_NAMES[@]} == 0 )); then
  MAC_ARCHIVE_SET_CLEAN=true
else
  AMBIGUOUS_MAC_ARCHIVES_JSON="$(print -rl -- "${AMBIGUOUS_MAC_ARCHIVE_NAMES[@]}" | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
fi

MAC_BUNDLE_ID="${AGENT_ISLAND_BUNDLE_ID:-}"
MAC_SIGN_IDENTITY="${AGENT_ISLAND_DEVELOPER_ID_APPLICATION:-}"
DISPLAY_NAME="${AGENT_ISLAND_DISPLAY_NAME:-}"
IOS_APP_BUNDLE_ID="${AGENT_ISLAND_IOS_BUNDLE_ID:-$(xcconfig_value AGENT_ISLAND_APP_BUNDLE_ID)}"
IOS_WIDGET_BUNDLE_ID="${AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID:-$(xcconfig_value AGENT_ISLAND_WIDGET_BUNDLE_ID)}"
[[ "$IOS_WIDGET_BUNDLE_ID" == '$('* ]] && IOS_WIDGET_BUNDLE_ID="$IOS_APP_BUNDLE_ID.liveactivity"
NOTARY_PROFILE="${AGENT_ISLAND_NOTARY_KEYCHAIN_PROFILE:-}"
ENTITLEMENTS_PATH="${AGENT_ISLAND_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${AGENT_ISLAND_PROVISIONING_PROFILE:-}"
RELEASE_PRIVACY_URL="${AGENT_ISLAND_PRIVACY_POLICY_URL:-}"
RELEASE_SUPPORT_URL="${AGENT_ISLAND_SUPPORT_URL:-}"
IOS_PRIVACY_URL="${AGENT_ISLAND_PRIVACY_POLICY_URL:-$(xcconfig_value AGENT_ISLAND_PRIVACY_POLICY_URL)}"
IOS_SUPPORT_URL="${AGENT_ISLAND_SUPPORT_URL:-$(xcconfig_value AGENT_ISLAND_SUPPORT_URL)}"
IOS_TEAM_ID="${AGENT_ISLAND_DEVELOPMENT_TEAM:-$(xcconfig_value AGENT_ISLAND_DEVELOPMENT_TEAM)}"
CLOUDKIT_CONTAINER_ID="${AGENT_ISLAND_ICLOUD_CONTAINER_ID:-$(xcconfig_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)}"
IOS_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID"

MAC_BUNDLE_READY=false
IOS_APP_BUNDLE_READY=false
IOS_WIDGET_BUNDLE_READY=false
ENTITLEMENTS_READY=false
PROVISIONING_PROFILE_READY=false
PROVISIONING_PROFILE_CERTIFICATE_READY=false
SOURCE_APP_IDENTIFIER=""
CLOUDKIT_CONTAINER_READY=false
RELEASE_PRIVACY_READY=false
RELEASE_SUPPORT_READY=false
IOS_TEAM_READY=false
MAC_SIGN_IDENTITY_READY=false
DISPLAY_NAME_READY=false
IOS_CONTAINER_READY=false
IOS_PRIVACY_READY=false
IOS_SUPPORT_READY=false
production_bundle_id "$MAC_BUNDLE_ID" && MAC_BUNDLE_READY=true
production_display_name "$DISPLAY_NAME" && DISPLAY_NAME_READY=true
production_bundle_id "$IOS_APP_BUNDLE_ID" && IOS_APP_BUNDLE_READY=true
if production_bundle_id "$IOS_WIDGET_BUNDLE_ID" && [[ "$IOS_WIDGET_BUNDLE_ID" == "$IOS_APP_BUNDLE_ID".* ]]; then
  IOS_WIDGET_BUNDLE_READY=true
fi
production_container_id "$CLOUDKIT_CONTAINER_ID" && CLOUDKIT_CONTAINER_READY=true
if [[ "$CLOUDKIT_CONTAINER_READY" == true && -f "$ENTITLEMENTS_PATH" ]] && /usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null 2>&1 && \
    ! /usr/bin/grep -Eqi 'yourname|yourdomain|example|placeholder' "$ENTITLEMENTS_PATH"; then
  ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - "$ENTITLEMENTS_PATH" 2>/dev/null || print '{}')"
  if print -r -- "$ENTITLEMENTS_JSON" | /usr/bin/jq -e \
      --arg container "$CLOUDKIT_CONTAINER_ID" --arg bundle "$MAC_BUNDLE_ID" --arg team "$IOS_TEAM_ID" '
      (."com.apple.application-identifier" | type == "string" and endswith("." + $bundle)) and
      (."com.apple.developer.team-identifier" == $team) and
      ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
      ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
      (."com.apple.developer.icloud-container-environment" == "Production") and
      ((."com.apple.security.get-task-allow" // false) == false)
    ' >/dev/null 2>&1; then
    ENTITLEMENTS_READY=true
    SOURCE_APP_IDENTIFIER="$(print -r -- "$ENTITLEMENTS_JSON" | /usr/bin/jq -r '."com.apple.application-identifier"')"
  fi
fi
if [[ "$ENTITLEMENTS_READY" == true && -f "$PROVISIONING_PROFILE" ]]; then
  PROFILE_PLIST="$READINESS_ROOT/provisioning-profile.plist"
  if /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST" >/dev/null 2>&1 && \
      /usr/bin/plutil -lint "$PROFILE_PLIST" >/dev/null 2>&1; then
    PROFILE_ENTITLEMENTS_PLIST="$READINESS_ROOT/provisioning-profile-entitlements.plist"
    PROFILE_ENTITLEMENTS_JSON="$READINESS_ROOT/provisioning-profile-entitlements.json"
    if /usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST" >/dev/null 2>&1 && \
        /usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON" "$PROFILE_ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
      PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
      PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
      if /usr/bin/jq -e \
          --arg container "$CLOUDKIT_CONTAINER_ID" --arg sourceAppIdentifier "$SOURCE_APP_IDENTIFIER" --arg team "$IOS_TEAM_ID" '
          (."com.apple.application-identifier" == $sourceAppIdentifier) and
          (."com.apple.developer.team-identifier" == $team) and
          ((."com.apple.developer.icloud-services" // []) | index("CloudKit") != null) and
          ((."com.apple.developer.icloud-container-identifiers" // []) == [$container]) and
          (."com.apple.developer.icloud-container-environment" == "Production") and
          ((."com.apple.security.get-task-allow" // false) == false)
        ' "$PROFILE_ENTITLEMENTS_JSON" >/dev/null 2>&1 && \
          [[ "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TEAM" == "$IOS_TEAM_ID" && \
            "$PROFILE_PLATFORM_COUNT" == "1" && "$PROFILE_PLATFORM" == "OSX" && \
            "$PROFILE_CERTIFICATE_COUNT" == <-> && "$PROFILE_CERTIFICATE_COUNT" -gt 0 && \
            "$PROFILE_PROVISIONS_ALL_DEVICES" == "true" && "$PROFILE_EXPIRATION_EPOCH" == <-> && \
            "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]]; then
        PROVISIONING_PROFILE_READY=true
      fi
    fi
  fi
fi

# A profile can match the Team/App ID yet authorize a different Developer ID
# certificate. Gatekeeper evaluates Developer ID profiles at launch, so report
# that certificate binding separately rather than claiming release readiness.
CONFIGURED_IDENTITY_MATCH_COUNT="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$MAC_SIGN_IDENTITY\"" || true)"
CONFIGURED_IDENTITY_SHA1=""
if [[ "$CONFIGURED_IDENTITY_MATCH_COUNT" == "1" ]]; then
  CONFIGURED_IDENTITY_SHA1="$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -F "\"$MAC_SIGN_IDENTITY\"" | /usr/bin/awk '{print toupper($2); exit}')"
fi
if [[ "$PROVISIONING_PROFILE_READY" == true && "$CONFIGURED_IDENTITY_SHA1" == [0-9A-F]## && ${#CONFIGURED_IDENTITY_SHA1} -eq 40 ]]; then
  for (( PROFILE_CERTIFICATE_INDEX = 0; PROFILE_CERTIFICATE_INDEX < PROFILE_CERTIFICATE_COUNT; PROFILE_CERTIFICATE_INDEX++ )); do
    PROFILE_CERTIFICATE_PATH="$READINESS_ROOT/profile-certificate-$PROFILE_CERTIFICATE_INDEX.cer"
    PROFILE_CERTIFICATE_BASE64="$(/usr/bin/plutil -extract "DeveloperCertificates.$PROFILE_CERTIFICATE_INDEX" raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    if [[ -n "$PROFILE_CERTIFICATE_BASE64" ]] && print -rn -- "$PROFILE_CERTIFICATE_BASE64" | /usr/bin/base64 -D >"$PROFILE_CERTIFICATE_PATH" 2>/dev/null; then
      PROFILE_CERTIFICATE_SHA1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 "$PROFILE_CERTIFICATE_PATH" | /usr/bin/awk '{print toupper($1)}')"
      if [[ "$PROFILE_CERTIFICATE_SHA1" == "$CONFIGURED_IDENTITY_SHA1" ]]; then
        PROVISIONING_PROFILE_CERTIFICATE_READY=true
        break
      fi
    fi
  done
fi
production_https_url "$RELEASE_PRIVACY_URL" && RELEASE_PRIVACY_READY=true
production_https_url "$RELEASE_SUPPORT_URL" && RELEASE_SUPPORT_READY=true
production_team_id "$IOS_TEAM_ID" && IOS_TEAM_READY=true
if [[ "$IOS_TEAM_READY" == true && "$MAC_SIGN_IDENTITY" == "Developer ID Application:"* && \
    "$MAC_SIGN_IDENTITY" == *"($IOS_TEAM_ID)" && \
    "$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc "\"$MAC_SIGN_IDENTITY\"" || true)" == "1" ]]; then
  MAC_SIGN_IDENTITY_READY=true
fi
[[ "$CLOUDKIT_CONTAINER_READY" == true ]] && IOS_CONTAINER_READY=true
production_https_url "$IOS_PRIVACY_URL" && IOS_PRIVACY_READY=true
production_https_url "$IOS_SUPPORT_URL" && IOS_SUPPORT_READY=true

IOS_PROJECT_PATH="$PROJECT_DIR/ApplePlatforms/iOS/AgentIsland.xcodeproj/project.pbxproj"
IOS_PROJECT=false
[[ -f "$IOS_PROJECT_PATH" ]] && IOS_PROJECT=true
IOS_PRIVACY_MANIFEST=false
if [[ -f "$PROJECT_DIR/ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy" && \
    -f "$PROJECT_DIR/ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy" ]]; then
  IOS_PRIVACY_MANIFEST=true
fi
IOS_APP_ICON=false
[[ -f "$PROJECT_DIR/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/ios-marketing.png" ]] && IOS_APP_ICON=true
IOS_SYNC_IMPLEMENTED=false
if /usr/bin/grep -Rqs --include='*.swift' 'CKContainer\|CloudKitSnapshotProvider\|HTTPSAgentSnapshotProvider' \
  "$PROJECT_DIR/ApplePlatforms/iOS/App" 2>/dev/null; then
  IOS_SYNC_IMPLEMENTED=true
fi

NOTARY_PROFILE_CONFIGURED=false
[[ -n "$NOTARY_PROFILE" ]] && NOTARY_PROFILE_CONFIGURED=true
CURRENT_UPLOAD_TOOLCHAIN=false
(( XCODE_MAJOR >= 26 && IPHONE_SDK_MAJOR >= 26 )) && CURRENT_UPLOAD_TOOLCHAIN=true
ENOUGH_DISK_FOR_XCODE=false
(( AVAILABLE_GIB >= 30 )) && ENOUGH_DISK_FOR_XCODE=true

READY_DEVELOPER_ID=false
if [[ "$FULL_XCODE" == true && "$DEVELOPER_ID_IDENTITIES" -gt 0 && "$MAC_SIGN_IDENTITY_READY" == true && "$MAC_BUNDLE_READY" == true && \
  "$DISPLAY_NAME_READY" == true && "$MAC_ARCHIVE_SET_CLEAN" == true && \
  "$NOTARY_PROFILE_CONFIGURED" == true && "$ENTITLEMENTS_READY" == true && \
  "$PROVISIONING_PROFILE_READY" == true && "$PROVISIONING_PROFILE_CERTIFICATE_READY" == true && \
  "$CLOUDKIT_CONTAINER_READY" == true && "$RELEASE_PRIVACY_READY" == true && \
  "$RELEASE_SUPPORT_READY" == true && "$IOS_TEAM_READY" == true ]]; then
  READY_DEVELOPER_ID=true
fi

READY_IOS_ARCHIVE=false
if [[ "$FULL_XCODE" == true && "$CURRENT_UPLOAD_TOOLCHAIN" == true && "$APPLE_DISTRIBUTION_IDENTITIES" -gt 0 && \
  "$IOS_PROJECT" == true && "$IOS_PRIVACY_MANIFEST" == true && "$IOS_APP_ICON" == true && \
  "$IOS_APP_BUNDLE_READY" == true && "$IOS_WIDGET_BUNDLE_READY" == true && "$IOS_TEAM_READY" == true && \
  "$IOS_CONTAINER_READY" == true && "$IOS_PRIVACY_READY" == true && "$IOS_SUPPORT_READY" == true ]]; then
  READY_IOS_ARCHIVE=true
fi

/usr/bin/jq -n \
  --arg developerPath "$DEVELOPER_PATH" \
  --arg xcodeVersion "$XCODE_VERSION" \
  --arg iphoneSDK "$IPHONE_SDK" \
  --arg macBundleID "$MAC_BUNDLE_ID" \
  --arg displayName "$DISPLAY_NAME" \
  --arg iosAppBundleID "$IOS_APP_BUNDLE_ID" \
  --arg iosWidgetBundleID "$IOS_WIDGET_BUNDLE_ID" \
  --arg iosDevelopmentTeam "$IOS_TEAM_ID" \
  --arg iosCloudKitContainer "$IOS_CONTAINER_ID" \
  --argjson fullXcode "$FULL_XCODE" \
  --argjson currentUploadToolchain "$CURRENT_UPLOAD_TOOLCHAIN" \
  --argjson validIdentities "${VALID_IDENTITIES:-0}" \
  --argjson developerIDIdentities "${DEVELOPER_ID_IDENTITIES:-0}" \
  --argjson developerIDIdentityConfigured "$MAC_SIGN_IDENTITY_READY" \
  --argjson appleDevelopmentIdentities "${APPLE_DEVELOPMENT_IDENTITIES:-0}" \
  --argjson appleDistributionIdentities "${APPLE_DISTRIBUTION_IDENTITIES:-0}" \
  --argjson availableGiB "$AVAILABLE_GIB" \
  --argjson enoughDiskForXcode "$ENOUGH_DISK_FOR_XCODE" \
  --argjson macDistributionArchiveSetClean "$MAC_ARCHIVE_SET_CLEAN" \
  --argjson ambiguousMacDistributionArchives "$AMBIGUOUS_MAC_ARCHIVES_JSON" \
  --argjson productionMacBundleID "$MAC_BUNDLE_READY" \
  --argjson productionDisplayName "$DISPLAY_NAME_READY" \
  --argjson productionIOSAppBundleID "$IOS_APP_BUNDLE_READY" \
  --argjson productionIOSWidgetBundleID "$IOS_WIDGET_BUNDLE_READY" \
  --argjson notaryProfileConfigured "$NOTARY_PROFILE_CONFIGURED" \
  --argjson cloudKitEntitlementsConfigured "$ENTITLEMENTS_READY" \
  --argjson cloudKitContainerConfigured "$CLOUDKIT_CONTAINER_READY" \
  --argjson provisioningProfileConfigured "$PROVISIONING_PROFILE_READY" \
  --argjson provisioningProfileSigningCertificateConfigured "$PROVISIONING_PROFILE_CERTIFICATE_READY" \
  --argjson privacyPolicyURLConfigured "$RELEASE_PRIVACY_READY" \
  --argjson supportURLConfigured "$RELEASE_SUPPORT_READY" \
  --argjson iosDevelopmentTeamConfigured "$IOS_TEAM_READY" \
  --argjson iosCloudKitContainerConfigured "$IOS_CONTAINER_READY" \
  --argjson iosPrivacyPolicyURLConfigured "$IOS_PRIVACY_READY" \
  --argjson iosSupportURLConfigured "$IOS_SUPPORT_READY" \
  --argjson iosProject "$IOS_PROJECT" \
  --argjson iosPrivacyManifest "$IOS_PRIVACY_MANIFEST" \
  --argjson iosAppIcon "$IOS_APP_ICON" \
  --argjson iosSyncImplemented "$IOS_SYNC_IMPLEMENTED" \
  --argjson readyDeveloperID "$READY_DEVELOPER_ID" \
  --argjson readyIOSArchive "$READY_IOS_ARCHIVE" \
  '{
    fullXcode: $fullXcode,
    developerPath: $developerPath,
    xcodeVersion: (if $xcodeVersion == "" then null else $xcodeVersion end),
    iphoneSDK: (if $iphoneSDK == "" then null else $iphoneSDK end),
    currentUploadToolchain: $currentUploadToolchain,
    validSigningIdentities: $validIdentities,
    developerIDApplicationIdentities: $developerIDIdentities,
    developerIDIdentityConfigured: $developerIDIdentityConfigured,
    appleDevelopmentIdentities: $appleDevelopmentIdentities,
    appleDistributionIdentities: $appleDistributionIdentities,
    availableDiskGiB: $availableGiB,
    enoughDiskForXcode: $enoughDiskForXcode,
    macDistributionArchiveSetClean: $macDistributionArchiveSetClean,
    ambiguousMacDistributionArchives: $ambiguousMacDistributionArchives,
    productionBundleIDConfigured: $productionMacBundleID,
    productionBundleID: (if $macBundleID == "" then null else $macBundleID end),
    productionDisplayNameConfigured: $productionDisplayName,
    productionDisplayName: (if $displayName == "" then null else $displayName end),
    iosAppBundleIDConfigured: $productionIOSAppBundleID,
    iosAppBundleID: (if $iosAppBundleID == "" then null else $iosAppBundleID end),
    iosWidgetBundleIDConfigured: $productionIOSWidgetBundleID,
    iosWidgetBundleID: (if $iosWidgetBundleID == "" then null else $iosWidgetBundleID end),
    notaryProfileConfigured: $notaryProfileConfigured,
    cloudKitEntitlementsConfigured: $cloudKitEntitlementsConfigured,
    cloudKitContainerConfigured: $cloudKitContainerConfigured,
    provisioningProfileConfigured: $provisioningProfileConfigured,
    provisioningProfileSigningCertificateConfigured: $provisioningProfileSigningCertificateConfigured,
    privacyPolicyURLConfigured: $privacyPolicyURLConfigured,
    supportURLConfigured: $supportURLConfigured,
    iosDevelopmentTeamConfigured: $iosDevelopmentTeamConfigured,
    iosDevelopmentTeam: (if $iosDevelopmentTeam == "" then null else $iosDevelopmentTeam end),
    iosCloudKitContainerConfigured: $iosCloudKitContainerConfigured,
    iosCloudKitContainer: (if $iosCloudKitContainer == "" then null else $iosCloudKitContainer end),
    iosPrivacyPolicyURLConfigured: $iosPrivacyPolicyURLConfigured,
    iosSupportURLConfigured: $iosSupportURLConfigured,
    iosProjectConfigured: $iosProject,
    iosPrivacyManifestPresent: $iosPrivacyManifest,
    iosAppIconPresent: $iosAppIcon,
    iosSyncTransportImplemented: $iosSyncImplemented,
    readyForDeveloperIDRelease: $readyDeveloperID,
    readyForIOSArchive: $readyIOSArchive,
    readyForFunctionalIOSTestFlight: ($readyIOSArchive and $iosSyncImplemented and
      $iosCloudKitContainerConfigured and $iosPrivacyPolicyURLConfigured and $iosSupportURLConfigured)
  }'
