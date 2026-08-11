#!/bin/bash
# Build a distributable .dmg from PushSense.app.
#
# Works with or without an Apple Developer account:
#   unsigned (default) — ad-hoc signed. Gatekeeper blocks it on first launch, so
#                        the disk image ships a README telling the user to
#                        right-click → Open once. Fine for sending to friends and
#                        early testers; NOT fine for paying customers.
#   PT_SIGN_ID=…        Developer ID signed + notarized (see make-app.sh). Then
#                        the app opens normally with no warning.
#
# The quarantine flag is what actually triggers the warning: macOS sets it on
# anything downloaded, and an unnotarized app cannot clear it. Right-click → Open
# is the documented user-side override; `xattr -d` is the terminal equivalent.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/PushSense.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
STAGE="$DIR/.build/dmg-stage"
DMG="$DIR/PushSense-$VERSION.dmg"

[ -d "$APP" ] || { echo "no $APP — run make-app.sh first" >&2; exit 1; }

echo "staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Only include the first-launch instructions when the app isn't notarized —
# a properly signed build opens with no warning and the note would confuse.
if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
PushSense — first launch
========================

1. Drag PushSense to the Applications folder.

2. IMPORTANT — the first time you open it:
   Right-click (or Control-click) PushSense in Applications and choose "Open".
   Then click "Open" again in the dialog.

   Double-clicking will NOT work the first time. macOS shows
   "Apple could not verify PushSense is free of malware" because this
   build is not notarized yet. Right-click → Open is the standard way
   to approve it. You only need to do this once.

3. Grant two permissions when asked (System Settings → Privacy & Security):
   - Microphone        — to hear you
   - Input Monitoring  — to detect the hotkey
   - Accessibility     — to type the text into the focused app

4. Download a speech model:
   Click the PushSense icon in the menubar → Speech model → pick one.
   "Large v3 Turbo" (1.6 GB) is recommended. It downloads once.

5. Hold Right-Command (default), speak, release.
   The text is typed into whatever field you're focused on.

Everything runs on your Mac. No audio ever leaves your computer.
TXT
fi

echo "building $DMG …"
hdiutil create -volname "PushSense $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

rm -rf "$STAGE"
echo "done: $DMG"
/usr/bin/du -sh "$DMG" | cut -f1 | xargs echo "dmg size:"
