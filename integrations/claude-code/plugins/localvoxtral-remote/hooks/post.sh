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
# fails a turn because dictation context is unavailable. After a
# transport-level failure the shim additionally BACKS OFF (see below): the ssh
# client on the Mac prints a `connect_to …: failed.` line onto the user's
# terminal for every dial against a live forward with no app behind it, and
# that stderr is another process on another machine — un-redirectable from
# here. Not dialing is the only silence we can buy.
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

# --- Listen port -------------------------------------------------------------
# Which loopback port on THIS host the Mac's `RemoteForward` binds. It is a
# per-Mac allocation (see ClaudeRemoteForwardPort): two Macs enrolled against
# this host would otherwise both request 8473, where the FIRST connection wins
# the bind forever and the second silently delivers this host's events — and
# this host's Authorization header — to the wrong Mac (issue #215).
#
# Validated, never trusted: the value arrives from plugin config, and an
# unvalidated one would be spliced into a URL. Digits only, no leading zero
# (which `[` may read as octal, or refuse), at most 5 of them (so the range
# test below can never see an oversized constant — the same hazard the backoff
# stamp guards against), and inside the unprivileged range. Anything else falls
# back to 8473, which is exactly what an install predating this option gets:
# an old plugin config and an old ssh-config block keep working unchanged.
PORT="${CLAUDE_PLUGIN_OPTION_PORT:-}"
case "$PORT" in
"" | *[!0-9]* | 0* | ??????*) PORT=8473 ;;
*)
  if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then PORT=8473; fi
  ;;
esac

# --- Transport backoff -------------------------------------------------------
# The one noise no redirect in this file can reach: while an SSH session holds
# the RemoteForward but localvoxtral is not running on the Mac, every dial
# makes the ssh CLIENT — on the other machine — print
# `connect_to 127.0.0.1 port <the Mac's listener port>: failed.` straight onto
# the terminal, over whatever TUI is drawn there (a herdr pane, the Claude
# Code screen), once per hook, dozens of times a turn via PostToolUse. The
# only lever on this side is to stop dialing a tunnel that just proved dead:
# after a transport-level failure, every event EXCEPT UserPromptSubmit skips
# the dial for BACKOFF_SECONDS.
#
# UserPromptSubmit always dials, deliberately: it is user-paced (one ssh line
# per submitted prompt while the app is down — an honest, bounded signal, not
# a storm), it is the event that joins the session and carries the prompt, so
# the first prompt after the app comes back is grounded immediately — and its
# completed exchange clears the backoff for every other event.
#
# State is one epoch-seconds stamp in a private per-user dir. Anything odd —
# no usable dir, no epoch from date, garbage content, a clock that jumped
# backwards — disables the backoff and the shim simply dials: exactly the
# pre-backoff behavior, fail-open as ever.
BACKOFF_SECONDS=300
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/localvoxtral"
elif [ -n "${HOME:-}" ]; then
  STAMP_DIR="$HOME/.cache/localvoxtral"
else
  STAMP_DIR=""
fi
STAMP="$STAMP_DIR/hook-backoff"
NOW="$(date +%s 2>/dev/null)" || NOW=""
# Digits only, at most 12 of them (epoch seconds are 10 until year 2286): a
# damaged value must never reach `[` or $(( )), where an oversized constant
# aborts some shells — with output on stderr.
case "$NOW" in *[!0-9]* | ?????????????*) NOW="" ;; esac
if [ -n "$STAMP_DIR" ] && [ -n "$NOW" ] && [ "$EVENT" != "UserPromptSubmit" ] \
  && [ -r "$STAMP" ]; then
  LAST="$(cat "$STAMP" 2>/dev/null)" || LAST=""
  case "$LAST" in
  "" | *[!0-9]* | ?????????????*) ;;
  *)
    if [ "$LAST" -le "$NOW" ] && [ $((NOW - LAST)) -lt "$BACKOFF_SECONDS" ]; then
      fail_open
    fi
    ;;
  esac
fi

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

# --- Allowlisted environment enrichment --------------------------------------
# A handful of values naming WHERE this session runs — a herdr pane, a cmux
# surface, a tmux pane, the SSH tty, the browser-side bridge session — so the
# Mac can later tell whether the surface the user is dictating into is the one
# this session lives in. Never content, never argv, never the whole environment.
#
# They ride as HEADERS because the body must stay Claude Code's event JSON
# BYTE-FOR-BYTE: the remote host is not assumed to have jq (or any JSON tool),
# so there is no way to merge a field into the body here. They go into the same
# 0600 header file as the token, which also keeps them out of every argv and
# leaves the curl invocation below untouched.
#
# Validation is a WHITELIST, applied before a byte is written: ASCII
# alphanumerics plus `._:/@+,=%-` only (`%` is in because a tmux pane id IS
# `%3`, and dropping it would silently disable the tmux arm). CR, LF, NUL,
# every other control byte,
# space and tab are all outside it, so a value that passes cannot terminate this
# header line or forge a new one — header injection is impossible by
# construction rather than by escaping. Anything failing validation, or longer
# than 200 characters, is silently DROPPED: this is enrichment, and losing a
# hint is nothing next to delivering the hook itself. The app re-applies the
# identical charset and caps on arrival and trusts none of this.
#
# The charset is ENUMERATED, not written as `[A-Za-z0-9…]` ranges. A bracket
# RANGE follows the active collation (POSIX leaves range expressions
# locale-dependent, and bash documents exactly this), so under a UTF-8 locale
# `[a-z]` can match `é` — which would have let a multibyte value through and,
# because `${#var}` counts CHARACTERS rather than bytes, let 200 such
# characters become a ~400-byte header line. An enumerated set has no collation
# to follow and matches the same bytes in every locale. The `LC_ALL=C` around
# the calls is the belt to that braces: with it, `${#var}` is a byte count too,
# so the cap means what it says even on a shell that resolves the enumeration
# oddly. It is scoped to a subshell — one fork, and the stdout gate below keeps
# the locale it was tested under.
lvx_env_header() {
  _lvx_name="$1"
  _lvx_value="${2:-}"
  [ -n "$_lvx_value" ] || return 0
  case "$_lvx_value" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/@+,=%-]*)
    return 0
    ;;
  esac
  # Charset-checked first, so every remaining character is one ASCII byte and
  # this length is also the byte length.
  [ "${#_lvx_value}" -le 200 ] || return 0
  cat 2>/dev/null >>"$WORK/header" <<EOF || return 0
$_lvx_name: $_lvx_value
EOF
}

(
  LC_ALL=C
  export LC_ALL
  lvx_env_header 'X-Lvx-Env-Herdr-Pane-Id' "${HERDR_PANE_ID:-}"
  lvx_env_header 'X-Lvx-Env-Herdr-Socket-Path' "${HERDR_SOCKET_PATH:-}"
  lvx_env_header 'X-Lvx-Env-Herdr-Session' "${HERDR_SESSION:-}"
  lvx_env_header 'X-Lvx-Env-Cmux-Surface-Id' "${CMUX_SURFACE_ID:-}"
  lvx_env_header 'X-Lvx-Env-Cmux-Socket-Path' "${CMUX_SOCKET_PATH:-}"
  lvx_env_header 'X-Lvx-Env-Bridge-Session-Id' "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}"
  lvx_env_header 'X-Lvx-Env-Tmux' "${TMUX:-}"
  lvx_env_header 'X-Lvx-Env-Tmux-Pane' "${TMUX_PANE:-}"
  lvx_env_header 'X-Lvx-Env-Ssh-Tty' "${SSH_TTY:-}"
  # Best effort: the shim's parent is the Claude Code process on THIS host. It
  # is a pid in this machine's namespace and the Mac treats it as a label only.
  lvx_env_header 'X-Lvx-Env-Hook-Parent-Pid' "${PPID:-}"
) 2>/dev/null || :

# --max-time 1 mirrors the old http hooks' one-second fail-open ceiling: a
# host whose forward silently failed must not stall every turn. --max-filesize
# (recognized since curl 7.10.8) belts the body the stdout gate below already
# rejects; when it trips, curl fails and STATUS goes empty.
STATUS="$(curl --silent --output "$WORK/body" --write-out '%{http_code}' \
  --max-time 1 --max-filesize 1024 --request POST \
  --header 'Content-Type: application/json' \
  --header @"$WORK/header" \
  --data-binary @- \
  "http://127.0.0.1:$PORT/v1/hook/$EVENT" 2>/dev/null)" || STATUS=""

# Arm the backoff on a transport-level failure (curl died: refused, reset,
# timed out); clear it the moment ANY HTTP exchange completes — even a 401
# proves the tunnel terminates at a listener instead of making ssh complain.
# Both sides are best-effort and silent: failing to record state just means
# the next event dials again. The stamp lands via a private tempfile + mv —
# rename(2) replaces a pre-planted symlink at the stamp path instead of
# writing through it, and a concurrent reader never sees a half-written
# value. chmod tightens a stamp dir that pre-existed with looser modes;
# if any step fails the arm is skipped, which just means dialing again.
if [ -n "$STAMP_DIR" ] && [ -n "$NOW" ]; then
  if [ -z "$STATUS" ] || [ "$STATUS" = "000" ]; then
    {
      mkdir -p "$STAMP_DIR" && chmod 700 "$STAMP_DIR" \
        && echo "$NOW" >"$STAMP.$$" && mv -f "$STAMP.$$" "$STAMP"
    } 2>/dev/null || { rm -f "$STAMP.$$"; } 2>/dev/null || :
  else
    rm -f "$STAMP" 2>/dev/null || :
  fi
fi

# stdout is control JSON to Claude Code, and it cuts BOTH ways: a
# UserPromptSubmit hook's non-JSON stdout is APPENDED TO THE USER'S PROMPT,
# and valid JSON with the wrong keys (hookSpecificOutput.additionalContext)
# would inject context. Whatever answered on $PORT — normally the tunnel to the
# app, but a squatter can bind that port first (see docs/agent/invariants.md) — its response
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
