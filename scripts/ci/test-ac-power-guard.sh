#!/usr/bin/env bash
# Regression test for ac-power-guard.sh's decision logic and its pmset
# parse. The probe is stubbed via the env seam and a fake pmset on PATH —
# no real power state consulted, runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/ac-power-guard.sh"

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

expect true "AC power runs" AC_POWER_GUARD_STATE=ac
expect false "battery power skips" AC_POWER_GUARD_STATE=battery

# A broken probe must fail OPEN — a silent permanent skip would disable
# every scheduled lane without anyone noticing.
expect true "probe error fails open into a run" AC_POWER_GUARD_STATE=error

# --- Production pmset parse path ----------------------------------------
# Exercise the real power_state() flow with pmset stubbed on PATH.

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-ac-power-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/pmset" <<'STUB'
#!/usr/bin/env bash
# Stub pmset: emits $STUB_PMSET_OUTPUT, or fails when $STUB_PMSET_FAIL set.
if [[ -n "${STUB_PMSET_FAIL:-}" ]]; then
  exit 1
fi
printf '%s\n' "$STUB_PMSET_OUTPUT"
STUB
chmod +x "$TMP_DIR/bin/pmset"

# Pin the seam EMPTY (falls through `[[ -n … ]]` into the real probe): a
# developer shell with AC_POWER_GUARD_STATE exported must not short-circuit
# these cases into false greens against the stubbed pmset.
pmset_env=("PATH=$TMP_DIR/bin:$PATH" "AC_POWER_GUARD_STATE=")

expect true "pmset AC Power parses as ac" \
  "${pmset_env[@]}" \
  "STUB_PMSET_OUTPUT=Now drawing from 'AC Power'"
# Real pmset follows the first line with per-battery detail lines; only the
# first line must decide.
expect false "pmset Battery Power (with detail lines) parses as battery" \
  "${pmset_env[@]}" \
  "STUB_PMSET_OUTPUT=$(printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t87%%; discharging;")"
expect false "pmset UPS Power parses as battery" \
  "${pmset_env[@]}" \
  "STUB_PMSET_OUTPUT=Now drawing from 'UPS Power'"
# Pipe-buffer-exceeding output must not clobber a captured battery reading:
# under `set -o pipefail`, a `pmset | head -n 1` capture dies of SIGPIPE once
# the output outgrows the 64 KB pipe buffer, and the `|| first_line=""`
# recovery then discarded a SUCCESSFULLY read battery line into a fail-open
# run — the one wrong direction for this guard (PR #187 review finding).
# 80 KB: over the pipe buffer, under the single-argument limit env can pass.
expect false "pmset battery line survives 80 KB of trailing output" \
  "${pmset_env[@]}" \
  "STUB_PMSET_OUTPUT=$(printf "Now drawing from 'Battery Power'\n"; head -c 80000 /dev/zero | tr '\0' 'x')"
expect true "pmset failure fails open" \
  "${pmset_env[@]}" \
  "STUB_PMSET_FAIL=1" "STUB_PMSET_OUTPUT="
expect true "unrecognized pmset wording fails open" \
  "${pmset_env[@]}" \
  "STUB_PMSET_OUTPUT=Now drawing from 'Fusion Reactor'"

echo "ac-power-guard tests passed"
