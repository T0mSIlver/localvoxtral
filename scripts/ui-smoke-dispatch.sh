#!/usr/bin/env bash
# Dispatches UI Smoke on a branch, or refuses. The run's AX drill is on a
# GitHub-hosted runner; its e2e dictation check holds the only Mac for several
# minutes and takes the owner's keyboard, so a run happens once per PR, on the
# final diff (#544):
#
#   refuse  the diff touches no insertion, focus or commit file (scripts/ci/e2e-dictation-filter.sh)
#   refuse  build-test is not green on the branch head
#   refuse  a UI Smoke run on the branch is still queued or running
#   refuse  a UI Smoke run on the branch started less than an hour ago
#   refuse  a UI Smoke run already ran on this head commit, whatever it
#           concluded: a NOT RUN or lost-focus red is not retried; say so in
#           the PR's Proof section and leave the rerun to the owner
#
# The last two count only runs whose job ran a step. Any label other than
# needs-ui-smoke creates a run that is skipped, or cancelled by the next
# label's run, without reaching the Mac (#570).
#
# Usage:
#   scripts/ui-smoke-dispatch.sh [--dry-run] [--override <why>] <branch>
#
#   --dry-run          print the decision, dispatch nothing (the PR body quotes
#                      the path line)
#   --override <why>   skip every refusal but the queued/running one; for a
#                      rerun the owner asked for. Quote <why> in the PR.
#
# Exit: 0 dispatched (or would, with --dry-run), 1 refused, 2 usage or API
# error. Test seam: UI_SMOKE_DISPATCH_NOW (epoch seconds) replaces the clock.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/e2e-dictation-filter.sh"
COOLDOWN_SECONDS=3600

usage() {
  echo "usage: $0 [--dry-run] [--override <why>] <branch>" >&2
  exit 2
}

dry_run=false
override=""
branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --override)
      [[ $# -ge 2 && -n "$2" ]] || usage
      override="$2"; shift 2 ;;
    -*) usage ;;
    *)
      [[ -z "$branch" ]] || usage
      branch="$1"; shift ;;
  esac
done
[[ -n "$branch" ]] || usage

api_error() {
  echo "error: $1" >&2
  exit 2
}

now="${UI_SMOKE_DISPATCH_NOW:-$(date +%s)}"
tmp="$(mktemp "${TMPDIR:-/tmp}/lv-ui-smoke-dispatch.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Encoded: a branch name may hold '#', '&' or '?'.
branch_uri="$(jq -rn --arg b "$branch" '$b | @uri')"
sha="$(gh api "repos/{owner}/{repo}/commits/$branch_uri" --jq '.sha')" \
  || api_error "cannot resolve $branch on GitHub; push it first"
echo "branch: $branch at ${sha:0:9}"

refusals=()

# The three-dot compare diffs against the merge base, like the PR does.
gh api --paginate "repos/{owner}/{repo}/compare/main...$sha" --jq '.files[].filename' >"$tmp" \
  || api_error "cannot list the files $branch changes against main"
decision="$("$FILTER" "$tmp")"
path_reason="$(sed -n 's/^reason=//p' <<<"$decision")"
echo "path: $path_reason"
[[ "$(sed -n 's/^run=//p' <<<"$decision")" == "true" ]] || refusals+=("the diff does not need it")

build_test="$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?check_name=build-test" \
  --jq '(.check_runs | max_by(.id)) as $r | if $r == null then "none" else "\($r.status)/\($r.conclusion // "")" end')" \
  || api_error "cannot read build-test on ${sha:0:9}"
echo "build-test: $build_test"
[[ "$build_test" == "completed/success" ]] || refusals+=("build-test is not green on ${sha:0:9}")

# id, status, head sha, start epoch, conclusion; newest first.
runs="$(gh api "repos/{owner}/{repo}/actions/workflows/ui-smoke.yml/runs?branch=$branch_uri&per_page=20" \
  --jq '.workflow_runs[] | [.id, .status, .head_sha, (.created_at | fromdateiso8601), (.conclusion // "")] | @tsv')" \
  || api_error "cannot list UI Smoke runs on $branch"
active_id=""
active_status=""
cooling=false
while IFS=$'\t' read -r id status run_sha created conclusion; do
  [[ -n "$id" ]] || continue
  age=$((now - created))
  echo "earlier run: $id ${status}${conclusion:+/$conclusion} on ${run_sha:0:9}, $((age / 60)) min ago"
  if [[ "$status" != completed ]]; then
    active_id="$id"
    active_status="$status"
    continue
  fi
  [[ "$age" -lt "$COOLDOWN_SECONDS" || "$run_sha" == "$sha" ]] || continue
  steps="$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --jq '[.jobs[].steps | length] | add // 0')" \
    || api_error "cannot read the jobs of run $id"
  if [[ "$steps" == 0 ]]; then
    echo "ignored: run $id never started (no job step ran)"
    continue
  fi
  if [[ "$age" -lt "$COOLDOWN_SECONDS" ]] && ! $cooling; then
    cooling=true
    refusals+=("run $id started $((age / 60)) min ago; wait an hour between runs")
  fi
  if [[ "$run_sha" == "$sha" ]]; then
    refusals+=("run $id already ran on ${sha:0:9} ($conclusion); report it in Proof, the owner decides on a rerun")
  fi
done <<<"$runs"

if [[ -n "$active_id" ]]; then
  echo "refused: run $active_id is $active_status; watch it instead: ./scripts/watch-checks.sh --run $active_id"
  exit 1
fi

if [[ ${#refusals[@]} -gt 0 ]]; then
  if [[ -z "$override" ]]; then
    for r in "${refusals[@]}"; do echo "refused: $r"; done
    exit 1
  fi
  echo "override: $override"
fi

if $dry_run; then
  echo "would dispatch UI Smoke on $branch"
  exit 0
fi

gh workflow run ui-smoke.yml --ref "$branch" || api_error "dispatch failed"
echo "dispatched UI Smoke on $branch; find the run with:"
echo "  gh run list --workflow ui-smoke.yml --branch $branch -L 1"
