#!/usr/bin/env bash
# Replays labelled quick captures through the production router (#730,
# QuickCaptureReplayLiveTests) and prints the scoreboard. Linux only: it
# spends Jev or chat-model tokens (36 captures cost well under a cent on Jev,
# a few cents on a hosted chat model), and nothing here may run on the Mac.
#
#   scripts/linux/quick-capture-replay.sh --captures FILE --projects FILE \
#     [--jev typesafe|vercelGateway --jev-key-file FILE] \
#     [--chat-url URL --chat-model ID [--chat-key-file FILE] [--chat-extra JSON]] \
#     [--follow-ups] \
#     [--polish-url URL --polish-model ID [--polish-key-file FILE] [--polish-extra JSON]] \
#     [--dry-run]
#
# --follow-ups replays the captures as one Inbox stream (#965): earlier
# captures are offered for a follow-up to join, and a capture's `join` field
# names the one it continues.
#
# --polish-url polishes each capture first, through the same request builder
# as the app (#970), with the bundled standard prompt; the router and the
# follow-up check then read the polished words. `QC PNAME` lines and the
# `QC POLISH` line count the captures where a project's name appears in the
# raw and in the polished words; no capture text is printed.
#
# --dry-run builds every polish request and prints counts, then stops before
# any request: no router, no polish, no key needed.
#
# Classifiers are tried in that order, as the app tries Jev first. The
# captures are private dictations: keep them outside the repository.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "quick-capture-replay: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
follow_ups="" dry_run="" polish_url="" polish_model="" polish_key_file="" polish_extra="" captures="" projects="" jev_host="" jev_key_file="" chat_url="" chat_model="" chat_key_file="" chat_extra=""
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
    --follow-ups) follow_ups=1; shift ;;
    --polish-url) polish_url="$2"; shift 2 ;;
    --polish-model) polish_model="$2"; shift 2 ;;
    --polish-key-file) polish_key_file="$2"; shift 2 ;;
    --polish-extra) polish_extra="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "quick-capture-replay: unknown flag $1" >&2; exit 2 ;;
  esac
done
[[ -n "$captures" && -n "$projects" ]] || { echo "quick-capture-replay: --captures and --projects are required" >&2; exit 2; }
[[ -z "$jev_key_file" ]] || jev_key_file="$(realpath "$jev_key_file")"
[[ -z "$chat_key_file" ]] || chat_key_file="$(realpath "$chat_key_file")"
[[ -z "$polish_key_file" ]] || polish_key_file="$(realpath "$polish_key_file")"
[[ -z "$polish_url" || -n "$polish_model" ]] || { echo "quick-capture-replay: --polish-url needs --polish-model" >&2; exit 2; }

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
  QC_CHAT_URL="$chat_url" QC_CHAT_MODEL="$chat_model" QC_CHAT_KEY_FILE="$chat_key_file" QC_CHAT_EXTRA="$chat_extra" QC_FOLLOW_UPS="$follow_ups" \
  QC_POLISH_URL="$polish_url" QC_POLISH_MODEL="$polish_model" QC_POLISH_KEY_FILE="$polish_key_file" QC_POLISH_EXTRA="$polish_extra" \
  QC_DRY_RUN="$dry_run" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter QuickCaptureReplayLiveTests
