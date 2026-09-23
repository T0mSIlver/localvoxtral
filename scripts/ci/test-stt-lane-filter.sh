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
expect true "what the client trims keys and model names with runs the lane" \
  Sources/localvoxtral/StringExtensions.swift
expect true "what the unavailable-device test calls runs the lane" \
  Sources/localvoxtral/AudioDeviceManager.swift
# `*` in a bash case pattern crosses `/`, so a wide *Realtime* used to buy the
# lane for files the suite never executes.
expect false "the view model's realtime event handling does not" \
  "Sources/localvoxtral/DictationSessionController+RealtimeEvents.swift"
expect false "the reconnect policy does not" \
  Sources/localvoxtral/RealtimeReconnectPolicy.swift
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

# A rename must not silently ungate the lane for the file an entry was written
# for. Exact entries are checked as paths; the one glob is checked against the
# three clients it exists to cover, by name, because "matches something" would
# still pass with two of them gone.
patterns="$(sed -n "/^PATTERNS=(/,/^)/p" "$FILTER" | sed -n "s/^  '\([^']*\)'.*/\1/p")"
[[ -n "$patterns" ]] || fail "could not parse PATTERNS"
pattern_lines="$(sed -n "/^PATTERNS=(/,/^)/p" "$FILTER" | sed '1d;$d' | grep -vcE "^[[:space:]]*(#|$)" || true)"
[[ "$pattern_lines" == "$(wc -l <<<"$patterns" | tr -d ' ')" ]] \
  || fail "PATTERNS holds an entry this test cannot parse"
while IFS= read -r pattern; do
  [[ "$pattern" == *'*'* ]] && continue
  [[ -e "$ROOT_DIR/$pattern" ]] || fail "listed path does not exist: $pattern"
done <<<"$patterns"
for client in BaseRealtimeWebSocketClient RealtimeAPIWebSocketClient MistralRealtimeWebSocketClient; do
  [[ -e "$ROOT_DIR/Sources/localvoxtral/$client.swift" ]] || fail "client file is gone: $client.swift"
  expect true "$client is in the client family" "Sources/localvoxtral/$client.swift"
done
echo "PASS: every listed path exists and the glob covers the three clients"

if "$FILTER" >/dev/null 2>&1; then fail "a missing argument was accepted"; fi
echo "OK: stt-lane-filter tests passed"
