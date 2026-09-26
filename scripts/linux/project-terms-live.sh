#!/usr/bin/env bash
# Runs the real `claude -p` and `vibe -p` project-terms requests (#609) through
# the production proposer, against a fixture repository whose hooks write a
# marker file (ProjectTermProposalLiveTests). Linux only: it spends about $0.25
# of Claude and Mistral tokens, and nothing here may run on the Mac.
#
#   SWIFT=/path/to/swift scripts/linux/project-terms-live.sh
#
# The run sees only HOME, PATH and LANG, as the app's run sees only the app's
# own environment: no CLAUDE_CODE_* or VIBE_HOME from the calling shell.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "project-terms-live: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"
SWIFT="$SWIFT" LV_LINUX_SCRATCH="$SCRATCH" ./scripts/core-tests-linux.sh --filter NoSuchTestBuildOnly >/dev/null
# SwiftPM deletes Package.resolved on Linux, where the package has no
# dependencies; the Mac build needs the pins back.
resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
trap 'cat "$resolved_backup" >Package.resolved; rm -f "$resolved_backup"' EXIT
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" LV_PROJECT_TERMS_LIVE=1 \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter ProjectTermProposalLiveTests
