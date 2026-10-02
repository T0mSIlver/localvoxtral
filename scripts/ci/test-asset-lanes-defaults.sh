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
cat >"$BIN/swift" <<'STUB'
#!/bin/sh
if [ "$1" = - ]; then cat >/dev/null; echo "0 0 1920 1080"; exit 0; fi
echo 77
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
cat >"$BIN/open" <<'STUB'
#!/bin/sh
echo "open $*" >>"$EVENTS"
echo 5555 >"$RUNNING"
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
    if [ -n "${3:-}" ]; then
      value="$(awk -F '\t' -v k="$3" '$1 == k { print $2 }' "$store")"
      [ -n "$value" ] || exit 1
      echo "$value"
    else
      cat "$store"
    fi ;;
  write)
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
  rm -rf "$DOMAINS" "$WORK/repo" "$WORK/home" "$WORK/tmp"
  mkdir -p "$DOMAINS" "$WORK/repo/assets" "$WORK/repo/dist/localvoxtral.app" "$WORK/home" "$WORK/tmp"
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

# 2. record-demo: the shell scene, up to the capture region. The owner's
#    polishing backend is external, so record-demo must not wait for the
#    managed helper: that holds only if it read the mode from the suite it
#    copied the owner's domain into.
fresh_mac external_url
status="$(run_lane record-demo.sh DEMO_TERMINAL_AGENT=shell DEMO_WIDTH=4000)"
[[ "$status" == 1 ]] || fail "record-demo exited $status"
grep -q "smaller than the 4000x800 capture region" "$WORK/out" \
  || fail "record-demo stopped before the capture region"
grep -q "Waiting for the polishing helper" "$WORK/out" \
  && fail "record-demo did not read the owner's polishing backend from the suite"
assert_owner_domain_untouched record-demo
assert_launches_on_suite record-demo 1
grep -q "^defaults import $HARNESS -" "$EVENTS" || fail "record-demo did not copy the owner's domain into the suite"
grep -q "^defaults write $HARNESS settings.agent_polish_profile_enabled" "$EVENTS" \
  || fail "record-demo did not pin agent polishing in the suite"
pass "record-demo runs the app on a copy of the owner's settings and never writes the owner's domain"

# 3. record-demo on a managed polishing backend waits for the helper, read
#    from the suite too.
fresh_mac managed_local
status="$(run_lane record-demo.sh DEMO_TERMINAL_AGENT=shell DEMO_POLISH_READY_SECONDS=0)"
[[ "$status" == 1 ]] || fail "record-demo exited $status"
grep -q "polishd never became healthy" "$WORK/out" || fail "record-demo did not wait for the managed helper"
assert_owner_domain_untouched "record-demo (managed polishing)"
pass "record-demo waits for the managed polishing helper and leaves the owner's domain alone"

echo "asset lanes defaults tests passed"
