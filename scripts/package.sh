#!/bin/bash
# Package Morphlet for distribution WITHOUT an Apple Developer account.
#
# This is the stopgap path. scripts/release.sh is the real one — use it as soon
# as you have a Developer ID, because everything below asks your users to do
# something they have been trained never to do.
#
# What this produces: a Release build with an AD-HOC signature (`-`), zipped.
# Ad-hoc rather than the local self-signed "LidGlass" certificate, for two
# reasons: nobody else's Mac trusts that certificate, so it buys nothing; and
# ad-hoc means anyone who clones this repo can build an identical artifact
# without needing a certificate in their keychain at all.
#
# What it does NOT do: notarize. Gatekeeper will refuse the app on first launch
# and every user will have to approve it by hand in System Settings. The
# INSTALL.txt written into the zip explains how.
#
#   ./scripts/package.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Release/Morphlet.app"
DIST="dist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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

echo "==> Verifying"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "Identifier|flags" || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# The staging directory's name becomes the folder users see when they unzip,
# so it has to be presentable — not "stage".
STAGE="$DIST/Morphlet-$VERSION"
ZIP="$DIST/Morphlet-$VERSION-unsigned.zip"

rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Morphlet.app"

cp packaging/INSTALL.txt "$STAGE/INSTALL.txt"

mkdir -p "$DIST"
rm -f "$ZIP"
# Clear extended attributes first, or ditto scatters AppleDouble "._" twins
# through the archive that show up as junk for anyone unzipping from a
# terminal. The code signature lives in the binary and _CodeSignature, not in
# xattrs, so this is safe — the verify below proves it.
xattr -cr "$STAGE"
# ditto, not zip: preserves the bundle's symlinks and permissions.
# --sequesterRsrc keeps any remaining metadata in one __MACOSX folder.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"

echo "==> Verifying the packaged copy unzips and still validates"
VERIFY=$(mktemp -d)
/usr/bin/ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --strict --verbose=2 "$VERIFY/Morphlet-$VERSION/Morphlet.app"
rm -rf "$VERIFY"

# Leave no registered build copy behind — see scripts/install.sh for why.
"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$APP"
[ -d /Applications/Morphlet.app ] && "$LSREGISTER" -f /Applications/Morphlet.app

echo
echo "Done: $ZIP"
echo
echo "Before you publish it:"
echo "  1. Unzip it on a Mac that has never run Morphlet and walk INSTALL.txt yourself."
echo "  2. Put the same Gatekeeper steps on the download page. People who hit an"
echo "     unexplained 'cannot be verified' dialog delete the app and leave."
echo "  3. Say plainly that nothing leaves the machine. You are asking for Screen"
echo "     Recording on an unsigned binary; the privacy story has to be up front."
