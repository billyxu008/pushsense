#!/bin/bash
# Package the SwiftPM binary into a proper PushTalk.app bundle. No shell wrapper
# — the real binary IS the CFBundleExecutable, so macOS associates the process
# with the bundle (required for the menubar item to appear). dylib paths are
# baked in via rpath.
set -e
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

DIR="$(cd "$(dirname "$0")" && pwd)"
# No model is baked in or bundled. The app resolves it at runtime from
# ~/Library/Application Support/PushTalk/models and downloads it on demand from
# the menubar (Speech model → Download). See ModelStore.swift.
APP="$DIR/PushTalk.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
FRAMEWORKS="$APP/Contents/Frameworks"

# Homebrew dylibs get COPIED into the bundle (see "bundling dylibs" below), so
# the app runs on a Mac with no Homebrew. Listed as real files, not the symlinks,
# because a bundle must not contain dangling links.
BREW_LIBS=(
  "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib"
  "/opt/homebrew/opt/ggml/lib/libggml.0.dylib"
  "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib"
  "/opt/homebrew/opt/libomp/lib/libomp.dylib"
)

# ggml's compute backends are separate .so PLUGINS that ggml_backend_load_all()
# discovers at RUNTIME — they never appear in otool -L, so the dependency check
# below cannot catch them. Metal (GPU) and the per-chip CPU kernels live here;
# without them the app silently falls back to a slow generic path on a machine
# that has no Homebrew. ggml reads GGML_BACKEND_PATH to locate them, which
# Whisper.swift points at this directory.
GGML_BACKEND_SRC="$(readlink -f /opt/homebrew/opt/ggml/libexec 2>/dev/null || echo /opt/homebrew/opt/ggml/libexec)"

echo "building release binary…"
swift build -c release 2>&1 | grep -viE "warning: building for|^\s+cd |builtin|Xcode-beta" | tail -3

echo "assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$DIR/.build/release/pushtalk" "$MACOS/PushTalk"

# overlay UI (WebView loads this from the bundle Resources)
cp "$DIR/Sources/pushtalk/Resources/overlay.html" "$RES/overlay.html"

# app icon (Dock / Finder / Get Info). Regenerate from icon-source.html — it
# reuses overlay.html's draw code so the icon matches the live overlay.
cp "$DIR/Sources/pushtalk/Resources/AppIcon.icns" "$RES/AppIcon.icns"

# ---- bundling dylibs -------------------------------------------------------
# Copy the whisper/ggml/libomp dylibs into Contents/Frameworks and rewrite every
# reference to point inside the bundle. Without this the app only runs on a Mac
# that has Homebrew with the exact same formulae installed — i.e. only this one.
#
# Each library is copied under its INSTALL NAME (the basename baked into the
# binary's load commands), so the rewritten paths resolve. @rpath references are
# handled by pointing the single rpath at Frameworks.
echo "bundling dylibs…"
mkdir -p "$FRAMEWORKS"
for src in "${BREW_LIBS[@]}"; do
  [ -f "$src" ] || { echo "missing dependency: $src" >&2; exit 1; }
  # Resolve the symlink so we copy the real Mach-O, but keep the basename the
  # load commands actually reference.
  cp -f "$(readlink -f "$src" 2>/dev/null || echo "$src")" "$FRAMEWORKS/$(basename "$src")"
  chmod u+w "$FRAMEWORKS/$(basename "$src")"
done

# The executable looks for its libs next to itself via @executable_path.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/PushTalk" 2>/dev/null || true

# Rewrite the main binary's references from /opt/homebrew/... to @rpath/...
for src in "${BREW_LIBS[@]}"; do
  base="$(basename "$src")"
  install_name_tool -change "$src" "@rpath/$base" "$MACOS/PushTalk" 2>/dev/null || true
done

# Rewrite each bundled dylib: its own id, and its references to its siblings.
# libwhisper points at ggml, libggml-base points at libomp, and libggml already
# uses @rpath for libggml-base — all of them must resolve inside the bundle.
for lib in "$FRAMEWORKS"/*.dylib; do
  base="$(basename "$lib")"
  install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
  for src in "${BREW_LIBS[@]}"; do
    install_name_tool -change "$src" "@rpath/$(basename "$src")" "$lib" 2>/dev/null || true
  done
done

# Copy the runtime backend plugins and rewrite their references too.
echo "bundling ggml backends…"
[ -d "$GGML_BACKEND_SRC" ] || { echo "missing ggml backends: $GGML_BACKEND_SRC" >&2; exit 1; }
for so in "$GGML_BACKEND_SRC"/*.so; do
  cp -f "$so" "$FRAMEWORKS/$(basename "$so")"
  chmod u+w "$FRAMEWORKS/$(basename "$so")"
done
for so in "$FRAMEWORKS"/*.so; do
  install_name_tool -add_rpath "@loader_path" "$so" 2>/dev/null || true
  for src in "${BREW_LIBS[@]}"; do
    install_name_tool -change "$src" "@rpath/$(basename "$src")" "$so" 2>/dev/null || true
  done
done

# Fail loudly if anything still points outside the bundle — a silent miss here
# means the app crashes on a machine without Homebrew, which is exactly the bug
# this whole block exists to prevent.
leaked=$(otool -L "$MACOS/PushTalk" "$FRAMEWORKS"/*.dylib "$FRAMEWORKS"/*.so 2>/dev/null | grep -E "^\s+/opt/homebrew" || true)
if [ -n "$leaked" ]; then
  echo "ERROR: unbundled Homebrew references remain:" >&2
  echo "$leaked" >&2
  exit 1
fi

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>PushTalk records your voice while you hold Right-Option, then types the transcription into the focused app.</string>
</dict>
</plist>
PLIST

# ---- signing ---------------------------------------------------------------
# Two modes:
#   default        ad-hoc signature, for local dev on this machine.
#   PT_SIGN_ID=…   a "Developer ID Application: …" identity, for distribution.
#                  Requires the hardened runtime, which notarization mandates.
#
# Nested code must be signed INSIDE-OUT — each dylib first, then the bundle.
# --deep is deliberately not used: Apple documents it as unsuitable for
# distribution because it ignores per-binary entitlements and requirements.
if [ -n "${PT_SIGN_ID:-}" ]; then
  echo "signing for distribution: $PT_SIGN_ID"
  # com.apple.security.cs.disable-library-validation lets the hardened runtime
  # load our own bundled dylibs, which are signed by us rather than Apple.
  ENT="$DIR/.build/pushtalk.entitlements"
  cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
PLIST

  for lib in "$FRAMEWORKS"/*.dylib "$FRAMEWORKS"/*.so; do
    codesign --force --timestamp --options runtime --sign "$PT_SIGN_ID" "$lib"
  done
  codesign --force --timestamp --options runtime --entitlements "$ENT" \
    --identifier com.billy.pushtalk --sign "$PT_SIGN_ID" "$APP"
  echo "verifying…"
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2
else
  # Ad-hoc. A stable designated requirement keeps TCC from treating every local
  # rebuild as a new Input Monitoring client (the ad-hoc cdhash changes).
  for lib in "$FRAMEWORKS"/*.dylib "$FRAMEWORKS"/*.so; do
    codesign --force --sign - "$lib"
  done
  codesign --force --sign - --identifier com.billy.pushtalk \
    --requirements '=designated => identifier "com.billy.pushtalk"' "$APP"
fi

echo "done: $APP"
du -sh "$APP" | cut -f1 | xargs echo "app size:"
