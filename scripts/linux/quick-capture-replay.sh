#!/usr/bin/env bash
# Replays labelled quick captures through the production router (#730,
# QuickCaptureReplayLiveTests) and prints the scoreboard. Linux only: it
# spends Jev or chat-model tokens (36 captures cost well under a cent on Jev,
# a few cents on a hosted chat model), and nothing here may run on the Mac.
#
#   scripts/linux/quick-capture-replay.sh --captures FILE --projects FILE \
#     [--jev typesafe|vercelGateway --jev-key-file FILE] \
#     [--chat-url URL --chat-model ID [--chat-key-file FILE] [--chat-extra JSON]]
#
# Classifiers are tried in that order, as the app tries Jev first. The
# captures are private dictations: keep them outside the repository.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "quick-capture-replay: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
captures="" projects="" jev_host="" jev_key_file="" chat_url="" chat_model="" chat_key_file="" chat_extra=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --captures) captures="$2"; shift 2 ;;
    --projects) projects="$2"; shift 2 ;;
    --jev) jev_host="$2"; shift 2 ;;
    --jev-key-file) jev_key_file="$2"; shift 2 ;;
    --chat-url) chat_url="$2"; shift 2 ;;
    --chat-model) chat_model="$2"; shift 2 ;;
    --chat-key-file) chat_key_file="$2"; shift 2 ;;
    --chat-extra) chat_extra="$2"; shift 2 ;;
    *) echo "quick-capture-replay: unknown flag $1" >&2; exit 2 ;;
  esac
done
[[ -n "$captures" && -n "$projects" ]] || { echo "quick-capture-replay: --captures and --projects are required" >&2; exit 2; }
[[ -z "$jev_key_file" ]] || jev_key_file="$(realpath "$jev_key_file")"
[[ -z "$chat_key_file" ]] || chat_key_file="$(realpath "$chat_key_file")"

SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"
SWIFT="$SWIFT" LV_LINUX_SCRATCH="$SCRATCH" ./scripts/core-tests-linux.sh --filter NoSuchTestBuildOnly >/dev/null
# SwiftPM deletes Package.resolved on Linux, where the package has no
# dependencies; the Mac build needs the pins back.
resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
trap 'cat "$resolved_backup" >Package.resolved; rm -f "$resolved_backup"' EXIT
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" LV_QUICK_CAPTURE_REPLAY=1 \
  QC_CAPTURES="$(realpath "$captures")" QC_PROJECTS="$(realpath "$projects")" \
  QC_JEV_HOST="$jev_host" QC_JEV_KEY_FILE="$jev_key_file" \
  QC_CHAT_URL="$chat_url" QC_CHAT_MODEL="$chat_model" QC_CHAT_KEY_FILE="$chat_key_file" QC_CHAT_EXTRA="$chat_extra" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter QuickCaptureReplayLiveTests
