#!/usr/bin/env bash
set -euo pipefail

# One-command release from any machine with gh. Dispatches the Release App
# workflow, which gates (build, unit tests, live integration, packaging,
# launch smoke) on the self-hosted Mac runner and only then tags, builds the
# DMG/zip, and publishes the GitHub release. A failed release leaves no tag.
#
# Usage:
#   ./scripts/release.sh                      # patch bump (v0.6.1 -> v0.6.2)
#   ./scripts/release.sh minor                # v0.6.1 -> v0.7.0
#   ./scripts/release.sh major                # v0.6.1 -> v1.0.0
#   ./scripts/release.sh 1.2.3                # explicit version
#   ./scripts/release.sh 1.2.3-rc.1 <branch>  # prerelease from a branch,
#                                             # installable for hand-testing
#                                             # before the branch merges
#   ./scripts/release.sh nightly              # a nightly prerelease of main,
#                                             # on demand (the cron does this
#                                             # every night at 03:15 UTC)
#   ./scripts/release.sh rehearse [target] [ref]
#                                             # every gate, no tag, no
#                                             # release: the artifacts land on
#                                             # the run instead. Any ref.
#                                             # target defaults to patch and
#                                             # may be nightly.
#
# The channels: stable follows GitHub's /releases/latest and is cut by hand
# when the owner decides; nightly is a prerelease of main that never touches
# that pointer. Same pipeline, same gates.

PUBLISH=true
if [[ "${1:-}" == "rehearse" ]]; then
  PUBLISH=false
  shift
fi

ARG="${1:-patch}"
REF="${2:-main}"

DISPATCH_ARGS=()
case "$ARG" in
  nightly)
    DISPATCH_ARGS=(-f channel=nightly) ;;
  patch|minor|major)
    DISPATCH_ARGS=(-f channel=stable -f "bump=$ARG") ;;
  *)
    if [[ "$ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
      DISPATCH_ARGS=(-f channel=stable -f "version=$ARG")
    else
      echo "Usage: $0 [patch|minor|major|X.Y.Z|X.Y.Z-rc.N [ref]|nightly] | $0 rehearse [patch|minor|major|X.Y.Z|X.Y.Z-rc.N|nightly] [ref]" >&2
      exit 1
    fi
    ;;
esac
DISPATCH_ARGS+=(-f "publish=$PUBLISH")

if [[ "$ARG" == "nightly" && "$PUBLISH" == "true" && "$REF" != "main" ]]; then
  echo "Nightly releases publish from main only. Use 'rehearse nightly $REF' to exercise the pipeline from that ref." >&2
  exit 1
fi

if [[ "$PUBLISH" == "true" ]]; then
  echo "Dispatching release ($ARG, ref=$REF)..."
else
  echo "Dispatching release REHEARSAL ($ARG, ref=$REF) — no tag, no release..."
fi
gh workflow run "Release App" --ref "$REF" "${DISPATCH_ARGS[@]}"
sleep 5
# Newest run on the dispatched ref, not the newest run of the workflow: the
# 03:15 cron or another dispatch can create a run inside that 5 s window.
RUN_ID="$(gh run list --workflow "Release App" --branch "$REF" --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "Watching run $RUN_ID (Ctrl+C detaches; the release continues remotely)"
gh run watch "$RUN_ID" --exit-status
if [[ "$PUBLISH" != "true" ]]; then
  echo "Rehearsal done. Artifacts: https://github.com/T0mSIlver/localvoxtral/actions/runs/$RUN_ID"
elif [[ "$ARG" == "nightly" ]]; then
  echo "Done. Nightly: https://github.com/T0mSIlver/localvoxtral/releases"
elif [[ "$ARG" =~ ^[0-9] ]]; then
  echo "Done. Release page: https://github.com/T0mSIlver/localvoxtral/releases/tag/v$ARG"
else
  echo "Done. Release page: https://github.com/T0mSIlver/localvoxtral/releases/latest"
fi
