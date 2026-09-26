#!/bin/bash
# Names the `waits:` labels a PR earns from its diff alone, for
# .github/workflows/pr-waits-labels.yml. The rest of the family (mac-e2e,
# ci-red, external) needs judgment and is set by hand; docs/agent/test-tiers.md
# "Why a PR waits: the waits labels" has the whole set.
#
# Usage:
#   scripts/ci/waits-labels.sh <changed-files-file> <marker-text-file> <base-ref>
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   <marker-text-file>    PR body + head commit message, for the lane markers
#   <base-ref>            the PR's base branch
#
# stdout: one label per line, possibly none.
#   waits:mac-llm      the LLM lane will run (llm-lane-filter.sh)
#   waits:mac-voxtral  the speechd or live STT lane will run
#                      (speechd-lane-filter.sh, stt-lane-filter.sh)
#   waits:stack        the base is another PR's branch, not main
#
# The filters decide exactly as they do in ci.yml, LANE_* narrowing env vars
# included, so a label here means that lane runs on the Mac. The workflow only
# adds labels; the scheduler clears a Mac label once the night run passed.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <changed-files-file> <marker-text-file> <base-ref>" >&2
  exit 2
fi

FILES="$1"
MARKER_TEXT="$2"
BASE_REF="$3"
DIR="$(cd "$(dirname "$0")" && pwd -P)"

runs() {
  [[ "$(sed -n 's/^run=//p' <<<"$1")" == "true" ]]
}

if runs "$("$DIR/llm-lane-filter.sh" "$FILES" "$MARKER_TEXT")"; then
  echo "waits:mac-llm"
fi
if runs "$("$DIR/speechd-lane-filter.sh" "$FILES" "$MARKER_TEXT")" \
  || runs "$("$DIR/stt-lane-filter.sh" "$FILES" pull_request "$MARKER_TEXT")"; then
  echo "waits:mac-voxtral"
fi
if [[ "$BASE_REF" != "main" ]]; then
  echo "waits:stack"
fi
