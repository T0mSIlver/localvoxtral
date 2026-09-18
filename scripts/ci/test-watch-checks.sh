#!/usr/bin/env bash
# Regression test for scripts/watch-checks.sh.
#
# What this protects: an agent runs watch-checks.sh right after `git push` and
# trusts exit 0 as "CI is green". For a few seconds after a push GitHub pairs
# the PR's new headRefOid with the PREVIOUS commit's check rollup, and has no
# workflow run for the new head at all. Exit 0 in that window (field report,
# PR #336) is a green nobody ran.
#
# `gh` and `ssh` are stubs on PATH; polling is driven by scripted responses
# (one file per poll, the last one repeats), never by the clock.
# Needs jq (the stub applies the script's own --jq filters to canned JSON).
#   ./scripts/ci/test-watch-checks.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
WATCH="$ROOT_DIR/scripts/watch-checks.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-watch-checks-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

OLD_SHA=9548d0916b78a0cf0273a0be7ae2e8797bae8eb4
NEW_SHA=0055865198e6c8ecb74422a4e580a379f1235976

# --- stubs ------------------------------------------------------------------

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

# Serves $SCEN/<key>.<n> for the n-th call with that key; when <key>.<n> is
# missing the highest-numbered earlier file repeats. Keys:
#   pr-view              JSON for `gh pr view` (run through the caller's --jq)
#   check-runs.<sha>     JSON for the commit's check-runs endpoint
#   status.<sha>         JSON for the commit's combined status (default: none)
#   run                  the `status/conclusion` line for `gh run view`
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${SCEN:?}"

serve() { # <key> <fallback-content>
  local key="$1" fallback="$2" n file
  n=$(($(cat "$SCEN/.count.$key" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$SCEN/.count.$key"
  while [[ $n -ge 1 ]]; do
    file="$SCEN/$key.$n"
    if [[ -f "$file" ]]; then cat "$file"; return; fi
    n=$((n - 1))
  done
  printf '%s\n' "$fallback"
}

jq_filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == --jq ]]; then jq_filter="${args[i + 1]}"; fi
done

case "$1 ${2:-}" in
  "pr view")
    serve pr-view '{}' | jq -r "$jq_filter"
    ;;
  "pr checks")
    # What the real gh printed in the field report.
    echo "no checks reported on the 'some' branch"
    exit 1
    ;;
  "run view")
    serve run 'queued/'
    ;;
  api\ *)
    url=""
    for a in "$@"; do
      case "$a" in repos/*) url="$a" ;; esac
    done
    sha="$(sed -E 's#.*/commits/([0-9a-f]+)/.*#\1#' <<<"$url")"
    case "$url" in
      */check-runs*) serve "check-runs.$sha" '{"total_count":0,"check_runs":[]}' | jq -r "$jq_filter" ;;
      */status*) serve "status.$sha" '{"state":"pending","statuses":[]}' | jq -r "$jq_filter" ;;
      *) echo "stub gh: unexpected api url: $url" >&2; exit 64 ;;
    esac
    ;;
  *)
    echo "stub gh: unexpected invocation: $*" >&2
    exit 64
    ;;
esac
STUB

# The build host always answers; fail-fast on a sleeping Mac is not under test.
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_BIN/ssh"
chmod +x "$STUB_BIN/gh" "$STUB_BIN/ssh"

# --- fixtures ---------------------------------------------------------------

check_runs() { # <name>:<status>:<conclusion|null>...
  local items=() spec name status conclusion
  for spec in "$@"; do
    IFS=: read -r name status conclusion <<<"$spec"
    [[ "$conclusion" == null ]] || conclusion="\"$conclusion\""
    items+=("{\"name\":\"$name\",\"status\":\"$status\",\"conclusion\":$conclusion,\"html_url\":\"https://example.invalid/$name\"}")
  done
  local joined
  joined="$(IFS=,; echo "${items[*]-}")"
  printf '{"total_count":%d,"check_runs":[%s]}\n' "$#" "$joined"
}

# The PR as `gh pr view` reports it: head <sha>, carrying the rollup GitHub
# attaches at that moment (which is NOT necessarily that head's).
GREEN_ROLLUP='[
  {"__typename":"CheckRun","name":"build-test","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"mac-lanes","status":"COMPLETED","conclusion":"SUCCESS"}]'
pr_view() { # <sha> <rollup-json>
  printf '{"headRefOid":"%s","statusCheckRollup":%s}\n' "$1" "$2"
}

new_scenario() {
  SCEN="$TMP_DIR/scen.$RANDOM$RANDOM"
  mkdir -p "$SCEN"
  export SCEN
}

# run_watch <grace-seconds> <args...>; sets RC and OUT (stdout+stderr).
run_watch() {
  local grace="$1"
  shift
  set +e
  OUT="$(PATH="$STUB_BIN:$PATH" LV_BUILD_HOST=stub-host LV_WATCH_INTERVAL=0 \
    LV_ZERO_CHECK_GRACE="$grace" "$WATCH" "$@" 2>&1)"
  RC=$?
  set -e
}

polls() { cat "$SCEN/.count.$1" 2>/dev/null || echo 0; }

expect_rc() {
  [[ "$RC" == "$1" ]] || fail "$2: expected exit $1, got $RC
$OUT"
}

# --- the field bug: new head, previous commit's green rollup, no run yet -----

new_scenario
pr_view "$NEW_SHA" "$GREEN_ROLLUP" >"$SCEN/pr-view.1"
check_runs build-test:completed:success mac-lanes:completed:success >"$SCEN/check-runs.$OLD_SHA.1"
check_runs >"$SCEN/check-runs.$NEW_SHA.1"
check_runs >"$SCEN/check-runs.$NEW_SHA.2"
check_runs build-test:in_progress:null mac-lanes:queued:null >"$SCEN/check-runs.$NEW_SHA.3"
check_runs build-test:completed:success mac-lanes:in_progress:null >"$SCEN/check-runs.$NEW_SHA.4"
check_runs build-test:completed:success mac-lanes:completed:success >"$SCEN/check-runs.$NEW_SHA.5"
run_watch 3600 336
expect_rc 0 "stale green rollup on a fresh head"
[[ "$(polls "check-runs.$NEW_SHA")" == 5 ]] \
  || fail "stale green rollup on a fresh head: passed after $(polls "check-runs.$NEW_SHA") polls of the head's checks, expected 5 (2 empty, 2 pending, 1 green)
$OUT"
grep -q "build-test is not registered yet" <<<"$OUT" \
  || fail "stale green rollup on a fresh head: never reported waiting for checks
$OUT"
[[ "$(polls "check-runs.$OLD_SHA")" == 0 ]] \
  || fail "the previous commit's checks were consulted"
pass "a fresh head with the previous commit's green rollup waits for its own checks, then passes"

# --- no check ever appears ---------------------------------------------------

new_scenario
pr_view "$NEW_SHA" "$GREEN_ROLLUP" >"$SCEN/pr-view.1"
run_watch 0 336
expect_rc 5 "no check ever appears"
grep -q "build-test never appeared on ${NEW_SHA:0:12}" <<<"$OUT" \
  || fail "no check ever appears: message does not name the head
$OUT"
if grep -q "^OK" <<<"$OUT"; then fail "no check ever appears: printed OK
$OUT"; fi
pass "zero checks past the grace window exits 5 with the head named, never OK"

# --- another check is green on the head before the CI run registers ----------
# (a bot check, or a dispatched run on the same SHA)

new_scenario
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.1"
check_runs some-bot:completed:success >"$SCEN/check-runs.$NEW_SHA.1"
check_runs some-bot:completed:success build-test:queued:null mac-lanes:queued:null >"$SCEN/check-runs.$NEW_SHA.2"
check_runs some-bot:completed:success build-test:completed:success mac-lanes:completed:success >"$SCEN/check-runs.$NEW_SHA.3"
run_watch 3600 336
expect_rc 0 "an unrelated green check before the CI run"
[[ "$(polls "check-runs.$NEW_SHA")" == 3 ]] \
  || fail "an unrelated green check before the CI run: passed after $(polls "check-runs.$NEW_SHA") polls, expected 3
$OUT"
pass "an unrelated green check does not pass a head whose build-test has not registered"

new_scenario
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.1"
check_runs some-bot:completed:success >"$SCEN/check-runs.$NEW_SHA.1"
run_watch 0 336
expect_rc 5 "only an unrelated green check, ever"
pass "a head that only ever gets an unrelated green check exits 5"

# --- ordinary outcomes on the pinned head ------------------------------------

new_scenario
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.1"
check_runs build-test:completed:success mac-lanes:completed:failure >"$SCEN/check-runs.$NEW_SHA.1"
run_watch 3600 336
expect_rc 1 "a failed check"
grep -q "mac-lanes" <<<"$OUT" || fail "a failed check: the failing check is not named
$OUT"
pass "a failed check exits 1 and names it"

new_scenario
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.1"
check_runs build-test:completed:success mac-lanes:completed:skipped >"$SCEN/check-runs.$NEW_SHA.1"
run_watch 3600 336
expect_rc 0 "success + skipped"
pass "success and skipped checks pass"

new_scenario
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.1"
check_runs build-test:completed:success >"$SCEN/check-runs.$NEW_SHA.1"
echo '{"state":"failure","statuses":[{"context":"legacy/status","state":"failure","target_url":null}]}' \
  >"$SCEN/status.$NEW_SHA.1"
run_watch 3600 336
expect_rc 1 "a failing commit status"
pass "a failing commit status (not a check run) exits 1"

# --- STALE-head detection survives -------------------------------------------

new_scenario
pr_view "$OLD_SHA" '[]' >"$SCEN/pr-view.1" # the initial pin
pr_view "$OLD_SHA" '[]' >"$SCEN/pr-view.2"
pr_view "$NEW_SHA" '[]' >"$SCEN/pr-view.3" # pushed while watching
check_runs build-test:in_progress:null >"$SCEN/check-runs.$OLD_SHA.1"
run_watch 3600 336
expect_rc 4 "head advanced while watching"
grep -q "STALE" <<<"$OUT" || fail "head advanced while watching: no STALE line
$OUT"
pass "a head that advances mid-watch exits 4 (STALE)"

# --- --run mode: a run id always has a status, so there is no empty set ------

new_scenario
echo "queued/" >"$SCEN/run.1"
echo "in_progress/" >"$SCEN/run.2"
echo "completed/success" >"$SCEN/run.3"
run_watch 3600 --run 123
expect_rc 0 "--run: queued -> success"
[[ "$(polls run)" == 3 ]] || fail "--run passed after $(polls run) polls, expected 3
$OUT"
pass "--run keeps polling a queued run and passes only on completed/success"

new_scenario
echo "completed/cancelled" >"$SCEN/run.1"
run_watch 3600 --run 123
expect_rc 1 "--run: cancelled"
pass "--run exits 1 on a non-success conclusion"

echo "OK: watch-checks tests passed"
