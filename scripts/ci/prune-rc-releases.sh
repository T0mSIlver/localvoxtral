#!/usr/bin/env bash
# Selects the RC releases to delete, keeping the newest N, and every leftover
# nightly release.
#
# Usage:
#   scripts/ci/prune-rc-releases.sh [--keep N] [tags-file]
#
# Input is one tag per line (from `gh release list --json tagName`, or a file
# for the tests). Output is the tags to delete, one per line, nothing else:
# first the RC tags beyond the newest N, newest first, then every old
# -nightly tag (the channel they came from is gone, so none is kept), newest
# first. The caller does the deleting, so this script needs no gh, no network
# and no credentials, which is what makes it testable.
#
# The selection is deliberately paranoid, because the caller's next step runs
# `gh release delete --cleanup-tag` on whatever comes out of here:
#
#   * a line is a candidate only if it matches the RC tag shape (vX.Y.Z-rc.N)
#     or the old nightly shape (vX.Y.Z-nightly.YYYYMMDD with an optional .N)
#     EXACTLY. A stable tag, a branch-ish name, a tag with a look-alike
#     prefix or suffix, or a line with whitespace in it is not a candidate
#     and can never be printed;
#   * RC ordering is by version and then N, both as numbers, NOT by input
#     order: v0.10.0-rc.1 is newer than v0.9.0-rc.5, and the API's ordering
#     is not a contract. Nightly ordering is by the embedded date and
#     sequence number.
set -euo pipefail

KEEP=7
TAGS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep needs a value" >&2; exit 2; }
      KEEP="$2"
      shift 2
      ;;
    -*)
      echo "usage: $0 [--keep N] [tags-file]" >&2
      exit 2
      ;;
    *)
      [[ -z "$TAGS_FILE" ]] || { echo "usage: $0 [--keep N] [tags-file]" >&2; exit 2; }
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

# The awk programs stay free of interval expressions ({8}) — the BSD awk on
# the release runner does not reliably support them.

# RC tags beyond the newest KEEP. Sort key: major, minor, patch, N.
RCS="$(printf '%s\n' "$INPUT" \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' || true)"
if [[ -n "$RCS" ]]; then
  printf '%s\n' "$RCS" \
    | awk -F'[v.-]' '{ printf "%d %d %d %d %s\n", $2, $3, $4, $6, $0 }' \
    | sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5r \
    | awk -v keep="$KEEP" 'NR > keep { print $5 }'
fi

# Every old nightly tag. Sort key: date, then sequence (absent means 1, the
# first nightly of that day), then the tag itself so the order is total.
NIGHTLIES="$(printf '%s\n' "$INPUT" \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[0-9]+)?$' || true)"
if [[ -n "$NIGHTLIES" ]]; then
  printf '%s\n' "$NIGHTLIES" \
    | awk -F'-nightly[.]' '{
        n = split($2, parts, ".")
        seq = (n > 1 ? parts[2] + 0 : 1)
        printf "%s %d %s\n", parts[1], seq, $0
      }' \
    | sort -k1,1r -k2,2nr -k3,3r \
    | awk '{ print $3 }'
fi
