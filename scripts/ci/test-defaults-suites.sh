#!/usr/bin/env bash
# Tests make their UserDefaults suites with makeTestDefaults() or
# makeTestDefaultsSuite() (Tests/localvoxtralTestSupport/TestDefaults.swift),
# never with UserDefaults(suiteName:). A named suite is a plist in
# ~/Library/Preferences that survives removePersistentDomain, and the owner's
# Mac had 310k of them, one per test run. The helper's suites live in a
# temporary folder that teardown deletes.
#
# Checks a fixture tree first, so the check is known to fail on the mistake,
# then the repo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HELPER="Tests/localvoxtralTestSupport/TestDefaults.swift"

# offenders <root>: every line under <root>/Tests that names a suite itself.
offenders() {
  (cd "$1" && grep -rnE 'UserDefaults(\.init)?\(suiteName:' Tests --include='*.swift' \
    | grep -v "^$HELPER:" || true)
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-defaults-suites.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/Tests/localvoxtralTests" "$TMP_DIR/Tests/localvoxtralTestSupport"
cat >"$TMP_DIR/Tests/localvoxtralTests/LeakyTests.swift" <<'SWIFT'
let defaults = UserDefaults(suiteName: "localvoxtral.LeakyTests.\(UUID().uuidString)")!
SWIFT
cat >"$TMP_DIR/$HELPER" <<'SWIFT'
defaults = UserDefaults(suiteName: suiteName)!
SWIFT
found="$(offenders "$TMP_DIR")"
if [[ "$found" != *LeakyTests.swift* || "$found" == *TestDefaults.swift* ]]; then
  printf 'FAIL: the check does not flag the fixture correctly:\n%s\n' "$found" >&2
  exit 1
fi

found="$(offenders "$ROOT_DIR")"
if [[ -n "$found" ]]; then
  printf '%s\n' "$found" >&2
  printf 'FAIL: these tests make a UserDefaults suite in ~/Library/Preferences, which outlives the run. Use makeTestDefaults() or makeTestDefaultsSuite() from %s.\n' "$HELPER" >&2
  exit 1
fi

echo "PASS: test defaults suites"
