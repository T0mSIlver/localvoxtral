#!/bin/bash
# Decides whether a change needs the e2e dictation check (ui-smoke.yml's
# second check, scripts/e2e-dictation.sh). That check holds the only Mac for
# about ten minutes and takes the owner's keyboard, so the answer is a path
# match, not each agent's judgment (#544). scripts/ui-smoke-dispatch.sh asks
# it before dispatching; the PR's Proof section quotes its reason line.
#
# Usage:
#   scripts/ci/e2e-dictation-filter.sh <changed-files-file>
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary or a PR body>
#
# Exits 0 for both decisions; non-zero only on usage errors.
set -euo pipefail

# The session path between the capture callback and the focused app, as
# AGENTS.md (Proof) names it: session start and stop, the realtime clients,
# transcript merging, text insertion, the overlay commit. Plus the check
# itself, and the dogfood capture it dictates through.
#
# Deliberately NOT here: the polish path (polishing is off in every scenario;
# PolishRequestGoldenTests proves it), the overlay's look (wrap, layout,
# anchor; UI change rules apply), settings, onboarding, the Claude context
# path, the helpers (their integration lanes), docs and CI plumbing. The
# evening runs on main catch what a path list misses.
PATTERNS=(
  'Sources/localvoxtral/DictationViewModel.swift'
  'Sources/localvoxtral/DictationSessionController*.swift' # start, stop, realtime events, reconnect, spoken send
  'Sources/localvoxtral/StopCommitCoordinator*.swift'      # the stop-commit, in both modes
  'Sources/localvoxtral/SessionAudioPipeline*.swift'       # capture callback to the client
  'Sources/localvoxtral/MicrophoneCapturing.swift'
  'Sources/localvoxtral/MicrophoneCaptureService.swift'
  'Sources/localvoxtralCore/AudioChunkBuffer.swift'
  'Sources/localvoxtralCore/FirstChunkPreprocessor.swift'
  'Sources/localvoxtral/RealtimeClient.swift'
  'Sources/localvoxtral/*RealtimeWebSocketClient.swift'   # Base, RealtimeAPI, Mistral
  'Sources/localvoxtralCore/TranscriptAccumulator.swift'
  'Sources/localvoxtralCore/TextMergingAlgorithms.swift'
  'Sources/localvoxtral/TranscriptDiff.swift'
  'Sources/localvoxtral/LiveHoldBackReplacementStream.swift'
  'Sources/localvoxtral/LiveTerminalNewlineGuard.swift'
  'Sources/localvoxtral/TUIAutocompleteTrailingSpace.swift'
  'Sources/localvoxtral/TextInsertionService.swift'
  'Sources/localvoxtral/SystemAccessibilityFocus.swift'
  'Sources/localvoxtral/OverlayBufferSessionCoordinator.swift'
  'Sources/localvoxtral/OverlayBufferStateMachine.swift'
  'Sources/localvoxtralCore/OverlayBufferTextAssembler.swift'
  'Sources/localvoxtral/Dogfood/*'                         # the WAV source the check dictates from
  'scripts/e2e-dictation.sh'
  'scripts/e2e/*'
  'scripts/lib/word-accuracy.sh'
  'scripts/lib/launch-app.sh'
  '.github/workflows/ui-smoke.yml'
  'scripts/ci/e2e-dictation-filter.sh'
)

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <changed-files-file>" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern)
        echo "run=true"
        echo "reason=session path: $file"
        exit 0
        ;;
    esac
  done
done <"$CHANGED_FILES_FILE"

echo "run=false"
echo "reason=no session-path file changed; the e2e dictation check is not needed"
