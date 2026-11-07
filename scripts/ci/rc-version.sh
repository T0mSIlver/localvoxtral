#!/usr/bin/env bash
# Computes the version and tag for an RC (release candidate) release.
#
# Usage:
#   scripts/ci/rc-version.sh [tags-file]
#
# <tags-file> is a newline-separated list of tags that already exist (local
# and remote, unioned by the caller). With no file the script reads
# `git tag --list` in the current repository.
#
# stdout is $GITHUB_OUTPUT-shaped:
#   base=<the stable tag the RC is derived from>
#   version=<X.(Y+1).0-rc.N>
#   tag=v<version>
#
# The shape: latest STABLE tag with the minor bumped, suffixed -rc.N. The
# daily cron cuts minor releases, so an RC built with v0.17.2 as the newest
# stable release is v0.18.0-rc.1: a candidate for the next daily. It sorts
# below the v0.18.0 that will eventually ship, so that release is always an
# upgrade.
#
# Rules this script exists to keep true and testable:
#
#   1. RC tags NEVER poison the next stable bump. The base is picked from
#      tags matching vX.Y.Z exactly; anything carrying a suffix (-rc.*, old
#      -nightly.*) is not a stable release and cannot be a base. That mirrors
#      release.yml's stable path, which excludes `v*-*` for the same reason.
#   2. N is 1 + the highest N already used for that version, hand-cut
#      X.Y.Z-rc.N tags included, so a new RC never collides with a tag.
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [tags-file]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  [[ -f "$1" ]] || { echo "tags file not found: $1" >&2; exit 2; }
  TAGS="$(cat "$1")"
else
  TAGS="$(git tag --list)"
fi

# The bump base: the highest vX.Y.Z, compared field by field as numbers.
# Numeric comparison, not sort order: v0.10.0 is newer than v0.9.0, and
# `sort -V` is not portable to the BSD sort on the release runner.
BASE="$(printf '%s\n' "$TAGS" \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's/^v//' \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -n 1 || true)"
BASE="${BASE:-0.0.0}"

IFS=. read -r MAJOR MINOR _PATCH <<<"$BASE"
NEXT="$MAJOR.$((MINOR + 1)).0"

# Highest N among existing vNEXT-rc.N tags (0 when there are none).
ESCAPED="${NEXT//./\\.}"
HIGHEST="$(printf '%s\n' "$TAGS" \
  | sed -n "s/^v${ESCAPED}-rc\\.\\([0-9][0-9]*\\)\$/\\1/p" \
  | sort -n \
  | tail -n 1 || true)"
HIGHEST="${HIGHEST:-0}"
N=$((HIGHEST + 1))

VERSION="$NEXT-rc.$N"

echo "base=v$BASE"
echo "version=$VERSION"
echo "tag=v$VERSION"
