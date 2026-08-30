#!/usr/bin/env bash
# Regression test for herdr-lane-filter.sh's path decisions and marker opt-in.
# Pure shell, no git or network — changed-file lists are written to temp files,
# so it runs anywhere (hosted fork PRs included).
#
# Not a mirror of the whole pattern list: it pins the decisions that decide
# whether a live-service lane runs at all — every path that can change what we
# say to herdr or believe it said, the doc the assumptions live in, and the
# run=false side that keeps ordinary UI/doc work off a lane that starts real
# servers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/herdr-lane-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-herdr-lane-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> <changed-path>... [--marker <text>]
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" marker_file=""
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--marker" ]]; then
      marker_file="$TMP_DIR/marker"
      printf '%s\n' "$2" >"$marker_file"
      shift 2
      continue
    fi
    printf '%s\n' "$1" >>"$changed"
    shift
  done
  local output
  if [[ -n "$marker_file" ]]; then
    output="$("$FILTER" "$changed" "$marker_file")" || fail "$description: filter exited non-zero"
  else
    output="$("$FILTER" "$changed")" || fail "$description: filter exited non-zero"
  fi
  local run reason
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# --- What we say to herdr, and what we believe it said ---------------------

expect true "socket client changes run the lane" \
  Sources/localvoxtral/ClaudeContext/HerdrSocketClient.swift
expect true "panel binding probe changes run the lane" \
  Sources/localvoxtral/ClaudeContext/HerdrPanelBindingProbe.swift
expect true "the ssh -L forward runs the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteHerdrForward.swift
expect true "forward supervision runs the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardSupervisor.swift
expect true "ssh -G canonicalization runs the lane" \
  Sources/localvoxtral/ClaudeContext/SSHDestinationCanonicalizer.swift
expect true "the remote herdr config patch runs the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentService.swift
expect true "the join arm that consumes all of it runs the lane" \
  Sources/localvoxtral/ClaudeContext/TerminalScreenClaudeJoin.swift

# --- The assumptions themselves -------------------------------------------
# The doc is the record of what the lane pins. Editing it without re-running
# the lane is exactly how a stale assumption survives a herdr upgrade.

expect true "editing the panel-binding design doc runs the lane" \
  docs/agent/remote-herdr-panel-binding.md
expect true "the fixture itself runs the lane" \
  scripts/herdr-integration-fixture.sh
expect true "the lane's own suite runs the lane" \
  Tests/localvoxtralTests/HerdrIntegrationTests.swift

# --- Marker opt-in ---------------------------------------------------------

expect true "the explicit marker runs the lane on an unrelated diff" \
  README.md --marker 'fixes a thing [run-herdr-integration] please run it'
expect false "a lookalike marker does not run the lane" \
  README.md --marker 'run-herdr-integration without the brackets'

# --- The run=false side ----------------------------------------------------
# A live-service lane that runs on everything is a lane people learn to
# ignore. These are the diffs that must NOT start a herdr server.

expect false "UI-only changes do not run the lane" \
  Sources/localvoxtral/SettingsView.swift
expect false "polish-model work does not run the lane" \
  Sources/localvoxtral/Resources/Config/llm_polish.toml
expect false "docs outside the assumption record do not run the lane" \
  README.md docs/architecture.md
expect false "an empty diff does not run the lane"

printf '\nAll herdr lane filter checks passed.\n'
