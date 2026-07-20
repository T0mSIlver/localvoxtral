#!/usr/bin/env bash
# Regression test for clean-stale-outputs.sh: transient outputs go, build
# caches stay, and the .build.smoke-hidden repair restores the cache instead
# of nesting it. Runs against a copy of the script in a throwaway tree.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-clean-stale-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

stage() {
  rm -rf "$TMP_DIR/tree"
  mkdir -p "$TMP_DIR/tree/scripts/ci"
  cp "$ROOT_DIR/scripts/ci/clean-stale-outputs.sh" "$TMP_DIR/tree/scripts/ci/"
}

# Normal case: transient outputs removed, caches preserved.
stage
mkdir -p "$TMP_DIR/tree/.build" "$TMP_DIR/tree/PolishHelper/.build" \
  "$TMP_DIR/tree/dist" "$TMP_DIR/tree/logs"
touch "$TMP_DIR/tree/.build/cache-marker" \
  "$TMP_DIR/tree/format-lint.txt" "$TMP_DIR/tree/default.profraw" \
  "$TMP_DIR/tree/.agent-eval-e2e-enable.json" \
  "$TMP_DIR/tree/.speechd-integration-enable.json"
"$TMP_DIR/tree/scripts/ci/clean-stale-outputs.sh"
[[ -f "$TMP_DIR/tree/.build/cache-marker" ]] || fail "build cache was removed"
[[ -d "$TMP_DIR/tree/PolishHelper/.build" ]] || fail "helper build cache was removed"
for gone in dist logs format-lint.txt default.profraw \
  .agent-eval-e2e-enable.json .speechd-integration-enable.json; do
  [[ ! -e "$TMP_DIR/tree/$gone" ]] || fail "$gone survived cleanup"
done
echo "PASS: transient outputs removed, build caches preserved"

# Repair case: a SIGKILLed smoke left .build.smoke-hidden AND a fresh .build
# was recreated after; the hidden (real) cache must win, not nest.
stage
mkdir -p "$TMP_DIR/tree/.build.smoke-hidden" "$TMP_DIR/tree/.build"
touch "$TMP_DIR/tree/.build.smoke-hidden/real-cache" \
  "$TMP_DIR/tree/.build/imposter"
"$TMP_DIR/tree/scripts/ci/clean-stale-outputs.sh"
[[ -f "$TMP_DIR/tree/.build/real-cache" ]] || fail "smoke-hidden cache was not restored"
[[ ! -e "$TMP_DIR/tree/.build/imposter" ]] || fail "imposter .build survived the repair"
[[ ! -d "$TMP_DIR/tree/.build.smoke-hidden" ]] || fail ".build.smoke-hidden left behind"
echo "PASS: smoke-hidden repair restores the real cache without nesting"

# Caller-cwd independence: invoked from a subdirectory, it still cleans the
# repo root the script lives in.
stage
mkdir -p "$TMP_DIR/tree/dist" "$TMP_DIR/elsewhere"
(cd "$TMP_DIR/elsewhere" && "$TMP_DIR/tree/scripts/ci/clean-stale-outputs.sh")
[[ ! -e "$TMP_DIR/tree/dist" ]] || fail "cleanup did not operate on the script's repo root"
echo "PASS: operates on the script's repo root regardless of caller cwd"

echo "clean-stale-outputs tests passed"
