#!/bin/bash
# Decides whether the mac-lanes job must package the signed app bundle, upload
# it and launch-smoke it for a given change. That is about 95 s of the owner's
# Mac per run (package_app.sh ~65 s, the zips and uploads ~28 s, the smoke).
#
# Usage:
#   scripts/ci/mac-package-filter.sh <changed-files-file> [event-name] [marker-text-file]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [event-name]          $GITHUB_EVENT_NAME; absent means "decide on paths
#                         alone" (what the tests do)
#   [marker-text-file]    optional free text (PR body + head commit message);
#                         the literal [mac-lanes] packages whatever the diff,
#                         since a draft carries it to get the signed bundle
#
# Two env vars say what else the run needs:
#   LANE_NEEDS_BUNDLE   space-separated names of the lanes this run will run
#                       that read the packaged bundle (the polishd and speechd
#                       integrations, the dogfood pass); non-empty packages
#   LANE_MAC_LANES_JOB_CHANGED=false   from scripts/ci/lane-diff-facts.sh:
#                       ci.yml changed outside the mac-lanes job, so not the
#                       packaging or smoke steps; only the literal "false"
#                       narrows
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
#
# The bundle is built from the root package's sources and manifest, the two
# helper packages' sources and manifests, the icons, the integrations it
# ships, and package_app.sh; clean-stale-outputs.sh decides what of dist/
# survives into the step. A diff can skip packaging only when EVERY path is
# on the SKIPPABLE list below: tests, docs, CI scripts, other workflows, the
# eval data. Anything else, including a path nobody classified, packages, so
# a new input can only cost Mac time, never ship an unsmoked bundle. build-test
# still packages and launch-smokes a bundle for fork PRs only, and the nightly
# release packages main every night.
set -euo pipefail

MARKER='[mac-lanes]'

# Paths that change nothing in the bundle and nothing the packaging or smoke
# steps run. Checked AFTER the must-package arms in is_skippable below, so a
# helper's sources or a shipped integration never reach these globs.
SKIPPABLE=(
  'Tests/*'
  'docs/*'
  'local-notes/*'
  'EvalCorpus/*'
  'EvalRecordings/*'
  'scripts/*'
  '.github/*'
  '*.md'
  'LICENSE'
  '.gitignore'
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
  *)
    echo "run=true"
    echo "reason=event '$EVENT_NAME' is not gated"
    exit 0
    ;;
esac

if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]] \
    && grep -qF "$MARKER" "$MARKER_TEXT_FILE"; then
  echo "run=true"
  echo "reason=explicit $MARKER marker"
  exit 0
fi

NEEDS_BUNDLE="${LANE_NEEDS_BUNDLE:-}"
if [[ -n "${NEEDS_BUNDLE// /}" ]]; then
  echo "run=true"
  echo "reason=the bundle feeds a lane this run runs: ${NEEDS_BUNDLE}"
  exit 0
fi

REJECTION=""
is_skippable() {
  local path="$1" pattern
  case "$path" in
    PolishHelper/Tests/* | SpeechHelper/Tests/*)
      return 0
      ;;
    Sources/* | PolishHelper/* | SpeechHelper/* | Package.* | assets/* | integrations/* \
      | scripts/package_app.sh | scripts/ci/mac-package-filter.sh \
      | scripts/ci/clean-stale-outputs.sh)
      REJECTION="packaging input: $path"
      return 1
      ;;
    .github/workflows/ci.yml)
      if [[ "${LANE_MAC_LANES_JOB_CHANGED:-}" == "false" ]]; then
        return 0
      fi
      REJECTION="the mac-lanes job may have changed: $path"
      return 1
      ;;
  esac
  for pattern in "${SKIPPABLE[@]}"; do
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) return 0 ;;
    esac
  done
  REJECTION="path is not known to be outside the bundle: $path"
  return 1
}

count=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  count=$((count + 1))
  if ! is_skippable "$file"; then
    echo "run=true"
    echo "reason=$REJECTION"
    exit 0
  fi
done <"$CHANGED_FILES_FILE"

if [[ "$count" -eq 0 ]]; then
  echo "run=true"
  echo "reason=empty changed-file list — failing open"
  exit 0
fi

echo "run=false"
echo "reason=none of $count changed path(s) goes into the bundle (tests, docs, CI scripts, other workflows, eval data); add $MARKER to the PR body and push to package anyway"
