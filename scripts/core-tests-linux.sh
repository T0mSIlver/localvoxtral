#!/usr/bin/env bash
# Builds and runs the localvoxtralCore tests on Linux (#432 step 9): the
# Foundation-only core, with no Mac. It also builds the Claude hook publisher,
# which runs on remote Linux hosts, and runs its tests. The app and its suite
# need AppKit and are not in the package on Linux, so the test product is
# built alone.
#
#   ./scripts/core-tests-linux.sh                       # every core test
#   ./scripts/core-tests-linux.sh --filter TranscriptAccumulatorTests
#
# SWIFT names the toolchain (default: `swift` on PATH, Swift 6.2).
# LV_LINUX_SCRATCH is the build directory (default: .build/linux).
set -euo pipefail

cd "$(dirname "$0")/.."
SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"

# The package has no dependencies on Linux, so SwiftPM deletes Package.resolved
# there. The Mac build syncs this tree, and would then resolve ShortcutRecorder
# afresh: put the pins back whatever happens.
resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
# `cat`, not `cp`: the backup is mktemp's 0600, and the restored file keeps
# the mode it would have been created with.
trap 'cat "$resolved_backup" >Package.resolved; rm -f "$resolved_backup"' EXIT

"$SWIFT" build --scratch-path "$SCRATCH" --product localvoxtral-claude-hook
"$SWIFT" build --scratch-path "$SCRATCH" --product localvoxtralPackageTests
"$SWIFT" test --skip-build --scratch-path "$SCRATCH" "$@"
