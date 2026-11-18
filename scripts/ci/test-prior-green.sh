#!/usr/bin/env bash
# Regression test for scripts/ci/prior-green.sh: when a ready may skip the
# rerun of a check on the same head. `gh` is a stub that serves canned
# check-runs JSON through the script's own --jq filter. Needs jq.
#   ./scripts/ci/test-prior-green.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRIOR="$ROOT_DIR/scripts/ci/prior-green.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-prior-green-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq_filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == --jq ]]; then jq_filter="${args[i + 1]}"; fi
done
[[ "$1" == api ]] || { echo "stub gh: unexpected: $*" >&2; exit 64; }
[[ "$2" == --paginate ]] || { echo "stub gh: not paginated: $*" >&2; exit 64; }
[[ "$3" == repos/o/r/commits/abc123/check-runs\?check_name=build-test\&filter=all\&* ]] \
  || { echo "stub gh: unexpected url (every attempt, not the latest, must be listed): $3" >&2; exit 64; }
[[ -z "${FAIL_API:-}" ]] || { echo "HTTP 502" >&2; exit 1; }
jq -r "$jq_filter" "$RUNS"
STUB
chmod +x "$TMP_DIR/bin/gh"

runs() { # <status>:<conclusion>:<completed_at>...
  if [[ $# -eq 0 ]]; then # bash 3.2 (build-test) calls an empty array unbound
    echo '{"total_count":0,"check_runs":[]}' >"$TMP_DIR/runs.json"
    return
  fi
  local items=() spec status conclusion at
  for spec in "$@"; do
    IFS=: read -r status conclusion at <<<"$spec"
    items+=("{\"name\":\"build-test\",\"status\":\"$status\",\"conclusion\":$([[ $conclusion == null ]] && echo null || echo "\"$conclusion\""),\"completed_at\":$([[ $at == null ]] && echo null || echo "\"$at\"")}")
  done
  local IFS=,
  printf '{"total_count":%d,"check_runs":[%s]}\n' "${#items[@]}" "${items[*]}" >"$TMP_DIR/runs.json"
}

expect() { # <want> <label>
  local got
  got="$(PATH="$TMP_DIR/bin:$PATH" RUNS="$TMP_DIR/runs.json" "$PRIOR" o/r abc123 build-test)"
  [[ "$got" == "$1" ]] || fail "$2: got '$got', want '$1'"
  pass "$2"
}

runs completed:success:2026-11-04T10:00:00Z
expect true "a passed run on the head lets the ready skip it"

runs completed:success:2026-11-04T10:00:00Z completed:skipped:2026-11-04T11:00:00Z
expect true "a skip a previous ready left does not hide the pass"

runs completed:success:2026-11-04T10:00:00Z completed:cancelled:2026-11-04T11:00:00Z
expect true "a cancelled rerun does not hide the pass"

runs completed:success:2026-11-04T10:00:00Z completed:failure:2026-11-04T11:00:00Z
expect false "a later failure on the same head is never covered by the older pass"

runs completed:failure:2026-11-04T10:00:00Z
expect false "a red head runs again"

# Codex review: a failed attempt whose retry the ready cancelled. With every
# attempt listed the failure stays newer than the old pass.
runs completed:success:2026-11-04T09:00:00Z completed:failure:2026-11-04T10:00:00Z completed:cancelled:2026-11-04T11:00:00Z
expect false "a failure behind a cancelled retry is not covered by an older pass"

runs in_progress:null:null
expect false "a run still going is no result"

runs completed:skipped:2026-11-04T10:00:00Z
expect false "a head with only skips runs"

runs
expect false "a new head with no runs runs everything"

runs completed:success:2026-11-04T10:00:00Z
got="$(FAIL_API=1 PATH="$TMP_DIR/bin:$PATH" RUNS="$TMP_DIR/runs.json" "$PRIOR" o/r abc123 build-test)"
[[ "$got" == false ]] || fail "an API error must run the job, got '$got'"
pass "an API error runs the job"
