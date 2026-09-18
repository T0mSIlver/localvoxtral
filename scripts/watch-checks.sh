#!/usr/bin/env bash
set -uo pipefail

# Watch a PR's checks (or a single workflow run) without eating GitHub's
# ~10-minute "runner lost communication" window when the Mac build host
# falls asleep.
#
# `gh pr checks --watch` / `gh run watch` poll silently while a queued or
# in-flight job sits on a dead self-hosted runner; GitHub only fails the job
# ~10 minutes after it lost contact, and a queued job just sits forever.
# This wrapper polls the same status AND probes the build host over SSH, so
# a sleeping Mac is reported within two probe intervals (~30 s) instead.
#
# Usage:
#   scripts/watch-checks.sh <pr-number>      # watch a PR's checks
#   scripts/watch-checks.sh --run <run-id>   # watch a workflow run (push/rerun)
#
# Env: LV_BUILD_HOST overrides the probed host; LV_WATCH_INTERVAL poll seconds;
# LV_ZERO_CHECK_GRACE seconds to wait for the required check to appear;
# LV_REQUIRED_CHECK its name (default build-test).
#
# Exit codes:
#   0  checks/run succeeded
#   1  checks/run concluded with failures
#   2  usage or gh query error
#   3  fail-fast: build host unreachable while work is pending
#   4  PR head advanced while watching
#   5  the required check never appeared on the PR head

usage() {
  echo "usage: $0 <pr-number> | --run <run-id>" >&2
  exit 2
}

MODE=pr
TARGET=""
case "${1:-}" in
  "") usage ;;
  --run)
    MODE=run
    TARGET="${2:-}"
    [[ -n "$TARGET" ]] || usage
    ;;
  -*) usage ;;
  *) TARGET="$1" ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${LV_BUILD_HOST:-$(git -C "$ROOT_DIR" config --get localvoxtral.buildhost || true)}"
INTERVAL="${LV_WATCH_INTERVAL:-15}"
ZERO_CHECK_GRACE="${LV_ZERO_CHECK_GRACE:-180}"
# build-test runs for every event and contributor, docs-only fast path
# included, so a head without it has no CI run yet — whatever else (a bot
# check, a dispatched run on the same SHA) already went green there.
REQUIRED_CHECK="${LV_REQUIRED_CHECK:-build-test}"

# gh resolves the repository (and {owner}/{repo}) from the working directory.
cd "$ROOT_DIR" || exit 2

# Reachable means SSH answered at all: 0 = gate v2 ran `diag`, 126 = gate
# denied the command (v1) — both prove the Mac is awake. 255 (connection
# failure) and 124 (timeout) mean asleep/unreachable.
probe_host() {
  [[ -n "$HOST" ]] || return 0 # no host configured — never fail-fast
  timeout 12 ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" diag >/dev/null 2>&1
  local rc=$?
  [[ $rc -ne 255 && $rc -ne 124 ]]
}

# Checks are read for the pinned head SHA, never through the PR. The PR's own
# rollup (`gh pr view --json statusCheckRollup`, `gh pr checks`) belongs to the
# last commit in the PR's commit list, which lags headRefOid after a push: for
# a few seconds it pairs the new head with the previous commit's checks, and a
# green previous commit read as "all checks passed" on a head with no run yet.
#
# Sets current_sha and check_rows (name, pending|pass|fail, detail, url per
# line); on failure sets query_error and returns non-zero.
query_pr() {
  local runs statuses
  if ! current_sha="$(gh pr view "$TARGET" --json headRefOid --jq '.headRefOid' 2>&1)"; then
    query_error="$current_sha"
    return 1
  fi
  if ! runs="$(gh api --paginate "repos/{owner}/{repo}/commits/$TARGET_SHA/check-runs?per_page=100" --jq '
    .check_runs[] | [
      .name,
      (if .status != "completed" then "pending"
       elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "pass"
       else "fail" end),
      (.conclusion // .status),
      (.html_url // "")
    ] | @tsv' 2>&1)"; then
    query_error="$runs"
    return 1
  fi
  if ! statuses="$(gh api --paginate "repos/{owner}/{repo}/commits/$TARGET_SHA/status?per_page=100" --jq '
    .statuses[] | [
      .context,
      (if .state == "pending" then "pending" elif .state == "success" then "pass" else "fail" end),
      .state,
      (.target_url // "")
    ] | @tsv' 2>&1)"; then
    query_error="$statuses"
    return 1
  fi
  check_rows="$runs"
  if [[ -n "$statuses" ]]; then
    check_rows="${check_rows:+$check_rows$'\n'}$statuses"
  fi
}

print_checks() {
  local name bucket detail url
  while IFS=$'\t' read -r name bucket detail url; do
    [[ -n "$name" ]] || continue
    printf '%-8s %-24s %-12s %s\n' "$bucket" "$name" "$detail" "$url"
  done <<<"$check_rows"
}

if [[ "$MODE" == run ]]; then
  echo "== watching run $TARGET (build host: ${HOST:-none}) =="
else
  echo "== watching PR #$TARGET checks (build host: ${HOST:-none}) =="
  if ! TARGET_SHA="$(gh pr view "$TARGET" --json headRefOid --jq '.headRefOid' 2>&1)"; then
    echo "FAIL: could not query PR #$TARGET via gh:" >&2
    echo "  $TARGET_SHA" >&2
    exit 2
  fi
fi

misses=0
pending_since=$SECONDS
zero_checks_since=""
query_failures=0
warned_runner_down=0
while :; do
  status_desc=""
  if [[ "$MODE" == run ]]; then
    if ! line="$(gh run view "$TARGET" --json status,conclusion \
      --template '{{.status}}/{{.conclusion}}' 2>&1)"; then
      echo "FAIL: could not query run $TARGET via gh:" >&2
      echo "  $line" >&2
      exit 2
    fi
    case "$line" in
      completed/success)
        echo "OK: run $TARGET succeeded"
        exit 0
        ;;
      completed/*)
        echo "FAIL: run $TARGET finished: ${line#completed/}" >&2
        exit 1
        ;;
    esac
    status_desc="run is $line"
  else
    if ! query_pr; then
      # GitHub throws transient 5xx-style errors (observed killing a watch
      # mid-run); only give up after several consecutive failures.
      query_failures=$((query_failures + 1))
      if [[ $query_failures -ge 4 ]]; then
        echo "FAIL: could not query PR #$TARGET via gh ($query_failures consecutive failures):" >&2
        echo "  $query_error" >&2
        exit 2
      fi
      echo "gh query failed (attempt $query_failures/3, retrying): ${query_error%%$'\n'*}"
      sleep "$INTERVAL"
      continue
    fi
    query_failures=0
    check_count=0
    pending_count=0
    failing_count=0
    required_seen=0
    while IFS=$'\t' read -r name bucket _; do
      [[ -n "$bucket" ]] || continue
      [[ "$name" != "$REQUIRED_CHECK" ]] || required_seen=1
      check_count=$((check_count + 1))
      case "$bucket" in
        pending) pending_count=$((pending_count + 1)) ;;
        fail) failing_count=$((failing_count + 1)) ;;
      esac
    done <<<"$check_rows"

    if [[ "$current_sha" != "$TARGET_SHA" ]]; then
      echo "STALE: PR #$TARGET head advanced from ${TARGET_SHA:0:12} to ${current_sha:0:12}; re-run watch-checks.sh" >&2
      exit 4
    fi

    if [[ "$required_seen" == 0 ]]; then
      if [[ -z "$zero_checks_since" ]]; then
        zero_checks_since=$SECONDS
      fi
      elapsed_zero=$((SECONDS - zero_checks_since))
      if [[ $elapsed_zero -lt $ZERO_CHECK_GRACE ]]; then
        print_checks
        echo "$REQUIRED_CHECK is not registered yet ($check_count other checks) -- waiting for GitHub... (${elapsed_zero}s/${ZERO_CHECK_GRACE}s)"
        status_desc="no checks are registered yet"
      else
        print_checks >&2
        echo "FAIL: $REQUIRED_CHECK never appeared on ${TARGET_SHA:0:12} within ${ZERO_CHECK_GRACE}s" \
          "($check_count other checks). Every PR reports it, so this is not a pass:" \
          "look for a workflow run that never started (gh run list --commit $TARGET_SHA)" >&2
        exit 5
      fi
    elif [[ "$pending_count" == 0 && "$failing_count" == 0 ]]; then
      print_checks
      echo "OK: all $check_count checks on ${TARGET_SHA:0:12} passed"
      exit 0
    elif [[ "$pending_count" == 0 ]]; then
      print_checks >&2
      echo "FAIL: checks concluded with failures" >&2
      exit 1
    else
      zero_checks_since=""
      print_checks
      status_desc="checks are pending"
    fi
  fi

  if [[ "$status_desc" == "no checks are registered yet" ]]; then
    sleep "$INTERVAL"
    continue
  fi

  if probe_host; then
    misses=0
    if [[ $warned_runner_down -eq 0 && $((SECONDS - pending_since)) -ge 180 ]]; then
      echo "WARN: host is reachable but work is still pending after 3 min —" \
        "the runner LaunchAgent may be down (owner logged out?);" \
        "check ./scripts/remote-build.sh svc-status" >&2
      warned_runner_down=1
    fi
  else
    misses=$((misses + 1))
    echo "WARN: build host $HOST unreachable (probe $misses/2) while $status_desc" >&2
    if [[ $misses -ge 2 ]]; then
      cat >&2 <<'EOF'
FAIL-FAST: the Mac build host is not answering while CI work is pending.
GitHub will keep the job queued indefinitely, or fail it ~10 minutes after
the runner lost communication. Don't wait for that:
  1. wake the Mac (and check it stays awake),
  2. re-run what died: gh run rerun <run-id> --failed
     (or push again / re-request the check).
EOF
      exit 3
    fi
  fi
  sleep "$INTERVAL"
done
