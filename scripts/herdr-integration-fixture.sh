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
#   scripts/herdr-integration-fixture.sh surface <workdir> <name> <app|attach> [pane-id]
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
# ## Files this borrows from the account, and how they come back
#
# For the duration of a run the fixture replaces the account's herdr
# `config.toml`, removes its `session.json`, and appends two delimited blocks
# to its `~/.ssh/config`. It has to touch the REAL ssh config because the code
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
# it. `recover` restores by hand.
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
      -v b2="$SSH_CONFIG_ALT_BEGIN" -v e2="$SSH_CONFIG_ALT_END" '
    $0 == b1 || $0 == b2 { skip = 1; next }
    $0 == e1 || $0 == e2 { skip = 0; next }
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
  if [[ -n "$owner" && -d "$owner" ]]; then
    stop_workdir_processes "$owner"
    rm -rf "$owner"
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
  HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" "$HERDR_BINARY" "$@"
}

# Kill whatever a run left behind in its own workdir. Touches no account files.
stop_workdir_processes() {
  local dir="$1" pid binary
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
  chmod 600 "$dir/hostkey" "$dir/id"

  # The fixture's OWN authorized_keys file — never the account's. The
  # environment= options are what make the remote half of the enrollment
  # config patch (`herdr server reload-config`) resolvable in a
  # non-interactive shell, which is where a real deployment gets it from the
  # user's login profile instead.
  {
    printf 'environment="PATH=%s:/usr/bin:/bin:/usr/sbin:/sbin",' \
      "$(dirname "$HERDR_BINARY")"
    printf 'environment="HERDR_SOCKET_PATH=%s" ' "$HERDR_SOCKET_PATH"
    cat "$dir/id.pub"
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
  local dir="$1" name="$2" mode="$3" pane="${4:-}" inner
  case "$mode" in
    app) inner="$HERDR_BINARY" ;;
    attach)
      [[ -n "$pane" ]] || die "surface mode 'attach' needs a pane id"
      inner="$HERDR_BINARY terminal attach $pane"
      ;;
    *) die "unknown surface mode: $mode" ;;
  esac
  # `script` gives the client a real pty; `stty` fixes the geometry so the
  # rendered layout is deterministic (herdr drops the sidebar entirely below
  # its mobile width threshold, which would make a no-match meaningless).
  # `-t 0` flushes the typescript on every I/O event. Without it `script`
  # buffers in 4 KiB blocks, so a freshly painted frame can sit unwritten and
  # the surface read would answer about the past.
  TERM=xterm-256color HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" \
    script -q -t 0 "$dir/surface-$name.log" \
    /bin/sh -c "stty rows $SURFACE_ROWS cols $SURFACE_COLUMNS; exec $inner" \
    </dev/null >/dev/null 2>&1 &
  echo $! >> "$dir/surface.pids"
  log "surface '$name' ($mode) started -> $dir/surface-$name.log"
}

command_up() {
  local dir="$1" destination="${2:-}"
  validate_workdir "$dir"
  [[ ! -e "$dir" ]] || die "workdir already exists: $dir (run 'down' first)"

  HERDR_BINARY="$(resolve_herdr)"
  log "herdr binary: $HERDR_BINARY ($("$HERDR_BINARY" --version 2>&1 | head -1))"

  # The fixture owns this account's herdr config, its session state and a
  # block in its ssh config for the duration of the lane. If the account
  # already has a herdr running, those files belong to a human right now —
  # refuse rather than trample them.
  if "$HERDR_BINARY" status server 2>/dev/null | grep -q '^status: running'; then
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

  # The whole-view client is what CREATES the first pane, so the pane the
  # lane binds to and the surface that renders it are the same real client.
  : > "$dir/surface.pids"
  start_surface "$dir" "primary" "app"

  # The pane the lane binds to must be the one the CLIENT owns, not herdr's
  # transient startup pane. A headless server spawns a pane of its own before
  # any client connects; the whole-view client then retires it and creates its
  # own in a new workspace. Reading `pane current` once can latch that dying
  # pane, and every later request answers `pane_not_found` for it (seen on the
  # CI runner, where the timing differed from the dev box). So: require the id
  # to be UNCHANGED across two reads a second apart AND to still resolve.
  local pane_id="" previous=""
  waited=0
  while true; do
    # `|| true`: before a pane exists, `pane current` answers with a
    # pane_not_found ERROR and a non-zero status, which `pipefail` would
    # otherwise turn into an abort on the very first poll.
    pane_id="$({ herdr_cli pane current 2>/dev/null || true; } \
      | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)"
    if [[ -n "$pane_id" && "$pane_id" == "$previous" ]] \
      && herdr_cli pane get "$pane_id" >/dev/null 2>&1; then
      break
    fi
    if (( waited >= READY_TIMEOUT_SECONDS )); then
      die "herdr never settled on a focused pane; see $dir/surface-primary.log and $dir/server.log"
    fi
    previous="$pane_id"
    sleep 1
    waited=$((waited + 1))
  done
  log "focused pane: $pane_id"

  # The agents panel renders rows PER AGENT-BEARING PANE, so a plain shell
  # pane renders no row at all and no custom token could ever appear. This is
  # the shape a real join targets: a pane whose agent an integration reported.
  local agent_session_id="lvx-fixture-session-0001"
  herdr_cli pane report-agent "$pane_id" \
    --source "$FIXTURE_AGENT_SOURCE" --agent claude --state working \
    --agent-session-id "$agent_session_id" >/dev/null
  log "pane $pane_id marked agent-bearing (session $agent_session_id)"

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
  start_surface "$dir" "$name" "$mode" "$pane"
}

command_reload() {
  local dir="$1"
  load_context "$dir"
  herdr_cli server reload-config
}

command_down() {
  local dir="$1"
  validate_workdir "$dir"
  if [[ -d "$dir" ]]; then
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
  if [[ -n "$owner" && -d "$owner" ]]; then
    stop_workdir_processes "$owner"
    rm -rf "$owner"
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
    [[ $# -ge 3 && $# -le 4 ]] || die "usage: $0 surface <workdir> <name> <app|attach> [pane-id]"
    command_surface "$@"
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
    die "usage: $0 [up|surface|reload|down|recover|status] ..."
    ;;
esac
