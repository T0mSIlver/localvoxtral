#!/usr/bin/env bash
# Regression tests for scripts/lib/unit-test-shards.sh: the plan, the one
# merged log, and the checks that turn a shard that ran too little red. The
# swift commands are a stub, so this runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-unit-shards-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/unit-test-shards.sh
. "$ROOT_DIR/scripts/lib/unit-test-shards.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$TMP_DIR/list" <<'LIST'
Building for debugging...
Mod.Alpha/testOne
Mod.Alpha/testTwo
Mod.Beta/testOne
Mod.Gamma/testOne
Mod.Gamma/testTwo
Mod.Gamma/testThree
Mod.Skipped/testOne
Mod.Delta/testOne
LIST
cat >"$TMP_DIR/weights" <<'WEIGHTS'
9.000 Beta
4.000 Gamma
3.000 Alpha
WEIGHTS

# --- plan -------------------------------------------------------------------

plan="$(LV_SHARD_SKIP_PATTERNS="Skipped" lv_plan_unit_shards 2 "$TMP_DIR/weights" <"$TMP_DIR/list")"
# Beta (9) alone; Gamma (4) + Alpha (3) + Delta (1 test at the known
# classes' 16 s / 6 tests) on the other. Skipped is gone.
[[ "$plan" == $'1 Mod.Beta\n6 Mod.Gamma Mod.Alpha Mod.Delta' ]] || fail "plan with weights: $plan"

plan="$(lv_plan_unit_shards 2 "$TMP_DIR/no-such-file" <"$TMP_DIR/list")"
# No weights: each class weighs its test count, ties go by name.
[[ "$plan" == $'4 Mod.Gamma Mod.Delta\n4 Mod.Alpha Mod.Beta Mod.Skipped' ]] || fail "plan without weights: $plan"

plan="$(lv_plan_unit_shards 20 "$TMP_DIR/weights" <"$TMP_DIR/list" | wc -l | tr -d ' ')"
[[ "$plan" == "5" ]] || fail "more shards than classes should give one shard per class, got $plan"

if printf 'no tests here\n' | lv_plan_unit_shards 2 "$TMP_DIR/weights" >/dev/null; then
  fail "a listing with no classes must fail"
fi

# A Swift Testing id the shards could neither filter nor count fails the plan.
for id in 'Mod/freeFunction()' 'Mod.Suite/test()' 'Mod.Outer/Inner/test()'; do
  if printf 'Mod.Alpha/testOne\n%s\n' "$id" \
      | lv_plan_unit_shards 2 "$TMP_DIR/weights" >/dev/null 2>"$TMP_DIR/plan.err"; then
    fail "the plan accepted a test id it cannot count: $id"
  fi
  grep -qF "not an XCTest test id, which the shards cannot run and count: $id" "$TMP_DIR/plan.err" \
    || fail "no reason given for $id: $(cat "$TMP_DIR/plan.err")"
done
# ... unless the run skips it anyway.
printf 'Mod.Alpha/testOne\nMod/skippedFree()\n' \
  | LV_SHARD_SKIP_PATTERNS="skippedFree" lv_plan_unit_shards 2 "$TMP_DIR/weights" >/dev/null \
  || fail "a skipped Swift Testing id must not fail the plan"

# --- weights from a log -----------------------------------------------------

cat >"$TMP_DIR/xctest.log" <<'LOG'
Test Suite 'Selected tests' started at 2026-09-23 10:00:00.000.
Test Suite 'Alpha' started at 2026-09-23 10:00:00.000.
Test Suite 'Alpha' passed at 2026-09-23 10:00:01.000.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.900 (1.250) seconds
Test Suite 'Beta' failed at 2026-09-23 10:00:02.000.
	 Executed 1 test, with 1 failure (0 unexpected) in 0.500 (0.500) seconds
Test Suite 'Selected tests' passed at 2026-09-23 10:00:03.000.
	 Executed 3 tests, with 1 failure (0 unexpected) in 1.400 (1.750) seconds
LOG
weights="$(lv_unit_suite_seconds "$TMP_DIR/xctest.log")"
[[ "$weights" == $'1.250 Alpha\n0.500 Beta' ]] || fail "weights from a log: $weights"
[[ "$(lv_executed_test_count "$TMP_DIR/xctest.log")" == "3" ]] || fail "executed count"

# Swift 6.4 runs each test bundle on its own: one run-level total per bundle,
# the last one often an empty bundle's.
cat >"$TMP_DIR/bundles.log" <<'LOG'
Test Suite 'Selected tests' started at 2026-09-24 10:00:00.000.
Test Suite 'Alpha' passed at 2026-09-24 10:00:01.000.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.900 (1.250) seconds
Test Suite 'appTests.xctest' passed at 2026-09-24 10:00:01.000.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.900 (1.250) seconds
Test Suite 'Selected tests' passed at 2026-09-24 10:00:01.000.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.900 (1.250) seconds
Test Suite 'Selected tests' started at 2026-09-24 10:00:02.000.
Test Suite 'Core' passed at 2026-09-24 10:00:02.000.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.100 (0.100) seconds
Test Suite 'Selected tests' passed at 2026-09-24 10:00:02.000.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.100 (0.100) seconds
Test Suite 'Selected tests' started at 2026-09-24 10:00:03.000.
Test Suite 'Selected tests' passed at 2026-09-24 10:00:03.000.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
LOG
[[ "$(lv_executed_test_count "$TMP_DIR/bundles.log")" == "7" ]] \
  || fail "executed count over bundles: $(lv_executed_test_count "$TMP_DIR/bundles.log")"

# --- a whole run against a stub swift ---------------------------------------

# Prints what a real `swift test --filter` would: one Executed line per class
# and the run's total last. STUB_DROP names a class to leave out (a --filter
# that matched nothing); STUB_FAIL a class whose test fails. STUB_LOCK prints
# the native build system's lock error before the tests and exits 1 after them,
# as Xcode 27's SwiftPM does (#543); STUB_ERROR adds one more output line and
# STUB_LOCK_JOINED text on the lock line itself.
LOCK_LINE="Another instance of SwiftPM (PID: 1) is already running using 'x/.build', but this will be ignored since \`--ignore-lock\` has been passederror: unable to attach DB: error: accessing build database \"x/.build/build.db\": database is locked Possibly there are two concurrent builds running in the same filesystem location."
lv_shard_swift() {
  echo "swift $*" >>"$TMP_DIR/calls"
  case "$1 ${2:-}" in
    "build --build-tests") echo "Build complete!"; return 0 ;;
    "test list") cat "$TMP_DIR/list"; return 0 ;;
  esac
  if [[ -n "${STUB_LOCK_ONCE:-}" && ! -f "$TMP_DIR/locked-once" ]]; then
    : >"$TMP_DIR/locked-once"
    echo "error: unable to attach DB: error: accessing build database \"x/build.db\": database is locked"
    return 1
  fi
  [[ -n "${STUB_LOCK:-}" ]] && echo "$LOCK_LINE${STUB_LOCK_JOINED:-}"
  local arg class total=0 failures=0 status=0 previous=""
  for arg in "$@"; do
    if [[ "$previous" == "--filter" ]]; then
      class="${arg#*.}"
      class="${class%/}"
      [[ "$class" == "${STUB_DROP:-}" ]] && { previous="$arg"; continue; }
      if [[ "$class" == "${STUB_FAIL:-}" ]]; then
        status=1
        failures=$((failures + 1))
        echo "/x/$class.swift:1: error: -[Mod.$class testOne] : XCTAssertTrue failed"
        echo "Test Case '-[Mod.$class testOne]' failed (0.001 seconds)."
        echo "Test Suite '$class' failed at 2026-09-23 10:00:00.000."
        echo "	 Executed 1 test, with 1 failure (0 unexpected) in 0.1 (0.1) seconds"
      else
        echo "Test Suite '$class' passed at 2026-09-23 10:00:00.000."
        echo "	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
      fi
      total=$((total + 1))
    fi
    previous="$arg"
  done
  echo "Test Suite 'Selected tests' passed at 2026-09-23 10:00:00.000."
  echo "	 Executed $total tests, with $failures failures (0 unexpected) in 0.1 (0.1) seconds"
  [[ -n "${STUB_ERROR:-}" ]] && echo "$STUB_ERROR"
  [[ -n "${STUB_LOCK:-}" ]] && status=1
  return "$status"
}

# Every class in the stub runs one test, so the listing's counts must match.
cat >"$TMP_DIR/list" <<'LIST'
Mod.Alpha/testOne
Mod.Beta/testOne
Mod.Gamma/testOne
Mod.Skipped/testOne
LIST

LV_SHARD_WEIGHTS="$TMP_DIR/weights"
log="$TMP_DIR/run.log"
lv_run_unit_shards 2 "$log" Skipped -- --enable-code-coverage >/dev/null \
  || fail "a clean run must pass: $(cat "$log")"
grep -q "^==> Unit shards: 3 of 3 tests ran in 2 shards" "$log" || fail "summary line: $(cat "$log")"
grep -q "Test Suite 'Alpha'" "$log" && grep -q "Test Suite 'Beta'" "$log" \
  && grep -q "Test Suite 'Gamma'" "$log" || fail "merged log misses a shard's output"
[[ "$(grep -c '^==> Shard [12]/2: exit 0' "$log")" == "2" ]] || fail "per-shard lines"
grep -q "^swift test --skip-build --ignore-lock --skip Skipped --filter Mod.Beta/ --enable-code-coverage$" \
  "$TMP_DIR/calls" || fail "shard command: $(cat "$TMP_DIR/calls")"
if grep -q "Mod.Skipped/" "$TMP_DIR/calls"; then fail "a skipped class got a filter"; fi
# Two test modules (the app's and the core's): each class is filtered under
# its own module, and the weights file's bare names still weigh them.
: >"$TMP_DIR/calls"
printf 'Mod.Alpha/testOne\nCore.Zeta/testOne\n' >"$TMP_DIR/list"
lv_run_unit_shards 2 "$TMP_DIR/two-modules.log" -- >/dev/null \
  || fail "a run over two modules must pass: $(cat "$TMP_DIR/two-modules.log")"
grep -q "^==> Unit shards: 2 of 2 tests ran in 2 shards" "$TMP_DIR/two-modules.log" \
  || fail "two-module summary: $(cat "$TMP_DIR/two-modules.log")"
grep -q -- "--filter Core.Zeta/" "$TMP_DIR/calls" || fail "the core class kept no module: $(cat "$TMP_DIR/calls")"
grep -q -- "--filter Mod.Alpha/" "$TMP_DIR/calls" || fail "the app class kept no module: $(cat "$TMP_DIR/calls")"
plan="$(lv_plan_unit_shards 1 "$TMP_DIR/weights" <"$TMP_DIR/list")"
[[ "$plan" == "2 Core.Zeta Mod.Alpha" ]] || fail "two-module plan: $plan"
printf 'Mod.Alpha/testOne\nMod.Beta/testOne\nMod.Gamma/testOne\nMod.Skipped/testOne\n' >"$TMP_DIR/list"

# Shard 1 comes before shard 2 in the log, whatever order they ended in.
[[ "$(grep -n '^==> Shard 1/2: exit' "$log" | cut -d: -f1)" -lt \
  "$(grep -n '^==> Shard 2/2: [0-9]* classes' "$log" | cut -d: -f1)" ]] \
  || fail "shard blocks out of order"

if STUB_FAIL=Gamma lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "a red shard must fail the run"
fi
grep -q "^==> Shard [12]/2: exit 1" "$log" || fail "red shard's exit status missing"

if STUB_DROP=Beta lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "a class that no shard ran must fail the run"
fi
grep -q "^==> FAILED: the shards ran 2 tests; the listing holds 3" "$log" \
  || fail "count mismatch line: $(cat "$log")"

rm -f "$TMP_DIR/locked-once"
STUB_LOCK_ONCE=1 lv_run_unit_shards 2 "$log" Skipped >/dev/null \
  || fail "a shard that met a locked build database must be retried: $(cat "$log")"
grep -q "build database was locked by another shard; retrying" "$log" || fail "retry not logged"

# Xcode 27: every shard meets the lock, runs all its tests and exits 1. A
# shard whose tests all passed and whose only error is the lock passes (#543).
STUB_LOCK=1 lv_run_unit_shards 2 "$log" Skipped >/dev/null \
  || fail "a shard whose only error was the locked build database must pass: $(cat "$log")"
[[ "$(grep -c '^==> Shard [12]/2: exit 0' "$log")" == "2" ]] || fail "lock-only shards: $(cat "$log")"
grep -q "exit 1 came only from SwiftPM's locked build database" "$log" || fail "lock pass not logged"
if grep -q "retrying" "$log"; then fail "a shard that ran its tests was retried"; fi

# ... and the lock never hides a real failure: a failed test, a test that did
# not run, or any other error.
if STUB_LOCK=1 STUB_FAIL=Gamma lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "the lock turned a failed test green: $(cat "$log")"
fi
grep -q "^==> Shard [12]/2: exit 1" "$log" || fail "a failed test behind the lock: $(cat "$log")"
if STUB_LOCK=1 STUB_DROP=Beta lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "the lock turned a missing test green: $(cat "$log")"
fi
grep -q "^==> Shard [12]/2: exit 1" "$log" || fail "a missing test behind the lock: $(cat "$log")"
if STUB_LOCK=1 STUB_ERROR="error: Exited with unexpected signal code 11" \
    lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "the lock turned a crash green: $(cat "$log")"
fi
[[ "$(grep -c '^==> Shard [12]/2: exit 1' "$log")" == "2" ]] || fail "a crash behind the lock: $(cat "$log")"
if STUB_LOCK=1 STUB_LOCK_JOINED="error: Exited with unexpected signal code 11" \
    lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "the lock turned a crash on its own line green: $(cat "$log")"
fi
if STUB_LOCK=1 STUB_ERROR="✘ Test run with 1 test failed after 0.1 seconds with 1 issue." \
    lv_run_unit_shards 2 "$log" Skipped >/dev/null; then
  fail "the lock turned a Swift Testing failure green: $(cat "$log")"
fi

# TERM mid-run: each shard's swift process goes too, not only the subshell
# that started it, and the log keeps what the shards printed so far.
cat >"$TMP_DIR/hang-list" <<'LIST'
Mod.Alpha/testOne
Mod.Beta/testOne
LIST
cat >"$TMP_DIR/term-run.sh" <<SCRIPT
#!/usr/bin/env bash
. "$ROOT_DIR/scripts/lib/unit-test-shards.sh"
lv_shard_swift() {
  case "\$1 \${2:-}" in
    "build --build-tests") return 0 ;;
    "test list") cat "$TMP_DIR/hang-list"; return 0 ;;
  esac
  echo "shard output before the hang"
  "$TMP_DIR/fake-swift" &
  echo "\$!" >>"$TMP_DIR/swift-pids"
  wait
}
LV_SHARD_WEIGHTS=/dev/null lv_run_unit_shards 2 "$TMP_DIR/term.log"
SCRIPT
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$TMP_DIR/fake-swift"
chmod +x "$TMP_DIR/term-run.sh" "$TMP_DIR/fake-swift"
"$TMP_DIR/term-run.sh" >/dev/null 2>&1 &
runner=$!
waited=0
until [[ -f "$TMP_DIR/swift-pids" && "$(wc -l <"$TMP_DIR/swift-pids")" -ge 2 ]]; do
  (( waited++ < 100 )) || fail "the shards never started"
  sleep 0.1
done
kill -TERM "$runner"
wait "$runner" 2>/dev/null || true
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    fail "a shard's swift process outlived TERM"
  fi
done <"$TMP_DIR/swift-pids"
[[ "$(grep -c '^==> Shard [12]/2: INTERRUPTED' "$TMP_DIR/term.log")" == "2" ]] \
  || fail "interrupted shards missing from the log: $(cat "$TMP_DIR/term.log")"
grep -q "shard output before the hang" "$TMP_DIR/term.log" || fail "partial shard output lost"

echo "PASS: unit test shards"
