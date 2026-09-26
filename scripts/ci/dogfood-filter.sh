#!/bin/bash
# Decides whether CI must run the `dogfood` job (the capture suite built with
# LOCALVOXTRAL_DOGFOOD=1) for a given change.
#
# Usage:
#   scripts/ci/dogfood-filter.sh <changed-files-file> [event-name]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [event-name]          $GITHUB_EVENT_NAME; absent means "decide on paths
#                         alone" (what the tests do)
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
#
# The job compiles and tests the root Swift package, so its only inputs are
# the package's sources, tests and manifest, plus the job definition and this
# filter. A diff that touches none of them (docs, scripts, other workflows,
# the helper packages) cannot change its result. The unit suite does not cover
# it: the capture is behind a compile flag, so a rename that only flagged code
# calls breaks this build alone. That is why any Swift change still runs it.
set -euo pipefail

PATTERNS=(
  'Sources/*'
  'Tests/*'
  'Package.swift'
  'Package.resolved'
  '.github/workflows/ci.yml'
  'scripts/ci/dogfood-filter.sh'
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [event-name]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
EVENT_NAME="${2:-}"

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

# Only a pull request is gated. A push (always to main) and a dispatch run it,
# and an unrecognized event fails open.
case "$EVENT_NAME" in
  pull_request | "")
    ;;
  *)
    echo "run=true"
    echo "reason=event '$EVENT_NAME' is not gated"
    exit 0
    ;;
esac

count=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  count=$((count + 1))
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern)
        echo "run=true"
        echo "reason=matched $file ($pattern)"
        exit 0
        ;;
    esac
  done
done <"$CHANGED_FILES_FILE"

if [[ "$count" -eq 0 ]]; then
  echo "run=true"
  echo "reason=empty changed-file list — failing open"
  exit 0
fi

echo "run=false"
echo "reason=none of $count changed path(s) is Swift source, tests, the package manifest or the job itself"
