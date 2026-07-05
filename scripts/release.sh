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

ARG="${1:-patch}"
REF="${2:-main}"

case "$ARG" in
  patch|minor|major)
    FIELD="bump"; VALUE="$ARG" ;;
  *)
    if [[ "$ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
      FIELD="version"; VALUE="$ARG"
    else
      echo "Usage: $0 [patch|minor|major|X.Y.Z|X.Y.Z-rc.N [ref]]" >&2
      exit 1
    fi
    ;;
esac

echo "Dispatching release ($FIELD=$VALUE, ref=$REF)..."
gh workflow run "Release App" --ref "$REF" -f "$FIELD=$VALUE"
sleep 5
RUN_ID="$(gh run list --workflow "Release App" --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "Watching run $RUN_ID (Ctrl+C detaches; the release continues remotely)"
gh run watch "$RUN_ID" --exit-status
if [[ "$FIELD" == "version" ]]; then
  echo "Done. Release page: https://github.com/T0mSIlver/localvoxtral/releases/tag/v$VALUE"
else
  echo "Done. Release page: https://github.com/T0mSIlver/localvoxtral/releases/latest"
fi
