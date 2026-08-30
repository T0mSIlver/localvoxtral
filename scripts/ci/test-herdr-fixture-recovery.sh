#!/usr/bin/env bash
# Regression test for the herdr fixture's crash recovery.
#
# The fixture borrows three of the account's real files (herdr `config.toml`,
# `session.json`, and delimited blocks in `~/.ssh/config`). `down` gives them
# back — but a run can be SIGKILLed, and nothing runs on SIGKILL. The pristine
# copies therefore live at a stable path, and the next `up` must restore them
# rather than back up the ALREADY-MODIFIED files over them, which is the step
# that would destroy the originals permanently.
#
# This drives that logic directly against a fake HOME, so it runs anywhere —
# no herdr, no ssh, no live server. Same sourced-mode pattern as
# scripts/ci/test-build-gate-*.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FIXTURE="$ROOT_DIR/scripts/herdr-integration-fixture.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-herdr-fixture-recovery.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() { printf 'PASS: %s\n' "$*"; }

PRISTINE_CONFIG='# the human own herdr config
[theme]
name = "kanagawa"
'
PRISTINE_SSH='Host prod
  HostName prod.example
  User someone
'
PRISTINE_SESSION='{"workspaces":["the human own session"]}'

GOLDEN="$TMP_DIR/golden"

# A fresh fake account with all three files as the human left them, plus
# byte-exact golden copies kept OUTSIDE that home so the assertions compare
# bytes rather than shell-stripped strings.
setup_home() {
  export HOME="$TMP_DIR/home"
  rm -rf "$HOME"
  mkdir -p "$HOME/.config/herdr" "$HOME/.ssh" "$GOLDEN"
  printf '%s' "$PRISTINE_CONFIG" > "$HOME/.config/herdr/config.toml"
  printf '%s' "$PRISTINE_SESSION" > "$HOME/.config/herdr/session.json"
  printf '%s' "$PRISTINE_SSH" > "$HOME/.ssh/config"
  cp "$HOME/.config/herdr/config.toml" "$GOLDEN/config.toml"
  cp "$HOME/.config/herdr/session.json" "$GOLDEN/session.json"
  cp "$HOME/.ssh/config" "$GOLDEN/ssh_config"
  # Sourced with HOME already set: the fixture resolves the account paths at
  # load, exactly as it does for a real invocation.
  # shellcheck source=/dev/null
  LOCALVOXTRAL_HERDR_FIXTURE_SOURCE_ONLY=1 source "$FIXTURE"
}

# Everything `up` does to the account's files, without herdr or ssh: take the
# hold, then modify. A run "killed" after this leaves exactly this state.
simulate_up_then_kill() {
  local dir="$1"
  mkdir -p "$dir"
  hold_account_files "$dir"
  printf 'onboarding = false\n[ui.sidebar.agents]\n' > "$HERDR_CONFIG_FILE"
  rm -f "$HERDR_SESSION_FILE"
  {
    printf '%s\n' "$SSH_CONFIG_BEGIN"
    printf 'Host lvx-herdr-fixture\n  HostName 127.0.0.1\n  Port 24601\n'
    printf '%s\n' "$SSH_CONFIG_END"
    printf '%s\n' "$SSH_CONFIG_ALT_BEGIN"
    printf 'Host lvx-herdr-fixture-altuser\n  HostName 127.0.0.1\n'
    printf '%s\n' "$SSH_CONFIG_ALT_END"
  } >> "$SSH_CONFIG_FILE"
  # The manifest records THIS shell's pid, which is very much alive. A killed
  # run's pid is not, so overwrite it with one that cannot be running.
  sed -e 's/^pid=.*/pid=999999/' "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
  mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"
}

assert_account_is_pristine() {
  local what="$1"
  cmp -s "$GOLDEN/config.toml" "$HERDR_CONFIG_FILE" \
    || fail "$what: herdr config was not restored byte for byte:
$(cat "$HERDR_CONFIG_FILE" 2>&1)"
  cmp -s "$GOLDEN/session.json" "$HERDR_SESSION_FILE" \
    || fail "$what: herdr session was not restored byte for byte"
  cmp -s "$GOLDEN/ssh_config" "$SSH_CONFIG_FILE" \
    || fail "$what: ssh config was not restored byte for byte:
$(cat "$SSH_CONFIG_FILE" 2>&1)"
  [[ ! -e "$HOLD_DIR" ]] || fail "$what: the hold directory survived the restore"
}

# --- 1. A killed run is detected and restored by the next `up` -------------

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-run1"
cmp -s "$GOLDEN/config.toml" "$HERDR_CONFIG_FILE" \
  && fail "the simulated run did not actually modify the config"
hold_is_present || fail "the simulated run left no hold"

reclaim_or_refuse_stale_hold 2>/dev/null
assert_account_is_pristine "after reclaiming a killed run"
pass "a killed run's held files are restored by the next up"

# --- 2. `recover` does the same by hand, with no workdir argument ----------

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-run2"
rm -rf "$TMP_DIR/lvx-herdr-fixture-run2"   # the run dir is gone; the hold is not
command_recover 2>/dev/null
assert_account_is_pristine "after recover"
pass "recover restores without the run directory"

# --- 3. Two consecutive interrupted runs cannot lose the originals ---------
# This is the defect: if the second run backed up the FIRST run's modified
# files, the human's originals would be gone for good after its teardown.

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-runA"
reclaim_or_refuse_stale_hold 2>/dev/null
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-runB"
# The step that would destroy the originals: run B's backup must be the
# HUMAN'S file, not run A's modified one.
cmp -s "$GOLDEN/config.toml" "$HOLD_DIR/herdr-config.pristine" \
  || fail "the second interrupted run backed up the first run's modified config"
reclaim_or_refuse_stale_hold 2>/dev/null
assert_account_is_pristine "after two consecutive interrupted runs"
pass "the pristine originals survive two consecutive interrupted runs"

# --- 4. A hold is never overwritten ---------------------------------------
# The direct guard on the data-loss step, independent of who calls it.

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-runC"
if ( hold_account_files "$TMP_DIR/lvx-herdr-fixture-runD" ) 2>/dev/null; then
  fail "hold_account_files overwrote an existing hold"
fi
cmp -s "$GOLDEN/config.toml" "$HOLD_DIR/herdr-config.pristine" \
  || fail "the pristine copy was replaced by the modified file"
pass "a second hold is refused rather than overwriting the pristine copies"

# --- 5. A LIVE run's hold is refused, not reclaimed ------------------------
# Two lanes racing for one account must not restore each other's files. The
# liveness evidence is "a process with the fixture's name is running under
# that pid", so the decoy has to carry that name for this to test anything.

setup_home
DECOY="$TMP_DIR/herdr-integration-fixture-decoy.sh"
printf '#!/bin/sh\nsleep 30\n' > "$DECOY"
chmod +x "$DECOY"
"$DECOY" &
DECOY_PID=$!
mkdir -p "$TMP_DIR/lvx-herdr-fixture-live"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-live" 2>/dev/null
sed -e "s/^pid=.*/pid=$DECOY_PID/" "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"

hold_owner_is_alive \
  || fail "the decoy was not recognised as a live fixture run; the refusal branch is untested"
if ( reclaim_or_refuse_stale_hold ) 2>/dev/null; then
  kill "$DECOY_PID" 2>/dev/null || true
  fail "a live run's hold was reclaimed instead of refused"
fi
hold_is_present || fail "the refusal must leave the live run's hold intact"
pass "a live run's hold is refused rather than reclaimed"

kill "$DECOY_PID" 2>/dev/null || true
wait "$DECOY_PID" 2>/dev/null || true
release_account_files 2>/dev/null || true

# --- 6. Restoring absent files means removing them, not writing empties ----

export HOME="$TMP_DIR/home-empty"
rm -rf "$HOME"
mkdir -p "$HOME"
# shellcheck source=/dev/null
LOCALVOXTRAL_HERDR_FIXTURE_SOURCE_ONLY=1 source "$FIXTURE"
mkdir -p "$TMP_DIR/lvx-herdr-fixture-empty"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-empty" 2>/dev/null
printf 'onboarding = false\n' > "$HERDR_CONFIG_FILE"
printf '%s\nHost x\n%s\n' "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_END" >> "$SSH_CONFIG_FILE"
release_account_files 2>/dev/null
[[ ! -e "$HERDR_CONFIG_FILE" ]] \
  || fail "a config that did not exist before must not exist after"
[[ ! -e "$SSH_CONFIG_FILE" ]] \
  || fail "an ssh config the fixture created must be removed again, not left empty"
pass "files the account never had are removed, not left behind"

printf '\nAll herdr fixture recovery checks passed.\n'
