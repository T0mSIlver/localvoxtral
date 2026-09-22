#!/usr/bin/env bash
# Regression test for restore-mtimes.sh.
#
# Builds a small git history with known commit times, stamps every file with
# "now" the way a fresh checkout does, runs the script and checks that each
# tracked file carries the time of the last commit that touched it, that a
# rename counts as a touch, and that untracked files are left alone.
#
# Needs git and perl, no network: ./scripts/ci/test-restore-mtimes.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RESTORE="$ROOT_DIR/scripts/ci/restore-mtimes.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-restore-mtimes-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

mtime() { perl -e 'print((stat $ARGV[0])[9])' "$1"; }

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git config user.name t
git config user.email t@example.com
git config commit.gpgsign false

# commit <epoch> <message>: everything staged, with both dates pinned.
commit() {
  GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" \
    git commit -q -m "$2"
}

T1=1600000000
T2=1600100000
T3=1600200000
T4=1600300000

mkdir -p "dir with space"
echo one >a.txt
echo one >"dir with space/b.txt"
echo one >renamed-from.txt
git add -A
commit "$T1" "first: a, b, renamed-from"

echo two >a.txt
git add -A
commit "$T2" "second: a changes"

git mv renamed-from.txt renamed-to.txt
commit "$T3" "third: rename"

echo three >c.txt
git add -A
commit "$T4" "fourth: c appears"

echo scratch >untracked.txt

NOW="$(mtime a.txt)"
touch a.txt "dir with space/b.txt" renamed-to.txt c.txt untracked.txt
UNTRACKED_BEFORE="$(mtime untracked.txt)"

OUT="$("$RESTORE" "$REPO")" || fail "script exited non-zero"
[[ "$OUT" == "restore-mtimes: set 4 of 4 tracked files" ]] \
  || fail "unexpected summary line: '$OUT'"
pass "reports every tracked file as set"

[[ "$(mtime a.txt)" == "$T2" ]] \
  || fail "a.txt should carry its LAST commit time $T2, got $(mtime a.txt)"
pass "a file changed twice carries the later commit's time"

[[ "$(mtime "dir with space/b.txt")" == "$T1" ]] \
  || fail "b.txt should carry $T1, got $(mtime "dir with space/b.txt")"
pass "an untouched file keeps its first commit's time, path with a space"

[[ "$(mtime renamed-to.txt)" == "$T3" ]] \
  || fail "renamed-to.txt should carry the rename's time $T3, got $(mtime renamed-to.txt)"
pass "a rename counts as a touch of the new path"

[[ "$(mtime c.txt)" == "$T4" ]] \
  || fail "c.txt should carry $T4, got $(mtime c.txt)"
pass "a file added late carries its own commit's time"

[[ "$(mtime untracked.txt)" == "$UNTRACKED_BEFORE" ]] \
  || fail "untracked.txt was touched"
pass "untracked files are left alone"

# Running it twice is a no-op: the second run sets the same times again.
"$RESTORE" "$REPO" >/dev/null || fail "second run exited non-zero"
[[ "$(mtime a.txt)" == "$T2" ]] || fail "second run changed a.txt"
pass "idempotent"

# Sanity: the checkout really had stamped the files with a later time first,
# or the assertions above proved nothing.
[[ "$NOW" -gt "$T4" ]] || fail "test setup: checkout mtime $NOW is not newer than $T4"
pass "the fixture started from checkout-time mtimes"

echo "all restore-mtimes checks passed"
