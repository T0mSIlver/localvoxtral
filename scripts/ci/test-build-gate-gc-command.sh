#!/usr/bin/env bash
# Regression tests for the gate's work-dir GC: the per-use stamp verbs, the
# age decision, the live-process and EvalRecordings keep-checks, and the
# denial surface of the new gc/disk verbs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-gate-gc-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

FAKE_HOME="$TMP_DIR/home"
WORK="$FAKE_HOME/work"
OLD_TS="202001010000"
mkdir -p "$WORK"

run_gate() {
  HOME="$FAKE_HOME" SSH_ORIGINAL_COMMAND="$1" bash "$GATE"
}

# Age every existing entry of a dir (files first-created, then all mtimes
# forced old — touching an existing file does not bump its parent dir).
age_tree() {
  find "$1" -exec touch -t "$OLD_TS" {} +
}

# --- stamp verbs -------------------------------------------------------------

run_gate 'mkdir -p work/localvoxtral-stamp-1' >/dev/null
[[ -f "$WORK/localvoxtral-stamp-1/.lv-last-used" ]] \
  || fail "mkdir verb did not create the last-used stamp"

age_tree "$WORK/localvoxtral-stamp-1"
old_ref="$TMP_DIR/old-ref"
touch -t "$OLD_TS" "$old_ref"
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_DIR/bin/swift"
HOME="$FAKE_HOME" PATH="$TMP_DIR/bin:$PATH" \
  SSH_ORIGINAL_COMMAND='cd work/localvoxtral-stamp-1 && swift build' \
  bash "$GATE" >/dev/null
[[ "$WORK/localvoxtral-stamp-1/.lv-last-used" -nt "$old_ref" ]] \
  || fail "cd verb did not refresh the last-used stamp"

# --- gc: age decision --------------------------------------------------------

# Stale in every way -> deleted.
mkdir -p "$WORK/localvoxtral-stale-1/.build/arm64/debug"
echo artifact >"$WORK/localvoxtral-stale-1/.build/arm64/debug/product"
echo source >"$WORK/localvoxtral-stale-1/main.swift"
age_tree "$WORK/localvoxtral-stale-1"

# Fresh stamp -> kept.
mkdir -p "$WORK/localvoxtral-fresh-1/.build"
age_tree "$WORK/localvoxtral-fresh-1"
touch "$WORK/localvoxtral-fresh-1/.lv-last-used"

# Old stamp but a build wrote a fresh product (pre-stamp dirs rely on this) -> kept.
mkdir -p "$WORK/localvoxtral-fresh-deep-1/.build/arm64/debug"
echo artifact >"$WORK/localvoxtral-fresh-deep-1/.build/arm64/debug/old"
age_tree "$WORK/localvoxtral-fresh-deep-1"
echo artifact >"$WORK/localvoxtral-fresh-deep-1/.build/arm64/debug/rebuilt"

# Only fresh entry is a depth-8 xcodebuild product OVERWRITE (no ancestor dir
# mtime bump) -> kept. Pins the find -maxdepth against the deepest real
# build-product path.
xcode_deep="$WORK/localvoxtral-fresh-xcode-1/.build/xcode/Build/Products/Release/app.app/Contents/MacOS"
mkdir -p "$xcode_deep"
echo binary >"$xcode_deep/app"
age_tree "$WORK/localvoxtral-fresh-xcode-1"
touch "$xcode_deep/app"
find "$WORK/localvoxtral-fresh-xcode-1" -type d -exec touch -t "$OLD_TS" {} +

# Stale but holds recordings -> pruned, EvalRecordings intact.
mkdir -p "$WORK/localvoxtral-recordings-1/EvalRecordings/agent-dictation/owner"
echo '{}' >"$WORK/localvoxtral-recordings-1/EvalRecordings/agent-dictation/owner/manifest.json"
mkdir -p "$WORK/localvoxtral-recordings-1/.build"
echo artifact >"$WORK/localvoxtral-recordings-1/.build/product"
echo source >"$WORK/localvoxtral-recordings-1/main.swift"
age_tree "$WORK/localvoxtral-recordings-1"

# Not a gate-managed dir -> never touched, however stale.
mkdir -p "$WORK/other-project"
echo keep >"$WORK/other-project/file"
age_tree "$WORK/other-project"

gc_output="$(run_gate 'gc')"

[[ ! -e "$WORK/localvoxtral-stale-1" ]] \
  || fail "stale work dir survived gc"
[[ -e "$WORK/localvoxtral-fresh-1" ]] \
  || fail "fresh-stamp work dir was deleted"
[[ -e "$WORK/localvoxtral-fresh-deep-1" ]] \
  || fail "work dir with a fresh build product was deleted"
[[ -e "$WORK/localvoxtral-fresh-xcode-1" ]] \
  || fail "work dir with only deep fresh xcodebuild output was deleted"
[[ -f "$WORK/localvoxtral-recordings-1/EvalRecordings/agent-dictation/owner/manifest.json" ]] \
  || fail "gc destroyed EvalRecordings in a stale dir"
[[ ! -e "$WORK/localvoxtral-recordings-1/.build" \
  && ! -e "$WORK/localvoxtral-recordings-1/main.swift" ]] \
  || fail "gc did not prune build state around EvalRecordings"
[[ -f "$WORK/other-project/file" ]] \
  || fail "gc touched a non-localvoxtral dir"
grep -q 'deleted 1, pruned 1' <<<"$gc_output" \
  || fail "gc summary wrong: $gc_output"

# --- gc: live-process keep-check --------------------------------------------

mkdir -p "$WORK/localvoxtral-busy-1/.build"
echo artifact >"$WORK/localvoxtral-busy-1/.build/product"
age_tree "$WORK/localvoxtral-busy-1"
cat >"$TMP_DIR/bin/lsof" <<STUB
#!/usr/bin/env bash
printf 'p123\nn$WORK/localvoxtral-busy-1/.build/product\n'
STUB
chmod +x "$TMP_DIR/bin/lsof"
busy_output="$(HOME="$FAKE_HOME" PATH="$TMP_DIR/bin:$PATH" \
  SSH_ORIGINAL_COMMAND='gc' bash "$GATE")"
[[ -e "$WORK/localvoxtral-busy-1/.build/product" ]] \
  || fail "gc deleted a work dir with live processes rooted in it"
grep -q 'live processes' <<<"$busy_output" \
  || fail "gc did not report the busy keep: $busy_output"
# The recordings skeleton from the earlier pass must not be re-reported as
# "pruned" on every subsequent run.
grep -q 'deleted 0, pruned 0' <<<"$busy_output" \
  || fail "gc re-counted an already-pruned skeleton: $busy_output"
rm -f "$TMP_DIR/bin/lsof"

# lsof present but ERRORING -> evidence unavailable -> fail closed, keep.
cat >"$TMP_DIR/bin/lsof" <<'STUB'
#!/usr/bin/env bash
echo 'lsof: simulated failure' >&2
exit 1
STUB
chmod +x "$TMP_DIR/bin/lsof"
HOME="$FAKE_HOME" PATH="$TMP_DIR/bin:$PATH" \
  SSH_ORIGINAL_COMMAND='gc' bash "$GATE" >/dev/null
[[ -e "$WORK/localvoxtral-busy-1/.build/product" ]] \
  || fail "gc deleted a work dir when lsof evidence was unavailable"
rm -f "$TMP_DIR/bin/lsof"
rm -rf "$WORK/localvoxtral-busy-1"

# --- disk verb ---------------------------------------------------------------

disk_output="$(run_gate 'disk')"
grep -q '^Data volume free: [0-9]* GiB' <<<"$disk_output" \
  || fail "disk verb missing the parseable free-space line: $disk_output"
# A numeric age proves file_mtime works on this platform (GNU stat -f
# "succeeds" with a mount point, which once rendered every age as "?").
grep -q 'workdir localvoxtral-fresh-1 last-used 0d ago' <<<"$disk_output" \
  || fail "disk verb missing a numeric last-used age: $disk_output"

# --- denial surface ----------------------------------------------------------

assert_denied() {
  local command="$1" status=0
  if HOME="$FAKE_HOME" SSH_ORIGINAL_COMMAND="$command" bash "$GATE" >/dev/null 2>&1; then
    fail "unsafe command was accepted: $command"
  else
    status=$?
  fi
  [[ "$status" == "126" ]] \
    || fail "unsafe command '$command' exited $status instead of 126"
}

assert_denied 'gc now'
assert_denied 'gc;id'
assert_denied 'disk /'
assert_denied 'disk;id'

printf 'PASS: gate stamps work dirs on use, gc reclaims only stale idle dirs, recordings survive\n'
