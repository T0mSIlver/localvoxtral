#!/bin/sh
# localvoxtral remote Mistral Vibe hook shim — strict POSIX sh. Needs curl, and
# the Python interpreter Vibe itself runs on.
#
# Vibe runs this once per hook (`~/.vibe/hooks.toml`) with the hook JSON on
# stdin. It hands that JSON to compact.py, which reduces it to at most two small
# request bodies in Claude Code's hook shape, and POSTs those to the tunnelled
# loopback listener on the Mac with this host's bearer token. It is the Vibe
# sibling of the Claude Code remote plugin's hooks/post.sh, and the rules it
# shares with that file are kept word for word: read that file's comments for
# the full reasoning behind the token handling, the header charset and the
# backoff.
#
# Everything here is fail-open and SILENT. Vibe reports a hook's non-zero exit
# or non-JSON stdout as a hook failure on the user's turn, so every path exits 0
# with no stdout and no stderr — a missing token, no Python, a dead tunnel, a
# sleeping Mac. Unlike the Claude Code shim this one never prints the listener's
# response: Vibe has no use for it.
#
# The token must never enter any process's argv (/proc/<pid>/cmdline is
# world-readable on Linux). It is read from a 0600 file into a shell variable
# and reaches curl through a private header file (`--header @file`, curl >=
# 7.55). compact.py never sees it.
set -u
# The token lives in a shell variable, and a shell EXPORTS a variable it
# imported from its environment, or any assignment under an inherited
# `allexport`. A Vibe started with TOKEN already exported would otherwise hand
# this host's bearer token to every child's environment, compact.py and curl
# included. Drop both before the name is ever assigned.
set +a
unset TOKEN PORT

fail_open() {
  cat >/dev/null 2>&1
  exit 0
}

umask 077

DIR="${LOCALVOXTRAL_VIBE_REMOTE_DIR:-${HOME:-}/.vibe/localvoxtral/remote}"
[ -r "$DIR/compact.py" ] || fail_open

# --- Private per-user state dir (the transport backoff stamp) ----------------
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/localvoxtral"
elif [ -n "${HOME:-}" ]; then
  STAMP_DIR="$HOME/.cache/localvoxtral"
else
  STAMP_DIR=""
fi
STAMP="$STAMP_DIR/vibe-hook-backoff"
NOW="$(date +%s 2>/dev/null)" || NOW=""
case "$NOW" in *[!0-9]* | ?????????????*) NOW="" ;; esac

WORK="$(mktemp -d 2>/dev/null)" || fail_open
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 0' HUP INT TERM

cat >"$WORK/payload" 2>/dev/null || exit 0

# --- Token and port ----------------------------------------------------------
# Both come from files the app wrote over ssh. The token is validated against
# the alphabet the app mints (base64url, no padding) before it is written into
# a header line: CR, LF and space are outside it, so a damaged file cannot
# forge a header. Enumerated, not a range, for the locale reason post.sh gives.
TOKEN=""
if [ -r "$DIR/token" ]; then
  IFS= read -r TOKEN <"$DIR/token" 2>/dev/null || :
fi
case "$TOKEN" in
"" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) exit 0 ;;
esac
[ "${#TOKEN}" -le 128 ] || exit 0

PORT=""
if [ -r "$DIR/port" ]; then
  IFS= read -r PORT <"$DIR/port" 2>/dev/null || :
fi
case "$PORT" in
"" | *[!0-9]* | 0* | ??????*) PORT=8473 ;;
*)
  if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then PORT=8473; fi
  ;;
esac

command -v curl >/dev/null 2>&1 || exit 0

# --- Transport backoff -------------------------------------------------------
# Same rule as the Claude Code shim: after a transport-level failure, skip the
# dial for BACKOFF_SECONDS, because every dial against a live forward with no
# app behind it makes the ssh CLIENT on the Mac print a line over the user's
# terminal. The turn-end hook always dials — it is user-paced, carries the
# prompt, and its completed exchange clears the backoff — the way
# UserPromptSubmit does there. The event name is read with awk only to make
# this decision; compact.py is what parses the payload.
BACKOFF_SECONDS=300
HOOK_EVENT="$(LC_ALL=C awk '
  match($0, /"hook_event_name"[[:space:]]*:[[:space:]]*"[a-z_]*"/) {
    value = substr($0, RSTART, RLENGTH)
    sub(/^"hook_event_name"[[:space:]]*:[[:space:]]*"/, "", value)
    sub(/"$/, "", value)
    print value
    exit
  }
' "$WORK/payload" 2>/dev/null)" || HOOK_EVENT=""
if [ -n "$STAMP_DIR" ] && [ -n "$NOW" ] && [ "$HOOK_EVENT" != "post_agent" ] \
  && [ -r "$STAMP" ]; then
  LAST="$(cat "$STAMP" 2>/dev/null)" || LAST=""
  case "$LAST" in
  "" | *[!0-9]* | ?????????????*) ;;
  *)
    if [ "$LAST" -le "$NOW" ] && [ $((NOW - LAST)) -lt "$BACKOFF_SECONDS" ]; then
      exit 0
    fi
    ;;
  esac
fi

# --- Python ------------------------------------------------------------------
# Vibe is a Python program, so an interpreter exists wherever this hook runs,
# and the right one is the one RUNNING Vibe: the executable of this hook's
# parent, or of that parent's parent when the parent is the `sh -c` Vibe
# spawned the command through. `command -v vibe` would be a guess — another
# install earlier on PATH is a different interpreter. Linux names the
# executable in /proc/<pid>/exe; macOS in `ps -o comm=`. The shebang of the
# `vibe` on PATH and then `python3` are the fallbacks for a host where neither
# answers. Whatever the source, only an absolute path to an executable whose
# NAME is exactly a Python (`python`, `python3`, `python3.N`) is run, and it is
# run isolated (`-I`: no PYTHON* variables, no user site, no cwd on the path).
is_python() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "${1##*/}" in
  python | python3 | python3.[0-9] | python3.[0-9][0-9]) [ -x "$1" ] ;;
  *) return 1 ;;
  esac
}
exe_of() {
  _exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || _exe=""
  [ -n "$_exe" ] || _exe="$(ps -o comm= -p "$1" 2>/dev/null)" || _exe=""
  echo "$_exe"
}
PY=""
GRANDPARENT="$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d '[:space:]')" || GRANDPARENT=""
case "$GRANDPARENT" in "" | *[!0-9]*) GRANDPARENT="" ;; esac
for _pid in "$PPID" $GRANDPARENT; do
  CANDIDATE="$(exe_of "$_pid")"
  if is_python "$CANDIDATE"; then
    PY="$CANDIDATE"
    break
  fi
done
if [ -z "$PY" ]; then
  VIBE_BIN="$(command -v vibe 2>/dev/null)" || VIBE_BIN=""
  if [ -n "$VIBE_BIN" ] && [ -r "$VIBE_BIN" ]; then
    IFS= read -r SHEBANG <"$VIBE_BIN" 2>/dev/null || SHEBANG=""
    CANDIDATE="${SHEBANG#\#!}"
    CANDIDATE="${CANDIDATE%% *}"
    is_python "$CANDIDATE" && PY="$CANDIDATE"
  fi
fi
if [ -z "$PY" ]; then
  CANDIDATE="$(command -v python3 2>/dev/null)" || CANDIDATE=""
  is_python "$CANDIDATE" && PY="$CANDIDATE"
fi
[ -n "$PY" ] || exit 0

# Time budget, inside Vibe's five-second hook timeout: compact.py spends at
# most 0.25 s on the session log and 0.5 s on each `ps` (one, or two for a
# Unified Harness payload on a host without /proc), and each of the two
# requests below is capped at one second.
#
# $PPID is Vibe, or the `sh -c` Vibe spawned this command through. compact.py
# tells the two apart and writes the answer to $WORK/agent-pid.
"$PY" -I "$DIR/compact.py" "$WORK" "$PPID" <"$WORK/payload" >/dev/null 2>&1 || exit 0
[ -r "$WORK/plan" ] || exit 0

# --- Request headers ---------------------------------------------------------
# Heredoc through a redirected `cat`, NOT printf/echo: an external printf would
# put the token into an argv. The hooks version is a constant of this file,
# sent so the Mac can tell when this host's hooks are older than the app's.
write_header() {
  cat 2>/dev/null >"$1" <<HEADERS
Authorization: Bearer $2
X-Lvx-Agent: vibe
X-Lvx-Vibe-Hooks-Version: 1.2.0
HEADERS
}
write_header "$WORK/header" "$TOKEN" || exit 0

# Allowlisted environment labels, under the same whitelist charset and length
# cap as the Claude Code shim (enumerated characters, LC_ALL=C, 200 bytes).
# The two Claude-allocated session handles are deliberately NOT sent: a Vibe
# started inside a Claude Code session inherits them, and the Mac would join
# this session to that Claude view.
lvx_env_header() {
  _lvx_name="$1"
  _lvx_value="${2:-}"
  [ -n "$_lvx_value" ] || return 0
  case "$_lvx_value" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/@+,=%-]*)
    return 0
    ;;
  esac
  [ "${#_lvx_value}" -le 200 ] || return 0
  cat 2>/dev/null >>"$WORK/header" <<HEADER || return 0
$_lvx_name: $_lvx_value
HEADER
}

AGENT_PID=""
if [ -r "$WORK/agent-pid" ]; then
  IFS= read -r AGENT_PID <"$WORK/agent-pid" 2>/dev/null || :
fi
case "$AGENT_PID" in "" | *[!0-9]* | ??????????*) AGENT_PID="" ;; esac

# --- Project label (#652) ----------------------------------------------------
# The Mac files what a remote session teaches it under a label. Without this
# header the label is the last component of the session's cwd, so each
# worktree of a repository, and each subdirectory a session starts in, learned
# alone. The label is the basename of the repository's main checkout: the
# parent of the shared git directory for a linked worktree, the toplevel
# otherwise (a submodule keeps its own). One git call, from this hook's cwd,
# which is the session's.
#
# A label like every value here, never a path: only the basename leaves, and
# only when it is a plain name in the charset the Mac's labels use (enumerated,
# as above), with no leading dot and at most 64 bytes. No git, no repository,
# a git too old for --path-format (it echoes the option back, which makes four
# lines) or anything else sends no header, and the Mac falls back to the cwd's
# last component.
# A function called through $( ), not a `case` written inside $( ): the
# bash 3.2 that is macOS's /bin/sh reads a case pattern's `)` as the end
# of the command substitution. Called in a subshell, so its locale, IFS,
# `set -f` and positional parameters stay there.
lvx_project() {
  LC_ALL=C
  export LC_ALL
  command -v git >/dev/null 2>&1 || return 0
  _lvx_git="$(git rev-parse --path-format=absolute --show-toplevel --git-dir \
    --git-common-dir 2>/dev/null)" || return 0
  set -f
  IFS='
'
  # shellcheck disable=SC2086  # one field per line is the point
  set -- $_lvx_git
  [ "$#" -eq 3 ] || return 0
  for _lvx_path in "$1" "$2" "$3"; do
    case "$_lvx_path" in /*) ;; *) return 0 ;; esac
  done
  if [ "$2" = "$3" ]; then
    _lvx_name="${1##*/}"
  elif [ "${3##*/}" = ".git" ]; then
    _lvx_main="${3%/*}"
    _lvx_name="${_lvx_main##*/}"
  else
    # A bare repository's worktree: the shared directory is the repository.
    _lvx_name="${3##*/}"
  fi
  case "$_lvx_name" in
  "" | .* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 0 ;;
  esac
  [ "${#_lvx_name}" -le 64 ] || return 0
  echo "$_lvx_name"
}
LVX_PROJECT="$(lvx_project 2>/dev/null)" || LVX_PROJECT=""

(
  LC_ALL=C
  export LC_ALL
  lvx_env_header 'X-Lvx-Env-Herdr-Pane-Id' "${HERDR_PANE_ID:-}"
  lvx_env_header 'X-Lvx-Env-Herdr-Socket-Path' "${HERDR_SOCKET_PATH:-}"
  lvx_env_header 'X-Lvx-Env-Herdr-Session' "${HERDR_SESSION:-}"
  lvx_env_header 'X-Lvx-Env-Cmux-Surface-Id' "${CMUX_SURFACE_ID:-}"
  lvx_env_header 'X-Lvx-Env-Cmux-Socket-Path' "${CMUX_SOCKET_PATH:-}"
  lvx_env_header 'X-Lvx-Env-Tmux' "${TMUX:-}"
  lvx_env_header 'X-Lvx-Env-Tmux-Pane' "${TMUX_PANE:-}"
  lvx_env_header 'X-Lvx-Env-Screen-Session' "${STY:-}"
  lvx_env_header 'X-Lvx-Env-Zellij-Session' "${ZELLIJ:-}"
  lvx_env_header 'X-Lvx-Env-Ssh-Tty' "${SSH_TTY:-}"
  lvx_env_header 'X-Lvx-Env-Local-Tty' "${LC_LVX_TTY:-}"
  set -f
  IFS=' '
  # shellcheck disable=SC2086  # word splitting is the point
  set -- ${SSH_CONNECTION:-}
  if [ "$#" -eq 4 ]; then
    lvx_env_header 'X-Lvx-Env-Ssh-Connection' "$1,$2,$3,$4"
  fi
  set +f
  lvx_env_header 'X-Lvx-Env-Hook-Parent-Pid' "$AGENT_PID"
  lvx_env_header 'X-Lvx-Env-Project' "${LVX_PROJECT:-}"
) 2>/dev/null || :

# --- Project terms (#641) ----------------------------------------------------
# `X-Lvx-Terms: wanted` on a 200 reply is the Mac asking for this session's
# project terms, once, after a dictation joined the session. The Mac cannot
# run the agent itself: the repository is here, and it never holds a path on
# this host. So this starts terms.sh, next to this file, DETACHED: its own
# session (setsid, or an ignored HUP where there is none), every descriptor on
# /dev/null, `env -i HOME PATH LANG USER LOGNAME` so no CLAUDE_* or plugin
# option reaches the agent (macOS finds a Claude Code login in the keychain
# only with the user's name set), and the token on stdin, never in an argv or the environment. The
# hook's own exit, output and timing do not change.
#
# One run per project per 24 hours whatever asks, a squatter on the port
# included: a per-project stamp directory, taken by an atomic mkdir, holds the
# attempt time, and terms.sh writes `done` there after the Mac accepts the
# answer. The project is the git toplevel of this hook's cwd, or the cwd
# outside git; its stamp is named by the cksum of that path.
lvx_terms_start() {
  _lvx_agent="$1"
  _lvx_session="$2"
  _lvx_runner="$3"
  _lvx_vibe="${4:-}"
  [ -n "$STAMP_DIR" ] && [ -n "$NOW" ] && [ -n "$_lvx_session" ] && [ -n "${HOME:-}" ] || return 0
  [ -r "$_lvx_runner" ] || return 0
  _lvx_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || _lvx_dir=""
  case "$_lvx_dir" in /*) ;; *) _lvx_dir="$(pwd -P 2>/dev/null)" || return 0 ;; esac
  case "$_lvx_dir" in /*) ;; *) return 0 ;; esac
  _lvx_sum="$(echo "$_lvx_dir" | cksum 2>/dev/null)" || return 0
  _lvx_crc="${_lvx_sum%% *}"
  _lvx_len="${_lvx_sum##* }"
  case "$_lvx_crc$_lvx_len" in "" | *[!0-9]*) return 0 ;; esac
  _lvx_terms="$STAMP_DIR/terms"
  { mkdir -p "$_lvx_terms" && chmod 700 "$STAMP_DIR" "$_lvx_terms"; } 2>/dev/null || return 0
  _lvx_stamp="$_lvx_terms/$_lvx_crc-$_lvx_len"
  if ! mkdir "$_lvx_stamp" 2>/dev/null; then
    [ ! -e "$_lvx_stamp/done" ] || return 0
    _lvx_last="$(cat "$_lvx_stamp/attempt" 2>/dev/null)" || _lvx_last=""
    case "$_lvx_last" in
    "" | *[!0-9]* | ?????????????*)
      # No attempt time yet: another hook holds a fresh claim and is about
      # to write it. Only a directory a day old is a claim that died.
      [ -z "$(find "$_lvx_stamp" -prune -mmin +1440 2>/dev/null)" ] && return 0
      _lvx_last=0
      ;;
    esac
    if [ "$_lvx_last" -gt "$NOW" ] || [ $((NOW - _lvx_last)) -lt 86400 ]; then
      return 0
    fi
    # A stale attempt: rename(2) lets exactly one hook take it over.
    mv "$_lvx_stamp" "$_lvx_stamp.$$" 2>/dev/null || return 0
    rm -rf "$_lvx_stamp.$$" 2>/dev/null
    mkdir "$_lvx_stamp" 2>/dev/null || return 0
  fi
  echo "$NOW" >"$_lvx_stamp/attempt" 2>/dev/null || return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid env -i HOME="$HOME" PATH="${PATH:-}" LANG="${LANG:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" sh "$_lvx_runner" \
      "$_lvx_agent" "$PORT" "$_lvx_session" "$_lvx_dir" "$_lvx_stamp" "$_lvx_vibe" \
      >/dev/null 2>&1 <<TERMS &
$TOKEN
TERMS
  else
    (
      trap '' HUP
      exec env -i HOME="$HOME" PATH="${PATH:-}" LANG="${LANG:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" sh "$_lvx_runner" \
        "$_lvx_agent" "$PORT" "$_lvx_session" "$_lvx_dir" "$_lvx_stamp" "$_lvx_vibe"
    ) >/dev/null 2>&1 <<TERMS &
$TOKEN
TERMS
  fi
  return 0
}

# --- Send --------------------------------------------------------------------
# One request per plan line, in order: the prompt before the event that ends or
# continues the turn. The event name is matched against the three this shim can
# send before it is spliced into a URL. The first transport failure arms the
# backoff and stops; any completed exchange clears it.
while IFS=' ' read -r INDEX NAME; do
  case "$INDEX" in 1 | 2) ;; *) break ;; esac
  case "$NAME" in UserPromptSubmit | PostToolUse | Stop) ;; *) break ;; esac
  [ -r "$WORK/event-$INDEX.json" ] || break
  STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --dump-header "$WORK/response-headers-$INDEX" \
    --max-time 1 --request POST \
    --header 'Content-Type: application/json' \
    --header @"$WORK/header" \
    --data-binary @"$WORK/event-$INDEX.json" \
    "http://127.0.0.1:$PORT/v1/hook/$NAME" 2>/dev/null)" || STATUS=""
  if [ -z "$STATUS" ] || [ "$STATUS" = "000" ]; then
    if [ -n "$STAMP_DIR" ] && [ -n "$NOW" ]; then
      {
        mkdir -p "$STAMP_DIR" && chmod 700 "$STAMP_DIR" \
          && echo "$NOW" >"$STAMP.$$" && mv -f "$STAMP.$$" "$STAMP"
      } 2>/dev/null || { rm -f "$STAMP.$$"; } 2>/dev/null || :
    fi
    break
  fi
  [ -z "$STAMP_DIR" ] || rm -f "$STAMP" 2>/dev/null || :
  if [ "$STATUS" = "200" ]; then
    DELIVERED=1
    # The Mac's ask for this project's terms: the header lines only, matched
    # exactly, and never printed (lvx_terms_start above).
    [ -z "$(LC_ALL=C sed -n \
        's/\r$//; /^[Xx]-[Ll][Vv][Xx]-[Tt][Ee][Rr][Mm][Ss]: wanted$/p' \
      "$WORK/response-headers-$INDEX" 2>/dev/null)" ] || TERMS_WANTED=1
  fi
done <"$WORK/plan"

SESSION_ID=""
if [ -r "$WORK/session-id" ]; then
  IFS= read -r SESSION_ID <"$WORK/session-id" 2>/dev/null || :
fi
case "$SESSION_ID" in
"" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*) SESSION_ID="" ;;
esac
[ "${#SESSION_ID}" -le 64 ] || SESSION_ID=""
if [ -n "${TERMS_WANTED:-}" ]; then
  lvx_terms_start vibe "$SESSION_ID" "$DIR/terms.sh" "${VIBE_HOME:-$HOME/.vibe}"
fi

# --- Exit watcher ------------------------------------------------------------
# Vibe has no session-end hook, and the Mac cannot probe a pid on this machine.
# Without help a finished Vibe session would stay joinable there until its
# four-hour TTL, on the very terminal the user starts the next one in. So the
# first hook of a session that reaches the Mac leaves ONE small background
# shell behind: it waits for the Vibe process to exit and then posts
# `SessionEnd`. `mkdir` of a per-session lock makes it one per session; a lock
# whose watcher is gone (reboot, kill) is replaced. It holds no file
# descriptor of this hook — Vibe waits for the hook's pipes to close — reads
# the token again when it sends, since it may have been replaced by then, and
# gives up after five tries a minute apart. The process START TIME is compared
# as well as the pid, which a long-lived host reuses.
# `LOCALVOXTRAL_VIBE_WATCHER=off` in Vibe's environment turns it off, for
# anyone who does not want a background process; sessions then end by TTL.
[ "${LOCALVOXTRAL_VIBE_WATCHER:-on}" != "off" ] || exit 0
[ -n "${DELIVERED:-}" ] && [ -n "$STAMP_DIR" ] && [ -n "$AGENT_PID" ] && [ -n "$SESSION_ID" ] || exit 0

WATCH_DIR="$STAMP_DIR/vibe-watch"
LOCK="$WATCH_DIR/$SESSION_ID"
{ mkdir -p "$WATCH_DIR" && chmod 700 "$STAMP_DIR" "$WATCH_DIR"; } 2>/dev/null || exit 0
# Locks whose watcher was killed (SIGKILL, a reboot under ~/.cache) are never
# replaced, because a session id does not come back. Sweep the old ones.
find "$WATCH_DIR"/* -prune -type d -mtime +2 -exec rm -rf {} + 2>/dev/null || :
if [ -d "$LOCK" ]; then
  WATCHER=""
  WATCHED=""
  IFS= read -r WATCHER <"$LOCK/pid" 2>/dev/null || :
  IFS= read -r WATCHED <"$LOCK/agent" 2>/dev/null || :
  case "$WATCHER" in "" | *[!0-9]*) WATCHER="" ;; esac
  if [ -n "$WATCHER" ] && kill -0 "$WATCHER" 2>/dev/null; then
    # Alive AND watching this Vibe process: nothing to do. Watching ANOTHER
    # one means the session id was reused by a new process (a resume): its
    # SessionEnd would evict the session that is live now, so it is stopped
    # and replaced. A recycled pid that is not a watcher at all ignores TERM
    # or dies of it; either way the lock below is ours again.
    [ "$WATCHED" != "$AGENT_PID" ] || exit 0
    kill "$WATCHER" 2>/dev/null || :
  fi
  rm -rf "$LOCK" 2>/dev/null || exit 0
fi
mkdir "$LOCK" 2>/dev/null || exit 0
echo "$AGENT_PID" >"$LOCK/agent" 2>/dev/null || :
# Empty means Vibe is ALREADY gone (Ctrl-C at the end of the turn, a closed
# pane): the Mac just learned of a session whose end nobody would announce.
# The watcher below then skips its wait and reports the end at once.
STARTED="$(ps -o lstart= -p "$AGENT_PID" 2>/dev/null)" || STARTED=""

send_session_end() {
  _work="$(mktemp -d 2>/dev/null)" || return 1
  unset TOKEN
  TOKEN=""
  IFS= read -r TOKEN <"$DIR/token" 2>/dev/null || :
  case "$TOKEN" in
  "" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
    rm -rf "$_work"
    return 0 # no usable token: the hooks were removed, nothing left to say
    ;;
  esac
  # The port too: a Vibe session can outlive a change of the Mac's forward.
  _port=""
  IFS= read -r _port <"$DIR/port" 2>/dev/null || :
  case "$_port" in
  "" | *[!0-9]* | 0* | ??????*) _port="$PORT" ;;
  *) if [ "$_port" -lt 1024 ] || [ "$_port" -gt 65535 ]; then _port="$PORT"; fi ;;
  esac
  write_header "$_work/header" "$TOKEN" || { rm -rf "$_work"; return 1; }
  cat >"$_work/body" 2>/dev/null <<BODY
{"hook_event_name":"SessionEnd","session_id":"$SESSION_ID"}
BODY
  _status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 2 --request POST \
    --header 'Content-Type: application/json' \
    --header @"$_work/header" \
    --data-binary @"$_work/body" \
    "http://127.0.0.1:$_port/v1/hook/SessionEnd" 2>/dev/null)" || _status=""
  rm -rf "$_work"
  [ -n "$_status" ] && [ "$_status" != "000" ]
}

# Seconds between liveness checks. The override exists for the test suite.
WATCH_INTERVAL="${LOCALVOXTRAL_VIBE_WATCH_INTERVAL:-2}"
case "$WATCH_INTERVAL" in "" | *[!0123456789.]* | ??????*) WATCH_INTERVAL=2 ;; esac

(
  trap '' HUP
  _checks=0
  while [ -n "$STARTED" ] && kill -0 "$AGENT_PID" 2>/dev/null; do
    sleep "$WATCH_INTERVAL"
    _checks=$((_checks + 1))
    if [ "$_checks" -ge 15 ]; then
      _checks=0
      [ "$(ps -o lstart= -p "$AGENT_PID" 2>/dev/null)" = "$STARTED" ] || break
    fi
  done
  _tries=0
  until send_session_end; do
    _tries=$((_tries + 1))
    [ "$_tries" -lt 5 ] || break
    sleep 60
  done
  rm -rf "$LOCK"
) </dev/null >/dev/null 2>&1 &
echo "$!" >"$LOCK/pid" 2>/dev/null || :
exit 0
