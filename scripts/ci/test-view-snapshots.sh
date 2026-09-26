#!/usr/bin/env bash
# Regression test for scripts/view-snapshots.sh, the wrapper agents use to
# render the app's views on a hosted runner and download the PNGs.
#
# What this protects: the wrapper must find the run IT dispatched (by the
# request id in the run name, since `gh workflow run` does not print one),
# must not report a cancelled or failed run as snapshots, and must refuse a
# bad filter or a non-empty --out before it spends a runner.
#
# `gh` is a stub on PATH that applies the script's own --jq filters to canned
# JSON (needs jq); VIEW_SNAPSHOTS_POLL_SECONDS=0 makes the waits instant.
#   ./scripts/ci/test-view-snapshots.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
WRAPPER="$ROOT_DIR/scripts/view-snapshots.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-view-snapshots-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

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
# The request id the wrapper dispatched with, once it has.
request_id() { sed -n 's/.*request_id=\([^ ]*\).*/\1/p' "$SCEN/dispatched"; }
case "$1 ${2:-}" in
  "workflow run")
    echo "$*" >>"$SCEN/dispatched"
    ;;
  "run download")
    dir=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[i]}" == -D ]] && dir="${args[i + 1]}"
    done
    echo "$*" >>"$SCEN/downloaded"
    touch "$dir/settings-general.png" "$dir/overlay-listening.png"
    ;;
  api\ *)
    case "$url" in
      */commits/*) jq -r "$jq_filter" <<<'{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
      */actions/workflows/view-snapshots.yml/runs*)
        # Lookups before the run shows up answer with someone else's run only.
        count=$(($(cat "$SCEN/lookups" 2>/dev/null || echo 0) + 1))
        echo "$count" >"$SCEN/lookups"
        runs='{"id":1,"display_title":"View snapshots someone-else"}'
        if ((count >= ${APPEARS_ON_LOOKUP:-1})); then
          runs+=",{\"id\":42,\"display_title\":\"View snapshots $(request_id)\"}"
        fi
        jq -r "$jq_filter" <<<"{\"workflow_runs\":[$runs]}"
        ;;
      */actions/runs/42)
        # In progress on the first read, then the scenario's verdict.
        reads=$(($(cat "$SCEN/reads" 2>/dev/null || echo 0) + 1))
        echo "$reads" >"$SCEN/reads"
        if ((reads == 2)); then
          jq -r "$jq_filter" <<<'{"status":"in_progress","conclusion":null,"html_url":"u"}'
        else
          jq -r "$jq_filter" <<<"{\"status\":\"completed\",\"conclusion\":\"${CONCLUSION:-success}\",\"html_url\":\"u\"}"
        fi
        ;;
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

# run_wrapper <scenario> [env assignments...] -- <wrapper args...>
# Sets $status, $stdout, $stderr.
run_wrapper() {
  local name="$1"; shift
  local assignments=()
  while [[ "$1" != -- ]]; do assignments+=("$1"); shift; done
  shift
  export SCEN="$TMP_DIR/$name"
  mkdir -p "$SCEN"
  set +e
  env PATH="$STUB_BIN:$PATH" VIEW_SNAPSHOTS_POLL_SECONDS=0 "${assignments[@]}" \
    "$WRAPPER" "$@" >"$SCEN/stdout" 2>"$SCEN/stderr"
  status=$?
  set -e
  stdout="$(cat "$SCEN/stdout")"
  stderr="$(cat "$SCEN/stderr")"
}

# --- refusals that must not dispatch -----------------------------------------

run_wrapper bad-filter -- --filter DictationViewModelTests --out "$TMP_DIR/bad-filter-out" feature/x
[[ $status -eq 2 ]] || fail "a filter outside ViewSnapshotTests: expected exit 2, got $status"
[[ ! -f "$SCEN/dispatched" ]] || fail "a filter outside ViewSnapshotTests dispatched a run"
pass "a filter outside ViewSnapshotTests is refused before dispatch"

mkdir -p "$TMP_DIR/full-out" && touch "$TMP_DIR/full-out/keep.txt"
run_wrapper full-out -- --out "$TMP_DIR/full-out" feature/x
[[ $status -eq 2 ]] || fail "a non-empty --out: expected exit 2, got $status"
[[ ! -f "$SCEN/dispatched" ]] || fail "a non-empty --out dispatched a run"
[[ -f "$TMP_DIR/full-out/keep.txt" ]] || fail "a non-empty --out lost its contents"
pass "a non-empty --out is refused before dispatch and left alone"

# --- the dispatch --------------------------------------------------------------

run_wrapper success APPEARS_ON_LOOKUP=3 -- --filter ViewSnapshotTests/testSettingsPanes \
  --out "$TMP_DIR/success-out" feature/x
[[ $status -eq 0 ]] || fail "success: expected exit 0, got $status: $stderr"
grep -q -- "--ref feature/x -f filter=ViewSnapshotTests/testSettingsPanes" "$SCEN/dispatched" \
  || fail "success: dispatched with the wrong ref or filter: $(cat "$SCEN/dispatched")"
grep -q "^run download 42 " "$SCEN/downloaded" \
  || fail "success: downloaded from the wrong run: $(cat "$SCEN/downloaded")"
[[ "$stdout" == "$TMP_DIR/success-out/overlay-listening.png"$'\n'"$TMP_DIR/success-out/settings-general.png" ]] \
  || fail "success: expected the two PNG paths on stdout, got: $stdout"
pass "the wrapper waits for its own run, then prints each PNG's path"

run_wrapper cancelled CONCLUSION=cancelled -- --out "$TMP_DIR/cancelled-out" feature/x
[[ $status -eq 1 ]] || fail "a cancelled run: expected exit 1, got $status"
[[ ! -f "$SCEN/downloaded" ]] || fail "a cancelled run was downloaded"
grep -q "concluded cancelled" <<<"$stderr" || fail "a cancelled run: stderr does not say so: $stderr"
pass "a cancelled run is an error, not snapshots"

run_wrapper failed CONCLUSION=failure -- --out "$TMP_DIR/failed-out" feature/x
[[ $status -eq 1 ]] || fail "a failed run: expected exit 1, got $status"
[[ ! -f "$SCEN/downloaded" ]] || fail "a failed run was downloaded"
pass "a failed run is an error, not snapshots"

echo "all view-snapshots wrapper checks passed"
