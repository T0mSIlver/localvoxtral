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
fi

misses=0
pending_since=$SECONDS
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
    checks_out="$(gh pr checks "$TARGET" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$checks_out"
      echo "OK: all checks passed"
      exit 0
    elif [[ $rc -ne 8 ]]; then
      # gh exits 8 while checks are pending; anything else is a conclusion
      # (or a query error, which the output makes obvious).
      echo "$checks_out" >&2
      echo "FAIL: checks concluded with failures" >&2
      exit 1
    fi
    status_desc="checks are pending"
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
