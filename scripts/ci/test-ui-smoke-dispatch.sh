#!/usr/bin/env bash
# Regression test for scripts/ui-smoke-dispatch.sh and the path filter it asks,
# scripts/ci/e2e-dictation-filter.sh.
#
# What this protects: UI Smoke holds the only Mac and the owner's keyboard.
# The wrapper dispatches it only for a session-path diff that build-test has
# passed, once per commit, never on top of a queued run and never within an
# hour of the last one (#544). Each refusal is pinned here, and so is the
# dispatch that must still happen.
#
# `gh` is a stub on PATH that applies the script's own --jq filters to canned
# JSON (needs jq); the clock is UI_SMOKE_DISPATCH_NOW.
#   ./scripts/ci/test-ui-smoke-dispatch.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
DISPATCH="$ROOT_DIR/scripts/ui-smoke-dispatch.sh"
FILTER="$ROOT_DIR/scripts/ci/e2e-dictation-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-ui-smoke-dispatch-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# --- the path filter ---------------------------------------------------------

# filter_expect <true|false> <description> <changed-path>...
filter_expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/filter-changed"
  : >"$changed"
  local path
  for path in "$@"; do printf '%s\n' "$path" >>"$changed"; done
  local output
  output="$("$FILTER" "$changed")"
  [[ "$(sed -n 's/^run=//p' <<<"$output")" == "$expected" ]] \
    || fail "filter: $description: expected run=$expected, got: $output"
  pass "filter: $description"
}

filter_expect false "session start and stop" Sources/localvoxtral/DictationViewModel.swift
filter_expect true "the controller's stop-commit" "Sources/localvoxtral/DictationSessionController+StopCommit.swift"
filter_expect false "another session controller file" "Sources/localvoxtral/DictationSessionController+Realtime.swift"
filter_expect true "the stop-commit" Sources/localvoxtral/StopCommitCoordinator.swift
filter_expect false "a realtime client" Sources/localvoxtralCore/MistralRealtimeWebSocketClient.swift
filter_expect false "the reconnect schedule" Sources/localvoxtral/RealtimeReconnectPolicy.swift
filter_expect false "the live correction" Sources/localvoxtralCore/LiveReplacementCorrector.swift
filter_expect false "transcript merging in core" Sources/localvoxtralCore/TextMergingAlgorithms.swift
filter_expect true "text insertion" Sources/localvoxtral/TextInsertionService.swift
filter_expect true "focus handling" Sources/localvoxtral/SystemAccessibilityFocus.swift
filter_expect true "the overlay commit" Sources/localvoxtral/OverlayBufferSessionCoordinator.swift
filter_expect true "the WAV source the check dictates from" Sources/localvoxtral/Dogfood/DogfoodAudioFileSource.swift
filter_expect true "a scenario" scripts/e2e/scenarios/overlay-buffer.scenario
filter_expect true "the lane's workflow" .github/workflows/ui-smoke.yml
filter_expect true "one match among unrelated files" docs/README.md Sources/localvoxtral/RealtimeClient.swift Sources/localvoxtral/TextInsertionService.swift
filter_expect false "the polish path (goldens prove it)" Sources/localvoxtral/PolishRequestAssembler.swift Sources/localvoxtral/LLMPolishingService.swift
filter_expect false "the overlay's look" Sources/localvoxtral/OverlayStableLineWrapper.swift Sources/localvoxtral/DictationOverlayView.swift
filter_expect false "settings and docs" Sources/localvoxtral/Settings/DictationSettingsPane.swift docs/agent/test-tiers.md AGENTS.md
filter_expect false "the AX drill alone" scripts/ui-smoke.sh
filter_expect false "an empty diff"

# --- the dispatch wrapper ----------------------------------------------------

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${SCEN:?}"
jq_filter="."
url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jq_filter="${args[i + 1]}" ;;
    repos/*) url="${args[i]}" ;;
  esac
done
case "$1 ${2:-}" in
  "workflow run")
    echo "$*" >>"$SCEN/dispatched"
    ;;
  api\ *)
    case "$url" in
      */compare/*) jq -r "$jq_filter" "$SCEN/compare.json" ;;
      */check-runs*) jq -r "$jq_filter" "$SCEN/check-runs.json" ;;
      */actions/runs/*/jobs*)
        run_id="${url#*/actions/runs/}"
        run_id="${run_id%%/*}"
        if [[ -f "$SCEN/jobs-$run_id.json" ]]; then
          jq -r "$jq_filter" "$SCEN/jobs-$run_id.json"
        else
          jq -r "$jq_filter" <<<'{"jobs":[{"name":"ui-smoke","conclusion":"failure","steps":[{"name":"Set up job"}]}]}'
        fi
        ;;
      */actions/workflows/ui-smoke.yml/runs*)
        echo "$url" >"$SCEN/runs-url"
        jq -r "$jq_filter" "$SCEN/runs.json"
        ;;
      */commits/*) jq -r "$jq_filter" <<<'{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
      *) echo "stub gh: unexpected api url: $url" >&2; exit 64 ;;
    esac
    ;;
  *)
    echo "stub gh: unexpected invocation: $*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOW=1790000000 # 2026-09-21T14:13:20Z
ISO_2H_AGO=2026-09-21T12:13:20Z
ISO_10M_AGO=2026-09-21T14:03:20Z

# scenario <name> <files-json-array> <build-test status/conclusion|none> <runs-json-array>
scenario() {
  local dir="$TMP_DIR/$1"
  mkdir -p "$dir"
  printf '{"files":%s}\n' "$(jq -c '[.[] | {filename: .}]' <<<"$2")" >"$dir/compare.json"
  if [[ "$3" == none ]]; then
    echo '{"check_runs":[]}' >"$dir/check-runs.json"
  else
    local status="${3%%/*}" conclusion="${3#*/}"
    [[ -n "$conclusion" ]] && conclusion="\"$conclusion\"" || conclusion=null
    printf '{"check_runs":[{"id":1,"status":"completed","conclusion":"failure"},{"id":2,"status":"%s","conclusion":%s}]}\n' \
      "$status" "$conclusion" >"$dir/check-runs.json"
  fi
  printf '{"workflow_runs":%s}\n' "$4" >"$dir/runs.json"
}

run_json() { # <id> <status> <sha> <created_at> <conclusion|null>
  local conclusion="$5"
  [[ "$conclusion" == null ]] || conclusion="\"$conclusion\""
  printf '{"id":%s,"status":"%s","head_sha":"%s","created_at":"%s","conclusion":%s}' \
    "$1" "$2" "$3" "$4" "$conclusion"
}

# expect <exit> <description> <scenario> <needle> [wrapper args...]
expect() {
  local expected_exit="$1" description="$2" name="$3" needle="$4"
  shift 4
  local output code=0
  output="$(SCEN="$TMP_DIR/$name" PATH="$STUB_BIN:$PATH" UI_SMOKE_DISPATCH_NOW="$NOW" \
    "$DISPATCH" "$@" t/some-branch 2>&1)" || code=$?
  [[ "$code" == "$expected_exit" ]] \
    || fail "$description: expected exit $expected_exit, got $code:"$'\n'"$output"
  grep -qF -- "$needle" <<<"$output" \
    || fail "$description: output lacks '$needle':"$'\n'"$output"
  if [[ "$expected_exit" == 0 && " $* " != *" --dry-run "* ]]; then
    grep -qF "workflow run ui-smoke.yml --ref t/some-branch" "$TMP_DIR/$name/dispatched" 2>/dev/null \
      || fail "$description: nothing was dispatched"
  elif [[ -f "$TMP_DIR/$name/dispatched" ]]; then
    fail "$description: dispatched although it should not have"
  fi
  pass "$description"
}

SESSION='["Sources/localvoxtral/TextInsertionService.swift"]'
DOCS='["docs/agent/test-tiers.md"]'

scenario clean "$SESSION" completed/success '[]'
expect 0 "a green session-path diff with no earlier run dispatches" clean "dispatched UI Smoke on t/some-branch"

scenario dry "$SESSION" completed/success '[]'
expect 0 "--dry-run decides without dispatching" dry "would dispatch" --dry-run

scenario docs "$DOCS" completed/success '[]'
expect 1 "a diff off the session path is refused" docs "refused: the diff does not need it"

scenario red "$SESSION" completed/failure '[]'
expect 1 "a red build-test is refused" red "refused: build-test is not green"

scenario pending "$SESSION" in_progress/ '[]'
expect 1 "a running build-test is refused (the newest check run counts)" pending "build-test: in_progress/"

scenario nobuild "$SESSION" none '[]'
expect 1 "a head build-test never ran on is refused" nobuild "build-test: none"

scenario queued "$SESSION" completed/success "[$(run_json 7 queued "$OLD_SHA" "$ISO_2H_AGO" null)]"
expect 1 "a queued run is refused" queued "refused: run 7 is queued; watch it instead"
scenario queued-override "$SESSION" completed/success "[$(run_json 7 in_progress "$OLD_SHA" "$ISO_2H_AGO" null)]"
expect 1 "--override never stacks a run on a running one" queued-override "refused: run 7 is in_progress" --override "owner asked"

scenario recent "$SESSION" completed/success "[$(run_json 8 completed "$OLD_SHA" "$ISO_10M_AGO" success)]"
expect 1 "a run within the hour is refused" recent "refused: run 8 started 10 min ago"

scenario samesha "$SESSION" completed/success "[$(run_json 9 completed "$HEAD_SHA" "$ISO_2H_AGO" failure)]"
expect 1 "a second run on the same commit is refused, even after a red" samesha "refused: run 9 already ran on aaaaaaaaa (failure)"

scenario newcommit "$SESSION" completed/success "[$(run_json 10 completed "$OLD_SHA" "$ISO_2H_AGO" success)]"
expect 0 "a new commit an hour after the last run dispatches" newcommit "dispatched UI Smoke"

scenario override "$DOCS" completed/success "[$(run_json 11 completed "$HEAD_SHA" "$ISO_10M_AGO" failure)]"
expect 0 "--override dispatches past the path, cooldown and same-commit refusals" override "override: owner asked for a rerun" --override "owner asked for a rerun"

# A label other than needs-ui-smoke creates a run whose job is skipped, or
# which the concurrency group cancels before it has a job (#570). Neither
# touched the Mac, so neither blocks the real check, not even on the head.
scenario labelnoise "$SESSION" completed/success "[$(run_json 21 completed "$HEAD_SHA" "$ISO_10M_AGO" cancelled),$(run_json 20 completed "$HEAD_SHA" "$ISO_10M_AGO" skipped)]"
echo '{"jobs":[]}' >"$TMP_DIR/labelnoise/jobs-21.json"
echo '{"jobs":[{"name":"ui-smoke","conclusion":"skipped","steps":[]}]}' >"$TMP_DIR/labelnoise/jobs-20.json"
expect 0 "runs whose job never started block nothing" labelnoise "ignored: run 20 never started"
# A dispatch cancelled while it waited for the Mac has a job but no steps.
scenario queuecancel "$SESSION" completed/success "[$(run_json 22 completed "$HEAD_SHA" "$ISO_10M_AGO" cancelled)]"
echo '{"jobs":[{"name":"ui-smoke","conclusion":"cancelled","steps":[]}]}' >"$TMP_DIR/queuecancel/jobs-22.json"
expect 0 "a run cancelled before its first step blocks nothing" queuecancel "ignored: run 22 never started"
# A red that reached the Mac (NOT RUN, lost focus) still counts, behind noise.
scenario noisyred "$SESSION" completed/success "[$(run_json 24 completed "$HEAD_SHA" "$ISO_10M_AGO" skipped),$(run_json 23 completed "$HEAD_SHA" "$ISO_10M_AGO" failure)]"
echo '{"jobs":[{"name":"ui-smoke","conclusion":"skipped","steps":[]}]}' >"$TMP_DIR/noisyred/jobs-24.json"
expect 1 "a red run that started still blocks the head" noisyred "refused: run 23 already ran on aaaaaaaaa (failure)"
expect 1 "a red run that started still starts the hour" noisyred "refused: run 23 started 10 min ago"

# An unencoded '&' would split the query: the lookup would find no runs and
# every run-history refusal would pass.
scenario amp "$SESSION" completed/success '[]'
SCEN="$TMP_DIR/amp" PATH="$STUB_BIN:$PATH" UI_SMOKE_DISPATCH_NOW="$NOW" \
  "$DISPATCH" --dry-run 't/fix-a&b' >/dev/null
grep -qF 'runs?branch=t%2Ffix-a%26b&per_page=' "$TMP_DIR/amp/runs-url" \
  || fail "the runs query does not encode the branch: $(cat "$TMP_DIR/amp/runs-url")"
pass "the branch is encoded in the runs query"

code=0
"$DISPATCH" >/dev/null 2>&1 || code=$?
[[ "$code" == 2 ]] || fail "no branch: expected exit 2, got $code"
pass "no branch is a usage error"

echo "ui-smoke-dispatch: all checks passed"
