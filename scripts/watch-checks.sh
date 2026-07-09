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
# Env: LV_BUILD_HOST overrides the probed host; LV_WATCH_INTERVAL poll seconds.
#
# Exit codes:
#   0  checks/run succeeded
#   1  checks/run concluded with failures
#   2  usage or gh query error
#   3  fail-fast: build host unreachable while work is pending
#   4  PR head advanced while watching

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
ZERO_CHECK_GRACE="${LV_ZERO_CHECK_GRACE:-90}"

# Reachable means SSH answered at all: 0 = gate v2 ran `diag`, 126 = gate
# denied the command (v1) — both prove the Mac is awake. 255 (connection
# failure) and 124 (timeout) mean asleep/unreachable.
probe_host() {
  [[ -n "$HOST" ]] || return 0 # no host configured — never fail-fast
  timeout 12 ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" diag >/dev/null 2>&1
  local rc=$?
  [[ $rc -ne 255 && $rc -ne 124 ]]
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
    if ! pr_status="$(gh pr view "$TARGET" --json headRefOid,statusCheckRollup --jq '
      def check_status:
        if .__typename == "CheckRun" then
          {
            pending: ((.status // "" | ascii_upcase) != "COMPLETED"),
            failing: (
              ((.status // "" | ascii_upcase) == "COMPLETED") and
              ((.conclusion // "" | ascii_upcase) as $c |
                ($c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED"))
            )
          }
        elif .__typename == "StatusContext" then
          {
            pending: ((.state // "" | ascii_upcase) == "PENDING" or (.state // "" | ascii_upcase) == "EXPECTED"),
            failing: ((.state // "" | ascii_upcase) != "SUCCESS" and (.state // "" | ascii_upcase) != "PENDING" and (.state // "" | ascii_upcase) != "EXPECTED")
          }
        else
          {pending: true, failing: false}
        end;
      .headRefOid as $sha |
      (.statusCheckRollup // []) as $checks |
      ($checks | map(check_status)) as $states |
      [
        $sha,
        ($checks | length),
        ($states | map(select(.pending)) | length),
        ($states | map(select(.failing)) | length)
      ] | @tsv
    ' 2>&1)"; then
      # GitHub's GraphQL throws transient 5xx-style errors (observed killing
      # a watch mid-run); only give up after several consecutive failures.
      query_failures=$((query_failures + 1))
      if [[ $query_failures -ge 4 ]]; then
        echo "FAIL: could not query PR #$TARGET via gh ($query_failures consecutive failures):" >&2
        echo "  $pr_status" >&2
        exit 2
      fi
      echo "gh query failed (attempt $query_failures/3, retrying): ${pr_status%%$'\n'*}"
      sleep "$INTERVAL"
      continue
    fi
    query_failures=0
    IFS=$'\t' read -r current_sha check_count pending_count failing_count <<<"$pr_status"

    if [[ "$current_sha" != "$TARGET_SHA" ]]; then
      echo "STALE: PR #$TARGET head advanced from ${TARGET_SHA:0:12} to ${current_sha:0:12}; re-run watch-checks.sh" >&2
      exit 4
    fi

    if [[ "$check_count" == 0 ]]; then
      if [[ -z "$zero_checks_since" ]]; then
        zero_checks_since=$SECONDS
      fi
      elapsed_zero=$((SECONDS - zero_checks_since))
      if [[ $elapsed_zero -lt $ZERO_CHECK_GRACE ]]; then
        echo "no checks registered yet -- waiting for GitHub... (${elapsed_zero}s/${ZERO_CHECK_GRACE}s)"
        status_desc="no checks are registered yet"
      else
        echo "FAIL: no checks reported" >&2
        exit 1
      fi
    elif [[ "$pending_count" == 0 && "$failing_count" == 0 ]]; then
      gh pr checks "$TARGET"
      echo "OK: all checks passed"
      exit 0
    elif [[ "$pending_count" == 0 ]]; then
      gh pr checks "$TARGET" >&2
      echo "FAIL: checks concluded with failures" >&2
      exit 1
    else
      zero_checks_since=""
      gh pr checks "$TARGET"
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
