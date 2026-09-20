#!/bin/bash
# Build a distributable .dmg — the drag-to-Applications disk image people
# expect from a Mac app, with a custom background, positioned icons and no
# Finder chrome.
#
# Same caveat as scripts/package.sh: this is ad-hoc signed and NOT notarized,
# so Gatekeeper still refuses it on first launch and users still have to
# approve it in System Settings. scripts/release.sh is the fix for that.
#
#   ./scripts/dmg.sh
#
# The styling step drives Finder through AppleScript, which needs Automation
# permission for whatever terminal runs this — macOS asks once. If that is
# refused or unavailable, the script still produces a working (plain) image
# and says so, rather than failing the build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Release/Morphlet.app"
DIST="dist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Window and icon geometry. These must agree with packaging/dmg-background.png
# — the arrow in the artwork is drawn on the row the two icons sit on.
WIN_W=660; WIN_H=480
ICON_SIZE=112
APP_X=196;     APP_Y=178
APPS_X=462;    APPS_Y=178
# Reference material, tucked into the top right and out of the flow.
INSTALL_X=600; INSTALL_Y=74

# Signed with the local self-signed "LidGlass" certificate, NOT ad-hoc.
# Ad-hoc signing leaves the designated requirement empty, so macOS identifies
# the app by its exact binary fingerprint — which changes on every build. The
# result is that Gatekeeper approval and the Screen Recording grant are lost
# on every update, and users must re-approve each release. Signing with the
# certificate gives a stable requirement:
#
#   identifier "com.danielnebreja.morphlet" and certificate leaf = H"0c31..."
#
# That rule does not reference the binary, so it survives rebuilds. It does
# NOT make Gatekeeper accept the app — only notarization does that — it just
# stops the app changing identity every release.
echo "==> Building Release, signed with the local certificate"
xcodebuild -project Morphlet.xcodeproj -target Morphlet \
  -configuration Release -sdk macosx \
  build | tail -1

echo "==> Verifying the app before it goes in the image"
codesign --verify --strict --verbose=2 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOLNAME="Morphlet $VERSION"
STAGE="$DIST/dmg-stage"
DMG="$DIST/Morphlet-$VERSION.dmg"
RW="$DIST/Morphlet-$VERSION-rw.dmg"

rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Morphlet.app"
cp packaging/INSTALL.txt "$STAGE/INSTALL.txt"
# Nothing executable ships here on purpose. macOS blocks a quarantined app AND
# a quarantined .command with the same "not free from malware" dialog, so a
# helper that opens System Settings cannot work — it would only add a second
# scary warning. Until notarization, the window art is the only guidance that
# actually reaches the user.
# The /Applications shortcut is what makes the window a drag-and-drop target;
# without it people copy the app to Downloads and then wonder why Screen
# Recording permission keeps resetting.
ln -s /Applications "$STAGE/Applications"

# One multi-resolution TIFF, so the background stays sharp on Retina. A plain
# PNG would be upscaled and look soft on exactly the displays this app targets.
tiffutil -cathidpicheck packaging/dmg-background.png packaging/dmg-background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null

xattr -cr "$STAGE"

mkdir -p "$DIST"
rm -f "$DMG" "$RW"

echo "==> Creating a writable image to style"
# Styling means letting Finder write a .DS_Store, so the image has to be
# read-write first and is converted to compressed read-only at the end.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov \
  -format UDRW -fs HFS+ -quiet "$RW"
rm -rf "$STAGE"

MOUNT="/Volumes/$VOLNAME"
hdiutil attach "$RW" -nobrowse -quiet
# Finder needs a moment after the volume appears before it will accept
# window commands for it.
sleep 2

echo "==> Styling the window"
STYLED=yes
# Ordering matters and is easy to get wrong. The window must be open and
# sized before icons are positioned, the positions must be set last, and the
# window must be CLOSED at the end — closing is what makes Finder flush
# .DS_Store. An extra open/close cycle after positioning throws the layout
# away, which is exactly what happened the first time this was written.
STYLE_REPORT=$(osascript <<APPLESCRIPT || STYLED=no
tell application "Finder"
  tell disk "$VOLNAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    delay 1
    set position of item "Morphlet.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    set position of item "INSTALL.txt" of container window to {$INSTALL_X, $INSTALL_Y}
    update without registering applications
    delay 2
    -- Read back what Finder actually holds, so a silent failure surfaces here
    -- rather than in the finished image.
    set s to (icon size of opts) as string
    set appPos to position of item "Morphlet.app" of container window
    set p to (item 1 of appPos) as string
    close
    delay 1
    return s & "/" & p
  end tell
end tell
APPLESCRIPT
)

if [ "${STYLE_REPORT:-}" != "$ICON_SIZE/$APP_X" ]; then
  STYLED=no
  echo "    Finder reported '${STYLE_REPORT:-none}', expected '$ICON_SIZE/$APP_X'"
fi

if [ "$STYLED" = yes ]; then
  echo "    window styled and saved"
else
  echo "    WARNING: Finder styling failed (Automation permission?)."
  echo "    The image still works, it just opens as a plain folder view."
fi

# Make sure the .DS_Store Finder just wrote is flushed to the image.
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet

echo "==> Compressing to the final image"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"

echo "==> Verifying the image"
hdiutil verify -quiet "$DMG"

# Mount the finished article and check the app inside still validates — a DMG
# that builds fine but carries a broken signature is the failure worth
# catching before upload.
VERIFY=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$VERIFY" -nobrowse -quiet
trap 'hdiutil detach "$VERIFY" -quiet 2>/dev/null || true; rm -rf "$VERIFY"' EXIT
echo "==> Contents:"
ls -1 "$VERIFY" | sed 's|^|      |'
[ -f "$VERIFY/.background/background.tiff" ] && echo "      .background/background.tiff (hidden)"
[ -f "$VERIFY/.DS_Store" ] && echo "      .DS_Store (hidden, carries the window layout)" || echo "      WARNING: no .DS_Store — the window will not be styled"
codesign --verify --strict --verbose=2 "$VERIFY/Morphlet.app"
hdiutil detach "$VERIFY" -quiet
trap - EXIT
rm -rf "$VERIFY"

"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$APP"
[ -d /Applications/Morphlet.app ] && "$LSREGISTER" -f /Applications/Morphlet.app

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "Done: $DMG ($SIZE)"
echo
echo "Still unsigned by Apple: users get the 'cannot be verified' dialog and"
echo "must approve Morphlet in System Settings. Put those steps on the download"
echo "page as well as in INSTALL.txt."
