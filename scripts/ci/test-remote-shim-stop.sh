#!/usr/bin/env bash
# Regression test for the Stop body the remote Claude Code shim posts (#818):
# hooks/post.sh rebuilds it from the session id and the cwd, so the reply
# Claude Code hands the hook as `last_assistant_message` never leaves the
# host. Runs the shim with a stub curl that keeps the body it was handed.
#
# No network:
#   ./scripts/ci/test-remote-shim-stop.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SHIM="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-stop-test.XXXXXX")"
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

ID=6f1c2d3e-aaaa-bbbb-cccc-0123456789ab
REPLY='Done. I ran \"rm -rf build\" and the tests pass.\nNext: ship it.'

# The payload shape Claude Code 2.1.283 hands a Stop hook, cwd given as its
# JSON string token.
payload() {
  printf '{"session_id":"%s","transcript_path":"/home/u/.claude/projects/p/s.jsonl","cwd":%s,"permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"%s"}' \
    "$1" "$2" "$REPLY"
}

for SH in "${SHELLS[@]}"; do
  case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac

  # The cwd crosses as the token it was, escapes and all, up to 4096 bytes.
  bs='\'
  at_cap="\"/$(printf '%04093d' 0 | tr 0 a)\""
  for cwd in '"/srv/app"' '"/srv/my app"' '"/srv/a\"b\\c"' "\"/srv/caf${bs}u00e9\"" '"/srv/café"' "$at_cap"; do
    got="$(posted_body Stop "$(payload "$ID" "$cwd")")"
    want="{\"hook_event_name\":\"Stop\",\"session_id\":\"$ID\",\"cwd\":$cwd}"
    [ "$got" = "$want" ] || fail "$SH_NAME cwd $cwd: posted '$got', want '$want'"
    case "$got" in *last_assistant_message* | *rm\ -rf*) fail "$SH_NAME: the reply crossed" ;; esac
    pass "$SH_NAME: a Stop in ${cwd:0:20} posts its session id and cwd, not the reply"
  done

  # A cwd that is not a well-formed JSON string is dropped, the Stop still
  # goes: an unknown escape, a raw tab, a non-string, a 4097-byte token.
  long="\"/$(printf '%04094d' 0 | tr 0 a)\""
  for cwd in '"/srv/\q"' "\"/srv/a$(printf '\t')b\"" 'null' "$long"; do
    got="$(posted_body Stop "$(payload "$ID" "$cwd")")"
    want="{\"hook_event_name\":\"Stop\",\"session_id\":\"$ID\"}"
    [ "$got" = "$want" ] || fail "$SH_NAME cwd ${cwd:0:40}: posted '$got', want '$want'"
    pass "$SH_NAME: a Stop whose cwd is ${cwd:0:20} posts without a cwd"
  done

  # A session id outside the checked charset still dials, with the event name
  # alone; the Mac drops a Stop it cannot attribute.
  got="$(posted_body Stop "$(payload 'bad id' '"/srv/app"')")"
  [ "$got" = '{"hook_event_name":"Stop"}' ] || fail "$SH_NAME bad session id: posted '$got'"
  pass "$SH_NAME: a Stop without a usable session id posts only its event name"

  # Other events are still posted byte for byte.
  prompt="{\"session_id\":\"$ID\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/srv/app\",\"prompt\":\"hi\"}"
  got="$(posted_body UserPromptSubmit "$prompt")"
  [ "$got" = "$prompt" ] || fail "$SH_NAME UserPromptSubmit: posted '$got', want the payload unchanged"
  pass "$SH_NAME: a UserPromptSubmit is posted unchanged"
done
