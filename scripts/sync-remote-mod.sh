#!/usr/bin/env bash
# Copies localvoxtral-mod's hooks module into the localvoxtral-remote plugin
# (#1412). The engine follows `$` into no import, so the two plugins cannot
# share the module's code through a file; the remote copy differs only in the
# plugin name its `$.state` values live under.
#
#   ./scripts/sync-remote-mod.sh           # write the copy
#   ./scripts/sync-remote-mod.sh --check   # fail if the copy is stale
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROM="$ROOT/integrations/claude-code/plugins/localvoxtral-mod"
TO="$ROOT/integrations/claude-code/plugins/localvoxtral-remote"
FILES=(hooks/register.tsx hooks/channel.ts hooks/inbox.ts hooks/hmac.ts hooks/remote.ts types/index.d.ts)

check=0
[[ "${1:-}" == "--check" ]] && check=1
status=0
for file in "${FILES[@]}"; do
  expected="$(sed "s/'localvoxtral-mod'/'localvoxtral-remote'/g" "$FROM/$file")"
  if [[ "$check" == 1 ]]; then
    if [[ "$expected" != "$(cat "$TO/$file" 2>/dev/null)" ]]; then
      echo "stale: ${TO#"$ROOT"/}/$file; run scripts/sync-remote-mod.sh" >&2
      status=1
    fi
  else
    mkdir -p "$(dirname "$TO/$file")"
    printf '%s\n' "$expected" >"$TO/$file"
  fi
done
exit "$status"
