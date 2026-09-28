#!/usr/bin/env bash
# Regression test for the herdr fixture's crash recovery.
#
# The fixture borrows one of the account's real files (delimited blocks in
# `~/.ssh/config`); its herdr runs on its own config and state homes, so the
# account's herdr `config.toml` and `session.json` must come out of every
# path below byte-identical. `down` gives the ssh config back — but a run can
# be SIGKILLed, and nothing runs on SIGKILL. The pristine copy therefore lives
# at a stable path, and the next `up` must restore it rather than back up the
# ALREADY-MODIFIED file over it, which is the step that would destroy the
# original permanently. A hold taken by a fixture from before #323 still
# carries herdr copies, and recovering one must put those back too.
#
# This drives that logic directly against a fake HOME, so it runs anywhere —
# no herdr, no ssh, no live server. Same sourced-mode pattern as
# scripts/ci/test-build-gate-*.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
# LV_HERDR_FIXTURE points it at another copy of the fixture, which is how the
# pre-#991 failures were shown.
FIXTURE="${LV_HERDR_FIXTURE:-$ROOT_DIR/scripts/herdr-integration-fixture.sh}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-herdr-fixture-recovery.XXXXXX")"
DECOY_PID=""
trap '[[ -z "$DECOY_PID" ]] || kill "$DECOY_PID" 2>/dev/null || :; rm -rf "$TMP_DIR"' EXIT

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
  {
    printf '%s\n' "$SSH_CONFIG_BEGIN"
    printf 'Host lvx-herdr-fixture\n  HostName 127.0.0.1\n  Port 24601\n'
    printf '%s\n' "$SSH_CONFIG_END"
    printf '%s\n' "$SSH_CONFIG_ALT_BEGIN"
    printf 'Host lvx-herdr-fixture-altuser\n  HostName 127.0.0.1\n'
    printf '%s\n' "$SSH_CONFIG_ALT_END"
    printf '%s\n' "$SSH_CONFIG_FED_BEGIN"
    printf 'Host lvx-herdr-fixture-fed\n  HostName 127.0.0.1\n  Port 24601\n'
    printf '%s\n' "$SSH_CONFIG_FED_END"
  } >> "$SSH_CONFIG_FILE"
  # The manifest records THIS shell's pid, which is very much alive. A killed
  # run's pid is not, so overwrite it with one that cannot be running.
  sed -e 's/^pid=.*/pid=999999/' "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
  mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"
}

assert_account_is_pristine() {
  local what="$1"
  cmp -s "$GOLDEN/config.toml" "$HOME/.config/herdr/config.toml" \
    || fail "$what: herdr config is not byte for byte the human's:
$(cat "$HOME/.config/herdr/config.toml" 2>&1)"
  cmp -s "$GOLDEN/session.json" "$HOME/.config/herdr/session.json" \
    || fail "$what: herdr session is not byte for byte the human's"
  cmp -s "$GOLDEN/ssh_config" "$SSH_CONFIG_FILE" \
    || fail "$what: ssh config was not restored byte for byte:
$(cat "$SSH_CONFIG_FILE" 2>&1)"
  [[ ! -e "$HOLD_DIR" ]] || fail "$what: the hold directory survived the restore"
}

# --- 1. A killed run is detected and restored by the next `up` -------------

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-run1"
cmp -s "$GOLDEN/ssh_config" "$SSH_CONFIG_FILE" \
  && fail "the simulated run did not actually modify the ssh config"
hold_is_present || fail "the simulated run left no hold"
for held in "$HOLD_DIR"/herdr-*; do
  [[ -e "$held" ]] && fail "the hold took a copy of the account's herdr files: $held"
done

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
cmp -s "$GOLDEN/ssh_config" "$HOLD_DIR/ssh-config.pristine" \
  || fail "the second interrupted run backed up the first run's modified ssh config"
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
cmp -s "$GOLDEN/ssh_config" "$HOLD_DIR/ssh-config.pristine" \
  || fail "the pristine copy was replaced by the modified file"
pass "a second hold is refused rather than overwriting the pristine copies"

# --- 5. A LIVE run's hold is refused, not reclaimed ------------------------
# Two lanes racing for one account must not restore each other's files. The
# liveness evidence is "a process with the fixture's name is running under
# that pid", so the decoy has to carry that name for this to test anything.

setup_home
DECOY="$TMP_DIR/herdr-integration-fixture-decoy.sh"
# `exec -a`, not a shell that runs `sleep` as its child: killing that shell
# orphaned the child for its full 30 s (#714). The decoy keeps its own name in
# argv, which is all the liveness check reads.
printf '#!/bin/bash\nexec -a "$0" sleep 30\n' > "$DECOY"
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
DECOY_PID=""
release_account_files 2>/dev/null || true

# --- 6. Restoring absent files means removing them, not writing empties ----

export HOME="$TMP_DIR/home-empty"
rm -rf "$HOME"
mkdir -p "$HOME"
# shellcheck source=/dev/null
LOCALVOXTRAL_HERDR_FIXTURE_SOURCE_ONLY=1 source "$FIXTURE"
mkdir -p "$TMP_DIR/lvx-herdr-fixture-empty"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-empty" 2>/dev/null
printf '%s\nHost x\n%s\n' "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_END" >> "$SSH_CONFIG_FILE"
release_account_files 2>/dev/null
[[ ! -e "$HOME/.config/herdr" ]] \
  || fail "releasing a current hold created herdr files the account never had"
[[ ! -e "$SSH_CONFIG_FILE" ]] \
  || fail "an ssh config the fixture created must be removed again, not left empty"
pass "files the account never had are removed, not left behind"

# --- 6b. A hold taken before #323 still gives the herdr files back ---------
# That fixture replaced config.toml and removed session.json, and a runner
# killed mid-run under it leaves a hold with herdr copies in it. Recovering it
# with the current script must restore both, including a file that was absent.

setup_home
mkdir -p "$TMP_DIR/lvx-herdr-fixture-legacy"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-legacy" 2>/dev/null
cp "$GOLDEN/config.toml" "$HOLD_DIR/herdr-config.pristine"
cp "$GOLDEN/session.json" "$HOLD_DIR/herdr-session.pristine"
printf 'onboarding = false\n[ui.sidebar.agents]\n' > "$HOME/.config/herdr/config.toml"
rm -f "$HOME/.config/herdr/session.json"
sed -e 's/^pid=.*/pid=999999/' "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"
command_recover 2>/dev/null
assert_account_is_pristine "after recovering a pre-#323 hold"

setup_home
mkdir -p "$TMP_DIR/lvx-herdr-fixture-legacy-absent"
rm -f "$HOME/.config/herdr/session.json"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-legacy-absent" 2>/dev/null
: > "$HOLD_DIR/herdr-session.absent"
printf '{"workspaces":["the fixture layout"]}' > "$HOME/.config/herdr/session.json"
sed -e 's/^pid=.*/pid=999999/' "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"
command_recover 2>/dev/null
[[ ! -e "$HOME/.config/herdr/session.json" ]] \
  || fail "a pre-#323 hold recorded session.json as absent, but recover left one behind"
pass "a pre-#323 hold still restores the herdr config and session"

# --- 6c. Every herdr the fixture starts uses the run's own homes -----------
# The account's own herdr server keeps running beside the lane (#323). A
# stub herdr records the socket and XDG homes each fixture call hands it.

setup_home
STUB_ENV_DIR="$TMP_DIR/stubenv"
mkdir -p "$STUB_ENV_DIR"
cat > "$STUB_ENV_DIR/herdr" <<EOF
#!/bin/sh
printf 'socket=%s config=%s state=%s argv=%s\n' "\$HERDR_SOCKET_PATH" "\$XDG_CONFIG_HOME" "\$XDG_STATE_HOME" "\$*" >> "$TMP_DIR/stub-env.log"
EOF
chmod +x "$STUB_ENV_DIR/herdr"
: > "$TMP_DIR/stub-env.log"
RUN_DIR="$TMP_DIR/lvx-herdr-fixture-homes"
mkdir -p "$RUN_DIR"
printf '%s\n' "$STUB_ENV_DIR/herdr" > "$RUN_DIR/herdr.bin"
(
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  load_context "$RUN_DIR"
  herdr_cli server reload-config
  stop_workdir_processes "$RUN_DIR"
) 2>/dev/null
want="socket=$RUN_DIR/herdr.sock config=$RUN_DIR/config-home state=$RUN_DIR/state-home argv=server reload-config"
grep -qxF "$want" "$TMP_DIR/stub-env.log" \
  || fail "herdr_cli did not run on the fixture's own socket and homes:
$(cat "$TMP_DIR/stub-env.log")"
grep -q "config=$HOME/.config " "$TMP_DIR/stub-env.log" \
  && fail "a fixture herdr call inherited the account's config home:
$(cat "$TMP_DIR/stub-env.log")"
[[ "$(fixture_config_file "$RUN_DIR")" == "$RUN_DIR/config-home/herdr/config.toml" ]] \
  || fail "the fixture server's config file is not under the run's config home"
assert_account_is_pristine "after fixture herdr calls"
pass "fixture herdr calls run on the workdir's socket and config/state homes"

# --- 6d. An unbalanced marker stops the restore; the config is not cut -----
# A begin marker whose end a human deleted used to drop every line after it,
# the account's own included (#991). The restore must refuse and leave both
# the config and the hold as they are.

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-unbalanced"
sed -e "/^$SSH_CONFIG_END\$/d" "$SSH_CONFIG_FILE" > "$TMP_DIR/unbalanced"
printf 'Host added-by-the-human\n  HostName later.example\n' >> "$TMP_DIR/unbalanced"
cp "$TMP_DIR/unbalanced" "$SSH_CONFIG_FILE"
if ( command_recover ) 2>/dev/null; then
  fail "recover stripped an ssh config whose fixture markers do not balance"
fi
cmp -s "$TMP_DIR/unbalanced" "$SSH_CONFIG_FILE" \
  || fail "an unbalanced config was rewritten:
$(cat "$SSH_CONFIG_FILE")"
hold_is_present || fail "a failed restore dropped the hold it would retry from"
pass "an unbalanced fixture marker stops the restore with the ssh config byte-identical"

# --- 6e. A run killed while rewriting the config leaves it whole -----------
# SIGKILL just before the rename: the config is the one before the rewrite,
# byte for byte, and the next recover finishes the job.

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-midstrip"
cp "$SSH_CONFIG_FILE" "$TMP_DIR/before-strip"
# The outer subshell swallows bash's "Killed" report on the inner one; the
# command after the inner one keeps bash from exec'ing it in the outer's place.
( (
  mv() { sh -c 'kill -KILL $PPID'; }
  command_recover
); exit $? ) 2>/dev/null && fail "the kill before the rename did not fire"
cmp -s "$TMP_DIR/before-strip" "$SSH_CONFIG_FILE" \
  || fail "a kill mid-rewrite changed the ssh config:
$(cat "$SSH_CONFIG_FILE")"
command_recover 2>/dev/null
assert_account_is_pristine "after a recover killed mid-rewrite"
leftover="$(find "$HOME/.ssh" -name '.config.lvx-fixture.*' | head -1)"
[[ -z "$leftover" ]] || fail "recover left the killed run's staged config behind: $leftover"
pass "a run killed mid-rewrite leaves the ssh config whole, and recover finishes"

# --- 6f. A config edited while the fixture rewrites it is left alone --------

setup_home
simulate_up_then_kill "$TMP_DIR/lvx-herdr-fixture-race"
(
  chmod() { command chmod "$@"; printf 'Host typed-meanwhile\n' >> "$SSH_CONFIG_FILE"; }
  command_recover
) 2>/dev/null && fail "recover replaced an ssh config that changed under it"
grep -qx 'Host typed-meanwhile' "$SSH_CONFIG_FILE" \
  || fail "the rename discarded an edit made while the fixture rewrote the config"
hold_is_present || fail "a refused rewrite dropped the hold"
pass "an ssh config edited mid-rewrite is not replaced"

# --- 6g. A config without a final newline comes back byte-identical --------
# The fixture's append terminates the account's last line so its begin marker
# starts a line of its own; the restore takes that newline back.

setup_home
printf 'Host prod\n  HostName prod.example' > "$HOME/.ssh/config"
cp "$HOME/.ssh/config" "$GOLDEN/ssh_config"
mkdir -p "$TMP_DIR/lvx-herdr-fixture-noeol"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-noeol" 2>/dev/null
printf '%s\nHost lvx-herdr-fixture\n%s\n' "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_END" | append_ssh_config_block
printf '%s\nHost lvx-herdr-fixture-fed\n%s\n' "$SSH_CONFIG_FED_BEGIN" "$SSH_CONFIG_FED_END" | append_ssh_config_block
grep -qx "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_FILE" \
  || fail "the begin marker was glued onto the account's unterminated last line"
release_account_files 2>/dev/null
assert_account_is_pristine "after a run on a config without a final newline"

# The account adds an unterminated line after the fixture's blocks: it stays.
setup_home
mkdir -p "$TMP_DIR/lvx-herdr-fixture-noeol2"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-noeol2" 2>/dev/null
printf '%s\nHost lvx-herdr-fixture\n%s\n' "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_END" | append_ssh_config_block
printf 'Host later\n  HostName later.example' >> "$SSH_CONFIG_FILE"
release_account_files 2>/dev/null
printf '%sHost later\n  HostName later.example' "$PRISTINE_SSH" > "$GOLDEN/ssh_config"
assert_account_is_pristine "after the account added an unterminated line mid-run"
pass "a missing final newline survives the fixture's append and strip"

# --- 6h. A symlinked config stays a symlink --------------------------------

setup_home
mkdir -p "$HOME/dotfiles"
/bin/mv "$HOME/.ssh/config" "$HOME/dotfiles/ssh_config"
ln -s ../dotfiles/ssh_config "$HOME/.ssh/config"
mkdir -p "$TMP_DIR/lvx-herdr-fixture-link"
hold_account_files "$TMP_DIR/lvx-herdr-fixture-link" 2>/dev/null
printf '%s\nHost lvx-herdr-fixture\n%s\n' "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_END" | append_ssh_config_block
[[ -L "$HOME/.ssh/config" ]] || fail "the append replaced the symlinked config with a file"
grep -qx "$SSH_CONFIG_BEGIN" "$HOME/dotfiles/ssh_config" || fail "the append did not reach the link's target"
release_account_files 2>/dev/null
[[ -L "$HOME/.ssh/config" ]] || fail "the restore replaced the symlinked config with a file"
assert_account_is_pristine "after a run on a symlinked config"
pass "a symlinked ssh config stays a symlink and comes back byte-identical"

# --- 7. A SIGKILL between `machine add` and federation.json still stops the
# daemon-started remote server ---------------------------------------------
# `command_federation` commits the remote socket to the HOLD MANIFEST before
# `machine add` runs, precisely because federation.json only lands at the
# end. Teardown must therefore stop the server by the manifest-recorded
# socket when the workdir (and federation.json with it) is already gone.
# Herdr-free: a stub `herdr` records its argv; the manifest entry is created
# the way `command_federation` creates it.

setup_home
STUB_DIR="$TMP_DIR/stubbin"
mkdir -p "$STUB_DIR"
STUB_HERDR="$STUB_DIR/herdr"
cat > "$STUB_HERDR" <<EOF
#!/bin/sh
printf 'socket=%s argv=%s\n' "\$HERDR_SOCKET_PATH" "\$*" >> "$TMP_DIR/stub-argv.log"
EOF
chmod +x "$STUB_HERDR"
: > "$TMP_DIR/stub-argv.log"
export HERDR_BIN="$STUB_HERDR"
FED_DIR="$TMP_DIR/lvx-herdr-fixture-fedkill"
mkdir -p "$FED_DIR"
hold_account_files "$FED_DIR" 2>/dev/null
printf '24999\n' > "$FED_DIR/sshd.port"
HERDR_BINARY="$(resolve_herdr)"
record_federation_hold_state "$FED_DIR" 1
# The killed run's pid is not running, and its workdir is gone before
# teardown ever runs — federation.json never existed.
sed -e 's/^pid=.*/pid=999999/' "$HOLD_MANIFEST" > "$HOLD_MANIFEST.tmp"
mv "$HOLD_MANIFEST.tmp" "$HOLD_MANIFEST"
rm -rf "$FED_DIR"
command_recover 2>/dev/null
grep -q 'server stop' "$TMP_DIR/stub-argv.log" \
  || fail "recover never ran 'server stop' for the orphaned remote server:
$(cat "$TMP_DIR/stub-argv.log" 2>&1)"
grep -q 'lvx-herdr-fixture-fedkill/remote.sock' "$TMP_DIR/stub-argv.log" \
  || fail "recover stopped the wrong socket (want the manifest-recorded remote.sock):
$(cat "$TMP_DIR/stub-argv.log" 2>&1)"
assert_account_is_pristine "after recovering a SIGKILLed federation"
pass "a SIGKILLed federation's remote server stops by its manifest-recorded socket"
unset HERDR_BIN

# The live server creates a provisional pane while its whole-view client is
# starting. CI measured that pane surviving two one-second reads and then
# being replaced immediately afterwards. Three stable reads must select the
# replacement, not the provisional id.
printf '0\n' > "$TMP_DIR/pane-read-count"
herdr_cli() {
  local group="$1" verb="$2" count
  [[ "$group" == "pane" ]] || return 1
  if [[ "$verb" == "get" ]]; then
    return 0
  fi
  [[ "$verb" == "current" ]] || return 1
  count="$(sed -n '1p' "$TMP_DIR/pane-read-count")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TMP_DIR/pane-read-count"
  case "$count" in
    1|2) printf '{"pane_id":"w1:p1"}\n' ;;
    *) printf '{"pane_id":"w2:p1"}\n' ;;
  esac
}
sleep() { :; }
READY_TIMEOUT_SECONDS=10
settled="$(settle_focused_pane "$TMP_DIR" 2>/dev/null)"
[[ "$settled" == "w2:p1" ]] \
  || fail "pane settlement accepted provisional w1:p1 instead of stable w2:p1 (got $settled)"
pass "pane settlement rejects an id that survives only two samples"

printf '\nAll herdr fixture recovery checks passed.\n'
