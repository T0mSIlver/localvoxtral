#!/bin/bash
# Resolves the optional hand-written release notes for a tag.
#
# Usage:
#   scripts/ci/resolve-release-notes.sh <tag> [repo-root]
#
# stdout is $GITHUB_OUTPUT-shaped:
#   path=<repo-relative path, or empty when there are none>
#   reason=<one line, safe for a step summary>
#
# Convention: `docs/release-notes/<tag>.md`, e.g. docs/release-notes/v0.9.0.md.
# The tag is exactly what release.yml computes (`v` + X.Y.Z, or X.Y.Z-rc.N).
#
# Optional on purpose. A release with no such file still publishes with
# GitHub's generated notes, exactly as every release before this one did —
# the file only ever ADDS a human summary above that list. So a forgotten
# file is a duller release, never a failed one.
#
# The one hard failure is a file that exists but says nothing: an empty or
# whitespace-only notes file would hand the release action a body_path it can
# read and produce a release whose human section is blank, which looks like a
# bug in the pipeline rather than a missing file. Fail loudly instead.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <tag> [repo-root]" >&2
  exit 2
fi

TAG="$1"
ROOT_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The tag reaches this script from release.yml's own computation, but it lands
# in a filesystem path, so validate its shape rather than trusting it: only the
# grammar release.yml can produce is accepted, which also rules out `..` and
# any separator.
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
  echo "refusing to resolve notes for a tag that is not vX.Y.Z[-rc.N]: $TAG" >&2
  exit 2
fi

REL="docs/release-notes/$TAG.md"
ABS="$ROOT_DIR/$REL"

if [[ ! -e "$ABS" ]]; then
  echo "path="
  echo "reason=no $REL — publishing with generated notes only"
  exit 0
fi

if [[ ! -f "$ABS" ]]; then
  echo "$REL exists but is not a regular file" >&2
  exit 1
fi

if [[ -z "$(tr -d '[:space:]' <"$ABS")" ]]; then
  echo "$REL exists but is empty — write the notes or delete the file" >&2
  exit 1
fi

echo "path=$REL"
echo "reason=hand-written notes from $REL, with the generated changelog appended"
