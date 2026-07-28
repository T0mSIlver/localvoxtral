#!/usr/bin/env bash
# Regression test for llm-lane-filter.sh's path decisions and marker opt-in.
# Pure shell, no git or network — changed-file lists are written to temp
# files, so it runs anywhere (hosted fork PRs included).
#
# Not a mirror of the whole pattern list: it pins the decisions that were
# bugs or near-misses — model-input integrations (the opencode plugin
# shipped without a pattern, PR #204 review), the marker path, and the
# run=false side that keeps UI/doc-only diffs off the live-model lane.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/llm-lane-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-llm-lane-filter-test.XXXXXX")"
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

# --- Model-input integrations ---------------------------------------------
# Both agent plugins shape what reaches the polish model (prompt extraction,
# cwd, file grounding); a plugin-only diff must run the lane.

expect true "opencode plugin change runs the lane" \
  integrations/opencode/localvoxtral.js
expect true "opencode integration docs stay lane-relevant (claude-code parity)" \
  integrations/opencode/README.md
expect true "claude-code plugin change runs the lane" \
  integrations/claude-code/plugins/localvoxtral/hooks/hooks.json

# --- Marker opt-in ----------------------------------------------------------

expect true "[run-llm-eval] marker forces the lane on any diff" \
  README.md --marker 'judgment call, opting in [run-llm-eval]'
expect false "unrelated marker text does not trigger" \
  README.md --marker 'no opt-in here'

# --- run=false side ---------------------------------------------------------

expect false "top-level docs do not run the lane" \
  README.md AGENTS.md
expect false "UI-only Swift change does not run the lane" \
  Sources/localvoxtral/SettingsView.swift
expect false "empty changed-file list decides run=false (caller owns fail-open)" \
  ""

printf 'OK: llm-lane-filter tests passed\n'
