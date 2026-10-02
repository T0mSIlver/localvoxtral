#!/usr/bin/env bash
# Submits one file (a zipped app or a signed DMG) to Apple's notary service
# and waits for the verdict (#1430).
#
# Usage:
#   scripts/ci/notarize.sh <file> <notarytool-keychain-profile>
#
# Exits 0 only on status Accepted. On any other status it prints Apple's log
# for the submission, which names each rejected binary and why, and exits 1.
# The profile lives in the release runner's login keychain
# (`xcrun notarytool store-credentials`); no secret passes through here.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <file> <notarytool-keychain-profile>" >&2
  exit 2
fi
FILE="$1"
PROFILE="$2"

OUT="$(mktemp "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

echo "Submitting $(basename "$FILE") for notarization"
# notarytool's exit status does not tell a rejection from a success; the
# JSON status does. A transport failure exits non-zero with no JSON.
if ! xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" \
    --wait --timeout 20m --output-format json > "$OUT"; then
  echo "notarytool submit failed:" >&2
  cat "$OUT" >&2
fi

read -r ID STATUS < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    d = {}
print(d.get("id") or "-", d.get("status") or "-")
' "$OUT")
echo "Submission $ID: $STATUS"

if [[ "$STATUS" == "Accepted" ]]; then
  exit 0
fi
if [[ "$ID" != "-" ]]; then
  echo "Notary log for $ID:" >&2
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
fi
exit 1
