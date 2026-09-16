#!/usr/bin/env bash
# Computes the version and tag for a NIGHTLY release.
#
# Usage:
#   scripts/ci/nightly-version.sh <YYYYMMDD> [tags-file]
#
# <tags-file> is a newline-separated list of tags that already exist (local
# and remote, unioned by the caller). With no file the script reads
# `git tag --list` in the current repository.
#
# stdout is $GITHUB_OUTPUT-shaped:
#   base=<the stable tag the nightly is derived from>
#   version=<X.Y.Z-nightly.YYYYMMDD[.N]>
#   tag=v<version>
#
# The shape: latest STABLE tag with patch+1, suffixed -nightly.<UTC date>.
# A nightly built on 2026-09-16 with v0.8.4 as the newest stable release is
# v0.8.5-nightly.20260916 — it sorts below the v0.8.5 that will eventually
# ship, so the stable release that follows is always an upgrade.
#
# Two rules this script exists to keep true and testable:
#
#   1. Nightly tags NEVER poison the next stable bump. The base is picked
#      from tags matching vX.Y.Z exactly — anything carrying a suffix
#      (-nightly.*, -rc.*) is not a stable release and cannot be a bump base.
#      That mirrors release.yml's stable path, which excludes `v*-*` for the
#      same reason.
#   2. A second nightly on the same day gets the first free .N suffix
#      (.2, .3, ...), so re-dispatching never collides with an existing tag.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <YYYYMMDD> [tags-file]" >&2
  exit 2
fi

DATE="$1"
if [[ ! "$DATE" =~ ^[0-9]{8}$ ]]; then
  echo "refusing to build a nightly version from a date that is not YYYYMMDD: $DATE" >&2
  exit 2
fi

if [[ $# -eq 2 ]]; then
  [[ -f "$2" ]] || { echo "tags file not found: $2" >&2; exit 2; }
  TAGS="$(cat "$2")"
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

IFS=. read -r MAJOR MINOR PATCH <<<"$BASE"
NEXT="$MAJOR.$MINOR.$((PATCH + 1))"

tag_exists() {
  grep -qxF "$1" <<<"$TAGS"
}

VERSION="$NEXT-nightly.$DATE"
if tag_exists "v$VERSION"; then
  SEQ=2
  while tag_exists "v$NEXT-nightly.$DATE.$SEQ"; do
    SEQ=$((SEQ + 1))
    if (( SEQ > 99 )); then
      echo "refusing to look past 99 nightlies for $DATE — something is wrong" >&2
      exit 1
    fi
  done
  VERSION="$NEXT-nightly.$DATE.$SEQ"
fi

echo "base=v$BASE"
echo "version=$VERSION"
echo "tag=v$VERSION"
