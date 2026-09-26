#!/usr/bin/env bash
# Drafts issues for labelled quick captures through the production drafter
# (#731, QuickCaptureDraftLiveTests), one markdown file per capture in --out.
# Linux only: each draft spends up to $0.50 of the agent's plan or key, and
# nothing here may run on the Mac. The runs are read-only in the checkouts
# the project list names; `gh issue list` reads their open issues.
#
#   scripts/linux/quick-capture-drafts.sh --captures FILE --projects FILE \
#     --ids h28,n2,... --out DIR [--agent claude|vibe]
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "quick-capture-drafts: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
captures="" projects="" ids="" out="" agent=claude
while [[ $# -gt 0 ]]; do
  case "$1" in
    --captures) captures="$2"; shift 2 ;;
    --projects) projects="$2"; shift 2 ;;
    --ids) ids="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    *) echo "quick-capture-drafts: unknown flag $1" >&2; exit 2 ;;
  esac
done
[[ -n "$captures" && -n "$projects" && -n "$ids" && -n "$out" ]] \
  || { echo "quick-capture-drafts: --captures, --projects, --ids and --out are required" >&2; exit 2; }
mkdir -p "$out"

SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"
SWIFT="$SWIFT" LV_LINUX_SCRATCH="$SCRATCH" ./scripts/core-tests-linux.sh --filter NoSuchTestBuildOnly >/dev/null
# SwiftPM deletes Package.resolved on Linux, where the package has no
# dependencies; the Mac build needs the pins back.
resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
trap 'cat "$resolved_backup" >Package.resolved; rm -f "$resolved_backup"' EXIT
# The run sees only HOME, PATH and LANG, as the app's run sees only the
# app's own environment.
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" LV_QUICK_CAPTURE_DRAFTS=1 \
  QC_CAPTURES="$(realpath "$captures")" QC_PROJECTS="$(realpath "$projects")" \
  QC_IDS="$ids" QC_AGENT="$agent" QC_OUT="$(realpath "$out")" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter QuickCaptureDraftLiveTests
