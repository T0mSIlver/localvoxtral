#!/usr/bin/env bash
# Runs #641 end to end on this Linux box as the remote host, with real agents
# (RemoteProjectTermsLiveTests): real Claude Code and Vibe sessions run the
# shipped remote hooks, which reach the test's listener through a real ssh
# RemoteForward, and the runner they start answers with a real `claude -p` or
# `vibe -p`. Linux only: it spends about $0.30 of Claude and Mistral tokens,
# and nothing here may run on the Mac.
#
#   SWIFT=/path/to/swift scripts/linux/remote-terms-live.sh [--filter <test>]
#
# The forward needs an sshd that accepts a key this script owns, so it starts
# a private one as this user on a loopback port, with its own host key and
# authorized key in a temporary directory. The user's ~/.ssh is not touched.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "remote-terms-live: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"
SWIFT="$SWIFT" LV_LINUX_SCRATCH="$SCRATCH" ./scripts/core-tests-linux.sh --filter NoSuchTestBuildOnly >/dev/null

resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
T="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-terms-live.XXXXXX")"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done
  cat "$resolved_backup" >Package.resolved
  rm -f "$resolved_backup"
  rm -rf "$T"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
SSHD_PORT="$(free_port)"
LISTENER_PORT="$(free_port)"
FORWARD_PORT="$(free_port)"

ssh-keygen -q -t ed25519 -N '' -f "$T/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$T/client_key"
cp "$T/client_key.pub" "$T/authorized_keys"
cat >"$T/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $SSHD_PORT
HostKey $T/host_key
AuthorizedKeysFile $T/authorized_keys
PidFile $T/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding remote
GatewayPorts no
EOF
/usr/sbin/sshd -D -e -f "$T/sshd_config" 2>"$T/sshd.log" &
pids+=("$!")

# The Mac's side of the tunnel: the host's FORWARD_PORT comes out at the
# listener's LISTENER_PORT, as the enrollment's RemoteForward does.
for _ in $(seq 50); do
  ssh -N -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/known_hosts" \
    -o ExitOnForwardFailure=yes -i "$T/client_key" -p "$SSHD_PORT" \
    -R "$FORWARD_PORT:127.0.0.1:$LISTENER_PORT" 127.0.0.1 2>"$T/ssh.log" &
  ssh_pid="$!"
  for _ in $(seq 20); do
    ss -tln | grep -q "127.0.0.1:$FORWARD_PORT " && break 2
    kill -0 "$ssh_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$ssh_pid" 2>/dev/null || :
  sleep 0.1
done
pids+=("$ssh_pid")
ss -tln | grep -q "127.0.0.1:$FORWARD_PORT " || {
  echo "remote-terms-live: the forward never came up" >&2
  cat "$T/sshd.log" "$T/ssh.log" >&2
  exit 1
}
echo "forward: host 127.0.0.1:$FORWARD_PORT -> ssh -> listener 127.0.0.1:$LISTENER_PORT (sshd pid ${pids[0]}, ssh pid $ssh_pid)"

env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" \
  LV_REMOTE_TERMS_LIVE=1 LVX_LISTENER_PORT="$LISTENER_PORT" LVX_FORWARD_PORT="$FORWARD_PORT" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter "${2:-RemoteProjectTermsLiveTests}"
