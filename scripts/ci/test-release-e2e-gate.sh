#!/usr/bin/env bash
# Regression test for the e2e gate in scripts/release.sh.
#
# What this protects: the e2e dictation check left PR time for release time
# (#574), so a stable release must refuse unless a UI Smoke run on the
# release commit scored and passed it. A run whose dictation step went green
# without scoring (a scheduled slot on a locked Mac, exit 3) must not count,
# and nightlies and rehearsals must not be gated. Each case is pinned here
# through --dry-run, and so is the dispatch-time check that the ref did not
# move after the gate passed.
#
# `gh` is a stub on PATH that applies the script's own --jq filters to canned
# JSON (needs jq).
#   ./scripts/ci/test-release-e2e-gate.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RELEASE="$ROOT_DIR/scripts/release.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-release-e2e-gate-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${SCEN:?}"
echo "$*" >>"$SCEN/calls"
jq_filter="."
url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jq_filter="${args[i + 1]}" ;;
    repos/*) url="${args[i]}" ;;
  esac
done
case "$1 ${2:-}" in
  "workflow run") echo "$*" >>"$SCEN/dispatched" ;;
  "run list") jq -r "$jq_filter" <<<'[{"databaseId":900}]' ;;
  "run view") jq -r "$jq_filter" <<<"{\"headSha\":\"$(cat "$SCEN/dispatched-sha")\"}" ;;
  "run cancel") echo "$*" >>"$SCEN/cancelled" ;;
  "run watch") ;;
  api\ *)
    case "$url" in
      */commits/*) jq -r "$jq_filter" <<<"{\"sha\":\"$(cat "$SCEN/ref-sha")\"}" ;;
      */actions/workflows/ui-smoke.yml/runs*)
        echo "$url" >"$SCEN/runs-url"
        jq -r "$jq_filter" "$SCEN/runs.json"
        ;;
      */actions/runs/*/jobs*)
        run_id="${url#*/actions/runs/}"
        run_id="${run_id%%/*}"
        jq -r "$jq_filter" "$SCEN/jobs-$run_id.json"
        ;;
      *) echo "stub gh: unexpected api url: $url" >&2; exit 64 ;;
    esac
    ;;
  *) echo "stub gh: unexpected invocation: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
# release.sh waits 5 s for the dispatched run to appear; not here.
printf '#!/bin/sh\nexit 0\n' >"$STUB_BIN/sleep"
chmod +x "$STUB_BIN/sleep"

# jobs_json <scored-step-conclusion|absent>: one UI Smoke run's jobs, with the
# dictation step green either way, as a locked scheduled slot leaves it.
jobs_json() {
  local marker=""
  if [[ "$1" != absent ]]; then
    marker=",{\"name\":\"E2E dictation scored\",\"conclusion\":\"$1\"}"
  fi
  printf '{"jobs":[{"name":"ui-smoke","steps":[{"name":"Run AX UI smoke","conclusion":"success"}]},{"name":"e2e-dictation","steps":[{"name":"Run e2e dictation","conclusion":"success"}%s]}]}\n' "$marker"
}

# scenario <name> <run-id:marker>... : UI Smoke runs on the release commit,
# newest first. The ref points at HEAD_SHA.
scenario() {
  local dir="$TMP_DIR/$1"
  shift
  mkdir -p "$dir"
  echo "$HEAD_SHA" >"$dir/ref-sha"
  echo "$HEAD_SHA" >"$dir/dispatched-sha"
  local ids=() entry
  for entry in "$@"; do
    ids+=("${entry%%:*}")
    jobs_json "${entry#*:}" >"$dir/jobs-${entry%%:*}.json"
  done
  printf '{"workflow_runs":[%s]}\n' \
    "$(printf '%s\n' "${ids[@]+"${ids[@]}"}" | jq -R 'select(length > 0) | {id: tonumber}' | jq -sc '.[]' | paste -sd, -)" \
    >"$dir/runs.json"
  printf '%s' "$dir"
}

# expect <exit> <description> <dir> <release.sh args>...
expect() {
  local expected="$1" description="$2" dir="$3"
  shift 3
  local status=0
  SCEN="$dir" PATH="$STUB_BIN:$PATH" "$RELEASE" "$@" >"$dir/out" 2>&1 || status=$?
  [[ "$status" == "$expected" ]] \
    || fail "$description: expected exit $expected, got $status: $(cat "$dir/out")"
  pass "$description"
}

dir="$(scenario no-run)"
expect 1 "a stable release with no UI Smoke run on its commit is refused" "$dir" --dry-run patch
grep -q "Refused: the e2e dictation check has not passed on main at aaaaaaaaa" "$dir/out" \
  || fail "the refusal names the ref and commit: $(cat "$dir/out")"
grep -q "gh workflow run ui-smoke.yml --ref main" "$dir/out" \
  || fail "the refusal says how to run the check: $(cat "$dir/out")"
grep -q "head_sha=$HEAD_SHA" "$dir/runs-url" || fail "the runs are looked up by the release commit"
[[ ! -f "$dir/dispatched" ]] || fail "a refused release dispatched"

dir="$(scenario unscored 11:absent 12:skipped)"
expect 1 "a run whose dictation went green unscored does not count" "$dir" --dry-run 1.2.3

dir="$(scenario scored-older 21:absent 22:success)"
expect 0 "a scored run on the release commit lets the release through" "$dir" --dry-run minor
grep -q "e2e dictation check: passed on aaaaaaaaa in UI Smoke run 22" "$dir/out" \
  || fail "the pass names the run: $(cat "$dir/out")"
grep -q "Dry run: would dispatch Release App (minor, ref=main, publish=true)" "$dir/out" \
  || fail "the dry run says what it would dispatch: $(cat "$dir/out")"
[[ ! -f "$dir/dispatched" ]] || fail "a dry run dispatched"

dir="$(scenario rc-branch)"
expect 1 "a release candidate from a branch is gated too" "$dir" --dry-run 1.2.3-rc.1 t/feature
grep -q "commits/t%2Ffeature" "$dir/calls" || fail "the branch name is URI-encoded"

dir="$(scenario nightly)"
expect 0 "a nightly is not gated" "$dir" --dry-run nightly
dir="$(scenario rehearsal)"
expect 0 "a rehearsal is not gated" "$dir" --dry-run rehearse patch
grep -q "not required for a nightly or a rehearsal" "$dir/out" || fail "the skip says why"

dir="$(scenario dispatch 31:success)"
expect 0 "a gated release dispatches and watches its run" "$dir" patch
grep -q "workflow run Release App --ref main -f channel=stable -f bump=patch -f publish=true" "$dir/dispatched" \
  || fail "dispatched: $(cat "$dir/dispatched")"
[[ ! -f "$dir/cancelled" ]] || fail "a run on the checked commit was cancelled"

dir="$(scenario moved 41:success)"
echo "$OTHER_SHA" >"$dir/dispatched-sha"
expect 1 "a ref that moved after the check has its run cancelled" "$dir" patch
grep -q "run cancel 900" "$dir/cancelled" || fail "the moved run was not cancelled"
grep -q "main moved to bbbbbbbbb after the e2e dictation check passed on aaaaaaaaa" "$dir/out" \
  || fail "the refusal names both commits: $(cat "$dir/out")"

echo "OK: release e2e gate"
