#!/usr/bin/env bash
# Regression test for the Notification body the remote Claude Code shim posts
# (#717): hooks/post.sh rebuilds it from the session id and the
# notification_type, so the `message` and `title` Claude Code hands the hook
# never leave the host. Runs the shim with a stub curl that keeps the body it
# was handed.
#
# No network:
#   ./scripts/ci/test-remote-shim-notification.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SHIM="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-notification-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

STUB="$TMP_DIR/stub"
mkdir -p "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
  --data-binary) case "$2" in @*) cp "${2#@}" "$CAPTURE" ;; esac; shift ;;
  esac
  shift
done
printf '200'
EOF
chmod +x "$STUB/curl"

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

# posted_body <event> <payload>: what reached curl, "<none>" when nothing did.
posted_body() {
  local capture="$TMP_DIR/capture"
  rm -f "$capture"
  printf '%s' "$2" | env -i PATH="$STUB:$PATH" HOME="$TMP_DIR" \
    XDG_RUNTIME_DIR="$TMP_DIR/run" CAPTURE="$capture" \
    CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token \
    "$SH" "$SHIM" "$1" >/dev/null
  if [ -r "$capture" ]; then cat "$capture"; else printf '<none>'; fi
}

# The payload shape Claude Code 2.1.283 hands a Notification hook.
payload() {
  printf '{"session_id":"%s","transcript_path":"/home/u/.claude/projects/p/s.jsonl","cwd":"/srv/app","hook_event_name":"Notification","message":"Claude needs your permission to use Bash: rm -rf build","title":"Claude Code","notification_type":"%s"}' "$1" "$2"
}

for SH in "${SHELLS[@]}"; do
  case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac

  for type in permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input; do
    got="$(posted_body Notification "$(payload 6f1c2d3e-aaaa-bbbb-cccc-0123456789ab "$type")")"
    want="{\"hook_event_name\":\"Notification\",\"session_id\":\"6f1c2d3e-aaaa-bbbb-cccc-0123456789ab\",\"notification_type\":\"$type\"}"
    [ "$got" = "$want" ] || fail "$SH_NAME $type: posted '$got', want '$want'"
    pass "$SH_NAME: a $type Notification posts only its session id and type"
  done

  # A type outside the closed set, a type trying to break out of the JSON
  # string, or a session id outside the checked charset posts nothing.
  for type in idle_prompt auth_success 'permission_prompt\",\"message\":\"x' ''; do
    got="$(posted_body Notification "$(payload 6f1c2d3e-aaaa-bbbb-cccc-0123456789ab "$type")")"
    [ "$got" = "<none>" ] || fail "$SH_NAME type '$type': posted '$got', want nothing"
    pass "$SH_NAME: a Notification of type '$type' posts nothing"
  done
  got="$(posted_body Notification "$(payload 'bad id' permission_prompt)")"
  [ "$got" = "<none>" ] || fail "$SH_NAME bad session id: posted '$got', want nothing"
  pass "$SH_NAME: a Notification without a usable session id posts nothing"

  # Every other event is still posted byte for byte.
  stop='{"session_id":"s1","hook_event_name":"Stop","cwd":"/srv/app"}'
  got="$(posted_body Stop "$stop")"
  [ "$got" = "$stop" ] || fail "$SH_NAME Stop: posted '$got', want the payload unchanged"
  pass "$SH_NAME: a Stop is posted unchanged"
done
