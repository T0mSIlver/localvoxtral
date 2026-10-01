#!/usr/bin/env bash
# Regression test for xctest-crash-summary.py (#1162).
#
# Runs it over fixture crash reports: a SIGSEGV report must yield its
# exception, termination and crashed-thread frames, newest report first; a
# report that is not JSON is named, not fatal; an empty directory says so and
# still exits 0, and --max caps the reports printed.
#
# Needs python3, no network: ./scripts/ci/test-xctest-crash-summary.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SUMMARY="$ROOT_DIR/scripts/ci/xctest-crash-summary.py"
FIXTURES="$ROOT_DIR/scripts/ci/fixtures/xctest-crash"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-xctest-crash-summary-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

expect_line() {
  grep -qxF -- "$2" <<<"$1" || fail "missing line: $2"$'\n'"--- output ---"$'\n'"$1"
}

REPORTS="$TMP_DIR/reports"
mkdir -p "$REPORTS"
cp "$FIXTURES"/*.ips "$REPORTS/"
cp "$FIXTURES/xctest-2026-10-01-135250.ips" "$REPORTS/other-process.ips"
# Checkout times carry no order; pin one: the broken report is the older.
touch -t 202610010000 "$REPORTS/xctest-2026-10-01-000000.ips"
touch -t 202610011352 "$REPORTS/xctest-2026-10-01-135250.ips"

out="$("$SUMMARY" --dir "$REPORTS")"
expect_line "$out" "xctest crash reports: 2"
expect_line "$out" "exception: EXC_BAD_ACCESS SIGSEGV KERN_INVALID_ADDRESS at 0x0000000000000008"
expect_line "$out" "termination: Segmentation fault: 11"
expect_line "$out" "-- crashed thread 0 (com.apple.main-thread) --"
expect_line "$out" "   1 localvoxtralPackageTests     OverlayDestinationClickTests.testARowScrolledOutOfViewPicksNothing() + 120 (OverlayDestinationClickTests.swift:110)"
expect_line "$out" "   2 XCTestCore                   0x3000"
grep -q "NSEventThread" <<<"$out" && fail "printed a thread that did not crash"
pass "a SIGSEGV report yields its exception and crashed-thread frames"

[[ "$(grep -n '^=====' <<<"$out" | head -n 1)" == *"135250"* ]] || fail "newest report is not first: $out"
grep -q "^===== xctest-2026-10-01-000000.ips: not a JSON crash report" <<<"$out" \
  || fail "the broken report is not named: $out"
pass "newest first, and a broken report is named, not fatal"

out="$("$SUMMARY" --dir "$REPORTS" --max 1)"
[[ "$(grep -c '^=====' <<<"$out")" == 1 ]] || fail "--max 1 printed more: $out"
pass "--max caps the reports printed"

mkdir "$TMP_DIR/empty"
out="$("$SUMMARY" --dir "$TMP_DIR/empty" --wait 1)" || fail "an empty directory is not exit 0"
[[ "$out" == "xctest crash reports: 0" ]] || fail "empty directory: $out"
pass "no report: says so and exits 0"
