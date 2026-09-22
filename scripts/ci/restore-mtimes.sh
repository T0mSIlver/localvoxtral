#!/usr/bin/env bash
# restore-mtimes.sh [repo-dir] [cache-base-commit]
#
# Sets every tracked file's mtime to the commit time of the last commit that
# touched it. A fresh checkout stamps every file with the checkout time, and
# swift-driver's incremental build compares each source's mtime with the one
# recorded in the previous build, so a restored `.build` cache was rebuilding
# all 400-odd files on every hosted run (437 "Compiling" lines after "Cache
# restored successfully", 2026-09-22). Commit times are the same on every
# checkout, so after this script an unchanged file matches its record and a
# changed one (a different commit) does not.
#
# The driver's comparison is equality, so one hole remains: two branches
# that commit DIFFERENT content to one file in the SAME second give it the
# same mtime, and a cache saved from one would let the other's change go
# uncompiled. The second argument closes it: the commit the restored cache
# was built from (ci.yml reads it off the matched cache key). Every file
# whose content differs between that commit and the checkout is touched to
# now, which can never equal what the record holds. A base that is not a
# commit here means touch everything, which is the full rebuild of today.
#
# Runs before `swift test` in ci.yml. Works on bash 3.2 and both awks; perl
# applies the times because BSD and GNU `touch` disagree on date syntax.
# Paths git has to quote (control characters) are left alone, which only
# costs a rebuild of that file.
set -euo pipefail

cd "${1:-.}"
CACHE_BASE="${2:-}"

TRACKED="$(mktemp "${TMPDIR:-/tmp}/lv-restore-mtimes.XXXXXX")"
trap 'rm -f "$TRACKED"' EXIT
# Same quoting as the log below, or a non-ASCII path would be quoted here and
# raw there, never match, and quietly rebuild every run.
git -c core.quotePath=false ls-files >"$TRACKED"
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

if [ -z "$CACHE_BASE" ]; then
  exit 0
fi
if git cat-file -e "$CACHE_BASE^{commit}" 2>/dev/null; then
  changed="$(git -c core.quotePath=false diff --name-only --no-renames "$CACHE_BASE" HEAD -- \
    | perl -ne 'chomp; next unless -f $_; utime undef, undef, $_ or die "utime $_: $!"; $n++; END { print $n // 0 }')"
  echo "restore-mtimes: touched $changed file(s) changed since cache base ${CACHE_BASE}"
else
  changed="$(perl -ne 'chomp; utime undef, undef, $_ or die "utime $_: $!"; $n++; END { print $n // 0 }' "$TRACKED")"
  echo "restore-mtimes: cache base ${CACHE_BASE} is not a commit here; touched all $changed tracked files"
fi
