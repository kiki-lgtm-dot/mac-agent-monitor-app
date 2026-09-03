#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

MAC_ROOT="${0:A:h:h}"
PRODUCT_ROOT="${MAC_ROOT:h:h}"
PROJECT_PATH="$MAC_ROOT/AgentIslandMac.xcodeproj"
SCHEME="AgentIslandMac"
CONFIGURATION="Release"
DIST_ROOT="$PRODUCT_ROOT/dist/macos-app-store"
PUBLIC_APP_NAME="MAC版灵动岛--Agent运行监测"
EXPORT_PACKAGE=false
ALLOW_PROVISIONING_UPDATES=false
WORK_ROOT=""
STAGING_ROOT=""
PUBLISHED=false

usage() {
  /bin/cat <<'EOF'
Usage: ./ApplePlatforms/macOS/scripts/release-macos-app-store.sh [options]

Creates and verifies a signed Mac App Store archive. Options:
  --export                       Export and verify a local App Store .pkg.
  --allow-provisioning-updates   Let Xcode update signing assets if needed.
  -h, --help                     Show this help.

The script never uploads, notarizes, or submits a build. It stages all output,
verifies the archive (and optional package), then publishes it under
dist/macos-app-store. Upload later, deliberately, with Xcode Organizer or an
Apple-supported upload tool after reviewing the generated metadata and hashes.

Required environment:
  AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT

Optional identity selectors when the Team has more than one matching identity:
  AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY
  AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY   (required only with --export)
EOF
}

fail() {
  print -u2 -r -- "macOS App Store release failed: $*"
  exit 2
}

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == /private/tmp/agentisland-mac-store.* ]]; then
    /bin/rm -rf "$WORK_ROOT"
  fi
  if [[ "$PUBLISHED" != true && -n "$STAGING_ROOT" && \
      "$STAGING_ROOT" == "$DIST_ROOT"/.agentisland-mac-store.* ]]; then
    /bin/rm -rf "$STAGING_ROOT"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# > 0 )); do
  case "$1" in
    --export)
      EXPORT_PACKAGE=true
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

for tool in /usr/bin/jq /usr/bin/plutil /usr/bin/security /usr/bin/codesign \
  /usr/bin/lipo /usr/bin/ditto /usr/bin/unzip /usr/bin/zipinfo \
  /usr/bin/xcodebuild /usr/bin/xcrun /usr/sbin/pkgutil; do
  [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done

DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
[[ "$DEVELOPER_PATH" == */Xcode*.app/Contents/Developer ]] \
  || fail "select full Xcode 26 or newer with xcode-select before archiving"
[[ -d "$DEVELOPER_PATH/Platforms/MacOSX.platform" ]] \
  || fail "the selected Xcode does not include the macOS platform"

XCODE_VERSION="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild -version \
  | /usr/bin/awk '/^Xcode / {print $2; exit}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
[[ "$XCODE_MAJOR" == <-> ]] || fail "could not determine the Xcode version"
(( XCODE_MAJOR >= 26 )) || fail "Xcode 26 or newer is required for this App Store candidate"

MACOS_SDK="$(DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcrun \
  --sdk macosx --show-sdk-version 2>/dev/null || true)"
MACOS_SDK_MAJOR="${MACOS_SDK%%.*}"
[[ "$MACOS_SDK_MAJOR" == <-> ]] || fail "could not determine the macOS SDK version"
(( MACOS_SDK_MAJOR >= 26 )) \
  || fail "the macOS 26 SDK or newer is required for this App Store candidate"

COPYRIGHT="${AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT:-}"
utf8_character_count() {
  printf '%s' "$1" | LC_ALL= LC_CTYPE=UTF-8 /usr/bin/wc -m \
    | /usr/bin/tr -d '[:space:]'
}
COPYRIGHT_CHARACTER_COUNT="$(utf8_character_count "$COPYRIGHT")"
[[ -n "$COPYRIGHT" && "$COPYRIGHT_CHARACTER_COUNT" == <-> && \
  "$COPYRIGHT_CHARACTER_COUNT" -ge 2 && "$COPYRIGHT_CHARACTER_COUNT" -le 200 && \
  "$COPYRIGHT" != [[:space:]]* && "$COPYRIGHT" != *[[:space:]] && \
  "$COPYRIGHT" != *[[:cntrl:]]* && "$COPYRIGHT" != *'$('* && \
  "$COPYRIGHT" != *'${'* && "$COPYRIGHT" != *'<'* && \
  "$COPYRIGHT" != *'>'* && "$COPYRIGHT" != *'['* && \
  "$COPYRIGHT" != *']'* && "${COPYRIGHT:l}" != *placeholder* && \
  "${COPYRIGHT:l}" != *yourname* && "${COPYRIGHT:l}" != *'legal name'* && \
  "$COPYRIGHT" != *'法定姓名'* ]] \
  || fail "set AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT to the final 2-200 character legal copyright string"

"$MAC_ROOT/scripts/validate-project.sh"

WORK_ROOT="$(mktemp -d /private/tmp/agentisland-mac-store.XXXXXX)"
BUILD_SETTINGS_JSON="$WORK_ROOT/build-settings.json"
DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK_ROOT/BuildSettingsDerivedData" \
  -showBuildSettings -json \
  AGENT_ISLAND_COPYRIGHT="$COPYRIGHT" >"$BUILD_SETTINGS_JSON"

/usr/bin/jq -e '
  type == "array" and length == 1 and
  .[0].target == "AgentIslandMac" and
  (.[0].buildSettings | type == "object")
' "$BUILD_SETTINGS_JSON" >/dev/null \
  || fail "Xcode did not resolve exactly one AgentIslandMac target"

build_setting() {
  local key="$1"
  local value
  value="$(/usr/bin/jq -er --arg key "$key" \
    '.[0].buildSettings[$key] | select(type == "string" and length > 0)' \
    "$BUILD_SETTINGS_JSON" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "resolved Release build setting is missing: $key"
  print -r -- "$value"
}

TEAM_ID="$(build_setting DEVELOPMENT_TEAM)"
VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
APP_BUNDLE_ID="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
CLOUD_CONTAINER_ID="$(build_setting AGENT_ISLAND_ICLOUD_CONTAINER_ID)"
DISPLAY_NAME="$(build_setting AGENT_ISLAND_DISPLAY_NAME)"
PRIVACY_POLICY_URL="$(build_setting AGENT_ISLAND_PRIVACY_POLICY_URL)"
SUPPORT_URL="$(build_setting AGENT_ISLAND_SUPPORT_URL)"
DEPLOYMENT_TARGET="$(build_setting MACOSX_DEPLOYMENT_TARGET)"
RESOLVED_COPYRIGHT="$(build_setting AGENT_ISLAND_COPYRIGHT)"

production_bundle_id() {
  local value="$1"
  local normalized="${value:l}"
  [[ ${#value} -le 255 && "$normalized" != local.* && \
    "$normalized" != *example* && "$normalized" != *placeholder* && \
    "$normalized" != *yourname* && "$normalized" != *yourdomain* && \
    "$normalized" != *.invalid ]] || return 1
  print -r -- "$value" | /usr/bin/jq -R -e \
    'test("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")' \
    >/dev/null
}

production_container_id() {
  local value="$1"
  local suffix="${value#iCloud.}"
  [[ "$value" == iCloud.* && "$suffix" != "$value" ]] || return 1
  production_bundle_id "$suffix"
}

production_https_url() {
  local value="$1"
  local normalized="${value:l}"
  local authority host normalized_host
  [[ "$value" == https://* && "$value" != *[[:space:]]* && \
    "$value" != *'#'* && "$value" != *'$('* ]] || return 1
  authority="${value#https://}"
  authority="${authority%%/*}"
  [[ -n "$authority" && "$authority" != *@* && "$authority" != *'?'* ]] || return 1
  host="${authority%%:*}"
  normalized_host="${host:l}"
  [[ "$host" == *.* && "$normalized_host" != localhost && \
    "$normalized_host" != 127.* && "$normalized_host" != *.local && \
    "$normalized_host" != *.invalid && "$normalized" != *example* && \
    "$normalized" != *placeholder* && "$normalized" != *yourdomain* && \
    "$normalized" != *yourname* ]]
}

[[ ${#TEAM_ID} -eq 10 && "$TEAM_ID" != *[^A-Z0-9]* ]] \
  || fail "Release build must resolve the production 10-character Team ID"
production_bundle_id "$APP_BUNDLE_ID" \
  || fail "Release build must resolve a production reverse-DNS bundle identifier"
production_container_id "$CLOUD_CONTAINER_ID" \
  || fail "Release build must resolve a production iCloud container identifier"
[[ "$DISPLAY_NAME" == "$PUBLIC_APP_NAME" ]] \
  || fail "Release display name must equal $PUBLIC_APP_NAME"
print -r -- "$VERSION" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' \
  || fail "MARKETING_VERSION must contain two or three numeric components"
print -r -- "$BUILD_NUMBER" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
  || fail "CURRENT_PROJECT_VERSION must be a positive integer without leading zeroes"
production_https_url "$PRIVACY_POLICY_URL" \
  || fail "Release build must contain a production HTTPS privacy-policy URL"
production_https_url "$SUPPORT_URL" \
  || fail "Release build must contain a production HTTPS support URL"
[[ "$RESOLVED_COPYRIGHT" == "$COPYRIGHT" ]] \
  || fail "Xcode did not preserve AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT"
[[ "$(build_setting CODE_SIGN_STYLE)" == "Automatic" ]] \
  || fail "Mac App Store target must use Automatic signing"
[[ "$(build_setting ENABLE_APP_SANDBOX)" == "YES" ]] \
  || fail "Mac App Store target must enable App Sandbox"
[[ "$(build_setting ENABLE_HARDENED_RUNTIME)" == "YES" ]] \
  || fail "Mac App Store target must enable Hardened Runtime"
[[ "$(build_setting CODE_SIGN_ENTITLEMENTS)" == "Config/AgentIslandMac.entitlements" ]] \
  || fail "Mac App Store target resolved the wrong entitlement file"

IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
REQUESTED_IDENTITY="${AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY:-}"
valid_app_distribution_identity_name() {
  local value="$1"
  [[ "$value" == "Apple Distribution: "* || \
    "$value" == "3rd Party Mac Developer Application: "* || \
    "$value" == "Mac App Distribution: "* ]]
}

if [[ -n "$REQUESTED_IDENTITY" ]]; then
  valid_app_distribution_identity_name "$REQUESTED_IDENTITY" \
    || fail "AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY must name an Apple/Mac App Distribution identity"
  [[ "$REQUESTED_IDENTITY" == *" ($TEAM_ID)" ]] \
    || fail "the requested App Distribution identity belongs to another Team"
  REQUESTED_IDENTITY_COUNT="$(print -r -- "$IDENTITY_OUTPUT" \
    | /usr/bin/grep -Fc "\"$REQUESTED_IDENTITY\"" || true)"
  [[ "$REQUESTED_IDENTITY_COUNT" == "1" ]] \
    || fail "the requested App Distribution identity must match exactly one keychain identity"
  SELECTED_IDENTITY="$REQUESTED_IDENTITY"
else
  MATCHING_IDENTITIES="$(print -r -- "$IDENTITY_OUTPUT" \
    | /usr/bin/awk -v team="$TEAM_ID" '
      match($0, /"(Apple Distribution|3rd Party Mac Developer Application|Mac App Distribution):[^"]+"/) {
        identity = substr($0, RSTART + 1, RLENGTH - 2)
        suffix = " (" team ")"
        if (length(identity) >= length(suffix) &&
            substr(identity, length(identity) - length(suffix) + 1) == suffix) {
          print identity
        }
      }
    ')"
  MATCHING_IDENTITY_COUNT="$(print -r -- "$MATCHING_IDENTITIES" \
    | /usr/bin/awk 'NF {count++} END {print count + 0}')"
  [[ "$MATCHING_IDENTITY_COUNT" == "1" ]] \
    || fail "expected exactly one App Distribution identity for Team $TEAM_ID; set AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY to disambiguate"
  SELECTED_IDENTITY="$(print -r -- "$MATCHING_IDENTITIES" | /usr/bin/head -n 1)"
fi

SELECTED_IDENTITY_SHA1="$(print -r -- "$IDENTITY_OUTPUT" \
  | /usr/bin/grep -F "\"$SELECTED_IDENTITY\"" \
  | /usr/bin/awk '{print toupper($2); exit}')"
[[ "$SELECTED_IDENTITY_SHA1" == [0-9A-F]## && \
  ${#SELECTED_IDENTITY_SHA1} -eq 40 ]] \
  || fail "could not resolve the App Distribution certificate SHA-1"

SELECTED_INSTALLER_IDENTITY=""
if [[ "$EXPORT_PACKAGE" == true ]]; then
  INSTALLER_IDENTITY_OUTPUT="$(/usr/bin/security find-identity -v 2>/dev/null || true)"
  REQUESTED_INSTALLER_IDENTITY="${AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY:-}"
  valid_installer_identity_name() {
    local value="$1"
    [[ "$value" == "Mac Installer Distribution: "* || \
      "$value" == "3rd Party Mac Developer Installer: "* ]]
  }
  if [[ -n "$REQUESTED_INSTALLER_IDENTITY" ]]; then
    valid_installer_identity_name "$REQUESTED_INSTALLER_IDENTITY" \
      || fail "AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY must name a Mac Installer Distribution identity"
    [[ "$REQUESTED_INSTALLER_IDENTITY" == *" ($TEAM_ID)" ]] \
      || fail "the requested Installer identity belongs to another Team"
    REQUESTED_INSTALLER_COUNT="$(print -r -- "$INSTALLER_IDENTITY_OUTPUT" \
      | /usr/bin/grep -Fc "\"$REQUESTED_INSTALLER_IDENTITY\"" || true)"
    [[ "$REQUESTED_INSTALLER_COUNT" == "1" ]] \
      || fail "the requested Installer identity must match exactly one keychain identity"
    SELECTED_INSTALLER_IDENTITY="$REQUESTED_INSTALLER_IDENTITY"
  else
    MATCHING_INSTALLER_IDENTITIES="$(print -r -- "$INSTALLER_IDENTITY_OUTPUT" \
      | /usr/bin/awk -v team="$TEAM_ID" '
        match($0, /"(Mac Installer Distribution|3rd Party Mac Developer Installer):[^"]+"/) {
          identity = substr($0, RSTART + 1, RLENGTH - 2)
          suffix = " (" team ")"
          if (length(identity) >= length(suffix) &&
              substr(identity, length(identity) - length(suffix) + 1) == suffix) {
            print identity
          }
        }
      ')"
    MATCHING_INSTALLER_COUNT="$(print -r -- "$MATCHING_INSTALLER_IDENTITIES" \
      | /usr/bin/awk 'NF {count++} END {print count + 0}')"
    [[ "$MATCHING_INSTALLER_COUNT" == "1" ]] \
      || fail "expected exactly one Mac Installer Distribution identity for Team $TEAM_ID; set AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY to disambiguate"
    SELECTED_INSTALLER_IDENTITY="$(print -r -- "$MATCHING_INSTALLER_IDENTITIES" \
      | /usr/bin/head -n 1)"
  fi
fi

validate_app_info_and_contents() {
  local app_path="$1"
  local label="$2"
  local info="$app_path/Contents/Info.plist"
  local executable_name executable_path normalized_arches
  [[ -d "$app_path" && ! -L "$app_path" ]] || fail "$label is not a regular App bundle"
  [[ -f "$info" && ! -L "$info" ]] || fail "$label is missing Contents/Info.plist"
  /usr/bin/plutil -lint "$info" >/dev/null || fail "$label has an invalid Info.plist"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null)" == "$APP_BUNDLE_ID" ]] \
    || fail "$label bundle identifier does not match the resolved Release setting"
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info" 2>/dev/null)" == "$VERSION" ]] \
    || fail "$label marketing version does not match the resolved Release setting"
  [[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$info" 2>/dev/null)" == "$BUILD_NUMBER" ]] \
    || fail "$label build number does not match the resolved Release setting"
  [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$info" 2>/dev/null)" == "$DISPLAY_NAME" ]] \
    || fail "$label display name does not match the resolved Release setting"
  [[ "$(/usr/bin/plutil -extract NSHumanReadableCopyright raw "$info" 2>/dev/null)" == "$COPYRIGHT" ]] \
    || fail "$label copyright is missing or changed"
  [[ "$(/usr/bin/plutil -extract AgentIslandPrivacyPolicyURL raw "$info" 2>/dev/null)" == "$PRIVACY_POLICY_URL" ]] \
    || fail "$label privacy-policy URL changed"
  [[ "$(/usr/bin/plutil -extract AgentIslandSupportURL raw "$info" 2>/dev/null)" == "$SUPPORT_URL" ]] \
    || fail "$label support URL changed"
  [[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$info" 2>/dev/null)" == "$DEPLOYMENT_TARGET" ]] \
    || fail "$label minimum macOS version changed"
  [[ "$(/usr/bin/plutil -extract LSUIElement raw "$info" 2>/dev/null)" == "true" ]] \
    || fail "$label must remain an LSUIElement menu-bar application"
  [[ "$(/usr/bin/plutil -extract ITSAppUsesNonExemptEncryption raw "$info" 2>/dev/null)" == "false" ]] \
    || fail "$label encryption declaration changed"
  [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "$info" 2>/dev/null)" == "AgentIsland" ]] \
    || fail "$label icon setting changed"
  for permission_key in NSCameraUsageDescription NSMicrophoneUsageDescription \
    NSScreenCaptureUsageDescription NSAppleEventsUsageDescription; do
    if /usr/bin/plutil -extract "$permission_key" raw "$info" >/dev/null 2>&1; then
      fail "$label unexpectedly requests $permission_key"
    fi
  done
  if ARBITRARY_LOADS="$(/usr/bin/plutil -extract \
      NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$info" 2>/dev/null)"; then
    [[ "$ARBITRARY_LOADS" == "false" ]] \
      || fail "$label enables arbitrary network loads"
  fi
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$info" 2>/dev/null)" \
    || fail "$label has no executable name"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -f "$executable_path" && -x "$executable_path" && ! -L "$executable_path" ]] \
    || fail "$label executable is missing, non-executable, or a symlink"
  normalized_arches="$(/usr/bin/lipo -archs "$executable_path" \
    | /usr/bin/tr ' ' '\n' | LC_ALL=C /usr/bin/sort -u | /usr/bin/paste -sd ' ' -)"
  [[ "$normalized_arches" == "arm64 x86_64" ]] \
    || fail "$label executable must contain exactly arm64 and x86_64"
  [[ -f "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" && \
    -f "$app_path/Contents/Resources/AgentIsland.icns" && \
    -f "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" && \
    -f "$app_path/Contents/Resources/Web/index.html" ]] \
    || fail "$label is missing a required privacy, icon, notice, or Web resource"
  /usr/bin/cmp -s "$PRODUCT_ROOT/Resources/PrivacyInfo.xcprivacy" \
    "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" \
    || fail "$label privacy manifest differs from the reviewed source manifest"
  if /usr/bin/find "$app_path" \( -name '.DS_Store' -o -name '._*' -o \
      -name '*.p8' -o -name '*.p12' -o -name '*.mobileprovision' -o \
      -name '*.m' -o -name '*.swift' -o -name '*.jsonl' \) -print -quit \
      | /usr/bin/grep -q .; then
    fail "$label contains source, fixture, credential, or Finder metadata"
  fi
}

validate_signature_and_profile() {
  local app_path="$1"
  local label="$2"
  local key="$3"
  local result_path="$4"
  local signature_info="$WORK_ROOT/$key-signature.txt"
  local signed_entitlements="$WORK_ROOT/$key-entitlements.plist"
  local signed_entitlements_json="$WORK_ROOT/$key-entitlements.json"
  local profile="$app_path/Contents/embedded.provisionprofile"
  local profile_plist="$WORK_ROOT/$key-profile.plist"
  local profile_entitlements="$WORK_ROOT/$key-profile-entitlements.plist"
  local profile_entitlements_json="$WORK_ROOT/$key-profile-entitlements.json"
  local signing_authority signed_team profile_prefix_count profile_team_count
  local profile_platform_count profile_prefix profile_team profile_platform
  local profile_expiration profile_expiration_epoch profile_cert_count
  local profile_uuid profile_name profile_cert_path profile_cert_base64
  local profile_cert_sha1 profile_certificate_matches=false

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" \
    || fail "$label code signature failed strict verification"
  /usr/bin/codesign -d --verbose=4 "$app_path" >/dev/null 2>"$signature_info" \
    || fail "$label signature metadata could not be read"
  signing_authority="$(/usr/bin/sed -n 's/^Authority=//p' "$signature_info" \
    | /usr/bin/head -n 1)"
  signed_team="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$signature_info" \
    | /usr/bin/head -n 1)"
  [[ "$signing_authority" == "$SELECTED_IDENTITY" ]] \
    || fail "$label was not signed with the selected App Distribution identity"
  [[ "$signed_team" == "$TEAM_ID" ]] \
    || fail "$label signature TeamIdentifier does not match the Release Team"
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$signature_info" \
    || fail "$label signature is missing Hardened Runtime"

  /usr/bin/codesign -d --entitlements - "$app_path" \
    >"$signed_entitlements" 2>/dev/null \
    || fail "$label signed entitlements could not be read"
  /usr/bin/plutil -convert json -o "$signed_entitlements_json" \
    "$signed_entitlements" \
    || fail "$label signed entitlements are not a valid plist"

  [[ -f "$profile" && ! -L "$profile" ]] \
    || fail "$label is missing Contents/embedded.provisionprofile"
  /usr/bin/security cms -D -i "$profile" -o "$profile_plist" >/dev/null 2>&1 \
    || fail "$label provisioning profile is not a decodable Apple-signed CMS profile"
  /usr/bin/plutil -lint "$profile_plist" >/dev/null \
    || fail "$label provisioning profile plist is invalid"
  /usr/bin/plutil -extract Entitlements xml1 -o "$profile_entitlements" \
    "$profile_plist" \
    || fail "$label provisioning profile has no Entitlements dictionary"
  /usr/bin/plutil -convert json -o "$profile_entitlements_json" \
    "$profile_entitlements" \
    || fail "$label provisioning-profile entitlements are invalid"

  if /usr/bin/plutil -type ProvisionedDevices "$profile_plist" >/dev/null 2>&1; then
    fail "$label provisioning profile is device-scoped, not a Mac App Store profile"
  fi
  if [[ "$(/usr/bin/plutil -extract ProvisionsAllDevices raw "$profile_plist" \
      2>/dev/null || true)" == "true" ]]; then
    fail "$label provisioning profile is an all-device Developer ID profile, not a Mac App Store profile"
  fi

  profile_prefix_count="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_team_count="$(/usr/bin/plutil -extract TeamIdentifier raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_platform_count="$(/usr/bin/plutil -extract Platform raw \
    "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_prefix_count" == "1" && "$profile_team_count" == "1" && \
    "$profile_platform_count" == "1" ]] \
    || fail "$label profile must contain one App ID prefix, TeamIdentifier, and platform"
  profile_prefix="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix.0 raw \
    "$profile_plist")"
  profile_team="$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$profile_plist")"
  profile_platform="$(/usr/bin/plutil -extract Platform.0 raw "$profile_plist")"
  [[ "$profile_team" == "$TEAM_ID" && "$profile_platform" == "OSX" ]] \
    || fail "$label profile belongs to another Team or platform"

  profile_expiration="$(/usr/bin/plutil -extract ExpirationDate raw \
    "$profile_plist" 2>/dev/null || true)"
  profile_expiration_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$profile_expiration" '+%s' 2>/dev/null || true)"
  [[ "$profile_expiration_epoch" == <-> ]] \
    || fail "$label profile has an unreadable ExpirationDate"
  (( profile_expiration_epoch > $(/bin/date -u '+%s') )) \
    || fail "$label provisioning profile expired at $profile_expiration"

  profile_cert_count="$(/usr/bin/plutil -extract DeveloperCertificates raw \
    "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_cert_count" == <-> && "$profile_cert_count" -gt 0 ]] \
    || fail "$label profile contains no distribution certificate"
  for (( profile_cert_index = 0; profile_cert_index < profile_cert_count; profile_cert_index++ )); do
    profile_cert_path="$WORK_ROOT/$key-profile-certificate-$profile_cert_index.cer"
    profile_cert_base64="$(/usr/bin/plutil -extract \
      "DeveloperCertificates.$profile_cert_index" raw "$profile_plist")"
    print -rn -- "$profile_cert_base64" | /usr/bin/base64 -D \
      >"$profile_cert_path" \
      || fail "$label profile contains an unreadable distribution certificate"
    profile_cert_sha1="$(LC_ALL=C LANG=C /usr/bin/shasum -a 1 \
      "$profile_cert_path" | /usr/bin/awk '{print toupper($1)}')"
    if [[ "$profile_cert_sha1" == "$SELECTED_IDENTITY_SHA1" ]]; then
      profile_certificate_matches=true
      break
    fi
  done
  [[ "$profile_certificate_matches" == true ]] \
    || fail "$label profile does not authorize the selected App Distribution certificate"

  /usr/bin/jq -e -s \
    --arg applicationIdentifier "$profile_prefix.$APP_BUNDLE_ID" \
    --arg team "$TEAM_ID" \
    --arg container "$CLOUD_CONTAINER_ID" '
      def app_identifier:
        .["com.apple.application-identifier"] // .["application-identifier"];
      .[0] as $signed
      | .[1] as $profile
      | ($signed | app_identifier) == $applicationIdentifier
        and ($profile | app_identifier) == $applicationIdentifier
        and ($signed | app_identifier) == ($profile | app_identifier)
        and $signed."com.apple.developer.team-identifier" == $team
        and $profile."com.apple.developer.team-identifier" == $team
        and (($signed."com.apple.security.get-task-allow" //
          $signed."get-task-allow" // false) == false)
        and (($profile."com.apple.security.get-task-allow" //
          $profile."get-task-allow" // false) == false)
        and $signed."com.apple.security.app-sandbox" == true
        and $signed."com.apple.security.files.user-selected.read-only" == true
        and $signed."com.apple.security.files.bookmarks.app-scope" == true
        and $signed."com.apple.security.network.client" == true
        and $signed."com.apple.developer.icloud-container-identifiers" == [$container]
        and $profile."com.apple.developer.icloud-container-identifiers" == [$container]
        and $signed."com.apple.developer.icloud-services" == ["CloudKit"]
        and $profile."com.apple.developer.icloud-services" == ["CloudKit"]
        and $signed."com.apple.developer.icloud-container-environment" == "Production"
        and $profile."com.apple.developer.icloud-container-environment" == "Production"
    ' "$signed_entitlements_json" "$profile_entitlements_json" >/dev/null \
    || fail "$label signature/profile failed exact sandbox, identifier, Team, or Production CloudKit validation"

  profile_uuid="$(/usr/bin/plutil -extract UUID raw "$profile_plist" 2>/dev/null || true)"
  profile_name="$(/usr/bin/plutil -extract Name raw "$profile_plist" 2>/dev/null || true)"
  [[ -n "$profile_uuid" && -n "$profile_name" ]] \
    || fail "$label profile is missing UUID or Name"
  /usr/bin/jq -n \
    --arg signingIdentity "$signing_authority" \
    --arg signingCertificateSHA1 "$SELECTED_IDENTITY_SHA1" \
    --arg applicationIdentifier "$profile_prefix.$APP_BUNDLE_ID" \
    --arg profileUUID "$profile_uuid" \
    --arg profileName "$profile_name" \
    --arg profileExpiration "$profile_expiration" \
    '{
      signingIdentity: $signingIdentity,
      signingCertificateSHA1: $signingCertificateSHA1,
      applicationIdentifier: $applicationIdentifier,
      profileUUID: $profileUUID,
      profileName: $profileName,
      profileExpiration: $profileExpiration,
      profileCertificateMatches: true
    }' >"$result_path"
}

/bin/mkdir -p "$DIST_ROOT"
STAGING_ROOT="$(mktemp -d "$DIST_ROOT/.agentisland-mac-store.XXXXXX")"
STAMP="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
FINAL_RELEASE_DIR="$DIST_ROOT/$VERSION-$BUILD_NUMBER-$STAMP"
[[ ! -e "$FINAL_RELEASE_DIR" && ! -L "$FINAL_RELEASE_DIR" ]] \
  || fail "release output already exists: $FINAL_RELEASE_DIR"

ARCHIVE_PATH="$STAGING_ROOT/AgentIslandMac.xcarchive"
ARCHIVE_ZIP="$STAGING_ROOT/AgentIslandMac.xcarchive.zip"
RESULT_BUNDLE="$STAGING_ROOT/AgentIslandMac-archive.xcresult"
ARCHIVE_SIGNATURE_RESULT="$WORK_ROOT/archive-signature-result.json"
ARCHIVE_FINAL="$FINAL_RELEASE_DIR/AgentIslandMac.xcarchive"
ARCHIVE_ZIP_FINAL="$FINAL_RELEASE_DIR/AgentIslandMac.xcarchive.zip"
RESULT_BUNDLE_FINAL="$FINAL_RELEASE_DIR/AgentIslandMac-archive.xcresult"
METADATA_PATH="$STAGING_ROOT/release-metadata.json"
METADATA_FINAL="$FINAL_RELEASE_DIR/release-metadata.json"

typeset -a ARCHIVE_ARGS
ARCHIVE_ARGS=(
  archive
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination 'generic/platform=macOS'
  -archivePath "$ARCHIVE_PATH"
  -resultBundlePath "$RESULT_BUNDLE"
  -derivedDataPath "$WORK_ROOT/ArchiveDerivedData"
)
[[ "$ALLOW_PROVISIONING_UPDATES" == true ]] \
  && ARCHIVE_ARGS+=(-allowProvisioningUpdates)

DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${ARCHIVE_ARGS[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SELECTED_IDENTITY" \
  AGENT_ISLAND_APP_BUNDLE_ID="$APP_BUNDLE_ID" \
  AGENT_ISLAND_ICLOUD_CONTAINER_ID="$CLOUD_CONTAINER_ID" \
  AGENT_ISLAND_DISPLAY_NAME="$DISPLAY_NAME" \
  AGENT_ISLAND_COPYRIGHT="$COPYRIGHT" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

[[ -d "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] \
  || fail "Xcode did not create the expected archive"
ARCHIVE_INFO="$ARCHIVE_PATH/Info.plist"
[[ -f "$ARCHIVE_INFO" ]] || fail "Xcode archive is missing Info.plist"
/usr/bin/plutil -lint "$ARCHIVE_INFO" >/dev/null \
  || fail "Xcode archive Info.plist is invalid"
[[ "$(/usr/bin/plutil -extract ApplicationProperties.CFBundleIdentifier raw \
    "$ARCHIVE_INFO" 2>/dev/null)" == "$APP_BUNDLE_ID" ]] \
  || fail "archive metadata bundle identifier does not match the Release build"
[[ "$(/usr/bin/plutil -extract ApplicationProperties.ApplicationPath raw \
    "$ARCHIVE_INFO" 2>/dev/null)" == "Applications/AgentIslandMac.app" ]] \
  || fail "archive metadata contains an unexpected application path"

archive_apps=("$ARCHIVE_PATH/Products/Applications"/*.app(/N))
(( ${#archive_apps} == 1 )) \
  || fail "archive must contain exactly one application product"
ARCHIVED_APP="${archive_apps[1]}"
[[ "${ARCHIVED_APP:t}" == "AgentIslandMac.app" ]] \
  || fail "archive contains an unexpected application product"
validate_app_info_and_contents "$ARCHIVED_APP" "archived App"
validate_signature_and_profile "$ARCHIVED_APP" "archived App" "archive" \
  "$ARCHIVE_SIGNATURE_RESULT"
ARCHIVED_PRIVACY_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$ARCHIVED_APP/Contents/Resources/PrivacyInfo.xcprivacy" \
  | /usr/bin/awk '{print $1}')"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent \
  "$ARCHIVE_PATH" "$ARCHIVE_ZIP"
/usr/bin/unzip -tq "$ARCHIVE_ZIP" >/dev/null \
  || fail "generated xcarchive ZIP failed integrity validation"
ZIP_LISTING="$WORK_ROOT/archive-zip-listing.txt"
/usr/bin/zipinfo -1 "$ARCHIVE_ZIP" >"$ZIP_LISTING"
[[ "$(/usr/bin/grep -Ec '^AgentIslandMac\.xcarchive/Info\.plist$' \
    "$ZIP_LISTING")" == "1" && \
  "$(/usr/bin/grep -Ec '^AgentIslandMac\.xcarchive/Products/Applications/AgentIslandMac\.app/Contents/Info\.plist$' \
    "$ZIP_LISTING")" == "1" ]] \
  || fail "xcarchive ZIP does not contain the one verified archive/app layout"
if /usr/bin/grep -Eq '(^|/)(__MACOSX|\.DS_Store|\._[^/]+)(/|$)|\.(p8|p12|mobileprovision|m|swift|jsonl)$' \
    "$ZIP_LISTING"; then
  fail "xcarchive ZIP contains forbidden Finder, source, fixture, or credential files"
fi
ARCHIVE_ZIP_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$ARCHIVE_ZIP" | /usr/bin/awk '{print $1}')"
print -r -- "$ARCHIVE_ZIP_SHA256  ${ARCHIVE_ZIP:t}" \
  >"$ARCHIVE_ZIP.sha256"
[[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$ARCHIVE_ZIP" \
  | /usr/bin/awk '{print $1}')" == "$ARCHIVE_ZIP_SHA256" ]] \
  || fail "xcarchive ZIP checksum changed after generation"

EXPORTED_PACKAGE=""
EXPORTED_PACKAGE_FINAL=""
PACKAGE_SHA256=""
PACKAGE_SIGNATURE_RESULT=""
EXPORTED_PROFILE_EXPIRATION=""
if [[ "$EXPORT_PACKAGE" == true ]]; then
  EXPORT_DIR="$STAGING_ROOT/export"
  EXPORT_DIR_FINAL="$FINAL_RELEASE_DIR/export"
  EXPORT_OPTIONS="$WORK_ROOT/ExportOptions.plist"
  /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert destination -string export "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert signingCertificate -string "$SELECTED_IDENTITY" \
    "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert installerSigningCertificate -string \
    "$SELECTED_INSTALLER_IDENTITY" "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool false \
    "$EXPORT_OPTIONS"

  /bin/mkdir -p "$EXPORT_DIR"
  typeset -a EXPORT_ARGS
  EXPORT_ARGS=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS"
  )
  [[ "$ALLOW_PROVISIONING_UPDATES" == true ]] \
    && EXPORT_ARGS+=(-allowProvisioningUpdates)
  DEVELOPER_DIR="$DEVELOPER_PATH" /usr/bin/xcodebuild "${EXPORT_ARGS[@]}"

  exported_packages=("$EXPORT_DIR"/*.pkg(.N))
  (( ${#exported_packages} == 1 )) \
    || fail "App Store export must produce exactly one flat .pkg"
  EXPORTED_PACKAGE="${exported_packages[1]}"
  EXPORTED_PACKAGE_FINAL="$EXPORT_DIR_FINAL/${EXPORTED_PACKAGE:t}"
  PACKAGE_SIGNATURE_INFO="$WORK_ROOT/package-signature.txt"
  /usr/sbin/pkgutil --check-signature "$EXPORTED_PACKAGE" \
    >"$PACKAGE_SIGNATURE_INFO" \
    || fail "exported package signature is invalid or untrusted"
  PACKAGE_SIGNING_AUTHORITY="$(/usr/bin/sed -n \
    's/^[[:space:]]*1\. //p' "$PACKAGE_SIGNATURE_INFO" | /usr/bin/head -n 1)"
  [[ "$PACKAGE_SIGNING_AUTHORITY" == "$SELECTED_INSTALLER_IDENTITY" ]] \
    || fail "exported package was not signed with the selected Installer identity"

  PACKAGE_EXPANDED="$WORK_ROOT/package-expanded"
  PACKAGE_PAYLOAD="$WORK_ROOT/package-payload"
  /usr/sbin/pkgutil --expand "$EXPORTED_PACKAGE" "$PACKAGE_EXPANDED" \
    || fail "exported package could not be expanded safely"
  payload_archives=("$PACKAGE_EXPANDED"/**/Payload(.N))
  (( ${#payload_archives} > 0 )) \
    || fail "exported package contains no payload archive"
  /bin/mkdir -p "$PACKAGE_PAYLOAD"
  for payload_archive in "${payload_archives[@]}"; do
    /usr/bin/ditto -x "$payload_archive" "$PACKAGE_PAYLOAD" \
      || fail "exported package payload could not be extracted safely"
  done
  packaged_apps=("$PACKAGE_PAYLOAD"/**/AgentIslandMac.app(/N))
  (( ${#packaged_apps} == 1 )) \
    || fail "exported package payload must contain exactly one AgentIslandMac.app"
  PACKAGED_APP="${packaged_apps[1]}"
  validate_app_info_and_contents "$PACKAGED_APP" "exported package App"
  PACKAGE_SIGNATURE_RESULT="$WORK_ROOT/package-app-signature-result.json"
  validate_signature_and_profile "$PACKAGED_APP" "exported package App" \
    "package-app" "$PACKAGE_SIGNATURE_RESULT"
  [[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
      "$PACKAGED_APP/Contents/Resources/PrivacyInfo.xcprivacy" \
      | /usr/bin/awk '{print $1}')" == "$ARCHIVED_PRIVACY_SHA256" ]] \
    || fail "exported package privacy manifest changed after Archive export"

  PACKAGE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
    "$EXPORTED_PACKAGE" | /usr/bin/awk '{print $1}')"
  print -r -- "$PACKAGE_SHA256  ${EXPORTED_PACKAGE:t}" \
    >"$EXPORTED_PACKAGE.sha256"
  [[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$EXPORTED_PACKAGE" \
    | /usr/bin/awk '{print $1}')" == "$PACKAGE_SHA256" ]] \
    || fail "exported package checksum changed after generation"
  EXPORTED_PROFILE_EXPIRATION="$(/usr/bin/jq -r '.profileExpiration' \
    "$PACKAGE_SIGNATURE_RESULT")"
fi

ARCHIVE_APPLICATION_IDENTIFIER="$(/usr/bin/jq -r '.applicationIdentifier' \
  "$ARCHIVE_SIGNATURE_RESULT")"
ARCHIVE_PROFILE_UUID="$(/usr/bin/jq -r '.profileUUID' "$ARCHIVE_SIGNATURE_RESULT")"
ARCHIVE_PROFILE_NAME="$(/usr/bin/jq -r '.profileName' "$ARCHIVE_SIGNATURE_RESULT")"
ARCHIVE_PROFILE_EXPIRATION="$(/usr/bin/jq -r '.profileExpiration' \
  "$ARCHIVE_SIGNATURE_RESULT")"
CREATED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n \
  --arg product "$PUBLIC_APP_NAME" \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg archivePath "$ARCHIVE_FINAL" \
  --arg archiveZip "$ARCHIVE_ZIP_FINAL" \
  --arg archiveZipSHA256 "$ARCHIVE_ZIP_SHA256" \
  --arg resultBundle "$RESULT_BUNDLE_FINAL" \
  --arg exportedPackage "$EXPORTED_PACKAGE_FINAL" \
  --arg packageSHA256 "$PACKAGE_SHA256" \
  --arg xcodeVersion "$XCODE_VERSION" \
  --arg macosSDK "$MACOS_SDK" \
  --arg teamID "$TEAM_ID" \
  --arg appBundleID "$APP_BUNDLE_ID" \
  --arg displayName "$DISPLAY_NAME" \
  --arg copyright "$COPYRIGHT" \
  --arg applicationIdentifier "$ARCHIVE_APPLICATION_IDENTIFIER" \
  --arg cloudContainerID "$CLOUD_CONTAINER_ID" \
  --arg privacyPolicyURL "$PRIVACY_POLICY_URL" \
  --arg supportURL "$SUPPORT_URL" \
  --arg privacyManifestSHA256 "$ARCHIVED_PRIVACY_SHA256" \
  --arg signingIdentity "$SELECTED_IDENTITY" \
  --arg signingCertificateSHA1 "$SELECTED_IDENTITY_SHA1" \
  --arg profileUUID "$ARCHIVE_PROFILE_UUID" \
  --arg profileName "$ARCHIVE_PROFILE_NAME" \
  --arg profileExpiration "$ARCHIVE_PROFILE_EXPIRATION" \
  --arg installerSigningIdentity "$SELECTED_INSTALLER_IDENTITY" \
  --arg exportedProfileExpiration "$EXPORTED_PROFILE_EXPIRATION" \
  --argjson allowProvisioningUpdates "$ALLOW_PROVISIONING_UPDATES" \
  --arg createdAt "$CREATED_AT" '
  {
    schemaVersion: 1,
    product: $product,
    platform: "macOS",
    distribution: "mac-app-store",
    version: $version,
    build: $build,
    archivePath: $archivePath,
    archiveZip: $archiveZip,
    archiveZipSHA256: $archiveZipSHA256,
    resultBundle: $resultBundle,
    exportedPackage: (if $exportedPackage == "" then null else $exportedPackage end),
    packageSHA256: (if $packageSHA256 == "" then null else $packageSHA256 end),
    exportMethod: (if $exportedPackage == "" then null else "app-store-connect" end),
    exportDestination: (if $exportedPackage == "" then null else "export" end),
    xcodeVersion: $xcodeVersion,
    macosSDK: $macosSDK,
    teamID: $teamID,
    appBundleID: $appBundleID,
    displayName: $displayName,
    copyright: $copyright,
    applicationIdentifier: $applicationIdentifier,
    cloudContainerID: $cloudContainerID,
    cloudKitEnvironment: "Production",
    privacyPolicyURL: $privacyPolicyURL,
    supportURL: $supportURL,
    privacyManifestSHA256: $privacyManifestSHA256,
    signingIdentity: $signingIdentity,
    signingCertificateSHA1: $signingCertificateSHA1,
    provisioningProfile: {
      uuid: $profileUUID,
      name: $profileName,
      expiration: $profileExpiration,
      certificateMatches: true
    },
    installerSigningIdentity: (
      if $installerSigningIdentity == "" then null else $installerSigningIdentity end
    ),
    exportedProvisioningProfileExpiration: (
      if $exportedProfileExpiration == "" then null else $exportedProfileExpiration end
    ),
    allowProvisioningUpdates: $allowProvisioningUpdates,
    uploaded: false,
    createdAt: $createdAt
  }' >"$METADATA_PATH"

/usr/bin/jq -e '
  .schemaVersion == 1 and
  .platform == "macOS" and
  .distribution == "mac-app-store" and
  .uploaded == false and
  .archiveZipSHA256 != "" and
  .provisioningProfile.certificateMatches == true and
  (if .exportedPackage == null then
     .packageSHA256 == null and .exportMethod == null and .exportDestination == null
   else
     .packageSHA256 != "" and .exportMethod == "app-store-connect" and
     .exportDestination == "export" and .installerSigningIdentity != null
   end)
' "$METADATA_PATH" >/dev/null \
  || fail "generated release metadata failed its non-uploading contract"

/bin/mv "$STAGING_ROOT" "$FINAL_RELEASE_DIR"
PUBLISHED=true

print -r -- "Archive: $ARCHIVE_FINAL"
print -r -- "Archive ZIP: $ARCHIVE_ZIP_FINAL"
[[ -n "$EXPORTED_PACKAGE_FINAL" ]] \
  && print -r -- "App Store package: $EXPORTED_PACKAGE_FINAL"
print -r -- "Metadata: $METADATA_FINAL"
print -r -- "No build was uploaded. Inspect these immutable candidates before a deliberate App Store Connect upload."
