#!/usr/bin/env bash
# Build + install Workout Feed to a connected iPhone - no Xcode GUI needed.
# Usage: ./deploy.sh [device-identifier]   (defaults to the first connected device)
set -euo pipefail
cd "$(dirname "$0")"

DERIVED="${DERIVED:-/tmp/workout-feed-dd}"

# The .xcodeproj is generated (gitignored) - a fresh clone won't have it yet.
[ -d WorkoutFeed.xcodeproj ] || xcodegen generate

echo "- Building (signed) for device..."
xcodebuild -quiet -project WorkoutFeed.xcodeproj -scheme WorkoutFeed \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Debug-iphoneos/WorkoutFeed.app"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # Prefer a USB-connected phone; fall back to a Wi-Fi-paired one ("available (paired)").
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep ' connected ' | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)"
fi
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep 'available (paired)' | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)"
fi

if [ -z "$DEVICE" ]; then
  echo "x No connected or Wi-Fi-paired iPhone found. Connect/unlock it, or pass its identifier." >&2
  exit 1
fi

echo "- Installing to $DEVICE..."
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "OK Installed dev.bibixx.workout-feed"
