#!/bin/bash
# Decides whether CI must run one of the two helper-package UNIT suites
# (`swift test --package-path PolishHelper` / `--package-path SpeechHelper`)
# for a given change. Kept standalone so the workflow decision is testable
# locally, exactly like llm-lane-filter.sh / speechd-lane-filter.sh.
#
# Usage:
#   scripts/ci/helper-lane-filter.sh <polish|speech> <changed-files-file> [event-name]
#
#   <polish|speech>       which helper's unit suite is being decided
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [event-name]          $GITHUB_EVENT_NAME; absent means "decide on paths
#                         alone" (what the tests do)
#
# LANE_MAC_LANES_JOB_CHANGED=false (from scripts/ci/lane-diff-facts.sh) says
# ci.yml changed outside the mac-lanes job and the file's head, which cannot
# change how these suites are invoked; only the literal "false" narrows.
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all — same contract as
# the other lane filters.
#
# WHY THIS IS SAFE TO GATE AT ALL (owner decision 2026-09-05, "option 8").
# These two suites ran on every self-hosted run (cost: docs/agent/test-tiers.md
# "Why the helper unit suites are path-gated"), including on diffs that could
# not possibly change what they test. They can be gated because both helpers are HERMETIC packages: `PolishHelper/Package.swift` and
# `SpeechHelper/Package.swift` declare only REMOTE dependencies (no `path:`
# dependency, no `..` reference, no symlink out of the directory, no source
# shared with the root package), so the only inputs to a helper's unit suite
# are (1) files under its own directory — Package.swift and Package.resolved
# included, which are the pin surface — (2) the Xcode toolchain, which is not
# a diff, and (3) the CI plumbing that decides how the suite is invoked and
# prepares the workspace it runs in.
# (3) is why the shared list below exists.
#
# This is NOT the live-model lane pattern of "expensive, so opt in". Nothing
# here is a judgment call and there is no marker: a diff that can affect the
# suite runs it, and `workflow_dispatch` runs both unconditionally, which is
# the escape hatch. Coverage is unchanged; only redundant executions go.
set -euo pipefail

# Changes that can alter EITHER helper suite without touching either helper
# directory: how the step is invoked, what decides whether it is invoked (this
# file included — every edit to it proves both lanes on its own first run,
# same discipline as scripts/ci/* in docs-only-filter.sh), what the mac-lanes
# job runs in the workspace before the suites, and the packaging script that
# builds both helpers. Named one by one rather than scripts/ci/*: that glob ran
# both suites for every edit to another lane's filter or test, 83 of 388 PR
# runs in two weeks (#621). A script the job comes to run before the suites
# joins this list in the same PR.
SHARED_PATTERNS=(
  '.github/workflows/ci.yml'                      # unless LANE_MAC_LANES_JOB_CHANGED=false
  'scripts/ci/helper-lane-filter.sh'
  'scripts/ci/lane-diff-facts.sh'                 # the fact that narrows ci.yml above
  'scripts/ci/docs-only-filter.sh'                # whether the job reaches the suites at all
  'scripts/ci/clean-stale-outputs.sh'             # what of the warm .build survives
  'scripts/ci/cleanup-stale-test-processes.sh'    # what it kills in the workspace first
  'scripts/package_app.sh'
)

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <polish|speech> <changed-files-file> [event-name]" >&2
  exit 2
fi

HELPER="$1"
CHANGED_FILES_FILE="$2"
EVENT_NAME="${3:-}"

case "$HELPER" in
  polish)
    HELPER_LABEL="PolishHelper"
    HELPER_PATTERNS=('PolishHelper/*')
    ;;
  speech)
    HELPER_LABEL="SpeechHelper"
    HELPER_PATTERNS=('SpeechHelper/*')
    ;;
  *)
    echo "unknown helper: $HELPER (expected polish or speech)" >&2
    exit 2
    ;;
esac

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

# Event rules come first: they are facts about the run, not about the diff,
# and they all say "run".
#   - workflow_dispatch: a dispatch exists to produce a full artifact on
#     demand and carries no diff the way a PR does. Run both; it is also the
#     no-new-grammar way for a human to force these suites.
#   - push: ci.yml's `push:` trigger is `branches: [main]` ONLY, so every push
#     event here is a push to main — the parity reference every branch is
#     compared against, which must never be gated.
#   - anything else (a trigger added later, an empty/garbled event name):
#     fail open, exactly like docs-only-filter.sh's unknown-path arm. A lane
#     that cannot classify its own run must run, never skip.
case "$EVENT_NAME" in
  pull_request | "")
    ;;
  workflow_dispatch)
    echo "run=true"
    echo "reason=workflow_dispatch — dispatches build everything"
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

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if [[ "$file" == ".github/workflows/ci.yml" && "${LANE_MAC_LANES_JOB_CHANGED:-}" == "false" ]]; then
    continue
  fi
  for pattern in "${HELPER_PATTERNS[@]}" "${SHARED_PATTERNS[@]}"; do
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
echo "reason=no $HELPER_LABEL-relevant changes ($HELPER_LABEL is a standalone package; nothing outside $HELPER_LABEL/ or the CI plumbing can change what its unit suite tests)"
