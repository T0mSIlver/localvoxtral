#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "Usage: ./scripts/release.sh v0.3.0"
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid tag: $TAG"
  echo "Expected semantic tag like v0.3.0"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes first."
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "Release must run from main. Current branch: $CURRENT_BRANCH"
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "Missing origin remote."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag already exists locally: $TAG"
  exit 1
fi

if git ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
  echo "Tag already exists on origin: $TAG"
  exit 1
fi

VERSION="${TAG#v}"
ARCHIVE_PATH="dist/localvoxtral-${TAG}.zip"
DMG_PATH="dist/localvoxtral-${TAG}.dmg"

echo "Running build and tests..."
swift build -c release
swift test

echo "Packaging app..."
./scripts/package_app.sh release "$VERSION" 1

echo "Creating archive $ARCHIVE_PATH..."
mkdir -p dist
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "dist/localvoxtral.app" "$ARCHIVE_PATH"

echo "Creating disk image $DMG_PATH..."
rm -f "$DMG_PATH"
hdiutil create -volname "localvoxtral" -srcfolder "dist/localvoxtral.app" -ov -format UDZO "$DMG_PATH"

echo "Pushing main..."
git push origin main

echo "Tagging and pushing $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Published $TAG"
echo "GitHub Actions will build and publish the release artifact from this tag."
echo "Release page: https://github.com/T0mSIlver/localvoxtral/releases/tag/$TAG"
