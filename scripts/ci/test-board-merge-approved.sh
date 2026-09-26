#!/usr/bin/env bash
# Regression test for scripts/board/merge-approved.sh, the pass that merges
# a PR once the owner moves its card to Done (#763). No network: the board
# reply is a recorded one (fixtures/board/approved-prs-reply.json: the
# board's Status field and six real open PRs on 2026-09-26, recorded through
# the same PR fragment), gh is a stub that logs its calls, and the pre-merge
# check runs on a throwaway git remote.
#
# What it pins:
#   - each verdict on the recorded PRs, and the rule behind each: stacked,
#     waits: labels and drafts wait; running or missing required checks wait;
#     the newest run of a check counts, so a rerun that passed clears a
#     failure; a failed or cancelled check, a conflict or a fork PR goes back;
#     a waits: label holds a PR even when a check failed
#   - the pre-merge check: base current merges, behind main merges only when
#     main's changes miss the PR's files and the checks, a conflict or a
#     dependency pinned to a fork goes back, a head that moved waits
#   - the actions: merge with the checked sha, delete the branch, move the
#     card back before commenting the failed log, and move a hand-check card
#     to Needs human review on the next pass, not the merging one
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/board/merge-approved.sh"
REPLY="$ROOT_DIR/scripts/ci/fixtures/board/approved-prs-reply.json"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-board-merge-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

# decide_one <number> <jq edit of that PR's content> -> its verdict line
decide_one() {
  local n="$1" edit="$2"
  jq --argjson n "$n" "
    .data.user.projectV2.items.nodes |= map(select(.content.number == \$n))
    | .data.user.projectV2.items.nodes[0].content |= ($edit)" "$REPLY" >"$TMP_DIR/one.json"
  "$SCRIPT" --decide "$TMP_DIR/one.json"
}

# expect_one <description> <expected line> <number> <jq edit>
expect_one() {
  local got
  got="$(decide_one "$3" "$4")"
  [[ "$got" == "$2" ]] || fail "$1: expected '$2', got '$got'"
  pass "$1"
}

# A check run started after every recorded one.
newer() {
  printf '.commits.nodes[0].commit.statusCheckRollup.contexts.nodes += [{__typename: "CheckRun", name: "%s", status: "COMPLETED", conclusion: "%s", startedAt: "2026-09-27T09:00:00Z", detailsUrl: "https://example.invalid/%s", checkSuite: {workflowRun: {databaseId: 42, workflow: {name: "CI"}}}}]' "$1" "$2" "$1"
}

# --- Decisions on the recorded reply ---------------------------------------

got="$("$SCRIPT" --decide "$REPLY")"
expected='#795 wait: GitHub has not computed mergeability
#790 wait: build-test running
#796 wait: waits:mac-voxtral, waits:mac-llm, waits:mac-e2e
#568 wait: draft
#749 wait: waits:mac-llm
#797 wait: stacked on t/792-split-dogfood-flag'
[[ "$got" == "$expected" ]] || fail "recorded reply: got
$got"
pass "recorded reply: stacked, waits:, draft, running and unknown mergeability wait"

MERGEABLE='.mergeable = "MERGEABLE"'
expect_one "green and mergeable merges" \
  "#795 merge: checks green" 795 "$MERGEABLE"
expect_one "a newer failed run goes back" \
  "#795 back: build-test failed" 795 "$MERGEABLE | $(newer build-test FAILURE)"
expect_one "a cancelled run goes back" \
  "#795 back: mac-lanes failed" 795 "$MERGEABLE | $(newer mac-lanes CANCELLED)"
expect_one "a failed commit status goes back" \
  "#795 back: codecov failed" 795 "$MERGEABLE | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes += [{__typename: \"StatusContext\", context: \"codecov\", state: \"FAILURE\", targetUrl: \"https://example.invalid\"}]"
expect_one "a waits: label holds a PR with a failed check" \
  "#795 wait: waits:ci-red" 795 "$MERGEABLE | $(newer build-test FAILURE) | .labels.nodes += [{name: \"waits:ci-red\"}]"
expect_one "a fork PR goes back" \
  "#795 back: fork PR, merge it by hand" 795 "$MERGEABLE | .isCrossRepository = true"
expect_one "a conflict goes back" \
  "#749 back: conflicts with main" 749 '.isDraft = false | .labels.nodes = [] | .mergeable = "CONFLICTING"'
# #568 failed linux at 20:33 and passed its rerun at 20:54; mac-lanes only
# ran on drafts, so it was skipped.
expect_one "a rerun that passed clears the failure; a skipped mac-lanes waits" \
  "#568 wait: mac-lanes not green yet" 568 '.isDraft = false | .mergeable = "MERGEABLE"'
expect_one "a required check that never ran waits" \
  "#795 wait: linux not green yet" 795 "$MERGEABLE | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes |= map(select(.name != \"linux\"))"

# --- A full pass: pre-merge check and actions ------------------------------

# The remote: main is A, from before the recorded CI runs (2026-09-26), then
# B, which landed after them. Each PR is a refs/pull/<n>/head.
REMOTE="$TMP_DIR/remote"
git init -q -b main "$REMOTE"
g() { git -C "$REMOTE" -c user.name=t -c user.email=t@t "$@"; }
mkdir "$REMOTE/Sources"
printf '1\n2\n3\n4\n5\n' >"$REMOTE/Sources/c.txt"
echo 'dependencies.append(.package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"))' >"$REMOTE/Package.swift"
g add -A && GIT_COMMITTER_DATE=2026-09-01T00:00:00Z g commit -qm A
A="$(g rev-parse HEAD)"
sed -i.bak '1s/.*/one/' "$REMOTE/Sources/c.txt" && rm "$REMOTE/Sources/c.txt.bak"
GIT_COMMITTER_DATE=2026-09-27T10:00:00Z g commit -qam B
B="$(g rev-parse HEAD)"

# pr <number> <from> <shell edit run in the remote's tree>
pr() {
  g checkout -q --detach "$2"
  (cd "$REMOTE" && eval "$3")
  g add -A && g commit -qm "pr $1"
  g update-ref "refs/pull/$1/head" HEAD
  g checkout -q main
}
pr 1 "$B" 'echo new >b.txt'
pr 2 "$A" 'echo new >b.txt'
pr 3 "$A" "sed -i.bak '5s/.*/five/' Sources/c.txt && rm Sources/c.txt.bak"
pr 4 "$A" "sed -i.bak '1s/.*/uno/' Sources/c.txt && rm Sources/c.txt.bak"
pr 5 "$B" "sed -i.bak 's#Kentzo/ShortcutRecorder#someone/ShortcutRecorder#' Package.swift && rm Package.swift.bak"
pr 6 "$B" 'echo new >b.txt'
pr 7 "$B" 'echo new >b.txt'

head_of() {
  if [[ "$1" == 6 ]]; then
    echo "$A" # the query saw an older head than the ref now holds
  else
    g rev-parse "refs/pull/$1/head"
  fi
}

# Seven copies of #795 (green, mergeable), renumbered onto the remote's PRs.
# #1 has a hand check; #7 has a failed check with a log.
jq -c '.data.user.projectV2.items.nodes[] | select(.content.number == 795)' "$REPLY" >"$TMP_DIR/795.json"
for n in 1 2 3 4 5 6 7; do
  jq --argjson n "$n" --arg head "$(head_of "$n")" '
    .id = "ITEM\($n)" | .content.number = $n | .content.headRefOid = $head
    | .content.headRefName = "t/pr\($n)" | .content.title = "PR \($n)"
    | .content.mergeable = "MERGEABLE"
    | if $n == 1 then . else .content.labels.nodes = [] | .content.body = "" end
    | if $n == 7 then .content |= ('"$(newer linux FAILURE)"') else . end' "$TMP_DIR/795.json"
done | jq -s . >"$TMP_DIR/items.json"
jq --slurpfile items "$TMP_DIR/items.json" '.data.user.projectV2.items.nodes = $items[0]' \
  "$REPLY" >"$TMP_DIR/pass-reply.json"

# gh stub: the board query answers from a file, everything else is logged.
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
for arg in "$@"; do
  case "$arg" in
    query=@*approved-prs.graphql) cat "$STUB_REPLY"; exit 0 ;;
    body=@*) cat "${arg#body=@}" >>"$STUB_CALLS" ;;
  esac
done
case "$*" in
  "run view"*) printf 'linux\tRun core tests\t2026-09-27T09:01:00Z error: testThing failed\n' ;;
  *"pulls?state=open&base=t/pr2"*) echo 8 ;; # #8 is stacked on #2
  *"pulls?state=open&base="*) ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$TMP_DIR/bin/gh"

CLONE="$TMP_DIR/clone"
git clone -q "$REMOTE" "$CLONE"
run_pass() {
  (cd "$CLONE" && PATH="$TMP_DIR/bin:$PATH" STUB_CALLS="$TMP_DIR/calls" STUB_REPLY="$1" \
    LV_BOARD_REMOTE="$REMOTE" LV_BOARD_STATE_DIR="$TMP_DIR/state" "$SCRIPT")
}

: >"$TMP_DIR/calls"
got="$(run_pass "$TMP_DIR/pass-reply.json")"
expected="#1 merge: checks green
#1 merged
#2 merge: checks green
#2 merged
#8 retargeted to main
#3 wait: main changed Sources/c.txt since the CI run: run the combined check (orchestrate-sessions), then merge by hand
#4 back: conflicts with main
#4 moved back to Needs human review
#5 back: pins a dependency to a fork: https://github.com/someone/shortcutrecorder
#5 moved back to Needs human review
#6 wait: head moved to ${B:0:9} after the query
#7 back: linux failed
#7 moved back to Needs human review"
# #6's ref holds its own commit, not B; fix the expectation to that.
expected="${expected/${B:0:9}/$(g rev-parse refs/pull/6/head | cut -c1-9)}"
[[ "$got" == "$expected" ]] || fail "pass output: got
$got"
pass "pre-merge check: current, and behind with nothing shared since the CI run, merge; shared code waits; conflict and fork pin go back; a moved head waits"

calls="$(cat "$TMP_DIR/calls")"
grep -q "api -X PUT repos/T0mSIlver/localvoxtral/pulls/1/merge -f merge_method=squash -f sha=$(g rev-parse refs/pull/1/head) -f commit_title=PR 1 (#1)" <<<"$calls" \
  || fail "#1 merged without its checked sha: $calls"
retarget8="$(grep -n 'api -X PATCH repos/T0mSIlver/localvoxtral/pulls/8 -f base=main' <<<"$calls" | cut -d: -f1 || true)"
delete2="$(grep -n 'api -X DELETE repos/T0mSIlver/localvoxtral/git/refs/heads/t/pr2' <<<"$calls" | cut -d: -f1 || true)"
[[ -n "$retarget8" && -n "$delete2" && "$retarget8" -lt "$delete2" ]] || fail "#8 not retargeted before #2's branch went: $calls"
grep -q 'issues/8/labels/waits:stack' <<<"$calls" || fail "#8 kept waits:stack"
for n in 3 6; do
  ! grep -qE "pulls/$n/|issues/$n/|item=ITEM$n " <<<"$calls" || fail "#$n waits but was acted on"
done
[[ "$(grep -c 'pulls/[0-9]*/merge' <<<"$calls")" == 2 ]] || fail "expected two merges: $calls"
pass "merge uses the checked sha, retargets a stacked PR, then deletes the branch; waiting PRs are left alone"

move4="$(grep -n 'item=ITEM4 .*option=404d76ac' <<<"$calls" | cut -d: -f1 || true)"
comment4="$(grep -n 'issues/4/comments' <<<"$calls" | cut -d: -f1 || true)"
[[ -n "$move4" && -n "$comment4" && "$move4" -lt "$comment4" ]] || fail "#4: card not moved before the comment: $calls"
grep -q 'Moved back to Needs human review, not merged: linux failed.' <<<"$calls" || fail "#7 comment lacks the reason"
grep -q 'error: testThing failed' <<<"$calls" || fail "#7 comment lacks the failed log"
grep -q 'run view 42 --repo T0mSIlver/localvoxtral --log-failed' <<<"$calls" || fail "#7's failed run log not fetched"
pass "back moves the card, then comments the reason and the failed log"

! grep -q 'item=ITEM1 ' <<<"$calls" || fail "#1's hand-check card moved in the merging pass"
[[ "$(cat "$TMP_DIR/state/after-merge")" == "ITEM1 1" ]] || fail "#1 not queued for its hand check"
jq '.data.user.projectV2.items.nodes = []' "$REPLY" >"$TMP_DIR/empty.json"
: >"$TMP_DIR/calls"
got="$(run_pass "$TMP_DIR/empty.json")"
[[ "$got" == "#1 hand check: card moved to Needs human review" ]] || fail "next pass: got '$got'"
grep -q 'item=ITEM1 .*option=404d76ac' "$TMP_DIR/calls" || fail "#1's card not moved on the next pass"
[[ ! -s "$TMP_DIR/state/after-merge" ]] || fail "#1 still queued after its move"
pass "a merged PR with a hand check goes to Needs human review on the next pass"

echo "All merge-approved tests passed."
