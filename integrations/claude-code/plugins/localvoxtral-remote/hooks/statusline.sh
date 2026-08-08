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
# back. Instead it reads the one-line `hook-status` stamp post.sh leaves
# after each dial (`<state> <epoch>`), so the indicator is exactly as fresh
# as the session's own hook traffic — which re-runs the status line anyway.
#
# stdout renders in the user's status line, so printing fails closed the same
# way post.sh's stdout gate does: the stamp's first token only ever SELECTS
# one of the fixed strings below — no byte of the stamp file (which another
# process could have altered; it is merely 0600) is ever echoed, and an
# unrecognized state renders as the never-heard-anything default.
set -u

# Drain the status-line payload (JSON on stdin, unused: the stamp is
# host-level) so Claude Code's writer never sees EPIPE.
cat >/dev/null 2>&1

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/localvoxtral"
elif [ -n "${HOME:-}" ]; then
  STAMP_DIR="$HOME/.cache/localvoxtral"
else
  STAMP_DIR=""
fi

STATE=""
if [ -n "$STAMP_DIR" ] && [ -r "$STAMP_DIR/hook-status" ]; then
  LINE="$(cat "$STAMP_DIR/hook-status" 2>/dev/null)" || LINE=""
  STATE="${LINE%% *}"
fi

# Fixed strings only. `printf '%b'` renders the SGR escapes; `\0033` is the
# strictly-POSIX octal spelling of ESC (the `\0ddd` form is the one XCU
# guarantees for %b), and the dots are literal UTF-8. printf here is safe in
# a way it is not in post.sh: there is no secret anywhere in this process,
# so an external printf putting its argument into an argv leaks nothing.
# Green dot: the Mac answered 200 to this host's last hook. Everything else
# names the failure the last dial actually saw.
case "$STATE" in
ok) printf '%b\n' '\0033[32m●\0033[0m localvoxtral connected' ;;
http-401) printf '%b\n' '\0033[33m○\0033[0m localvoxtral token rejected' ;;
http-*) printf '%b\n' '\0033[33m○\0033[0m localvoxtral not connected' ;;
down) printf '%b\n' '\0033[2m○ localvoxtral unreachable\0033[0m' ;;
unconfigured) printf '%b\n' '\0033[33m○\0033[0m localvoxtral token not configured' ;;
*) printf '%b\n' '\0033[2m○ localvoxtral no hooks yet\0033[0m' ;;
esac
exit 0
