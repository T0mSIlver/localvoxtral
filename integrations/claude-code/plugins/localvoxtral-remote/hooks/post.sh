#!/bin/sh
# localvoxtral-remote Claude Code hook shim — strict POSIX sh, needs only curl.
#
# Claude Code runs this once per hook event with the event JSON on stdin. Its
# ONLY job is to POST that JSON, unchanged, to the tunnelled loopback listener
# on the Mac, authenticated with the enrolled host's bearer token, and to print
# the listener's 200 response body (an allowlisted ClaudeHookOutput JSON — the
# marker terminalSequence) on stdout for Claude Code to act on.
#
# Why a command hook and not a declarative `type: "http"` hook: Claude Code
# expands http-hook header `${VAR}` references from the actual process
# environment ONLY. Plugin userConfig options are injected as
# CLAUDE_PLUGIN_OPTION_<KEY> into COMMAND-hook subprocesses, never into http
# hooks — verified empirically on Claude Code 2.1.220, where every http hook
# authenticated as `Bearer ` (empty) and was correctly 401'd forever.
#
# Everything here is fail-open. Missing curl, an unset/empty token, a tunnel
# that is down, a Mac that is asleep, a timeout, a non-200 answer — all of it
# exits 0 with NO stdout and NO stderr, so Claude Code never blocks, warns, or
# fails a turn because dictation context is unavailable.
#
# The token must never enter any process's argv: /proc/<pid>/cmdline is
# world-readable on Linux, so `curl -H "Authorization: Bearer $TOKEN"` would
# publish the credential to every local user. The header therefore reaches
# curl through a private tempfile (`--header @file`, curl >= 7.55; an older
# curl treats the argument literally, sends no credential, gets a 401, and
# fails open). The event JSON body rides stdin (`--data-binary @-`).
set -u

EVENT="${1:-Unknown}"

# Fail open: consume stdin so Claude Code's writer never sees EPIPE, say
# nothing, succeed.
fail_open() {
  cat >/dev/null 2>&1
  exit 0
}

TOKEN="${CLAUDE_PLUGIN_OPTION_TOKEN:-}"
[ -n "$TOKEN" ] || fail_open
command -v curl >/dev/null 2>&1 || fail_open

# 0700 directory / 0600 files for the header tempfile; removed on every exit.
umask 077
WORK="$(mktemp -d 2>/dev/null)" || fail_open
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 0' HUP INT TERM

# Heredoc through a redirected `cat`, NOT printf/echo: POSIX does not require
# printf to be a shell builtin, and an external printf would put the token
# straight into the argv this file exists to keep it out of.
cat >"$WORK/header" 2>/dev/null <<EOF || fail_open
Authorization: Bearer $TOKEN
EOF

# --max-time 1 mirrors the old http hooks' one-second fail-open ceiling: a
# host whose forward silently failed must not stall every turn.
STATUS="$(curl --silent --output "$WORK/body" --write-out '%{http_code}' \
  --max-time 1 --request POST \
  --header 'Content-Type: application/json' \
  --header @"$WORK/header" \
  --data-binary @- \
  "http://127.0.0.1:8473/v1/hook/$EVENT" 2>/dev/null)" || STATUS=""

# stdout is control JSON to Claude Code — and a UserPromptSubmit hook's
# non-JSON stdout is appended to the user's prompt. Print the listener's body
# on 200 and absolutely nothing otherwise.
if [ "$STATUS" = "200" ]; then
  cat "$WORK/body" 2>/dev/null
fi
exit 0
