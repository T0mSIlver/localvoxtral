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
#   ./scripts/release.sh --dry-run ...        # check, print what would be
#                                             # dispatched, dispatch nothing
#
# A stable release (every form but nightly and rehearse) needs the e2e
# dictation check to have passed on the release commit. That check
# (scripts/e2e-dictation.sh) is the only one where the packaged app dictates
# into another app's window; it holds the owner's Mac and keyboard, so it
# runs here, when the owner is at the Mac, rather than on every PR (#574).
# Run it with the Mac unlocked:
#   gh workflow run ui-smoke.yml --ref <ref>
# The evening UI Smoke runs on main count too, while main has not moved.
#
# The channels: stable follows GitHub's /releases/latest and is cut by hand
# when the owner decides; nightly is a prerelease of main that never touches
# that pointer. Same pipeline, same gates.

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

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
      echo "Usage: $0 [--dry-run] [patch|minor|major|X.Y.Z|X.Y.Z-rc.N [ref]|nightly] | $0 [--dry-run] rehearse [patch|minor|major|X.Y.Z|X.Y.Z-rc.N|nightly] [ref]" >&2
      exit 1
    fi
    ;;
esac
DISPATCH_ARGS+=(-f "publish=$PUBLISH")

if [[ "$ARG" == "nightly" && "$PUBLISH" == "true" && "$REF" != "main" ]]; then
  echo "Nightly releases publish from main only. Use 'rehearse nightly $REF' to exercise the pipeline from that ref." >&2
  exit 1
fi

# Must match the step name in ui-smoke.yml, as scripts/ci/ui-smoke-guard.sh
# does: the step runs only when every scenario was scored and passed. The
# dictation step itself also concludes success when the Mac could not run it.
E2E_STEP="E2E dictation scored"

GATE_E2E=false
if [[ "$PUBLISH" == "true" && "$ARG" != "nightly" ]]; then
  GATE_E2E=true
fi
RELEASE_SHA=""
if $GATE_E2E; then
  # Encoded: a branch name may hold '#', '&' or '?'.
  ref_uri="$(jq -rn --arg r "$REF" '$r | @uri')"
  RELEASE_SHA="$(gh api "repos/{owner}/{repo}/commits/$ref_uri" --jq '.sha')"
  runs="$(gh api "repos/{owner}/{repo}/actions/workflows/ui-smoke.yml/runs?head_sha=$RELEASE_SHA&status=completed&per_page=100" \
    --jq '.workflow_runs[].id')"
  scored_run=""
  for id in $runs; do
    conclusion="$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" \
      --jq "[.jobs[].steps[] | select(.name == \"$E2E_STEP\") | .conclusion] | first // empty")"
    if [[ "$conclusion" == "success" ]]; then
      scored_run="$id"
      break
    fi
  done
  if [[ -z "$scored_run" ]]; then
    echo "Refused: the e2e dictation check has not passed on $REF at ${RELEASE_SHA:0:9}." >&2
    echo "Run it with the Mac unlocked, then release again:" >&2
    echo "  gh workflow run ui-smoke.yml --ref $REF" >&2
    exit 1
  fi
  echo "e2e dictation check: passed on ${RELEASE_SHA:0:9} in UI Smoke run $scored_run"
else
  echo "e2e dictation check: not required for a nightly or a rehearsal"
fi

if $DRY_RUN; then
  echo "Dry run: would dispatch Release App ($ARG, ref=$REF, publish=$PUBLISH)"
  exit 0
fi

if [[ "$PUBLISH" == "true" ]]; then
  echo "Dispatching release ($ARG, ref=$REF)..."
else
  echo "Dispatching release REHEARSAL ($ARG, ref=$REF) — no tag, no release..."
fi
# Our run is the one on this ref that was not there before the dispatch: the
# newest run can be the 03:15 cron's or an earlier dispatch's while ours has
# not registered yet.
list_runs() {
  gh run list --workflow "Release App" --branch "$REF" --limit 20 --json databaseId --jq '.[].databaseId'
}
RUNS_BEFORE="$(list_runs)"
gh workflow run "Release App" --ref "$REF" "${DISPATCH_ARGS[@]}"
RUN_ID=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 5
  RUN_ID="$(list_runs | grep -vxF -f <(printf '%s\n' "$RUNS_BEFORE") | head -n 1 || true)"
  [[ -n "$RUN_ID" ]] && break
done
if [[ -z "$RUN_ID" ]]; then
  echo "Dispatched, but no new Release App run on $REF appeared within a minute. Find it with:" >&2
  echo "  gh run list --workflow 'Release App' --branch $REF" >&2
  exit 1
fi
if $GATE_E2E; then
  # The ref may have moved between the check and the dispatch. The workflow
  # gates for minutes before it tags, so cancelling now leaves no tag.
  run_sha="$(gh run view "$RUN_ID" --json headSha --jq '.headSha')"
  if [[ "$run_sha" != "$RELEASE_SHA" ]]; then
    echo "Refused: $REF moved to ${run_sha:0:9} after the e2e dictation check passed on ${RELEASE_SHA:0:9}." >&2
    if gh run cancel "$RUN_ID"; then
      echo "Cancelled run $RUN_ID before it tagged anything. Run the check on the new head, then release again." >&2
    else
      echo "Could not cancel run $RUN_ID; cancel it by hand before it tags: gh run cancel $RUN_ID" >&2
    fi
    exit 1
  fi
fi
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
