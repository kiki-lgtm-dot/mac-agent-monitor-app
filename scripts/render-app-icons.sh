#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_SVG="$PROJECT_DIR/Assets/AppIcon/AgentIsland-AppIcon.svg"
MAC_ICONSET="$PROJECT_DIR/Assets/AppIcon/AgentIsland.iconset"
MAC_ICNS="$PROJECT_DIR/Resources/AgentIsland.icns"
IOS_APPICON="$PROJECT_DIR/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset"
RENDER_ROOT="$(mktemp -d /private/tmp/agentisland-icon.XXXXXX)"
OPAQUE_PNG_TOOL="$RENDER_ROOT/OpaquePNG"

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  [[ "$RENDER_ROOT" == /private/tmp/agentisland-icon.* ]] && /bin/rm -rf "$RENDER_ROOT"
  exit "$exit_code"
}
trap cleanup EXIT

[[ -f "$SOURCE_SVG" ]] || { echo "Missing App Icon SVG" >&2; exit 2; }
/bin/mkdir -p "$MAC_ICONSET" "$IOS_APPICON"

/usr/bin/qlmanage -t -s 1024 -o "$RENDER_ROOT" "$SOURCE_SVG" >/dev/null 2>&1
RENDERED_PNG="$RENDER_ROOT/AgentIsland-AppIcon.svg.png"
MASTER_PNG="$RENDER_ROOT/AgentIsland-AppIcon-opaque.png"
[[ -f "$RENDERED_PNG" ]] || { echo "Quick Look did not render the App Icon" >&2; exit 2; }
/usr/bin/xcrun clang -fobjc-arc \
  -framework Foundation \
  -framework CoreGraphics \
  -framework ImageIO \
  "$PROJECT_DIR/Tools/OpaquePNG.m" \
  -o "$OPAQUE_PNG_TOOL"
"$OPAQUE_PNG_TOOL" "$RENDERED_PNG" "$MASTER_PNG"
[[ "$(/usr/bin/sips -g hasAlpha "$MASTER_PNG" | /usr/bin/awk '/hasAlpha:/ {print $2}')" == "no" ]] || {
  echo "Rendered App Icon still contains an alpha channel" >&2
  exit 2
}

render_png() {
  local pixels="$1"
  local destination="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$MASTER_PNG" --out "$destination" >/dev/null
}

render_png 16 "$MAC_ICONSET/icon_16x16.png"
render_png 32 "$MAC_ICONSET/icon_16x16@2x.png"
render_png 32 "$MAC_ICONSET/icon_32x32.png"
render_png 64 "$MAC_ICONSET/icon_32x32@2x.png"
render_png 128 "$MAC_ICONSET/icon_128x128.png"
render_png 256 "$MAC_ICONSET/icon_128x128@2x.png"
render_png 256 "$MAC_ICONSET/icon_256x256.png"
render_png 512 "$MAC_ICONSET/icon_256x256@2x.png"
render_png 512 "$MAC_ICONSET/icon_512x512.png"
render_png 1024 "$MAC_ICONSET/icon_512x512@2x.png"
/usr/bin/iconutil -c icns "$MAC_ICONSET" -o "$MAC_ICNS"

typeset -A ios_sizes
ios_sizes=(
  iphone-notification-2x 40
  iphone-notification-3x 60
  iphone-settings-2x 58
  iphone-settings-3x 87
  iphone-spotlight-2x 80
  iphone-spotlight-3x 120
  iphone-app-2x 120
  iphone-app-3x 180
  ios-marketing 1024
)
for name pixels in ${(kv)ios_sizes}; do
  render_png "$pixels" "$IOS_APPICON/$name.png"
  [[ "$(/usr/bin/sips -g hasAlpha "$IOS_APPICON/$name.png" | /usr/bin/awk '/hasAlpha:/ {print $2}')" == "no" ]] || {
    echo "iOS App Icon contains an alpha channel: $name.png" >&2
    exit 2
  }
done

echo "$MAC_ICNS"
echo "$IOS_APPICON"
