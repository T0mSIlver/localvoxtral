#!/usr/bin/env bash
# Regression test for waits-labels.sh: each lane filter maps to its label,
# the markers count, and the base decides waits:stack. The path lists
# themselves are pinned by the filters' own tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/ci/waits-labels.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-waits-labels-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <expected labels, space-separated> <description> <base-ref> <marker> <changed-path>...
expect() {
  local expected="$1" description="$2" base="$3" marker="$4"
  shift 4
  : >"$TMP_DIR/changed"
  for path in "$@"; do
    printf '%s\n' "$path" >>"$TMP_DIR/changed"
  done
  printf '%s\n' "$marker" >"$TMP_DIR/marker"
  local got
  got="$("$SCRIPT" "$TMP_DIR/changed" "$TMP_DIR/marker" "$base" | tr '\n' ' ' | sed 's/ $//')"
  [[ "$got" == "$expected" ]] || fail "$description: expected '$expected', got '$got'"
  printf 'PASS: %s\n' "$description"
}

expect "" "a docs change on main waits for nothing" \
  main "" docs/install.md
expect "waits:mac-llm" "a polish helper change waits for the LLM lane" \
  main "" PolishHelper/Sources/PolishHelper/main.swift
expect "waits:mac-voxtral" "a speech helper change waits for the speechd lane" \
  main "" SpeechHelper/Package.swift
expect "waits:mac-voxtral" "the STT filter alone earns the Voxtral label" \
  main "" Sources/localvoxtralCore/RealtimeAPIWebSocketClient.swift
expect "waits:mac-llm waits:mac-voxtral" "both lane markers earn both labels" \
  main "[run-llm-eval] [run-speechd-integration]" docs/install.md
expect "waits:stack" "a base other than main is a stack" \
  t/717-wire-notification-type "" docs/install.md
