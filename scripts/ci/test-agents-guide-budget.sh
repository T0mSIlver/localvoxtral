#!/usr/bin/env bash
# Shell port of AgentsGuideSizeTests, so the guard on AGENTS.md still runs on
# the docs-only FAST PATH.
#
# Why this exists. `AGENTS.md` and `docs/agent/*.md` are `*.md`, so
# docs-only-filter.sh returns docs_only=true for a diff that touches only
# them — and the fast path skips the whole Swift lane, including the one
# tier-0 test whose entire job is guarding AGENTS.md's 32 KiB Codex
# truncation budget. The guard was skipped exactly on the diffs that can
# break it (verified live on PR #257). Owner's call (2026-09-05): run the
# check on the fast path rather than drop AGENTS.md from the allowlist.
#
# Why shell and not `swift test --filter AgentsGuideSizeTests`. Measured: the
# Swift route needs a full build first — 33.7 s warm on the Mac build host,
# ~69 s cold on a hosted runner (run 33981779091's unit step) — to run three
# assertions that take 6 ms. A whole SwiftPM build to make a docs PR safe is
# the wrong trade when the assertions are three file reads.
#
# HOW DRIFT IS PREVENTED. This script does not restate the Swift test's data.
# It PARSES the cap, the routed paths and the anchors out of
# AgentsGuideSizeTests.swift, so the Swift test stays the single source of
# truth and the two can never disagree about a value. It also pins the SET OF
# TEST METHODS in that file: add a fourth assertion there and this script
# fails until someone ports it, rather than silently covering two thirds of
# the guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFT_TEST="$ROOT_DIR/Tests/localvoxtralTests/AgentsGuideSizeTests.swift"
AGENTS_GUIDE="$ROOT_DIR/AGENTS.md"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
pass() { printf 'PASS: %s\n' "$*"; }

[[ -f "$SWIFT_TEST" ]] || {
  echo "FAIL: $SWIFT_TEST not found — the Swift guard moved; retarget this port" >&2
  exit 1
}

# --- 0. the ported surface is still the whole surface ------------------------
# Sorted list of test methods in the Swift file. If it changes, this port is
# out of date by construction.
methods="$(grep -oE '^    func (test[A-Za-z0-9_]+)\(' "$SWIFT_TEST" \
  | sed -E 's/^    func //; s/\($//' | sort | tr '\n' ' ')"
expected_methods="testDeepGuidesKeepTheAnchorsCommentsPointAt testRootAgentsGuideStaysUnderTheCodexTruncationCap testRouterTargetsExist "
if [[ "$methods" != "$expected_methods" ]]; then
  fail "AgentsGuideSizeTests' test methods changed.
    expected: $expected_methods
    found:    $methods
  Port the new/renamed assertion into this script (and update expected_methods),
  or the docs fast path silently stops covering it."
else
  pass "ported surface matches AgentsGuideSizeTests' three test methods"
fi

# --- 1. the byte budget ------------------------------------------------------
cap="$(sed -nE 's/.*codexProjectDocMaxBytes = ([0-9_]+).*/\1/p' "$SWIFT_TEST" \
  | tr -d '_' | head -n 1)"
if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
  fail "could not parse codexProjectDocMaxBytes out of $SWIFT_TEST"
else
  bytes="$(wc -c <"$AGENTS_GUIDE" | tr -d ' ')"
  if (( bytes < cap )); then
    pass "AGENTS.md is $bytes bytes, under the $cap-byte Codex cap (headroom $((cap - bytes)))"
  else
    fail "AGENTS.md is $bytes bytes; Codex silently truncates it at $cap. \
Move deep or situational content into docs/agent/ (or a colocated AGENTS.md) \
and route to it from the root file — see \"Rules for editing THIS file\"."
  fi
fi

# --- 2. every router target resolves -----------------------------------------
routed="$(awk '/let routedPaths = \[/ { capture = 1; next }
               capture && /^        \]/ { exit }
               capture { print }' "$SWIFT_TEST" \
  | grep -oE '"[^"]+"' | tr -d '"')"
routed_count="$(grep -c . <<<"$routed" || true)"
if (( routed_count < 5 )); then
  fail "parsed only $routed_count routed paths out of $SWIFT_TEST — the parser is broken"
else
  missing=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$ROOT_DIR/$p" ]] || missing+="$p "
  done <<<"$routed"
  if [[ -n "$missing" ]]; then
    fail "AGENTS.md routes agents to paths that do not exist: $missing"
  else
    pass "all $routed_count router targets resolve"
  fi
fi

# --- 3. the anchors other files point at are still there ---------------------
# Each entry is `("<file>", "<anchor>")`, possibly wrapped across lines; the
# Swift source keeps file and anchor as adjacent string literals.
anchors_block="$(awk '/expectedAnchors: \[\(file: String, anchor: String\)\] = \[/ { capture = 1; next }
                      capture && /^        \]/ { exit }
                      capture { print }' "$SWIFT_TEST")"
# Flatten, then split on tuple boundaries: the Swift source puts one tuple per
# line today, but a long anchor may wrap, and this handles both.
anchors="$(tr '\n' ' ' <<<"$anchors_block" | sed 's/),/)\n/g' | sed 's/^ *//')"
anchor_count=0
anchor_bad=0
while IFS= read -r tuple; do
  [[ -z "$tuple" ]] && continue
  file="$(grep -oE '"[^"]+"' <<<"$tuple" | head -n 1 | tr -d '"')"
  anchor="$(grep -oE '"[^"]+"' <<<"$tuple" | sed -n 2p | tr -d '"')"
  [[ -n "$file" && -n "$anchor" ]] || continue
  anchor_count=$((anchor_count + 1))
  if [[ ! -f "$ROOT_DIR/$file" ]]; then
    fail "$file no longer exists — a comment elsewhere points at an anchor in it"
    anchor_bad=1
  elif ! grep -qF -- "$anchor" "$ROOT_DIR/$file"; then
    fail "$file no longer contains \"$anchor\" — a comment elsewhere points at it; retarget both in the same PR"
    anchor_bad=1
  fi
done <<<"$anchors"
if (( anchor_count < 3 )); then
  fail "parsed only $anchor_count anchors out of $SWIFT_TEST — the parser is broken"
elif (( anchor_bad == 0 )); then
  pass "all $anchor_count deep-guide anchors still resolve"
fi

if (( failures > 0 )); then
  echo "test-agents-guide-budget: $failures failure(s)" >&2
  exit 1
fi
echo "test-agents-guide-budget: OK"
