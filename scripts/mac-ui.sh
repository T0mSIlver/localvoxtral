#!/usr/bin/env bash
# mac-ui.sh — dev-box client for the SSH UI gate on the owner's Mac
# (scripts/mac/localvoxtral-ui-gate.sh). Verbs pass straight through:
#
#   ./scripts/mac-ui.sh state
#   ./scripts/mac-ui.sh ax find role=AXButton,title~General
#   ./scripts/mac-ui.sh ax click role=AXButton,title=General
#   ./scripts/mac-ui.sh shot settings | base64 -d > /tmp/settings.png
#   ./scripts/mac-ui.sh batch <<'EOF'
#   menu open
#   menu click Settings
#   ax find role=AXButton,title=General
#   EOF
#
# The gate is the trust boundary, not this script: every verb is validated on
# the Mac, and this file adds no verb of its own. What it adds is the transport
# the gate is fast enough for now — one multiplexed ssh connection kept alive
# between verbs (ControlMaster/ControlPersist), so a click-by-click session
# pays the handshake once. The connection is per gate host and key, in a
# socket under ~/.ssh, and dies on its own after LV_UI_SSH_PERSIST (600 s) of
# silence; `--disconnect` closes it now.
#
# Host and key, in order of precedence:
#   LV_UI_HOST                 env, for one call
#   git config localvoxtral.uihost   machine-local, set once per clone
#   tom@192.168.1.167          the default
#   LV_UI_KEY                  env; default ~/.ssh/localvoxtral-ui-gate
#
# The gate itself is installed BY HAND by the owner (scripts/mac/README.md,
# "`localvoxtral-ui-gate.sh` — SSH UI gate"). Nothing here installs, updates
# or even checks the installed copy; `state`'s setup.gate.revision is how you
# find out whether the Mac runs the revision in your tree.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/mac-ui.sh <gate verb> [args...]
       scripts/mac-ui.sh batch < verbs.txt      (one gate verb per line on stdin)
       scripts/mac-ui.sh --host                 (print the resolved host and key)
       scripts/mac-ui.sh --disconnect           (close the multiplexed connection)
USAGE
  exit 2
}

(( $# >= 1 )) || usage

HOST="${LV_UI_HOST:-$(git -C "$ROOT_DIR" config --get localvoxtral.uihost 2>/dev/null || true)}"
HOST="${HOST:-tom@192.168.1.167}"
KEY="${LV_UI_KEY:-$HOME/.ssh/localvoxtral-ui-gate}"
PERSIST="${LV_UI_SSH_PERSIST:-600}"

# One control socket per host+key, named by a hash so a long destination
# cannot overflow the sun_path limit (%C is ssh's own hash of the connection).
CONTROL_DIR="$HOME/.ssh"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o IdentitiesOnly=yes
  -i "$KEY"
  -o ControlMaster=auto
  -o ControlPath="$CONTROL_DIR/lv-ui-%C"
  -o ControlPersist="$PERSIST"
)

case "$1" in
  --host)
    printf 'host=%s\nkey=%s\n' "$HOST" "$KEY"
    exit 0
    ;;
  --disconnect)
    ssh "${SSH_OPTS[@]}" -O exit "$HOST" 2>/dev/null || true
    exit 0
    ;;
  -*)
    usage
    ;;
esac

[[ -r "$KEY" ]] || {
  printf 'mac-ui: no key at %s (LV_UI_KEY). The gate key is created by the owner: scripts/mac/README.md\n' "$KEY" >&2
  exit 2
}

# The gate reads ONE line: sshd hands it "$*" as SSH_ORIGINAL_COMMAND. Only
# `batch` reads stdin; every other verb gets `-n` so a terminal on this side
# is never held open waiting for input the gate will not read.
if [[ "$1" == "batch" ]]; then
  (( $# == 1 )) || usage
  exec ssh "${SSH_OPTS[@]}" "$HOST" batch
fi
exec ssh -n "${SSH_OPTS[@]}" "$HOST" "$*"
