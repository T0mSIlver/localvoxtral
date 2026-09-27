#!/usr/bin/env bash
# The owner approves an open PR by moving its card on the project board
# (github.com/users/T0mSIlver/projects/1) from Needs human review to Done
# (#763). GitHub sends no event for a card move on a personal board, so the
# scheduler session runs one pass of this script every 10 minutes.
#
# One pass:
#   1. One GraphQL query, approved-prs.graphql (cost 1): every open PR whose
#      card says Done, with its labels, mergeability and checks.
#   2. Decide each PR (the jq program below, no network):
#        wait   stacked, a waits: label, draft, checks still running, or a
#               required check (build-test, linux, mac-lanes) not green yet
#        back   a failed check, a conflict with main, a fork PR
#        merge  everything green
#   3. For merge, the pre-merge check from the orchestrate-sessions skill, in
#      git (no API): the head is still the one the checks ran on, no
#      dependency is pinned to a fork, the combined tree has no conflict, and
#      what landed on main since the PR's CI run was created (CI tests the
#      merge with main as it was then) neither touches the PR's code nor
#      changes a check. Otherwise it waits for the scheduler's combined check.
#   4. Act: squash-merge, retarget PRs stacked on the branch to main (their
#      waits:stack label goes), then delete the branch. On back, move the card to
#      Needs human review and comment the failing output on the PR, so a card
#      never says Done on an unmerged PR for long. A merged PR with a hand
#      check (the needs-human-review label and Hand check steps in its body)
#      goes back to Needs human review on the next pass, after GitHub's
#      "Pull request merged" workflow has set it to Done.
#
# A PR that waits is printed every pass and left alone; the Done card stays,
# because the owner's OK still holds once the wait is over.
#
# Usage:
#   scripts/board/merge-approved.sh            one pass
#   scripts/board/merge-approved.sh --dry-run  query and decide, act on nothing
#   scripts/board/merge-approved.sh --decide <reply.json>
#                                              decide a recorded reply: no
#                                              network, no git (tests)
#
# stdout: one line per approved PR, `#<n> <verdict>: <reason>`, nothing when
# no card waits. Exit 1 when an action failed, 2 on usage or query error.
#
# Env: LV_BOARD_OWNER, LV_BOARD_NUMBER, LV_BOARD_REPO name the board and repo;
# LV_BOARD_REMOTE is the git remote to fetch from (origin); LV_BOARD_STATE_DIR
# keeps the after-merge moves between passes.
set -euo pipefail

OWNER="${LV_BOARD_OWNER:-T0mSIlver}"
NUMBER="${LV_BOARD_NUMBER:-1}"
REPO="${LV_BOARD_REPO:-T0mSIlver/localvoxtral}"
REMOTE="${LV_BOARD_REMOTE:-origin}"
STATE_DIR="${LV_BOARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/localvoxtral-board}"
BACK_STATUS="Needs human review"
DIR="$(cd "$(dirname "$0")" && pwd -P)"

usage() {
  sed -n '/^# Usage:/,/^# stdout/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# Reads the query reply on stdin, prints one JSON object per approved PR.
DECIDE='
def ok: . == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL";
def failed: . == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED"
  or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE" or . == "STALE"
  or . == "ERROR";
def checks:
  [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
   | if .__typename == "CheckRun" then
       {name, workflow: (.checkSuite.workflowRun.workflow.name // ""),
        run: .checkSuite.workflowRun.databaseId, url: .detailsUrl,
        created: .checkSuite.workflowRun.createdAt,
        started: (.startedAt // "9999"),
        state: (if .status == "COMPLETED" then .conclusion else "PENDING" end)}
     else
       {name: .context, workflow: "status", run: null, url: .targetUrl, created: null,
        started: "", state: (if .state == "EXPECTED" then "PENDING" else .state end)}
     end]
  # A rerun adds a check run on the same commit; the newest one counts.
  | group_by([.workflow, .name]) | map(max_by(.started));
def names: map(.name) | unique | join(", ");
.data.user.projectV2.items.nodes[]
| .id as $item
| .content
| select(.number != null)
| checks as $checks
| ($checks | map(select(.state | failed))) as $failed
| ($checks | map(select((.state | ok | not) and (.state | failed | not)))) as $running
| ([.labels.nodes[].name | select(startswith("waits:"))]) as $waits
| (["build-test", "linux", "mac-lanes"]
   | map(. as $n | select([$checks[] | select(.workflow == "CI" and .name == $n
                                             and .state == "SUCCESS")] | length == 0))
  ) as $missing
| {number, item: $item, title, head: .headRefOid, branch: .headRefName,
   hand_check: ((.labels.nodes | any(.name == "needs-human-review"))
                and ((.body // "") | test("Hand check[\\s\\S]*\\n\\s*1\\.\\s"))),
   ci_created: ([$checks[] | select(.workflow == "CI") | .created // empty] | max),
   failed: []}
+ if .baseRefName != "main" then {verdict: "wait", reason: "stacked on \(.baseRefName)"}
  elif ($waits | length) > 0 then {verdict: "wait", reason: ($waits | join(", "))}
  elif .isDraft then {verdict: "wait", reason: "draft"}
  elif .isCrossRepository then {verdict: "back", reason: "fork PR, merge it by hand"}
  elif .mergeable == "CONFLICTING" then {verdict: "back", reason: "conflicts with main"}
  elif ($failed | length) > 0 then
    {verdict: "back", reason: "\($failed | names) failed", failed: $failed}
  elif ($running | length) > 0 then {verdict: "wait", reason: "\($running | names) running"}
  elif .mergeable != "MERGEABLE" then {verdict: "wait", reason: "GitHub has not computed mergeability"}
  elif ($missing | length) > 0 then {verdict: "wait", reason: "\($missing | join(", ")) not green yet"}
  else {verdict: "merge", reason: "checks green"}
  end
'

decide() {
  jq -c "$DECIDE"
}

MODE=pass
case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry ;;
  --decide)
    [[ $# -eq 2 ]] || usage
    decide <"$2" | jq -r '"#\(.number) \(.verdict): \(.reason)"'
    exit 0
    ;;
  *) usage ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-board.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
STATUS=0

graphql() {
  gh api graphql "$@"
}

# set_status <item-id> <option-id>
set_status() {
  graphql -f project="$PROJECT_ID" -f item="$1" -f field="$FIELD_ID" -f option="$2" \
    -f query='mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item,
        fieldId: $field, value: {singleSelectOptionId: $option}}) { clientMutationId } }' \
    >/dev/null
}

# URLs of the package dependencies at a commit, lowercased, one per line.
dependency_urls() {
  local commit="$1" path
  git ls-tree -r --name-only "$commit" \
    | grep -E '(^|/)Package\.(swift|resolved)$' \
    | while read -r path; do
        git show "$commit:$path" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || true
      done \
    | sed -E 's/\.git$//' | tr 'A-Z' 'a-z' | sort -u
}

# A URL the PR adds whose repo name main already takes from another owner, or
# one under the board owner's account: a dependency pinned to a fork.
fork_pins() {
  local main_urls pr_urls url repo owner
  main_urls="$(dependency_urls "$1")"
  pr_urls="$(dependency_urls "$2")"
  owner="$(tr 'A-Z' 'a-z' <<<"$OWNER")"
  while read -r url; do
    [[ -n "$url" ]] || continue
    grep -qxF "$url" <<<"$main_urls" && continue
    repo="${url##*/}"
    if [[ "$url" == "https://github.com/$owner/"* ]] \
      || grep -qE "/[^/]+/${repo//./\\.}\$" <<<"$main_urls"; then
      echo "$url"
    fi
  done <<<"$pr_urls"
}

# premerge <number> <head-oid> <ci-run-created>: the pre-merge check. Prints
# "merge", or a verdict and reason ("wait <reason>" / "back <reason>").
premerge() {
  local n="$1" head="$2" created="$3" main pr pins landed shared
  git fetch -q "$REMOTE" "+refs/heads/main:refs/board/main" "+refs/pull/$n/head:refs/board/pr$n"
  main="$(git rev-parse refs/board/main)"
  pr="$(git rev-parse "refs/board/pr$n")"
  if [[ "$pr" != "$head" ]]; then
    echo "wait head moved to ${pr:0:9} after the query"
    return
  fi
  pins="$(fork_pins "$main" "$pr" | tr '\n' ' ')"
  if [[ -n "$pins" ]]; then
    echo "back pins a dependency to a fork: ${pins% }"
    return
  fi
  if ! git merge-tree --write-tree "$main" "$pr" >/dev/null 2>&1; then
    echo "back conflicts with main"
    return
  fi
  # CI tested the merge with main as it was when the run was created. That
  # still holds unless what landed since touches a file the PR changes or
  # changes a check the PR never ran.
  landed="$(git log --since="$created" --format= --name-only "$main" | sed '/^$/d' | sort -u)"
  shared="$(
    {
      grep -E '^(\.github/|scripts/ci/)' <<<"$landed" || true
      comm -12 <(echo "$landed") <(git diff --name-only "$(git merge-base "$main" "$pr")" "$pr" | sort -u)
    } | sort -u | head -5 | tr '\n' ' '
  )"
  if [[ -n "$shared" ]]; then
    echo "wait main changed ${shared% } since the CI run: run the combined check (a hosted combo PR, orchestrate-sessions), then merge by hand"
    return
  fi
  echo merge
}

# comment_back <decision-json> <reason>
comment_back() {
  local decision="$1" reason="$2" n body="$TMP_DIR/comment.md" run name
  n="$(jq -r .number <<<"$decision")"
  {
    printf 'Moved back to %s, not merged: %s.\n' "$BACK_STATUS" "$reason"
    while IFS=$'\t' read -r name run url; do
      printf '\n<details><summary>%s failed: %s</summary>\n\n```\n' "$name" "$url"
      if [[ "$run" != "null" ]]; then
        gh run view "$run" --repo "$REPO" --log-failed 2>&1 | cut -f3- | tail -n 40 || true
      fi
      printf '```\n</details>\n'
    done < <(jq -r '.failed[] | [.name, (.run | tostring), .url] | @tsv' <<<"$decision")
    printf '\nOnce it is fixed, the owner moves the card to Done again (#763).\n'
  } >"$body"
  gh api "repos/$REPO/issues/$n/comments" -F body=@"$body" >/dev/null
}

# merge_pr <decision-json>
merge_pr() {
  local decision="$1" n head branch title stacked s
  n="$(jq -r .number <<<"$decision")"
  head="$(jq -r .head <<<"$decision")"
  branch="$(jq -r .branch <<<"$decision")"
  title="$(jq -r .title <<<"$decision")"
  gh api -X PUT "repos/$REPO/pulls/$n/merge" -f merge_method=squash -f sha="$head" \
    -f commit_title="$title (#$n)" >/dev/null || return 1
  echo "#$n merged"
  # Deleting a PR's base branch closes that PR: retarget first.
  if ! stacked="$(gh api --paginate "repos/$REPO/pulls?state=open&base=$branch&per_page=100" --jq '.[].number')"; then
    echo "#$n merged, but listing PRs stacked on it failed; $branch kept" >&2
    return 2
  fi
  for s in $stacked; do
    gh api -X PATCH "repos/$REPO/pulls/$s" -f base=main >/dev/null \
      || { echo "#$n merged, but retargeting #$s failed; $branch kept" >&2; return 2; }
    gh api -X DELETE "repos/$REPO/issues/$s/labels/waits:stack" >/dev/null 2>&1 || true
    echo "#$s retargeted to main"
  done
  gh api -X DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null 2>&1 \
    || { echo "#$n merged, but deleting $branch failed" >&2; return 2; }
}

REPLY="$TMP_DIR/reply.json"
if ! graphql -F owner="$OWNER" -F number="$NUMBER" -F query=@"$DIR/approved-prs.graphql" >"$REPLY"; then
  echo "board query failed" >&2
  exit 2
fi
PROJECT_ID="$(jq -r '.data.user.projectV2.id' "$REPLY")"
FIELD_ID="$(jq -r '.data.user.projectV2.field.id' "$REPLY")"
BACK_OPTION="$(jq -r --arg name "$BACK_STATUS" \
  'first(.data.user.projectV2.field.options[] | select(.name == $name) | .id) // empty' "$REPLY")"

# Hand-check cards of PRs merged on an earlier pass: GitHub's merged workflow
# has set them to Done by now.
AFTER_MERGE="$STATE_DIR/after-merge"
if [[ "$MODE" == pass && -s "$AFTER_MERGE" ]]; then
  : >"$TMP_DIR/after-merge-left"
  while read -r item n; do
    if [[ -n "$BACK_OPTION" ]] && set_status "$item" "$BACK_OPTION"; then
      echo "#$n hand check: card moved to $BACK_STATUS"
    else
      echo "$item $n" >>"$TMP_DIR/after-merge-left"
      echo "#$n hand check: moving the card to $BACK_STATUS failed" >&2
      STATUS=1
    fi
  done <"$AFTER_MERGE"
  mv "$TMP_DIR/after-merge-left" "$AFTER_MERGE"
fi

# fd 3: gh and git in the loop must not eat the decisions.
while read -r decision <&3; do
  n="$(jq -r .number <<<"$decision")"
  verdict="$(jq -r .verdict <<<"$decision")"
  reason="$(jq -r .reason <<<"$decision")"
  if [[ "$verdict" == merge ]]; then
    check="$(premerge "$n" "$(jq -r .head <<<"$decision")" "$(jq -r .ci_created <<<"$decision")")" \
      || check="wait the pre-merge check failed to run"
    verdict="${check%% *}"
    [[ "$verdict" == merge ]] || reason="${check#* }"
  fi
  echo "#$n $verdict: $reason"
  [[ "$MODE" == pass ]] || continue

  case "$verdict" in
    merge)
      # 0 merged, 1 not merged, 2 merged but the branch cleanup stopped.
      merged=0
      merge_pr "$decision" || merged=$?
      if [[ "$merged" == 1 ]]; then
        echo "#$n merge failed" >&2
        STATUS=1
        continue
      fi
      [[ "$merged" == 0 ]] || STATUS=1
      if [[ "$(jq -r .hand_check <<<"$decision")" == true ]]; then
        mkdir -p "$STATE_DIR"
        echo "$(jq -r .item <<<"$decision") $n" >>"$AFTER_MERGE"
      fi
      ;;
    back)
      # Move first: a comment without the move would repeat every pass.
      if [[ -z "$BACK_OPTION" ]]; then
        echo "#$n not moved back: the board has no $BACK_STATUS status" >&2
        STATUS=1
      elif set_status "$(jq -r .item <<<"$decision")" "$BACK_OPTION"; then
        comment_back "$decision" "$reason" || { echo "#$n moved back, comment failed" >&2; STATUS=1; }
        echo "#$n moved back to $BACK_STATUS"
      else
        echo "#$n moving the card back failed" >&2
        STATUS=1
      fi
      ;;
  esac
done 3< <(decide <"$REPLY")

if [[ "$(jq -r '.data.user.projectV2.items.pageInfo.hasNextPage' "$REPLY")" == true ]]; then
  echo "more than 50 open PRs in Done: this pass saw the first 50" >&2
  STATUS=1
fi

exit "$STATUS"
