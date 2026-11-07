#!/bin/bash
# Regression test for the widget sandbox check at the end of
# scripts/packaging/sign-bundle.sh (#1952). codesign and file are stubs on
# PATH, so it runs on Linux and macOS alike; /bin/bash, like the script.
#
# What it pins:
#   - an extension signed with the sandbox entitlement passes, also when
#     codesign keeps writing after the key (the SIGPIPE that grep -q caused
#     under pipefail) and when it prints the entitlements and exits non-zero
#   - an extension without the entitlement still fails, and the failure
#     shows what codesign printed and its stderr
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/packaging/sign-bundle.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-sign-bundle-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
printf 'bash %s\n' "$BASH_VERSION"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

STUBS="$TMP_DIR/bin"
mkdir -p "$STUBS"
# `codesign -d --entitlements - <path>` prints $FAKE_ENTITLEMENTS, then
# $FAKE_TAIL_LINES more lines (enough to fill a pipe), writes $FAKE_STDERR to
# stderr and exits $FAKE_D_EXIT. Signing and --verify succeed.
cat >"$STUBS/codesign" <<'STUB'
#!/bin/bash
if [[ "$1" == "-d" ]]; then
  printf '%s\n' "$FAKE_ENTITLEMENTS"
  i=0
  while [[ $i -lt ${FAKE_TAIL_LINES:-0} ]]; do
    echo "[Key] com.example.filler.$i"
    i=$((i + 1))
  done
  printf '%s\n' "${FAKE_STDERR:-}" >&2
  exit "${FAKE_D_EXIT:-0}"
fi
exit 0
STUB
printf '#!/bin/sh\necho data\n' >"$STUBS/file"
chmod +x "$STUBS/codesign" "$STUBS/file"

APP="$TMP_DIR/localvoxtral.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns/localvoxtralWidgets.appex/Contents/MacOS"

SANDBOXED='[Dict]
	[Key] com.apple.security.app-sandbox
	[Value]
		[Bool] true'
UNSANDBOXED='[Dict]
	[Key] com.apple.security.application-groups'

# run <entitlements> <tail-lines> <d-exit> [stderr]: the script's exit status;
# its stderr is in $TMP_DIR/err.
run() {
  local status=0
  FAKE_ENTITLEMENTS="$1" FAKE_TAIL_LINES="$2" FAKE_D_EXIT="$3" FAKE_STDERR="${4:-}" \
    PATH="$STUBS:$PATH" "$SCRIPT" "$APP" - >/dev/null 2>"$TMP_DIR/err" || status=$?
  echo "$status"
}

[[ "$(run "$SANDBOXED" 0 0)" == 0 ]] || fail "a sandboxed extension fails the check: $(cat "$TMP_DIR/err")"
[[ "$(run "$SANDBOXED" 20000 0)" == 0 ]] \
  || fail "output after the key fails the check (SIGPIPE): $(cat "$TMP_DIR/err")"
[[ "$(run "$SANDBOXED" 0 1)" == 0 ]] \
  || fail "a non-zero codesign exit after printing the key fails the check: $(cat "$TMP_DIR/err")"

[[ "$(run "$UNSANDBOXED" 0 0 'codesign-stderr-line')" == 1 ]] || fail "a missing entitlement passes the check"
grep -q 'lost its sandbox entitlement' "$TMP_DIR/err" || fail "the failure does not say what is wrong"
grep -q 'com.apple.security.application-groups' "$TMP_DIR/err" || fail "the failure does not show codesign's output"
grep -q 'codesign-stderr-line' "$TMP_DIR/err" || fail "the failure does not show codesign's stderr"
[[ "$(run '' 0 1 'no signature')" == 1 ]] || fail "a codesign that prints nothing passes the check"

echo "sign-bundle sandbox check: ok"
