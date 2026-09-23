#!/usr/bin/env bash
# Regression test for llm-lane-filter.sh's path decisions and marker opt-in.
# Pure shell, no git or network — changed-file lists are written to temp
# files, so it runs anywhere (hosted fork PRs included).
#
# Not a mirror of the whole pattern list: it pins the decisions that were
# bugs or near-misses — model-input integrations (the opencode plugin
# shipped without a pattern, PR #204 review), the marker path, and the
# run=false side that keeps UI/doc-only diffs off the live-model lane.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/llm-lane-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-llm-lane-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> <changed-path>... [--marker <text>]
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" marker_file=""
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--marker" ]]; then
      marker_file="$TMP_DIR/marker"
      printf '%s\n' "$2" >"$marker_file"
      shift 2
      continue
    fi
    printf '%s\n' "$1" >>"$changed"
    shift
  done
  local output
  if [[ -n "$marker_file" ]]; then
    output="$("$FILTER" "$changed" "$marker_file")" || fail "$description: filter exited non-zero"
  else
    output="$("$FILTER" "$changed")" || fail "$description: filter exited non-zero"
  fi
  local run reason
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# --- Model-input integrations ---------------------------------------------
# Both agent plugins shape what reaches the polish model (prompt extraction,
# cwd, file grounding); a plugin-only diff must run the lane.

expect true "opencode plugin change runs the lane" \
  integrations/opencode/localvoxtral.js
expect true "opencode integration docs stay lane-relevant (claude-code parity)" \
  integrations/opencode/README.md
expect true "claude-code plugin change runs the lane" \
  integrations/claude-code/plugins/localvoxtral/hooks/hooks.json

# --- Marker opt-in ----------------------------------------------------------

expect true "[run-llm-eval] marker forces the lane on any diff" \
  README.md --marker 'judgment call, opting in [run-llm-eval]'
expect false "unrelated marker text does not trigger" \
  README.md --marker 'no opt-in here'

# --- run=false side ---------------------------------------------------------

# --- The ClaudeContext exemption list (#418) --------------------------------
expect false "an enrollment change does not run the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentService.swift
expect false "a settings-model plus forward-supervisor change does not run the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel.swift \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardSupervisor.swift
expect true "an exempt file beside a join change still runs the lane" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentService.swift \
  Sources/localvoxtral/ClaudeContext/SSHDestinationTTYProbe.swift
expect true "a NEW file in ClaudeContext runs the lane until it is exempted" \
  Sources/localvoxtral/ClaudeContext/SomethingNobodyClassifiedYet.swift
expect true "what reads a screen or accepts a hook record is not exempt" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteContextListener.swift
expect true "what evicts sessions from the registry is not exempt" \
  Sources/localvoxtral/ClaudeContext/ClaudeRemoteListenerCoordinator.swift
expect true "what decides whether the cmux join arm authenticates is not exempt" \
  Sources/localvoxtral/ClaudeContext/CmuxSocketPasswordStore.swift

# Every exempt path must exist (a rename must not leave a dead exemption that a
# new file of the old name would inherit), and the catch-all must be the ONLY
# pattern that matches it: exempting a file that a named pattern asks for would
# silently overrule that pattern.
FILTER_SOURCE="$ROOT_DIR/scripts/ci/llm-lane-filter.sh"
exempt_paths="$(sed -n "/^EXEMPT=(/,/^)/p" "$FILTER_SOURCE" | sed -n "s/^  '\([^']*\)'.*/\1/p")"
[[ -n "$exempt_paths" ]] || fail "could not parse the EXEMPT list"
# The sed above reads one shape of entry. An entry written any other way
# (double quotes, another indent, a computed value) would skip both checks
# below, so every line of the array has to be one the sed read.
exempt_lines="$(sed -n "/^EXEMPT=(/,/^)/p" "$FILTER_SOURCE" | sed '1d;$d' | grep -vcE "^[[:space:]]*(#|$)" || true)"
[[ "$exempt_lines" == "$(wc -l <<<"$exempt_paths" | tr -d ' ')" ]] \
  || fail "EXEMPT holds an entry this test cannot parse (single-quoted, two-space indent, one per line)"
patterns="$(sed -n "/^PATTERNS=(/,/^)/p" "$FILTER_SOURCE" | sed -n "s/^  '\([^']*\)'.*/\1/p")"
while IFS= read -r exempt; do
  [[ -e "$ROOT_DIR/$exempt" ]] || fail "exempt path does not exist: $exempt"
  while IFS= read -r pattern; do
    [[ "$pattern" == 'Sources/localvoxtral/ClaudeContext/*' ]] && continue
    # shellcheck disable=SC2254
    case "$exempt" in
      $pattern) fail "exempt path $exempt is also asked for by pattern $pattern" ;;
    esac
  done <<<"$patterns"
done <<<"$exempt_paths"
echo "PASS: every exempt path exists and only the catch-all matches it"

expect false "top-level docs do not run the lane" \
  README.md AGENTS.md
expect false "UI-only Swift change does not run the lane" \
  Sources/localvoxtral/SettingsView.swift
# Nothing that shapes the polish request is left in the view model files
# (#432 step 7b): what the request is built from lives in the coordinator.
expect false "a view model or session change does not run the lane" \
  Sources/localvoxtral/DictationViewModel.swift \
  Sources/localvoxtral/DictationSessionController.swift \
  Sources/localvoxtral/DictationSessionController+Session.swift
expect true "the stop-commit's polish step runs the lane" \
  Sources/localvoxtral/StopCommitCoordinator.swift
expect true "the session's stop-commit, which feeds it, runs the lane" \
  Sources/localvoxtral/DictationSessionController+StopCommit.swift
# The pure polish pieces moved to the core target (#432 step 9) and still run it.
expect true "the token guard in the core target runs the lane" \
  Sources/localvoxtralCore/PolishTokenGuard.swift
expect true "the outcome classifier in the core target runs the lane" \
  Sources/localvoxtralCore/PolishOutcomeClassifier.swift
expect true "the polish error in the core target runs the lane" \
  Sources/localvoxtralCore/LLMPolishingError.swift
expect false "empty changed-file list decides run=false (caller owns fail-open)" \
  ""

printf 'OK: llm-lane-filter tests passed\n'
