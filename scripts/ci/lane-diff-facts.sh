#!/bin/bash
# Reads two facts about a diff that a changed-file list cannot carry, for the
# lane filters that would otherwise run on any edit to the file:
#
#   mac_lanes_job_changed   whether .github/workflows/ci.yml changed in the
#                           part the Mac runs: the `mac-lanes` job, or the
#                           file's head before `jobs:` (triggers, concurrency,
#                           env, permissions). Most ci.yml edits touch only
#                           build-test, linux or dogfood.
#   package_deps_changed    whether the root Package.swift changed a line that
#                           can declare a dependency or its pin, the tools
#                           version, the platforms or a build setting. Moving
#                           files between targets or adding a test target
#                           changes none of those.
#
# Usage:
#   scripts/ci/lane-diff-facts.sh <base-commit> <head-commit>
#
# stdout is $GITHUB_OUTPUT-shaped, one line per fact, each true|false. Every
# failure (a missing commit, a file absent on one side, a ci.yml whose
# mac-lanes job this script cannot find) prints true: a fact that cannot be
# read must never skip a lane. Exits non-zero only on usage errors.
set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-commit> <head-commit>" >&2
  exit 2
fi

BASE="$1"
HEAD="$2"

WORKFLOW='.github/workflows/ci.yml'
MANIFEST='Package.swift'

# The file's head plus the mac-lanes job, up to the next job at the same
# indent. Prints nothing when either landmark is missing, which the caller
# reads as "cannot tell".
mac_lanes_slice() {
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; saw_jobs = 1; next }
    !in_jobs { print; next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 ~ /^  mac-lanes:/); if (in_job) saw_job = 1 }
    in_job { print }
    END { if (!saw_jobs || !saw_job) exit 1 }
  '
}

# Lines that can declare a package dependency or its version, the tools
# version, the platforms, or a compile or link setting. Comments go first
# (a `//` at the start of a line or after whitespace, so a URL's `://` stays;
# the `// swift-tools-version:` line is kept, being a comment only in form),
# whitespace is trimmed and the lines sorted, so a reworded comment, a
# reindent or a reorder is no change.
manifest_dependency_lines() {
  sed -E -e '/swift-tools-version/b' -e 's#^[[:space:]]*//.*$##' -e 's#[[:space:]]+//.*$##' \
    | { grep -E 'swift-tools-version|\.package\(|url:|from:|exact:|revision:|branch:|upToNext|path:|platforms|\.macOS\(|[sS]wiftSettings|unsafeFlags|Feature\(|swiftLanguage|\.define\(|[cC]Settings|[cC]xxSettings|linkerSettings|\.linked' || true; } \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | LC_ALL=C sort
}

# Echoes true when the named slice of $1 differs between the two commits.
slice_changed() {
  local path="$1" filter="$2" before after
  before="$(git show "$BASE:$path" 2>/dev/null)" || { echo true; return; }
  after="$(git show "$HEAD:$path" 2>/dev/null)" || { echo true; return; }
  before="$($filter <<<"$before")" || { echo true; return; }
  after="$($filter <<<"$after")" || { echo true; return; }
  if [[ "$before" == "$after" ]]; then
    echo false
  else
    echo true
  fi
}

echo "mac_lanes_job_changed=$(slice_changed "$WORKFLOW" mac_lanes_slice)"
echo "package_deps_changed=$(slice_changed "$MANIFEST" manifest_dependency_lines)"
