#!/bin/bash
# Pins scripts/ci/mac-package-filter.sh: which diffs skip packaging and
# launch-smoking the signed bundle on the owner's Mac, and that everything
# unclassified, every lane that reads the bundle, and every event but a pull
# request still package.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/mac-package-filter.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-mac-package-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> [--event <name>] [--marker <text>] [--env NAME=VALUE] <changed-path>...
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" marker_file="" event="pull_request"
  local -a env_args=()
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env_args+=("$2"); shift 2 ;;
      --marker) marker_file="$TMP_DIR/marker"; printf '%s\n' "$2" >"$marker_file"; shift 2 ;;
      --event) event="$2"; shift 2 ;;
      *) printf '%s\n' "$1" >>"$changed"; shift ;;
    esac
  done
  local output run reason
  output="$(env -u LANE_NEEDS_BUNDLE -u LANE_MAC_LANES_JOB_CHANGED ${env_args[@]+"${env_args[@]}"} \
    "$FILTER" "$changed" "$event" "$marker_file")" || fail "$description: filter exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# What goes into the bundle, or runs in the packaging and smoke steps.
expect true "an app source packages" Sources/localvoxtral/SettingsView.swift
expect true "a bundled prompt packages" Sources/localvoxtral/Resources/Config/llm_polish.toml
expect true "a markdown file under Sources packages" Sources/localvoxtral/Resources/Notes.md
expect true "the manifest packages, even a target-only edit" Package.swift
expect true "the lockfile packages" Package.resolved
expect true "a PolishHelper source packages" PolishHelper/Sources/PolishHelperCore/PolishdRouter.swift
expect true "a SpeechHelper manifest packages" SpeechHelper/Package.swift
expect true "an icon packages" assets/icons/app/AppIcon.png
expect true "the shipped Claude Code plugin packages, docs included" integrations/claude-code/README.md
expect true "the opencode plugin packages" integrations/opencode/localvoxtral.js
expect true "package_app.sh packages" scripts/package_app.sh
expect true "what cleans dist/ before packaging packages" scripts/ci/clean-stale-outputs.sh
expect true "this filter's own edit packages" scripts/ci/mac-package-filter.sh
expect true "a ci.yml edit packages when no fact was read" .github/workflows/ci.yml
expect true "a ci.yml edit inside the mac-lanes job packages" \
  --env LANE_MAC_LANES_JOB_CHANGED=true .github/workflows/ci.yml
expect true "a garbled ci.yml fact fails open" \
  --env LANE_MAC_LANES_JOB_CHANGED=maybe .github/workflows/ci.yml
expect true "a path nobody classified packages" Makefile
expect true "one packaging input among skippable paths packages" \
  Tests/localvoxtralTests/SettingsViewTests.swift docs/architecture.md Sources/localvoxtral/SettingsView.swift

# What cannot change the bundle.
expect false "a test-only diff does not" \
  Tests/localvoxtralTests/SettingsViewTests.swift Tests/localvoxtralCoreTests/PolishTokenGuardTests.swift
expect false "a helper's unit tests do not" \
  PolishHelper/Tests/PolishHelperCoreTests/PolishdRouterTests.swift \
  SpeechHelper/Tests/SpeechHelperCoreTests/DeltaTests.swift
expect false "a CI script does not" scripts/ci/stt-lane-filter.sh scripts/ci/test-stt-lane-filter.sh
expect false "a dev script does not" scripts/remote-build.sh scripts/try-pr.sh
expect false "another workflow does not" .github/workflows/ui-smoke.yml .github/workflows/README.md
expect false "a ci.yml edit outside the mac-lanes job does not" \
  --env LANE_MAC_LANES_JOB_CHANGED=false .github/workflows/ci.yml scripts/ci/test-dogfood-filter.sh
expect false "docs and eval data do not" \
  docs/agent/test-tiers.md AGENTS.md EvalCorpus/agent-dictation/cases.jsonl

# What else asks for the bundle.
expect true "a lane that reads the bundle packages a test-only diff" \
  --env "LANE_NEEDS_BUNDLE=polishd" Tests/localvoxtralTests/PolishHelperIntegrationTests.swift
expect true "two such lanes package" \
  --env "LANE_NEEDS_BUNDLE=polishd speechd" docs/architecture.md
expect false "a blank lane list asks for nothing" \
  --env "LANE_NEEDS_BUNDLE= " docs/architecture.md
expect true "[mac-lanes] packages whatever the diff" \
  --marker "needs try-pr [mac-lanes]" docs/architecture.md
expect false "a lane marker alone does not" \
  --marker "[run-herdr-integration]" Tests/localvoxtralTests/HerdrIntegrationTests.swift

# Events and fail-open.
expect true "a dispatch always packages" --event workflow_dispatch docs/architecture.md
expect true "a push always packages" --event push docs/architecture.md
expect true "an unknown event packages" --event merge_group docs/architecture.md
expect true "an empty changed-file list packages (fail open)"

if "$FILTER" >/dev/null 2>&1; then fail "a missing argument was accepted"; fi
if "$FILTER" "$TMP_DIR/does-not-exist" >/dev/null 2>&1; then fail "a missing file was accepted"; fi
echo "OK: mac-package-filter tests passed"
