#!/usr/bin/env bash
# Stand up (and tear down) the live fixture the `integration-herdr` lane runs
# against: a real `herdr` server with a real pane, a real loopback sshd the
# app's own `ssh -L` forward can dial, and a real whole-view herdr client
# rendered into a pty whose output is the "focused surface" the panel-binding
# probe reads.
#
# Everything BELOW the focused surface is production code in that lane. The
# only fixture is the surface itself: a pty running the real herdr client,
# scraped from its typescript instead of from a terminal's accessibility tree.
#
# Usage:
#   scripts/herdr-integration-fixture.sh up      <workdir> [ssh-destination]
#   scripts/herdr-integration-fixture.sh surface <workdir> <name> <app|attach|observe> [pane-id]
#   scripts/herdr-integration-fixture.sh federation <workdir>
#   scripts/herdr-integration-fixture.sh federation-select <workdir> <profile-id|local>
#   scripts/herdr-integration-fixture.sh reload  <workdir>
#   scripts/herdr-integration-fixture.sh down    <workdir>
#   scripts/herdr-integration-fixture.sh recover
#   scripts/herdr-integration-fixture.sh status
#
# `up` prints one JSON object on stdout describing the fixture; every other
# diagnostic goes to stderr. With no ssh-destination it provisions its OWN
# loopback sshd (hermetic: no second machine, nothing added to the account's
# real authorized_keys) and uses the alias `lvx-herdr-fixture`. Pass a
# destination to aim the same lane at a real second host instead; the ssh half
# is then the caller's own already-working configuration.
#
# Destination mode leaves the second host's herdr server running by design:
# teardown closes only the workspace the federation step created
# (`workspace close <id>` over the same ssh, best-effort, logged) and never
# runs `herdr server stop` there — that server may hold a human's live
# session. A `workspace create` + `report-agent` residue may briefly remain
# if the close fails; the server itself is never stopped.
#
# ## Files this borrows from the account, and how they come back
#
# For the duration of a run the fixture replaces the account's herdr
# `config.toml`, removes its `session.json`, and appends three delimited blocks
# to its `~/.ssh/config` (the connection block, the canonicalization-test
# block, and — hermetic mode only — the federation block). It has to touch the REAL ssh config because the code
# under test never passes `-F`: the app's forward argv and
# `SSHDestinationCanonicalizer.live()` both run `ssh` / `ssh -G` against the
# user's default configuration chain, so an alias that only existed in a
# fixture-local file would exercise an invocation shape the app never
# produces.
#
# Because a run can be SIGKILLed (a torn-down runner, a sleeping Mac, a manual
# kill of a wedged xctest), the pristine originals do NOT live in the run's own
# temp dir — that would strand them when the run dies, and the NEXT run would
# then back up the already-modified files and destroy the originals for good.
# They live at a stable, discoverable path instead:
#
#   ~/.localvoxtral-herdr-fixture-hold/   manifest + pristine copies
#
# The manifest is written AFTER the pristine copies and BEFORE the first
# modification, so a crash at any point leaves either nothing held or a
# complete, restorable hold. `up` refuses to overwrite an existing hold; it
# restores a dead run's hold first, and refuses outright while a live run owns
# it. `recover` restores by hand. The `federation` verb commits its own
# teardown state (remote socket / destination target + created workspace) to
# the same manifest BEFORE `machine add`, so a SIGKILL mid-federation still
# leaves a record teardown can act on.
#
# Deliberately loud: every precondition that cannot be met exits non-zero with
# the exact recovery or provisioning step. This lane must never look green
# because something was missing.
set -euo pipefail

FIXTURE_ALIAS="lvx-herdr-fixture"
# The integration id the fixture reports its pane's agent under. Deliberately
# NOT "localvoxtral": the app's own metadata source must stay distinguishable
# from the fixture's agent report in herdr's own records.
FIXTURE_AGENT_SOURCE="lvxfixture"
SSH_CONFIG_BEGIN="# BEGIN localvoxtral herdr integration fixture"
SSH_CONFIG_END="# END localvoxtral herdr integration fixture"
SSH_CONFIG_ALT_BEGIN="# BEGIN localvoxtral herdr integration fixture aliases"
SSH_CONFIG_ALT_END="# END localvoxtral herdr integration fixture aliases"
SSH_CONFIG_FED_BEGIN="# BEGIN localvoxtral herdr integration fixture federation"
SSH_CONFIG_FED_END="# END localvoxtral herdr integration fixture federation"
# The federated machine the `federation` verb adds: its label as shown in the
# client's machines sidebar.
FEDERATION_ALIAS_SUFFIX="-fed"
FEDERATION_LABEL="lvx-federation"
# The remote server's socket when the lane addresses it directly (hermetic
# loopback only): a short path under the workdir. macOS caps sun_path at 104
# bytes, and the lane's workdir names alone can reach 56 — a named session's
# socket (<config>/sessions/<name>/herdr.sock) does not fit, measured
# 2026-09-13 as "local socket name length exceeds capacity of sun_path".
FEDERATION_REMOTE_SOCKET_NAME="remote.sock"
# The integration id the remote pane's agent is reported under. Distinct from
# the local pane's session so the two endpoints' rows stay distinguishable in
# herdr's own records.
FEDERATION_AGENT_SESSION_ID="lvx-fixture-session-0002"
# Wide enough that herdr renders the desktop layout with its agents sidebar
# (herdr's mobile_width_threshold is 64 columns and the sidebar is 26).
SURFACE_COLUMNS=130
SURFACE_ROWS=45
READY_TIMEOUT_SECONDS=30

# Account-level paths, resolved once at load. A sourcing test sets HOME before
# sourcing this file (see scripts/ci/test-herdr-fixture-recovery.sh).
HERDR_CONFIG_FILE="$HOME/.config/herdr/config.toml"
HERDR_SESSION_FILE="$HOME/.config/herdr/session.json"
SSH_CONFIG_FILE="$HOME/.ssh/config"
HOLD_DIR="$HOME/.localvoxtral-herdr-fixture-hold"
HOLD_MANIFEST="$HOLD_DIR/manifest"

log() { printf '[herdr-fixture] %s\n' "$*" >&2; }

environment_value() {
  local name="$1" value
  value="$(printenv "$name" 2>/dev/null || true)"
  [[ -n "$value" ]] && printf '%s' "$value" || printf '<unset>'
}

tty_state() {
  local descriptor="$1"
  [[ -t "$descriptor" ]] && printf 'tty' || printf 'not-a-tty'
}

record_start_diagnostics() {
  local dir="$1" inherited_socket="$2" account_status="$3" version config_state session_state
  version="$("$HERDR_BINARY" --version 2>&1 | head -1)"
  [[ -e "$HERDR_CONFIG_FILE" ]] && config_state=present || config_state=absent
  [[ -e "$HERDR_SESSION_FILE" ]] && session_state=present || session_state=absent
  {
    printf 'account=%s uid=%s home=%s\n' "$(id -un)" "$(id -u)" "$HOME"
    printf 'herdr.binary=%s\n' "$HERDR_BINARY"
    printf 'herdr.version=%s\n' "$version"
    printf 'herdr.status.before=%s\n' "${account_status:-<empty>}"
    printf 'herdr.socket.inherited=%s\n' "${inherited_socket:-<unset>}"
    printf 'herdr.socket.fixture=%s\n' "$HERDR_SOCKET_PATH"
    printf 'herdr.config=%s state=%s\n' "$HERDR_CONFIG_FILE" "$config_state"
    printf 'herdr.session=%s state=%s\n' "$HERDR_SESSION_FILE" "$session_state"
    printf 'env.PATH=%s\n' "$PATH"
    printf 'env.XDG_CONFIG_HOME=%s\n' "$(environment_value XDG_CONFIG_HOME)"
    printf 'env.XDG_RUNTIME_DIR=%s\n' "$(environment_value XDG_RUNTIME_DIR)"
    printf 'env.TERM=%s env.COLUMNS=%s env.LINES=%s\n' \
      "$(environment_value TERM)" "$(environment_value COLUMNS)" "$(environment_value LINES)"
    printf 'stdio.stdin=%s stdout=%s stderr=%s\n' \
      "$(tty_state 0)" "$(tty_state 1)" "$(tty_state 2)"
    printf 'script.binary=%s\n' "$(command -v script 2>/dev/null || printf '<missing>')"
    printf 'pty.requested=%sx%s\n' "$SURFACE_ROWS" "$SURFACE_COLUMNS"
    printf 'sidebar.configured_width=26 mobile_width_threshold=64\n'
  } | tee "$dir/environment.txt" >&2
}

# Set while `up` is between "started modifying things" and "fully succeeded".
# A failure in that window restores through the EXIT trap; a KILL in it (or at
# any point afterwards) is what the hold directory exists for.
UP_IN_PROGRESS_DIR=""

restore_after_failed_up() {
  local status=$?
  if (( status != 0 )) && [[ -n "$UP_IN_PROGRESS_DIR" ]]; then
    log "up failed (status $status) — restoring this account's files"
    command_down "$UP_IN_PROGRESS_DIR" >/dev/null 2>&1 || true
  fi
}

die() {
  printf '[herdr-fixture] ERROR: %s\n' "$*" >&2
  exit 1
}

recovery_hint() {
  printf '%s recover' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------- held state

hold_is_present() { [[ -f "$HOLD_MANIFEST" ]]; }

hold_field() {
  local key="$1"
  [[ -f "$HOLD_MANIFEST" ]] || return 0
  sed -n "s/^${key}=//p" "$HOLD_MANIFEST" | head -1
}

# Upsert one key=value line in the hold manifest — the stable path that
# survives a SIGKILL of the run, unlike anything under the workdir.
# `command_federation` commits its teardown state here BEFORE `machine add`
# daemon-starts anything, so `down`, `recover` and stale-hold reclaim can
# stop the hermetic remote server by the recorded socket (or close the
# created destination workspace) even when federation.json was never written.
record_hold_field() {
  local key="$1" value="$2" tmp
  [[ -f "$HOLD_MANIFEST" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvx-hold.XXXXXX")"
  grep -v "^${key}=" "$HOLD_MANIFEST" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$HOLD_MANIFEST"
  rm -f "$tmp"
}

# Is the process that took the hold still running THIS script? A pid alone
# would be fooled by reuse; the command check makes a false "live" essentially
# impossible, and a false "dead" only costs a restore that was going to happen
# anyway.
hold_owner_is_alive() {
  local pid
  pid="$(hold_field pid)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'herdr-integration-fixture' || return 1
  return 0
}

# Copy the account's files aside and COMMIT the manifest, in that order, before
# anything is modified. Refuses if a hold already exists: overwriting a
# pristine copy with an already-modified file is the one step that turns a
# recoverable interruption into permanent data loss.
hold_account_files() {
  local dir="$1"
  if hold_is_present; then
    die "held state already exists at $HOLD_DIR; refusing to overwrite the pristine copies.
  Run: $(recovery_hint)"
  fi
  mkdir -p "$HOLD_DIR"
  chmod 700 "$HOLD_DIR"
  rm -f "$HOLD_DIR"/*.pristine "$HOLD_DIR"/*.absent "$HOLD_DIR"/*.created 2>/dev/null || true

  mkdir -p "$(dirname "$HERDR_CONFIG_FILE")"
  if [[ -f "$HERDR_CONFIG_FILE" ]]; then
    cp "$HERDR_CONFIG_FILE" "$HOLD_DIR/herdr-config.pristine"
  else
    : > "$HOLD_DIR/herdr-config.absent"
  fi
  if [[ -f "$HERDR_SESSION_FILE" ]]; then
    cp "$HERDR_SESSION_FILE" "$HOLD_DIR/herdr-session.pristine"
  else
    : > "$HOLD_DIR/herdr-session.absent"
  fi
  mkdir -p "$(dirname "$SSH_CONFIG_FILE")"
  chmod 700 "$(dirname "$SSH_CONFIG_FILE")"
  if [[ -f "$SSH_CONFIG_FILE" ]]; then
    # Informational only — the ssh config is restored by REMOVING our
    # delimited blocks, never by writing this copy back, so an edit the user
    # makes while the lane runs survives.
    cp "$SSH_CONFIG_FILE" "$HOLD_DIR/ssh-config.pristine"
  else
    : > "$HOLD_DIR/ssh-config.created"
  fi

  # Manifest last, and atomically: a crash before this leaves pristine copies
  # nobody will read and nothing modified; a crash after it leaves a hold that
  # `up` or `recover` can act on.
  {
    printf 'workdir=%s\n' "$dir"
    printf 'pid=%s\n' "$$"
    printf 'startedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'home=%s\n' "$HOME"
  } > "$HOLD_DIR/manifest.tmp"
  mv "$HOLD_DIR/manifest.tmp" "$HOLD_MANIFEST"
  log "holding this account's herdr config, session and ssh config (backups in $HOLD_DIR)"
}

# Drop our delimited blocks from the ssh config in place. Idempotent, and it
# leaves anything the user added while the lane ran untouched.
strip_ssh_config_blocks() {
  [[ -f "$SSH_CONFIG_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvx-sshcfg.XXXXXX")"
  awk -v b1="$SSH_CONFIG_BEGIN" -v e1="$SSH_CONFIG_END" \
      -v b2="$SSH_CONFIG_ALT_BEGIN" -v e2="$SSH_CONFIG_ALT_END" \
      -v b3="$SSH_CONFIG_FED_BEGIN" -v e3="$SSH_CONFIG_FED_END" '
    $0 == b1 || $0 == b2 || $0 == b3 { skip = 1; next }
    $0 == e1 || $0 == e2 || $0 == e3 { skip = 0; next }
    !skip { print }
  ' "$SSH_CONFIG_FILE" > "$tmp"
  cat "$tmp" > "$SSH_CONFIG_FILE"
  rm -f "$tmp"
  chmod 600 "$SSH_CONFIG_FILE"
  # Only remove the file if the fixture is the reason it exists at all.
  if [[ ! -s "$SSH_CONFIG_FILE" && -f "$HOLD_DIR/ssh-config.created" ]]; then
    rm -f "$SSH_CONFIG_FILE"
  fi
}

# Put the account back and drop the hold. Safe to call when nothing is held.
release_account_files() {
  hold_is_present || return 0
  mkdir -p "$(dirname "$HERDR_CONFIG_FILE")"
  if [[ -f "$HOLD_DIR/herdr-config.pristine" ]]; then
    cp "$HOLD_DIR/herdr-config.pristine" "$HERDR_CONFIG_FILE"
  elif [[ -f "$HOLD_DIR/herdr-config.absent" ]]; then
    rm -f "$HERDR_CONFIG_FILE"
  fi
  if [[ -f "$HOLD_DIR/herdr-session.pristine" ]]; then
    cp "$HOLD_DIR/herdr-session.pristine" "$HERDR_SESSION_FILE"
  elif [[ -f "$HOLD_DIR/herdr-session.absent" ]]; then
    rm -f "$HERDR_SESSION_FILE"
  fi
  strip_ssh_config_blocks
  rm -rf "$HOLD_DIR"
  log "restored this account's herdr config, session and ssh config"
}

# `down <dir>` must not release a hold that belongs to a DIFFERENT run.
release_account_files_if_held_by() {
  local dir="$1" owner
  hold_is_present || return 0
  owner="$(hold_field workdir)"
  if [[ -n "$owner" && "$owner" != "$dir" ]]; then
    log "held state belongs to $owner, not $dir — leaving it alone"
    return 0
  fi
  release_account_files
}

# Called at the START of `up`. A hold from a run that is still alive means two
# lanes are racing for one account: refuse. A hold from a dead run is exactly
# what the stable path exists for: restore it, loudly, and carry on.
reclaim_or_refuse_stale_hold() {
  hold_is_present || return 0
  local owner started
  owner="$(hold_field workdir)"
  started="$(hold_field startedAt)"
  if hold_owner_is_alive; then
    die "another herdr fixture run (pid $(hold_field pid), started $started) is holding
  this account's files. Wait for it to finish, or if you know it is dead:
    $(recovery_hint)"
  fi
  log "found held state from an interrupted run (started $started, workdir $owner)"
  if [[ -n "$owner" ]]; then
    # Manifest-aware: stops the daemon-started hermetic remote server by its
    # recorded socket (or closes the created destination workspace) even when
    # the workdir — and federation.json with it — is already gone.
    stop_federation_server "$owner"
    if [[ -d "$owner" ]]; then
      stop_workdir_processes "$owner"
      rm -rf "$owner"
    fi
  fi
  release_account_files
  if hold_is_present; then
    die "could not restore the interrupted run's held state. Run: $(recovery_hint)"
  fi
}

# ------------------------------------------------------------- helpers

# Absolute path to the herdr binary. PATH first (so an owner's own install
# wins), then the two package-manager prefixes; never a relative path.
resolve_herdr() {
  if [[ -n "${HERDR_BIN:-}" ]]; then
    [[ -x "$HERDR_BIN" ]] || die "HERDR_BIN is set but not executable: $HERDR_BIN"
    printf '%s\n' "$HERDR_BIN"
    return 0
  fi
  local candidate
  if candidate="$(command -v herdr 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in /opt/homebrew/bin/herdr /usr/local/bin/herdr "$HOME/.cargo/bin/herdr" "$HOME/bin/herdr"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "herdr is not installed on this machine.
  The integration-herdr lane exercises a LIVE herdr server; it cannot be
  simulated. Install it (brew install herdr, or https://herdr.dev) or point
  HERDR_BIN at an existing binary, then re-run the lane."
}

# Quiet, read-only probe for the `herdr machine` subcommand (herdr 0.9.0+).
# Used by `up` to decide whether surfaces need client-state isolation, and by
# the `federation` verb as its loud version gate. Reads only; never writes.
# Always runs with XDG_STATE_HOME pointed at scratch — the caller's scratch
# client dir when one exists, otherwise an empty temp dir — so the account's
# ~/.local/state/herdr/client/ catalog is never read, even on a runner that
# has a real 0.9 catalog of its own.
machine_catalog_available_quietly() {
  local state_home="${1:-}" scratch=""
  scrub_herdr_env
  if [[ -z "$state_home" ]]; then
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/lvx-herdr-catalog-sniff.XXXXXX")"
    state_home="$scratch"
  fi
  local status=0
  XDG_STATE_HOME="$state_home" "$HERDR_BINARY" machine list --json </dev/null >/dev/null 2>&1 || status=$?
  [[ -n "$scratch" ]] && rm -rf "$scratch"
  return $status
}

validate_workdir() {
  local dir="$1"
  [[ "$dir" == /* ]] || die "workdir must be an absolute path: $dir"
  [[ "$dir" != "/" && "$dir" != "$HOME" ]] || die "refusing to use $dir as a workdir"
  case "$dir" in
    */lvx-herdr-fixture-*) ;;
    *) die "workdir basename must start with lvx-herdr-fixture- (got $dir)" ;;
  esac
}

free_port() {
  # A loopback port nothing is listening on. Deliberately not "bind 0 and
  # release": that races the same way and needs a language runtime. A
  # collision here is not silent — sshd fails to bind and `up` dies on the
  # readiness wait with its log attached.
  local attempt port
  for attempt in $(seq 1 40); do
    port=$(( 20000 + RANDOM % 20000 ))
    if ! nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  die "could not find a free loopback port for the fixture sshd"
}

herdr_cli() {
  scrub_herdr_env
  HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" "$HERDR_BINARY" "$@"
}

# Drop the herdr session variables a runner may itself live under. A lane that
# runs inside a herdr pane inherits HERDR_PANE_ID (making `pane current` answer
# about the RUNNER's pane — measured 2026-09-13 as pane_not_found against
# scratch servers) and HERDR_ENV (tripping the nested-client guard for every
# surface); HERDR_SESSION would retarget every --session-less command. The
# fixture always addresses its servers explicitly, so these are never wanted.
# No-op on a clean runner, which is why the existing verbs are safe to harden.
scrub_herdr_env() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION || true
}

record_pane_snapshot() {
  local dir="$1" event="$2" pane="${3:-}"
  [[ -S "$HERDR_SOCKET_PATH" ]] || return 0
  {
    printf '\n[%s] event=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$event"
    printf 'current='; herdr_cli pane current 2>&1 || true
    if [[ -n "$pane" ]]; then
      printf 'selected='; herdr_cli pane get "$pane" 2>&1 || true
    fi
  } >> "$dir/pane-lifecycle.log"
}

# Kill whatever a run left behind in its own workdir. Touches no account files.
stop_workdir_processes() {
  local dir="$1" pid binary
  scrub_herdr_env
  [[ -d "$dir" ]] || return 0
  binary="$(cat "$dir/herdr.bin" 2>/dev/null || true)"
  if [[ -f "$dir/surface.pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < "$dir/surface.pids"
  fi
  if [[ -x "$binary" ]]; then
    HERDR_SOCKET_PATH="$dir/herdr.sock" "$binary" server stop >/dev/null 2>&1 || true
  fi
  for pid in "$dir/server.child.pid" "$dir/sshd.child.pid" "$dir/sshd.pid"; do
    kill "$(cat "$pid" 2>/dev/null || true)" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------- up

provision_loopback_sshd() {
  local dir="$1" port
  port="$(free_port)"

  ssh-keygen -q -t ed25519 -N '' -f "$dir/hostkey" -C "localvoxtral-herdr-fixture-host"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/id" -C "localvoxtral-herdr-fixture-user"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/id-fed" -C "localvoxtral-herdr-fixture-federation"
  chmod 600 "$dir/hostkey" "$dir/id" "$dir/id-fed"

  # The fixture's OWN authorized_keys file — never the account's. The
  # environment= options are what make the remote half of the enrollment
  # config patch (`herdr server reload-config`) resolvable in a
  # non-interactive shell, which is where a real deployment gets it from the
  # user's login profile instead.
  #
  # The second key is the federation key. Its entry forces XDG_CONFIG_HOME and
  # HERDR_SOCKET_PATH onto every remote herdr invocation over the `-fed`
  # alias. The forced socket is the whole reason the profile below targets the
  # DEFAULT remote session rather than a named one: a `herdr --session <name>`
  # command resolves its socket from the session name and IGNORES
  # HERDR_SOCKET_PATH (src/session.rs: explicit session wins over the env),
  # landing on <config>/sessions/<name>/herdr.sock — which does not fit
  # macOS's 104-byte sun_path under the lane's workdir layout (measured
  # 2026-09-13). With no --session flag the forced socket IS honored, so the
  # "remote machine" is still a genuinely separate server (own socket, own
  # panes, own row-less config file) at a path with room to spare. The
  # enrollment/forward key keeps its own entry so those verbs still reach the
  # account's real config.
  {
    printf 'environment="PATH=%s:/usr/bin:/bin:/usr/sbin:/sbin",' \
      "$(dirname "$HERDR_BINARY")"
    printf 'environment="HERDR_SOCKET_PATH=%s" ' "$HERDR_SOCKET_PATH"
    cat "$dir/id.pub"
    printf 'environment="PATH=%s:/usr/bin:/bin:/usr/sbin:/sbin",' \
      "$(dirname "$HERDR_BINARY")"
    printf 'environment="XDG_CONFIG_HOME=%s",' "$dir/remote-config-home"
    printf 'environment="HERDR_SOCKET_PATH=%s" ' "$dir/$FEDERATION_REMOTE_SOCKET_NAME"
    cat "$dir/id-fed.pub"
  } > "$dir/authorized_keys"
  chmod 600 "$dir/authorized_keys"

  printf '[127.0.0.1]:%s ' "$port" > "$dir/known_hosts"
  cat "$dir/hostkey.pub" >> "$dir/known_hosts"

  cat > "$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/hostkey
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
StrictModes no
UsePAM no
PermitUserEnvironment yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PrintMotd no
LogLevel DEBUG1
EOF

  # Detached from this shell's stdio on purpose: a daemon that keeps the
  # caller's stdout pipe open makes every `up` look like a hang to a parent
  # that reads to EOF.
  /usr/sbin/sshd -D -f "$dir/sshd_config" -E "$dir/sshd.log" \
    </dev/null >>"$dir/sshd.out" 2>&1 &
  echo $! > "$dir/sshd.child.pid"
  log "loopback sshd starting on 127.0.0.1:$port"

  local waited=0
  until nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; do
    (( waited < READY_TIMEOUT_SECONDS )) || die "loopback sshd never listened on $port; see $dir/sshd.log"
    sleep 1
    waited=$((waited + 1))
  done

  {
    printf '%s\n' "$SSH_CONFIG_BEGIN"
    printf 'Host %s\n' "$FIXTURE_ALIAS"
    printf '  HostName 127.0.0.1\n'
    printf '  Port %s\n' "$port"
    printf '  User %s\n' "$(id -un)"
    printf '  IdentityFile %s\n' "$dir/id"
    printf '  IdentitiesOnly yes\n'
    printf '  UserKnownHostsFile %s\n' "$dir/known_hosts"
    printf '  StrictHostKeyChecking yes\n'
    printf '%s\n' "$SSH_CONFIG_END"
  } >> "$SSH_CONFIG_FILE"
  # The federation alias: same loopback sshd, the federation key (whose entry
  # forces XDG_CONFIG_HOME and HERDR_SOCKET_PATH onto every remote herdr
  # invocation over the `-fed` alias — see the authorized_keys entry above).
  # `machine add` and every federated bridge resolve their target through the
  # REAL ssh config (the bridge spawns plain `ssh`, measured 2026-09-13), which is why
  # this block lives here and not in a fixture-local file.
  {
    printf '%s\n' "$SSH_CONFIG_FED_BEGIN"
    printf 'Host %s%s\n' "$FIXTURE_ALIAS" "$FEDERATION_ALIAS_SUFFIX"
    printf '  HostName 127.0.0.1\n'
    printf '  Port %s\n' "$port"
    printf '  User %s\n' "$(id -un)"
    printf '  IdentityFile %s\n' "$dir/id-fed"
    printf '  IdentitiesOnly yes\n'
    printf '  UserKnownHostsFile %s\n' "$dir/known_hosts"
    printf '  StrictHostKeyChecking yes\n'
    printf '%s\n' "$SSH_CONFIG_FED_END"
  } >> "$SSH_CONFIG_FILE"
  chmod 600 "$SSH_CONFIG_FILE"
  printf '%s\n' "$port" > "$dir/sshd.port"
}

# Two extra aliases the canonicalization test needs, derived from wherever the
# lane's destination actually points:
#   <alias>-altuser    same (hostname, port), a DIFFERENT User — must still
#                      match, because `ssh -G` always prints an effective user
#                      and comparing it would reject the alias shape this
#                      fallback exists for.
#   <alias>-otherport  same hostname, a different port — must NOT match.
# Written for BOTH modes so the test asserts the same thing whether the lane
# runs hermetically or against a real second host.
write_canonicalization_aliases() {
  local alias_used="$1" hostname port other_port
  hostname="$(ssh -G -- "$alias_used" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
  port="$(ssh -G -- "$alias_used" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  if [[ -z "$hostname" || -z "$port" ]]; then
    die "ssh -G could not resolve '$alias_used'; the lane needs a destination ssh can configure"
  fi
  if (( port >= 65535 )); then other_port=$((port - 1)); else other_port=$((port + 1)); fi
  {
    printf '%s\n' "$SSH_CONFIG_ALT_BEGIN"
    printf 'Host %s-altuser\n' "$alias_used"
    printf '  HostName %s\n' "$hostname"
    printf '  Port %s\n' "$port"
    printf '  User lvxaltuser\n'
    printf 'Host %s-otherport\n' "$alias_used"
    printf '  HostName %s\n' "$hostname"
    printf '  Port %s\n' "$other_port"
    printf '%s\n' "$SSH_CONFIG_ALT_END"
  } >> "$SSH_CONFIG_FILE"
  chmod 600 "$SSH_CONFIG_FILE"
}

start_surface() {
  local dir="$1" name="$2" mode="$3" pane="${4:-}" geometry
  geometry="$dir/surface-$name.geometry"
  local -a inner
  case "$mode" in
    app) inner=("$HERDR_BINARY") ;;
    attach)
      [[ -n "$pane" ]] || die "surface mode 'attach' needs a pane id"
      inner=("$HERDR_BINARY" terminal attach "$pane")
      ;;
    observe)
      [[ -n "$pane" ]] || die "surface mode 'observe' needs a pane id"
      inner=("$HERDR_BINARY" terminal session observe "$pane")
      ;;
    *) die "unknown surface mode: $mode" ;;
  esac
  # `script` gives the client a real pty; `stty` fixes the geometry so the
  # rendered layout is deterministic (herdr drops the sidebar entirely below
  # its mobile width threshold, which would make a no-match meaningless).
  # `-t 0` flushes the typescript on every I/O event. Without it `script`
  # buffers in 4 KiB blocks, so a freshly painted frame can sit unwritten and
  # the surface read would answer about the past.
  #
  # A 0.9 client keeps its machine catalog under $XDG_STATE_HOME/herdr/client
  # and would otherwise read and write the ACCOUNT's real catalog. Point it at
  # the run's scratch dir — but only when `up` created one (i.e. this herdr
  # knows `machine`): on an older herdr the dir is absent and the surface
  # behaves exactly as before.
  #
  # Scrubbed (see scrub_herdr_env): a runner living inside a herdr pane would
  # otherwise hand its own pane id to every client it starts.
  local -a surface_env=(TERM=xterm-256color "HERDR_SOCKET_PATH=$HERDR_SOCKET_PATH")
  if [[ -d "$dir/client-state-home" ]]; then
    surface_env+=("XDG_STATE_HOME=$dir/client-state-home")
  fi
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SESSION \
    "${surface_env[@]}" \
    script -q -t 0 "$dir/surface-$name.log" \
    /bin/sh -c '
      rows="$1"; columns="$2"; geometry="$3"; shift 3
      stty rows "$rows" cols "$columns"
      {
        printf "pty.rows_cols="; stty size
        printf "pty.stdin=%s stdout=%s stderr=%s controlling_tty=%s\n" \
          "$([[ -t 0 ]] && echo tty || echo not-a-tty)" \
          "$([[ -t 1 ]] && echo tty || echo not-a-tty)" \
          "$([[ -t 2 ]] && echo tty || echo not-a-tty)" \
          "$(tty 2>/dev/null || echo none)"
        printf "env.TERM=%s env.COLUMNS=%s env.LINES=%s\n" \
          "${TERM:-<unset>}" "${COLUMNS:-<unset>}" "${LINES:-<unset>}"
      } > "$geometry"
      exec "$@"
    ' fixture-surface "$SURFACE_ROWS" "$SURFACE_COLUMNS" "$geometry" "${inner[@]}" \
    </dev/null >/dev/null 2>&1 &
  echo $! >> "$dir/surface.pids"
  local waited=0
  until [[ -s "$geometry" ]]; do
    (( waited < READY_TIMEOUT_SECONDS * 10 )) \
      || die "surface '$name' never recorded its pty geometry"
    sleep 0.1
    waited=$((waited + 1))
  done
  log "surface '$name' ($mode) started -> $dir/surface-$name.log"
  sed "s/^/[herdr-fixture] surface.$name./" "$geometry" >&2
  record_pane_snapshot "$dir" "surface-$name-started" "$pane"
}

# Print the focused pane id once it is stable: UNCHANGED across three reads a
# second apart AND still resolving via `pane get`. Dies loudly past the
# readiness timeout. Callers that act on the id (report-agent) must still
# handle it dying afterwards — settle narrows the race, it does not close it.
settle_focused_pane() {
  local dir="$1" pane_id="" candidate="" stable_reads=0 waited=0
  while true; do
    # `|| true`: before a pane exists, `pane current` answers with a
    # pane_not_found ERROR and a non-zero status, which `pipefail` would
    # otherwise turn into an abort on the very first poll.
    pane_id="$({ herdr_cli pane current 2>/dev/null || true; } \
      | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)"
    if [[ -n "$pane_id" ]] && herdr_cli pane get "$pane_id" >/dev/null 2>&1; then
      if [[ "$pane_id" == "$candidate" ]]; then
        stable_reads=$((stable_reads + 1))
      else
        candidate="$pane_id"
        stable_reads=1
      fi
      if (( stable_reads >= 3 )); then
        log "focused pane: $pane_id (stable across $stable_reads reads)"
        printf '%s\n' "$pane_id"
        return 0
      fi
    else
      candidate=""
      stable_reads=0
    fi
    if (( waited >= READY_TIMEOUT_SECONDS )); then
      die "herdr never settled on a focused pane; see $dir/surface-primary.log and $dir/server.log"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

command_up() {
  local dir="$1" destination="${2:-}"
  validate_workdir "$dir"
  [[ ! -e "$dir" ]] || die "workdir already exists: $dir (run 'down' first)"

  local inherited_socket="${HERDR_SOCKET_PATH:-}" account_status
  HERDR_BINARY="$(resolve_herdr)"
  log "herdr binary: $HERDR_BINARY ($("$HERDR_BINARY" --version 2>&1 | head -1))"
  account_status="$("$HERDR_BINARY" status server 2>&1 | tr '\n' ' ' || true)"

  # The fixture owns this account's herdr config, its session state and a
  # block in its ssh config for the duration of the lane. If the account
  # already has a herdr running, those files belong to a human right now —
  # refuse rather than trample them.
  if grep -q '^status: running' <<<"$account_status"; then
    die "a herdr server is already running for $(id -un).
  This lane takes over the account's herdr config and session state for the
  duration of the run, so it refuses to start beside a live one. Quit herdr
  (or run the lane as a different account) and try again."
  fi

  # Before anything is created or modified: hand back whatever an interrupted
  # run left held, or refuse if a live run owns it.
  reclaim_or_refuse_stale_hold

  mkdir -p "$dir"
  chmod 700 "$dir"
  UP_IN_PROGRESS_DIR="$dir"
  HERDR_SOCKET_PATH="$dir/herdr.sock"
  export HERDR_SOCKET_PATH
  # Recorded first, so teardown can still reach the binary if `up` dies partway.
  printf '%s\n' "$HERDR_BINARY" > "$dir/herdr.bin"

  record_start_diagnostics "$dir" "$inherited_socket" "$account_status"

  hold_account_files "$dir"

  # The forward under test builds its argv from the ALIAS alone and never
  # passes -F, so the fixture's connection details have to live where ssh
  # actually looks: the account's ~/.ssh/config, in delimited blocks teardown
  # removes again. This is the same file the app's own enrollment writes its
  # host blocks into.
  if [[ -f "$SSH_CONFIG_FILE" ]] \
    && grep -qF "$SSH_CONFIG_BEGIN" "$SSH_CONFIG_FILE"; then
    die "a fixture block is still in $SSH_CONFIG_FILE. Run: $(recovery_hint)"
  fi

  local alias_used="$destination" provisioned_ssh=0
  if [[ -z "$destination" ]]; then
    alias_used="$FIXTURE_ALIAS"
    provisioned_ssh=1
    provision_loopback_sshd "$dir"
  else
    log "using caller-supplied ssh destination '$destination' (no sshd provisioned)"
  fi
  write_canonicalization_aliases "$alias_used"

  # Federation capability sniff (quiet, read-only): does this herdr know
  # `machine`? On 0.9+ every surface the lane starts must run with
  # XDG_STATE_HOME pointed at the run's scratch dir (created here), or the
  # 0.9 client would read and write the ACCOUNT's real machine catalog. On an
  # older herdr the sniff fails, no dir is created, and every surface behaves
  # exactly as before — the pre-federation lane stays green there.
  if machine_catalog_available_quietly; then
    mkdir -p "$dir/client-state-home"
    chmod 700 "$dir/client-state-home"
    log "herdr knows machine federation; client state isolated at $dir/client-state-home"
  else
    log "herdr has no machine subcommand; federation tests will refuse (need 0.9.0+)"
  fi

  # herdr persists its workspace/pane layout and restores it on the next
  # start. A leftover session makes pane ids (and how many panes exist) depend
  # on what ran before, which is exactly what a lane must not do.
  rm -f "$HERDR_SESSION_FILE"
  # `onboarding = false` matters: herdr's first-run setup screen has no
  # workspace and therefore no pane, so `pane.current` answers pane_not_found
  # forever and the fixture would never become ready. The update checks are
  # off so the lane makes no network requests.
  cat > "$HERDR_CONFIG_FILE" <<'EOF'
onboarding = false

[update]
version_check = false
manifest_check = false

[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
EOF

  herdr_cli server </dev/null >"$dir/server.log" 2>&1 &
  echo $! > "$dir/server.child.pid"

  local waited=0
  until [[ -S "$HERDR_SOCKET_PATH" ]]; do
    (( waited < READY_TIMEOUT_SECONDS )) || die "herdr server never created $HERDR_SOCKET_PATH; see $dir/server.log"
    sleep 1
    waited=$((waited + 1))
  done
  log "herdr server listening on $HERDR_SOCKET_PATH"

  # The whole-view client creates the pane whose rendered output the lane
  # reads. Require its id to be unchanged across three reads and to resolve.
  : > "$dir/surface.pids"
  start_surface "$dir" "primary" "app"

  # The failed runner artifact measured the provisional w1:p1 surviving the old
  # two-read check, then disappearing 50–200 ms later as w2:p1 arrived. The
  # third one-second sample rejects that measured transient without changing
  # any token TTL or failure timeout.
  #
  # Even that is not airtight: the settled pane can still die between the
  # settle and the `report-agent` below (seen on the CI runner 2026-09-07 as
  # `pane_not_found` for the just-settled `w1:p1`, failing the whole lane at
  # bring-up). So the settle+report pair retries, bounded, on exactly that
  # payload — any other failure still dies loudly.
  #
  # The report matters: the agents panel renders rows PER AGENT-BEARING PANE,
  # so a plain shell pane renders no row and no stamped token could appear.
  local agent_session_id="lvx-fixture-session-0001"
  local pane_id="" attempt=0
  while true; do
    pane_id="$(settle_focused_pane "$dir")"
    if herdr_cli pane report-agent "$pane_id" \
      --source "$FIXTURE_AGENT_SOURCE" --agent claude --state working \
      --agent-session-id "$agent_session_id" \
      >"$dir/report-agent.out" 2>"$dir/report-agent.err"; then
      break
    fi
    attempt=$((attempt + 1))
    if (( attempt >= 3 )) || ! grep -q 'pane_not_found' "$dir/report-agent.err" "$dir/report-agent.out" 2>/dev/null; then
      cat "$dir/report-agent.out" "$dir/report-agent.err" 2>/dev/null >&2 || true
      die "pane report-agent failed for $pane_id (attempt $attempt); see $dir/surface-primary.log and $dir/server.log"
    fi
    log "pane $pane_id died between settle and report-agent (attempt $attempt/3) — re-settling"
    sleep 1
  done
  log "pane $pane_id marked agent-bearing (session $agent_session_id)"
  record_pane_snapshot "$dir" "primary-ready" "$pane_id"

  printf '{"agentSessionID":"%s","alias":"%s","altUserAlias":"%s-altuser","otherPortAlias":"%s-otherport","herdrBinary":"%s","socketPath":"%s","paneID":"%s","primarySurfaceLog":"%s","provisionedSSH":%s,"workdir":"%s"}\n' \
    "$agent_session_id" "$alias_used" "$alias_used" "$alias_used" \
    "$HERDR_BINARY" "$HERDR_SOCKET_PATH" "$pane_id" \
    "$dir/surface-primary.log" \
    "$([[ $provisioned_ssh == 1 ]] && echo true || echo false)" \
    "$dir" \
    | tee "$dir/fixture.json"
  UP_IN_PROGRESS_DIR=""
}

# --------------------------------------------------------------- misc

load_context() {
  local dir="$1"
  validate_workdir "$dir"
  [[ -d "$dir" ]] || die "workdir not found: $dir"
  HERDR_BINARY="$(cat "$dir/herdr.bin" 2>/dev/null || true)"
  [[ -x "$HERDR_BINARY" ]] || die "fixture workdir has no usable herdr binary record: $dir"
  HERDR_SOCKET_PATH="$dir/herdr.sock"
  export HERDR_SOCKET_PATH
}

command_surface() {
  local dir="$1" name="$2" mode="$3" pane="${4:-}"
  load_context "$dir"
  record_pane_snapshot "$dir" "before-surface-$name" "$pane"
  start_surface "$dir" "$name" "$mode" "$pane"
  record_pane_snapshot "$dir" "after-surface-$name" "$pane"
}

command_reload() {
  local dir="$1"
  load_context "$dir"
  herdr_cli server reload-config
}

# ------------------------------------------------------- federation

# Set up the federated 0.9 client the federation tests need. Deliberately NOT
# part of `up`: on a host whose herdr predates `machine` this refuses loudly
# (which is what the new tests assert there), while the pre-federation lane
# keeps running.
#
# What it builds, in the fixture's existing style (loud failures, nothing of
# the account's touched beyond what `up` already holds):
# - the scratch CLIENT state dir is already `up`'s (XDG_STATE_HOME for every
#   surface, every client/CLI process below, and every `machine list` probe
#   including the version gate here); the account's
#   ~/.local/state/herdr/client/ is never read or written;
# - one `herdr machine add` of the fixture's own loopback target (hermetic) or
#   the caller's destination, targeting the DEFAULT remote session (no
#   --remote-session flag);
# - a REMOTE config home carrying onboarding=false and update checks off but
#   deliberately NO [ui.sidebar.agents] table, so the row-config test can pin
#   that rows render from the LOCAL client config only;
# - one agent-bearing pane on the remote server (headless workspace create +
#   report-agent — no second presenting client needed, measured 2026-09-13);
# - the selection file left on Local.
#
# Why the DEFAULT remote session rather than a named one: the profile's
# session only names the server; the socket it is reached at comes from the
# forced HERDR_SOCKET_PATH — but ONLY when no --session flag overrides it
# (measured 2026-09-13: explicit session wins over the env). A named session's
# socket (<config>/sessions/<name>/herdr.sock) exceeds macOS's 104-byte
# sun_path under the lane's workdir layout, while the explicit short socket
# has room to spare. The remote side is still a genuinely separate server
# with its own panes and its own config file, which is what the composition
# tests need.
# Commit federation teardown state to the hold manifest BEFORE `machine add`
# daemon-starts anything. The manifest lives at a stable path outside the
# workdir, so a SIGKILL between `machine add` and the final federation.json
# still leaves a recoverable record: the hermetic remote socket (plus sshd
# port and binary) for a socket-addressed `server stop`, or the destination
# target for a workspace-scoped close. The destination workspace id itself is
# recorded after `workspace create` (record_hold_field, same manifest).
record_federation_hold_state() {
  local dir="$1" hermetic="$2" target="${3:-}"
  record_hold_field federationWorkdir "$dir"
  record_hold_field federationHermetic "$hermetic"
  record_hold_field federationHerdrBinary "${HERDR_BINARY:-$(command -v herdr 2>/dev/null || true)}"
  if [[ "$hermetic" == "1" ]]; then
    record_hold_field federationRemoteSocket "$dir/$FEDERATION_REMOTE_SOCKET_NAME"
    if [[ -f "$dir/sshd.port" ]]; then
      record_hold_field federationSshdPort "$(cat "$dir/sshd.port")"
    fi
  else
    record_hold_field federationTarget "$target"
  fi
}

command_federation() {
  local dir="$1"
  load_context "$dir"
  scrub_herdr_env
  [[ ! -f "$dir/federation.json" ]] || die "federation is already set up in $dir (run 'down' first)"
  local client_state_home="$dir/client-state-home"

  local version version_json
  version="$("$HERDR_BINARY" --version 2>&1 | head -1)"
  log "herdr binary: $HERDR_BINARY ($version)"
  # The scratch client dir may not exist yet on a pre-0.9 host (up only
  # creates it when the sniff passes); a nonexistent XDG_STATE_HOME simply
  # reads as an empty catalog, and the probe never writes. Either way the
  # account's real catalog is never consulted.
  if ! version_json="$(XDG_STATE_HOME="$client_state_home" "$HERDR_BINARY" machine list --json </dev/null 2>/dev/null)" \
    || ! grep -q '^\[' <<<"$version_json"; then
    die "the federated-machine lane needs herdr 0.9.0 or newer (the \`herdr machine\` subcommand).
  This machine has: ${version:-<herdr --version failed>}.
  Upgrade herdr on this machine (e.g. brew upgrade herdr) and re-run the lane.
  Nothing was changed; the pre-federation lane is unaffected."
  fi
  [[ -d "$client_state_home" ]] \
    || die "no scratch client-state dir at $client_state_home; re-run 'up' with a 0.9-capable herdr first"
  log "herdr.version=$version"

  local alias_used hermetic=0 fed_target remote_home=""
  alias_used="$(sed -n 's/.*"alias":"\([^"]*\)".*/\1/p' "$dir/fixture.json" | head -1)"
  [[ -n "$alias_used" ]] || die "fixture.json has no alias; re-run 'up' first"
  if [[ -f "$dir/id-fed" ]]; then
    hermetic=1
    fed_target="${FIXTURE_ALIAS}${FEDERATION_ALIAS_SUFFIX}"
    remote_home="$dir/remote-config-home"
    mkdir -p "$remote_home/herdr"
    chmod 700 "$remote_home" "$remote_home/herdr"
    # Row-less on purpose: the lane pins that the agents-panel row renders
    # from the LOCAL client config (ClientShellConfig::from_config) even when
    # the remote side configures no rows at all.
    cat > "$remote_home/herdr/config.toml" <<'EOF'
onboarding = false

[update]
version_check = false
manifest_check = false
EOF
    log "remote config home: $remote_home (no [ui.sidebar.agents] by design)"
  else
    log "using caller-supplied ssh destination '$alias_used' as the federated machine (no remote config isolation)"
    fed_target="$alias_used"
  fi

  # The federated bridges spawn plain `ssh` (no -F), so the target must
  # resolve through the REAL ssh config — which is why the hermetic alias
  # lives there (see provision_loopback_sshd).
  ssh -G -- "$fed_target" >/dev/null 2>&1 \
    || die "ssh cannot resolve the federation target '$fed_target'; the lane needs a destination ssh can configure"

  # Non-interactive or nothing: stdin stays closed so a herdr approval prompt
  # (remote install/update) fails fast instead of parking the lane with no
  # output (measured 2026-09-13: an open stdin hung `machine add` past 120 s).
  # No --remote-session flag: the profile targets the default session and the
  # remote socket comes from the forced HERDR_SOCKET_PATH (see above).
  #
  # Committed to the hold manifest FIRST: `machine add` daemon-starts the
  # remote server, and a SIGKILL right after it would otherwise orphan that
  # daemon with no record of its socket.
  if (( hermetic )); then
    record_federation_hold_state "$dir" 1
  else
    record_federation_hold_state "$dir" 0 "$fed_target"
  fi
  local add_out profile_id
  add_out="$(XDG_STATE_HOME="$client_state_home" "$HERDR_BINARY" machine add "$fed_target" \
    --label "$FEDERATION_LABEL" </dev/null 2>&1)" \
    || die "herdr machine add $fed_target failed:
$add_out"
  profile_id="$(sed -n 's/^Saved SSH machine \([0-9a-f]*\)\..*/\1/p' <<<"$add_out" | head -1)"
  [[ -n "$profile_id" ]] || die "could not parse a profile id from machine add output:
$add_out"
  log "federated machine: id=$profile_id label=$FEDERATION_LABEL target=$fed_target session=default"

  # One agent-bearing pane on the remote server. Headless: `workspace create`
  # needs no presenting client, and an unfocused pane still gets an agents row
  # once it reports an agent (measured 2026-09-13). Hermetic commands address
  # the remote server directly (same box) with the remote socket stated
  # EXPLICITLY — the exported HERDR_SOCKET_PATH points at the LOCAL server and
  # there is no --session flag to override it. Destination mode reaches it
  # over ssh in BatchMode so a credential prompt fails loudly instead of
  # hanging.
  local create_out remote_pane_id remote_workspace_id=""
  local remote_socket="$dir/$FEDERATION_REMOTE_SOCKET_NAME"
  # Destination mode only: snapshot the second host's existing workspaces so
  # teardown closes ONLY the workspace this step creates. Best-effort — if
  # the list fails, the close below still runs best-effort against the id
  # `workspace create` returned.
  local pre_existing_workspaces=""
  if ! (( hermetic )); then
    pre_existing_workspaces="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T -- "$alias_used" \
      "herdr workspace list" </dev/null 2>&1 || true)"
  fi
  if (( hermetic )); then
    create_out="$(HERDR_SOCKET_PATH="$remote_socket" XDG_CONFIG_HOME="$remote_home" \
      "$HERDR_BINARY" workspace create </dev/null 2>&1)" \
      || die "remote workspace create failed:
$create_out"
  else
    create_out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T -- "$alias_used" \
      "herdr workspace create" </dev/null 2>&1)" \
      || die "remote workspace create over ssh to $alias_used failed:
$create_out"
  fi
  remote_pane_id="$(sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' <<<"$create_out" | head -1)"
  [[ -n "$remote_pane_id" ]] || die "could not parse a remote pane id from workspace create output:
$create_out"
  if ! (( hermetic )); then
    # Exactly what this step CREATED on the second host: teardown closes this
    # workspace and never stops that host's server. If the id pre-existed
    # (an empty server answers create with its own w1, measured 2026-09-13),
    # there is nothing of ours to close — record nothing.
    remote_workspace_id="$(sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p' <<<"$create_out" | head -1)"
    if [[ -n "$remote_workspace_id" ]] \
      && ! grep -qF "\"workspace_id\":\"$remote_workspace_id\"" <<<"$pre_existing_workspaces" 2>/dev/null; then
      record_hold_field federationRemoteWorkspace "$remote_workspace_id"
      log "remote workspace created: $remote_workspace_id (closed on teardown; the server is left running)"
    elif [[ -n "$remote_workspace_id" ]]; then
      log "remote workspace $remote_workspace_id pre-existed; teardown will not close it"
      remote_workspace_id=""
    else
      log "WARNING: could not parse a remote workspace id from workspace create output; teardown will close nothing"
    fi
  fi
  if (( hermetic )); then
    HERDR_SOCKET_PATH="$remote_socket" XDG_CONFIG_HOME="$remote_home" "$HERDR_BINARY" \
      pane report-agent "$remote_pane_id" \
      --source "$FIXTURE_AGENT_SOURCE" --agent claude --state working \
      --agent-session-id "$FEDERATION_AGENT_SESSION_ID" </dev/null >/dev/null 2>&1 \
      || die "remote pane report-agent failed for $remote_pane_id"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 -T -- "$alias_used" \
      "herdr pane report-agent $remote_pane_id --source $FIXTURE_AGENT_SOURCE --agent claude --state working --agent-session-id $FEDERATION_AGENT_SESSION_ID" \
      </dev/null >/dev/null 2>&1 \
      || die "remote pane report-agent over ssh to $alias_used failed for $remote_pane_id"
  fi
  log "remote pane: $remote_pane_id (agent session $FEDERATION_AGENT_SESSION_ID)"

  # Leave the selection on Local, in herdr's own EndpointSelection encoding
  # (pretty {version, selected_profile}; serde reads a missing field as the
  # same None, so compact and pretty decode identically — this mirrors
  # store_selection_to_path byte for byte).
  mkdir -p "$client_state_home/herdr/client"
  printf '{\n  "version": 1,\n  "selected_profile": null\n}\n' \
    > "$client_state_home/herdr/client/endpoint-selection.json"

  local remote_socket_path="" remote_config_path=""
  if (( hermetic )); then
    remote_socket_path="$dir/$FEDERATION_REMOTE_SOCKET_NAME"
    remote_config_path="$remote_home/herdr/config.toml"
    [[ -S "$remote_socket_path" ]] || die "remote server never created $remote_socket_path"
  fi
  printf '{"profileID":"%s","label":"%s","target":"%s","session":"%s","remoteAgentSessionID":"%s","clientStateHome":"%s","clientDir":"%s","remoteSocketPath":"%s","remotePaneID":"%s","remoteConfigPath":"%s","remoteWorkspaceID":"%s"}\n' \
    "$profile_id" "$FEDERATION_LABEL" "$fed_target" "default" \
    "$FEDERATION_AGENT_SESSION_ID" "$client_state_home" \
    "$client_state_home/herdr/client" "$remote_socket_path" "$remote_pane_id" \
    "$remote_config_path" "$remote_workspace_id" \
    | tee "$dir/federation.json"
}

# Put the scratch client on Local or on the federated machine by writing the
# selection file BEFORE a whole-view surface starts: a running client keeps
# its own selection (measured 2026-09-13: rewriting the file under a live
# client changes `machine list` but not what it views), while a starting
# client honors the file (load_from_paths). This is the file write a real UI
# switch produces (store_selection on every switch), called out as such: the
# lane does not drive the sidebar switch through the pty.
command_federation_select() {
  local dir="$1" which="$2"
  load_context "$dir"
  local client_state_home="$dir/client-state-home"
  [[ -d "$client_state_home" ]] || die "no scratch client-state dir at $client_state_home; run 'federation' first"
  local selected_json="null"
  [[ "$which" == "local" ]] || selected_json="\"$which\""
  mkdir -p "$client_state_home/herdr/client"
  printf '{\n  "version": 1,\n  "selected_profile": %s\n}\n' "$selected_json" \
    > "$client_state_home/herdr/client/endpoint-selection.json"
  log "federation selection: $which"
}

# Undo what `federation` created on the remote side. Hermetic mode stops the
# daemon-started remote server by its recorded socket; destination mode
# closes ONLY the created workspace and NEVER stops the second host's server
# (that server may hold a human's live session — see the header). Both paths
# prefer the workdir's records and fall back to the hold manifest, so they
# work whether or not federation.json was ever written. Never fails
# teardown: a dead server is the common case on the way out.
stop_federation_server() {
  local dir="$1"
  scrub_herdr_env
  # No federation was ever set up here: nothing to undo.
  if [[ ! -f "$dir/federation.json" && -z "$(hold_field federationHermetic)" ]]; then
    return 0
  fi
  local hold_workdir
  hold_workdir="$(hold_field federationWorkdir)"
  if [[ -f "$dir/id-fed" ]] \
    || { [[ "$(hold_field federationHermetic)" == "1" ]] \
      && { [[ "$hold_workdir" == "$dir" ]] || [[ "$(hold_field workdir)" == "$dir" ]]; }; }; then
    stop_hermetic_federation_server "$dir"
  else
    close_destination_federation_workspace "$dir"
  fi
}

# Hermetic teardown: the remote server is ours (daemon-started by
# `machine add`), addressed by its explicit short socket. The exported
# HERDR_SOCKET_PATH points at the LOCAL server and must not leak in, so the
# socket is named explicitly — from the hold manifest first (survives a
# SIGKILL that took the workdir), then the workdir layout.
stop_hermetic_federation_server() {
  local dir="$1" binary socket
  binary="$(cat "$dir/herdr.bin" 2>/dev/null || true)"
  [[ -x "$binary" ]] || binary="$(hold_field federationHerdrBinary)"
  [[ -x "$binary" ]] || binary="$(command -v herdr 2>/dev/null || true)"
  socket="$(hold_field federationRemoteSocket)"
  if [[ "$(hold_field federationWorkdir)" != "$dir" && "$(hold_field workdir)" != "$dir" ]]; then
    socket=""
  fi
  [[ -n "$socket" ]] || socket="$dir/$FEDERATION_REMOTE_SOCKET_NAME"
  if [[ ! -x "$binary" ]]; then
    log "no herdr binary on record for $dir; cannot stop its remote server"
    return 0
  fi
  if [[ -d "$dir" ]]; then
    HERDR_SOCKET_PATH="$socket" \
      XDG_CONFIG_HOME="$dir/remote-config-home" "$binary" \
      server stop </dev/null >/dev/null 2>&1 || true
  else
    # The workdir (and its remote-config-home) is gone; the socket address
    # alone is what `server stop` needs.
    HERDR_SOCKET_PATH="$socket" "$binary" \
      server stop </dev/null >/dev/null 2>&1 || true
  fi
  log "federated hermetic remote server stopped (socket $socket)"
}

# Destination teardown: close only the workspace `federation` created, over
# the same ssh, best-effort and logged. The remote server is left running by
# design. A `workspace create` + `report-agent` residue may remain if the
# close fails or no workspace id was recorded.
close_destination_federation_workspace() {
  local dir="$1" target workspace hold_workdir
  hold_workdir="$(hold_field federationWorkdir)"
  if [[ -f "$dir/federation.json" ]]; then
    target="$(sed -n 's/.*"target":"\([^"]*\)".*/\1/p' "$dir/federation.json" | head -1)"
    workspace="$(sed -n 's/.*"remoteWorkspaceID":"\([^"]*\)".*/\1/p' "$dir/federation.json" | head -1)"
  fi
  if [[ "$hold_workdir" == "$dir" || "$(hold_field workdir)" == "$dir" ]]; then
    [[ -n "$target" ]] || target="$(hold_field federationTarget)"
    [[ -n "$workspace" ]] || workspace="$(hold_field federationRemoteWorkspace)"
  fi
  if [[ -z "${workspace:-}" ]]; then
    log "destination federation recorded no created workspace for $dir; leaving ${target:-the second host}'s server alone by design"
    return 0
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -T -- "$target" \
    "herdr workspace close $workspace" </dev/null >/dev/null 2>&1; then
    log "federated destination workspace $workspace closed on $target (server left running)"
  else
    log "WARNING: could not close destination workspace $workspace on $target; the server was left running by design"
  fi
}

command_down() {
  local dir="$1"
  validate_workdir "$dir"
  if [[ -d "$dir" ]]; then
    stop_federation_server "$dir"
    stop_workdir_processes "$dir"
    rm -rf "$dir"
    log "torn down $dir"
  else
    log "nothing to tear down at $dir"
  fi
  release_account_files_if_held_by "$dir"
}

# The verb a human runs after a killed run. Needs no workdir: everything it
# needs is in the hold directory.
command_recover() {
  if ! hold_is_present; then
    log "nothing held — this account's files are already its own"
    return 0
  fi
  local owner
  owner="$(hold_field workdir)"
  if hold_owner_is_alive; then
    die "a herdr fixture run (pid $(hold_field pid)) is still alive and holding these
  files. Stop it first, then re-run recover."
  fi
  log "recovering held state from $owner (started $(hold_field startedAt))"
  if [[ -n "$owner" ]]; then
    # Manifest-aware like the reclaim path: the hermetic remote server stops
    # by its recorded socket even when the workdir is already gone.
    stop_federation_server "$owner"
    if [[ -d "$owner" ]]; then
      stop_workdir_processes "$owner"
      rm -rf "$owner"
    fi
  fi
  release_account_files
}

command_status() {
  if ! hold_is_present; then
    printf 'held=false\n'
    return 0
  fi
  printf 'held=true\n'
  printf 'workdir=%s\n' "$(hold_field workdir)"
  printf 'pid=%s\n' "$(hold_field pid)"
  printf 'startedAt=%s\n' "$(hold_field startedAt)"
  printf 'ownerAlive=%s\n' "$(hold_owner_is_alive && echo true || echo false)"
  printf 'backups=%s\n' "$HOLD_DIR"
}

# Shell regression tests source the reviewed implementation directly, exactly
# like scripts/mac/localvoxtral-build-gate.sh does. This variable cannot make
# a real invocation behave differently: it only suppresses dispatch.
if [[ "${LOCALVOXTRAL_HERDR_FIXTURE_SOURCE_ONLY:-0}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

trap restore_after_failed_up EXIT

VERB="${1:-}"
shift || true
case "$VERB" in
  up)
    [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 up <workdir> [ssh-destination]"
    command_up "$@"
    ;;
  surface)
    [[ $# -ge 3 && $# -le 4 ]] || die "usage: $0 surface <workdir> <name> <app|attach|observe> [pane-id]"
    command_surface "$@"
    ;;
  federation)
    [[ $# -eq 1 ]] || die "usage: $0 federation <workdir>"
    command_federation "$@"
    ;;
  federation-select)
    [[ $# -eq 2 ]] || die "usage: $0 federation-select <workdir> <profile-id|local>"
    command_federation_select "$@"
    ;;
  reload)
    [[ $# -eq 1 ]] || die "usage: $0 reload <workdir>"
    command_reload "$@"
    ;;
  down)
    [[ $# -eq 1 ]] || die "usage: $0 down <workdir>"
    command_down "$@"
    ;;
  recover)
    [[ $# -eq 0 ]] || die "usage: $0 recover"
    command_recover
    ;;
  status)
    [[ $# -eq 0 ]] || die "usage: $0 status"
    command_status
    ;;
  *)
    die "usage: $0 [up|surface|federation|federation-select|reload|down|recover|status] ..."
    ;;
esac
