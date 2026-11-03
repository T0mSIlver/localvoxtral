#!/usr/bin/env bash
# release-freshness.sh: fail when main has gone too long without a stable
# release.
#
# The daily release skips green when no main commit has passed the e2e
# dictation check (daily-release-plan.sh), and its job can sit unclaimed in
# the queue until GitHub cancels it, because it needs the Mac Mini's runner.
# Between 2026-10-22 and 2026-11-03 both happened: no release for 12 days,
# every skip green, the rest cancelled, and nothing told anyone. The release
# job cannot report its own absence, so this runs on a hosted runner
# (release-freshness.yml) and reads only git.
#
# Run from a checkout of main with full history and tags. Prints
# GitHub-output style lines and exits:
#   0  fresh: main has nothing since the newest stable tag, or the oldest
#      commit since it is younger than the limit
#   1  stale: the oldest unreleased commit is at least <limit> days old
#
#   base=<vX.Y.Z or none>   newest stable tag reachable from HEAD
#   waiting=<n>             commits on HEAD since that tag
#   oldest_days=<n>         age of the oldest of them
#   stale=true|false
#   reason=<one line>
#
# Env:
#   RELEASE_FRESHNESS_DAYS  limit in days (default 3)
#   RELEASE_FRESHNESS_NOW   epoch seconds to measure against (default: now);
#                           tests pass it instead of reading the clock
set -euo pipefail

LIMIT_DAYS="${RELEASE_FRESHNESS_DAYS:-3}"
NOW="${RELEASE_FRESHNESS_NOW:-$(date +%s)}"

BASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude 'v*-*' HEAD 2>/dev/null || true)"
echo "base=${BASE_TAG:-none}"

if [[ -z "$BASE_TAG" ]]; then
  echo "waiting=0"
  echo "stale=false"
  echo "reason=no stable tag is reachable from HEAD; nothing to measure"
  exit 0
fi

WAITING="$(git rev-list --count "$BASE_TAG..HEAD")"
echo "waiting=$WAITING"
if [[ "$WAITING" -eq 0 ]]; then
  echo "oldest_days=0"
  echo "stale=false"
  echo "reason=main is released as $BASE_TAG"
  exit 0
fi

# git log lists newest first, so the last line is the oldest commit.
OLDEST="$(git log --format=%ct "$BASE_TAG..HEAD" | tail -n 1)"
OLDEST_DAYS=$(( (NOW - OLDEST) / 86400 ))
echo "oldest_days=$OLDEST_DAYS"

if [[ "$OLDEST_DAYS" -ge "$LIMIT_DAYS" ]]; then
  echo "stale=true"
  echo "reason=$WAITING commit(s) on main have waited for a release since $BASE_TAG; the oldest landed $OLDEST_DAYS days ago (limit $LIMIT_DAYS). Look at: gh run list -w release.yml (skipped green, cancelled, or queued), gh api repos/\$GITHUB_REPOSITORY/actions/runners (is mac-mini online and idle), and whether UI Smoke ran on main (gh workflow run ui-smoke.yml with the Mac unlocked)"
  exit 1
fi

echo "stale=false"
echo "reason=$WAITING commit(s) since $BASE_TAG, the oldest $OLDEST_DAYS day(s) old, under the limit of $LIMIT_DAYS"
