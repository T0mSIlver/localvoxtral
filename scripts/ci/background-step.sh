#!/bin/bash
# background-step.sh start <state-dir> -- <command> [arg]...
# background-step.sh finish <state-dir> <timeout-seconds>
# background-step.sh stop <state-dir>
#
# Runs a command across workflow steps: `start` launches it detached and
# returns at once, `finish` waits for it, prints its whole output and exits
# with its status, so the job fails the way it would have had the command run
# in one step. build-test uses it to run the shell suites while the Swift
# build and unit suite run, instead of 30 s ahead of them. A runner keeps a
# step's background processes alive until the job ends.
#
# `finish` exits 124 when the command has not ended within the timeout, and
# 1 when `start` never recorded one. Past the timeout it stops the command
# first. `stop` (a cancelled job) kills the command's whole process group and
# prints what it wrote, so a cancelled run still shows the suites' output.
#
# Written for bash 3.2 (the hosted macOS image's /bin/bash).
set -uo pipefail

usage() {
  echo "usage: $0 start <state-dir> -- <command> [arg]..." >&2
  echo "       $0 finish <state-dir> <timeout-seconds>" >&2
  echo "       $0 stop <state-dir>" >&2
  exit 64
}

# Kills the process group `start` recorded, TERM then KILL. Never fails.
stop_group() {
  local pgid
  pgid="$(cat "$1/pgid" 2>/dev/null)" || return 0
  case "$pgid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- "-$pgid" 2>/dev/null || return 0
  sleep 1
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

[ "$#" -ge 2 ] || usage
action="$1"
state="$2"
shift 2

case "$action" in
  start)
    [ "${1:-}" = "--" ] || usage
    shift
    [ "$#" -ge 1 ] || usage
    mkdir -p "$state" || exit 1
    rm -f "$state/status" "$state/output.log" "$state/pgid"
    echo "$*" >"$state/command"
    # Job control puts the background job in its own process group, so
    # `stop` can kill the suites and everything they spawned at once.
    set -m
    # Every descriptor redirected: a background process holding the step's
    # stdout would keep the step open until it exits.
    (
      "$@" >"$state/output.log" 2>&1 </dev/null
      echo "$?" >"$state/status.tmp"
      mv "$state/status.tmp" "$state/status"
    ) >/dev/null 2>&1 </dev/null &
    echo "$!" >"$state/pgid"
    set +m
    echo "started in background (pid $!): $*"
    ;;
  finish)
    [ "$#" -eq 1 ] || usage
    timeout="$1"
    case "$timeout" in
      ''|*[!0-9]*) usage ;;
    esac
    if [ ! -f "$state/command" ]; then
      echo "background-step: nothing was started in $state" >&2
      exit 1
    fi
    waited_from=$SECONDS
    while [ ! -f "$state/status" ]; do
      if [ $((SECONDS - waited_from)) -ge "$timeout" ]; then
        stop_group "$state"
        cat "$state/output.log" 2>/dev/null
        echo "background-step: still running after ${timeout}s: $(cat "$state/command")" >&2
        exit 124
      fi
      sleep 1
    done
    echo "finished after waiting $((SECONDS - waited_from))s here: $(cat "$state/command")"
    cat "$state/output.log"
    status="$(cat "$state/status")"
    case "$status" in
      ''|*[!0-9]*) echo "background-step: unreadable status '$status'" >&2; exit 1 ;;
    esac
    exit "$status"
    ;;
  stop)
    [ "$#" -eq 0 ] || usage
    [ -f "$state/command" ] || exit 0
    stop_group "$state"
    echo "background-step: stopped: $(cat "$state/command")"
    cat "$state/output.log" 2>/dev/null
    exit 0
    ;;
  *)
    usage
    ;;
esac
