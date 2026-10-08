#!/usr/bin/env bash
# capture-readme-assets.sh and record-demo.sh run the packaged app as the
# owner, on the owner's Mac. They used to snapshot the owner's
# `com.localvoxtral.app` defaults domain, force their settings into it and
# restore it on exit; now they run the app on the harness defaults suite and
# only read the owner's domain (#1450). This suite runs both real scripts
# against stubbed macOS tools and a file-backed `defaults`, and asserts that
# neither writes, imports or deletes the owner's domain, that every launch
# carries the suite, and that each run reports the owner's defaults unchanged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-asset-lanes-defaults.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; echo "--- event log:" >&2; cat "$EVENTS" >&2 || true; echo "--- output:" >&2; cat "$WORK/out" >&2 || true; exit 1; }
pass() { echo "PASS: $1"; }

OWNER="com.localvoxtral.app"
HARNESS="com.localvoxtral.harness"
REAL_MKTEMP="$(command -v mktemp)"
BIN="$WORK/bin"
mkdir -p "$BIN"

# Every stub appends to one ordered event log.
cat >"$BIN/uname" <<'STUB'
#!/bin/sh
echo Darwin
STUB
for tool in say sleep ffmpeg plutil; do
  printf '#!/bin/sh\nexit 0\n' >"$BIN/$tool"
done
# The scripts take `mktemp -t <name>`, which GNU mktemp refuses without X's.
cat >"$BIN/mktemp" <<STUB
#!/bin/sh
if [ "\$1" = -t ]; then exec "$REAL_MKTEMP" "\${TMPDIR:-/tmp}/\$2.XXXXXX"; fi
exec "$REAL_MKTEMP" "\$@"
STUB
# Every Swift helper: the permission preflight passes, the window-id helper
# finds window 77, the AX probe presses its row, `swift -` reports the main
# display, and the gesture helper taps.
# STUB_NO_MENU_WINDOW: the window-id helper finds no open menu (layer 100).
cat >"$BIN/swift" <<'STUB'
#!/bin/sh
if [ "$1" = - ]; then cat >/dev/null; echo "0 0 1920 1080"; exit 0; fi
[ -n "${STUB_NO_MENU_WINDOW:-}" ] && [ "${3:-}" = 100 ] && exit 1
echo 77
STUB
# `swiftc -o <bin> <helper>` builds the window-id helper once: the "binary"
# answers like the swift stub above.
cat >"$BIN/swiftc" <<STUB
#!/bin/sh
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
printf '#!/bin/sh\nexec "%s" helper "\$@"\n' "$BIN/swift" >"\$out"
chmod +x "\$out"
STUB
cat >"$BIN/pgrep" <<'STUB'
#!/bin/sh
# `pgrep -x[q|n] localvoxtral`: the pid in $RUNNING.
case "$1" in
  -x|-xq|-xn) [ -s "$RUNNING" ] || exit 1; [ "$1" = -xq ] || cat "$RUNNING" ;;
  *) exit 1 ;;
esac
STUB
cat >"$BIN/pkill" <<'STUB'
#!/bin/sh
: >"$RUNNING"
STUB
cat >"$BIN/osascript" <<'STUB'
#!/bin/sh
case "$*" in
  *"get dark mode"*) echo false ;;
  *"exists menu bar item"*) echo true ;;
  *"localvoxtral\" to quit"*) echo "quit" >>"$EVENTS"; : >"$RUNNING" ;;
esac
exit 0
STUB
cat >"$BIN/screencapture" <<'STUB'
#!/bin/sh
for last; do :; done
echo png >"$last"
STUB
# The managed polishing helper never answers.
printf '#!/bin/sh\nexit 7\n' >"$BIN/curl"
# A launch on a data folder leaves a History store in it, which is not a
# SQLite file: record-demo's seeding refuses it, which ends that lane.
cat >"$BIN/open" <<'STUB'
#!/bin/sh
echo "open $*" >>"$EVENTS"
echo 5555 >"$RUNNING"
for arg; do
  case "$arg" in LOCALVOXTRAL_DATA_HOME=*) echo stub >"${arg#*=}/history.store" ;; esac
done
STUB
# record-demo's tools, found through the login shell's PATH.
cat >"$BIN/zsh" <<STUB
#!/bin/sh
name="\${2##* }"
[ -x "$BIN/\$name" ] && echo "$BIN/\$name"
STUB
for tool in claude herdr gh; do
  printf '#!/bin/sh\nexit 0\n' >"$BIN/$tool"
done
cat >"$BIN/mdfind" <<STUB
#!/bin/sh
echo "$WORK/Ghostty.app"
STUB
# One file per domain under $DOMAINS, one `key<TAB>value` line per key.
# `export` prints the file and `import` replaces it, so a copy round-trips.
cat >"$BIN/defaults" <<'STUB'
#!/bin/sh
echo "defaults $1 $2 ${3:-}" >>"$EVENTS"
store="$DOMAINS/$2"
case "$1" in
  read)
    [ -f "$store" ] || { echo "Domain $2 does not exist" >&2; exit 1; }
    [ -z "${STUB_READ_ERROR:-}" ] || { echo "$STUB_READ_ERROR" >&2; exit 1; }
    if [ -n "${3:-}" ]; then
      value="$(awk -F '\t' -v k="$3" '$1 == k { print $2 }' "$store")"
      [ -n "$value" ] || exit 1
      echo "$value"
    else
      cat "$store"
    fi ;;
  write)
    # STUB_TERM_ON_FIRST_WRITE: the first write sends SIGTERM to the script.
    if [ -n "${STUB_TERM_ON_FIRST_WRITE:-}" ] && [ ! -e "$EVENTS.term" ]; then
      : >"$EVENTS.term"
      echo "TERM" >>"$EVENTS"
      kill -TERM "$PPID"
    fi
    key="$3"; shift 3
    for value; do :; done
    touch "$store"
    grep -v "^$key	" "$store" >"$store.new" || true
    printf '%s\t%s\n' "$key" "$value" >>"$store.new"
    mv "$store.new" "$store" ;;
  delete)
    [ -f "$store" ] || exit 1
    if [ -n "${3:-}" ]; then
      grep -v "^$3	" "$store" >"$store.new" || true
      mv "$store.new" "$store"
    else
      rm -f "$store"
    fi ;;
  export)
    [ -f "$store" ] || exit 1
    if [ "$3" = - ]; then cat "$store"; else cp "$store" "$3"; fi ;;
  import)
    if [ "$3" = - ]; then cat >"$store"; else cp "$3" "$store"; fi ;;
esac
STUB
chmod +x "$BIN"/*

export EVENTS="$WORK/events" RUNNING="$WORK/running" DOMAINS="$WORK/domains"
OWNER_GOLDEN="$WORK/owner-golden"

# A fresh Mac: the owner's app running, the owner's domain set to `$1` for
# the polishing backend, and a repo checkout with an assets/ folder.
fresh_mac() {
  rm -rf "$DOMAINS" "$WORK/repo" "$WORK/home" "$WORK/tmp" "$EVENTS.term"
  mkdir -p "$DOMAINS" "$WORK/repo/assets" "$WORK/repo/dist/localvoxtral.app/Contents/MacOS" "$WORK/home" "$WORK/tmp" \
    "$WORK/Ghostty.app"
  for helper in localvoxtral-claude-hook localvoxtral-cli; do
    printf '#!/bin/sh\nexit 0\n' >"$WORK/repo/dist/localvoxtral.app/Contents/MacOS/$helper"
    chmod +x "$WORK/repo/dist/localvoxtral.app/Contents/MacOS/$helper"
  done
  echo '{"oauthAccount": {}}' >"$WORK/home/.claude.json"
  : >"$EVENTS"
  echo 4242 >"$RUNNING"
  printf 'settings.polishing_backend_mode\t%s\nsettings.overlay_buffer_font_size\t15\n' "$1" >"$DOMAINS/$OWNER"
  cp "$DOMAINS/$OWNER" "$OWNER_GOLDEN"
}

# run_lane <script> [env...]: prints the script's exit status.
run_lane() {
  local script="$1" status=0
  shift
  (cd "$WORK/repo" && env HOME="$WORK/home" TMPDIR="$WORK/tmp" PATH="$BIN:$PATH" "$@" \
    bash "$ROOT_DIR/scripts/$script" dist/localvoxtral.app) >"$WORK/out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

assert_owner_domain_untouched() {
  grep -qE "^defaults (write|import|delete) $OWNER( |$)" "$EVENTS" \
    && fail "$1 wrote the owner's defaults domain"
  cmp -s "$OWNER_GOLDEN" "$DOMAINS/$OWNER" || fail "$1 changed the owner's defaults domain"
  [[ ! -e "$DOMAINS/$HARNESS" ]] || fail "$1 left the harness suite behind: $(cat "$DOMAINS/$HARNESS")"
  grep -q "Owner defaults unchanged" "$WORK/out" || fail "$1 did not report the owner's defaults"
}

# Every launch of the app under test carries the suite.
assert_launches_on_suite() {
  local launches
  launches="$(grep -c "^open .*dist/localvoxtral.app" "$EVENTS" || true)"
  [[ "$launches" == "$2" ]] || fail "$1 launched the app $launches times, expected $2"
  grep "^open .*dist/localvoxtral.app" "$EVENTS" | grep -v -- "--env LOCALVOXTRAL_DEFAULTS_SUITE=$HARNESS " \
    && fail "$1 launched the app on the owner's preferences"
  return 0
}

# 1. capture-readme-assets: a full run on stubs.
fresh_mac managed_local
status="$(run_lane capture-readme-assets.sh)"
[[ "$status" == 0 ]] || fail "capture-readme-assets exited $status"
grep -q "^Done. Review with" "$WORK/out" || fail "capture-readme-assets did not finish"
assert_owner_domain_untouched capture-readme-assets
assert_launches_on_suite capture-readme-assets 2
grep -q "^defaults write $HARNESS settings.onboarding_completed" "$EVENTS" \
  || fail "capture-readme-assets did not complete onboarding in the suite"
grep -q "^defaults write $HARNESS debug.enrollment_sheet_preview" "$EVENTS" \
  || fail "capture-readme-assets did not arm the enrollment sheet in the suite"
# AppKit reads the language and region from the argument domain, not a suite.
grep "^open .*dist/localvoxtral.app" "$EVENTS" \
  | grep -v -- "--args -AppleLanguages (en-US) -AppleLocale en_US$" \
  && fail "capture-readme-assets launched the app without its language and region"
pass "capture-readme-assets runs the app on the harness suite and never writes the owner's domain"

# 2. record-demo up to the capture region, which it checks before staging or
#    launching anything: the suite starts as a copy of the owner's domain,
#    with the demo's settings pinned, and the speech and polishing backends
#    point at the scripted one (scripts/lib/demo-backend.py).
fresh_mac managed_local
status="$(run_lane record-demo.sh DEMO_FORCE=1 DEMO_WIDTH=4000)"
[[ "$status" == 1 ]] || fail "record-demo exited $status"
grep -q "smaller than 4000x800" "$WORK/out" \
  || fail "record-demo stopped before the capture region"
assert_owner_domain_untouched record-demo
assert_launches_on_suite record-demo 0
grep -q "^defaults import $HARNESS -" "$EVENTS" || fail "record-demo did not copy the owner's domain into the suite"
grep -q "^defaults write $HARNESS settings.agent_polish_profile_enabled" "$EVENTS" \
  || fail "record-demo did not pin agent polishing in the suite"
grep -q "^defaults write $HARNESS settings.polishing_backend_mode" "$EVENTS" \
  || fail "record-demo did not point polishing at the scripted backend"
grep -q "^defaults write $HARNESS settings.dictation_backend_mode" "$EVENTS" \
  || fail "record-demo did not point speech at the scripted backend"
pass "record-demo runs on a copy of the owner's settings and never writes the owner's domain"

# 3. record-demo's launch: on the suite and its own data folder, then the
#    History seeding, which refuses the stub's store.
fresh_mac managed_local
status="$(run_lane record-demo.sh DEMO_FORCE=1)"
[[ "$status" == 1 ]] || fail "record-demo exited $status"
grep -q "Seeding History failed" "$WORK/out" || fail "record-demo did not reach the History seeding"
assert_owner_domain_untouched "record-demo (launch)"
assert_launches_on_suite "record-demo (launch)" 1
grep "^open .*dist/localvoxtral.app" "$EVENTS" | grep -q -- "--env LOCALVOXTRAL_DATA_HOME=$WORK/tmp/lv-demo-data." \
  || fail "record-demo launched the app without a data folder of its own"
pass "record-demo launches the app on the suite and a data folder of its own"

# 4. An owner's domain that cannot be read is not a fresh Mac: record-demo
#    stops instead of recording on the app's defaults.
fresh_mac external_url
status="$(run_lane record-demo.sh DEMO_FORCE=1 STUB_READ_ERROR="Could not read domain")"
[[ "$status" == 1 ]] || fail "record-demo exited $status"
grep -q "Could not copy $OWNER defaults into $HARNESS" "$WORK/out" || fail "record-demo did not stop at the copy"
grep -q "^open .*dist/localvoxtral.app" "$EVENTS" && fail "record-demo launched the app without the owner's settings"
pass "record-demo stops when the owner's domain cannot be read"

# 5. A signal ends the run after cleanup. The TERM comes from the first
#    defaults write, before the launch; the script must exit 143 and touch
#    neither the suite nor the app again (#1720).
assert_ends_on_signal() {
  local after
  [[ "$2" == 143 ]] || fail "$1 exited $2 after SIGTERM, expected 143"
  after="$(sed -n '/^TERM$/,$p' "$EVENTS" | grep -E "^(defaults (write|import)|open) " || true)"
  [[ -z "$after" ]] || fail "$1 carried on after SIGTERM: $after"
  [[ "$(grep -c "Owner defaults unchanged" "$WORK/out")" == 1 ]] || fail "$1 did not clean up exactly once"
  [[ ! -e "$DOMAINS/$HARNESS" ]] || fail "$1 left the harness suite behind after SIGTERM"
}
fresh_mac managed_local
status="$(run_lane capture-readme-assets.sh STUB_TERM_ON_FIRST_WRITE=1)"
assert_ends_on_signal capture-readme-assets "$status"
pass "capture-readme-assets stops after cleanup on SIGTERM"
fresh_mac external_url
status="$(run_lane record-demo.sh DEMO_FORCE=1 STUB_TERM_ON_FIRST_WRITE=1)"
assert_ends_on_signal record-demo "$status"
pass "record-demo stops after cleanup on SIGTERM"

# 6. A missed popover shot fails the run and leaves no popover.png, so the
#    workflow cannot upload the checkout's old one as new (#1723).
fresh_mac managed_local
echo old >"$WORK/repo/assets/popover.png"
status="$(run_lane capture-readme-assets.sh STUB_NO_MENU_WINDOW=1)"
[[ "$status" != 0 ]] || fail "capture-readme-assets succeeded without a popover shot"
[[ ! -e "$WORK/repo/assets/popover.png" ]] || fail "capture-readme-assets left the old popover.png in assets/"
pass "capture-readme-assets fails and leaves no popover.png when the popover shot fails"

echo "asset lanes defaults tests passed"
