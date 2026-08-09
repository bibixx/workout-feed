#!/usr/bin/env bash
# Cut a release: build the unsigned .ipa, update the SideStore source, tag, and publish via gh.
# Usage: ./release.sh ["release notes"]    notes default to "Release v<version>"
# The version comes from MARKETING_VERSION in project.yml - bump it there first.
set -euo pipefail
cd "$(dirname "$0")"

REPO="bibixx/workout-feed"
SOURCE_JSON="docs/sidestore.json"

if [ -n "$(git status --porcelain)" ]; then
  echo "x Working tree is dirty. Commit or stash first, so the release commit contains only $SOURCE_JSON." >&2
  exit 1
fi

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\(.*\)"/\1/p' project.yml)"
if [ -z "$VERSION" ]; then
  echo "x Could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
TAG="v$VERSION"
NOTES="${1:-Release $TAG}"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "x Tag $TAG already exists. Bump MARKETING_VERSION in project.yml first." >&2
  exit 1
fi

./build-ipa.sh

SIZE="$(stat -f%z dist/WorkoutFeed.ipa)"
# Full UTC timestamp, not a bare date: SideStore parses "YYYY-MM-DD" as midnight UTC,
# which can be in the future locally and turns the release into a countdown.
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/WorkoutFeed.ipa"

echo "- Updating $SOURCE_JSON (v$VERSION, $SIZE bytes)..."
VERSION="$VERSION" SIZE="$SIZE" DATE="$DATE" DOWNLOAD_URL="$DOWNLOAD_URL" NOTES="$NOTES" \
python3 - "$SOURCE_JSON" <<'PY'
import json, os, sys

path = sys.argv[1]
with open(path) as f:
    source = json.load(f)

entry = {
    "version": os.environ["VERSION"],
    "date": os.environ["DATE"],
    "localizedDescription": os.environ["NOTES"],
    "downloadURL": os.environ["DOWNLOAD_URL"],
    "size": int(os.environ["SIZE"]),
    "minOSVersion": "17.0",
}
versions = source["apps"][0]["versions"]
versions[:] = [v for v in versions if v["version"] != entry["version"]]
versions.insert(0, entry)

with open(path, "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

git add "$SOURCE_JSON"
if git diff --cached --quiet; then
  echo "- $SOURCE_JSON unchanged (rerun after a partial release?)"
else
  git commit -m "release: $TAG"
fi
# -m keeps this working under tag-signing git configs, which refuse message-less tags.
git tag -m "$TAG" "$TAG"
git push origin main "$TAG"

echo "- Creating GitHub release $TAG..."
gh release create "$TAG" dist/WorkoutFeed.ipa --title "$TAG" --notes "$NOTES"

echo "OK $TAG published. The Pages deploy will refresh the SideStore source shortly."
