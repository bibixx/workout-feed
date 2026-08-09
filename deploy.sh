#!/usr/bin/env bash
# Build + install Workout Feed - no Xcode GUI needed.
# Usage: ./deploy.sh [device-identifier]   install to an iPhone (defaults to the first connected one)
#        ./deploy.sh --sim                 build for the iOS Simulator, boot one, install + launch
# Env:   DERIVED=<path>                    derived-data dir (default /tmp/workout-feed-dd)
set -euo pipefail
cd "$(dirname "$0")"

DERIVED="${DERIVED:-/tmp/workout-feed-dd}"
BUNDLE_ID="dev.bibixx.workout-feed"
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

SIM=0
DEVICE="${1:-}"
if [ "$DEVICE" = "--sim" ] || [ "$DEVICE" = "-s" ]; then
  SIM=1
  DEVICE=""
fi

# Resolve the install target BEFORE the (multi-minute) build, so a missing phone fails fast.
if [ "$SIM" = 0 ] && [ -z "$DEVICE" ]; then
  # Prefer an actively connected iPhone; fall back to a Wi-Fi-paired one ("available (paired)").
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep ' connected ' | grep -oE "$UUID_RE" | head -1 || true)"
  if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep 'available (paired)' | grep -oE "$UUID_RE" | head -1 || true)"
  fi
  if [ -z "$DEVICE" ]; then
    echo "x No connected or Wi-Fi-paired iPhone found. Connect/unlock it, pass its identifier, or use --sim." >&2
    exit 1
  fi
fi

# The .xcodeproj is generated (gitignored) - a fresh clone won't have it yet.
[ -d WorkoutFeed.xcodeproj ] || xcodegen generate

if [ "$SIM" = 1 ]; then
  echo "- Building for the iOS Simulator..."
  xcodebuild -quiet -project WorkoutFeed.xcodeproj -scheme WorkoutFeed \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" build
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/WorkoutFeed.app"

  # Reuse a booted simulator if there is one; otherwise boot the first available iPhone.
  SIM_UDID="$(xcrun simctl list devices booted | grep 'iPhone' | grep -oE "$UUID_RE" | head -1 || true)"
  if [ -z "$SIM_UDID" ]; then
    SIM_UDID="$(xcrun simctl list devices available | grep -E '^\s+iPhone' | grep -oE "$UUID_RE" | head -1 || true)"
    if [ -z "$SIM_UDID" ]; then
      echo "x No iPhone simulator available. Install one via Xcode > Settings > Components." >&2
      exit 1
    fi
    echo "- Booting simulator $SIM_UDID..."
    xcrun simctl boot "$SIM_UDID"
  fi
  open -a Simulator

  echo "- Installing to simulator $SIM_UDID..."
  xcrun simctl install "$SIM_UDID" "$APP"
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
  echo "OK Launched $BUNDLE_ID in the Simulator"
else
  echo "- Building (signed) for device..."
  xcodebuild -quiet -project WorkoutFeed.xcodeproj -scheme WorkoutFeed \
    -configuration Debug -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates -derivedDataPath "$DERIVED" build
  APP="$DERIVED/Build/Products/Debug-iphoneos/WorkoutFeed.app"

  echo "- Installing to $DEVICE..."
  xcrun devicectl device install app --device "$DEVICE" "$APP"
  echo "OK Installed $BUNDLE_ID"
fi
