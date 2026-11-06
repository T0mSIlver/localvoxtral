# shellcheck shell=bash
# A build dir on the Mac belongs to the worktree that first synced into it.
# On 2026-11-05 three runs from three worktrees synced and packaged into one
# dir through LV_BUILD_DIR, and a helper built from one tree voided another
# tree's eval (LVX-112). remote-build.sh therefore refuses to sync into, or
# remove, a dir another worktree owns.
#
# The owner marker is a file on the machine the agents run on, beside the build
# host's lock (scripts/lib/build-host-lock.sh): `<lock minus .lock>.build-dirs/
# <dir with / as _>` holds the owning worktree's path. It lives here, not in the
# dir on the Mac, because the SSH gate has no verb that reads a file back
# before the sync. LV_BUILD_DIR_CLAIMS overrides the place; with neither it nor
# a lock, no marker is kept. Without a marker, a dir named like another
# worktree's default (work/localvoxtral-<slug>-<8 hex>) is still refused.
#
# LV_BUILD_DIR_SHARED=1 syncs into an owned dir on purpose, leaving its owner
# as it is. A marker whose worktree no longer exists on this machine passes to
# the next tree that syncs. Runs are serialized by the host lock, so claiming
# needs no lock of its own.
#
# Sourced by remote-build.sh. Written for bash 3.2.

LV_BUILD_DIR_CLAIMS="${LV_BUILD_DIR_CLAIMS:-${LV_LOCK_DIR:+${LV_LOCK_DIR%.lock}.build-dirs}}"
LV_BUILD_DIR_REFUSED_STATUS=77

lv_build_dir_claim_file() {
  printf '%s/%s\n' "$LV_BUILD_DIR_CLAIMS" "$(printf '%s' "${1%/}" | tr '/' '_')"
}

lv_build_dir_owner() {
  local owner=""
  [[ -n "$LV_BUILD_DIR_CLAIMS" ]] || return 0
  IFS= read -r owner <"$(lv_build_dir_claim_file "$1")" 2>/dev/null || true
  printf '%s' "$owner"
}

lv_build_dir_refuse() {
  local dir="$1" why="$2"
  {
    echo "remote-build.sh: refusing to use $HOST:$dir: $why."
    echo "  Unset LV_BUILD_DIR to use this worktree's own dir, or set"
    echo "  LV_BUILD_DIR_SHARED=1 to share that dir on purpose (LVX-112)."
  } >&2
  exit "$LV_BUILD_DIR_REFUSED_STATUS"
}

# lv_build_dir_check <dir> <this tree's default dir> <this tree's root>
# Exits LV_BUILD_DIR_REFUSED_STATUS when another worktree owns <dir>.
lv_build_dir_check() {
  local dir="${1%/}" default_dir="${2%/}" root="$3" owner
  owner="$(lv_build_dir_owner "$dir")"
  if [[ -n "$owner" && "$owner" != "$root" && -e "$owner" ]]; then
    if [[ "${LV_BUILD_DIR_SHARED:-0}" == "1" ]]; then
      echo "==> LV_BUILD_DIR_SHARED=1: using $dir, which belongs to $owner" >&2
      return 0
    fi
    lv_build_dir_refuse "$dir" "it belongs to the worktree $owner"
  fi
  if [[ -z "$owner" && "$dir" != "$default_dir" \
        && "$dir" =~ ^work/localvoxtral-.+-[0-9a-f]{8}$ \
        && "${LV_BUILD_DIR_SHARED:-0}" != "1" ]]; then
    lv_build_dir_refuse "$dir" "it is named for another worktree, and no marker says whose"
  fi
  return 0
}

# lv_build_dir_claim <dir> <this tree's default dir> <this tree's root>
# Checks, then records this tree as the owner unless a live owner keeps it.
lv_build_dir_claim() {
  local dir="${1%/}" root="$3" owner file
  lv_build_dir_check "$@"
  [[ -n "$LV_BUILD_DIR_CLAIMS" ]] || return 0
  owner="$(lv_build_dir_owner "$dir")"
  [[ "$owner" == "$root" ]] && return 0
  [[ -n "$owner" && -e "$owner" ]] && return 0
  [[ -z "$owner" ]] || echo "==> $dir belonged to $owner, which is gone; this worktree owns it now" >&2
  mkdir -p "$LV_BUILD_DIR_CLAIMS"
  file="$(lv_build_dir_claim_file "$dir")"
  printf '%s\n' "$root" >"$file.$$" && mv -f "$file.$$" "$file"
}

# After `remove`: the dir is gone, so is its owner.
lv_build_dir_forget() {
  [[ -n "$LV_BUILD_DIR_CLAIMS" ]] || return 0
  rm -f "$(lv_build_dir_claim_file "$1")"
}
