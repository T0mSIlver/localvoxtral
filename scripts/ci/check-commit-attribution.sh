#!/bin/bash
# check-commit-attribution.sh <rev-range>
#
# Fails when a commit in <rev-range> credits an AI tool: a Co-authored-by
# trailer naming Claude or an anthropic.com address, or a Claude-Session
# trailer. The owner's rule (2026-10-01): commits on main carry no AI
# attribution; main was rewritten once to drop the trailers that got through.
# CI runs it on a PR's own commits, whose messages a squash merge copies into
# main, and on each push to main, which is where a trailer GitHub adds at
# merge time (one per commit author who isn't the merger) first shows up.
#
# Prints each offending commit and line. Exit 1 if any, 0 if none, 2 on usage.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <rev-range>" >&2
  exit 2
fi

trailer_pattern='^[[:space:]]*(co-authored-by:.*(claude|anthropic)|claude-session:)'
found=0
for commit in $(git rev-list "$1"); do
  short="$(git rev-parse --short "$commit")"
  lines="$(git log -1 --format=%B "$commit" | grep -iE "$trailer_pattern" || true)"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines" | sed "s/^/$short: /"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "Remove these lines from the commit messages (AGENTS.md, \"No AI attribution\")." >&2
  exit 1
fi
echo "No AI attribution in $1"
