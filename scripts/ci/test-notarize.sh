#!/usr/bin/env bash
# Tests notarize.sh's argument checks and its verdicts with a stub xcrun on
# PATH: no Apple account or Mac needed, runs on Linux.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/ci/notarize.sh"
ID="8f0d8ed8-6aca-405e-ba51-60680f29ccbf"
KC="/test/notary.keychain-db"
INFO_CMD="xcrun notarytool info $ID --keychain-profile test-profile --keychain $KC"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-notarize-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
CALLS="$TMP_DIR/calls"
cat >"$TMP_DIR/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# Stub xcrun: logs each call, then answers `notarytool <verb>` with
# $STUB_<VERB>_OUT on stdout and exits $STUB_<VERB>_RC (default 0).
printf '%s\n' "$*" >>"$STUB_CALLS"
verb="$(tr '[:lower:]' '[:upper:]' <<<"$2")"
out="STUB_${verb}_OUT"
rc="STUB_${verb}_RC"
printf '%s\n' "${!out:-}"
exit "${!rc:-0}"
STUB
chmod +x "$TMP_DIR/bin/xcrun"

SUBMITTED="{\"id\":\"$ID\",\"message\":\"Successfully uploaded file\"}"
status_json() { printf '{"id":"%s","status":"%s"}' "$ID" "$1"; }

# run <expected exit> <description> [env overrides...] -- [args...]
# Leaves stdout+stderr in $OUTPUT and the xcrun calls in $CALLS.
run() {
  local expected="$1" description="$2"
  shift 2
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  : >"$CALLS"
  local rc=0
  OUTPUT="$(env -u NOTARIZE_TIMEOUT "NOTARY_KEYCHAIN=$KC" "PATH=$TMP_DIR/bin:$PATH" "STUB_CALLS=$CALLS" \
    ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" 2>&1)" || rc=$?
  [[ "$rc" == "$expected" ]] \
    || fail "$description: expected exit $expected, got $rc. Output: $OUTPUT"
  DESCRIPTION="$description"
}
contains() {
  grep -qF -- "$1" <<<"$OUTPUT" || fail "$DESCRIPTION: output lacks '$1'. Output: $OUTPUT"
}
called() {
  grep -qF -- "$1" "$CALLS" || fail "$DESCRIPTION: xcrun was not called with '$1'. Calls: $(cat "$CALLS")"
}
not_called() {
  ! grep -qF -- "$1" "$CALLS" || fail "$DESCRIPTION: xcrun was called with '$1'. Calls: $(cat "$CALLS")"
}
# A profile read without --keychain comes from the data-protection keychain,
# which is unreadable while the screen is locked (run 37111344554).
every_call_names_keychain() {
  local line
  while IFS= read -r line; do
    [[ "$line" == *"--keychain-profile test-profile --keychain $KC"* ]] \
      || fail "$DESCRIPTION: a notarytool call lacks --keychain $KC: $line"
  done <"$CALLS"
}
pass() { printf 'PASS: %s\n' "$DESCRIPTION"; }

run 2 "one argument is a usage error" -- app.zip
contains "usage:"
[[ ! -s "$CALLS" ]] || fail "$DESCRIPTION: xcrun was called"
pass

for bad in 0 3x 1.5h "3 h"; do
  run 2 "NOTARIZE_TIMEOUT='$bad' is refused before submitting" "NOTARIZE_TIMEOUT=$bad" -- app.zip test-profile
  contains "NOTARIZE_TIMEOUT must be"
  [[ ! -s "$CALLS" ]] || fail "$DESCRIPTION: xcrun was called"
  pass
done

run 0 "Accepted exits 0 after a default 3h wait" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=$(status_json Accepted)" -- app.zip test-profile
contains "Follow it with: $INFO_CMD"
contains "Submission $ID: Accepted"
called "notarytool submit app.zip --keychain-profile test-profile --keychain $KC --output-format json"
not_called "--wait"
called "notarytool wait $ID --keychain-profile test-profile --keychain $KC --timeout 3h"
not_called "notarytool log"
# The id must be out before the wait starts, so a stuck run can be followed.
[[ "$(grep -n 'Follow it with' <<<"$OUTPUT" | cut -d: -f1)" -lt \
   "$(grep -n "Submission $ID: Accepted" <<<"$OUTPUT" | cut -d: -f1)" ]] \
  || fail "$DESCRIPTION: the id was not printed before the verdict"
pass

run 0 "NOTARIZE_TIMEOUT reaches the wait" "NOTARIZE_TIMEOUT=1h" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=$(status_json Accepted)" -- app.dmg test-profile
called "--timeout 1h"
pass

# What the first rehearsal (run 37070780672) got from notarytool: no JSON, a
# non-zero exit, and Apple still processing.
run 1 "a timed-out wait fails with the id and the info command" \
  "STUB_SUBMIT_OUT=$SUBMITTED" \
  "STUB_WAIT_OUT=Timeout of 10800 second(s) was reached before processing completed." "STUB_WAIT_RC=1" \
  "STUB_INFO_OUT=$(status_json 'In Progress')" -- app.zip test-profile
contains "::error::Apple did not finish notarizing app.zip within 3h"
contains "Submission $ID is still In Progress; follow it with: $INFO_CMD"
called "notarytool info $ID"
not_called "notarytool log"
every_call_names_keychain
pass

run 1 "a wait that returns In Progress fails as a timeout" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=$(status_json 'In Progress')" \
  "STUB_INFO_OUT=$(status_json 'In Progress')" -- app.zip test-profile
contains "still In Progress; follow it with: $INFO_CMD"
pass

run 0 "a wait that fails but whose submission was accepted exits 0" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=network error" "STUB_WAIT_RC=1" \
  "STUB_INFO_OUT=$(status_json Accepted)" -- app.zip test-profile
contains "Submission $ID: Accepted"
pass

run 1 "Invalid prints Apple's log" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=$(status_json Invalid)" \
  "STUB_LOG_OUT=The binary is not signed." -- app.zip test-profile
contains "Submission $ID: Invalid"
contains "The binary is not signed."
every_call_names_keychain
called "notarytool log $ID --keychain-profile test-profile --keychain $KC"
not_called "notarytool info"
pass

run 1 "an unreadable status fails with the info command" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_RC=1" "STUB_INFO_RC=1" -- app.zip test-profile
contains "::error::Could not read the status of submission $ID"
contains "$INFO_CMD"
pass

run 1 "a submit with no id fails before waiting" \
  "STUB_SUBMIT_OUT=Error: HTTP status code: 401" "STUB_SUBMIT_RC=1" -- app.zip test-profile
contains "returned no submission id"
contains "HTTP status code: 401"
not_called "notarytool wait"
pass

run 0 "the profile is read from the login keychain file by default" \
  "NOTARY_KEYCHAIN=" "HOME=/Users/runner" \
  "STUB_SUBMIT_OUT=$SUBMITTED" "STUB_WAIT_OUT=$(status_json Accepted)" -- app.zip test-profile
called "notarytool submit app.zip --keychain-profile test-profile --keychain /Users/runner/Library/Keychains/login.keychain-db"
called "notarytool wait $ID --keychain-profile test-profile --keychain /Users/runner/Library/Keychains/login.keychain-db"
pass

echo "notarize tests passed"
