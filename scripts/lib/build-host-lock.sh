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
# removes the directory. People take the same directory by hand with that
# recipe, and the script honours their locks.
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

lv_lock_holder() {
  cat "$LV_LOCK_DIR/owner" 2>/dev/null | head -n 1
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

# Waits for the lock, then holds it. $1 names the job in the owner line.
lv_lock_acquire() {
  [[ -n "${LV_LOCK_DIR:-}" && "${LV_LOCK_HELD:-}" != "$LV_LOCK_DIR" ]] || return 0
  mkdir -p "$(dirname "$LV_LOCK_DIR")"
  LV_LOCK_OWNER_LINE="${LV_LOCK_OWNER:-$(basename "${ROOT_DIR:-$PWD}")} $(date -u +%Y-%m-%dT%H:%M:%SZ) remote-build.sh $1 host=$(hostname) pid=$$"
  local started=$SECONDS said_at=-1 said_holder="" holder age
  while :; do
    if mkdir "$LV_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$LV_LOCK_OWNER_LINE" >"$LV_LOCK_DIR/owner"
      LV_LOCK_TAKEN=1
      export LV_LOCK_HELD="$LV_LOCK_DIR"
      echo "==> Holding the build host lock $LV_LOCK_DIR"
      return 0
    fi
    holder="$(lv_lock_holder)"
    if lv_lock_holder_is_dead "$holder"; then
      echo "==> Clearing the build host lock left by a remote-build.sh that is gone: $holder" >&2
      [[ "$(lv_lock_holder)" == "$holder" ]] && rm -rf "$LV_LOCK_DIR"
      continue
    fi
    if [[ "$holder" != "$said_holder" ]] || (( said_at < 0 || SECONDS - said_at >= 300 )); then
      age="$(lv_lock_age "$holder")"
      echo "==> Waiting for the build host lock $LV_LOCK_DIR, held by: ${holder:-an owner that wrote no line}; $(( (SECONDS - started) / 60 )) min so far, retrying every ${LV_LOCK_POLL_SECONDS}s" >&2
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

# Releases the lock this run took, and only while the line in it is still ours.
lv_lock_release() {
  [[ "$LV_LOCK_TAKEN" == 1 ]] || return 0
  LV_LOCK_TAKEN=0
  if [[ "$(lv_lock_holder)" == "$LV_LOCK_OWNER_LINE" ]]; then
    rm -rf "$LV_LOCK_DIR"
    echo "==> Released the build host lock $LV_LOCK_DIR"
  else
    echo "==> WARN: the build host lock $LV_LOCK_DIR no longer holds this run's line; left as it is" >&2
  fi
}
