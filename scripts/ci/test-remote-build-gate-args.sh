#!/usr/bin/env bash
# Regression test (#431): remote-build.sh refuses an argument the build host's
# SSH gate would deny — before the rsync, naming the character and, for `|`,
# the one-filter-per-suite workaround. Eight sessions between 2026-07-05 and
# 2026-09-21 spent a full tree sync discovering that by hand, because the gate
# writes its reason only to a log on the Mac.
#
# ssh and rsync are stubbed to log every call: the point of the guard is that
# neither runs at all.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-gate-args-test.XXXXXX")"
# remote-build.sh's background GC can still be writing here as this script
# exits: retry the removal rather than fail the suite on its own cleanup.
trap 'for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
for tool in ssh rsync; do
  cat >"$TMP_DIR/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$LV_TEST_TRANSPORT_LOG"
exit 0
STUB
  chmod +x "$TMP_DIR/bin/$tool"
done

transport_log="$TMP_DIR/transport.log"
: >"$transport_log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  # The Mac path; test-remote-build-linux-routing.sh covers the Linux one.
  "LV_TEST_ON_MAC=1"
  "LV_BUILD_DIR=work/localvoxtral-gate-args-regression"
  "LV_TEST_TRANSPORT_LOG=$transport_log"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/last-gc.log"
)

# $1 = description, $2 = expected exit status, rest = remote-build.sh arguments.
run_remote_build() {
  local description="$1" expected="$2" status=0
  shift 2
  env "${common_env[@]}" "$REMOTE_BUILD" "$@" \
    >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || status=$?
  [[ "$status" == "$expected" ]] \
    || fail "$description: exit $status, expected $expected"
}

assert_stderr_has() {
  grep -qF -- "$1" "$TMP_DIR/stderr" \
    || fail "refusal never says \"$1\"; it said: $(cat "$TMP_DIR/stderr")"
}

# The reported case: one --filter carrying an alternation.
run_remote_build 'piped --filter' 1 test --filter 'TextMergingAlgorithmsTests|OverlayBufferTests'
assert_stderr_has "'|'"
assert_stderr_has '--filter SuiteA --filter SuiteB'
[[ ! -s "$transport_log" ]] \
  || fail "refused run still reached the host: $(cat "$transport_log")"

# Every argument-taking command that ends up inside a gated payload.
for command in build test exec; do
  run_remote_build "$command with a metacharacter" 1 "$command" 'swift build $(id)'
  assert_stderr_has "'\$'"
done
[[ ! -s "$transport_log" ]] \
  || fail "refused run still reached the host: $(cat "$transport_log")"

# Whitespace survives the raw argument but not `printf %q`, which is what the
# gate actually inspects.
run_remote_build 'argument with a space' 1 test --filter 'Suite One'
assert_stderr_has 'quoting it for transport produces'
[[ ! -s "$transport_log" ]] \
  || fail "refused run still reached the host: $(cat "$transport_log")"

# The guard is not a filter on the rest: a clean run still syncs and runs.
run_remote_build 'clean --filter' 0 test --filter TextMergingAlgorithmsTests
grep -q '^rsync ' "$transport_log" || fail "clean run never synced the tree"
grep -q 'swift test' "$transport_log" || fail "clean run never sent its payload"

# Commands whose arguments are not shell payloads keep their own validation.
run_remote_build 'diag rejects arguments' 1 diag extra
assert_stderr_has 'does not accept extra arguments'

printf 'PASS: remote-build refuses gate-blocked arguments before the tree sync\n'
