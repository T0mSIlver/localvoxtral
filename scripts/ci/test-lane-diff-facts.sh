#!/bin/bash
# Pins scripts/ci/lane-diff-facts.sh against commits in a throwaway repo:
# which ci.yml and Package.swift edits it reports as unchanged for the Mac
# lanes, and that anything it cannot read reports as changed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FACTS="$ROOT_DIR/scripts/ci/lane-diff-facts.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-lane-diff-facts-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.github/workflows"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false

WORKFLOW_BASE='name: CI
on:
  pull_request:
jobs:
  build-test:
    runs-on: macos-latest
    steps:
      - name: Test
        run: swift test
  mac-lanes:
    runs-on: [self-hosted]
    steps:
      - name: Integration tests (live STT service)
        run: swift test --filter RealtimeAPIVLLMIntegrationTests
  linux:
    runs-on: ubuntu-24.04
    steps:
      - name: Shell suites
        run: ./scripts/ci/run-shell-suites.sh
'

MANIFEST_BASE='// swift-tools-version: 6.2
import PackageDescription
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    // The core.
    .target(name: "Core"),
]
dependencies.append(.package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"))
targets += [
    .executableTarget(
        name: "App",
        dependencies: ["Core"],
        swiftSettings: dogfoodSwiftSettings
    ),
]
let package = Package(
    name: "app",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: dependencies,
    targets: targets
)
'

commit() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q --allow-empty -m "$1"
  git -C "$REPO" rev-parse HEAD
}

printf '%s' "$WORKFLOW_BASE" >"$REPO/.github/workflows/ci.yml"
printf '%s' "$MANIFEST_BASE" >"$REPO/Package.swift"
BASE="$(commit base)"

# expect <fact> <true|false> <description> <perl-substitution> <file>
# Applies the substitution to <file> on top of BASE and reads the facts. Perl,
# not sed: BSD sed on the hosted Mac has no `\n` in a replacement.
expect() {
  local fact="$1" expected="$2" description="$3" expression="$4" file="$5" head output got
  git -C "$REPO" checkout -q "$BASE" -- .
  perl -0pi -e "$expression" "$REPO/$file"
  # A substitution that matched nothing would pass every "false" case.
  if git -C "$REPO" diff --quiet "$BASE" -- "$file"; then
    fail "$description: the edit changed nothing in $file"
  fi
  head="$(commit "$description")"
  output="$(cd "$REPO" && "$FACTS" "$BASE" "$head")" || fail "$description: exited non-zero"
  got="$(sed -n "s/^$fact=//p" <<<"$output")"
  [[ "$got" == "$expected" ]] || fail "$description: expected $fact=$expected, got '$got' ($output)"
  printf 'PASS: %s\n' "$description"
}

expect mac_lanes_job_changed false "an edit to build-test is outside the mac-lanes job" \
  's/run: swift test$/run: swift test --parallel/m' .github/workflows/ci.yml
expect mac_lanes_job_changed false "an edit to the job after mac-lanes is outside it" \
  's/ubuntu-24.04/ubuntu-26.04/' .github/workflows/ci.yml
expect mac_lanes_job_changed true "an edit to a mac-lanes step is inside it" \
  's/--filter RealtimeAPIVLLMIntegrationTests/--filter Other/' .github/workflows/ci.yml
expect mac_lanes_job_changed true "an edit to the file's triggers counts" \
  's/^  pull_request:/  pull_request:\n    types: [opened]/m' .github/workflows/ci.yml
expect mac_lanes_job_changed true "a renamed mac-lanes job cannot be read and counts" \
  's/^  mac-lanes:/  mac-jobs:/m' .github/workflows/ci.yml
expect mac_lanes_job_changed false "a manifest-only commit leaves the job unchanged" \
  's/The core\./The pure core./' Package.swift

expect package_deps_changed false "a reworded comment is no dependency change" \
  's/The core\./The pure core./' Package.swift
expect package_deps_changed false "a new target is no dependency change" \
  's/    \.target\(name: "Core"\),/    .target(name: "Core"),\n    .testTarget(name: "CoreTests", dependencies: ["Core"]),/' Package.swift
expect package_deps_changed false "a target's name or target dependencies are no dependency change" \
  's/dependencies: \["Core"\]/dependencies: ["Core", "Wire"]/' Package.swift
expect package_deps_changed true "a new version pin is a dependency change" \
  's/from: "3.4.0"/from: "3.5.0"/' Package.swift
# shellcheck disable=SC2016 # $1 is perl's capture group, not a shell variable
expect package_deps_changed true "a pin on a line of its own is a dependency change" \
  's|\.package\(url: "(\S+)", from: "3\.4\.0"\)|.package(\n    url: "$1",\n    exact: "3.4.1"\n)|' Package.swift
expect package_deps_changed true "a platform change counts" \
  's/\.macOS\(\.v15\)/.macOS(.v26)/' Package.swift
expect package_deps_changed true "a build setting counts" \
  's/swiftSettings: dogfoodSwiftSettings/swiftSettings: [.unsafeFlags(["-Ounchecked"])]/' Package.swift
expect package_deps_changed true "the tools version counts" \
  's/swift-tools-version: 6.2/swift-tools-version: 6.3/' Package.swift

# Anything unreadable reports changed.
output="$(cd "$REPO" && "$FACTS" 0000000000000000000000000000000000000000 "$BASE")" \
  || fail "an unknown base exited non-zero"
[[ "$output" == $'mac_lanes_job_changed=true\npackage_deps_changed=true' ]] \
  || fail "an unknown base must report both facts changed, got: $output"
echo "PASS: an unknown base reports both facts changed"

git -C "$REPO" checkout -q "$BASE" -- .
git -C "$REPO" rm -qf .github/workflows/ci.yml Package.swift
GONE="$(commit gone)"
output="$(cd "$REPO" && "$FACTS" "$BASE" "$GONE")" || fail "a deleted file exited non-zero"
[[ "$output" == $'mac_lanes_job_changed=true\npackage_deps_changed=true' ]] \
  || fail "a file missing on one side must report changed, got: $output"
echo "PASS: a file missing on one side reports changed"

# The real workflow must keep the landmarks the reader looks for.
grep -q '^jobs:[[:space:]]*$' "$ROOT_DIR/.github/workflows/ci.yml" || fail "ci.yml has no top-level jobs: line"
grep -q '^  mac-lanes:[[:space:]]*$' "$ROOT_DIR/.github/workflows/ci.yml" || fail "ci.yml has no mac-lanes job at two-space indent"
echo "PASS: ci.yml still has the landmarks the reader slices on"

if "$FACTS" >/dev/null 2>&1; then fail "a missing argument was accepted"; fi
echo "OK: lane-diff-facts tests passed"
