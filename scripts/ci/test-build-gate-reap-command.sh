#!/usr/bin/env bash
# Security regression tests for the forced-command gate's scoped reap verb.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-gate-reap-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/home/bin"
reaper_log="$TMP_DIR/reaper.log"
cat >"$TMP_DIR/home/bin/localvoxtral-cleanup-stale-test-processes.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$LV_REAPER_LOG"
STUB
chmod +x "$TMP_DIR/home/bin/localvoxtral-cleanup-stale-test-processes.sh"

HOME="$TMP_DIR/home" LV_REAPER_LOG="$reaper_log" \
  SSH_ORIGINAL_COMMAND='reap work/localvoxtral-safe-123' bash "$GATE"
expected="$TMP_DIR/home/work/localvoxtral-safe-123"
actual="$(cat "$reaper_log")"
[[ "$actual" == "$expected" ]] \
  || fail "valid reap root was '$actual', expected '$expected'"

assert_denied() {
  local command="$1" status=0
  if HOME="$TMP_DIR/home" LV_REAPER_LOG="$reaper_log" \
    SSH_ORIGINAL_COMMAND="$command" bash "$GATE" >/dev/null 2>&1; then
    fail "unsafe command was accepted: $command"
  else
    status=$?
  fi
  [[ "$status" == "126" ]] \
    || fail "unsafe command '$command' exited $status instead of 126"
}

assert_denied 'reap'
assert_denied 'reap ../../etc'
assert_denied 'reap work/localvoxtral-safe-123 extra'
assert_denied 'reap work/not-localvoxtral'
assert_denied 'reap work/localvoxtral-safe-123;id'

printf 'PASS: gate accepts one validated workdir and denies unsafe reap commands\n'
