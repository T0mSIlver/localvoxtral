#!/bin/bash
# Pins scripts/ci/stt-lane-filter.sh: which diffs buy live STT inference on the
# owner's Mac, and that main, dispatches and unknown events are never gated.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/stt-lane-filter.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-stt-lane-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> [--event <name>] [--marker <text>] <changed-path>...
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" marker_file="" event="pull_request"
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --marker) marker_file="$TMP_DIR/marker"; printf '%s\n' "$2" >"$marker_file"; shift 2 ;;
      --event) event="$2"; shift 2 ;;
      *) printf '%s\n' "$1" >>"$changed"; shift ;;
    esac
  done
  local output run reason
  output="$("$FILTER" "$changed" "$event" "$marker_file")" || fail "$description: filter exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

expect true "the realtime client runs the lane" \
  Sources/localvoxtral/RealtimeAPIWebSocketClient.swift
expect true "the shared base client runs the lane" \
  Sources/localvoxtral/BaseRealtimeWebSocketClient.swift
expect true "the view model's realtime event handling runs the lane" \
  "Sources/localvoxtral/DictationViewModel+RealtimeEvents.swift"
expect true "the scorer's normalizer runs the lane" \
  Sources/localvoxtral/TextMergingAlgorithms.swift
expect true "the suite itself runs the lane" \
  Tests/localvoxtralTests/RealtimeAPIVLLMIntegrationTests.swift
expect true "a dependency pin runs the lane" Package.resolved
expect true "the workflow that invokes it runs the lane" .github/workflows/ci.yml

expect false "a settings pane change does not" Sources/localvoxtral/SettingsView.swift
expect false "an enrollment change does not" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentService.swift
# The service under test is the helper installed on the build host, never the
# PR's build, so this lane cannot see a SpeechHelper diff.
expect false "a SpeechHelper change does not (its own integration lane does)" \
  SpeechHelper/Sources/SpeechHelperCore/Engine.swift
expect false "an empty changed-file list decides run=false (caller owns fail-open)"

expect true "[run-stt-integration] forces the lane" \
  --marker "proof [run-stt-integration]" docs/architecture.md
expect false "another lane's marker does not" \
  --marker "[run-llm-eval]" docs/architecture.md

expect true "a push to main is never gated" --event push docs/architecture.md
expect true "a dispatch is never gated" --event workflow_dispatch docs/architecture.md
expect true "an unknown event fails open" --event merge_group docs/architecture.md

# Every source pattern must still match a file, or a rename has silently
# ungated the lane for the file it was written for.
patterns="$(sed -n "/^PATTERNS=(/,/^)/p" "$FILTER" | sed -n "s/^  '\([^']*\)'.*/\1/p")"
[[ -n "$patterns" ]] || fail "could not parse PATTERNS"
while IFS= read -r pattern; do
  # shellcheck disable=SC2086
  if ! compgen -G "$ROOT_DIR/"$pattern >/dev/null; then
    fail "pattern matches no file in the tree: $pattern"
  fi
done <<<"$patterns"
echo "PASS: every pattern matches a file in the tree"

if "$FILTER" >/dev/null 2>&1; then fail "a missing argument was accepted"; fi
echo "OK: stt-lane-filter tests passed"
