#!/usr/bin/env bash
set -uo pipefail

# Preflight for the Mac build loop: is the build host reachable, is the gate
# answering, is voxmlx serving, and does CI look alive? Agents should run this
# before long remote work so a sleeping Mac fails fast with an actionable
# message instead of a hung rsync or a CI job queued forever.
#
# Exit code: 0 when the build loop is usable (SSH gate reachable), 1 otherwise.
# voxmlx/CI problems are reported but only warn — unit builds still work
# without them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${LV_BUILD_HOST:-$(git -C "$ROOT_DIR" config --get localvoxtral.buildhost || true)}"

if [[ -z "$HOST" ]]; then
  echo "FAIL: no build host configured (git config localvoxtral.buildhost)" >&2
  exit 1
fi

fail=0

echo "== Mac build host: $HOST =="

diag_output=""
if diag_output="$(timeout 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" diag 2>&1)"; then
  echo "OK: SSH gate reachable (gate v2)"
  # Surface the two liveness signals agents actually branch on.
  echo "$diag_output" | grep -A2 -- '-- port 8000 --' | sed 's/^/  /'
  if echo "$diag_output" | grep -q 'Runner.Listener'; then
    echo "  actions runner: process visible"
  fi
elif echo "$diag_output" | grep -qi 'denied command\|command not allowed'; then
  echo "OK: SSH gate reachable (gate v1 — no diagnostics; install v2, see scripts/mac/README.md)"
else
  echo "FAIL: build host unreachable over SSH:" >&2
  echo "$diag_output" | tail -3 | sed 's/^/  /' >&2
  echo "  (Mac asleep, owner logged out, or IP changed — update 'git config localvoxtral.buildhost')" >&2
  fail=1
fi

# CI recency is a best-effort proxy for "self-hosted runner online" — the
# runners API needs a repo-admin token, which this box deliberately lacks.
if command -v gh >/dev/null 2>&1; then
  latest_run="$(gh run list --limit 1 --json status,conclusion,displayTitle,updatedAt \
    --template '{{range .}}{{.status}}/{{.conclusion}} {{.updatedAt}} {{.displayTitle}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$latest_run" ]]; then
    echo "CI:  latest run: $latest_run"
    if [[ "$latest_run" == queued/* ]]; then
      echo "WARN: latest CI run is queued — self-hosted runner may be offline" >&2
    fi
  else
    echo "WARN: could not query CI runs via gh" >&2
  fi
fi

exit "$fail"
