#!/usr/bin/env bash
# The UI Smoke and e2e lanes back up the owner's `com.localvoxtral.app`
# defaults domain, force their own modes into it, and restore it on exit. A
# lane can be SIGKILLed anywhere in that sequence (a torn-down runner, a
# sleeping Mac), and the next lane must then put the owner's domain back
# before it takes a backup of its own. Before #991 the backup was a plist plus
# a separate "had domain" marker: a lane killed between the two left a plist
# with no marker, and the next lane's recovery deleted the live domain and
# threw the plist away.
#
# This drives scripts/lib/owner-app-session.sh against a file-backed
# `defaults` stub that can SIGKILL the lane at a chosen step, and asserts the
# owner's domain comes out byte-identical. LV_OWNER_SESSION_LIB points it at
# another copy of the lib, which is how the pre-fix failure was shown.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${LV_OWNER_SESSION_LIB:-$ROOT_DIR/scripts/lib/owner-app-session.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-owner-defaults-backup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

BIN="$WORK/bin"
mkdir -p "$BIN"

# One file per domain under $DOMAINS. STUB_KILL_AT=<verb> SIGKILLs the lane
# (the stub's parent shell) when that verb runs: after `export` has written
# its file, before `delete` or `mv` has done anything. Every call is logged.
cat >"$BIN/defaults" <<'STUB'
#!/bin/sh
echo "defaults $1" >>"$CALLS"
store="$DOMAINS/$2.plist"
case "$1" in
  read)
    [ -f "$store" ] || { echo "Domain $2 does not exist" >&2; exit 1; }
    [ -z "$STUB_READ_ERROR" ] || { echo "$STUB_READ_ERROR" >&2; exit 1; }
    cat "$store" ;;
  export)
    cp "$store" "$3" || exit 1
    [ "$STUB_KILL_AT" != export ] || kill -KILL "$PPID" ;;
  import) cp "$3" "$store" ;;
  delete)
    [ "$STUB_KILL_AT" != delete ] || kill -KILL "$PPID"
    [ -f "$store" ] || exit 1
    rm -f "$store" ;;
  write)
    [ -f "$store" ] || printf '<plist version="1.0">\n' >"$store"
    printf '<!-- forced %s -->\n' "$3" >>"$store" ;;
esac
STUB
# `plutil -lint -s <file>`: a plist is anything that opens with a plist tag.
cat >"$BIN/plutil" <<'STUB'
#!/bin/sh
head -n 3 "$3" | grep -q '<plist'
STUB
cat >"$BIN/mv" <<'STUB'
#!/bin/sh
[ "$STUB_KILL_AT" != mv ] || kill -KILL "$PPID"
exec /bin/mv "$@"
STUB
chmod +x "$BIN"/*

OWNER_PLIST='<plist version="1.0">
<dict><key>settings.dictation_backend_mode</key><string>the owner own mode</string></dict>
</plist>
'

export DOMAINS="$WORK/domains" CALLS="$WORK/calls"
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

# lane [recover|snapshot|force|restore]...: one lane process running the
# given steps in order, the way ui-smoke.sh and e2e-dictation.sh do. Prints
# the lane's exit status; 137 is the stub's SIGKILL.
lane() {
  local status=0
  HOME="$WORK/home" PATH="${LANE_PATH:-$BIN:$PATH}" bash -c '
    set -uo pipefail
    BUNDLE_ID="${LANE_BUNDLE_ID:-com.localvoxtral.app}"
    record_fail() { echo "record_fail: $*" >&2; }
    source "$1"; shift
    for step in "$@"; do
      case "$step" in
        recover) recover_previous_defaults_backup || exit 11 ;;
        snapshot) snapshot_defaults || exit 12 ;;
        force) defaults write "$BUNDLE_ID" settings.dictation_backend_mode external_url || exit 13 ;;
        restore) restore_defaults || exit 14 ;;
      esac
    done
  ' lane "$LIB" "$@" >>"$WORK/lane.out" 2>&1 || status=$?
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

# 1. Killed right after the export, before the backup is committed: the domain
#    was never touched, so the next lane recovers nothing and ends clean.
fresh_account
[[ "$(STUB_KILL_AT=export lane recover snapshot)" == 137 ]] || fail "the export kill did not fire"
[[ "$(lane recover snapshot force restore)" == 0 ]] || fail "the lane after an export kill failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after a lane killed right after its export"
assert_no_leftovers "after a lane killed right after its export"
pass "a lane killed between export and commit leaves the owner's domain intact"

# 2. Killed after the backup is committed and the lane's modes are forced: the
#    next lane restores the owner's domain before snapshotting.
fresh_account
[[ "$(STUB_KILL_AT=mv lane recover snapshot)" == 137 ]] || fail "the rename kill did not fire"
[[ "$(lane recover snapshot force)" == 0 ]] || fail "the lane after a rename kill failed: $(cat "$WORK/lane.out")"
cmp -s "$GOLDEN" "$LIVE" && fail "the lane did not force its modes, so the next check proves nothing"
[[ "$(STUB_KILL_AT=delete lane restore)" == 137 ]] || fail "the delete kill did not fire"
[[ "$(lane recover)" == 0 ]] || fail "recovery after a kill mid-restore failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after a lane killed mid-restore"
assert_no_leftovers "after a lane killed mid-restore"
pass "a lane killed with its modes forced, or mid-restore, is restored by the next lane"

# 3. A damaged backup stops recovery before the live domain is deleted.
fresh_account
[[ "$(lane snapshot force)" == 0 ]] || fail "snapshot failed: $(cat "$WORK/lane.out")"
backup="$WORK/home/.localvoxtral-ui-smoke.defaults-backup"
[[ -f "$backup" ]] || fail "no backup at $backup"
forced="$WORK/forced.plist"
cp "$LIVE" "$forced"
printf 'garbage' >>"$backup"
: >"$CALLS"
[[ "$(lane recover)" == 11 ]] || fail "recovery from a damaged backup did not fail"
grep -q "defaults delete" "$CALLS" && fail "recovery deleted the live domain before the backup validated"
cmp -s "$forced" "$LIVE" || fail "recovery from a damaged backup changed the live domain"
[[ -f "$backup" ]] || fail "recovery from a damaged backup removed the backup"
[[ "$(lane snapshot)" == 12 ]] || fail "a lane snapshotted over a backup that is still on disk"
pass "a damaged backup stops recovery with the live domain and the backup untouched"

# 4. A domain `defaults` cannot read is not an absent domain.
fresh_account
[[ "$(STUB_READ_ERROR='Could not read domain' lane snapshot)" == 12 ]] \
  || fail "a snapshot of an unreadable domain succeeded"
[[ -z "$(ls -A "$WORK/home")" ]] || fail "a failed snapshot left a backup behind"
assert_live_is_golden "after a failed snapshot"
pass "an unreadable domain fails the snapshot instead of being backed up as absent"

# 5. An absent domain comes back absent.
fresh_account absent
[[ "$(lane recover snapshot force restore)" == 0 ]] || fail "lane on an absent domain failed: $(cat "$WORK/lane.out")"
[[ ! -e "$LIVE" ]] || fail "a domain that did not exist before the lane exists after it"
assert_no_leftovers "after a lane on an absent domain"
pass "an absent domain is restored as absent"

# 6. A pre-#991 lane killed between its export and its marker left a plist
#    with no marker. Recovery must import it, not delete the domain.
fresh_account
cp "$GOLDEN" "$WORK/home/.localvoxtral-ui-smoke.pre.plist"
printf '<plist version="1.0">\n<!-- forced external_url -->\n' >"$LIVE"
[[ "$(lane recover)" == 0 ]] || fail "recovering a legacy backup failed: $(cat "$WORK/lane.out")"
assert_live_is_golden "after recovering a legacy backup without its marker"
assert_no_leftovers "after recovering a legacy backup"
pass "a legacy backup whose marker was never written is imported, not discarded"

# 7. On macOS, the same lane against the real `defaults` and `plutil`, on a
#    throwaway domain: the stubs above encode two facts about them (the
#    "does not exist" error of an absent domain, and `plutil -lint -s`).
if [[ "$(uname)" == Darwin ]]; then
  export LANE_PATH="$PATH" LANE_BUNDLE_ID="com.localvoxtral.test-owner-defaults-backup.$$"
  trap '/usr/bin/defaults delete "$LANE_BUNDLE_ID" >/dev/null 2>&1 || :; rm -rf "$WORK"' EXIT
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
  /usr/bin/defaults write "$LANE_BUNDLE_ID" settings.dictation_backend_mode -string "the owner own mode"
  /usr/bin/defaults export "$LANE_BUNDLE_ID" "$WORK/real-golden.plist"
  [[ "$(lane recover snapshot force restore)" == 0 ]] || fail "real defaults: the lane failed: $(cat "$WORK/lane.out")"
  /usr/bin/defaults export "$LANE_BUNDLE_ID" "$WORK/real-after.plist"
  cmp -s "$WORK/real-golden.plist" "$WORK/real-after.plist" \
    || fail "real defaults: the domain is not byte-identical after the lane:
$(cat "$WORK/real-after.plist")"
  /usr/bin/defaults delete "$LANE_BUNDLE_ID"
  [[ "$(lane snapshot force restore)" == 0 ]] || fail "real defaults: the lane on an absent domain failed: $(cat "$WORK/lane.out")"
  /usr/bin/defaults read "$LANE_BUNDLE_ID" >/dev/null 2>&1 \
    && fail "real defaults: an absent domain exists after the lane"
  [[ -z "$(ls -A "$WORK/home")" ]] || fail "real defaults: files left in HOME: $(ls -A "$WORK/home")"
  pass "real defaults and plutil: a present domain comes back byte-identical, an absent one absent"
fi

echo "owner defaults backup tests passed"
