#!/usr/bin/env bash
# runner-node-resign.sh — keep the self-hosted runner's bundled node binaries
# signed with the owner's stable code-signing identity so their TCC grants
# (Accessibility + Screen Recording, needed by the tier-2 GUI lanes) survive
# runner auto-updates.
#
# Why: macOS keys a TCC grant to the client binary's code signature. An
# UNSIGNED binary is keyed by content hash, so the runner's auto-update —
# which replaces every externals/node*/bin/node — silently kills the grants
# on each update (field incidents 2026-07-24/25: red tier-2 lanes plus real
# TCC prompts on the runner's GUI session). Signing node with a stable
# identity + identifier records the grant against the signature's designated
# requirement instead; re-signing a NEW node with the SAME identity and
# identifier keeps the existing grant valid with no Settings visit.
#
# Verbs:
#   run [--dry-run]  resign pass (default; what the LaunchAgent invokes)
#   install-agent    copy this script to a stable path and bootstrap the
#                    WatchPaths + hourly LaunchAgent (owner GUI session, once)
#   status           per-node signing state + agent state
#
# One-time, after the FIRST signed pass only: remove and re-add the four TCC
# rows (node20 + node24 x Accessibility + Screen Recording) — the old rows
# are keyed to the pre-signing content hashes and never match again. The
# first manual `run` may pop one keychain "Always Allow" prompt for the
# signing key — trigger that by hand in a GUI terminal; never let the agent
# be the first signer or it hangs on the prompt (same gotcha as CI signing,
# docs/agent/field-debugging.md).
#
# The agent double-fires benignly: our own codesign writes touch WatchPaths,
# so launchd runs one extra pass that finds everything signed and exits.
#
# Test seams (scripts/ci/test-runner-node-resign.sh): external commands
# (codesign, pgrep) resolve via PATH; locations and timings via LV_* env.
# No seam default changes production behavior.
set -euo pipefail

RUNNER_DIR="${LV_RUNNER_DIR:-$HOME/actions-runner}"
IDENTITY="${LV_RESIGN_IDENTITY:-localvoxtral-dev}"
IDENTIFIER="${LV_RESIGN_IDENTIFIER:-com.localvoxtral.runner-node}"
IDLE_TIMEOUT_SECS="${LV_RESIGN_IDLE_TIMEOUT_SECS:-1800}"
IDLE_POLL_SECS="${LV_RESIGN_IDLE_POLL_SECS:-20}"
# The LaunchAgent sets this to 60: WatchPaths fires mid-auto-update, and the
# scan must not race the runner still unpacking its new externals tree.
SETTLE_SECS="${LV_RESIGN_SETTLE_SECS:-0}"

LABEL="com.localvoxtral.runner-node-resign"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_BIN_DIR="$HOME/Library/Application Support/localvoxtral/bin"
INSTALLED_SCRIPT="$INSTALL_BIN_DIR/runner-node-resign.sh"
LOG_FILE="$HOME/Library/Logs/localvoxtral-runner-node-resign.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
die() {
  log "ERROR: $*" >&2
  exit 1
}

list_nodes() {
  local n
  for n in "$RUNNER_DIR"/externals/node*/bin/node; do
    [[ -f "$n" ]] && printf '%s\n' "$n"
  done
  return 0
}

# True when the binary already carries our identity AND identifier. Display
# flags only — never let a probe re-sign anything (PR #82 forensics).
node_is_ours() {
  local node="$1" info
  info="$(codesign -dvv "$node" 2>&1 || true)"
  [[ "$info" == *"Identifier=$IDENTIFIER"* && "$info" == *"Authority=$IDENTITY"* ]]
}

worker_active() {
  pgrep -f "$RUNNER_DIR/bin/Runner.Worker" >/dev/null 2>&1
}

# Never stop the service under a live job: a Runner.Worker process means a
# CI run is in flight. Timeout leaves everything untouched — the hourly
# StartInterval pass retries.
wait_for_idle() {
  local waited=0 step="$IDLE_POLL_SECS"
  [[ "$step" -ge 1 ]] || step=1
  while worker_active; do
    if [[ "$waited" -ge "$IDLE_TIMEOUT_SECS" ]]; then
      return 1
    fi
    log "a runner job is in flight — waiting (${waited}s/${IDLE_TIMEOUT_SECS}s)"
    sleep "$IDLE_POLL_SECS"
    waited=$((waited + step))
  done
  return 0
}

cmd_run() {
  local dry_run="${1:-}"
  [[ -d "$RUNNER_DIR/externals" ]] \
    || die "runner externals dir not found: $RUNNER_DIR/externals (set LV_RUNNER_DIR)"
  if [[ "$SETTLE_SECS" -gt 0 ]]; then
    sleep "$SETTLE_SECS"
  fi

  local nodes total=0 n unsigned
  unsigned=()
  nodes="$(list_nodes)"
  [[ -n "$nodes" ]] || die "no externals/node*/bin/node binaries under $RUNNER_DIR"
  while IFS= read -r n; do
    total=$((total + 1))
    node_is_ours "$n" || unsigned+=("$n")
  done <<<"$nodes"

  if [[ ${#unsigned[@]} -eq 0 ]]; then
    log "all $total node binaries already carry $IDENTITY/$IDENTIFIER — nothing to do"
    return 0
  fi

  if [[ "$dry_run" == "--dry-run" ]]; then
    for n in ${unsigned[@]+"${unsigned[@]}"}; do
      log "dry-run: would sign $n"
    done
    log "dry-run: would stop the runner service, sign ${#unsigned[@]} of $total binaries, restart it"
    return 0
  fi

  wait_for_idle \
    || die "runner worker still busy after ${IDLE_TIMEOUT_SECS}s — leaving the service untouched (hourly pass retries)"

  log "signing ${#unsigned[@]} of $total node binaries with identity '$IDENTITY' (identifier $IDENTIFIER)"
  local svc_stopped=0 failures=0
  if [[ -x "$RUNNER_DIR/svc.sh" ]]; then
    log "stopping runner service"
    (cd "$RUNNER_DIR" && ./svc.sh stop) || log "WARN: svc.sh stop reported nonzero (continuing)"
    svc_stopped=1
  else
    # Signing a binary the running service has mapped can get its process
    # killed by the kernel's signature revalidation — warn loudly.
    log "WARN: $RUNNER_DIR/svc.sh not found/executable — signing WITHOUT a service stop"
  fi

  for n in ${unsigned[@]+"${unsigned[@]}"}; do
    if codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$n"; then
      log "signed: $n"
    else
      log "ERROR: codesign failed for $n"
      failures=$((failures + 1))
    fi
  done

  # Restart even after sign failures: a broken grant is recoverable, a
  # stopped runner service silently kills all CI.
  if [[ "$svc_stopped" -eq 1 ]]; then
    log "starting runner service"
    (cd "$RUNNER_DIR" && ./svc.sh start) \
      || die "svc.sh start failed — the runner service may be DOWN, intervene now"
  fi

  [[ "$failures" -eq 0 ]] \
    || die "$failures binaries failed to sign — their TCC grants stay broken until a clean pass"
  log "done — TCC grants keyed to $IDENTITY/$IDENTIFIER remain valid across this update"
}

cmd_status() {
  local n found=0
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    found=1
    if node_is_ours "$n"; then
      printf 'signed   %s\n' "$n"
    else
      printf 'UNSIGNED %s\n' "$n"
    fi
  done <<<"$(list_nodes)"
  [[ "$found" -eq 1 ]] || printf 'no node binaries under %s/externals\n' "$RUNNER_DIR"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    printf 'agent    %s loaded\n' "$LABEL"
  else
    printf 'agent    %s NOT loaded (run install-agent)\n' "$LABEL"
  fi
}

cmd_install_agent() {
  [[ -d "$RUNNER_DIR/externals" ]] \
    || die "runner externals dir not found: $RUNNER_DIR/externals (set LV_RUNNER_DIR)"
  command -v codesign >/dev/null 2>&1 || die "codesign not found"

  mkdir -p "$INSTALL_BIN_DIR" "$(dirname "$AGENT_PLIST")" "$(dirname "$LOG_FILE")"
  install -m 0755 "${BASH_SOURCE[0]}" "$INSTALLED_SCRIPT"

  cat >"$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$INSTALLED_SCRIPT</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LV_RESIGN_SETTLE_SECS</key><string>60</string>
  </dict>
  <key>WatchPaths</key>
  <array><string>$RUNNER_DIR/externals</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"

  log "agent installed: $AGENT_PLIST (script: $INSTALLED_SCRIPT, log: $LOG_FILE)"
  cat <<'NEXT'
Next steps (once):
  1. Run the first pass BY HAND in this GUI terminal so the keychain
     "Always Allow" prompt for the signing key lands on you, not the agent:
       "$HOME/Library/Application Support/localvoxtral/bin/runner-node-resign.sh" run
  2. System Settings > Privacy & Security: in BOTH Accessibility and
     Screen Recording, REMOVE the existing node rows and re-add BOTH
     ~/actions-runner/externals/node*/bin/node binaries (4 entries total).
     The old rows are keyed to the pre-signing hashes and never match again.
  3. Verify: dispatch ui-smoke.yml — its TCC preflight is the live probe.
NEXT
}

case "${1:-run}" in
  run)
    shift || true
    cmd_run "${1:-}"
    ;;
  install-agent)
    cmd_install_agent
    ;;
  status)
    cmd_status
    ;;
  *)
    echo "Usage: $0 [run [--dry-run]|install-agent|status]" >&2
    exit 1
    ;;
esac
