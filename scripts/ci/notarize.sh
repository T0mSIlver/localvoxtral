#!/usr/bin/env bash
# Submits one file (a zipped app or a signed DMG) to Apple's notary service
# and waits for the verdict (#1430).
#
# Usage:
#   NOTARIZE_TIMEOUT=3h scripts/ci/notarize.sh <file> <notarytool-keychain-profile>
#
# NOTARIZE_TIMEOUT bounds the wait, in notarytool's format (seconds, or a
# number followed by s, m or h; default 3h). Apple can hold a team's first
# submissions for hours: the first rehearsal's was still In Progress after
# 10 h, so 20 min was far too short.
#
# Exits 0 only on status Accepted. The submission id is printed as soon as
# Apple assigns it, so a slow run can be followed with `notarytool info`. On a
# timeout it exits 1 naming the id and that command; on any other status it
# prints Apple's log for the submission, which names each rejected binary and
# why, and exits 1. The profile lives in the release runner's login keychain
# (`xcrun notarytool store-credentials ... --keychain <that file>`); no secret
# passes through here.
#
# NOTARY_KEYCHAIN names the keychain file holding the profile (default: the
# login keychain file). Every call passes it with --keychain, because a profile
# looked up without it comes from the data-protection keychain, which macOS
# makes unreadable while the screen is locked: notarytool then reports "No
# Keychain password item found", as rehearsal run 37111344554 did 4 s before
# the owner unlocked the Mac. The login keychain file stays readable then, as
# codesign's Developer ID key in it does.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <file> <notarytool-keychain-profile>" >&2
  exit 2
fi
FILE="$1"
PROFILE="$2"
TIMEOUT="${NOTARIZE_TIMEOUT:-3h}"
KEYCHAIN="${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
AUTH=(--keychain-profile "$PROFILE" --keychain "$KEYCHAIN")
# Checked here because the wait's exit status is not trusted below: a
# timeout notarytool rejects would otherwise read as Apple being slow.
if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]]; then
  echo "NOTARIZE_TIMEOUT must be a positive number of seconds, or end in s, m or h; got '$TIMEOUT'" >&2
  exit 2
fi

OUT="$(mktemp "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

# json_field <file> <key>: prints the key's value from notarytool's JSON, or
# "-" when the file holds no JSON or no such key.
json_field() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    d = {}
print((d.get(sys.argv[2]) or "-") if isinstance(d, dict) else "-")
' "$1" "$2"
}

echo "Submitting $(basename "$FILE") for notarization"
# Submitted without --wait so the id is known before the wait starts.
if ! xcrun notarytool submit "$FILE" "${AUTH[@]}" \
    --output-format json > "$OUT"; then
  echo "notarytool submit failed:" >&2
  cat "$OUT" >&2
fi
ID="$(json_field "$OUT" id)"
if [[ "$ID" == "-" ]]; then
  echo "::error::notarytool submit returned no submission id for $(basename "$FILE")" >&2
  cat "$OUT" >&2
  exit 1
fi
INFO_CMD="xcrun notarytool info $ID --keychain-profile $PROFILE --keychain $KEYCHAIN"
echo "Submission $ID: submitted; waiting up to $TIMEOUT. Follow it with: $INFO_CMD"

# notarytool's exit status does not tell a rejection or a timeout from a
# success; the JSON status does. A wait that ends without a final status
# (timeout, transport failure) is settled by one `info` call.
xcrun notarytool wait "$ID" "${AUTH[@]}" \
  --timeout "$TIMEOUT" --output-format json > "$OUT" || true
STATUS="$(json_field "$OUT" status)"
if [[ "$STATUS" == "-" || "$STATUS" == "In Progress" ]]; then
  echo "notarytool wait ended without a verdict:"
  cat "$OUT"
  xcrun notarytool info "$ID" "${AUTH[@]}" \
    --output-format json > "$OUT" || true
  STATUS="$(json_field "$OUT" status)"
fi
echo "Submission $ID: $STATUS"

case "$STATUS" in
  Accepted)
    exit 0
    ;;
  "In Progress")
    echo "::error::Apple did not finish notarizing $(basename "$FILE") within $TIMEOUT. Submission $ID is still In Progress; follow it with: $INFO_CMD" >&2
    exit 1
    ;;
  -)
    echo "::error::Could not read the status of submission $ID for $(basename "$FILE"). Check it with: $INFO_CMD" >&2
    exit 1
    ;;
esac
echo "Notary log for $ID:" >&2
xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
exit 1
