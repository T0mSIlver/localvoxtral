#!/usr/bin/env bash
# clean-test-leftovers.sh [--apply]
#
# Removes what test runs left in the owner's account before LVX-52 and LVX-53:
#
# 1. UserDefaults suites the unit tests made, one plist per test in
#    ~/Library/Preferences (localvoxtral.<Suite>Tests.<UUID>.plist and the
#    other names below). Deleted outright: each held only a test's settings.
# 2. Dictations the e2e harness wrote into the owner's History: rows whose
#    target app is com.localvoxtral.e2e-target, and their recordings. The
#    History store and the recordings are copied to a backup folder first.
#
# Without --apply it only counts. With --apply the app must be quit, since it
# holds the History store open.
#
# Run on the Mac whose account it cleans, as that user. Written for the
# system's bash 3.2 and /usr/bin/sqlite3.
set -euo pipefail

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

PREFS="${LV_CLEAN_PREFERENCES_DIR:-$HOME/Library/Preferences}"
DATA="${LV_CLEAN_DATA_DIR:-$HOME/Library/Application Support/localvoxtral}"
STORE="$DATA/history.store"
AUDIO="$DATA/dictation-audio"
TARGET="com.localvoxtral.e2e-target"
UUID_RE='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
# The names the test suites used. A bare <UUID>.plist is matched separately,
# and only when it is empty or holds nothing but the app's own keys.
NAMED_RE="^(localvoxtral\..+|com\.localvoxtral\.harness-test-|lvx-preview-|insights-usage-|[A-Za-z]+Tests\..*)\.?$UUID_RE\.plist$"
BARE_RE="^$UUID_RE\.plist$"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-clean.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ "$APPLY" = 1 ] && pgrep -x localvoxtral >/dev/null 2>&1; then
  echo "localvoxtral is running. Quit it (menu bar > Quit), then run this again." >&2
  exit 1
fi

# --- 1. preference suites ----------------------------------------------------

ls -f "$PREFS" | grep -E "$NAMED_RE" >"$WORK/named" || true
: >"$WORK/bare"
ls -f "$PREFS" | grep -E "$BARE_RE" | while IFS= read -r name; do
  # Keys other than settings.* and debug.* mean another program's plist: keep it.
  others="$(plutil -convert xml1 -o - "$PREFS/$name" 2>/dev/null \
    | sed -n 's:.*<key>\(.*\)</key>.*:\1:p' | grep -vE '^(settings|debug)\.' || true)"
  [ -z "$others" ] && echo "$name" >>"$WORK/bare"
done || true

named_count="$(wc -l <"$WORK/named" | tr -d ' ')"
bare_count="$(wc -l <"$WORK/bare" | tr -d ' ')"
echo "Preference suites left by tests in $PREFS: $((named_count + bare_count))"
sed -E "s/\.?$UUID_RE\.plist$//" "$WORK/named" | sed -E 's/^localvoxtral\..*/localvoxtral.*/' \
  | sort | uniq -c | sort -rn | head -15
[ "$bare_count" = 0 ] || printf '%7s (a bare UUID)\n' "$bare_count"

# --- 2. e2e dictations in History ---------------------------------------------

rows=0
if [ -f "$STORE" ]; then
  q() { sqlite3 -readonly "$STORE" "$1"; }
  rows="$(q "select count(*) from ZDICTATIONSESSIONRECORD where ZTARGETAPPBUNDLEID = '$TARGET';")"
  echo
  echo "History dictations into $TARGET: $rows"
  if [ "$rows" != 0 ]; then
    q "select '  from ' || min(datetime(ZSTARTEDAT + 978307200, 'unixepoch')) || ' to ' ||
              max(datetime(ZSTARTEDAT + 978307200, 'unixepoch')) || ' UTC'
       from ZDICTATIONSESSIONRECORD where ZTARGETAPPBUNDLEID = '$TARGET';"
    q "select date(ZSTARTEDAT + 978307200, 'unixepoch'), count(*) from ZDICTATIONSESSIONRECORD
       where ZTARGETAPPBUNDLEID = '$TARGET' group by 1 order by 1;" | sed 's/^/    /; s/|/: /'
    q "select upper(substr(hex(ZID),1,8) || '-' || substr(hex(ZID),9,4) || '-' || substr(hex(ZID),13,4)
              || '-' || substr(hex(ZID),17,4) || '-' || substr(hex(ZID),21,12))
       from ZDICTATIONSESSIONRECORD where ZTARGETAPPBUNDLEID = '$TARGET';" >"$WORK/ids"
    : >"$WORK/wavs"
    while IFS= read -r id; do
      [ -f "$AUDIO/$id.wav" ] && echo "$id.wav" >>"$WORK/wavs"
    done <"$WORK/ids"
    echo "  with $(wc -l <"$WORK/wavs" | tr -d ' ') recordings in $AUDIO"
  fi
else
  echo
  echo "No History store at $STORE."
fi

if [ "$APPLY" = 0 ]; then
  echo
  echo "Dry run: nothing changed. Run with --apply to remove these."
  exit 0
fi

# --- apply ---------------------------------------------------------------------

echo
if [ $((named_count + bare_count)) != 0 ]; then
  (cd "$PREFS" && cat "$WORK/named" "$WORK/bare" | tr '\n' '\0' | xargs -0 rm -f)
  echo "Deleted $((named_count + bare_count)) preference suites."
fi

if [ "$rows" != 0 ]; then
  backup="$DATA/backups/test-leftovers-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup/dictation-audio"
  for f in "$STORE" "$STORE-wal" "$STORE-shm"; do
    [ -f "$f" ] && cp -p "$f" "$backup/"
  done
  while IFS= read -r wav; do
    mv "$AUDIO/$wav" "$backup/dictation-audio/"
  done <"$WORK/wavs"
  sqlite3 "$STORE" "begin; delete from ZDICTATIONSESSIONRECORD where ZTARGETAPPBUNDLEID = '$TARGET'; commit;"
  left="$(sqlite3 "$STORE" "select count(*) from ZDICTATIONSESSIONRECORD where ZTARGETAPPBUNDLEID = '$TARGET';")"
  echo "Deleted $rows History dictations ($left left); store and recordings backed up to $backup"
fi
