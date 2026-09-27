#!/usr/bin/env bash
# Regression test for daily-release-plan.sh, the gate of the unattended daily
# release: it must ship only a main commit newer than the last stable tag on
# which the e2e dictation check scored and passed, and fail closed when it
# cannot tell.
#
# A throwaway git repo stands in for main; `gh` is a stub on PATH that applies
# the script's own --jq filters to canned JSON (needs jq).
#   ./scripts/ci/test-daily-release-plan.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PLAN="$ROOT_DIR/scripts/ci/daily-release-plan.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-daily-release-plan-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# main: c1 (v0.9.0) - c2 - c3 - c4 (HEAD); side: c1 - s1, never merged.
REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@"; }
commit() { g commit -q --allow-empty -m "$1"; g rev-parse HEAD; }
C1="$(commit c1)"
g tag -a v0.9.0 -m v0.9.0
g tag -a v0.9.1-nightly.20260926 -m nightly
g checkout -q -b side
S1="$(commit s1)"
g checkout -q main
C2="$(commit c2)"
C3="$(commit c3)"
C4="$(commit c4)"
GONE=cccccccccccccccccccccccccccccccccccccccc

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${SCEN:?}"
jq_filter="."
url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jq_filter="${args[i + 1]}" ;;
    repos/*) url="${args[i]}" ;;
  esac
done
echo "$url" >>"$SCEN/calls"
case "$url" in
  */actions/workflows/ui-smoke.yml/runs*)
    [[ ! -f "$SCEN/runs-fail" ]] || exit 1
    jq -r "$jq_filter" "$SCEN/runs.json"
    ;;
  */actions/runs/*/jobs)
    run_id="${url#*/actions/runs/}"
    run_id="${run_id%%/*}"
    [[ ! -f "$SCEN/jobs-fail" ]] || exit 1
    jq -r "$jq_filter" "$SCEN/jobs-$run_id.json"
    ;;
  *) echo "stub gh: unexpected api url: $url" >&2; exit 64 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# jobs_json <scored-step-conclusion|absent>: the dictation step is green
# either way, as a locked scheduled slot leaves it.
jobs_json() {
  local marker=""
  if [[ "$1" != absent ]]; then
    marker=",{\"name\":\"E2E dictation scored\",\"conclusion\":\"$1\"}"
  fi
  printf '{"jobs":[{"name":"e2e-dictation","steps":[{"name":"Run e2e dictation","conclusion":"success"}%s]}]}\n' "$marker"
}

# scenario <name> <run-id:sha:marker>... : UI Smoke runs on main, newest first.
scenario() {
  local dir="$TMP_DIR/$1"
  shift
  mkdir -p "$dir"
  : >"$dir/calls"
  local entry id rest sha marker runs=""
  for entry in "$@"; do
    id="${entry%%:*}"
    rest="${entry#*:}"
    sha="${rest%%:*}"
    marker="${rest#*:}"
    jobs_json "$marker" >"$dir/jobs-$id.json"
    runs="$runs${runs:+,}{\"id\":$id,\"head_sha\":\"$sha\"}"
  done
  printf '{"workflow_runs":[%s]}\n' "$runs" >"$dir/runs.json"
  printf '%s' "$dir"
}

# run_plan <dir> [ref]: runs the plan with main (or ref) checked out.
run_plan() {
  local dir="$1" ref="${2:-main}" status=0
  g checkout -q "$ref"
  (cd "$REPO" && SCEN="$dir" PATH="$STUB_BIN:$PATH" GITHUB_REPOSITORY=o/r "$PLAN") \
    >"$dir/out" 2>"$dir/err" || status=$?
  g checkout -q main
  return "$status"
}

field() { sed -n "s/^$1=//p" "$2/out"; }

dir="$(scenario nothing-new "1:$C1:success")"
run_plan "$dir" v0.9.0 || fail "nothing new: exited non-zero: $(cat "$dir/err")"
[[ "$(field run "$dir")" == false ]] || fail "nothing new: $(cat "$dir/out")"
grep -q "already released as v0.9.0" "$dir/out" || fail "nothing new says why: $(cat "$dir/out")"
[[ ! -s "$dir/calls" ]] || fail "nothing new still called the API: $(cat "$dir/calls")"
pass "main at the newest stable tag releases nothing and asks GitHub nothing"

dir="$(scenario newest-scored "4:$C4:absent" "3:$C3:skipped" "2:$C2:success" "1:$C1:success")"
run_plan "$dir" || fail "newest scored: exited non-zero: $(cat "$dir/err")"
[[ "$(field run "$dir")" == true ]] || fail "newest scored: $(cat "$dir/out")"
[[ "$(field sha "$dir")" == "$C2" ]] || fail "picked $(field sha "$dir"), expected c2 $C2"
[[ "$(field base "$dir")" == v0.9.0 ]] || fail "base is the stable tag, never the nightly: $(field base "$dir")"
grep -q "main is 2 commit(s) past it" "$dir/out" || fail "the reason says how far main moved: $(cat "$dir/out")"
grep -q "branch=main&status=completed&" "$dir/calls" || fail "runs are read from main, red ones included: $(cat "$dir/calls")"
pass "unscored runs are passed over; the newest scored commit ships, behind main's head"

dir="$(scenario head-scored "4:$C4:success" "2:$C2:success")"
run_plan "$dir" || fail "head scored: exited non-zero"
[[ "$(field sha "$dir")" == "$C4" ]] || fail "head scored picked $(field sha "$dir")"
grep -q "main is 0 commit(s) past it" "$dir/out" || fail "$(cat "$dir/out")"
pass "a scored run on main's head ships main's head"

dir="$(scenario only-released "4:$C4:absent" "1:$C1:success")"
run_plan "$dir" || fail "only released: exited non-zero"
[[ "$(field run "$dir")" == false ]] || fail "a scored run on the released commit shipped it again: $(cat "$dir/out")"
grep -q "no commit on main since v0.9.0 has passed the e2e dictation check; dispatch UI Smoke on main" "$dir/out" || fail "$(cat "$dir/out")"
grep -q "runs/1/jobs" "$dir/calls" && fail "a run on an already released commit cost a jobs call"
pass "a scored run on an already released commit does not count"

dir="$(scenario off-main "9:$S1:success" "8:$GONE:success" "7:not-a-sha:success")"
run_plan "$dir" || fail "off main: exited non-zero"
[[ "$(field run "$dir")" == false ]] || fail "a commit not on main shipped: $(cat "$dir/out")"
pass "scored runs on a commit off main, unknown or malformed are ignored"

dir="$(scenario runs-fail "2:$C2:success")"
touch "$dir/runs-fail"
if run_plan "$dir"; then fail "a failed runs query did not fail the plan: $(cat "$dir/out")"; fi
grep -q "^run=true" "$dir/out" && fail "a failed runs query said run=true"
pass "a failed runs query fails closed"

dir="$(scenario jobs-fail "2:$C2:success")"
touch "$dir/jobs-fail"
if run_plan "$dir"; then fail "a failed jobs query did not fail the plan: $(cat "$dir/out")"; fi
grep -q "^run=true" "$dir/out" && fail "a failed jobs query said run=true"
pass "a failed jobs query fails closed"

echo "OK: daily release plan"
