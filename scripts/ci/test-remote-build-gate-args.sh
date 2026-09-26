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
# A run holding LV_TEST_HOLD_GC parks its background `gc` until the test
# writes to the gc-go FIFO, then reports on gc-done once the line is logged.
# That lets the test replay #679's interleaving on purpose: the gc of one run
# logs while a later run is being checked.
for tool in ssh rsync; do
  cat >"$TMP_DIR/bin/$tool" <<STUB
#!/usr/bin/env bash
held=""
if [[ "\${!#}" == gc && -n "\${LV_TEST_HOLD_GC:-}" ]]; then
  held=1
  read -r _ <"\$LV_TEST_HOLD_GC/gc-go"
fi
printf '$tool %s\n' "\$*" >>"\$LV_TEST_TRANSPORT_LOG"
[[ -z "\$held" ]] || echo logged >"\$LV_TEST_HOLD_GC/gc-done"
exit 0
STUB
  chmod +x "$TMP_DIR/bin/$tool"
done
# Held open read-write so neither side of a FIFO blocks on open, only on read.
mkfifo "$TMP_DIR/gc-go" "$TMP_DIR/gc-done"
exec 3<>"$TMP_DIR/gc-go" 4<>"$TMP_DIR/gc-done"

# Every remote-build.sh run that reaches its end leaves a backgrounded
# `ssh … gc` behind, which can log after the run exits (#679). A check that
# starts a fresh log per run therefore reads only that run's transport; a gc
# from an earlier run lands in the earlier run's file.
transport_runs=0
new_transport_log() {
  transport_runs=$((transport_runs + 1))
  transport_log="$TMP_DIR/transport.$transport_runs.log"
  : >"$transport_log"
}
new_transport_log
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  # The Mac path; test-remote-build-linux-routing.sh covers the Linux one.
  "LV_TEST_ON_MAC=1"
  # The argument cases below include an unfiltered `test`; the opt-in cases
  # at the end (#617) override this.
  "LV_ALLOW_HEAVY_MAC_RUN=1"
  "LV_BUILD_DIR=work/localvoxtral-gate-args-regression"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/last-gc.log"
)

# $1 = description, $2 = expected exit status, rest = remote-build.sh arguments.
# extra_env, when set, is appended to the environment of the next call.
extra_env=()
run_remote_build() {
  local description="$1" expected="$2" status=0
  shift 2
  env "${common_env[@]}" "LV_TEST_TRANSPORT_LOG=$transport_log" \
    ${extra_env[@]+"${extra_env[@]}"} "$REMOTE_BUILD" "$@" \
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
# Its background gc is held (see the stubs) until a later run has been checked.
extra_env=("LV_TEST_HOLD_GC=$TMP_DIR")
run_remote_build 'clean --filter' 0 test --filter TextMergingAlgorithmsTests
extra_env=()
clean_run_log="$transport_log"
grep -q '^rsync ' "$transport_log" || fail "clean run never synced the tree"
grep -q 'swift test' "$transport_log" || fail "clean run never sent its payload"

# Commands whose arguments are not shell payloads keep their own validation.
run_remote_build 'diag rejects arguments' 1 diag extra
assert_stderr_has 'does not accept extra arguments'

# #617: the full suite and the live lanes and evals need the opt-in; they
# refuse before any sync, naming the way out.
assert_no_transport() {
  [[ ! -s "$transport_log" ]] \
    || fail "$1 still reached the host: $(cat "$transport_log")"
}
without_opt_in() {
  local description="$1" expected="$2" status=0
  shift 2
  new_transport_log
  env "${common_env[@]}" "LV_TEST_TRANSPORT_LOG=$transport_log" LV_ALLOW_HEAVY_MAC_RUN=0 \
    "$REMOTE_BUILD" "$@" \
    >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || status=$?
  [[ "$status" == "$expected" ]] \
    || fail "$description: exit $status, expected $expected: $(cat "$TMP_DIR/stderr")"
}

without_opt_in 'bare invocation' 2
assert_stderr_has 'test --filter <Suite>'
assert_stderr_has 'LV_ALLOW_HEAVY_MAC_RUN=1'
# #679: the clean run's gc logs only now, after this refused run started. It
# must not count as this run's transport. The read's timeout is a hang guard
# for a remote-build.sh that stops running gc, not a wait for timing.
echo go >&3
read -t 60 -r _ <&4 || fail "the clean run's background gc never reached the host"
grep -q ' gc$' "$clean_run_log" || fail "the clean run's gc was not logged as that run's"
assert_no_transport 'a bare invocation'
for args in 'test' 'test --skip AlphaTests'; do
  # shellcheck disable=SC2086
  without_opt_in "$args" 2 $args
  assert_stderr_has "hosted build-test already runs it"
  assert_no_transport "$args"
done
for command in integration integration-keychain integration-mistral \
  integration-polishd integration-speechd integration-herdr eval-llm eval-e2e \
  eval-term-recall speechd-bench polishd-bench; do
  without_opt_in "$command" 2 "$command"
  assert_stderr_has "$command runs live inference"
  assert_stderr_has 'AGENTS.md'
  assert_stderr_has "LV_ALLOW_HEAVY_MAC_RUN=1"
  assert_no_transport "$command"
done

# Scoped and light runs need no opt-in.
for args in 'test --filter AlphaTests' 'test --filter=AlphaTests' \
  'test --package-path SpeechHelper' 'build' 'package' 'exec true'; do
  # shellcheck disable=SC2086
  without_opt_in "$args" 0 $args
  grep -q '^ssh ' "$transport_log" || fail "$args never reached the host"
done
for command in diag disk svc-status; do
  without_opt_in "$command" 0 "$command"
  grep -q "^ssh .*$command" "$transport_log" || fail "$command never reached the host"
done

# The opt-in lets them through.
new_transport_log
env "${common_env[@]}" "LV_TEST_TRANSPORT_LOG=$transport_log" LV_TEST_SHARDS=1 "$REMOTE_BUILD" test >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || true
grep -q 'swift test' "$transport_log" || fail "an opted-in plain test never ran: $(cat "$TMP_DIR/stderr")"
new_transport_log
env "${common_env[@]}" "LV_TEST_TRANSPORT_LOG=$transport_log" "$REMOTE_BUILD" integration >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || true
grep -q 'swift test' "$transport_log" || fail "an opted-in integration never ran: $(cat "$TMP_DIR/stderr")"
if grep -q 'runs live inference' "$TMP_DIR/stderr"; then
  fail "an opted-in integration was refused"
fi

printf 'PASS: remote-build refuses gate-blocked arguments before the tree sync\n'
printf 'PASS: the full suite and the live lanes need LV_ALLOW_HEAVY_MAC_RUN=1\n'
