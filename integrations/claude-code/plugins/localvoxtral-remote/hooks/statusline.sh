#!/bin/sh
# localvoxtral connection indicator for the Claude Code status line — strict
# POSIX sh, no dependencies at all (not even curl).
#
# NOT a hook, and NOT wired up by the plugin: Claude Code has no plugin-owned
# status line, and localvoxtral never writes `~/.claude/settings.json` (that
# file is the user's). The user opts in by copying this script to a stable
# path and pointing their `statusLine` setting at it — see the README's
# "Connection indicator" section. It renders whether hooks from THIS host are
# reaching localvoxtral on the Mac.
#
# It never dials the tunnel. A status line re-runs constantly, and every dial
# against a live forward with no app behind it makes ssh — on the other
# machine — print `connect_to …: failed.` onto the user's terminal; that is
# the storm post.sh's backoff exists to end, and a poller would bring it
# back. Instead it reads the host and per-session stamps post.sh leaves after
# each dial.
#
# stdout renders in the user's status line, so printing fails closed the same
# way post.sh's stdout gate does: stamp tokens only select fixed strings. No
# byte read from stdin or a stamp is ever echoed.
set -u

# Extract only the bounded path-safe session id shape post.sh accepts.
SESSION_ID="$(LC_ALL=C awk '
  match($0, /"session_id"[[:space:]]*:[[:space:]]*"[^"]*"/) {
    value = substr($0, RSTART, RLENGTH)
    sub(/^"session_id"[[:space:]]*:[[:space:]]*"/, "", value)
    sub(/"$/, "", value)
    print value
    exit
  }
' 2>/dev/null)" || SESSION_ID=""
case "$SESSION_ID" in
"" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*) SESSION_ID="" ;;
*) [ "${#SESSION_ID}" -le 64 ] || SESSION_ID="" ;;
esac

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/localvoxtral"
elif [ -n "${HOME:-}" ]; then
  STAMP_DIR="$HOME/.cache/localvoxtral"
else
  STAMP_DIR=""
fi

STATE=""
EPOCH=""
if [ -n "$STAMP_DIR" ] && [ -r "$STAMP_DIR/hook-status" ]; then
  LINE="$(cat "$STAMP_DIR/hook-status" 2>/dev/null)" || LINE=""
  STATE="${LINE%% *}"
  EPOCH="${LINE#* }"
  [ "$EPOCH" = "$LINE" ] && EPOCH=""
fi

# Host success expires after 15 minutes. A joined session stamp expires with
# the registry's four-hour TTL. Values are validated before arithmetic.
STALE_SECONDS=900
SESSION_TTL_SECONDS=14400
STALE=""
NOW="$(date +%s 2>/dev/null)" || NOW=""
case "$NOW" in "" | *[!0-9]* | ?????????????*) NOW="" ;; esac
case "$EPOCH" in "" | *[!0-9]* | ?????????????*) EPOCH="" ;; esac
if [ -n "$NOW" ] && [ -n "$EPOCH" ] && [ "$EPOCH" -le "$NOW" ] \
  && [ $((NOW - EPOCH)) -gt "$STALE_SECONDS" ]; then
  STALE=1
fi

SESSION_STATE=""
SESSION_EPOCH=""
if [ -n "$STAMP_DIR" ] && [ -n "$SESSION_ID" ] \
  && [ -r "$STAMP_DIR/sessions/$SESSION_ID" ]; then
  SESSION_LINE="$(cat "$STAMP_DIR/sessions/$SESSION_ID" 2>/dev/null)" || SESSION_LINE=""
  SESSION_STATE="${SESSION_LINE%% *}"
  SESSION_EPOCH="${SESSION_LINE#* }"
  [ "$SESSION_EPOCH" = "$SESSION_LINE" ] && SESSION_EPOCH=""
fi
case "$SESSION_EPOCH" in "" | *[!0-9]* | ?????????????*) SESSION_EPOCH="" ;; esac

SESSION_JOINED=""
if [ "$SESSION_STATE" = "joined" ] && [ -n "$NOW" ] && [ -n "$SESSION_EPOCH" ] \
  && { [ "$SESSION_EPOCH" -gt "$NOW" ] \
    || [ $((NOW - SESSION_EPOCH)) -le "$SESSION_TTL_SECONDS" ]; }; then
  SESSION_JOINED=1
fi

# Fixed strings only. `printf '%b'` renders the SGR escapes; `\0033` is the
# strictly-POSIX octal spelling of ESC (the `\0ddd` form is the one XCU
# guarantees for %b), and the dots are literal UTF-8. printf here is safe in
# a way it is not in post.sh: there is no secret anywhere in this process,
# so an external printf putting its argument into an argv leaks nothing.
# Shape and color both carry the state. NO_COLOR and dumb terminals keep the
# same glyphs without escape sequences.
USE_COLOR=1
if [ "${NO_COLOR+x}" = x ] || [ "${TERM:-}" = dumb ]; then
  USE_COLOR=""
fi

render() {
  STATE_NAME="$1"
  if [ -z "$USE_COLOR" ]; then
    case "$STATE_NAME" in
    joined) printf '%s\n' 'lvx ●' ;;
    unknown) printf '%s\n' 'lvx ◐' ;;
    offline) printf '%s\n' 'lvx ○' ;;
    rejected) printf '%s\n' 'lvx ✕' ;;
    esac
    return 0
  fi
  case "$STATE_NAME" in
  joined) printf '%b\n' 'lvx \0033[32m●\0033[0m' ;;
  unknown) printf '%b\n' 'lvx \0033[33m◐\0033[0m' ;;
  offline) printf '%b\n' 'lvx \0033[90m○\0033[0m' ;;
  rejected) printf '%b\n' 'lvx \0033[31m✕\0033[0m' ;;
  esac
}

case "$STATE" in
ok)
  if [ -n "$STALE" ]; then
    render offline
  elif [ -n "$SESSION_JOINED" ]; then
    render joined
  else
    render unknown
  fi
  ;;
http-* | unconfigured) render rejected ;;
*) render offline ;;
esac
exit 0
