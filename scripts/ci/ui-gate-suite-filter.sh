#!/bin/bash
# Decides whether CI must run scripts/ci/test-ui-gate.sh for a given change.
# Same contract as the other lane filters, so the decision is testable without
# a workflow run.
#
# Usage:
#   scripts/ci/ui-gate-suite-filter.sh <changed-files-file> [event-name]
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# WHY THIS SUITE CAN BE GATED. It is ~360 assertions that each start a fresh
# bash, about 60 % of the shell-suite step at the head of build-test, the job
# every agent iterates on (#418). It is hermetic: every macOS tool is a PATH
# stub, and the only repo files it reads are the ones below
# (test-ui-gate-suite-filter.sh fails when the suite starts reading another).
# Those files changed in 6 of the 148 commits before this filter existed.
# Every push to main and every dispatch still runs it.
set -euo pipefail

INPUTS=(
  'scripts/mac/localvoxtral-ui-gate.sh'
  'scripts/mac/ui-gate-doctor.sh'
  'scripts/mac/lv-attach.sh'
  'scripts/mac/install-ui-artifact.sh'
  'scripts/mac/README.md'
  'scripts/ci/screen-lock-state.sh'
  'scripts/try-pr.sh'
  '.github/workflows/ci.yml'
  'scripts/ci/test-ui-gate.sh'
  'scripts/ci/ui-gate-suite-filter.sh'
  'scripts/ci/run-shell-suites.sh'
  'scripts/ci/background-step.sh'
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [event-name]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
EVENT_NAME="${2:-}"

case "$EVENT_NAME" in
  pull_request | "")
    ;;
  workflow_dispatch)
    echo "run=true"
    echo "reason=workflow_dispatch — dispatches run everything"
    exit 0
    ;;
  push)
    echo "run=true"
    echo "reason=push to main — main is the parity reference and is never gated"
    exit 0
    ;;
  *)
    echo "run=true"
    echo "reason=unrecognized event '$EVENT_NAME' — failing open"
    exit 0
    ;;
esac

# The caller's diff can be missing (the fast-path step fails open before it
# writes one). No diff means no evidence the suite is unaffected.
if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "run=true"
  echo "reason=no changed-file list — failing open"
  exit 0
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  for input in "${INPUTS[@]}"; do
    if [[ "$file" == "$input" ]]; then
      echo "run=true"
      echo "reason=matched $file"
      exit 0
    fi
  done
done <"$CHANGED_FILES_FILE"

echo "run=false"
echo "reason=no file the UI gate suite reads has changed"
