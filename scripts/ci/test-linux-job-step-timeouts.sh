#!/bin/bash
# ci.yml's `linux` job bounds each step, never the job (#1831).
#
# A job's timeout-minutes also counts the wait for a hosted runner: on
# 2026-10-05 five PRs' linux jobs were cancelled after 15 minutes in the
# ubuntu-24.04 queue without ever getting a runner. The steps' own bounds
# still stop a hung test run.
#
# Pure bash and awk: this runs on hosted runners with no YAML library.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT_DIR/.github/workflows/ci.yml}"

# Prints "job" for a job-level timeout and the name of each step without one.
problems="$(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[^[:space:]#]/      { in_jobs = 0 }
  in_jobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
    if (step != "" && !bounded) print step
    step = ""
    in_linux = ($0 ~ /^  linux:/)
    next
  }
  !in_linux { next }
  /^    timeout-minutes:/ { print "job" }
  /^      - name: / {
    if (step != "" && !bounded) print step
    step = $0; sub(/^      - name: /, "", step); bounded = 0
    next
  }
  /^        timeout-minutes:/ { bounded = 1 }
  END { if (in_linux && step != "" && !bounded) print step }
' "$CI_YML")"

if ! grep -q '^  linux:' "$CI_YML"; then
  echo "FAIL: no linux job in $CI_YML" >&2
  exit 1
fi
if [[ -n "$problems" ]]; then
  echo "FAIL: ci.yml's linux job must bound its steps, not the job (#1831):" >&2
  sed 's/^/  /' <<<"$problems" >&2
  exit 1
fi
echo "PASS: the linux job bounds each step and not the job"
