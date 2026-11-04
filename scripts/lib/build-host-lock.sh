# shellcheck shell=bash
# One heavy job at a time per build host. An 8 GB Mac dropped SSH with two cold
# builds and an eval on it at once, so every remote-build.sh run that sends work
# to a host first waits for that host's lock.
#
# The lock is a directory on the machine the agents run on, one per build host,
# named in git config like the host itself (machine-local, never committed):
#   git config localvoxtral.<build host>.lock /path/to/<host>.lock
# LV_LOCK_DIR overrides it; with neither, nothing waits. Taking the lock is
# `mkdir`, the holder writes one owner line into `<lock>/owner`, releasing
# removes the directory. People take the same directory by hand
# (scripts/build-host-lock.sh, or that recipe), and the script waits for their
# locks, except one taken by hand from its own worktree: that one it would wait
# on forever, so it says so and stops.
#
# The script never breaks a lock by age: past LV_LOCK_OLD_SECONDS (3 h) it says
# so and keeps waiting, since only the person or agent coordinating the host
# may break a lock. It does clear one a remote-build.sh on this machine left
# behind when its process died. A nested run (LV_LOCK_HELD names the lock) does
# not wait for the lock its parent holds.
#
# Sourced by remote-build.sh. Written for bash 3.2.

LV_LOCK_OLD_SECONDS="${LV_LOCK_OLD_SECONDS:-10800}"
LV_LOCK_WAIT_SECONDS="${LV_LOCK_WAIT_SECONDS:-10800}"
LV_LOCK_POLL_SECONDS="${LV_LOCK_POLL_SECONDS:-30}"
LV_LOCK_OWNER_LINE=""
LV_LOCK_TAKEN=0

# The holder's owner line, empty while it has not written one (or just left).
lv_lock_holder() {
  local line=""
  if [[ -f "$LV_LOCK_DIR/owner" ]]; then
    IFS= read -r line <"$LV_LOCK_DIR/owner" 2>/dev/null || true
  fi
  printf '%s' "$line"
}

# Removes the lock left by $1, a dead holder, under a short reclaim mutex: two
# waiters that both found it dead recheck the line one at a time, so the second
# sees the lock the first then took and leaves it. Succeeds only when it removed
# the lock. A mutex whose holder is gone, or that never got a pid and is over a
# minute old, is cleared for the next try.
lv_lock_reclaim() {
  local holder="$1" mutex="$LV_LOCK_DIR.reclaim" mutex_pid="" removed=1
  if ! mkdir "$mutex" 2>/dev/null; then
    IFS= read -r mutex_pid <"$mutex/pid" 2>/dev/null || mutex_pid=""
    if [[ "$mutex_pid" =~ ^[0-9]+$ ]]; then
      kill -0 "$mutex_pid" 2>/dev/null || rm -rf "$mutex"
    elif [[ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rm -rf "$mutex"
    fi
    return 1
  fi
  printf '%s\n' "$$" >"$mutex/pid"
  if [[ "$(lv_lock_holder)" == "$holder" ]]; then
    echo "==> Clearing the build host lock left by a remote-build.sh that is gone: $holder" >&2
    rm -rf "$LV_LOCK_DIR"
    removed=0
  fi
  rm -rf "$mutex"
  return "$removed"
}

# Whether the holder is a remote-build.sh on this machine whose process is gone.
lv_lock_holder_is_dead() {
  local holder="$1" pid
  case "$holder" in
    *" remote-build.sh "*" host=$(hostname) pid="*) ;;
    *) return 1 ;;
  esac
  pid="${holder##*pid=}"
  pid="${pid%% *}"
  [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null
}

lv_lock_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# Seconds since the first UTC timestamp in the holder's line, or nothing.
lv_lock_age() {
  local stamp since
  stamp="$(printf '%s\n' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' | head -n 1)"
  [[ -n "$stamp" ]] || return 0
  since="$(lv_lock_epoch "$stamp")" || return 0
  [[ -n "$since" ]] && printf '%s' "$(( $(date -u +%s) - since ))"
}

# Whether the holder took the lock by hand (scripts/build-host-lock.sh) from
# this worktree. remote-build.sh takes the lock itself, so waiting on it would
# wait on ourselves: that held the Mini for 55 minutes (LVX-104).
lv_lock_held_by_hand_here() {
  [[ "$1" == *" by-hand "*" worktree=${ROOT_DIR:-$PWD}" ]]
}

# Whether the line is not one a remote-build.sh wrote: someone took the lock by
# hand. Theirs may be a real heavy job, so it is waited for, but named.
lv_lock_held_by_hand() {
  [[ -n "$1" && "$1" != *" remote-build.sh "*" host="*" pid="* ]]
}

# Waits for the lock, then holds it. $1 names the job in the owner line.
lv_lock_acquire() {
  [[ -n "${LV_LOCK_DIR:-}" && "${LV_LOCK_HELD:-}" != "$LV_LOCK_DIR" ]] || return 0
  mkdir -p "$(dirname "$LV_LOCK_DIR")"
  LV_LOCK_OWNER_LINE="${LV_LOCK_OWNER:-$(basename "${ROOT_DIR:-$PWD}")} $(date -u +%Y-%m-%dT%H:%M:%SZ) remote-build.sh $1 host=$(hostname) pid=$$"
  local started=$SECONDS said_at=-1 said_holder="" holder age
  while :; do
    if mkdir "$LV_LOCK_DIR" 2>/dev/null; then
      # Taken from here on, so a signal before the owner line is written still
      # releases it (the caller registers lv_lock_release before acquiring).
      LV_LOCK_TAKEN=1
      printf '%s\n' "$LV_LOCK_OWNER_LINE" >"$LV_LOCK_DIR/owner"
      export LV_LOCK_HELD="$LV_LOCK_DIR"
      echo "==> Holding the build host lock $LV_LOCK_DIR"
      return 0
    fi
    holder="$(lv_lock_holder)"
    if lv_lock_holder_is_dead "$holder" && lv_lock_reclaim "$holder"; then
      continue
    fi
    if lv_lock_held_by_hand_here "$holder"; then
      echo "remote-build.sh: the build host lock $LV_LOCK_DIR was taken by hand from this worktree ($holder)." >&2
      echo "remote-build.sh takes the lock itself; release yours first: scripts/build-host-lock.sh release <build host>" >&2
      exit 75
    fi
    if [[ "$holder" != "$said_holder" ]] || (( said_at < 0 || SECONDS - said_at >= 300 )); then
      age="$(lv_lock_age "$holder")"
      echo "==> Waiting for the build host lock $LV_LOCK_DIR, held by: ${holder:-an owner that wrote no line}; $(( (SECONDS - started) / 60 )) min so far, retrying every ${LV_LOCK_POLL_SECONDS}s" >&2
      if [[ "$said_holder" != "$holder" ]] && lv_lock_held_by_hand "$holder"; then
        echo "==> That lock was taken by hand, not by a remote-build.sh. remote-build.sh takes the lock itself: if you took it around this run, release it, or this run waits on you" >&2
      fi
      if [[ -n "$age" ]] && (( age > LV_LOCK_OLD_SECONDS )); then
        echo "==> That lock is over $(( LV_LOCK_OLD_SECONDS / 3600 )) h old; whoever coordinates the host may break it (rm -r $LV_LOCK_DIR)" >&2
      fi
      said_holder="$holder"
      said_at=$SECONDS
    fi
    if (( SECONDS - started >= LV_LOCK_WAIT_SECONDS )); then
      echo "remote-build.sh: gave up after ${LV_LOCK_WAIT_SECONDS}s waiting for the build host lock $LV_LOCK_DIR, held by: ${holder:-an owner that wrote no line}" >&2
      exit 75
    fi
    sleep "$LV_LOCK_POLL_SECONDS"
  done
}

# Releases the lock this run took, and only while the line in it is still ours
# (or not yet written: a signal right after the mkdir).
lv_lock_release() {
  [[ "$LV_LOCK_TAKEN" == 1 ]] || return 0
  LV_LOCK_TAKEN=0
  local holder
  holder="$(lv_lock_holder)"
  if [[ "$holder" == "$LV_LOCK_OWNER_LINE" || -z "$holder" ]]; then
    rm -rf "$LV_LOCK_DIR"
    echo "==> Released the build host lock $LV_LOCK_DIR"
  else
    echo "==> WARN: the build host lock $LV_LOCK_DIR no longer holds this run's line; left as it is" >&2
  fi
}
