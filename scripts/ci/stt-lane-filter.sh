#!/bin/bash
# Decides whether CI must run the live STT integration
# (`swift test --filter RealtimeAPIVLLMIntegrationTests`) for a given change.
# Standalone for the same reason as the other lane filters: the decision is
# testable without a workflow run.
#
# Usage:
#   scripts/ci/stt-lane-filter.sh <changed-files-file> [event-name] [marker-text-file]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [event-name]          $GITHUB_EVENT_NAME; absent means "decide on paths
#                         alone" (what the tests do)
#   [marker-text-file]    optional free text (PR body + head commit message);
#                         the literal [run-stt-integration] runs the lane
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
#
# WHY THIS LANE CAN BE GATED. It ran on every mac-lanes run: 50 s of live
# inference on the owner's Mac, 18 % of the job (#418). What it drives is the
# realtime websocket client against the STT test service. That service is the
# helper INSTALLED on the build host, not the one the PR builds, so a
# SpeechHelper change cannot move this lane (SpeechHelperIntegrationTests and
# speechd-lane-filter.sh cover that). The lane can only see a change to the
# client family, to the scorer and TTS fixture it uses, to the package pins,
# or to how CI invokes it. A compile break anywhere else is build-test's to
# catch, and the nightly e2e dictation (scripts/e2e-dictation.sh) drives the
# same client through the whole packaged app.
#
set -euo pipefail

MARKER='[run-stt-integration]'

# The files the suite executes, traced from the test: the client, its base
# and protocol, what they call, and what the unconditional device test calls.
# Exact paths except for the client family: bash `case` lets `*` cross `/`, and
# a wide `*Realtime*` also bought the lane for the view model's event handling
# and the reconnect policy, which the suite never runs. A new file the client
# comes to depend on has to be added here; until then main's run and the
# nightly e2e dictation are what see it.
PATTERNS=(
  'Sources/localvoxtral/RealtimeClient.swift'
  'Sources/localvoxtral/*RealtimeWebSocketClient.swift'   # Base, and Mistral, which shares it
  'Sources/localvoxtral/RealtimeAPIWebSocketClient.swift' # the client under test
  'Sources/localvoxtral/StringExtensions.swift'           # API key and model trimming
  'Sources/localvoxtral/MicrophoneCaptureService.swift'
  'Sources/localvoxtral/AudioDeviceManager.swift'         # the unavailable-device test
  'Sources/localvoxtral/TextMergingAlgorithms.swift'      # the scorer normalizes through it
  'Tests/localvoxtralTests/RealtimeAPIVLLMIntegrationTests.swift'
  'Tests/localvoxtralTests/IntegrationTestSupport.swift'
  'Package.swift'
  'Package.resolved'
  '.github/workflows/ci.yml'
  'scripts/ci/stt-lane-filter.sh'
  'scripts/mac/lv-test-servers.sh'                  # how the service is warmed
)

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <changed-files-file> [event-name] [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
EVENT_NAME="${2:-}"
MARKER_TEXT_FILE="${3:-}"

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

case "$EVENT_NAME" in
  pull_request | "")
    ;;
  workflow_dispatch)
    echo "run=true"
    echo "reason=workflow_dispatch — dispatches build everything"
    exit 0
    ;;
  push)
    echo "run=true"
    echo "reason=push to main — main is the parity reference and is never gated"
    exit 0
    ;;
  *)
    echo "run=true"
    echo "reason=unrecognized event '$EVENT_NAME' — failing open"
    exit 0
    ;;
esac

if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]] \
    && grep -qF "$MARKER" "$MARKER_TEXT_FILE"; then
  echo "run=true"
  echo "reason=explicit $MARKER marker"
  exit 0
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern)
        echo "run=true"
        echo "reason=matched $file ($pattern)"
        exit 0
        ;;
    esac
  done
done <"$CHANGED_FILES_FILE"

echo "run=false"
echo "reason=no change the live STT lane can see; add $MARKER to the PR body or commit message and push to opt in"
