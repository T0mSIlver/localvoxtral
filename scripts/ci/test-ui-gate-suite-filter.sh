#!/bin/bash
# Pins scripts/ci/ui-gate-suite-filter.sh, and ties its input list to what
# test-ui-gate.sh actually reads, so the suite cannot grow a dependency that
# the filter then silently ignores.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/ui-gate-suite-filter.sh"
SUITE="$ROOT_DIR/scripts/ci/test-ui-gate.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-ui-gate-suite-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> [--event <name>] <changed-path>...
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" event="pull_request"
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --event) event="$2"; shift 2 ;;
      *) printf '%s\n' "$1" >>"$changed"; shift ;;
    esac
  done
  local output run reason
  output="$("$FILTER" "$changed" "$event")" || fail "$description: filter exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

expect true "the gate script runs the suite" scripts/mac/localvoxtral-ui-gate.sh
expect true "the suite itself runs the suite" scripts/ci/test-ui-gate.sh
expect true "the workflow it asserts on runs the suite" .github/workflows/ci.yml
expect true "an input beside unrelated files still runs it" \
  Sources/localvoxtral/SettingsView.swift scripts/try-pr.sh
expect false "a Swift change does not" Sources/localvoxtral/SettingsView.swift
expect false "another gate's script does not" scripts/mac/localvoxtral-build-gate.sh
expect false "an empty changed-file list does not" 
expect true "a push to main is never gated" --event push docs/architecture.md
expect true "a dispatch is never gated" --event workflow_dispatch docs/architecture.md
expect true "an unknown event fails open" --event merge_group docs/architecture.md

output="$("$FILTER" "$TMP_DIR/no-such-file" pull_request)"
[[ "$(sed -n 's/^run=//p' <<<"$output")" == "true" ]] || fail "a missing changed-file list did not fail open"
echo "PASS: a missing changed-file list fails open"

# Every repo file the suite reads must be an input of the filter. The suite
# names them as $ROOT_DIR/<path>; a path built any other way would escape this
# check, so the suite is also required to mention ROOT_DIR only in that shape.
inputs="$(sed -n "/^INPUTS=(/,/^)/p" "$FILTER" | sed -n "s/^  '\([^']*\)'.*/\1/p")"
[[ -n "$inputs" ]] || fail "could not parse INPUTS"
input_lines="$(sed -n "/^INPUTS=(/,/^)/p" "$FILTER" | sed '1d;$d' | grep -vcE "^[[:space:]]*(#|$)" || true)"
[[ "$input_lines" == "$(wc -l <<<"$inputs" | tr -d ' ')" ]] || fail "INPUTS holds an entry this test cannot parse"
while IFS= read -r input; do
  [[ -e "$ROOT_DIR/$input" ]] || fail "listed input does not exist: $input"
done <<<"$inputs"

read_paths="$(grep -oE '\$ROOT_DIR/[A-Za-z0-9_./-]+' "$SUITE" | sed 's|^\$ROOT_DIR/||' | sort -u)"
[[ -n "$read_paths" ]] || fail "found no \$ROOT_DIR/<path> reference in the suite; the scan is broken"
while IFS= read -r path; do
  grep -qxF "$path" <<<"$inputs" || fail "test-ui-gate.sh reads $path, which the filter does not list"
done <<<"$read_paths"
bare="$(grep -nE '\$\{?ROOT_DIR\}?' "$SUITE" | grep -vE '\$ROOT_DIR/[A-Za-z0-9_.]|^[0-9]+:ROOT_DIR=' || true)"
[[ -z "$bare" ]] || fail "test-ui-gate.sh uses ROOT_DIR in a shape this scan cannot follow:
$bare"
echo "PASS: every repo file the suite reads is an input of the filter"

echo "OK: ui-gate-suite-filter tests passed"
