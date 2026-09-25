#!/usr/bin/env bash
# Regression test for ui-smoke-guard.sh's decision logic. Both probes are
# stubbed via the script's env seams — no gh, no swift, runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/ui-smoke-guard.sh"

# Pin the power probe for every case that is not about power: without this,
# running the suite on a battery-powered Mac would flip every expectation.
export AC_POWER_GUARD_STATE=ac

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <expected run=> <description> [env overrides...]
expect() {
  local expected="$1" description="$2"
  shift 2
  local output
  output="$(env "$@" "$GUARD")" || fail "$description: guard exited non-zero"
  local run reason
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# Battery power skips before anything else is consulted: the stubbed error
# states on both other seams prove neither probe is reached (reaching either
# would fail open into run=true or hit the unstubbed gh path).
expect false "battery power skips regardless of coverage and lock state" \
  AC_POWER_GUARD_STATE=battery \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=error

# A broken power probe must fail open INTO the remaining rules, not into an
# unconditional run — the lock decision still applies.
expect true "power probe error falls through to an unlocked run" \
  AC_POWER_GUARD_STATE=error \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked
expect false "power probe error still respects a locked screen" \
  AC_POWER_GUARD_STATE=error \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=locked

# A recent success wins before the lock probe is even consulted: the lock
# state must not matter (and the stubbed "error" state proves the probe is
# not reached, because reaching it would fail open into run=true).
expect false "recent success skips regardless of lock state" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=3600 \
  UI_SMOKE_GUARD_LOCK_STATE=error

# 20 h window boundary: 19 h ago is covered, 21 h ago is stale.
expect false "success 19 h ago still counts as covered" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=$((19 * 3600)) \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked
expect true "success 21 h ago is stale — run again" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=$((21 * 3600)) \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked

# Lock states with no recent success.
expect false "locked screen skips" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=locked
expect false "missing GUI session skips" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=no-session
expect true "unlocked screen runs" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked

# A broken probe must fail OPEN — a silent permanent skip would disable the
# lane without anyone noticing.
expect true "probe error fails open into a run" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=error
# --- Production gh query path (PR #158 review finding) ------------------
# A guard-skipped slot also concludes `success` (skipped steps never fail a
# job), and the dictation step concludes `success` when the Mac could not run
# it (exit 3 on a schedule), so the dedup counts only runs whose "E2E
# dictation scored" marker step ran — otherwise a locked 18:00 slot suppresses
# the 19:30/21:00 retries. Exercise the real last_success_age_seconds() flow
# with gh stubbed on PATH: run 111 is a fresh guard-skip, run 222 is older.

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-ui-smoke-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: emits pre-extracted --jq output keyed on the API path.
path="$2"
case "$path" in
  */workflows/ui-smoke.yml/runs*)
    [[ -n "${STUB_PATH_LOG:-}" ]] && printf '%s\n' "$path" >>"$STUB_PATH_LOG"
    printf '%s\n' "$STUB_RUNS_TSV"
    ;;
  */actions/runs/111/jobs)
    # Guard-skip run: the marker step was skipped -> jq's `first // empty`
    # over conclusion "skipped" would still emit "skipped"; model that.
    printf 'skipped\n'
    ;;
  */actions/runs/222/jobs)
    # The guard selects the step by name inside --jq.
    case "$*" in
      *"E2E dictation scored"*) printf '%s\n' "$STUB_RUN_222_E2E" ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$TMP_DIR/bin/gh"

now_iso() {
  python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

gh_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "GITHUB_REPOSITORY=stub/stub"
  "UI_SMOKE_GUARD_LOCK_STATE=unlocked"
)

# Newest run is a guard-skip; the older run 222 scored its dictation
# recently -> still covered (proves the skip run is ignored but a real
# dictation is found behind it). The query must ask for `completed` runs: a
# scored dictation counts on an evening when the hosted drill, and so the
# run, was red.
PATH_LOG="$TMP_DIR/paths"
: >"$PATH_LOG"
expect false "fresh guard-skip is ignored; older scored dictation still covers" \
  "${gh_env[@]}" "STUB_PATH_LOG=$PATH_LOG" \
  "STUB_RUNS_TSV=$(printf '111\t%s\n222\t%s' "$(now_iso)" "$(now_iso)")" \
  "STUB_RUN_222_E2E=success"
grep -q 'runs?status=completed&' "$PATH_LOG" || fail "the guard does not look at red runs"

# Newest run is a guard-skip and no dictation was scored behind it -> NOT
# covered; with the screen unlocked the slot must run. This is the review
# finding's exact scenario (locked 18:00 skip must not suppress the 19:30
# retry), and also the exit-3 case: the dictation step passed, the marker
# was skipped.
expect true "no scored dictation does not count as covered — retry runs" \
  "${gh_env[@]}" \
  "STUB_RUNS_TSV=$(printf '111\t%s\n222\t%s' "$(now_iso)" "$(now_iso)")" \
  "STUB_RUN_222_E2E=skipped"

# Fractional-second timestamp must not break the age parse (fail-open would
# silently defeat the dedup).
frac_iso="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123Z"))')"
expect false "fractional-second timestamp still parses as covered" \
  "${gh_env[@]}" \
  "STUB_RUNS_TSV=$(printf '222\t%s' "$frac_iso")" \
  "STUB_RUN_222_E2E=success"

echo "ui-smoke-guard tests passed"
