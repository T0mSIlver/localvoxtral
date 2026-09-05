#!/bin/bash
# Decides whether CI's live-herdr integration lane must run for a given
# change. Kept standalone so the workflow decision is testable locally.
#
# Usage:
#   scripts/ci/herdr-lane-filter.sh <changed-files-file> [marker-text-file]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [marker-text-file]    optional free text (PR body + head commit message);
#                         if it contains [run-herdr-integration], the lane
#                         runs regardless of the diff
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
set -euo pipefail

MARKER='[run-herdr-integration]'

# The lane proves EXTERNAL assumptions about a live herdr server and a real
# ssh forward. A path belongs here when changing it can alter what the app
# sends herdr, what it believes herdr answered, how the forward to herdr is
# opened or leased, which host that forward reaches, or the trust argument
# those assumptions support.
#
# Deliberately NOT here: everything else in the Claude context path that never
# talks to herdr (repo collection, prompt blocks, insertion). Those are
# covered by the tier-0 unit suite; adding them would make a live-service lane
# run on ordinary UI work.
PATTERNS=(
  '*HerdrSocketClient*'                              # the wire client: every request/response shape
  '*HerdrPanelBindingProbe*'                         # the nonce stamp, settle loop, and mic indicator
  '*HerdrClientTTYProbe*'                            # which surface is bound to a herdr client at all
  '*ClaudeRemoteHerdrForward*'                       # the ssh -L forward, its argv, leases and teardown
  '*ClaudeRemoteForwardSupervisor*'                  # the process supervision under that forward
  '*ClaudeRemoteForwardCoordinator*'                 # which hosts get a forward, and in what order
  '*SSHDestinationCanonicalizer*'                    # ssh -G identity matching for the destination
  '*SSHDestinationTTYProbe*'                         # the argv fallback the panel binding falls through to
  '*ClaudeRemoteEnrollmentService*'                  # the remote herdr config patch + its refusal rules
  '*SocketPaneScreenContext*'                        # what a herdr join is allowed to read back
  '*TerminalScreenClaudeJoin*'                       # the arm that consumes all of the above
  'docs/agent/remote-herdr-panel-binding.md'         # the assumptions this lane exists to pin
  'scripts/herdr-integration-fixture.sh'             # the fixture itself
  'scripts/ci/herdr-lane-filter.sh'
  '*HerdrIntegration*'                               # the lane's own suite and support
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
MARKER_TEXT_FILE="${2:-}"

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

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
# "and push": the marker is only read from the event payload at run-creation
# time — editing the PR body after a skipped run creates no new run, and
# reruns reuse the original payload, so a late-added marker needs a push.
echo "reason=no herdr-relevant changes; add $MARKER to the PR body or commit message and push to opt in"
