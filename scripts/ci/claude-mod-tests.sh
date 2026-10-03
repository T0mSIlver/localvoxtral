#!/usr/bin/env bash
# Validates and tests every Claude Code mod under integrations/claude-code
# with a pinned Claude Code build. Neither command needs an account.
#
#   CLAUDE=claude ./scripts/ci/claude-mod-tests.sh   # use the claude on PATH
#
# Mods are early access and their API moves between releases: bump the pin
# deliberately, with the mod's tests green on the new build.
set -euo pipefail

CLAUDE_CODE_VERSION="2.1.287"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -n "${CLAUDE:-}" ]]; then
  claude_cmd=("$CLAUDE")
else
  claude_cmd=(npx --yes "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}")
fi

status=0
for manifest in "$ROOT"/integrations/claude-code/plugins/*/hooks/hooks.json; do
  grep -q '"modules"' "$manifest" || continue
  plugin="$(dirname "$(dirname "$manifest")")"
  echo "== ${plugin#"$ROOT"/}"
  "${claude_cmd[@]}" plugin validate "$plugin" || status=1
  "${claude_cmd[@]}" plugin test "$plugin" || status=1
done
exit "$status"
