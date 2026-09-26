#!/usr/bin/env bash
# daily-release-plan.sh: pick the commit the daily release ships, or none.
#
# The daily release (release.yml's `daily` channel, the 03:15 UTC cron) is a
# stable minor release, so it carries the stable gate: the e2e dictation check
# (scripts/e2e-dictation.sh) must have scored and passed on the release
# commit. Nobody is at the Mac at 03:15, so the release does not run the
# check; it ships the newest main commit that a UI Smoke run (ui-smoke.yml)
# already checked, normally the one the owner dispatches on main when he is
# at the Mac. That commit can be behind main's head: what merged after the
# check waits for the next one.
#
# Run from a checkout of main with full history and tags. Decides:
#
#   run=false  main has nothing since the newest stable tag
#   run=false  no commit since that tag has a UI Smoke run that scored
#   run=true   sha=<the newest such commit>
#
# A UI Smoke run counts only when its "E2E dictation scored" step concluded
# `success`: the dictation step itself also goes green when the Mac could not
# run it (exit 3 on a guarded dispatch). release.sh reads the same step name.
#
# Fails CLOSED: this is a release gate, so an API error exits non-zero and the
# run goes red instead of releasing an unchecked commit.
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   sha=<40 hex>          (run=true only)
#   base=<vX.Y.Z or none> the stable tag the minor bump starts from
#   reason=<one line>
#
# Needs: git, gh (GH_TOKEN with actions:read), GITHUB_REPOSITORY.
set -euo pipefail

E2E_STEP="E2E dictation scored"
# Several days of dispatches on main, guard skips included. A commit checked
# longer ago than that is not worth releasing unattended.
RUNS_PER_PAGE=30

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

HEAD_SHA="$(git rev-parse HEAD)"
BASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude 'v*-*' HEAD 2>/dev/null || true)"
BASE_SHA=""
if [[ -n "$BASE_TAG" ]]; then
  BASE_SHA="$(git rev-list -n 1 "$BASE_TAG")"
fi
echo "base=${BASE_TAG:-none}"

if [[ -n "$BASE_SHA" && "$BASE_SHA" == "$HEAD_SHA" ]]; then
  echo "run=false"
  echo "reason=main is already released as $BASE_TAG ($(git rev-parse --short HEAD)); nothing new to ship"
  exit 0
fi

# is_releasable <sha>: on main, and newer than the base tag.
is_releasable() {
  local sha="$1"
  git cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$sha" "$HEAD_SHA" || return 1
  if [[ -n "$BASE_SHA" ]] && git merge-base --is-ancestor "$sha" "$BASE_SHA"; then
    return 1
  fi
  return 0
}

if ! runs="$(gh api \
  "repos/${GITHUB_REPOSITORY}/actions/workflows/ui-smoke.yml/runs?branch=main&status=completed&per_page=${RUNS_PER_PAGE}" \
  --jq '.workflow_runs[] | "\(.id) \(.head_sha)"')"; then
  echo "could not list UI Smoke runs; refusing to pick a release commit" >&2
  exit 1
fi

# Newest first. The ancestry check comes before the jobs call, so runs on
# commits already released cost no API call.
while read -r id sha; do
  [[ -n "$id" ]] || continue
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  is_releasable "$sha" || continue
  if ! scored="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs" \
    --jq "[.jobs[].steps[] | select(.name == \"${E2E_STEP}\") | .conclusion] | first // empty")"; then
    echo "could not read the jobs of UI Smoke run $id; refusing to pick a release commit" >&2
    exit 1
  fi
  if [[ "$scored" == "success" ]]; then
    behind="$(git rev-list --count "$sha..$HEAD_SHA")"
    echo "run=true"
    echo "sha=$sha"
    echo "reason=e2e dictation passed on ${sha:0:9} in UI Smoke run $id; main is $behind commit(s) past it"
    exit 0
  fi
done <<<"$runs"

echo "run=false"
echo "reason=no commit on main since ${BASE_TAG:-the first commit} has passed the e2e dictation check; dispatch UI Smoke on main with the Mac unlocked (gh workflow run ui-smoke.yml)"
