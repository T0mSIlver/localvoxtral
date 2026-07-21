#!/usr/bin/env bash
# Regression test: every remote-build run fires one best-effort background
# `gc` at the gate (success AND failure — disk fills either way), without
# altering the payload's exit status, and the tree sync protects the gate's
# .lv-last-used stamp from rsync --delete. All transport commands are stubbed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-gc-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
command="$1"
case "$command" in
  mkdir\ -p\ *) exit 0 ;;
  gc)
    printf 'gc-requested\n' >>"$LV_TEST_GC_MARKER"
    exit 0
    ;;
  cd\ *)
    [[ "$LV_TEST_PAYLOAD_RESULT" == "success" ]] && exit 0
    exit 42
    ;;
  *) exit 0 ;;
esac
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$LV_TEST_RSYNC_LOG"
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

gc_marker="$TMP_DIR/gc.log"
rsync_log="$TMP_DIR/rsync.log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-gc-regression"
  "LV_TEST_GC_MARKER=$gc_marker"
  "LV_TEST_RSYNC_LOG=$rsync_log"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/last-gc.log"
)

# The gc ssh runs in a backgrounded subshell that outlives the script; poll
# briefly for its marker instead of assuming completion order.
await_gc_marker() {
  local poll=0
  while (( poll < 50 )); do
    [[ -s "$gc_marker" ]] && return 0
    sleep 0.1
    poll=$((poll + 1))
  done
  return 1
}

env "${common_env[@]}" LV_TEST_PAYLOAD_RESULT=success \
  "$REMOTE_BUILD" test --filter NoSuchTest >/dev/null
await_gc_marker || fail "successful run did not request a remote gc"

grep -qF -- '--filter=P /.lv-last-used' "$rsync_log" \
  || fail "tree sync does not protect the gate's last-used stamp from --delete"

: >"$gc_marker"
status=0
if env "${common_env[@]}" LV_TEST_PAYLOAD_RESULT=failure \
  "$REMOTE_BUILD" test --filter NoSuchTest >/dev/null 2>&1; then
  fail "failed payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "42" ]] || fail "payload exit status changed from 42 to $status"
await_gc_marker || fail "failed run did not request a remote gc"

printf 'PASS: remote-build fires one background gc per run and shields the stamp from --delete\n'
