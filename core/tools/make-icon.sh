#!/bin/bash
# Regenerate AppIcon.icns from icon-source.html.
#
# icon-source.html reuses overlay.html's drawing code verbatim, so the Dock icon
# stays faithful to the live overlay. To restyle the icon, edit the tuning
# constants at the bottom of icon-source.html (T / VOL / SCALE) and re-run this.
#
# Run make-app.sh afterwards to bake the new icon into PushSense.app.
set -e
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/../Sources/pushsense/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "building renderer…"
swiftc -O "$DIR/RenderIcon.swift" -o "$WORK/render-icon" 2>&1 | grep -v "^$" | tail -3 || true

echo "rendering master…"
# WKWebView snapshots at the display's backing scale, so this lands at 2048 on
# a Retina Mac — good, that's our master.
"$WORK/render-icon" "$DIR/icon-source.html" "$WORK/master.png"

echo "building iconset…"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
  px="${spec%%:*}"; nm="${spec##*:}"
  sips -Z "$px" "$WORK/master.png" --out "$ICONSET/$nm.png" >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "done: $OUT"
