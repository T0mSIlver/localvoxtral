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
#
# `up` prints one JSON object on stdout describing the fixture; every other
# diagnostic goes to stderr. With no ssh-destination it provisions its OWN
# loopback sshd (hermetic: no second machine, nothing added to the account's
# real authorized_keys) and uses the alias `lvx-herdr-fixture`. Pass a
# destination to aim the same lane at a real second host instead; the ssh half
# is then the caller's own already-working configuration and is left untouched.
#
# Deliberately loud: every precondition that cannot be met exits non-zero with
# the exact provisioning step. This lane must never look green because
# something was missing.
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

log() { printf '[herdr-fixture] %s\n' "$*" >&2; }

# Set while `up` holds account-level files (herdr config/session, an
# ~/.ssh/config block). Cleared once `up` has fully succeeded.
UP_IN_PROGRESS_DIR=""

restore_after_failed_up() {
  local status=$?
  if (( status != 0 )) && [[ -n "$UP_IN_PROGRESS_DIR" ]]; then
    log "up failed (status $status) — restoring this account's files"
    command_down "$UP_IN_PROGRESS_DIR" >/dev/null 2>&1 || true
  fi
}
trap restore_after_failed_up EXIT

die() {
  printf '[herdr-fixture] ERROR: %s\n' "$*" >&2
  exit 1
}

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
  } >> "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
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
  local dir="$1" alias_used="$2" hostname port other_port
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
  } >> "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
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

herdr_cli() {
  HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" "$HERDR_BINARY" "$@"
}

command_up() {
  local dir="$1" destination="${2:-}"
  validate_workdir "$dir"
  [[ ! -e "$dir" ]] || die "workdir already exists: $dir (run 'down' first)"

  HERDR_BINARY="$(resolve_herdr)"
  log "herdr binary: $HERDR_BINARY ($("$HERDR_BINARY" --version 2>&1 | head -1))"

  # The fixture owns this account's `~/.config/herdr/config.toml`, its
  # `session.json`, and a block in `~/.ssh/config` for the duration of the
  # lane. If the account already has a herdr running, those files belong to a
  # human right now — refuse rather than trample them.
  if "$HERDR_BINARY" status server 2>/dev/null | grep -q '^status: running'; then
    die "a herdr server is already running for $(id -un).
  This lane takes over the account's herdr config and session state for the
  duration of the run, so it refuses to start beside a live one. Quit herdr
  (or run the lane as a different account) and try again."
  fi

  mkdir -p "$dir"
  chmod 700 "$dir"
  # From here on the fixture holds account-level files. Any failure must put
  # them back: a half-provisioned `up` that left the account's herdr config
  # replaced would be worse than no lane at all.
  UP_IN_PROGRESS_DIR="$dir"
  HERDR_SOCKET_PATH="$dir/herdr.sock"
  export HERDR_SOCKET_PATH
  # Recorded first, so `down` can still reach the binary if `up` dies partway.
  printf '%s\n' "$HERDR_BINARY" > "$dir/herdr.bin"

  # The forward under test builds its argv from the ALIAS alone, so the
  # fixture's connection details have to live where ssh finds them: the
  # account's ~/.ssh/config, in delimited blocks `down` removes again. This is
  # the same file the app's own enrollment writes its host blocks into.
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ -f "$HOME/.ssh/config" ]]; then
    cp "$HOME/.ssh/config" "$dir/ssh_config.bak"
    if grep -qF "$SSH_CONFIG_BEGIN" "$HOME/.ssh/config" \
      || grep -qF "$SSH_CONFIG_ALT_BEGIN" "$HOME/.ssh/config"; then
      die "an earlier fixture block is still in ~/.ssh/config; run 'down' first"
    fi
  else
    : > "$dir/ssh_config.absent"
  fi

  local alias_used="$destination" provisioned_ssh=0
  if [[ -z "$destination" ]]; then
    alias_used="$FIXTURE_ALIAS"
    provisioned_ssh=1
    provision_loopback_sshd "$dir"
  else
    log "using caller-supplied ssh destination '$destination' (no sshd provisioned)"
  fi
  write_canonicalization_aliases "$dir" "$alias_used"

  # The panel row the whole-view client must render for the binding probe.
  # Written as the account's REAL herdr config (backed up here, restored by
  # `down`), because that is the file `herdr server reload-config` reads.
  mkdir -p "$HOME/.config/herdr"
  if [[ -f "$HOME/.config/herdr/config.toml" ]]; then
    cp "$HOME/.config/herdr/config.toml" "$dir/herdr-config.bak"
  else
    : > "$dir/herdr-config.absent"
  fi
  # herdr persists its workspace/pane layout and restores it on the next
  # start. A leftover session makes pane ids (and how many panes exist)
  # depend on what ran before, which is exactly what a lane must not do.
  if [[ -f "$HOME/.config/herdr/session.json" ]]; then
    cp "$HOME/.config/herdr/session.json" "$dir/herdr-session.bak"
  else
    : > "$dir/herdr-session.absent"
  fi
  rm -f "$HOME/.config/herdr/session.json"
  # `onboarding = false` matters: herdr's first-run setup screen has no
  # workspace and therefore no pane, so `pane.current` answers pane_not_found
  # forever and the fixture would never become ready. The update checks are
  # off so the lane makes no network requests.
  cat > "$HOME/.config/herdr/config.toml" <<'EOF'
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
  if [[ ! -d "$dir" ]]; then
    log "nothing to tear down at $dir"
    return 0
  fi
  HERDR_BINARY="$(cat "$dir/herdr.bin" 2>/dev/null || true)"
  HERDR_SOCKET_PATH="$dir/herdr.sock"
  export HERDR_SOCKET_PATH

  local pid
  if [[ -f "$dir/surface.pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < "$dir/surface.pids"
  fi
  if [[ -x "$HERDR_BINARY" ]]; then
    HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" "$HERDR_BINARY" server stop >/dev/null 2>&1 || true
  fi
  for pid in "$dir/server.child.pid" "$dir/sshd.child.pid"; do
    kill "$(cat "$pid" 2>/dev/null || true)" 2>/dev/null || true
  done
  if [[ -f "$dir/sshd.pid" ]]; then
    kill "$(cat "$dir/sshd.pid" 2>/dev/null || true)" 2>/dev/null || true
  fi

  # Restore the account's files before anything else can fail.
  if [[ -f "$dir/ssh_config.bak" ]]; then
    cp "$dir/ssh_config.bak" "$HOME/.ssh/config"
  elif [[ -f "$dir/ssh_config.absent" ]]; then
    rm -f "$HOME/.ssh/config"
  fi
  if [[ -f "$dir/herdr-config.bak" ]]; then
    cp "$dir/herdr-config.bak" "$HOME/.config/herdr/config.toml"
  elif [[ -f "$dir/herdr-config.absent" ]]; then
    rm -f "$HOME/.config/herdr/config.toml"
  fi
  if [[ -f "$dir/herdr-session.bak" ]]; then
    cp "$dir/herdr-session.bak" "$HOME/.config/herdr/session.json"
  elif [[ -f "$dir/herdr-session.absent" ]]; then
    rm -f "$HOME/.config/herdr/session.json"
  fi

  rm -rf "$dir"
  log "torn down $dir"
}

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
  *)
    die "usage: $0 [up|surface|reload|down] ..."
    ;;
esac
