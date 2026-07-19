#!/bin/bash
# Package the SwiftPM binary into a proper PushTalk.app bundle. No shell wrapper
# — the real binary IS the CFBundleExecutable, so macOS associates the process
# with the bundle (required for the menubar item to appear). dylib paths are
# baked in via rpath.
set -e
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="~/transcriber-models/ggml-large-v3-turbo.bin"
APP="$DIR/PushTalk.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "building release binary…"
swift build -c release 2>&1 | grep -viE "warning: building for|^\s+cd |builtin|Xcode-beta" | tail -3

echo "assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$DIR/.build/release/pushtalk" "$MACOS/PushTalk"

# overlay UI (WebView loads this from the bundle Resources)
cp "$DIR/Sources/pushtalk/Resources/overlay.html" "$RES/overlay.html"

# Bake the whisper/ggml dylib dirs into the binary's rpath so it finds them
# without a launcher script or DYLD env var.
install_name_tool -add_rpath /opt/homebrew/opt/whisper-cpp/lib "$MACOS/PushTalk" 2>/dev/null || true
install_name_tool -add_rpath /opt/homebrew/opt/ggml/lib "$MACOS/PushTalk" 2>/dev/null || true

# Pass the model path via an env var baked into Info.plist is not possible; the
# binary reads argv[1]. Since the bundle launches with no args, embed the model
# path as a fallback the binary can read from its own Info.plist.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PushTalk</string>
  <key>CFBundleDisplayName</key><string>PushTalk</string>
  <key>CFBundleIdentifier</key><string>com.billy.pushtalk</string>
  <key>CFBundleVersion</key><string>0.1.1</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PushTalk</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>PushTalk records your voice while you hold Right-Option, then types the transcription into the focused app.</string>
  <key>PTModelPath</key><string>$MODEL</string>
</dict>
</plist>
PLIST

# Give TCC a stable designated requirement. The default ad-hoc signature uses
# a changing cdhash, which makes macOS treat every local rebuild as a different
# Input Monitoring client.
codesign --force --deep --sign - --identifier com.billy.pushtalk \
  --requirements '=designated => identifier "com.billy.pushtalk"' "$APP"

echo "done: $APP"
du -sh "$APP" | cut -f1 | xargs echo "app size:"
