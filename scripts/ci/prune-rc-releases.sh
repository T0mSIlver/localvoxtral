#!/usr/bin/env bash
# Selects the rc releases to delete, keeping the newest N.
#
# Usage:
#   scripts/ci/prune-rc-releases.sh [--keep N] [--protect TAG] [tags-file]
#
# Input is one release per line: the tag, then optionally a TAB and the
# release's published_at (ISO 8601 UTC), from `gh api .../releases`, or a file
# for the tests. Output is the tags to delete, newest first, one per line,
# nothing else. Auto rc releases and leftover -nightly releases (the old name
# of the channel) are ONE pool: the newest N of it are kept, so a leftover
# nightly ages out as each new rc is published. The caller does the deleting,
# so this script needs no gh, no network and no credentials, which is what
# makes it testable.
#
# The selection is deliberately paranoid, because the caller's next step runs
# `gh release delete --cleanup-tag` on whatever comes out of here:
#
#   * a line is a candidate only if its tag matches the rc shape (vX.Y.Z-rc.N)
#     or the old nightly shape (vX.Y.Z-nightly.YYYYMMDD with an optional .N)
#     EXACTLY. A stable tag, a branch-ish name, a tag with a look-alike
#     prefix or suffix, or a tag with whitespace in it is not a candidate and
#     can never be printed;
#   * "newest" means most recently PUBLISHED, not highest version: hand-cut
#     v1.0.0-rc.1..7 must not push the automatic v0.18.0-rc.1 that was just
#     published out of the newest N. A missing timestamp sorts as oldest;
#     ties fall back to version and N (rc) or date and sequence (nightly), as
#     numbers. The API's list order is not a contract;
#   * --protect TAG is never printed, whatever the order says: the caller
#     passes the tag it just published.
set -euo pipefail

KEEP=7
PROTECT=""
TAGS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep needs a value" >&2; exit 2; }
      KEEP="$2"
      shift 2
      ;;
    --protect)
      [[ $# -ge 2 ]] || { echo "--protect needs a value" >&2; exit 2; }
      PROTECT="$2"
      shift 2
      ;;
    -*)
      echo "usage: $0 [--keep N] [--protect TAG] [tags-file]" >&2
      exit 2
      ;;
    *)
      [[ -z "$TAGS_FILE" ]] || { echo "usage: $0 [--keep N] [--protect TAG] [tags-file]" >&2; exit 2; }
      TAGS_FILE="$1"
      shift
      ;;
  esac
done

if [[ ! "$KEEP" =~ ^[0-9]+$ ]]; then
  echo "--keep must be a non-negative integer, got: $KEEP" >&2
  exit 2
fi

if [[ -n "$TAGS_FILE" ]]; then
  [[ -f "$TAGS_FILE" ]] || { echo "tags file not found: $TAGS_FILE" >&2; exit 2; }
  INPUT="$(cat "$TAGS_FILE")"
else
  INPUT="$(cat)"
fi

# The awk program stays free of interval expressions ({8}) — the BSD awk on
# the release runner does not reliably support them.
#
# One row per candidate: published_at, four numeric keys, tag. The tag is the
# text before the first TAB, so a tag with whitespace never matches a shape.
TAB="$(printf '\t')"
printf '%s\n' "$INPUT" \
  | awk -F'\t' '
      $1 ~ /^v[0-9]+[.][0-9]+[.][0-9]+-rc[.][0-9]+$/ {
        split($1, p, /[v.-]/)
        printf "%s\t%d\t%d\t%d\t%d\t%s\n", $2, p[2], p[3], p[4], p[6], $1
        next
      }
      $1 ~ /^v[0-9]+[.][0-9]+[.][0-9]+-nightly[.][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]([.][0-9]+)?$/ {
        split($1, q, "-nightly[.]")
        n = split(q[2], parts, ".")
        printf "%s\t%d\t%d\t0\t0\t%s\n", $2, parts[1], (n > 1 ? parts[2] + 0 : 1), $1
      }' \
  | sort -t"$TAB" -k1,1r -k2,2nr -k3,3nr -k4,4nr -k5,5nr -k6,6r \
  | awk -F'\t' -v keep="$KEEP" -v protect="$PROTECT" \
      'NR > keep && $6 != protect { print $6 }'
