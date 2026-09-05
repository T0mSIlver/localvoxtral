#!/usr/bin/env bash
# Regression test for helper-lane-filter.sh's path and event decisions.
# Pure shell, no git or network — changed-file lists are written to temp
# files, so it runs anywhere (hosted fork PRs included).
#
# What it pins, in the order the decisions are made:
#   - the event rules (dispatch / push-to-main / unknown all fail open to run)
#   - each helper's own directory, INCLUDING its Package.resolved, which is
#     the dependency-pin surface and the thing most likely to be forgotten
#   - the shared CI-plumbing list (ci.yml, scripts/ci/*, package_app.sh),
#     which is the whole reason this can be gated safely
#   - independence: a PolishHelper diff must NOT run the SpeechHelper suite,
#     and vice versa — the bug this gate would introduce if the two pattern
#     lists ever leaked into each other
#   - the run=false side, which is the point of the change
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/helper-lane-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-helper-lane-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <polish|speech> <true|false> <description> [--event <name>] <changed-path>...
expect() {
  local helper="$1" expected="$2" description="$3"
  shift 3
  local changed="$TMP_DIR/changed" event=""
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--event" ]]; then
      event="$2"
      shift 2
      continue
    fi
    printf '%s\n' "$1" >>"$changed"
    shift
  done
  local output
  if [[ -n "$event" ]]; then
    output="$("$FILTER" "$helper" "$changed" "$event")" \
      || fail "$description: filter exited non-zero"
  else
    output="$("$FILTER" "$helper" "$changed")" \
      || fail "$description: filter exited non-zero"
  fi
  local run reason
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: [%s] %s (%s)\n' "$helper" "$description" "$reason"
}

expect_usage_error() {
  local description="$1"
  shift
  if "$FILTER" "$@" >/dev/null 2>&1; then
    fail "$description: expected a usage error, got exit 0"
  fi
  printf 'PASS: %s\n' "$description"
}

# --- Event rules (checked before any path) ---------------------------------

expect polish true "workflow_dispatch runs the polish lane whatever the diff" \
  --event workflow_dispatch README.md
expect speech true "workflow_dispatch runs the speech lane whatever the diff" \
  --event workflow_dispatch README.md
expect polish true "push (ci.yml only pushes on main) runs the polish lane" \
  --event push README.md
expect speech true "push (ci.yml only pushes on main) runs the speech lane" \
  --event push README.md
expect polish true "an unrecognized event fails open" \
  --event merge_group README.md
expect speech true "an unrecognized event fails open" \
  --event schedule README.md
expect polish false "pull_request decides on paths alone" \
  --event pull_request README.md

# --- Each helper's own directory -------------------------------------------

expect polish true "a PolishHelper source change runs the polish lane" \
  PolishHelper/Sources/PolishHelperCore/PolishRouter.swift
expect polish true "PolishHelper/Package.resolved is the pin surface" \
  PolishHelper/Package.resolved
expect polish true "PolishHelper/Package.swift runs the polish lane" \
  PolishHelper/Package.swift
expect polish true "a PolishHelper TEST-only change runs the polish lane" \
  PolishHelper/Tests/PolishHelperCoreTests/RouterTests.swift
expect speech true "a SpeechHelper source change runs the speech lane" \
  SpeechHelper/Sources/SpeechEngineText/StreamingDelta.swift
expect speech true "SpeechHelper/Package.resolved is the pin surface" \
  SpeechHelper/Package.resolved
expect speech true "SpeechHelper/DEPENDENCY.md is inside the helper and counts" \
  SpeechHelper/DEPENDENCY.md

# --- The shared CI-plumbing list -------------------------------------------
# These are the only paths outside a helper directory that can change what
# its unit suite tests: how the step is invoked, what decides it, and what
# builds the helper.

for helper in polish speech; do
  expect "$helper" true "ci.yml runs both lanes" .github/workflows/ci.yml
  expect "$helper" true "any scripts/ci/ change runs both lanes" \
    scripts/ci/run-supervised-command.sh
  expect "$helper" true "this filter's own edits prove both lanes first" \
    scripts/ci/helper-lane-filter.sh
  expect "$helper" true "package_app.sh builds both helpers" scripts/package_app.sh
done

# --- Independence: one helper never drags in the other ---------------------

expect speech false "a PolishHelper-only diff must NOT run the speech lane" \
  PolishHelper/Sources/PolishHelperCore/PolishRouter.swift
expect polish false "a SpeechHelper-only diff must NOT run the polish lane" \
  SpeechHelper/Sources/SpeechEngine/RealtimeServer.swift

# --- The run=false side (the point of the change) ---------------------------

expect polish false "root app sources do not run the polish lane" \
  Sources/localvoxtral/SettingsView.swift Sources/localvoxtral/DictationViewModel.swift
expect speech false "root app sources do not run the speech lane" \
  Sources/localvoxtral/SettingsView.swift
expect polish false "root tests do not run the polish lane" \
  Tests/localvoxtralTests/DictationViewModelPolishTokenGuardTests.swift
expect speech false "the root package manifest does not run the speech lane" \
  Package.swift Package.resolved
expect polish false "docs do not run the polish lane" README.md AGENTS.md
expect speech false "a non-ci script does not run the speech lane" \
  scripts/try-pr.sh
expect polish false "empty changed-file list decides run=false (caller owns fail-open)" \
  ""

# --- Usage errors ----------------------------------------------------------

expect_usage_error "an unknown helper name is a usage error" \
  mystery /dev/null
expect_usage_error "a missing changed-files file is a usage error" \
  polish "$TMP_DIR/does-not-exist"

printf 'OK: helper-lane-filter tests passed\n'
