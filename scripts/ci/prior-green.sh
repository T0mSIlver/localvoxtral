#!/usr/bin/env bash
# Prints `true` when the newest finished run of CHECK on SHA passed, else
# `false`. Used by ci.yml's `prior` job: marking a PR ready (or back to draft)
# starts a run on a head that already ran build-test and linux, and on the
# hosted macOS queue every rerun costs a slot.
#
#   scripts/ci/prior-green.sh <owner/repo> <sha> <check-name>
#
# Skipped and cancelled runs are not results: a skipped job is the one a
# previous ready left, and a cancelled one never finished. Among the rest the
# newest decides, so a later failure on the same head is never covered by an
# older pass. Any error prints `false`: the caller then runs the job, and a
# failed lookup can never turn a check green.
set -uo pipefail

repo="${1:?owner/repo}" sha="${2:?sha}" name="${3:?check name}"

# `filter=all`: the default lists only each run's latest attempt, which hides
# a failure behind its cancelled retry, and the older pass would then decide.
# Every page, then the newest real result across them.
answer="$(gh api --paginate \
  "repos/$repo/commits/$sha/check-runs?check_name=$name&filter=all&per_page=100" \
  --jq '.check_runs[]
        | select(.status == "completed")
        | select(.conclusion != "skipped" and .conclusion != "cancelled")
        | "\(.completed_at) \(.conclusion)"' 2>/dev/null)" || answer=""
answer="$(printf '%s\n' "$answer" | LC_ALL=C sort | tail -n 1 | cut -d' ' -f2)"

if [[ "$answer" == "success" ]]; then echo true; else echo false; fi
