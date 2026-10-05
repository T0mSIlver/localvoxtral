#!/usr/bin/env bash
# People read the docs on the site, agents read the Markdown. This runs
# scripts/docs-site/check-human-links.py on the repo, then on a fixture repo
# to show what it refuses and what it leaves alone. The docs-site workflow
# runs the same script against the built site, which also checks anchors.
#   ./scripts/ci/test-human-doc-links.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT_DIR/scripts/docs-site/check-human-links.py"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

python3 "$CHECK" || fail "the repo links a docs page as Markdown from a human-facing file (above)"
echo "PASS: no human-facing file links a docs page as Markdown"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/docs/agent" "$FIX/integrations/foo" "$FIX/Sources/App"
echo "# Guide" >"$FIX/docs/guide.md"
echo "# Agent notes" >"$FIX/docs/agent/notes.md"
cat >"$FIX/README.md" <<'EOF'
[relative](docs/guide.md#a) and [agent notes](docs/agent/notes.md)
<a href="docs/guide.md">html</a>
[site](https://t0msilver.github.io/localvoxtral/docs/guide/)
EOF
cat >"$FIX/integrations/foo/README.md" <<'EOF'
[blob](https://github.com/T0mSIlver/localvoxtral/blob/main/docs/guide.md)
EOF
cat >"$FIX/Sources/App/Doctor.swift" <<'EOF'
// Agents: see docs/guide.md.
let fix = "see docs/guide.md"
let ok = "README.md"
EOF
# Not a human-facing surface: agents follow its Markdown paths.
echo "[guide](docs/guide.md)" >"$FIX/AGENTS.md"

set +e
OUT="$(python3 "$CHECK" --repo "$FIX")"
STATUS=$?
set -e
(( STATUS == 1 )) || fail "fixture: exit $STATUS, want 1; output: $OUT"
expect() { grep -qF -- "$1" <<<"$OUT" || fail "fixture: no '$1' in: $OUT"; }
refuse() { ! grep -qF -- "$1" <<<"$OUT" || fail "fixture: flagged '$1': $OUT"; }
expect "FAIL README.md: links docs/guide.md#a;"
expect "FAIL README.md: links docs/guide.md;"
expect "FAIL integrations/foo/README.md: links https://github.com/T0mSIlver/localvoxtral/blob/main/docs/guide.md;"
expect "FAIL Sources/App/Doctor.swift: names docs/guide.md;"
expect ", 4 failures"
refuse "AGENTS.md"
refuse "agent/notes.md"
refuse "localvoxtral/docs/guide/"
echo "PASS: repo paths and github.com links to docs pages fail; agent files, comments and site links pass"
