#!/usr/bin/env bash
# The repository the remote shims send as X-Lvx-Env-Repository (#926, #971):
# hooks/repository.sh prints what the checkout's `origin` names, owner/name
# for github.com and host/path for any other host, and nothing for no origin,
# a local path or a URL it cannot read. The Mac merges a repository's
# checkouts into one project by it (ProjectRemote reads the same shapes).
#
# Needs git, no network:
#   ./scripts/ci/test-remote-shim-repository.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/repository.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-repository-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$TMP_DIR/repo"

# expect <origin url or "-" for none> <printed value>
expect() {
  git -C "$TMP_DIR/repo" remote remove origin 2>/dev/null || :
  [ "$1" = - ] || git -C "$TMP_DIR/repo" remote add origin "$1"
  local got stderr
  got="$(cd "$TMP_DIR/repo" && sh "$SCRIPT" 2>"$TMP_DIR/stderr")" || fail "$1: exit status $?"
  stderr="$(cat "$TMP_DIR/stderr")"
  [ -z "$stderr" ] || fail "$1: wrote to stderr: $stderr"
  [ "$got" = "$2" ] || fail "origin $1: printed '$got', wanted '$2'"
}

expect https://github.com/me/quill.git me/quill
expect git@github.com:me/quill.git me/quill
expect ssh://git@github.com:22/me/quill me/quill
expect https://gitlab.com/me/group/quill.git gitlab.com/me/group/quill
expect ssh://git@git.example.com:2222/me/quill.git git.example.com/me/quill
expect git@git.example.com:me/quill git.example.com/me/quill
pass "GitHub origins print owner/name, other hosts print host/path"

expect - ""
expect /srv/git/quill.git ""
expect ../quill ""
expect 'https://github.com/me/quill; touch hacked' ""
[ ! -e "$TMP_DIR/repo/hacked" ] || fail "an origin ran a command"
pass "no origin, a local path and a hostile URL print nothing"

echo "remote shim repository: all checks passed"
