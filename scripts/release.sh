#!/bin/bash
# Build, sign, notarize and staple a Morphlet build that other people can run.
#
# scripts/install.sh signs with the local self-signed certificate, which only
# works on this machine: anywhere else Gatekeeper refuses to open the app. For
# distribution macOS wants a Developer ID signature plus notarization, which is
# what this does.
#
# ── One-time setup (you do this, not the script) ────────────────────────────
#
#   1. Join the Apple Developer Program and create a "Developer ID Application"
#      certificate, then install it in your login keychain. Confirm with:
#
#          security find-identity -v -p codesigning
#
#   2. Create an app-specific password at https://appleid.apple.com ▸ Sign-In
#      and Security ▸ App-Specific Passwords.
#
#   3. Store the notarization credentials in your keychain, once. This prompts
#      for your Apple ID, team ID and that app-specific password, and nothing
#      sensitive is ever passed to this script or written into the repo:
#
#          xcrun notarytool store-credentials "morphlet-notary" --apple-id "<you@example.com>" --team-id "<TEAMID>"
#
# ── Every release ───────────────────────────────────────────────────────────
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID="TEAMID" \
#   ./scripts/release.sh
#
# Produces dist/Morphlet-<version>.zip, notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID, e.g. \"Developer ID Application: Your Name (TEAMID)\"}"
: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple team identifier}"
NOTARY_PROFILE="${NOTARY_PROFILE:-morphlet-notary}"

APP="build/Release/Morphlet.app"
DIST="dist"

echo "==> Building Release with Developer ID signing"
# CODE_SIGN_IDENTITY is overridden here rather than in the project so that
# everyday local builds keep using the self-signed certificate.
xcodebuild -project Morphlet.xcodeproj -target Morphlet \
  -configuration Release -sdk macosx \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build | tail -1

echo "==> Verifying signature"
# Notarization rejects anything not signed with a secure timestamp and the
# hardened runtime, so fail here rather than after a round trip to Apple.
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Timestamp" || true
if ! codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "ERROR: hardened runtime flag missing — notarization would be rejected." >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$DIST/Morphlet-$VERSION.zip"
mkdir -p "$DIST"
rm -f "$ZIP"

echo "==> Submitting $VERSION for notarization (this can take a few minutes)"
# ditto, not zip: it preserves the bundle's symlinks and extended attributes.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket"
# Staple the .app, then re-zip: the ticket has to travel inside the bundle so
# the app validates on a machine that is offline at first launch.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verifying the way Gatekeeper will"
spctl --assess --type execute --verbose=4 "$APP"

echo
echo "Done: $ZIP"
echo "Test it by unzipping on a Mac that has never seen this app before."
