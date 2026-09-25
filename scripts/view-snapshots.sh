#!/usr/bin/env bash
# Renders the app's views to PNG on a GitHub-hosted runner and downloads them,
# for an agent that has to show the owner what a view looks like. Dispatches
# .github/workflows/view-snapshots.yml on a pushed branch, waits for it, and
# prints the path of every PNG. Nothing runs on the owner's Mac.
# docs/agent/view-snapshots.md says how to add a view or a state.
#
# Usage:
#   scripts/view-snapshots.sh [--filter <test>] [--out <dir>] [branch]
#
#   branch     default: the current branch. The runner renders what GitHub
#              has, so push first; a local HEAD that differs is warned about.
#   --filter   ViewSnapshotTests (default) or one case of it, e.g.
#              ViewSnapshotTests/testSettingsPanes
#   --out      an empty or new folder; default .build/view-snapshots/<short
#              sha>, emptied first
#
# Exit: 0 downloaded, 1 the run failed or was cancelled, 2 usage or API error.
# Test seam: VIEW_SNAPSHOTS_POLL_SECONDS (default 5) between run lookups.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
WORKFLOW=view-snapshots.yml
POLL_SECONDS="${VIEW_SNAPSHOTS_POLL_SECONDS:-5}"
LOOKUP_ATTEMPTS=24

usage() {
  echo "usage: $0 [--filter <test>] [--out <dir>] [branch]" >&2
  exit 2
}

api_error() {
  echo "error: $1" >&2
  exit 2
}

filter=ViewSnapshotTests
out=""
branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)
      [[ $# -ge 2 && -n "$2" ]] || usage
      filter="$2"; shift 2 ;;
    --out)
      [[ $# -ge 2 && -n "$2" ]] || usage
      out="$2"; shift 2 ;;
    -*) usage ;;
    *)
      [[ -z "$branch" ]] || usage
      branch="$1"; shift ;;
  esac
done
# The workflow refuses anything else; failing here saves a runner.
[[ "$filter" =~ ^ViewSnapshotTests(/[A-Za-z0-9_]+)?$ ]] \
  || api_error "--filter must be ViewSnapshotTests or ViewSnapshotTests/<test>, got: $filter"
if [[ -z "$branch" ]]; then
  branch="$(git -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD)" \
    || api_error "detached HEAD: name the branch"
fi

branch_uri="$(jq -rn --arg b "$branch" '$b | @uri')"
sha="$(gh api "repos/{owner}/{repo}/commits/$branch_uri" --jq '.sha')" \
  || api_error "cannot resolve $branch on GitHub; push it first"
local_sha="$(git -C "$ROOT_DIR" rev-parse --verify --quiet "refs/heads/$branch" || true)"
if [[ -n "$local_sha" && "$local_sha" != "$sha" ]]; then
  echo "warning: renders $branch as pushed (${sha:0:9}), not your local ${local_sha:0:9}" >&2
fi

# Checked before dispatching: a bad --out must not cost a runner.
if [[ -z "$out" ]]; then
  out="$ROOT_DIR/.build/view-snapshots/${sha:0:9}"
  rm -rf "$out"
elif [[ -n "$(ls -A "$out" 2>/dev/null)" ]]; then
  api_error "--out $out is not empty"
fi
mkdir -p "$out"

# The run name carries this id: `gh workflow run` does not say which run it
# started, and two dispatches on one branch must not pick up each other's.
request_id="$(date +%s)-$$-$RANDOM"
gh workflow run "$WORKFLOW" --ref "$branch" -f filter="$filter" -f request_id="$request_id" >/dev/null \
  || api_error "cannot dispatch $WORKFLOW on $branch"
echo "dispatched $WORKFLOW on $branch at ${sha:0:9} ($filter)" >&2

# The runs API, not `gh run list`: the latter has missed recent dispatches.
run_id=""
for _ in $(seq "$LOOKUP_ATTEMPTS"); do
  run_id="$(gh api "repos/{owner}/{repo}/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=30" \
    --jq ".workflow_runs[] | select(.display_title == \"View snapshots $request_id\") | .id" | head -n 1)" \
    || api_error "cannot list $WORKFLOW runs"
  [[ -n "$run_id" ]] && break
  sleep "$POLL_SECONDS"
done
[[ -n "$run_id" ]] || api_error "the dispatched run never appeared (request $request_id)"
echo "run: $(gh api "repos/{owner}/{repo}/actions/runs/$run_id" --jq '.html_url')" >&2

# Polled, not `gh run watch --exit-status`, which exits 0 on a cancelled run.
while :; do
  state="$(gh api "repos/{owner}/{repo}/actions/runs/$run_id" --jq '"\(.status) \(.conclusion)"')" \
    || api_error "cannot read run $run_id"
  [[ "$state" == completed* ]] && break
  sleep "$((POLL_SECONDS * 6))"
done
conclusion="${state#completed }"
if [[ "$conclusion" != "success" ]]; then
  echo "error: run $run_id concluded $conclusion; its test log is the view-snapshots-log artifact" >&2
  exit 1
fi

gh run download "$run_id" -n view-snapshots -D "$out" >/dev/null \
  || api_error "cannot download the view-snapshots artifact of run $run_id"
out="$(cd "$out" && pwd -P)"
find "$out" -name '*.png' | sort
