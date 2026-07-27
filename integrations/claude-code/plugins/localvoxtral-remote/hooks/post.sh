#!/bin/sh
# localvoxtral-remote Claude Code hook shim — strict POSIX sh, needs only curl.
#
# Claude Code runs this once per hook event with the event JSON on stdin. Its
# ONLY job is to POST that JSON, unchanged, to the tunnelled loopback listener
# on the Mac, authenticated with the enrolled host's bearer token, and to print
# the listener's 200 response body on stdout for Claude Code to act on — but
# only after gating it against the exact allowlisted ClaudeHookOutput grammar
# (see the stdout gate at the bottom); anything else prints nothing.
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
# Known, accepted leak: a SIGKILL (Claude Code escalating past the hook
# timeout) skips the traps and strands one 0700 dir — private to the user,
# bounded by how often hooks get killed.
umask 077
WORK="$(mktemp -d 2>/dev/null)" || fail_open
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 0' HUP INT TERM

# Heredoc through a redirected `cat`, NOT printf/echo: POSIX does not require
# printf to be a shell builtin, and an external printf would put the token
# straight into the argv this file exists to keep it out of.
cat 2>/dev/null >"$WORK/header" <<EOF || fail_open
Authorization: Bearer $TOKEN
EOF

# --max-time 1 mirrors the old http hooks' one-second fail-open ceiling: a
# host whose forward silently failed must not stall every turn. --max-filesize
# (recognized since curl 7.10.8) belts the body the stdout gate below already
# rejects; when it trips, curl fails and STATUS goes empty.
STATUS="$(curl --silent --output "$WORK/body" --write-out '%{http_code}' \
  --max-time 1 --max-filesize 1024 --request POST \
  --header 'Content-Type: application/json' \
  --header @"$WORK/header" \
  --data-binary @- \
  "http://127.0.0.1:8473/v1/hook/$EVENT" 2>/dev/null)" || STATUS=""

# stdout is control JSON to Claude Code, and it cuts BOTH ways: a
# UserPromptSubmit hook's non-JSON stdout is APPENDED TO THE USER'S PROMPT,
# and valid JSON with the wrong keys (hookSpecificOutput.additionalContext)
# would inject context. Whatever answered on 8473 — normally the tunnel to the
# app, but a squatter can bind that port first (see AGENTS.md) — its response
# must never be able to put a byte into the prompt. So printing fails CLOSED,
# the mirror image of delivery failing open: stdout is either one single small
# line matching EXACTLY the one body the listener can emit
# (ClaudeRemoteHTTPCodec.markerResponseBody — sorted keys, suppressOutput
# always true, optional OSC-2 terminalSequence whose marker obeys
# ClaudeMarkerSequence's lvx- allowlist) or absolutely nothing. A forged
# well-formed marker is inert: markers are broker-allocated, so an unknown one
# joins nothing.
# The `{ …; } 2>/dev/null` grouping matters: `wc <file 2>/dev/null` lets the
# SHELL's own "cannot open" reach stderr, because the input redirection fails
# before the stderr one is applied — and a body file that never got written IS
# the tunnel-down path, the one that must be silent (caught live 2026-07-27).
BODY_GRAMMAR='[{]"suppressOutput":true(,"terminalSequence":"\\u001[bB]]2;lvx-[0-9a-flvx-]{1,28}\\u0007")?[}]'
if [ "$STATUS" = "200" ] && [ -r "$WORK/body" ]; then
  SIZE="$({ wc -c <"$WORK/body"; } 2>/dev/null | tr -d '[:space:]')"; [ -n "$SIZE" ] || SIZE=9999
  LINES="$({ grep -c '' <"$WORK/body"; } 2>/dev/null)"; [ -n "$LINES" ] || LINES=0
  if [ "$SIZE" -le 256 ] && [ "$LINES" -eq 1 ] \
    && grep -Eqx "$BODY_GRAMMAR" "$WORK/body" 2>/dev/null; then
    cat "$WORK/body" 2>/dev/null
  fi
fi
exit 0
