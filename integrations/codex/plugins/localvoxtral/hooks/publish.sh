#!/bin/sh
# localvoxtral Codex hook shim — strict POSIX sh, no dependencies beyond a
# shell and the publisher binary it locates.
#
# Codex runs this once per hook event (`hooks/hooks.json` beside it) with the
# event JSON on stdin. Its ONLY job is to find the `localvoxtral-claude-hook`
# publisher and run it in Codex mode.
#
# Everything here is fail-open. Codex reads a hook's stdout as a decision and
# reports a non-zero exit as a failed hook, so when the publisher is missing
# or cannot run we drain stdin and exit 0. This script prints NOTHING on any
# path, and stderr is discarded.
#
# Changing this file does not ask the user to trust the hooks again: Codex
# hashes the command line in hooks.json, not the script it runs. Changing
# hooks.json does.
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
  # Fail open: consume stdin so Codex's writer never sees EPIPE.
  cat >/dev/null 2>&1
  exit 0
fi

# NOT `exec`: if the publisher cannot start, a failed exec would become the
# hook's exit status and Codex would show it. Run as a child and swallow it.
#
# $PPID is this shell's parent: Codex itself, or the login shell Codex runs
# the command through when that shell did not exec. The publisher tells the
# two apart (ClaudeHookPublisher.vibeAncestorPID); it needs a starting pid
# that outlives this line, which its own getppid() — this shell — does not.
LOCALVOXTRAL_CLAUDE_PPID="$PPID" "$BIN" --agent codex 2>/dev/null
exit 0
