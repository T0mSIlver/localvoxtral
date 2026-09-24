#!/usr/bin/env bash
# Regression test (#545): off a Mac, `remote-build.sh test` runs the suites
# that build on Linux here and sends only the rest to the Mac. ssh, rsync,
# uname and the local swift are stubs; the payloads sent must still pass the
# real build gate.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-linux-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
printf '%s\n' "$1" >>"$LV_TEST_SSH_LOG"
case "$1" in
  *"swift test"*)
    echo "Test Suite 'Selected tests' passed at 2026-09-25 10:00:00.000."
    echo "	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
    ;;
esac
exit 0
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$TMP_DIR/bin/uname" <<'STUB'
#!/usr/bin/env bash
echo "${LV_TEST_UNAME:-Linux}"
STUB
# The local toolchain scripts/core-tests-linux.sh drives.
cat >"$TMP_DIR/bin/fake-swift" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LV_TEST_SWIFT_LOG"
if [[ "$1" == test ]]; then
  echo "	 Executed 3 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
  exit "${LV_TEST_LINUX_STATUS:-0}"
fi
exit 0
STUB
chmod +x "$TMP_DIR/bin/"*

ssh_log="$TMP_DIR/ssh.log"
swift_log="$TMP_DIR/swift.log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "SWIFT=$TMP_DIR/bin/fake-swift"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-linux-routing-regression"
  "LV_LINUX_SCRATCH=$TMP_DIR/linux-build"
  "LV_TEST_SSH_LOG=$ssh_log"
  "LV_TEST_SWIFT_LOG=$swift_log"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote.log"
  "LOCALVOXTRAL_LINUX_LOG=$TMP_DIR/linux.log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/gc.log"
)

run() {
  : >"$ssh_log"
  : >"$swift_log"
  env "${common_env[@]}" "$@" >"$TMP_DIR/out.log" 2>&1
}

swift_tests() { grep '^test ' "$swift_log" || true; }
mac_tests() { grep 'swift test' "$ssh_log" || true; }

# The split follows Package.swift: its Linux test modules exist, and the app's
# suite is not one of them.
modules="$(bash -c '. "$1/scripts/lib/linux-suites.sh"; lv_linux_test_modules' _ "$ROOT_DIR")"
[[ -n "$modules" ]] || fail "no Linux test module found in Package.swift"
for module in $modules; do
  [[ -d "$ROOT_DIR/Tests/$module" ]] || fail "Linux test module $module has no Tests/$module"
  [[ "$module" != localvoxtralTests ]] || fail "the app's suite is listed as a Linux module"
done

# A --filter naming Linux suites only never reaches the Mac, and needs no
# build host.
run LV_BUILD_HOST= "$REMOTE_BUILD" test --filter TextMergingAlgorithmsTests \
  --filter localvoxtralCoreTests.DoubleMetaphoneTests/testSmith \
  || fail "a Linux-only run failed: $(cat "$TMP_DIR/out.log")"
[[ ! -s "$ssh_log" ]] || fail "a Linux-only filter reached the Mac: $(cat "$ssh_log")"
swift_tests | grep -q -- '--filter TextMergingAlgorithmsTests --filter localvoxtralCoreTests.DoubleMetaphoneTests/testSmith$' \
  || fail "the Linux run lost a filter: $(cat "$swift_log")"
grep -q '^==> Linux suites passed here: Executed 3 tests' "$TMP_DIR/out.log" \
  || fail "no Linux summary: $(cat "$TMP_DIR/out.log")"

# A Mac-only suite goes to the Mac alone.
run "$REMOTE_BUILD" test --filter AlphaTests || fail "a Mac-only run failed"
[[ -z "$(swift_tests)" ]] || fail "a Mac-only filter ran Linux tests: $(cat "$swift_log")"
mac_tests | grep -q -- '--filter AlphaTests *$' || fail "the Mac lost its filter: $(cat "$ssh_log")"

# So does anything that is not a plain suite name, or that a Mac-only class
# name contains.
run "$REMOTE_BUILD" test --filter 'Text.*Tests' || true
[[ -z "$(swift_tests)" ]] || fail "a regex filter ran on Linux"
run "$REMOTE_BUILD" test --filter localvoxtralTests.TextMergingAlgorithmsTests || true
[[ -z "$(swift_tests)" ]] || fail "a filter naming the app's module ran on Linux"

# Mixed: each side gets its own filters.
run "$REMOTE_BUILD" test --filter AlphaTests --filter=DoubleMetaphoneTests \
  || fail "a mixed run failed: $(cat "$TMP_DIR/out.log")"
swift_tests | grep -q -- '--filter DoubleMetaphoneTests$' || fail "Linux lost its filter: $(cat "$swift_log")"
mac_tests | grep -q -- '--filter AlphaTests *$' || fail "the Mac lost its filter: $(cat "$ssh_log")"
if mac_tests | grep -q DoubleMetaphone; then fail "the Mac also ran a Linux suite"; fi

# Any argument besides --filter keeps the whole run on the Mac.
run "$REMOTE_BUILD" test --filter DoubleMetaphoneTests --skip AlphaTests || true
[[ -z "$(swift_tests)" ]] || fail "a run with --skip ran on Linux"
mac_tests | grep -q -- '--filter DoubleMetaphoneTests --skip AlphaTests *$' \
  || fail "the Mac lost the arguments: $(cat "$ssh_log")"

# A plain run: the Linux part here, the rest on the Mac without it.
run LV_TEST_SHARDS=1 "$REMOTE_BUILD" test || fail "a plain run failed: $(cat "$TMP_DIR/out.log")"
[[ "$(swift_tests)" =~ ^test\ --skip-build\ --scratch-path\ [^\ ]+$ ]] \
  || fail "the Linux part must run every Linux suite: $(cat "$swift_log")"
for module in $modules; do
  mac_tests | grep -q -- "--skip $module " || fail "the Mac still runs $module: $(cat "$ssh_log")"
done

# A red Linux run fails the whole run even when the Mac is green.
if run LV_TEST_SHARDS=1 LV_TEST_LINUX_STATUS=1 "$REMOTE_BUILD" test; then
  fail "a red Linux run left the run green"
fi
grep -q '^==> Linux suites FAILED here (exit 1)' "$TMP_DIR/out.log" \
  || fail "a red Linux run must say so: $(cat "$TMP_DIR/out.log")"

# Every payload above is in the gate's own terms.
LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY=1
export LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY
# shellcheck source=../mac/localvoxtral-build-gate.sh
source "$GATE"
run LV_TEST_SHARDS=1 "$REMOTE_BUILD" test --filter AlphaTests --filter DoubleMetaphoneTests
cp "$ssh_log" "$TMP_DIR/payloads"
run LV_TEST_SHARDS=1 "$REMOTE_BUILD" test
cat "$ssh_log" >>"$TMP_DIR/payloads"
while IFS= read -r command; do
  [[ "$command" == cd\ * ]] || continue
  allow_build_payload "${command#cd work/localvoxtral-linux-routing-regression && }" \
    || fail "the build gate would refuse: $command"
done <"$TMP_DIR/payloads"

# Everything on the Mac, as before: on request, and on a Mac.
run LV_TEST_ON_MAC=1 "$REMOTE_BUILD" test --filter DoubleMetaphoneTests || true
[[ -z "$(swift_tests)" ]] || fail "LV_TEST_ON_MAC=1 still ran Linux tests"
mac_tests | grep -q DoubleMetaphoneTests || fail "LV_TEST_ON_MAC=1 did not reach the Mac"
run LV_TEST_UNAME=Darwin "$REMOTE_BUILD" test --filter DoubleMetaphoneTests || true
[[ -z "$(swift_tests)" ]] || fail "on a Mac the Linux routing must stay off"

printf 'PASS: remote-build runs the Linux suites here and the rest on the Mac\n'
