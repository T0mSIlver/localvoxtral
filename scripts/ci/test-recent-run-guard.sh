#!/usr/bin/env bash
# Tests recent-run-guard.sh against canned workflow-run lists: `gh` is a stub
# on PATH and the clock is pinned through RECENT_RUN_GUARD_NOW (needs jq).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/recent-run-guard.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-recent-run-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: records the URL, then prints $STUB_RUNS or fails.
printf '%s\n' "$*" >"$STUB_ARGS_FILE"
if [[ -n "${STUB_FAIL:-}" ]]; then
  echo "HTTP 403: Resource not accessible by integration" >&2
  exit 1
fi
printf '%s\n' "$STUB_RUNS"
STUB
chmod +x "$TMP_DIR/bin/gh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# 2026-10-04T04:45:00Z, the Sunday slot. SELF is the run asking.
NOW=1791089100
SELF=900

# run <id> <event> <status> <conclusion|null> <created_at>
run() {
  local conclusion="$4"
  [[ "$conclusion" == null ]] || conclusion="\"$conclusion\""
  printf '{"id":%s,"event":"%s","status":"%s","conclusion":%s,"created_at":"%s"}' \
    "$1" "$2" "$3" "$conclusion" "$5"
}
runs() {
  local IFS=,
  printf '{"workflow_runs":[%s]}' "$*"
}

# expect <expected run=> <description> <runs json> [env overrides...]
expect() {
  local expected="$1" description="$2" json="$3"
  shift 3
  local output run reason
  output="$(env "PATH=$TMP_DIR/bin:$PATH" STUB_ARGS_FILE="$TMP_DIR/args" \
    STUB_RUNS="$json" RECENT_RUN_GUARD_NOW="$NOW" \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID="$SELF" "$@" \
    "$GUARD" eval-e2e.yml 20)" || fail "$description: guard exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

SELF_RUN="$(run $SELF schedule in_progress null 2026-10-04T04:45:00Z)"

expect true "no other run: the cron measures" "$(runs "$SELF_RUN")"
grep -q 'repos/owner/repo/actions/workflows/eval-e2e.yml/runs?branch=main' "$TMP_DIR/args" \
  || fail "the guard did not ask for eval-e2e.yml's runs on main: $(cat "$TMP_DIR/args")"
expect false "the scheduler's dispatch succeeded an hour ago" \
  "$(runs "$SELF_RUN" "$(run 801 workflow_dispatch completed success 2026-10-04T03:45:00Z)")"
expect false "the scheduler's dispatch is still running" \
  "$(runs "$SELF_RUN" "$(run 802 workflow_dispatch in_progress null 2026-10-04T04:44:00Z)")"
expect false "a dispatch waits in the queue" \
  "$(runs "$SELF_RUN" "$(run 803 workflow_dispatch queued null 2026-10-04T04:40:00Z)")"
expect true "a failed dispatch does not count" \
  "$(runs "$SELF_RUN" "$(run 804 workflow_dispatch completed failure 2026-10-04T03:45:00Z)")"
expect true "a cancelled dispatch does not count" \
  "$(runs "$SELF_RUN" "$(run 805 workflow_dispatch completed cancelled 2026-10-04T03:45:00Z)")"
expect true "a success older than 20 h does not count" \
  "$(runs "$SELF_RUN" "$(run 806 workflow_dispatch completed success 2026-10-03T08:44:00Z)")"
expect false "a success just inside 20 h counts" \
  "$(runs "$SELF_RUN" "$(run 807 workflow_dispatch completed success 2026-10-03T08:46:00Z)")"
expect true "the run asking is not its own cover" \
  "$(runs "$(run $SELF schedule in_progress null 2026-10-04T04:45:00Z)")"
expect true "a failed query fails open" "{}" STUB_FAIL=1
expect true "an unreadable reply fails open" "not json"
