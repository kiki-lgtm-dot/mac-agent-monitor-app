#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/AgentIsland.xcodeproj/project.pbxproj"
scheme_file="$project_root/AgentIsland.xcodeproj/xcshareddata/xcschemes/AgentIslandMobile.xcscheme"
workspace_file="$project_root/AgentIsland.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
asset_manifest="$project_root/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentisland-ios-validation.XXXXXX")"
run_build=false
run_tests=false
require_release_configuration=false

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "iOS project validation failed: $*" >&2
  exit 1
}

xcconfig_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" \
    "$project_root/Config/Project.xcconfig" | tail -n 1
}

production_https_url() {
  local value="$1"
  local authority host normalized_host
  case "$value" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[[:space:]]*|*'#'*|*'$('* ) return 1 ;;
  esac
  authority="${value#https://}"
  authority="${authority%%/*}"
  case "$authority" in
    ''|*@*|*'?'*) return 1 ;;
  esac
  host="${authority%%:*}"
  normalized_host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_host" in
    ''|localhost|127.*|*.local|*.invalid|*example*|*placeholder*|*yourdomain*|*yourname*) return 1 ;;
  esac
  case "$normalized_host" in
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

for argument in "$@"; do
  case "$argument" in
    --build) run_build=true ;;
    --test) run_build=true; run_tests=true ;;
    --release) require_release_configuration=true ;;
    *) fail "unknown option: $argument" ;;
  esac
done

require_file() {
  [ -f "$project_root/$1" ] || fail "missing $1"
}

command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required"
command -v sips >/dev/null 2>&1 || fail "sips is required"

required_files=(
  "AgentIsland.xcodeproj/project.pbxproj"
  "AgentIsland.xcodeproj/xcshareddata/xcschemes/AgentIslandMobile.xcscheme"
  "AgentIsland.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
  "Config/Project.xcconfig"
  "Config/AgentIslandMobile.entitlements"
  "Config/App-Info.plist"
  "Config/Widget-Info.plist"
  "Config/PrivacyInfo.xcprivacy"
  "WidgetExtension/PrivacyInfo.xcprivacy"
  "App/AgentIslandMobileApp.swift"
  "App/CloudKitSnapshotProvider.swift"
  "App/DashboardStore.swift"
  "App/DashboardView.swift"
  "App/Formatting.swift"
  "App/LiveActivityCoordinator.swift"
  "App/SyncedSnapshotStore.swift"
  "Shared/AgentSnapshot.swift"
  "Shared/AgentIslandActivityAttributes.swift"
  "WidgetExtension/AgentIslandLiveActivity.swift"
  "WidgetExtension/AgentIslandWidgetBundle.swift"
  "Tests/DashboardStoreTests.swift"
  "Tests/AgentSnapshotTests.swift"
  "Tests/SnapshotFixtures.swift"
  "Resources/Assets.xcassets/Contents.json"
  "Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
  "Resources/en.lproj/Localizable.strings"
  "Resources/zh-Hans.lproj/Localizable.strings"
  "scripts/release-ios.sh"
)

for relative_path in "${required_files[@]}"; do
  require_file "$relative_path"
done

plutil -lint \
  "$project_file" \
  "$project_root/Config/App-Info.plist" \
  "$project_root/Config/Widget-Info.plist" \
  "$project_root/Config/PrivacyInfo.xcprivacy" \
  "$project_root/WidgetExtension/PrivacyInfo.xcprivacy" \
  "$project_root/Config/AgentIslandMobile.entitlements" \
  "$project_root/Resources/en.lproj/Localizable.strings" \
  "$project_root/Resources/zh-Hans.lproj/Localizable.strings" >/dev/null

privacy_json="$work_dir/privacy.json"
plutil -convert json -o "$privacy_json" "$project_root/Config/PrivacyInfo.xcprivacy"
jq -e '
  .NSPrivacyTracking == false
  and .NSPrivacyTrackingDomains == []
  and .NSPrivacyAccessedAPITypes == []
  and (.NSPrivacyCollectedDataTypes | length == 2)
  and ([.NSPrivacyCollectedDataTypes[].NSPrivacyCollectedDataType] | sort)
    == [
      "NSPrivacyCollectedDataTypeOtherUsageData",
      "NSPrivacyCollectedDataTypeOtherUserContent"
    ]
  and any(
    .NSPrivacyCollectedDataTypes[];
    .NSPrivacyCollectedDataType == "NSPrivacyCollectedDataTypeOtherUsageData"
    and .NSPrivacyCollectedDataTypeLinked == true
    and .NSPrivacyCollectedDataTypeTracking == false
    and (.NSPrivacyCollectedDataTypePurposes
      | index("NSPrivacyCollectedDataTypePurposeAppFunctionality") != null)
  )
  and any(
    .NSPrivacyCollectedDataTypes[];
    .NSPrivacyCollectedDataType == "NSPrivacyCollectedDataTypeOtherUserContent"
    and .NSPrivacyCollectedDataTypeLinked == true
    and .NSPrivacyCollectedDataTypeTracking == false
    and (.NSPrivacyCollectedDataTypePurposes
      | index("NSPrivacyCollectedDataTypePurposeAppFunctionality") != null)
  )
' "$privacy_json" >/dev/null \
  || fail "privacy manifest must disclose synced usage data and optional conversation titles for app functionality"

widget_privacy_json="$work_dir/widget-privacy.json"
plutil -convert json -o "$widget_privacy_json" \
  "$project_root/WidgetExtension/PrivacyInfo.xcprivacy"
jq -e '
  .NSPrivacyTracking == false
  and .NSPrivacyTrackingDomains == []
  and .NSPrivacyCollectedDataTypes == []
  and .NSPrivacyAccessedAPITypes == []
' "$widget_privacy_json" >/dev/null \
  || fail "Widget privacy manifest must declare no tracking, collection, or required-reason APIs"

zsh -n "$project_root/scripts/release-ios.sh" \
  || fail "release-ios.sh has invalid zsh syntax"

release_script="$project_root/scripts/release-ios.sh"
for release_marker in \
  'Apple Distribution:' \
  'ApplicationIdentifierPrefix.0' \
  'TeamIdentifier.0' \
  'ExpirationDate' \
  'com.apple.developer.icloud-container-environment' \
  'Production' \
  'ProvisionedDevices' \
  'uploaded: false' \
  'expected exactly one Apple Distribution identity' \
  'validate_app_info "$APP_PATH" "archived App"' \
  'validate_app_info "$EXPORTED_APP_PATH" "exported App"' \
  'validate_privacy_manifests "$APP_PATH" "$WIDGET_PATH" "archived"' \
  'validate_privacy_manifests "$EXPORTED_APP_PATH" "$EXPORTED_WIDGET_PATH" "exported"' \
  'privacyManifestSHA256' \
  'extract_profile_entitlements_json' \
  'Project.xcconfig must contain a final, conflict-checked AGENT_ISLAND_DISPLAY_NAME' \
  'displayName: $displayName' \
  'AgentIslandPrivacyPolicyURL' \
  'AgentIslandSupportURL' \
  'AgentIslandCloudKitRecordType' \
  '-derivedDataPath "$WORK_DIR/DerivedData"' \
  'LC_ALL=C LANG=C /usr/bin/shasum -a 256'; do
  grep -Fq -- "$release_marker" "$release_script" \
    || fail "release-ios.sh is missing the release gate: $release_marker"
done
if grep -Fq -- '--entitlements :-' "$release_script"; then
  fail "release-ios.sh must not use deprecated codesign entitlement output syntax"
fi
if grep -Fq -- '-extract Entitlements json' "$release_script"; then
  fail "release-ios.sh must isolate profile Entitlements as XML before JSON conversion"
fi
grep -Fq 'startswith("com.apple.developer.ubiquity")' "$release_script" \
  || fail "release-ios.sh must reject Widget ubiquity entitlements"
grep -Fq 'destination -string export' "$release_script" \
  || fail "release-ios.sh must keep IPA export local"
for forbidden_upload_marker in \
  '-uploadApp' \
  '--upload-app' \
  'iTMSTransporter' \
  'destination -string upload'; do
  if grep -Fq -- "$forbidden_upload_marker" "$release_script"; then
    fail "release-ios.sh must never upload a build"
  fi
done

jq -e '.info.version == 1' "$project_root/Resources/Assets.xcassets/Contents.json" >/dev/null \
  || fail "invalid asset catalog Contents.json"
jq -e '.info.version == 1 and (.images | length > 0)' "$asset_manifest" >/dev/null \
  || fail "invalid AppIcon Contents.json"
jq -e '
  any(.images[]; .idiom == "ios-marketing" and .size == "1024x1024" and .scale == "1x")
  and any(.images[]; .idiom == "iphone" and .size == "60x60" and .scale == "2x")
  and any(.images[]; .idiom == "iphone" and .size == "60x60" and .scale == "3x")
' "$asset_manifest" >/dev/null \
  || fail "AppIcon must include App Store and iPhone 2x/3x application icons"

xmllint --noout "$scheme_file" "$workspace_file"

project_json="$work_dir/project.json"
plutil -convert json -o "$project_json" "$project_file"

jq -e '
  [.objects[] | select(.isa == "PBXNativeTarget") | .name] | sort
  == ["AgentIslandLiveActivityExtension", "AgentIslandMobile", "AgentIslandMobileTests"]
' "$project_json" >/dev/null || fail "expected App, Widget Extension, and unit-test targets"

jq -e '
  .objects as $objects
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMobile").key) as $appID
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMobileTests").value) as $tests
  | ($tests.productType == "com.apple.product-type.bundle.unit-test")
    and any($tests.dependencies[]; $objects[.].target == $appID)
    and ([
      $tests.buildPhases[] as $phaseID
      | $objects[$phaseID]
      | select(.isa == "PBXSourcesBuildPhase")
      | .files[] as $buildFileID
      | $objects[$objects[$buildFileID].fileRef].path
    ] | sort == ["AgentSnapshotTests.swift", "DashboardStoreTests.swift", "SnapshotFixtures.swift"])
    and all(
      $objects[$objects[$tests.buildConfigurationList].buildConfigurations[]];
      .buildSettings.TEST_TARGET_NAME == "AgentIslandMobile"
      and .buildSettings.BUNDLE_LOADER == "$(TEST_HOST)"
      and .buildSettings.SKIP_INSTALL == "YES"
      and .buildSettings.PRODUCT_BUNDLE_IDENTIFIER == "$(AGENT_ISLAND_APP_BUNDLE_ID).tests"
    )
' "$project_json" >/dev/null || fail "unit-test target is not correctly hosted by AgentIslandMobile"

scheme_has_tests="$(xmllint --xpath \
  'boolean(/Scheme/TestAction/Testables/TestableReference[@skipped="NO"]/BuildableReference[@BlueprintName="AgentIslandMobileTests" and @BuildableName="AgentIslandMobileTests.xctest"])' \
  "$scheme_file")"
[ "$scheme_has_tests" = true ] || fail "shared scheme TestAction does not include AgentIslandMobileTests"
scheme_builds_tests="$(xmllint --xpath \
  'boolean(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry[@buildForTesting="YES"]/BuildableReference[@BlueprintName="AgentIslandMobileTests" and @BuildableName="AgentIslandMobileTests.xctest"])' \
  "$scheme_file")"
[ "$scheme_builds_tests" = true ] \
  || fail "shared scheme BuildAction does not build AgentIslandMobileTests for testing"

jq -e '
  .objects as $objects
  | [
      $objects[]
      | ..
      | strings
      | select(test("^[A-F0-9]{24}$"))
      | select($objects[.] == null)
    ]
  | length == 0
' "$project_json" >/dev/null || fail "project contains dangling object references"

jq -e '
  .objects as $objects
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMobile")) as $app
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandLiveActivityExtension")) as $widget
  | any(
      $app.value.dependencies[];
      . as $dependencyID |
      $objects[$dependencyID].target == $widget.key
    )
  and any(
    $app.value.buildPhases[];
    . as $phaseID |
    $objects[$phaseID].isa == "PBXCopyFilesBuildPhase"
    and ($objects[$phaseID].dstSubfolderSpec | tostring) == "13"
    and any(
      $objects[$phaseID].files[];
      . as $buildFileID |
      $objects[$objects[$buildFileID].fileRef].path
        == "AgentIslandLiveActivityExtension.appex"
      )
  )
' "$project_json" >/dev/null || fail "Widget Extension is not an embedded App dependency"

source_members_for_target() {
  local target_name="$1"
  jq -r --arg target "$target_name" '
    .objects as $objects
    | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == $target).value) as $targetObject
    | $targetObject.buildPhases[] as $phaseID
    | $objects[$phaseID]
    | select(.isa == "PBXSourcesBuildPhase")
    | .files[] as $buildFileID
    | $objects[$objects[$buildFileID].fileRef].path
  ' "$project_json" | LC_ALL=C sort
}

resource_members_for_target() {
  local target_name="$1"
  jq -r --arg target "$target_name" '
    .objects as $objects
    | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == $target).value) as $targetObject
    | $targetObject.buildPhases[] as $phaseID
    | $objects[$phaseID]
    | select(.isa == "PBXResourcesBuildPhase")
    | .files[] as $buildFileID
    | $objects[$objects[$buildFileID].fileRef].path
      // $objects[$objects[$buildFileID].fileRef].name
  ' "$project_json" | LC_ALL=C sort
}

cat >"$work_dir/app-sources.expected" <<'EOF'
AgentIslandActivityAttributes.swift
AgentIslandMobileApp.swift
AgentSnapshot.swift
CloudKitSnapshotProvider.swift
DashboardStore.swift
DashboardView.swift
Formatting.swift
LiveActivityCoordinator.swift
SyncedSnapshotStore.swift
EOF
source_members_for_target "AgentIslandMobile" >"$work_dir/app-sources.actual"
diff -u "$work_dir/app-sources.expected" "$work_dir/app-sources.actual" >/dev/null \
  || fail "AgentIslandMobile source membership differs from the expected set"

cat >"$work_dir/widget-sources.expected" <<'EOF'
AgentIslandActivityAttributes.swift
AgentIslandLiveActivity.swift
AgentIslandWidgetBundle.swift
AgentSnapshot.swift
EOF
source_members_for_target "AgentIslandLiveActivityExtension" >"$work_dir/widget-sources.actual"
diff -u "$work_dir/widget-sources.expected" "$work_dir/widget-sources.actual" >/dev/null \
  || fail "Widget Extension source membership differs from the expected set"

cat >"$work_dir/test-sources.expected" <<'EOF'
AgentSnapshotTests.swift
DashboardStoreTests.swift
SnapshotFixtures.swift
EOF
source_members_for_target "AgentIslandMobileTests" >"$work_dir/test-sources.actual"
diff -u "$work_dir/test-sources.expected" "$work_dir/test-sources.actual" >/dev/null \
  || fail "AgentIslandMobileTests source membership differs from the expected set"

cat >"$work_dir/app-resources.expected" <<'EOF'
Assets.xcassets
Localizable.strings
PrivacyInfo.xcprivacy
EOF
resource_members_for_target "AgentIslandMobile" >"$work_dir/app-resources.actual"
diff -u "$work_dir/app-resources.expected" "$work_dir/app-resources.actual" >/dev/null \
  || fail "AgentIslandMobile resource membership differs from the expected set"

cat >"$work_dir/widget-resources.expected" <<'EOF'
Localizable.strings
PrivacyInfo.xcprivacy
EOF
resource_members_for_target "AgentIslandLiveActivityExtension" \
  >"$work_dir/widget-resources.actual"
diff -u "$work_dir/widget-resources.expected" "$work_dir/widget-resources.actual" >/dev/null \
  || fail "Widget Extension resource membership differs from the expected set"

jq -e '
  .objects as $objects
  | ($objects | to_entries[]
      | select(.value.isa == "PBXGroup" and .value.path == "Config").value
      | .children[] as $fileID
      | select($objects[$fileID].path == "PrivacyInfo.xcprivacy")
      | $fileID) as $appPrivacy
  | ($objects | to_entries[]
      | select(.value.isa == "PBXGroup" and .value.path == "WidgetExtension").value
      | .children[] as $fileID
      | select($objects[$fileID].path == "PrivacyInfo.xcprivacy")
      | $fileID) as $widgetPrivacy
  | ($objects | to_entries[]
      | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMobile").value) as $app
  | ($objects | to_entries[]
      | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandLiveActivityExtension").value) as $widget
  | any(
      $app.buildPhases[];
      . as $phaseID
      | $objects[$phaseID].isa == "PBXResourcesBuildPhase"
      and any($objects[$phaseID].files[]; $objects[.].fileRef == $appPrivacy)
    )
  and all(
      $app.buildPhases[];
      . as $phaseID
      | $objects[$phaseID].isa != "PBXResourcesBuildPhase"
      or all($objects[$phaseID].files[]; $objects[.].fileRef != $widgetPrivacy)
    )
  and any(
      $widget.buildPhases[];
      . as $phaseID
      | $objects[$phaseID].isa == "PBXResourcesBuildPhase"
      and any($objects[$phaseID].files[]; $objects[.].fileRef == $widgetPrivacy)
    )
  and all(
      $widget.buildPhases[];
      . as $phaseID
      | $objects[$phaseID].isa != "PBXResourcesBuildPhase"
      or all($objects[$phaseID].files[]; $objects[.].fileRef != $appPrivacy)
    )
' "$project_json" >/dev/null \
  || fail "App and Widget targets must embed their own PrivacyInfo.xcprivacy files"

grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = "$(AGENT_ISLAND_APP_BUNDLE_ID)"' "$project_file" \
  || fail "App target does not use the configurable bundle ID"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = "$(AGENT_ISLAND_WIDGET_BUNDLE_ID)"' "$project_file" \
  || fail "Widget target does not use the configurable bundle ID"
grep -Fq 'CODE_SIGN_STYLE = Automatic' "$project_file" \
  || fail "automatic signing is not configured"
grep -Fq 'IPHONEOS_DEPLOYMENT_TARGET = 17.0' "$project_root/Config/Project.xcconfig" \
  || fail "iOS 17 deployment target is missing"
grep -Fq 'AGENT_ISLAND_DISPLAY_NAME =' "$project_root/Config/Project.xcconfig" \
  || fail "replaceable App Store display-name configuration is missing"
grep -Fq '<string>$(AGENT_ISLAND_DISPLAY_NAME)</string>' \
  "$project_root/Config/App-Info.plist" \
  || fail "App CFBundleDisplayName must use AGENT_ISLAND_DISPLAY_NAME"
grep -Fq '<string>$(AGENT_ISLAND_DISPLAY_NAME) Live Activity</string>' \
  "$project_root/Config/Widget-Info.plist" \
  || fail "Widget CFBundleDisplayName must derive from AGENT_ISLAND_DISPLAY_NAME"
grep -Fq 'CODE_SIGN_ENTITLEMENTS = Config/AgentIslandMobile.entitlements' "$project_file" \
  || fail "App target does not use the CloudKit entitlements file"
grep -Fq 'AGENT_ISLAND_ICLOUD_CONTAINER_ID = iCloud.' "$project_root/Config/Project.xcconfig" \
  || fail "replaceable iCloud container configuration is missing"
grep -Fq 'AGENT_ISLAND_PRIVACY_POLICY_URL = https:' "$project_root/Config/Project.xcconfig" \
  || fail "replaceable privacy-policy HTTPS URL configuration is missing"
grep -Fq 'AGENT_ISLAND_SUPPORT_URL = https:' "$project_root/Config/Project.xcconfig" \
  || fail "replaceable support HTTPS URL configuration is missing"
grep -Fq 'AGENT_ISLAND_WIDGET_BUNDLE_ID = $(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' \
  "$project_root/Config/Project.xcconfig" \
  || fail "the Widget bundle ID must remain a child of the App bundle ID"

if [ "$require_release_configuration" = true ]; then
  url_slash="$(xcconfig_value AGENT_ISLAND_URL_SLASH)"
  [ "$url_slash" = / ] || fail "AGENT_ISLAND_URL_SLASH must remain a single slash"
  url_slash_reference='$(AGENT_ISLAND_URL_SLASH)'
  for setting in AGENT_ISLAND_PRIVACY_POLICY_URL AGENT_ISLAND_SUPPORT_URL; do
    setting_value="$(xcconfig_value "$setting")"
    resolved_url="${setting_value//$url_slash_reference/$url_slash}"
    if ! production_https_url "$resolved_url"; then
      fail "$setting must be replaced with a production HTTPS URL"
    fi
  done

  app_bundle_id="$(xcconfig_value AGENT_ISLAND_APP_BUNDLE_ID)"
  cloud_container_id="$(xcconfig_value AGENT_ISLAND_ICLOUD_CONTAINER_ID)"
  development_team="$(xcconfig_value AGENT_ISLAND_DEVELOPMENT_TEAM)"
  display_name="$(xcconfig_value AGENT_ISLAND_DISPLAY_NAME)"
  display_name_lower="$(printf '%s' "$display_name" | tr '[:upper:]' '[:lower:]')"
  [ -n "$display_name" ] \
    || fail "AGENT_ISLAND_DISPLAY_NAME must contain the final App Store name"
  [ "$display_name_lower" != "agent island" ] \
    || fail "AGENT_ISLAND_DISPLAY_NAME still uses the known-conflicting development name"
  [ "${#display_name}" -le 30 ] \
    || fail "AGENT_ISLAND_DISPLAY_NAME exceeds the App Store 30-character limit"
  [[ "$display_name" != [[:space:]]* && "$display_name" != *[[:space:]] ]] \
    || fail "AGENT_ISLAND_DISPLAY_NAME must not start or end with whitespace"
  case "$display_name" in
    *'$('*|*'${'*|*[[:cntrl:]]*)
      fail "AGENT_ISLAND_DISPLAY_NAME must be a resolved, single-line display name"
      ;;
  esac
  [[ "$app_bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] \
    || fail "AGENT_ISLAND_APP_BUNDLE_ID must be a production reverse-DNS identifier"
  [[ "$app_bundle_id" != com.example.* ]] \
    || fail "AGENT_ISLAND_APP_BUNDLE_ID still uses the example namespace"
  [[ "$cloud_container_id" =~ ^iCloud\.[A-Za-z0-9.-]+$ ]] \
    || fail "AGENT_ISLAND_ICLOUD_CONTAINER_ID must be a registered iCloud container"
  [[ "$cloud_container_id" != iCloud.com.example.* ]] \
    || fail "AGENT_ISLAND_ICLOUD_CONTAINER_ID still uses the example namespace"
  [[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] \
    || fail "AGENT_ISLAND_DEVELOPMENT_TEAM must be the 10-character production Team ID"
fi

jq -e '
  .objects as $objects
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMobile").value) as $app
  | ($objects | to_entries[] | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandLiveActivityExtension").value) as $widget
  | any(
      $app.buildPhases[];
      . as $phaseID |
      $objects[$phaseID].isa == "PBXFrameworksBuildPhase"
      and any(
        $objects[$phaseID].files[];
        . as $buildFileID |
        $objects[$objects[$buildFileID].fileRef].path
          == "System/Library/Frameworks/CloudKit.framework"
      )
    )
  and all(
    $widget.buildPhases[];
    . as $phaseID |
    $objects[$phaseID].isa != "PBXFrameworksBuildPhase"
    or all(
      $objects[$phaseID].files[];
      . as $buildFileID |
      $objects[$objects[$buildFileID].fileRef].path
        != "System/Library/Frameworks/CloudKit.framework"
    )
  )
  and all(
    $objects[$objects[$app.buildConfigurationList].buildConfigurations[]];
    .buildSettings.CODE_SIGN_ENTITLEMENTS == "Config/AgentIslandMobile.entitlements"
  )
  and all(
    $objects[$objects[$widget.buildConfigurationList].buildConfigurations[]];
    .buildSettings.CODE_SIGN_ENTITLEMENTS == null
  )
' "$project_json" >/dev/null || fail "CloudKit must link to the App target only"

if source_members_for_target "AgentIslandLiveActivityExtension" | grep -Fq 'CloudKitSnapshotProvider.swift'; then
  fail "Widget Extension must not compile the CloudKit provider"
fi

grep -Fq 'fetchSnapshot(forAccountKey: accountKey)' \
  "$project_root/App/CloudKitSnapshotProvider.swift" \
  || fail "CloudKit cache reads must be scoped to the resolved iCloud account"
grep -Fq 'clearSnapshot(forAccountKey: accountKey)' \
  "$project_root/App/CloudKitSnapshotProvider.swift" \
  || fail "a missing CloudKit record must clear its account-scoped cache"
grep -Fq 'SHA256.hash' "$project_root/App/CloudKitSnapshotProvider.swift" \
  || fail "the CloudKit user record identifier must be irreversibly hashed before caching"
if grep -Fq 'cache.fetchSnapshot()' "$project_root/App/CloudKitSnapshotProvider.swift"; then
  fail "unscoped CloudKit cache fallback is forbidden"
fi

dashboard_store="$project_root/App/DashboardStore.swift"
[ "$(grep -Fc 'await clearAccountScopedState()' "$dashboard_store")" -eq 2 ] \
  || fail "both unavailable and changed iCloud accounts must clear in-memory state"
for account_clear_marker in \
  'private func clearAccountScopedState() async' \
  'snapshot = .empty' \
  'revealFullConversationTitles = false' \
  'await LiveActivityCoordinator.shared.stop()'; do
  grep -Fq "$account_clear_marker" "$dashboard_store" \
    || fail "account-scoped state cleanup is missing: $account_clear_marker"
done
for snapshot_validation_marker in \
  'snapshot.sourceDevice.id == "mac"' \
  'snapshot.sourceDevice.name == "Mac"' \
  'snapshot.sourceDevice.platform == "macOS"' \
  'agentIdentifiers.insert(agent.id).inserted' \
  'conversationIdentifiers.insert(conversation.id).inserted' \
  'snapshot.sync.includesFullConversationTitles' \
  'case undisclosedConversationTitle' \
  'CharacterSet.controlCharacters.contains' \
  'case duplicateIdentifier'; do
  grep -Fq "$snapshot_validation_marker" "$project_root/App/SyncedSnapshotStore.swift" \
    || fail "snapshot validation is missing: $snapshot_validation_marker"
done
grep -Fq 'guard let fileSize = values.fileSize' "$project_root/App/SyncedSnapshotStore.swift" \
  || fail "account cache must reject an unknown payload size before reading"
grep -Fq 'guard let fileSize = values.fileSize' "$project_root/App/CloudKitSnapshotProvider.swift" \
  || fail "CloudKit assets must reject an unknown payload size before reading"
[ "$(grep -Fc 'guard try await resolvedAccountKey() == accountKey' \
  "$project_root/App/CloudKitSnapshotProvider.swift")" -ge 2 ] \
  || fail "CloudKit account identity must be re-verified both before and after accepting a payload"

entitlements_json="$work_dir/entitlements.json"
plutil -convert json -o "$entitlements_json" \
  "$project_root/Config/AgentIslandMobile.entitlements"
jq -e '."com.apple.developer.icloud-container-identifiers"
  == ["$(AGENT_ISLAND_ICLOUD_CONTAINER_ID)"]' "$entitlements_json" >/dev/null \
  || fail "CloudKit entitlement must contain only the configurable container"
jq -e '."com.apple.developer.icloud-services" == ["CloudKit"]' \
  "$entitlements_json" >/dev/null \
  || fail "CloudKit service entitlement is missing"

for info_key in \
  AgentIslandCloudKitContainerIdentifier \
  AgentIslandCloudKitRecordName \
  AgentIslandCloudKitRecordType \
  AgentIslandCloudKitPayloadField; do
  plutil -extract "$info_key" raw "$project_root/Config/App-Info.plist" >/dev/null \
    || fail "App-Info.plist is missing $info_key"
  if plutil -extract "$info_key" raw "$project_root/Config/Widget-Info.plist" >/dev/null 2>&1; then
    fail "Widget-Info.plist must not contain $info_key"
  fi
done

for info_key in AgentIslandPrivacyPolicyURL AgentIslandSupportURL; do
  plutil -extract "$info_key" raw "$project_root/Config/App-Info.plist" >/dev/null \
    || fail "App-Info.plist is missing $info_key"
done

grep -Fq 'components.scheme?.lowercased() == "https"' \
  "$project_root/App/DashboardView.swift" \
  || fail "release links must reject non-HTTPS URLs"
grep -Fq 'Link(destination: privacyPolicyURL)' "$project_root/App/DashboardView.swift" \
  || fail "the dashboard must expose the configured privacy policy"
grep -Fq 'Link(destination: supportURL)' "$project_root/App/DashboardView.swift" \
  || fail "the dashboard must expose the configured support URL"
grep -Fq 'navigationTitle(Text(verbatim: releaseLinks.displayName))' \
  "$project_root/App/DashboardView.swift" \
  || fail "the dashboard title must follow the configurable App display name"

sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' \
  "$project_root/Resources/en.lproj/Localizable.strings" | LC_ALL=C sort \
  >"$work_dir/en.keys"
sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' \
  "$project_root/Resources/zh-Hans.lproj/Localizable.strings" | LC_ALL=C sort \
  >"$work_dir/zh-Hans.keys"
diff -u "$work_dir/en.keys" "$work_dir/zh-Hans.keys" >/dev/null \
  || fail "English and Simplified Chinese localization keys differ"

while IFS=$'\t' read -r icon_name expected_width expected_height; do
  icon_path="$project_root/Resources/Assets.xcassets/AppIcon.appiconset/$icon_name"
  [ -f "$icon_path" ] || fail "AppIcon references missing file $icon_name"
  icon_properties="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha \
    "$icon_path" 2>/dev/null)" || fail "AppIcon file is not a readable image: $icon_name"
  actual_width="$(printf '%s\n' "$icon_properties" | awk '/pixelWidth:/ {print $2; exit}')"
  actual_height="$(printf '%s\n' "$icon_properties" | awk '/pixelHeight:/ {print $2; exit}')"
  has_alpha="$(printf '%s\n' "$icon_properties" | awk '/hasAlpha:/ {print $2; exit}')"
  [ "$actual_width" = "$expected_width" ] && [ "$actual_height" = "$expected_height" ] \
    || fail "AppIcon $icon_name is ${actual_width}x${actual_height}, expected ${expected_width}x${expected_height}"
  [ "$has_alpha" = no ] || fail "AppIcon $icon_name must not contain an alpha channel"
done < <(jq -r '
  .images[]
  | select(.filename != null)
  | (.size | split("x") | map(tonumber)) as $points
  | (.scale | sub("x$"; "") | tonumber) as $scale
  | [.filename, ($points[0] * $scale), ($points[1] * $scale)]
  | @tsv
' "$asset_manifest")

if xcrun --find swift-format >/dev/null 2>&1; then
  xcrun swift-format lint --recursive \
    "$project_root/App" "$project_root/Shared" "$project_root/WidgetExtension" \
    "$project_root/Tests"
fi

if xcrun --find swiftc >/dev/null 2>&1; then
  xcrun swiftc -parse \
    "$project_root"/App/*.swift \
    "$project_root"/Shared/*.swift \
    "$project_root"/WidgetExtension/*.swift \
    "$project_root"/Tests/*.swift
fi

if [ "$run_build" = true ]; then
  xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 \
    || fail "--build requires full Xcode with the iPhone Simulator SDK"
  xcodebuild build-for-testing \
    -project "$project_root/AgentIsland.xcodeproj" \
    -scheme AgentIslandMobile \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work_dir/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

  if [ "$run_tests" = true ]; then
    test_destination="${AGENT_ISLAND_IOS_TEST_DESTINATION:-}"
    [ -n "$test_destination" ] \
      || fail "--test requires AGENT_ISLAND_IOS_TEST_DESTINATION, for example platform=iOS Simulator,name=iPhone 17 Pro"
    xcodebuild test-without-building \
      -project "$project_root/AgentIsland.xcodeproj" \
      -scheme AgentIslandMobile \
      -configuration Debug \
      -destination "$test_destination" \
      -derivedDataPath "$work_dir/DerivedData" \
      -resultBundlePath "$work_dir/AgentIslandMobileTests.xcresult" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO
  fi
fi

echo "Aivulet iOS project validation passed."
