#!/usr/bin/env bash
# publish-release.sh — publish a tagged release and its assets, resumably
# (#1555).
#
# Usage: publish-release.sh <tag> <asset-dir> <notes-file>
#
# Running it again on the same files finishes what an earlier run left, so a
# release that lost its network part-way is finished without a rebuild
# (`release.sh publish <tag>` reruns it on the release run's artifact):
#   1. finds the release for <tag>, drafts included, or creates it as a draft
#      whose body is <notes-file> above GitHub's generated notes. The tag must
#      already exist: this script never creates one;
#   2. uploads each asset the release lacks or holds at another size;
#   3. checks that every asset is there at its size, then publishes the draft.
# The release stays a draft until step 3, so nobody sees it half uploaded. A
# tag with a '-' (rc, nightly) is a prerelease and never marked Latest.
#
# Every GitHub call is retried: release run 37128200212 lost the zip to
# `getaddrinfo ENOTFOUND uploads.github.com`. gh exits 1 for a network error
# and a refusal alike, so every failure is retried; each call is safe to
# repeat (an upload replaces the asset with --clobber).
#
# Environment: GITHUB_REPOSITORY (owner/repo) and gh's own GH_TOKEN.
#   PUBLISH_RETRY_ATTEMPTS  tries per call (default 5)
#   PUBLISH_RETRY_DELAY     seconds before the first retry, doubled after
#                           each (default 10)
#
# Tested by test-publish-release.sh with a stub gh.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <tag> <asset-dir> <notes-file>" >&2
  exit 2
fi
TAG="$1"
DIR="$2"
NOTES="$3"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name owner/repo}"
ATTEMPTS="${PUBLISH_RETRY_ATTEMPTS:-5}"
DELAY="${PUBLISH_RETRY_DELAY:-10}"

# Interpolated into jq filters below, so the shape is checked first.
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "publish-release.sh: '$TAG' is not a release tag (vX.Y.Z or vX.Y.Z-suffix)" >&2
  exit 2
fi
if [[ "$TAG" == *-* ]]; then
  PRERELEASE=true
  LATEST=false
else
  PRERELEASE=false
  LATEST=true
fi

ASSETS=(
  "localvoxtral-$TAG.zip"
  "localvoxtral-$TAG.zip.sha256"
  "localvoxtral-$TAG.dmg"
  "localvoxtral-$TAG.dmg.sha256"
  "localvoxtral-$TAG.dSYM.zip"
  "localvoxtral-polishd-$TAG.dSYM.zip"
  "localvoxtral-speechd-$TAG.dSYM.zip"
)

# Everything local is checked before the first network call.
[[ -f "$NOTES" ]] || { echo "publish-release.sh: no notes file at $NOTES" >&2; exit 1; }
for name in "${ASSETS[@]}"; do
  [[ -s "$DIR/$name" ]] || { echo "publish-release.sh: missing or empty asset $DIR/$name" >&2; exit 1; }
done
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
for name in "localvoxtral-$TAG.zip" "localvoxtral-$TAG.dmg"; do
  recorded="$(cut -d' ' -f1 <"$DIR/$name.sha256")"
  actual="$(sha256_of "$DIR/$name")"
  if [[ "$recorded" != "$actual" ]]; then
    echo "publish-release.sh: $name.sha256 records $recorded but $name hashes to $actual" >&2
    exit 1
  fi
done

STATE="$(mktemp "${TMPDIR:-/tmp}/publish-release.XXXXXX")"
trap 'rm -f "$STATE"' EXIT

# retry <what> <command...>
retry() {
  local what="$1" attempt=1 delay="$DELAY"
  shift
  until "$@"; do
    if (( attempt >= ATTEMPTS )); then
      echo "::error::$what failed $ATTEMPTS times; giving up" >&2
      return 1
    fi
    echo "::warning::$what failed (attempt $attempt of $ATTEMPTS); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# Writes the release's state to $STATE: `release <id> <draft>` then one
# `asset <name> <size> <state>` line per asset, or `none`. The list endpoint
# is the one that returns drafts; a new release is among the newest 100.
query_release() {
  gh api "repos/$REPO/releases?per_page=100" --jq "
    [.[] | select(.tag_name == \"$TAG\")]
    | if length == 0 then \"none\"
      else (.[0] | \"release \(.id) \(.draft)\", (.assets[] | \"asset \(.name) \(.size) \(.state)\"))
      end" >"$STATE"
}
release_field() { awk -v n="$1" '$1 == "release" { print $n }' "$STATE"; }
uploaded_size() { awk -v a="$1" '$1 == "asset" && $2 == a && $4 == "uploaded" { print $3 }' "$STATE"; }

ensure_release() {
  query_release || return 1
  [[ -n "$(release_field 2)" ]] && return 0
  # On a lost response the release may exist anyway; the query that follows
  # finds it, so a retry does not create a second one.
  gh api -X POST "repos/$REPO/releases" \
    -f tag_name="$TAG" -f name="localvoxtral $TAG" \
    -F draft=true -F prerelease="$PRERELEASE" -f make_latest="$LATEST" \
    -F generate_release_notes=true -F body=@"$NOTES" >/dev/null || true
  query_release || return 1
  [[ -n "$(release_field 2)" ]]
}

# Fails closed: a missing tag reads like a network failure and is retried,
# then stops the publish.
retry "Finding tag $TAG" gh api "repos/$REPO/git/ref/tags/$TAG" --silent
retry "Finding or creating the release for $TAG" ensure_release
RELEASE_ID="$(release_field 2)"
echo "Release $TAG: id $RELEASE_ID, draft=$(release_field 3)"

for name in "${ASSETS[@]}"; do
  size="$(wc -c <"$DIR/$name" | tr -d ' ')"
  if [[ "$(uploaded_size "$name")" == "$size" ]]; then
    echo "$name: already uploaded"
    continue
  fi
  # A failure here moves on to the next asset; the check below names it.
  if retry "Uploading $name" gh release upload "$TAG" "$DIR/$name" --repo "$REPO" --clobber; then
    echo "$name: uploaded"
  fi
done

retry "Reading the release back" query_release
missing=""
for name in "${ASSETS[@]}"; do
  size="$(wc -c <"$DIR/$name" | tr -d ' ')"
  [[ "$(uploaded_size "$name")" == "$size" ]] || missing="$missing $name"
done
if [[ -n "$missing" ]]; then
  echo "::error::The $TAG release lacks, or holds at another size:$missing. It stays a draft; rerun ./scripts/release.sh publish $TAG." >&2
  exit 1
fi

if [[ "$(release_field 3)" == "true" ]]; then
  retry "Publishing the $TAG draft" gh api -X PATCH "repos/$REPO/releases/$RELEASE_ID" \
    -F draft=false -f make_latest="$LATEST" --silent
  echo "Published $TAG (prerelease=$PRERELEASE, latest=$LATEST)"
else
  echo "$TAG was already published; its assets are complete"
fi
