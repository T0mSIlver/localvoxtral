#!/usr/bin/env bash
# Pins how ui-smoke.yml's e2e dictation step concludes for each exit status of
# scripts/e2e-dictation.sh, guarded (the owner's dispatch on main) or not.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTCOME="$ROOT_DIR/scripts/ci/e2e-dictation-outcome.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

expect() {
  # expect <status> <guarded> <want exit> <want annotation prefix or empty>
  local out got
  set +e
  out="$("$OUTCOME" "$1" "$2")"
  got=$?
  set -e
  [[ "$got" == "$3" ]] || fail "status $1 guarded=$2 concluded $got, want $3"
  if [[ -n "$4" ]]; then
    [[ "$out" == "$4"* ]] || fail "status $1 guarded=$2 printed '$out', want '$4…'"
  else
    [[ -z "$out" ]] || fail "status $1 guarded=$2 printed '$out', want nothing"
  fi
  echo "PASS: status $1 guarded=$2 -> exit $3"
}

expect 0 true 0 ""
expect 0 false 0 ""
expect 1 true 1 ""
expect 1 false 1 ""
expect 3 true 0 "::warning::"
expect 3 false 3 ""
# A missing Accessibility grant is red even on the owner's guarded dispatch.
expect 4 true 4 "::error::"
expect 4 false 4 "::error::"

echo "e2e-dictation outcome tests passed"
