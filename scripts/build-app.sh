#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB

PROJECT_DIR="${0:A:h:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/AgentIsland.app"
ARCHIVE_PATH="$DIST_DIR/AgentIsland-macOS-universal.zip"
STAGING_ROOT="$(mktemp -d /private/tmp/agentisland-build.XXXXXX)"
STAGING_APP="$STAGING_ROOT/AgentIsland.app"
VERIFY_DIR="$STAGING_ROOT/verify"
CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$PROJECT_DIR/.native-build"
PUBLISH_ROOT=""
BACKUP_ROOT=""
COMMIT_STARTED=0
COMMIT_DONE=0
HAD_OLD_APP=0
HAD_OLD_ARCHIVE=0
SIGN_IDENTITY="${AGENT_ISLAND_CODESIGN_IDENTITY:--}"
BUNDLE_ID_OVERRIDE="${AGENT_ISLAND_BUNDLE_ID:-}"
VERSION_OVERRIDE="${AGENT_ISLAND_VERSION:-}"
BUILD_OVERRIDE="${AGENT_ISLAND_BUILD_NUMBER:-}"
DISPLAY_NAME_OVERRIDE="${AGENT_ISLAND_DISPLAY_NAME:-}"
ENTITLEMENTS_PATH="${AGENT_ISLAND_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${AGENT_ISLAND_PROVISIONING_PROFILE:-}"
PRIVACY_POLICY_URL="${AGENT_ISLAND_PRIVACY_POLICY_URL:-}"
SUPPORT_URL="${AGENT_ISLAND_SUPPORT_URL:-}"
DEFAULT_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$PROJECT_DIR/Resources/Info.plist")"
EFFECTIVE_BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-$DEFAULT_BUNDLE_ID}"

validate_bundle_id() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ "$value" == [A-Za-z0-9.-]## && "$value" == *.* && "$value" != *..* && "$value" != .* && "$value" != *. ]]
}

validate_version() {
  local value="$1"
  [[ -z "$value" || "$value" == <->(|.<->)(|.<->) ]]
}

validate_display_name() {
  local value="$1"
  local comparison
  [[ -z "$value" ]] && return 0
  (( ${#value} >= 2 && ${#value} <= 30 )) || return 1
  [[ "$value" != [[:space:]]* && "$value" != *[[:space:]] && "$value" != *[[:cntrl:]]* ]] || return 1
  comparison="$(print -rn -- "$value" | /usr/bin/tr -cd '[:alnum:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$comparison" != "agentisland" && "$comparison" != "tasklume" ]]
}

validate_optional_release_url() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ "$value" == https://* && "$value" != *[[:space:]]* ]]
}

sign_app() {
  local app_path="$1"
  local -a sign_args
  sign_args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    sign_args+=(--timestamp=none)
  else
    sign_args+=(--options runtime --timestamp)
  fi
  [[ -n "$ENTITLEMENTS_PATH" ]] && sign_args+=(--entitlements "$ENTITLEMENTS_PATH")
  /usr/bin/codesign "${sign_args[@]}" "$app_path"
}

restore_old_outputs() {
  set +e

  if [[ -e "$BACKUP_ROOT/AgentIsland.app" ]]; then
    rm -rf "$APP_DIR"
    mv "$BACKUP_ROOT/AgentIsland.app" "$APP_DIR"
  elif (( ! HAD_OLD_APP )); then
    rm -rf "$APP_DIR"
  fi

  if [[ -e "$BACKUP_ROOT/AgentIsland-macOS-universal.zip" ]]; then
    rm -f "$ARCHIVE_PATH"
    mv "$BACKUP_ROOT/AgentIsland-macOS-universal.zip" "$ARCHIVE_PATH"
  elif (( ! HAD_OLD_ARCHIVE )); then
    rm -f "$ARCHIVE_PATH"
  fi
}

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM

  if (( COMMIT_STARTED && ! COMMIT_DONE )); then
    restore_old_outputs
  fi

  rm -rf "$STAGING_ROOT"
  [[ -n "$PUBLISH_ROOT" ]] && rm -rf "$PUBLISH_ROOT"
  [[ -n "$BACKUP_ROOT" ]] && rm -rf "$BACKUP_ROOT"
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$APP_DIR" == "$PROJECT_DIR/dist/AgentIsland.app" ]] || { echo "Refusing unsafe app path" >&2; exit 2; }
[[ "$ARCHIVE_PATH" == "$PROJECT_DIR/dist/AgentIsland-macOS-universal.zip" ]] || { echo "Refusing unsafe archive path" >&2; exit 2; }
validate_bundle_id "$BUNDLE_ID_OVERRIDE" || { echo "Invalid AGENT_ISLAND_BUNDLE_ID" >&2; exit 2; }
validate_version "$VERSION_OVERRIDE" || { echo "Invalid AGENT_ISLAND_VERSION" >&2; exit 2; }
[[ -z "$BUILD_OVERRIDE" || "$BUILD_OVERRIDE" == <-> ]] || { echo "Invalid AGENT_ISLAND_BUILD_NUMBER" >&2; exit 2; }
validate_display_name "$DISPLAY_NAME_OVERRIDE" || {
  echo "AGENT_ISLAND_DISPLAY_NAME must be 2-30 characters, have no surrounding/control whitespace, and not equal Agent Island or TaskLume" >&2
  exit 2
}
validate_optional_release_url "$PRIVACY_POLICY_URL" || { echo "AGENT_ISLAND_PRIVACY_POLICY_URL must be HTTPS" >&2; exit 2; }
validate_optional_release_url "$SUPPORT_URL" || { echo "AGENT_ISLAND_SUPPORT_URL must be HTTPS" >&2; exit 2; }
if [[ -n "$ENTITLEMENTS_PATH" || -n "$PROVISIONING_PROFILE" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "Capabilities require a non-ad-hoc signing identity" >&2; exit 2; }
  [[ -f "$ENTITLEMENTS_PATH" ]] || { echo "AGENT_ISLAND_ENTITLEMENTS must name an existing file" >&2; exit 2; }
  [[ -f "$PROVISIONING_PROFILE" ]] || { echo "AGENT_ISLAND_PROVISIONING_PROFILE must name an existing file" >&2; exit 2; }
  /usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null
  if /usr/bin/grep -Eqi 'yourname|yourdomain|example|placeholder' "$ENTITLEMENTS_PATH"; then
    echo "AGENT_ISLAND_ENTITLEMENTS still contains placeholder values" >&2
    exit 2
  fi
  PROFILE_PLIST="$STAGING_ROOT/provisioning-profile.plist"
  /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST" >/dev/null
  PROFILE_ENTITLEMENTS_PLIST="$STAGING_ROOT/provisioning-profile-entitlements.plist"
  PROFILE_ENTITLEMENTS_JSON="$STAGING_ROOT/provisioning-profile-entitlements.json"
  /usr/bin/plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS_PLIST" "$PROFILE_PLIST"
  /usr/bin/plutil -convert json -o "$PROFILE_ENTITLEMENTS_JSON" "$PROFILE_ENTITLEMENTS_PLIST"
  PROFILE_APP_ID="$(/usr/bin/jq -r '.["com.apple.application-identifier"] // empty' "$PROFILE_ENTITLEMENTS_JSON")"
  PROFILE_TEAM_ID="$(/usr/bin/jq -r '.["com.apple.developer.team-identifier"] // empty' "$PROFILE_ENTITLEMENTS_JSON")"
  SOURCE_ENTITLEMENTS_JSON="$(/usr/bin/plutil -convert json -o - "$ENTITLEMENTS_PATH")"
  SOURCE_APP_ID="$(print -r -- "$SOURCE_ENTITLEMENTS_JSON" \
    | /usr/bin/jq -r '.["com.apple.application-identifier"] // empty')"
  SOURCE_TEAM_ID="$(print -r -- "$SOURCE_ENTITLEMENTS_JSON" \
    | /usr/bin/jq -r '.["com.apple.developer.team-identifier"] // empty')"
  [[ "$PROFILE_APP_ID" == *."$EFFECTIVE_BUNDLE_ID" ]] || {
    echo "Provisioning profile does not authorize $EFFECTIVE_BUNDLE_ID" >&2
    exit 2
  }
  [[ -n "$PROFILE_TEAM_ID" && "$SOURCE_APP_ID" == "$PROFILE_APP_ID" && \
    "$SOURCE_TEAM_ID" == "$PROFILE_TEAM_ID" ]] || {
    echo "Entitlements App ID/team do not match the macOS provisioning profile" >&2
    exit 2
  }
  PROFILE_TEAM_COUNT="$(/usr/bin/plutil -extract TeamIdentifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_TOP_LEVEL_TEAM="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PLATFORM_COUNT="$(/usr/bin/plutil -extract Platform raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PLATFORM="$(/usr/bin/plutil -extract Platform.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
  [[ "$PROFILE_TEAM_COUNT" == "1" && "$PROFILE_TOP_LEVEL_TEAM" == "$PROFILE_TEAM_ID" && \
    "$PROFILE_PLATFORM_COUNT" == "1" && "$PROFILE_PLATFORM" == "OSX" && \
    "$PROFILE_PROVISIONS_ALL_DEVICES" == "true" && "$PROFILE_EXPIRATION_EPOCH" == <-> && \
    "$PROFILE_EXPIRATION_EPOCH" -gt "$(/bin/date -u '+%s')" ]] || {
    echo "Capabilities require an unexpired all-device OSX provisioning profile for the signing Team" >&2
    exit 2
  }
fi
mkdir -p "$DIST_DIR" "$MACOS_DIR" "$RESOURCES_DIR/Web" "$BUILD_DIR"
PUBLISH_ROOT="$(mktemp -d "$DIST_DIR/.agentisland-publish.XXXXXX")"
# Avoid an .app suffix while staging under Desktop: File Provider otherwise
# recognizes the temporary bundle and may attach Finder metadata before it can
# be verified. The final same-filesystem rename supplies the public .app name.
PUBLISH_APP="$PUBLISH_ROOT/AgentIsland.pending"
PUBLISH_ARCHIVE="$PUBLISH_ROOT/AgentIsland-macOS-universal.zip"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
clang \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDK_PATH" \
  -framework Cocoa \
  -framework WebKit \
  -framework QuartzCore \
  -framework UniformTypeIdentifiers \
  -framework Security \
  -framework CloudKit \
  -lsqlite3 \
  "$PROJECT_DIR/Native/AgentIsland.m" \
  -o "$MACOS_DIR/AgentIsland"

COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/AgentIsland.icns" "$RESOURCES_DIR/AgentIsland.icns"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Web/index.html" "$RESOURCES_DIR/Web/index.html"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
[[ -n "$PROVISIONING_PROFILE" ]] && COPYFILE_DISABLE=1 cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
[[ -n "$BUNDLE_ID_OVERRIDE" ]] && /usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID_OVERRIDE" "$CONTENTS_DIR/Info.plist"
[[ -n "$VERSION_OVERRIDE" ]] && /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION_OVERRIDE" "$CONTENTS_DIR/Info.plist"
[[ -n "$BUILD_OVERRIDE" ]] && /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_OVERRIDE" "$CONTENTS_DIR/Info.plist"
[[ -n "$DISPLAY_NAME_OVERRIDE" ]] && /usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME_OVERRIDE" "$CONTENTS_DIR/Info.plist"
[[ -n "$PRIVACY_POLICY_URL" ]] && /usr/bin/plutil -replace AgentIslandPrivacyPolicyURL -string "$PRIVACY_POLICY_URL" "$CONTENTS_DIR/Info.plist"
[[ -n "$SUPPORT_URL" ]] && /usr/bin/plutil -replace AgentIslandSupportURL -string "$SUPPORT_URL" "$CONTENTS_DIR/Info.plist"

xattr -cr "$STAGING_APP"
sign_app "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

# Stage the app on the destination filesystem so the final rename is atomic.
# Re-sign it there because Desktop File Provider can attach Finder metadata to
# app bundles copied into a Desktop-backed dist directory.
COPYFILE_DISABLE=1 ditto --noextattr --norsrc "$STAGING_APP" "$PUBLISH_APP"
xattr -cr "$PUBLISH_APP"
sign_app "$PUBLISH_APP"
codesign --verify --deep --strict --verbose=2 "$PUBLISH_APP"

# Desktop may be managed by File Provider and re-attach Finder metadata to a
# visible .app bundle. The archive is therefore the canonical distributable:
# it is made from the clean staging bundle and verified after extraction.
COPYFILE_DISABLE=1 ditto --noextattr --norsrc -c -k --keepParent "$STAGING_APP" "$PUBLISH_ARCHIVE"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$PUBLISH_ARCHIVE" "$VERIFY_DIR"
xattr -cr "$VERIFY_DIR/AgentIsland.app"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/AgentIsland.app"

# Do not touch either published artifact until both staged outputs have passed
# verification. Keep the old pair in the same directory tree so any failure
# during the two renames can restore them without crossing filesystems.
BACKUP_ROOT="$(mktemp -d "$DIST_DIR/.agentisland-backup.XXXXXX")"
[[ -e "$APP_DIR" ]] && HAD_OLD_APP=1
[[ -e "$ARCHIVE_PATH" ]] && HAD_OLD_ARCHIVE=1
COMMIT_STARTED=1

(( HAD_OLD_APP )) && mv "$APP_DIR" "$BACKUP_ROOT/AgentIsland.app"
(( HAD_OLD_ARCHIVE )) && mv "$ARCHIVE_PATH" "$BACKUP_ROOT/AgentIsland-macOS-universal.zip"
mv "$PUBLISH_APP" "$APP_DIR"
mv "$PUBLISH_ARCHIVE" "$ARCHIVE_PATH"

# Do not mutate the visible bundle after its rename: Desktop File Provider can
# race by re-attaching Finder metadata. The app was verified in the same-filesystem
# publish directory, while the cleanly built and strictly re-verified ZIP remains
# the canonical distributable.

COMMIT_DONE=1
rm -rf "$BACKUP_ROOT"
BACKUP_ROOT=""

echo "$APP_DIR"
