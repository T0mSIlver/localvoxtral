#!/usr/bin/env bash
# Pins scripts/lib/word-accuracy.sh to the behaviour the e2e dictation lane
# relies on. Runs anywhere (no macOS, no app).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCORE="$ROOT_DIR/scripts/lib/word-accuracy.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

expect() {
  local want="$1" expected="$2" actual="$3" got
  got="$("$SCORE" "$expected" "$actual")"
  [ "$got" = "$want" ] || fail "score('$expected', '$actual') = $got, want $want"
}

expect 1.000 "hello from localvoxtral" "hello from localvoxtral"
expect 1.000 "Hello, from localvoxtral." "hello from   LOCALVOXTRAL"
expect 0.667 "hello from localvoxtral" "hello from"
expect 0.667 "hello from localvoxtral" "hello form localvoxtral"
expect 0.000 "hello from localvoxtral" ""
expect 1.000 "" ""
expect 0.000 "" "noise"
# Text inserted twice must lose half the score, not keep all of it.
expect 0.500 "hello from localvoxtral" "hello from localvoxtral hello from localvoxtral"
# Punctuation splits tokens the way the Swift scorer's letter/digit runs do.
expect 1.000 "end to end" "end-to-end"

if "$SCORE" only-one-argument >/dev/null 2>&1; then
  fail "a missing argument was accepted"
fi

echo "PASS: word accuracy"
