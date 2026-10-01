#!/bin/bash
# Regression test for check-commit-attribution.sh, on a throwaway repository.
# Pins: the trailers seen on main before its 2026-10-01 rewrite fail (both
# spellings of Co-authored-by, Claude-Session); a human co-author, prose that
# mentions Claude Code, and a commit Claude authored but whose message credits
# no one pass (the squash merge, not the author field, is what reaches main).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECK="$ROOT_DIR/scripts/ci/check-commit-attribution.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-commit-attribution-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cd "$TMP_DIR"
git init -q
export GIT_AUTHOR_NAME=Tom GIT_AUTHOR_EMAIL=tom@example.com
export GIT_COMMITTER_NAME=Tom GIT_COMMITTER_EMAIL=tom@example.com
git commit -q --allow-empty -m base
base="$(git rev-parse HEAD)"

# expect <0|1> <description> <commit message> [author email]
expect() {
  local expected="$1" description="$2" message="$3" email="${4:-tom@example.com}"
  git reset -q --hard "$base"
  GIT_AUTHOR_EMAIL="$email" git commit -q --allow-empty -m "$message"
  local status=0
  "$CHECK" "$base..HEAD" >"$TMP_DIR/out" 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || fail "$description: exit $status, expected $expected: $(cat "$TMP_DIR/out")"
  printf 'PASS: %s\n' "$description"
}

expect 1 "Co-Authored-By naming Claude fails" \
  $'Fix\n\nCo-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>'
expect 1 "GitHub's squash spelling fails" \
  $'Fix\n\n* step\n\nCo-authored-by: Claude <noreply@anthropic.com>'
expect 1 "Claude-Session fails" \
  $'Fix\n\nClaude-Session: https://claude.ai/code/session_01abc'
expect 0 "a human co-author passes" \
  $'Fix\n\nCo-authored-by: Ada <ada@example.com>'
expect 0 "prose about Claude Code passes" \
  $'Doctor finds running Claude Code sessions\n\nThe claude-session scene and anthropic docs.'
expect 0 "an anthropic.com author with a clean message passes" "Fix" "noreply@anthropic.com"

git reset -q --hard "$base"
"$CHECK" "$base..HEAD" >/dev/null || fail "an empty range fails"
printf 'PASS: an empty range passes\n'
