#!/usr/bin/env bash
# Regression test for LVX-112: a build dir on the Mac belongs to the worktree
# that first synced into it (scripts/lib/build-dir-claim.sh). Another worktree
# that points LV_BUILD_DIR at it is refused before any sync, unless it sets
# LV_BUILD_DIR_SHARED=1; so is one that names another worktree's default dir.
# Two copies of scripts/ stand in for two worktrees; ssh and rsync are stubs
# that log what reached the host.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-build-dir-owner-test.XXXXXX")"
# remote-build.sh's background GC can still be writing as this script exits.
trap 'for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tree in tree-a tree-b; do
  mkdir -p "$TMP_DIR/$tree"
  cp -R "$ROOT_DIR/scripts" "$TMP_DIR/$tree/scripts"
done
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
printf 'ssh %s\n' "$1" >>"$LV_TEST_HOST_LOG"
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
printf 'rsync %s\n' "${!#}" >>"$LV_TEST_HOST_LOG"
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

host_log="$TMP_DIR/host.log"
LOCK="$TMP_DIR/locks/fake-host.lock"
CLAIMS="$TMP_DIR/locks/fake-host.build-dirs"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_LOCK_DIR=$LOCK"
  "LV_LOCK_OWNER=dir-owner-test"
  "LV_TEST_HOST_LOG=$host_log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/gc.log"
)

# run <tree> <env assignment>... -- <verb> [args]: sets $status and $out.
run() {
  local tree="$1"
  shift
  local -a env_args=()
  while [[ "$1" != "--" ]]; do env_args+=("$1"); shift; done
  shift
  : >"$host_log"
  status=0
  env "${common_env[@]}" ${env_args[@]+"${env_args[@]}"} \
    LOCALVOXTRAL_REMOTE_LOG="$TMP_DIR/$tree-remote.log" \
    "$TMP_DIR/$tree/scripts/remote-build.sh" "$@" >"$TMP_DIR/out" 2>&1 || status=$?
  out="$(cat "$TMP_DIR/out")"
}

synced() { grep -q '^rsync ' "$host_log"; }

SHARED_DIR=work/localvoxtral-shared-night

# --- the first tree to sync owns the dir --------------------------------------
run tree-a LV_BUILD_DIR="$SHARED_DIR" -- build
[[ "$status" == 0 ]] || fail "the first tree was refused a free dir: $out"
synced || fail "the first tree did not sync"

run tree-a LV_BUILD_DIR="$SHARED_DIR" -- build
[[ "$status" == 0 ]] || fail "the owner was refused its own dir: $out"
echo "PASS: the first tree to sync owns the dir and keeps using it"

# --- another tree is refused before it syncs or packages -----------------------
for verb in build package; do
  run tree-b LV_BUILD_DIR="$SHARED_DIR" -- "$verb"
  [[ "$status" == 77 ]] || fail "$verb from a second tree: status $status, not 77: $out"
  ! synced || fail "$verb from a second tree reached the host: $(cat "$host_log")"
  grep -qF "it belongs to the worktree $TMP_DIR/tree-a" <<<"$out" \
    || fail "the refusal does not name the owner: $out"
done
run tree-b LV_BUILD_DIR="$SHARED_DIR" -- remove "$SHARED_DIR"
[[ "$status" == 77 ]] || fail "remove from a second tree: status $status, not 77: $out"
! grep -q '^ssh remove' "$host_log" || fail "a second tree removed the owner's dir"
echo "PASS: another tree is refused sync, package and remove, naming the owner"

# --- sharing on purpose -------------------------------------------------------
run tree-b LV_BUILD_DIR="$SHARED_DIR" LV_BUILD_DIR_SHARED=1 -- build
[[ "$status" == 0 ]] || fail "LV_BUILD_DIR_SHARED=1 was refused: $out"
synced || fail "LV_BUILD_DIR_SHARED=1 did not sync"
[[ "$(cat "$CLAIMS/work_localvoxtral-shared-night")" == "$TMP_DIR/tree-a" ]] \
  || fail "sharing a dir changed its owner"
echo "PASS: LV_BUILD_DIR_SHARED=1 shares the dir and leaves its owner"

# --- another tree's default dir, before any marker exists ----------------------
# The 11-05 dir was work/localvoxtral-wt-lvx2-b9daaa21, another tree's default.
run tree-b LV_BUILD_DIR=work/localvoxtral-wt-lvx2-b9daaa21 -- build
[[ "$status" == 77 ]] || fail "another tree's default dir: status $status, not 77: $out"
! synced || fail "a sync reached another tree's default dir"
run tree-b LV_BUILD_DIR_CLAIMS= LV_LOCK_DIR= LV_BUILD_DIR=work/localvoxtral-wt-lvx2-b9daaa21 -- build
[[ "$status" == 77 ]] || fail "without a claims dir, another tree's default dir: status $status: $out"
run tree-b -- build
[[ "$status" == 0 ]] || fail "a tree was refused its own default dir: $out"
echo "PASS: another tree's default dir is refused even with no marker"

# --- an owner that is gone hands the dir on; remove forgets the owner ----------
rm -rf "$TMP_DIR/tree-a"
run tree-b LV_BUILD_DIR="$SHARED_DIR" -- build
[[ "$status" == 0 ]] || fail "a dir whose owner is gone was refused: $out"
[[ "$(cat "$CLAIMS/work_localvoxtral-shared-night")" == "$TMP_DIR/tree-b" ]] \
  || fail "the dir did not pass to the tree that synced after its owner was gone"
run tree-b LV_BUILD_DIR="$SHARED_DIR" -- remove "$SHARED_DIR"
[[ "$status" == 0 ]] || fail "the owner could not remove its dir: $out"
[[ ! -e "$CLAIMS/work_localvoxtral-shared-night" ]] || fail "remove left the owner marker"
echo "PASS: a gone owner hands the dir on, and remove forgets the owner"

echo "OK: build dir owner tests passed"
