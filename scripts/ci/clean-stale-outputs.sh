#!/usr/bin/env bash
# Shared "Clean stale outputs (keep build caches)" for the persistent
# self-hosted runner workspace, which ci.yml, ui-smoke.yml, and eval-e2e.yml
# all share with `clean: false` checkouts. The three workflows previously
# carried hand-copied variants of this block and the lists drifted (PR #157
# review): ci.yml removed format-lint.txt/default.profraw but not logs,
# the other two removed logs but left coverage/lint droppings behind.
#
# Removes every transient output any of the three can leave behind — safe
# because none of them is a build cache — and repairs ci.yml's launch-smoke
# `.build` rename if a cancelled run died mid-smoke (its EXIT trap doesn't
# run on SIGKILL): a leftover .build.smoke-hidden would make the next run's
# `mv` nest one dir inside the other and silently corrupt the cache.
#
# Operates on the repo root containing this script, so callers don't have
# to be careful about their working directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT_DIR"

if [[ -d .build.smoke-hidden ]]; then
  rm -rf .build
  mv .build.smoke-hidden .build
fi

rm -rf dist logs format-lint.txt default.profraw

# Transient eval enable markers (gitignored, marker-through-the-tree
# pattern): clean: false preserves them across runs, and a stray one would
# flip a marker-gated live suite ON in a plain unit step.
rm -f .agent-eval-e2e-enable.json .llm-polish-eval-enable.json \
  .polishd-integration-enable.json .speechd-integration-enable.json
