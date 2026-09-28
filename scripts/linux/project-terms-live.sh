#!/usr/bin/env bash
# Runs the real `claude -p`, `vibe -p` (#609) and `opencode run` (#642)
# project-terms requests through the production proposer, against a fixture
# repository whose hooks and plugins write a marker file
# (ProjectTermProposalLiveTests). Linux only: it spends about $0.25 of Claude
# and Mistral tokens, and nothing here may run on the Mac.
#
#   SWIFT=/path/to/swift scripts/linux/project-terms-live.sh [test filter]
#
# The run sees only HOME, PATH and LANG, as the app's run sees only the app's
# own environment: no CLAUDE_CODE_* or VIBE_HOME from the calling shell. The
# opencode case bills the Mistral key in ~/.config/localvoxtral/mistral_api_key
# unless LV_OPENCODE_LIVE_MODEL names another provider.
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
opencode_env=()
[[ -n "${LV_OPENCODE_LIVE_MODEL:-}" ]] && opencode_env+=(LV_OPENCODE_LIVE_MODEL="$LV_OPENCODE_LIVE_MODEL")
key_file="$HOME/.config/localvoxtral/mistral_api_key"
[[ -r "$key_file" ]] && opencode_env+=(LV_OPENCODE_LIVE_MISTRAL_KEY="$(<"$key_file")")
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" LV_PROJECT_TERMS_LIVE=1 "${opencode_env[@]}" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter "${1:-ProjectTermProposalLiveTests}"
