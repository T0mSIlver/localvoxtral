#!/usr/bin/env bash
# restore-mtimes.sh [repo-dir]
#
# Sets every tracked file's mtime to the commit time of the last commit that
# touched it. A fresh checkout stamps every file with the checkout time, and
# swift-driver's incremental build compares each source's mtime with the one
# recorded in the previous build, so a restored `.build` cache was rebuilding
# all 400-odd files on every hosted run (437 "Compiling" lines after "Cache
# restored successfully", 2026-09-22). Commit times are the same on every
# checkout, so after this script an unchanged file matches its record and a
# changed one (a newer commit) does not.
#
# Runs before `swift test` in ci.yml. Works on bash 3.2 and both awks; perl
# applies the times because BSD and GNU `touch` disagree on date syntax.
# Paths git has to quote (control characters) are left alone, which only
# costs a rebuild of that file.
set -euo pipefail

cd "${1:-.}"

TRACKED="$(mktemp "${TMPDIR:-/tmp}/lv-restore-mtimes.XXXXXX")"
trap 'rm -f "$TRACKED"' EXIT
git ls-files >"$TRACKED"
total="$(wc -l <"$TRACKED" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
  echo "restore-mtimes: no tracked files" >&2
  exit 0
fi

# Newest commit first: the first time a path appears is its last touch. A
# commit's header line is a tab followed by its time, which no unquoted path
# can start with. The log is read to its end on purpose: stopping once every
# tracked file has a time would leave git writing into a closed pipe, and
# under `pipefail` its SIGPIPE fails the whole script on any history longer
# than one pipe buffer (test-restore-mtimes.sh pins this).
git -c core.quotePath=false log --format='%x09%ct' --name-only --no-renames \
  | awk '
      FNR == NR { tracked[$0] = 1; next }
      /^\t[0-9]+$/ { time = substr($0, 2); next }
      $0 == "" || !($0 in tracked) || ($0 in seen) { next }
      {
        seen[$0] = 1
        print time "\t" $0
      }
    ' "$TRACKED" - \
  | perl -ne '
      chomp;
      my ($time, $path) = split /\t/, $_, 2;
      next unless -f $path;
      utime $time, $time, $path or die "utime $path: $!";
      $n++;
      END { print "restore-mtimes: set ", ($n // 0), " of '"$total"' tracked files\n" }
    '
