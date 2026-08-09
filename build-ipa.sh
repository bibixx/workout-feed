#!/usr/bin/env bash
# Build an unsigned Release .ipa for sideloading (SideStore/AltStore re-sign it on-device).
# Usage: ./build-ipa.sh                    writes dist/WorkoutFeed.ipa
# Env:   DERIVED=<path>                    derived-data dir (default /tmp/workout-feed-dd-release)
set -euo pipefail
cd "$(dirname "$0")"

DERIVED="${DERIVED:-/tmp/workout-feed-dd-release}"

# The .xcodeproj is generated (gitignored) - a fresh clone won't have it yet.
[ -d WorkoutFeed.xcodeproj ] || xcodegen generate

echo "- Building Release (unsigned) for device..."
xcodebuild -quiet -project WorkoutFeed.xcodeproj -scheme WorkoutFeed \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
APP="$DERIVED/Build/Products/Release-iphoneos/WorkoutFeed.app"

echo "- Packaging dist/WorkoutFeed.ipa..."
rm -rf dist/Payload dist/WorkoutFeed.ipa
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && zip -qry WorkoutFeed.ipa Payload)
rm -rf dist/Payload

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
SIZE="$(stat -f%z dist/WorkoutFeed.ipa)"
echo "OK dist/WorkoutFeed.ipa (v$VERSION, $SIZE bytes)"
