#!/usr/bin/env bash
# The lanes that borrow the owner's app on the GUI Mac used to back up the
# owner's `com.localvoxtral.app` defaults domain, force their own modes into
# it, and restore it on exit. They now run the app on a defaults suite of
# their own (#1029, #1450), but a lane killed in that old sequence (a
# torn-down runner, a sleeping Mac) left its backup on disk and its modes in
# the owner's domain, and the next lane must still put the owner's domain
# back. Before #991 the backup was a plist plus a separate "had domain"
# marker: a lane killed between the two left a plist with no marker.
#
# This drives the recovery in scripts/lib/owner-app-session.sh against a
# file-backed `defaults` stub that can SIGKILL the lane at a chosen step, and
# asserts the owner's domain comes out byte-identical. LV_OWNER_SESSION_LIB
# points it at another copy of the lib.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${LV_OWNER_SESSION_LIB:-$ROOT_DIR/scripts/lib/owner-app-session.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-owner-defaults-backup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

BIN="$WORK/bin"
mkdir -p "$BIN"

# STUB_KILL_AT_STEP=<n> SIGKILLs the lane before the n-th call to `defaults`
# or `rm` has done anything; $STEPS counts them.
cat >"$WORK/step.sh" <<'STUB'
if [ -n "$STUB_KILL_AT_STEP" ]; then
  n=$(($(cat "$STEPS" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$STEPS"
  if [ "$n" = "$STUB_KILL_AT_STEP" ]; then kill -KILL "$LANE_PID"; exit 137; fi
fi
STUB

# One file per domain under $DOMAINS. STUB_KILL_AT=delete SIGKILLs the lane
# (the stub's parent shell) before `delete` has done anything. Every call is
# logged.
cat >"$BIN/defaults" <<'STUB'
#!/bin/sh
echo "defaults $1" >>"$CALLS"
. "$STEP_LIB"
store="$DOMAINS/$2.plist"
case "$1" in
  import) cp "$3" "$store" ;;
  delete)
    [ "$STUB_KILL_AT" != delete ] || kill -KILL "$PPID"
    [ -f "$store" ] || exit 1
    rm -f "$store" ;;
esac
STUB
# `plutil -lint -s <file>`: a plist is anything that opens with a plist tag.
cat >"$BIN/plutil" <<'STUB'
#!/bin/sh
head -n 3 "$3" | grep -q '<plist'
STUB
# STUB_RM_FAIL=<path>: `rm` of that path fails and removes nothing.
cat >"$BIN/rm" <<STUB
#!/bin/sh
. "\$STEP_LIB"
for arg in "\$@"; do [ "\$arg" != "\$STUB_RM_FAIL" ] || exit 1; done
exec $(command -v rm) "\$@"
STUB
chmod +x "$BIN"/*

OWNER_PLIST='<plist version="1.0">
<dict><key>settings.dictation_backend_mode</key><string>the owner own mode</string></dict>
</plist>
'

export DOMAINS="$WORK/domains" CALLS="$WORK/calls" STEPS="$WORK/steps" STEP_LIB="$WORK/step.sh"
LIVE="$DOMAINS/com.localvoxtral.app.plist"
GOLDEN="$WORK/golden.plist"

fresh_account() {
  rm -rf "$WORK/home" "$DOMAINS"
  mkdir -p "$WORK/home" "$DOMAINS"
  : >"$CALLS"
  if [[ "${1:-present}" == present ]]; then
    printf '%s' "$OWNER_PLIST" >"$LIVE"
    cp "$LIVE" "$GOLDEN"
  fi
}

# A backup as the old lanes wrote it, at ~/.localvoxtral-<lane>.defaults-backup.
# write_backup <lane> <present|absent>: of the current live domain.
write_backup() {
  local backup="$WORK/home/.localvoxtral-$1.defaults-backup" payload="$WORK/payload"
  if [[ "$2" == present ]]; then cp "$LIVE" "$payload"; else : >"$payload"; fi
  {
    printf 'localvoxtral defaults backup v1\n'
    printf 'domain=%s\n' "$2"
    printf 'cksum=%s\n' "$(cksum <"$payload" | awk '{ print $1 " " $2 }')"
    printf -- '--\n'
    cat "$payload"
  } >"$backup"
  rm -f "$payload"
}

# The modes a killed lane left in the owner's domain.
force_live() {
  printf '<plist version="1.0">\n<!-- forced external_url -->\n' >"$LIVE"
}

# lane: one lane process recovering, the way every lane starts. Prints its
# exit status; 137 is the stub's SIGKILL.
lane() {
  local status=0
  HOME="$WORK/home" PATH="${LANE_PATH:-$BIN:$PATH}" bash -c '
    set -uo pipefail
    BUNDLE_ID="${LANE_BUNDLE_ID:-com.localvoxtral.app}"
    record_fail() { echo "record_fail: $*" >&2; }
    export LANE_PID=$$
    source "$1"
    recover_previous_defaults_backup || exit 11
  ' lane "$LIB" >>"$WORK/lane.out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

assert_live_is_golden() {
  cmp -s "$GOLDEN" "$LIVE" || fail "$1: the owner's domain is not byte-identical:
$(cat "$LIVE" 2>&1)
--- lane output:
$(cat "$WORK/lane.out")"
}

assert_no_leftovers() {
  local left
  left="$(cd "$WORK/home" && ls -A)"
  [[ -z "$left" ]] || fail "$1: files left in HOME: $left"
}

# 1. A lane killed with its modes forced: the next lane restores the owner's
#    domain, and a lane killed mid-restore is finished by the one after it.
fresh_account
write_backup ui-smoke present
force_live
touch "$WORK/home/.localvoxtral-ui-smoke.defaults-backup.staged.abc123"
[[ "$(STUB_KILL_AT=delete lane)" == 137 ]] || fail "the delete kill did not fire"
[[ "$(lane)" == 0 ]] || fail "recovery after a kill mid-restore failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after a lane killed mid-restore"
assert_no_leftovers "after a lane killed mid-restore"
pass "a lane killed with its modes forced, or mid-restore, is restored by the next lane"

# 2. capture-readme-assets and record-demo kept backups on paths of their own.
for old_lane in capture-assets record-demo; do
  fresh_account
  write_backup "$old_lane" present
  force_live
  [[ "$(lane)" == 0 ]] || fail "recovering the $old_lane backup failed: $(cat "$WORK/lane.out")"
  assert_live_is_golden "after recovering the $old_lane backup"
  assert_no_leftovers "after recovering the $old_lane backup"
done
pass "the backups capture-readme-assets and record-demo left are restored too"

# 2b. Two killed runs on different paths: the later one may have backed up
#     the earlier one's forced modes, so only the oldest backup is restored
#     and the other is dropped.
fresh_account
write_backup ui-smoke present
touch -t 202609010000 "$WORK/home/.localvoxtral-ui-smoke.defaults-backup"
force_live
write_backup capture-assets present
force_live
[[ "$(lane)" == 0 ]] || fail "recovering two backups failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after recovering two backups"
assert_no_leftovers "after recovering two backups"
pass "with two backups on disk, the oldest is restored and the other dropped"

# 2c. A recovery killed before any one of its steps leaves the oldest backup
#     on disk, so the next lane restores the owner's domain from it, never
#     from the forced modes in a newer backup. The oldest is a current backup,
#     then a pre-#991 one.
two_backups() {
  fresh_account
  if [[ "$1" == legacy ]]; then
    cp "$GOLDEN" "$WORK/home/.localvoxtral-ui-smoke.pre.plist"
    touch "$WORK/home/.localvoxtral-ui-smoke.pre.plist.had-domain"
    touch -t 202609010000 "$WORK/home/.localvoxtral-ui-smoke.pre.plist"
  else
    write_backup ui-smoke present
    touch -t 202609010000 "$WORK/home/.localvoxtral-ui-smoke.defaults-backup"
  fi
  force_live
  write_backup capture-assets present
  force_live
}
for oldest_kind in current legacy; do
  step=1
  while :; do
    two_backups "$oldest_kind"
    rm -f "$STEPS"
    status="$(STUB_KILL_AT_STEP=$step lane)"
    [[ "$status" == 0 ]] && break
    [[ "$status" == 137 ]] || fail "$oldest_kind: recovery killed at step $step exited $status: $(cat "$WORK/lane.out")"
    [[ "$(lane)" == 0 ]] || fail "$oldest_kind: recovery after a kill at step $step failed: $(cat "$WORK/lane.out")"
    assert_live_is_golden "$oldest_kind: after a recovery killed at step $step"
    assert_no_leftovers "$oldest_kind: after a recovery killed at step $step"
    step=$((step + 1))
    ((step < 100)) || fail "$oldest_kind: recovery never finished without a kill"
  done
  ((step > 3)) || fail "$oldest_kind: recovery ran only $((step - 1)) steps; the kill counter is not seeing them"
  assert_live_is_golden "$oldest_kind: after an unkilled recovery"
  assert_no_leftovers "$oldest_kind: after an unkilled recovery"
done
pass "a recovery killed before any of its steps is finished from the oldest backup"

# 2d. A newer backup that cannot be removed fails the lane and keeps the
#     oldest, so the next recovery still restores from it.
two_backups current
newer="$WORK/home/.localvoxtral-capture-assets.defaults-backup"
[[ "$(STUB_RM_FAIL="$newer" lane)" == 11 ]] || fail "recovery passed with a backup it could not remove"
[[ -f "$WORK/home/.localvoxtral-ui-smoke.defaults-backup" ]] || fail "the oldest backup was removed while a newer one remained"
[[ "$(lane)" == 0 ]] || fail "recovery after a failed removal failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after a failed removal"
assert_no_leftovers "after a failed removal"
pass "a backup recovery cannot remove fails the lane and keeps the oldest"

# 3. A damaged backup stops recovery before the live domain is deleted.
fresh_account
write_backup ui-smoke present
force_live
backup="$WORK/home/.localvoxtral-ui-smoke.defaults-backup"
forced="$WORK/forced.plist"
cp "$LIVE" "$forced"
printf 'garbage' >>"$backup"
: >"$CALLS"
[[ "$(lane)" == 11 ]] || fail "recovery from a damaged backup did not fail"
grep -q "defaults delete" "$CALLS" && fail "recovery deleted the live domain before the backup validated"
cmp -s "$forced" "$LIVE" || fail "recovery from a damaged backup changed the live domain"
[[ -f "$backup" ]] || fail "recovery from a damaged backup removed the backup"
pass "a damaged backup stops recovery with the live domain and the backup untouched"

# 4. An absent domain comes back absent.
fresh_account absent
write_backup ui-smoke absent
force_live
[[ "$(lane)" == 0 ]] || fail "recovering an absent domain failed: $(cat "$WORK/lane.out")"
[[ ! -e "$LIVE" ]] || fail "a domain that did not exist before the lane exists after it"
assert_no_leftovers "after recovering an absent domain"
pass "an absent domain is restored as absent"

# 5. A pre-#991 lane killed between its export and its marker left a plist
#    with no marker. Recovery must import it, not delete the domain.
fresh_account
cp "$GOLDEN" "$WORK/home/.localvoxtral-ui-smoke.pre.plist"
force_live
[[ "$(lane)" == 0 ]] || fail "recovering a legacy backup failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after recovering a legacy backup without its marker"
assert_no_leftovers "after recovering a legacy backup"
pass "a legacy backup whose marker was never written is imported, not discarded"

# 6. No backup: recovery touches nothing.
fresh_account
: >"$CALLS"
[[ "$(lane)" == 0 ]] || fail "recovery with no backup failed: $(cat "$WORK/lane.out")"
[[ ! -s "$CALLS" ]] || fail "recovery with no backup called defaults: $(cat "$CALLS")"
assert_live_is_golden "after recovery with no backup"
pass "with no backup on disk, recovery leaves the owner's domain alone"

# 7. On macOS, the same recovery against the real `defaults` and `plutil`, on
#    a throwaway domain: the stubs above encode two facts about them (the
#    domain `defaults import` writes, and `plutil -lint -s`).
if [[ "$(uname)" == Darwin ]]; then
  export LANE_PATH="$PATH" LANE_BUNDLE_ID="com.localvoxtral.test-owner-defaults-backup.$$"
  trap '/usr/bin/defaults delete "$LANE_BUNDLE_ID" >/dev/null 2>&1 || :; rm -rf "$WORK"' EXIT
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
  /usr/bin/defaults write "$LANE_BUNDLE_ID" settings.dictation_backend_mode -string "the owner own mode"
  /usr/bin/defaults export "$LANE_BUNDLE_ID" "$WORK/real-golden.plist"
  LIVE="$WORK/real-golden.plist" write_backup ui-smoke present
  /usr/bin/defaults write "$LANE_BUNDLE_ID" settings.dictation_backend_mode -string external_url
  [[ "$(lane)" == 0 ]] || fail "real defaults: recovery failed: $(cat "$WORK/lane.out")"
  /usr/bin/defaults export "$LANE_BUNDLE_ID" "$WORK/real-after.plist"
  cmp -s "$WORK/real-golden.plist" "$WORK/real-after.plist" \
    || fail "real defaults: the domain is not byte-identical after recovery:
$(cat "$WORK/real-after.plist")"
  [[ -z "$(ls -A "$WORK/home")" ]] || fail "real defaults: files left in HOME: $(ls -A "$WORK/home")"
  pass "real defaults and plutil: a recovered domain comes back byte-identical"
fi

echo "owner defaults backup tests passed"
