#!/usr/bin/env bash
# e2e-dictation-outcome.sh STATUS GUARDED — the exit status ui-smoke.yml's
# e2e dictation step concludes with, given scripts/e2e-dictation.sh's STATUS
# and whether the run is the owner's guarded dispatch on main.
#
#   3 (the Mac was locked, the STT server down or lagging): a guarded run
#     warns and stays green, like ui-smoke-guard.sh's own skips; a branch
#     dispatch or the label is a PR asking for a result and goes red.
#   4 (the app under test has no Accessibility grant): red everywhere. The
#     grant does not come back by itself, so a green skip would hide every
#     later run measuring nothing (run 36929217304).
#   anything else: unchanged.
set -euo pipefail

status="${1:?usage: e2e-dictation-outcome.sh STATUS GUARDED}"
guarded="${2:?usage: e2e-dictation-outcome.sh STATUS GUARDED}"

case "$status" in
  3)
    if [[ "$guarded" == "true" ]]; then
      echo "::warning::e2e dictation did not run: the Mac was not in a state to run it."
      exit 0
    fi
    ;;
  4)
    echo "::error::e2e dictation measured nothing: the app under test has no Accessibility grant. Allow the localvoxtral-dev-signed localvoxtral in System Settings > Privacy & Security > Accessibility, then dispatch again."
    ;;
esac
exit "$status"
