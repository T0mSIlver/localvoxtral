#!/usr/bin/env bash
# Takes or releases a build host's lock by hand, for heavy work that does not
# go through remote-build.sh: a bench, an eval, a package build. remote-build.sh
# takes the lock itself, so never take it around a remote-build.sh run: the
# run would wait on you (LVX-104). It now refuses a lock taken by hand from its
# own worktree.
#
#   scripts/build-host-lock.sh take <build host> <what you run>
#   scripts/build-host-lock.sh release <build host>
#   scripts/build-host-lock.sh show <build host>
#
# The lock directory is the one remote-build.sh uses: LV_LOCK_DIR, else
# `git config localvoxtral.<build host>.lock`. The owner line names this
# worktree, and `release` removes the lock only while that line is still this
# worktree's: a lock someone else took after yours stays.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
verb="${1:-}" host="${2:-}"
[[ -n "$verb" && -n "$host" ]] || { sed -n '9,11p' "$0" | sed 's/^# *//' >&2; exit 64; }
LV_LOCK_DIR="${LV_LOCK_DIR:-$(git -C "$ROOT_DIR" config --get "localvoxtral.$host.lock" 2>/dev/null || true)}"
[[ -n "$LV_LOCK_DIR" ]] || { echo "build-host-lock: no lock is configured for $host" >&2; exit 64; }
mine=" worktree=$ROOT_DIR"

holder() {
  local line=""
  [[ -f "$LV_LOCK_DIR/owner" ]] && IFS= read -r line <"$LV_LOCK_DIR/owner" 2>/dev/null || true
  printf '%s' "$line"
}

case "$verb" in
  take)
    what="${*:3}"
    [[ -n "$what" ]] || { echo "build-host-lock: say what you run: take $host <what>" >&2; exit 64; }
    mkdir -p "$(dirname "$LV_LOCK_DIR")"
    if ! mkdir "$LV_LOCK_DIR" 2>/dev/null; then
      echo "build-host-lock: $LV_LOCK_DIR is held by: $(holder)" >&2
      exit 75
    fi
    printf '%s %s by-hand %s%s\n' "${LV_LOCK_OWNER:-$(basename "$ROOT_DIR")}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$what" "$mine" >"$LV_LOCK_DIR/owner"
    echo "Holding $LV_LOCK_DIR. Release it with: scripts/build-host-lock.sh release $host"
    ;;
  release)
    line="$(holder)"
    if [[ ! -d "$LV_LOCK_DIR" ]]; then
      echo "build-host-lock: $LV_LOCK_DIR is not held"
    elif [[ "$line" == *" by-hand "*"$mine" ]]; then
      rm -r "$LV_LOCK_DIR"
      echo "Released $LV_LOCK_DIR"
    else
      echo "build-host-lock: $LV_LOCK_DIR is not this worktree's (held by: ${line:-an owner that wrote no line}); left as it is" >&2
      exit 1
    fi
    ;;
  show) echo "$(holder)" ;;
  *) echo "build-host-lock: unknown verb $verb" >&2; exit 64 ;;
esac
