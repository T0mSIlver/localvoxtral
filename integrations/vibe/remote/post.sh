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
# Vibe is a Python program, so an interpreter exists wherever this hook runs.
# The one Vibe uses is named by the shebang of its launcher script (uv and pipx
# both write an absolute path there); `python3` on PATH is the fallback. The
# shebang is read with the shell's own `read`, and only an absolute path to an
# executable is accepted.
PY=""
VIBE_BIN="$(command -v vibe 2>/dev/null)" || VIBE_BIN=""
if [ -n "$VIBE_BIN" ] && [ -r "$VIBE_BIN" ]; then
  IFS= read -r SHEBANG <"$VIBE_BIN" 2>/dev/null || SHEBANG=""
  case "$SHEBANG" in
  '#!/'*)
    CANDIDATE="${SHEBANG#\#!}"
    CANDIDATE="${CANDIDATE%% *}"
    case "$CANDIDATE" in
    */python*) [ -x "$CANDIDATE" ] && PY="$CANDIDATE" ;;
    esac
    ;;
  esac
fi
[ -n "$PY" ] || PY="$(command -v python3 2>/dev/null)" || PY=""
[ -n "$PY" ] || exit 0

# $PPID is Vibe, or the `sh -c` Vibe spawned this command through. compact.py
# tells the two apart and writes the answer to $WORK/agent-pid.
"$PY" "$DIR/compact.py" "$WORK" "$PPID" <"$WORK/payload" >/dev/null 2>&1 || exit 0
[ -r "$WORK/plan" ] || exit 0

# --- Request headers ---------------------------------------------------------
# Heredoc through a redirected `cat`, NOT printf/echo: an external printf would
# put the token into an argv. The hooks version is a constant of this file; the
# Mac uses it to tell when this host's hooks are older than the app's.
cat 2>/dev/null >"$WORK/header" <<HEADERS || exit 0
Authorization: Bearer $TOKEN
X-Lvx-Agent: vibe
X-Lvx-Vibe-Hooks-Version: 1.0.0
HEADERS

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
) 2>/dev/null || :

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
done <"$WORK/plan"
exit 0
