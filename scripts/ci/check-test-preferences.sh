#!/usr/bin/env bash
# check-test-preferences.sh <marker-file>
#
# Fails when the unit suite left UserDefaults suites in ~/Library/Preferences:
# a plist named with a UUID and newer than <marker-file>, which the step
# touched before the suite ran. A named suite outlives removePersistentDomain,
# and the owner's MacBook had 310k of them. Tests take theirs from
# makeTestDefaults() (Tests/localvoxtralTestSupport/TestDefaults.swift),
# which keeps them in a temp folder; scripts/ci/test-defaults-suites.sh
# catches the usual way back in, this catches the rest.
#
# Written for bash 3.2.
set -uo pipefail

marker="${1:?usage: $0 <marker-file>}"
prefs="${LV_PREFERENCES_DIR:-$HOME/Library/Preferences}"
uuid='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'

leaked="$(find "$prefs" -maxdepth 1 -name '*.plist' -newer "$marker" 2>/dev/null \
  | sed 's#.*/##' | grep "$uuid" || true)"
if [ -z "$leaked" ]; then
  echo "PASS: the unit suite left no preference suites in $prefs"
  exit 0
fi
count="$(printf '%s\n' "$leaked" | wc -l | tr -d ' ')"
printf 'FAIL: the unit suite left %s preference suites in %s, by name:\n' "$count" "$prefs" >&2
printf '%s\n' "$leaked" | sed -e "s/\.\{0,1\}$uuid.*//" -e 's/^$/(a bare UUID)/' | sort | uniq -c | sort -rn | head -20 >&2
echo "Make those suites with makeTestDefaults() from Tests/localvoxtralTestSupport/TestDefaults.swift." >&2
exit 1
