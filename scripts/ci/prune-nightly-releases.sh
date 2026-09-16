#!/usr/bin/env bash
# Selects the nightly releases to delete, keeping the newest N.
#
# Usage:
#   scripts/ci/prune-nightly-releases.sh [--keep N] [tags-file]
#
# Input is one tag per line (from `gh release list --json tagName`, or a file
# for the tests). Output is the tags to delete, newest first, one per line —
# nothing else. The caller does the deleting, so this script needs no gh, no
# network and no credentials, which is what makes it testable.
#
# The selection is deliberately paranoid, because the caller's next step runs
# `gh release delete --cleanup-tag` on whatever comes out of here:
#
#   * a line is a candidate only if it matches the nightly tag shape EXACTLY
#     (vX.Y.Z-nightly.YYYYMMDD with an optional .N). A stable tag, an rc tag,
#     a branch-ish name, a tag with a nightly-looking prefix or suffix, or a
#     line with whitespace in it is not a candidate and can never be printed;
#   * ordering is by the embedded date and sequence number, NOT by version and
#     not by input order: v0.9.0-nightly.20260101 is older than
#     v0.8.5-nightly.20260201, and the API's ordering is not a contract.
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

CANDIDATES="$(printf '%s\n' "$INPUT" \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[0-9]+)?$' || true)"
[[ -n "$CANDIDATES" ]] || exit 0

# Sort key per candidate: date, then sequence (absent means 1, i.e. the first
# nightly of that day), then the tag itself so the order is total. The awk
# below stays free of interval expressions ({8}) — the BSD awk on the release
# runner does not reliably support them.
printf '%s\n' "$CANDIDATES" \
  | awk -F'-nightly[.]' '{
      n = split($2, parts, ".")
      seq = (n > 1 ? parts[2] + 0 : 1)
      printf "%s %d %s\n", parts[1], seq, $0
    }' \
  | sort -k1,1r -k2,2nr -k3,3r \
  | awk -v keep="$KEEP" 'NR > keep { print $3 }'
