#!/usr/bin/env bash
# Regression test: plain `remote-build.sh test` runs the unit suite in shards
# (#442). Every payload it sends must pass the real build gate's allowlist,
# the merged log must hold every shard, and a red shard reaps the work dir
# once, after all shards have ended. ssh and rsync are stubs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-shards-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
# Answers like the gate would run SwiftPM: a listing of three classes, and for
# each --filter one class's worth of XCTest output. LV_TEST_RED_CLASS makes
# the shard that runs that class exit 1.
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
command="$1"
printf '%s\n' "$command" >>"$LV_TEST_SSH_LOG"
case "$command" in
  reap\ *|gc|mkdir\ -p\ *) exit 0 ;;
  *"swift build --build-tests") echo "Build complete!"; exit 0 ;;
  *"swift test list --skip-build")
    printf '%s\n' localvoxtralTests.AlphaTests/testA localvoxtralTests.BetaTests/testB \
      localvoxtralTests.GammaTests/testC localvoxtralTests.HerdrIntegrationTests/testD
    exit 0
    ;;
esac
status=0 total=0
for word in $command; do
  case "$word" in
    localvoxtralTests.*/)
      class="${word#localvoxtralTests.}"
      class="${class%/}"
      echo "Test Suite '$class' passed at 2026-09-23 10:00:00.000."
      echo "	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
      total=$((total + 1))
      [[ "$class" == "${LV_TEST_RED_CLASS:-}" ]] && status=1
      ;;
  esac
done
echo "Test Suite 'Selected tests' passed at 2026-09-23 10:00:00.000."
echo "	 Executed $total tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
echo "shard ended" >>"$LV_TEST_SSH_LOG"
exit "$status"
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

ssh_log="$TMP_DIR/ssh.log"
remote_log="$TMP_DIR/remote.log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-shards-regression"
  "LV_TEST_SHARDS=2"
  "LV_TEST_SSH_LOG=$ssh_log"
  "LOCALVOXTRAL_REMOTE_LOG=$remote_log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/gc.log"
)

env "${common_env[@]}" "$REMOTE_BUILD" test >/dev/null 2>&1 \
  || fail "a green sharded run failed: $(cat "$remote_log")"
grep -q "^==> Unit shards: 3 of 3 tests ran in 2 shards" "$remote_log" \
  || fail "summary line missing: $(cat "$remote_log")"
for class in AlphaTests BetaTests GammaTests; do
  grep -q "Test Suite '$class'" "$remote_log" || fail "$class missing from the merged log"
done
if grep -q "HerdrIntegrationTests" "$remote_log"; then
  fail "a suite the unit lane skips got a shard"
fi
if grep -q "^reap " "$ssh_log"; then fail "a green run requested a reap"; fi

# Every payload in the gate's own terms.
LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY=1
export LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY
# shellcheck source=../mac/localvoxtral-build-gate.sh
source "$GATE"
payloads=0
while IFS= read -r command; do
  [[ "$command" == cd\ * ]] || continue
  [[ "$command" == "cd work/localvoxtral-shards-regression && "* ]] \
    || fail "payload outside the work dir: $command"
  allow_build_payload "${command#cd work/localvoxtral-shards-regression && }" \
    || fail "the build gate would refuse: $command"
  payloads=$((payloads + 1))
done <"$ssh_log"
# build, list, two shards
[[ "$payloads" == "4" ]] || fail "expected 4 payloads, sent $payloads: $(cat "$ssh_log")"

: >"$ssh_log"
if env "${common_env[@]}" LV_TEST_RED_CLASS=BetaTests "$REMOTE_BUILD" test >/dev/null 2>&1; then
  fail "a red shard left the run green"
fi
[[ "$(grep -c '^reap ' "$ssh_log")" == "1" ]] || fail "a red run must reap exactly once: $(cat "$ssh_log")"
reap_line="$(grep -n '^reap ' "$ssh_log" | cut -d: -f1)"
last_shard_end="$(grep -n '^shard ended$' "$ssh_log" | tail -n 1 | cut -d: -f1)"
(( reap_line > last_shard_end )) || fail "the reap came before every shard had ended: $(cat "$ssh_log")"

# Any extra argument keeps the one plain `swift test`.
: >"$ssh_log"
env "${common_env[@]}" "$REMOTE_BUILD" test --filter AlphaTests >/dev/null 2>&1 || true
grep -q "&& swift test --skip RealtimeAPIVLLMIntegrationTests .* --filter AlphaTests *$" "$ssh_log" \
  || fail "test with arguments must stay one swift test: $(cat "$ssh_log")"
if grep -q "swift build --build-tests" "$ssh_log"; then fail "test with arguments ran shards"; fi

printf 'PASS: remote-build runs the unit suite in gate-shaped shards\n'
