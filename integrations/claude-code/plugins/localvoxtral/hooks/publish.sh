#!/bin/sh
# localvoxtral Claude Code hook shim — strict POSIX sh, no dependencies beyond
# a shell and the publisher binary it locates.
#
# Claude Code runs this once per hook event with the event JSON on stdin. Its
# ONLY job is to find the `localvoxtral-claude-hook` publisher and run it.
#
# Everything here is fail-open. If the publisher is missing (app not installed,
# plugin installed on a box without the app, a remote host over SSH) or cannot
# be executed (wrong architecture, missing +x, a quarantined bundle), we drain
# stdin and exit 0 so Claude Code never blocks, warns, or fails a turn because
# dictation context is unavailable.
#
# stdout belongs to the publisher: Claude Code parses a hook's stdout as control
# JSON, and for UserPromptSubmit non-JSON stdout is appended to the user's
# prompt. This script therefore prints NOTHING on any path, and stderr is
# discarded.
set -u

EVENT="${1:-Unknown}"

# Candidate order, most specific first:
#   1. LOCALVOXTRAL_CLAUDE_HOOK_BIN — explicit env override; also the seam for
#      remote/SSH setups where the publisher lives somewhere non-standard.
#   2. CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH — the `publisher_path` userConfig
#      that ClaudePluginInstallService sets at install time. This is what makes
#      the plugin work for an app in ~/Applications, a dev build, or a mounted
#      volume, rather than only the two guesses below.
#   3. the usual bundle locations.
#   4. PATH (Linux/remote builds of the publisher).
for candidate in \
  "${LOCALVOXTRAL_CLAUDE_HOOK_BIN:-}" \
  "${CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH:-}" \
  "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook" \
  "${HOME:-}/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook"
do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    BIN="$candidate"
    break
  fi
done

if [ -z "${BIN:-}" ]; then
  BIN="$(command -v localvoxtral-claude-hook 2>/dev/null)" || BIN=""
fi

if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
  # Fail open: consume stdin so Claude Code's writer never sees EPIPE, say
  # nothing, succeed.
  cat >/dev/null 2>&1
  exit 0
fi

# NOT `exec`: exec replaces this shell, so if the publisher cannot start
# (Exec format error, missing dyld dependency, quarantine) the shell is already
# gone and the failing exec status becomes the hook's exit code — a visible
# error on the user's turn, which is exactly what fail-open must prevent.
# Running it as a child means we stay alive to swallow that.
#
# Because we do NOT exec, the publisher's own getppid() is THIS shell, which
# exits a millisecond later. The app probes that pid for session liveness, so
# handing it a dying shell would mark every session stale and silently discard
# all context. $PPID is this shell's parent — the process Claude Code actually
# spawned the hook from — so pass it explicitly.
LOCALVOXTRAL_CLAUDE_PPID="$PPID" "$BIN" --event "$EVENT" 2>/dev/null
exit 0
