#!/usr/bin/env bash
# Regression test (#1623): the remote Claude Code shim keeps its bearer token
# out of every child's environment. Claude Code exports it to the hook as
# CLAUDE_PLUGIN_OPTION_TOKEN; date, cat, awk, mktemp and curl have no use for
# it, and curl authenticates from a private header file.
#
# Each child runs through a stub that logs whether the variable is set, never
# its value, then execs the real tool. curl's stub also checks the header file
# still carries the token.
#
# No network:
#   ./scripts/ci/test-remote-shim-token-env.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SHIM="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-token-env-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

STUB="$TMP_DIR/stub"
mkdir -p "$STUB"
for tool in date cat awk mktemp find rm mkdir chmod mv; do
  real="$(command -v "$tool")"
  cat >"$STUB/$tool" <<STUB
#!/bin/sh
if [ -n "\${CLAUDE_PLUGIN_OPTION_TOKEN+set}" ]; then echo "$tool" >>"\$ENV_LOG"; fi
exec "$real" "\$@"
STUB
  chmod +x "$STUB/$tool"
done
cat >"$STUB/curl" <<'STUB'
#!/bin/sh
if [ -n "${CLAUDE_PLUGIN_OPTION_TOKEN+set}" ]; then echo curl >>"$ENV_LOG"; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
  --header | -H) case "$2" in @*) grep -q '^Authorization: Bearer unit-test-token$' "${2#@}" \
    && echo authorized >>"$AUTH_LOG" ;; esac; shift ;;
  esac
  shift
done
printf '200'
STUB
chmod +x "$STUB/curl"

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

payload='{"session_id":"s1","hook_event_name":"CwdChanged","old_cwd":"/srv","new_cwd":"/srv/app"}'
for SH in "${SHELLS[@]}"; do
  : >"$TMP_DIR/env.log"
  : >"$TMP_DIR/auth.log"
  printf '%s' "$payload" | env -i PATH="$STUB:$PATH" HOME="$TMP_DIR" \
    XDG_RUNTIME_DIR="$TMP_DIR/run" ENV_LOG="$TMP_DIR/env.log" AUTH_LOG="$TMP_DIR/auth.log" \
    CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token \
    "$SH" "$SHIM" CwdChanged >/dev/null
  [ -s "$TMP_DIR/auth.log" ] || fail "$SH: curl was not handed the token in its header file"
  [ ! -s "$TMP_DIR/env.log" ] \
    || fail "$SH: these children inherited CLAUDE_PLUGIN_OPTION_TOKEN: $(sort -u "$TMP_DIR/env.log" | tr '\n' ' ')"
  pass "$SH: the token reaches curl's header file and no child's environment"
done
