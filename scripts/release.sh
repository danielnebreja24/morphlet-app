#!/bin/bash
# Build, sign, notarize and staple the disk image people actually download.
#
# This is the real distribution path. scripts/dmg.sh on its own signs with the
# local certificate, which only works on this machine; everywhere else
# Gatekeeper refuses it and the user has to approve the app by hand in System
# Settings. Notarizing removes that step entirely.
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
#          xcrun notarytool store-credentials "<profile-name>" --apple-id "<you@example.com>" --team-id "<TEAMID>"
#
# ── Every release ───────────────────────────────────────────────────────────
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID="TEAMID" \
#   NOTARY_PROFILE="<profile-name>" \
#   ./scripts/release.sh
#
# Produces dist/Morphlet-<version>.dmg, notarized and stapled, ready to attach
# to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID, e.g. \"Developer ID Application: Your Name (TEAMID)\"}"
: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple team identifier}"
NOTARY_PROFILE="${NOTARY_PROFILE:-morphlet-notary}"

# Build the same styled disk image users get, but signed for distribution.
# Notarizing the image rather than a bare zip means the ticket travels inside
# the thing people actually download.
echo "==> Building the disk image with Developer ID signing"
SIGN_IDENTITY="$DEVELOPER_ID" TEAM_ID="$TEAM_ID" ./scripts/dmg.sh

VERSION=$(grep -o 'MARKETING_VERSION = [0-9.]*' Morphlet.xcodeproj/project.pbxproj | head -1 | cut -d' ' -f3)
DMG="dist/Morphlet-$VERSION.dmg"
[ -f "$DMG" ] || { echo "ERROR: $DMG was not produced." >&2; exit 1; }

echo
echo "==> Checking the signature before spending a round trip to Apple"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; rm -rf "$MOUNT"' EXIT
codesign --verify --strict --verbose=2 "$MOUNT/Morphlet.app"
# One capture, then assert against it. Reading the flags needs --verbose=4;
# at --verbose=2 codesign does not print them at all, which made an earlier
# version of this check fail on a perfectly good signature.
DETAILS=$(codesign -dv --verbose=4 "$MOUNT/Morphlet.app" 2>&1)
echo "$DETAILS" | grep -E "Authority|TeamIdentifier|flags|Timestamp" | sed 's/^/    /'
# Notarization rejects anything without the hardened runtime or a secure
# timestamp, so fail here rather than after a submission.
grep -q "flags=.*runtime" <<<"$DETAILS" || {
  echo "ERROR: hardened runtime missing — notarization would be rejected." >&2; exit 1; }
grep -q "^Timestamp=" <<<"$DETAILS" || {
  echo "ERROR: no secure timestamp — notarization would be rejected." >&2; exit 1; }
grep -q "Developer ID Application" <<<"$DETAILS" || {
  echo "ERROR: not signed with a Developer ID — Apple will refuse it." >&2; exit 1; }
hdiutil detach "$MOUNT" -force -quiet
trap - EXIT
rm -rf "$MOUNT"

echo
echo "==> Signing the disk image itself"
# The app inside was signed at build time, but the .dmg is a separate artifact.
# Without this, spctl reports "no usable signature" for the image even after
# notarization, because there is no signature for it to assess.
codesign --sign "$DEVELOPER_ID" --timestamp --force "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo
echo "==> Submitting $VERSION for notarization (a few minutes)"
# --wait exits 0 even when Apple rejects the build, so read the status back
# rather than trusting the exit code. Stapling an Invalid submission silently
# produces a disk image that still fails on a stranger's Mac.
SUBMIT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
echo "$SUBMIT"
SUBMISSION_ID=$(grep -m1 -oE "id: [0-9a-f-]{36}" <<<"$SUBMIT" | head -1 | cut -d' ' -f2)
if ! grep -qE "status: Accepted" <<<"$SUBMIT"; then
  echo >&2
  echo "ERROR: Apple did not accept this build. Their reasons:" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(sys.stdin.read()); raise SystemExit
print('  ' + d.get('statusSummary',''))
seen=set()
for i in d.get('issues') or []:
    key=(i.get('message'), i.get('path'))
    if key in seen: continue
    seen.add(key)
    print(f\"  - {i.get('message')}\")
    print(f\"    {i.get('path')}\")
    if i.get('docUrl'): print(f\"    {i['docUrl']}\")
" >&2
  exit 1
fi

echo
echo "==> Stapling the ticket to the disk image"
# Stapling the .dmg means it validates on a Mac that is offline at first launch.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "==> Verifying the way Gatekeeper will"
# This is the check that used to say "rejected". It must now say "accepted".
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

VERIFY=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$VERIFY" -nobrowse -quiet
spctl --assess --type execute --verbose=2 "$VERIFY/Morphlet.app"
xcrun stapler validate "$VERIFY/Morphlet.app" || true
hdiutil detach "$VERIFY" -force -quiet
rm -rf "$VERIFY"

echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1)) — notarized and stapled."
echo
echo "This build changes the signing identity, so anyone upgrading from an"
echo "unsigned release re-approves Screen Recording once. From here on the"
echo "Developer ID keeps the app's identity stable across every version."
