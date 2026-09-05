#!/bin/bash
# Regression test: no workflow job may declare the same step name twice.
#
# Why this exists: ci.yml carried two byte-identical copies of the
# "Clean abandoned test processes" + "Process-cleanup regression tests" pair
# from PR #150 (2026-07-20) until 2026-09-05 — a rebase artifact that no
# reviewer or check could see, because a duplicated step is perfectly valid
# YAML and both copies pass. It went unnoticed for six weeks because the
# shell-test step cost ~13 s; PR #238 added scripts/ci/test-ui-gate.sh and the
# duplicate silently became ~90 s of every single CI run.
#
# A repeated step name in one job is never intentional here: it is either
# copy-paste work that should have been one step, or a merge artifact. The
# check is name-based on purpose — that is the symptom a human reads in the
# Actions UI ("Process-cleanup regression tests" twice) and the one a rebase
# reproduces.
#
# Pure bash, no YAML library: macOS system python3 ships no PyYAML and this
# must run on hosted fork-PR runners too. Steps are matched structurally by
# indentation (a step name is the `- name:` at the deepest list level), and
# names are grouped per `jobs:` entry so two jobs may legitimately share one.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"

failures=0

check_file() {
  local file="$1"
  # awk state machine:
  #   - a line matching /^  [A-Za-z0-9_-]+:$/ at two-space indent inside the
  #     top-level `jobs:` mapping starts a new job;
  #   - a line matching /^ +- name: / is a step name (steps are the only
  #     deeper list of named mappings in these workflows);
  #   - names are printed as "<job>\t<name>" so the caller can group.
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[^[:space:]#]/      { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      job = $0
      sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
      next
    }
    in_jobs && job != "" && /^[[:space:]]+- name: / {
      name = $0
      sub(/^[[:space:]]+- name: /, "", name)
      print job "\t" name
    }
  ' "$file"
}

for file in "$WORKFLOW_DIR"/*.yml; do
  [[ -e "$file" ]] || continue
  duplicates="$(check_file "$file" | sort | uniq -d || true)"
  if [[ -n "$duplicates" ]]; then
    echo "FAIL: $(basename "$file") declares the same step name twice in one job:" >&2
    sed 's/^/  /' <<<"$duplicates" >&2
    failures=$((failures + 1))
  fi
done

# The check is only worth anything if it actually saw steps. A silent zero
# (indentation convention changed, directory moved) must fail, not pass.
total="$(for file in "$WORKFLOW_DIR"/*.yml; do check_file "$file"; done | wc -l | tr -d ' ')"
if [[ "$total" -lt 50 ]]; then
  echo "FAIL: only $total step names parsed across $WORKFLOW_DIR — the parser is broken" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "test-workflow-step-names: $failures failure(s)" >&2
  exit 1
fi

echo "test-workflow-step-names: OK ($total step names, no duplicates within a job)"
