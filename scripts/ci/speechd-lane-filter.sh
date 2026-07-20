#!/bin/bash
# Decides whether CI's speechd live-model integration step must run for a
# given change. Kept standalone so the workflow decision is testable locally.
#
# Usage:
#   scripts/ci/speechd-lane-filter.sh <changed-files-file> [marker-text-file]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [marker-text-file]    optional free text (PR body + head commit message);
#                         if it contains [run-speechd-integration], the lane
#                         runs regardless of the diff
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
set -euo pipefail

MARKER='[run-speechd-integration]'

# Changes here can alter the helper binary, its pinned mlx-audio-swift graph,
# the managed launch/model-download contract, the packaged resource layout,
# or the live-model contract asserted by the integration suite.
# SpeechHelper/* includes Package.swift + Package.resolved, which are the
# mlx-audio-swift pin surface.
PATTERNS=(
  'SpeechHelper/*'
  'Sources/localvoxtral/Backends/BackendCatalog.swift'
  'Sources/localvoxtral/Backends/BackendManager.swift'
  'Sources/localvoxtral/Backends/SpeechModelCatalog.swift'
  'scripts/package_app.sh'
  'scripts/ci/speechd-lane-filter.sh'
  'Tests/localvoxtralTests/SpeechHelperIntegrationTests.swift'
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
MARKER_TEXT_FILE="${2:-}"

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]] \
    && grep -qF "$MARKER" "$MARKER_TEXT_FILE"; then
  echo "run=true"
  echo "reason=explicit $MARKER marker"
  exit 0
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
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

echo "run=false"
echo "reason=no speechd-relevant changes; add $MARKER to the PR body or commit message and push to opt in"
