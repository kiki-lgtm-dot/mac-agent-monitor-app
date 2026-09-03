#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$project_root/../.." && pwd)"
project_file="$project_root/AgentIslandMac.xcodeproj/project.pbxproj"
scheme_file="$project_root/AgentIslandMac.xcodeproj/xcshareddata/xcschemes/AgentIslandMac.xcscheme"
workspace_file="$project_root/AgentIslandMac.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
shared_xcconfig="$repo_root/ApplePlatforms/iOS/Config/Project.xcconfig"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentisland-macos-validation.XXXXXX")"
run_build=false

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "macOS project validation failed: $*" >&2
  exit 1
}

xcconfig_value() {
  local config_file="$1"
  local key="$2"
  sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$config_file" \
    | tail -n 1
}

for argument in "$@"; do
  case "$argument" in
    --build) run_build=true ;;
    *) fail "unknown option: $argument" ;;
  esac
done

command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required"
command -v iconutil >/dev/null 2>&1 || fail "iconutil is required"
command -v sips >/dev/null 2>&1 || fail "sips is required"

required_files=(
  "ApplePlatforms/macOS/AgentIslandMac.xcodeproj/project.pbxproj"
  "ApplePlatforms/macOS/AgentIslandMac.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
  "ApplePlatforms/macOS/AgentIslandMac.xcodeproj/xcshareddata/xcschemes/AgentIslandMac.xcscheme"
  "ApplePlatforms/macOS/Config/Project.xcconfig"
  "ApplePlatforms/macOS/Config/Mac-Info.plist"
  "ApplePlatforms/macOS/Config/AgentIslandMac.entitlements"
  "ApplePlatforms/macOS/scripts/release-macos-app-store.sh"
  "ApplePlatforms/macOS/scripts/submit-macos-app-store.sh"
  "ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh"
  "ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh"
  "ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh"
  "ApplePlatforms/iOS/Config/Project.xcconfig"
  "Native/AgentIsland.m"
  "Resources/Info.plist"
  "Resources/PrivacyInfo.xcprivacy"
  "Resources/AgentIsland.icns"
  "Web/index.html"
  "THIRD_PARTY_NOTICES.md"
)
for relative_path in "${required_files[@]}"; do
  [ -f "$repo_root/$relative_path" ] || fail "missing $relative_path"
done
for release_script in \
  release-macos-app-store.sh \
  submit-macos-app-store.sh \
  confirm-macos-app-store-evidence.sh \
  verify-macos-app-store-delivery.sh \
  verify-macos-app-store-evidence.sh; do
  [ -x "$repo_root/ApplePlatforms/macOS/scripts/$release_script" ] \
    || fail "macOS App Store script must be executable: $release_script"
  /bin/zsh -n "$repo_root/ApplePlatforms/macOS/scripts/$release_script" \
    || fail "macOS App Store script has invalid zsh syntax: $release_script"
done

delivery_verifier="$repo_root/ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh"
for required_marker in \
  '--check' \
  '--json' \
  'evidenceVerified: true' \
  'uploadAccepted: true' \
  'processingState: null' \
  'submittedForAppReview: false' \
  '[[ "$raw_path" == "$canonical_path" ]]' \
  'submit-macos-app-store.sh" --check'; do
  grep -Fq -- "$required_marker" "$delivery_verifier" \
    || fail "Mac App Store delivery verifier is missing: $required_marker"
done

processing_verifier="$repo_root/ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh"
for required_marker in \
  'deliveryEvidenceVerified: true' \
  'deliveryRecordPath: $deliveryRecordPath' \
  'releaseMetadataPath: $releaseMetadataPath' \
  'archiveZipPath: $archiveZipPath' \
  'validationResultPath: $validationResultPath' \
  'uploadResultPath: $uploadResultPath' \
  'submittedAt: $submittedAt' \
  'processingState: "Complete"' \
  'warningsReviewed: true' \
  'submittedForAppReview: false' \
  '[[ "$raw_path" == "$canonical_path" ]]' \
  'verify-macos-app-store-delivery.sh"'; do
  grep -Fq -- "$required_marker" "$processing_verifier" \
    || fail "Mac App Store processing verifier is missing: $required_marker"
done

plutil -lint \
  "$project_file" \
  "$project_root/Config/Mac-Info.plist" \
  "$project_root/Config/AgentIslandMac.entitlements" \
  "$repo_root/Resources/Info.plist" \
  "$repo_root/Resources/PrivacyInfo.xcprivacy" >/dev/null
xmllint --noout "$scheme_file" "$workspace_file"

iconset_dir="$work_dir/AgentIsland.iconset"
/usr/bin/iconutil --convert iconset "$repo_root/Resources/AgentIsland.icns" \
  --output "$iconset_dir" >/dev/null \
  || fail "Resources/AgentIsland.icns is not a valid macOS icon set"
expected_icon_count=0
for icon_spec in \
  icon_16x16.png:16 \
  icon_16x16@2x.png:32 \
  icon_32x32.png:32 \
  icon_32x32@2x.png:64 \
  icon_128x128.png:128 \
  icon_128x128@2x.png:256 \
  icon_256x256.png:256 \
  icon_256x256@2x.png:512 \
  icon_512x512.png:512 \
  icon_512x512@2x.png:1024; do
  icon_name="${icon_spec%%:*}"
  icon_dimension="${icon_spec##*:}"
  icon_path="$iconset_dir/$icon_name"
  [ -f "$icon_path" ] || fail "macOS icon is missing $icon_name"
  icon_width="$(/usr/bin/sips -g pixelWidth "$icon_path" 2>/dev/null \
    | /usr/bin/awk '/pixelWidth:/ {print $2}')"
  icon_height="$(/usr/bin/sips -g pixelHeight "$icon_path" 2>/dev/null \
    | /usr/bin/awk '/pixelHeight:/ {print $2}')"
  [ "$icon_width" = "$icon_dimension" ] && [ "$icon_height" = "$icon_dimension" ] \
    || fail "macOS icon $icon_name must be ${icon_dimension}x${icon_dimension}"
  expected_icon_count=$((expected_icon_count + 1))
done
actual_icon_count="$(/usr/bin/find "$iconset_dir" -type f -name '*.png' \
  | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
[ "$actual_icon_count" = "$expected_icon_count" ] \
  || fail "macOS icon set contains unexpected or duplicate PNG representations"

project_json="$work_dir/project.json"
info_json="$work_dir/info.json"
entitlements_json="$work_dir/entitlements.json"
plutil -convert json -o "$project_json" "$project_file"
plutil -convert json -o "$info_json" "$project_root/Config/Mac-Info.plist"
plutil -convert json -o "$entitlements_json" \
  "$project_root/Config/AgentIslandMac.entitlements"

jq -e '
  .archiveVersion == "1" and
  .objectVersion == "56" and
  .objects[.rootObject].compatibilityVersion == "Xcode 14.0"
' "$project_json" >/dev/null \
  || fail "project file format must remain readable by the supported Xcode 14 minimum"

jq -e '
  .objects as $objects
  | [.objects | to_entries[] | select(.value.isa == "PBXNativeTarget")] as $targets
  | ($targets | length == 1)
    and ($targets[0].key == "C10500000000000000000001")
    and ($targets[0].value.name == "AgentIslandMac")
    and ($targets[0].value.productName == "AgentIslandMac")
    and ($targets[0].value.productType == "com.apple.product-type.application")
    and ($objects[$targets[0].value.productReference].path == "AgentIslandMac.app")
' "$project_json" >/dev/null \
  || fail "expected one AgentIslandMac application target"

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
  | ($objects | to_entries[]
      | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMac").value) as $app
  | def members($phaseType):
      [$app.buildPhases[] as $phaseID
        | $objects[$phaseID]
        | select(.isa == $phaseType)
        | .files[] as $buildFileID
        | $objects[$objects[$buildFileID].fileRef]
        | (.path // .name)];
    (members("PBXSourcesBuildPhase") | sort) == ["../../Native/AgentIsland.m"]
    and (members("PBXResourcesBuildPhase") | sort) == [
      "../../Resources/AgentIsland.icns",
      "../../Resources/PrivacyInfo.xcprivacy",
      "../../THIRD_PARTY_NOTICES.md"
    ]
    and any(
      $app.buildPhases[];
      . as $phaseID
      | $objects[$phaseID].isa == "PBXCopyFilesBuildPhase"
      and ($objects[$phaseID].dstSubfolderSpec | tostring) == "7"
      and $objects[$phaseID].dstPath == "Web"
      and ([$objects[$phaseID].files[] as $buildFileID
        | $objects[$objects[$buildFileID].fileRef].path]
        == ["../../Web/index.html"])
    )
    and (members("PBXFrameworksBuildPhase") | map(split("/")[-1]) | sort) == [
      "CloudKit.framework",
      "Cocoa.framework",
      "QuartzCore.framework",
      "Security.framework",
      "UniformTypeIdentifiers.framework",
      "WebKit.framework",
      "libsqlite3.tbd"
    ]
' "$project_json" >/dev/null \
  || fail "target source, resource, Web copy, or framework membership is incomplete"

jq -e '
  .objects as $objects
  | ($objects | to_entries[]
      | select(.value.isa == "PBXNativeTarget" and .value.name == "AgentIslandMac").value) as $app
  | $objects[.rootObject] as $project
  | [$objects[$app.buildConfigurationList].buildConfigurations[]
      | $objects[.]] as $configs
  | ($configs | map(.name) | sort) == ["Debug", "Release"]
    and ($project.attributes.TargetAttributes.C10500000000000000000001.SystemCapabilities
      | keys | sort) == ["com.apple.AppSandbox", "com.apple.iCloud"]
    and $project.attributes.TargetAttributes.C10500000000000000000001.SystemCapabilities."com.apple.AppSandbox".enabled == "1"
    and $project.attributes.TargetAttributes.C10500000000000000000001.SystemCapabilities."com.apple.iCloud".enabled == "1"
    and all($configs[];
      .buildSettings.PRODUCT_BUNDLE_IDENTIFIER == "$(AGENT_ISLAND_MAC_APP_BUNDLE_ID)"
      and .buildSettings.DEVELOPMENT_TEAM == "$(AGENT_ISLAND_DEVELOPMENT_TEAM)"
      and .buildSettings.CODE_SIGN_STYLE == "Automatic"
      and .buildSettings.CODE_SIGN_ENTITLEMENTS == "Config/AgentIslandMac.entitlements"
      and .buildSettings.GENERATE_INFOPLIST_FILE == "NO"
      and .buildSettings.INFOPLIST_FILE == "Config/Mac-Info.plist"
      and .buildSettings.ENABLE_APP_SANDBOX == "YES"
      and .buildSettings.ENABLE_HARDENED_RUNTIME == "YES"
      and .buildSettings.SUPPORTED_PLATFORMS == "macosx"
      and .buildSettings.SKIP_INSTALL == "NO")
' "$project_json" >/dev/null \
  || fail "AgentIslandMac target build settings do not satisfy signing and sandbox requirements"

jq -e '
  .objects as $objects
  | $objects[.rootObject] as $project
  | [$objects[$project.buildConfigurationList].buildConfigurations[]
      | $objects[.]] as $configs
  | ($configs | map(.name) | sort) == ["Debug", "Release"]
    and all($configs[];
      $objects[.baseConfigurationReference].path == "Project.xcconfig"
      and .buildSettings.SDKROOT == "macosx"
      and .buildSettings.MACOSX_DEPLOYMENT_TARGET == "13.0")
' "$project_json" >/dev/null \
  || fail "project configurations must inherit Config/Project.xcconfig for macOS 13"

scheme_build_reference_count="$(xmllint --xpath \
  'count(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference)' \
  "$scheme_file")"
[ "$scheme_build_reference_count" = "1" ] \
  || fail "AgentIslandMac scheme must build exactly one target"
scheme_builds_app="$(xmllint --xpath \
  'boolean(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference[@BlueprintIdentifier="C10500000000000000000001" and @BlueprintName="AgentIslandMac" and @BuildableName="AgentIslandMac.app" and @ReferencedContainer="container:AgentIslandMac.xcodeproj"])' \
  "$scheme_file")"
[ "$scheme_builds_app" = "true" ] \
  || fail "shared scheme does not reference the AgentIslandMac App target"
scheme_archives_release="$(xmllint --xpath \
  'boolean(/Scheme/ArchiveAction[@buildConfiguration="Release"])' "$scheme_file")"
[ "$scheme_archives_release" = "true" ] \
  || fail "shared scheme must archive its Release configuration"
workspace_references_project="$(xmllint --xpath \
  'boolean(/Workspace/FileRef[@location="self:"])' "$workspace_file")"
[ "$workspace_references_project" = "true" ] \
  || fail "project workspace does not reference itself"

grep -Fxq '#include "../../iOS/Config/Project.xcconfig"' \
  "$project_root/Config/Project.xcconfig" \
  || fail "macOS must inherit the shared iOS release identity configuration"
for identity_key in \
  AGENT_ISLAND_DISPLAY_NAME \
  AGENT_ISLAND_APP_BUNDLE_ID \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID \
  AGENT_ISLAND_DEVELOPMENT_TEAM; do
  if grep -Eq "^[[:space:]]*$identity_key[[:space:]]*=" \
      "$project_root/Config/Project.xcconfig"; then
    fail "macOS Project.xcconfig must not shadow shared identity key $identity_key"
  fi
done
mac_bundle_key_count="$(grep -Ec \
  '^[[:space:]]*AGENT_ISLAND_MAC_APP_BUNDLE_ID[[:space:]]*=' \
  "$project_root/Config/Project.xcconfig")"
[ "$mac_bundle_key_count" = "1" ] \
  || fail "macOS Project.xcconfig must define AGENT_ISLAND_MAC_APP_BUNDLE_ID exactly once"
mac_bundle_value="$(xcconfig_value \
  "$project_root/Config/Project.xcconfig" AGENT_ISLAND_MAC_APP_BUNDLE_ID)"
printf '%s\n' "$mac_bundle_value" | grep -Eq \
  '^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$' \
  || fail "macOS Project.xcconfig contains an invalid Mac App bundle ID"
for shared_key in \
  AGENT_ISLAND_DISPLAY_NAME \
  AGENT_ISLAND_APP_BUNDLE_ID \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID \
  AGENT_ISLAND_PRIVACY_POLICY_URL \
  AGENT_ISLAND_SUPPORT_URL \
  AGENT_ISLAND_DEVELOPMENT_TEAM; do
  shared_key_count="$(grep -Ec "^[[:space:]]*$shared_key[[:space:]]*=" "$shared_xcconfig")"
  [ "$shared_key_count" = "1" ] \
    || fail "shared identity configuration must define $shared_key exactly once"
done
grep -Fxq 'AGENT_ISLAND_DISPLAY_NAME = MAC版灵动岛--Agent运行监测' "$shared_xcconfig" \
  || fail "the public display name must be exactly MAC版灵动岛--Agent运行监测"
grep -Fxq 'AGENT_ISLAND_PRIVACY_POLICY_URL = https:$(AGENT_ISLAND_URL_SLASH)$(AGENT_ISLAND_URL_SLASH)kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  "$shared_xcconfig" \
  || fail "macOS must use the published privacy-policy URL"
grep -Fxq 'AGENT_ISLAND_SUPPORT_URL = https:$(AGENT_ISLAND_URL_SLASH)$(AGENT_ISLAND_URL_SLASH)kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  "$shared_xcconfig" \
  || fail "macOS must use the published support URL"
legacy_marketing_version="$(plutil -extract CFBundleShortVersionString raw -o - \
  "$repo_root/Resources/Info.plist")"
legacy_build_number="$(plutil -extract CFBundleVersion raw -o - \
  "$repo_root/Resources/Info.plist")"
[ "$(xcconfig_value "$project_root/Config/Project.xcconfig" MARKETING_VERSION)" \
    = "$legacy_marketing_version" ] \
  || fail "macOS App Store and Developer ID marketing versions must match"
[ "$(xcconfig_value "$project_root/Config/Project.xcconfig" CURRENT_PROJECT_VERSION)" \
    = "$legacy_build_number" ] \
  || fail "macOS App Store and Developer ID build numbers must match"

jq -e '
  .CFBundleDisplayName == "$(AGENT_ISLAND_DISPLAY_NAME)"
  and .CFBundleDevelopmentRegion == "$(DEVELOPMENT_LANGUAGE)"
  and .CFBundleExecutable == "$(EXECUTABLE_NAME)"
  and .CFBundleIdentifier == "$(PRODUCT_BUNDLE_IDENTIFIER)"
  and .CFBundleShortVersionString == "$(MARKETING_VERSION)"
  and .CFBundleVersion == "$(CURRENT_PROJECT_VERSION)"
  and .AgentIslandPrivacyPolicyURL == "$(AGENT_ISLAND_PRIVACY_POLICY_URL)"
  and .AgentIslandSupportURL == "$(AGENT_ISLAND_SUPPORT_URL)"
  and .CFBundleIconFile == "AgentIsland"
  and .LSApplicationCategoryType == "public.app-category.developer-tools"
  and .LSUIElement == true
  and .ITSAppUsesNonExemptEncryption == false
  and .NSAppTransportSecurity.NSAllowsLocalNetworking == true
  and .NSHumanReadableCopyright == "$(AGENT_ISLAND_COPYRIGHT)"
' "$info_json" >/dev/null \
  || fail "Mac-Info.plist release macros or Developer Tools category are incomplete"

jq -e '
  (keys | sort) == [
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.security.app-sandbox",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.files.user-selected.read-only",
    "com.apple.security.network.client"
  ]
  and ."com.apple.security.app-sandbox" == true
  and ."com.apple.security.files.user-selected.read-only" == true
  and ."com.apple.security.files.bookmarks.app-scope" == true
  and ."com.apple.security.network.client" == true
  and ."com.apple.developer.icloud-container-identifiers"
    == ["$(AGENT_ISLAND_ICLOUD_CONTAINER_ID)"]
  and ."com.apple.developer.icloud-container-environment" == "Production"
  and ."com.apple.developer.icloud-services" == ["CloudKit"]
' "$entitlements_json" >/dev/null \
  || fail "App Sandbox, document access, bookmarks, network, or CloudKit entitlements are incomplete"

if [ "$run_build" = true ]; then
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  [ -n "$developer_dir" ] || fail "Xcode developer directory is not selected"
  [ -x /usr/bin/xcodebuild ] || fail "xcodebuild is unavailable"
  /usr/bin/xcodebuild -version >/dev/null 2>&1 \
    || fail "full Xcode is required for --build (Command Line Tools are not enough)"
  /usr/bin/xcodebuild \
    -project "$project_root/AgentIslandMac.xcodeproj" \
    -scheme AgentIslandMac \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$work_dir/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
  echo "macOS Xcode project static validation and unsigned build passed"
else
  echo "macOS Xcode project static validation passed"
fi
