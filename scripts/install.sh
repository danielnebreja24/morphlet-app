#!/bin/bash
# Build Morphlet, install it to /Applications, and delete the build copy.
#
# Defaults to a Release build. Debug is -Onone, single-architecture, and
# defines DEBUG=1, which turns on a per-frame angle log at 30 lines/second —
# fine while tuning the fold, wrong for something you actually run all day:
#
#     CONFIG=Debug ./scripts/install.sh
#
# Two copies of Morphlet confuse Spotlight and the Screen Recording permission
# list, and Xcode registers every build product with macOS — so the build copy
# must go. This script also never launches the app: an app started from a
# terminal gets its permission requests attributed to the terminal. Launch
# Morphlet from Spotlight or Finder instead.
#
# This installs a locally-signed build for this machine only. To produce
# something other people can run, see scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILT="build/$CONFIG/Morphlet.app"

xcodebuild -project Morphlet.xcodeproj -target Morphlet -configuration "$CONFIG" -sdk macosx build | tail -1

pkill -x Morphlet || true
rm -rf /Applications/Morphlet.app
cp -R "$BUILT" /Applications/Morphlet.app

"$LSREGISTER" -u "$BUILT"
rm -rf "$BUILT"
"$LSREGISTER" -f /Applications/Morphlet.app

echo "Installed /Applications/Morphlet.app ($CONFIG) — launch it from Spotlight or Finder."
