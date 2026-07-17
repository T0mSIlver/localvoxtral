#!/usr/bin/env bash
# Regression test: a failed/interrupted SSH payload requests one scoped reap,
# while a successful payload does not. All transport commands are stubbed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-reap-test.XXXXXX")"
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
  reap\ *)
    printf '%s\n' "$command" >>"$LV_TEST_REAP_LOG"
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
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

reap_log="$TMP_DIR/reap.log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-reap-regression"
  "LV_TEST_REAP_LOG=$reap_log"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
)

status=0
if env "${common_env[@]}" LV_TEST_PAYLOAD_RESULT=failure \
  "$REMOTE_BUILD" test --filter NoSuchTest >/dev/null 2>&1; then
  fail "failed payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "42" ]] || fail "payload exit status changed from 42 to $status"
[[ "$(cat "$reap_log")" == 'reap work/localvoxtral-reap-regression' ]] \
  || fail "failed payload did not request exactly its own workdir reap"

: >"$reap_log"
env "${common_env[@]}" LV_TEST_PAYLOAD_RESULT=success \
  "$REMOTE_BUILD" test --filter NoSuchTest >/dev/null
[[ ! -s "$reap_log" ]] || fail "successful payload unexpectedly requested a reap"

printf 'PASS: remote-build reaps one failed payload and leaves successful runs alone\n'
