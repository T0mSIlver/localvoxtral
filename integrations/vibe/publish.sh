#!/bin/sh
# localvoxtral Mistral Vibe hook shim — strict POSIX sh, no dependencies beyond
# a shell and the publisher binary it locates.
#
# Vibe runs this once per hook (`~/.vibe/hooks.toml`) with the hook JSON on
# stdin. Its ONLY job is to find the `localvoxtral-claude-hook` publisher and
# run it in Vibe mode.
#
# Everything here is fail-open. Vibe reports a hook's non-zero exit or
# non-JSON stdout as a hook failure on the user's turn, so when the publisher
# is missing or cannot run we drain stdin and exit 0. This script prints
# NOTHING on any path, and stderr is discarded.
set -u

# Candidate order, most specific first:
#   1. LOCALVOXTRAL_CLAUDE_HOOK_BIN — explicit env override.
#   2. the link the app repoints at its own publisher on every launch
#      (ClaudePublisherPointer); it follows the app when it moves.
#   3. the usual bundle locations.
#   4. PATH.
for candidate in \
  "${LOCALVOXTRAL_CLAUDE_HOOK_BIN:-}" \
  "${HOME:-}/Library/Application Support/localvoxtral/claude/publisher" \
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
  # Fail open: consume stdin so Vibe's writer never sees EPIPE.
  cat >/dev/null 2>&1
  exit 0
fi

# NOT `exec`: if the publisher cannot start, a failed exec would become the
# hook's exit status and Vibe would show it. Run as a child and swallow it.
#
# $PPID is this shell's parent: Vibe itself, or the `sh -c` Vibe spawned the
# command through when that shell did not exec. The publisher tells the two
# apart (ClaudeHookPublisher.vibeAncestorPID); it needs a starting pid that
# outlives this line, which its own getppid() — this shell — does not.
LOCALVOXTRAL_CLAUDE_PPID="$PPID" "$BIN" --agent vibe 2>/dev/null
exit 0
