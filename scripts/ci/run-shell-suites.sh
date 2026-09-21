#!/usr/bin/env bash
# run-shell-suites.sh <suite>...
#
# Runs the pure-shell gate suites at the same time and reports them in the
# order given. They were a serial 51 s at the head of build-test, the job every
# agent iterates on (#418); each is its own process working in its own mktemp
# directory, so the step now costs what its slowest suite costs.
#
# A suite's output is shown only when it fails, whole, so a red step reads like
# the serial one did. Exit status is 1 if any suite failed.
#
# Written for bash 3.2 (the hosted macOS image's /bin/bash): no `wait -n`, no
# associative arrays.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <suite>..." >&2
  exit 2
fi

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shell-suites.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

index=0
for suite in "$@"; do
  index=$((index + 1))
  (
    started=$SECONDS
    "$suite" >"$LOG_DIR/$index.log" 2>&1
    echo "$? $((SECONDS - started))" >"$LOG_DIR/$index.status"
  ) &
done
wait

failed=0
index=0
for suite in "$@"; do
  index=$((index + 1))
  status=""
  seconds="?"
  if [ -f "$LOG_DIR/$index.status" ]; then
    read -r status seconds <"$LOG_DIR/$index.status"
  fi
  if [ "$status" = "0" ]; then
    printf 'ok    %3ss  %s\n' "$seconds" "$suite"
  else
    failed=1
    printf 'FAIL  %3ss  %s (exit %s)\n' "$seconds" "$suite" "${status:-none recorded}"
    sed 's/^/    /' "$LOG_DIR/$index.log" 2>/dev/null
  fi
done
exit "$failed"
