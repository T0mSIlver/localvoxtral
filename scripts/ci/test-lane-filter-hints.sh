#!/usr/bin/env bash
# Regression test for LVX-114: nothing a lane filter prints holds a bracketed
# lane marker. Its reason lands in CI logs and step summaries, and gets pasted
# into PR bodies as proof; a bracketed marker there opts the PR into a live
# lane (#2042 ran the LLM lane in daytime that way, #2037 before it). AGENTS.md:
# "Name markers without brackets unless you mean them."
#
# Two checks per filter: its output over every decision this test can reach
# (no change, an unrelated change, a matching change, the marker, the skip
# marker), and its source, so a print on a path no input reaches is caught too.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-lane-filter-hints.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

BRACKETED='\[(run|skip)-[a-z-]+[]:]'
FILTERS=(llm speechd stt herdr)

# filter <name> <changed-files-file> <marker-text-file>: all it prints.
filter() {
  local script="$ROOT_DIR/scripts/ci/$1-lane-filter.sh"
  if [[ "$1" == stt ]]; then
    "$script" "$2" "" "$3" 2>&1
  else
    "$script" "$2" "$3" 2>&1
  fi
}

printf '' >"$TMP_DIR/none"
printf 'README.md\n' >"$TMP_DIR/unrelated"
# One path each filter runs its lane for.
printf 'Sources/localvoxtralCore/PolishTokenGuard.swift\nSources/localvoxtral/StopCommitCoordinator.swift\nSpeechHelper/Package.swift\nSources/localvoxtral/RealtimeAPIWebSocketClient.swift\nSources/localvoxtralCore/ClaudeContext/HerdrSocketClient.swift\n' >"$TMP_DIR/matching"
printf 'nothing to see\n' >"$TMP_DIR/no-marker"
printf '[run-llm-eval] [run-speechd-integration] [run-stt-integration] [run-herdr-integration]\n' >"$TMP_DIR/markers"
printf '[skip-llm-eval: a rename]\n' >"$TMP_DIR/skip"
printf '[skip-llm-eval]\n' >"$TMP_DIR/skip-bare"

for name in "${FILTERS[@]}"; do
  for changed in none unrelated matching; do
    for marker in no-marker markers skip skip-bare; do
      out="$(filter "$name" "$TMP_DIR/$changed" "$TMP_DIR/$marker")" \
        || fail "$name filter exited non-zero on $changed/$marker: $out"
      if grep -qE "$BRACKETED" <<<"$out"; then
        fail "$name filter printed a bracketed marker ($changed, $marker): $(grep -E "$BRACKETED" <<<"$out")"
      fi
    done
  done
  # Source: no print names $MARKER (the bracketed form) or spells one out.
  if grep -nE '^[^#]*(echo|printf).*(\$MARKER([^_A-Za-z]|$)|\$\{MARKER\}|'"$BRACKETED"')' \
      "$ROOT_DIR/scripts/ci/$name-lane-filter.sh"; then
    fail "$name-lane-filter.sh prints the bracketed marker (lines above); print \$MARKER_NAME"
  fi
done
echo "PASS: no lane filter prints a bracketed marker"
