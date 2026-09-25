#!/usr/bin/env bash
# Regression test for dogfood-filter.sh. Pure shell, no git or network:
# changed-file lists are written to temp files, so it runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/dogfood-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-dogfood-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> [--event <name>] <changed-path>...
expect() {
  local expected="$1" description="$2"
  shift 2
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
    output="$("$FILTER" "$changed" "$event")" || fail "$description: filter exited non-zero"
  else
    output="$("$FILTER" "$changed")" || fail "$description: filter exited non-zero"
  fi
  local actual
  actual="$(sed -n 's/^run=//p' <<<"$output")"
  [[ "$actual" == "$expected" ]] \
    || fail "$description: expected run=$expected, got '$actual' (output: $output)"
  grep -q '^reason=.' <<<"$output" || fail "$description: missing reason"
}

# Swift inputs run it.
expect true "app source" Sources/localvoxtral/DictationViewModel.swift
expect true "core source" Sources/localvoxtralCore/SessionClock.swift
expect true "bundled config resource" Sources/localvoxtral/Resources/Config/default.toml
expect true "test file" Tests/localvoxtralTests/DogfoodCaptureStoreTests.swift
expect true "manifest" Package.swift
expect true "lockfile" Package.resolved
expect true "one Swift file among docs" docs/dictation.md Sources/localvoxtral/SettingsStore.swift

# The job definition and this filter run it.
expect true "ci.yml" .github/workflows/ci.yml
expect true "the filter itself" scripts/ci/dogfood-filter.sh

# Everything else skips it.
expect false "docs only" docs/dictation.md AGENTS.md
expect false "scripts only" scripts/lib/owner-app-session.sh scripts/ci/test-ui-smoke-owner-app.sh
expect false "another workflow" .github/workflows/ui-smoke.yml
expect false "helper package" PolishHelper/Sources/PolishHelper/main.swift SpeechHelper/Package.swift
expect false "eval corpus" EvalCorpus/agent-dictation/README.md
expect false "nested Package.swift is not the root manifest" integrations/foo/Package.swift

# Fail open.
expect true "empty list"
expect true "push" --event push docs/dictation.md
expect true "dispatch" --event workflow_dispatch docs/dictation.md
expect true "unknown event" --event merge_group docs/dictation.md
expect false "pull_request is gated" --event pull_request docs/dictation.md

# Usage errors exit non-zero.
if "$FILTER" >/dev/null 2>&1; then fail "no arguments should exit non-zero"; fi
if "$FILTER" "$TMP_DIR/missing" >/dev/null 2>&1; then fail "missing file should exit non-zero"; fi

echo "PASS: dogfood-filter.sh"
