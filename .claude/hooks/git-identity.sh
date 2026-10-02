#!/bin/bash
# SessionStart hook: a session whose git identity is Claude's commits as the
# repository owner instead. GitHub's squash merge credits every commit author
# in a PR as a Co-authored-by trailer on main, so a Claude-authored commit put
# "Co-authored-by: Claude" on main even with a clean message (2026-10-01).
# Sets the identity in this clone's config only, and only when it is Claude's:
# a person's own identity is left alone.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}"
email="$(git config user.email || true)"
case "$email" in
  *@anthropic.com)
    git config --local user.name "Tom Vaucourt"
    git config --local user.email "34662901+T0mSIlver@users.noreply.github.com"
    ;;
esac
