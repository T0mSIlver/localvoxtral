# Shared by the lanes that borrow the owner's localvoxtral on the GUI Mac
# (ui-smoke.sh, e2e-dictation.sh), and by capture-readme-assets.sh and
# record-demo.sh: quit the owner's running instance and bring it back
# afterwards, and keep the lane's settings out of the owner's defaults.
#
# UI Smoke and e2e run the app on a defaults suite of their own (#1029) and
# never write the owner's domain. capture-readme-assets.sh and record-demo.sh
# still snapshot and restore it, on backup paths of their own, through the
# backup functions below. Every lane restores a backup a killed run left
# before it starts.
#
# Source it after setting:
#   APP_PROCESS, BUNDLE_ID, OWNER_APP_BUNDLE (empty), OSASCRIPT_TIMEOUT_BIN,
#   OSASCRIPT_TIMEOUT_SECONDS, and a record_fail function.
#
# ONE backup path for every lane, on purpose: a lane that died mid-run leaves
# its forced defaults installed and its backup on disk, and whichever lane runs
# next must restore that backup before it snapshots. With a path per lane, the
# next lane would snapshot the dead lane's forced defaults as the owner's.
#
# The backup is one file: a header saying whether the domain existed and the
# checksum of the exported plist, then the plist. It is staged beside its final
# path and renamed into place, so a lane killed at any point leaves either no
# backup or a complete one. Restoring deletes the live domain only after the
# backup validates; a backup that does not validate stops the restore with the
# domain untouched (#991).
#
# Written for the runner's bash 3.2.
PERSISTENT_DEFAULTS_BACKUP="${HOME}/.localvoxtral-ui-smoke.defaults-backup"
# Before #991 the backup was this plist plus a separate `.had-domain` marker.
LEGACY_DEFAULTS_BACKUP="${HOME}/.localvoxtral-ui-smoke.pre.plist"
DEFAULTS_BACKUP_HEADER="localvoxtral defaults backup v1"

defaults_backup_checksum() {
  cksum <"$1" | awk '{ print $1 " " $2 }'
}

# The staging files a killed snapshot or restore can leave beside the backup.
remove_defaults_backup_scratch() {
  rm -f "${PERSISTENT_DEFAULTS_BACKUP}".staged.* "${PERSISTENT_DEFAULTS_BACKUP}".export.* \
    "${PERSISTENT_DEFAULTS_BACKUP}".payload.*
}

# read_defaults_backup <backup> <payload-out>: prints `present` or `absent`
# and writes the plist to <payload-out>, or fails if any part of the backup
# does not check out.
read_defaults_backup() {
  local backup="$1" payload="$2" state sum
  [[ "$(sed -n '1p' "$backup")" == "$DEFAULTS_BACKUP_HEADER" ]] || return 1
  state="$(sed -n '2s/^domain=//p' "$backup")"
  sum="$(sed -n '3s/^cksum=//p' "$backup")"
  [[ "$(sed -n '4p' "$backup")" == "--" ]] || return 1
  tail -n +5 "$backup" >"$payload" || return 1
  [[ -n "$sum" && "$(defaults_backup_checksum "$payload")" == "$sum" ]] || return 1
  case "$state" in
    present) plutil -lint -s "$payload" >/dev/null 2>&1 || return 1 ;;
    absent) [[ ! -s "$payload" ]] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$state"
}

# apply_defaults_backup <present|absent> <plist>: replace the live domain.
apply_defaults_backup() {
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$1" == present ]]; then
    defaults import "$BUNDLE_ID" "$2" >/dev/null 2>&1 || return 1
  fi
}

# A backup a pre-#991 lane left. Its marker cannot be trusted: a lane killed
# between the export and the marker left an export with no marker. Importing
# the plist is right either way, since an absent domain was backed up as an
# empty dict.
restore_legacy_defaults_backup() {
  if [[ ! -e "$LEGACY_DEFAULTS_BACKUP" ]]; then
    rm -f "${LEGACY_DEFAULTS_BACKUP}.had-domain"
    return 0
  fi
  if ! plutil -lint -s "$LEGACY_DEFAULTS_BACKUP" >/dev/null 2>&1; then
    printf 'ERROR: %s is not a valid plist; leaving the %s domain untouched.\n' "$LEGACY_DEFAULTS_BACKUP" "$BUNDLE_ID" >&2
    return 1
  fi
  apply_defaults_backup present "$LEGACY_DEFAULTS_BACKUP" || return 1
  rm -f "$LEGACY_DEFAULTS_BACKUP" "${LEGACY_DEFAULTS_BACKUP}.had-domain"
}

restore_defaults() {
  # `return $?`, never a bare `return`: cleanup runs this from an EXIT trap,
  # where a bare `return` hands back the status from before the trap.
  if [[ ! -e "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    restore_legacy_defaults_backup
    return $?
  fi

  local payload state
  payload="$(mktemp "${PERSISTENT_DEFAULTS_BACKUP}.payload.XXXXXX")" || return 1
  if ! state="$(read_defaults_backup "$PERSISTENT_DEFAULTS_BACKUP" "$payload")"; then
    rm -f "$payload"
    printf 'ERROR: %s does not validate; leaving the %s domain untouched.\n' "$PERSISTENT_DEFAULTS_BACKUP" "$BUNDLE_ID" >&2
    return 1
  fi
  if ! apply_defaults_backup "$state" "$payload"; then
    rm -f "$payload"
    return 1
  fi
  rm -f "$payload" "$PERSISTENT_DEFAULTS_BACKUP"
}

recover_previous_defaults_backup() {
  remove_defaults_backup_scratch
  if [[ ! -e "$PERSISTENT_DEFAULTS_BACKUP" && ! -e "$LEGACY_DEFAULTS_BACKUP" ]]; then
    rm -f "${LEGACY_DEFAULTS_BACKUP}.had-domain"
    return 0
  fi

  printf 'WARNING: found a defaults backup from a previous interrupted run; restoring owner defaults before continuing.\n' >&2
  if restore_defaults; then
    printf 'WARNING: previous defaults backup restored and removed.\n' >&2
    return 0
  fi

  record_fail "Could not restore the previous defaults backup at $PERSISTENT_DEFAULTS_BACKUP (or $LEGACY_DEFAULTS_BACKUP); refusing to mutate owner defaults."
  return 1
}

# Existence comes from `defaults read`: only its "does not exist" error means
# the domain is absent. Any other failure, or an export that fails or does not
# lint, fails the snapshot, so the lane never mutates a domain it could not
# back up.
snapshot_defaults() {
  if [[ -e "$PERSISTENT_DEFAULTS_BACKUP" || -e "$LEGACY_DEFAULTS_BACKUP" ]]; then
    printf 'ERROR: a defaults backup is already on disk; restore it before taking another.\n' >&2
    return 1
  fi
  remove_defaults_backup_scratch

  local export_file staged state read_error
  export_file="$(mktemp "${PERSISTENT_DEFAULTS_BACKUP}.export.XXXXXX")" || return 1
  if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    state=present
    if ! defaults export "$BUNDLE_ID" "$export_file" >/dev/null 2>&1 \
      || ! plutil -lint -s "$export_file" >/dev/null 2>&1; then
      rm -f "$export_file"
      return 1
    fi
  else
    read_error="$(defaults read "$BUNDLE_ID" 2>&1 >/dev/null)"
    if [[ "$read_error" != *"does not exist"* ]]; then
      rm -f "$export_file"
      return 1
    fi
    state=absent
  fi

  staged="$(mktemp "${PERSISTENT_DEFAULTS_BACKUP}.staged.XXXXXX")" || { rm -f "$export_file"; return 1; }
  if {
    printf '%s\n' "$DEFAULTS_BACKUP_HEADER"
    printf 'domain=%s\n' "$state"
    printf 'cksum=%s\n' "$(defaults_backup_checksum "$export_file")"
    printf -- '--\n'
    cat "$export_file"
  } >"$staged" \
    && [[ "$(read_defaults_backup "$staged" "$export_file")" == "$state" ]] \
    && mv -f "$staged" "$PERSISTENT_DEFAULTS_BACKUP"; then
    rm -f "$export_file"
    return 0
  fi
  rm -f "$export_file" "$staged"
  return 1
}

# The suite UI Smoke and e2e write their settings into, and the app reads
# instead of $BUNDLE_ID when LOCALVOXTRAL_DEFAULTS_SUITE names it. Emptied
# before and after a run, so a killed run's settings never reach the next.
HARNESS_DEFAULTS_SUITE="com.localvoxtral.harness"

use_harness_defaults() {
  defaults delete "$HARNESS_DEFAULTS_SUITE" >/dev/null 2>&1 || true
  LOCALVOXTRAL_DEFAULTS_SUITE="$HARNESS_DEFAULTS_SUITE"
  export LOCALVOXTRAL_DEFAULTS_SUITE
}

# A no-op for a run that never got to use_harness_defaults: it touches nothing.
drop_harness_defaults() {
  [[ -n "${LOCALVOXTRAL_DEFAULTS_SUITE:-}" ]] || return 0
  defaults delete "$HARNESS_DEFAULTS_SUITE" >/dev/null 2>&1 || true
}

# A read-only digest of the owner's domain. A lane logs it before it launches
# the app and again after the app quits, before the owner's app comes back.
owner_defaults_digest() {
  local exported
  exported="$(defaults export "$BUNDLE_ID" - 2>/dev/null)" || exported="<absent>"
  printf '%s' "$exported" | cksum | awk '{ print $1 }'
}

# Prints whether the owner's domain moved since OWNER_DEFAULTS_BEFORE. Silent
# when the lane never got that far.
report_owner_defaults() {
  [[ -n "${OWNER_DEFAULTS_BEFORE:-}" ]] || return 0
  local after
  after="$(owner_defaults_digest)"
  if [[ "$after" == "$OWNER_DEFAULTS_BEFORE" ]]; then
    printf 'Owner defaults unchanged (%s digest %s).\n' "$BUNDLE_ID" "$after"
  else
    printf 'WARNING: owner defaults changed during the run (%s digest %s before, %s after).\n' "$BUNDLE_ID" "$OWNER_DEFAULTS_BEFORE" "$after" >&2
  fi
}

run_osascript() {
  if [[ -n "$OSASCRIPT_TIMEOUT_BIN" ]]; then
    "$OSASCRIPT_TIMEOUT_BIN" "${OSASCRIPT_TIMEOUT_SECONDS}s" osascript "$@"
  else
    # macOS does not ship GNU timeout; if it is unavailable, run osascript
    # directly rather than failing the smoke drill before AX checks can run.
    osascript "$@"
  fi
}

quit_app() {
  if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
    return
  fi

  run_osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done
}

# Quits the owner's running instance, remembering its bundle for
# relaunch_owner_app. The bundle is read off the executable path because the
# owner may run a try-pr copy rather than /Applications.
quit_owner_app() {
  local pid executable
  pid="$(pgrep -x "$APP_PROCESS" 2>/dev/null | head -n 1)"
  [[ -n "$pid" ]] || return 0
  executable="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
  if [[ "$executable" == */Contents/MacOS/* ]]; then
    OWNER_APP_BUNDLE="${executable%%/Contents/MacOS/*}"
  else
    # Unresolvable: still mark the slot as taken so cleanup quits the drill's
    # instance, but there is nothing to relaunch.
    OWNER_APP_BUNDLE="unknown"
    printf 'WARNING: could not resolve the bundle of running pid %s (%s); it will not be relaunched.\n' "$pid" "$executable" >&2
  fi
  quit_app
}

# Plain `open`, not lv_open: the owner's app must come back with the owner's
# environment, not the lane's CI-only flags (they would hide its API keys).
# `open` still hands the app this shell's RUNNER_TRACKING_ID, and at the end of
# the job the Actions runner kills every process carrying the job's id as an
# orphan, the relaunched owner app included. So the relaunch drops it, and the
# lane's flags with it.
relaunch_owner_app() {
  [[ -n "$OWNER_APP_BUNDLE" && "$OWNER_APP_BUNDLE" != "unknown" ]] || return 0
  if pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
    printf 'WARNING: a localvoxtral instance is still running; not relaunching the owner app at %s.\n' "$OWNER_APP_BUNDLE" >&2
    return 0
  fi
  if [[ ! -d "$OWNER_APP_BUNDLE" ]]; then
    printf 'WARNING: the owner app at %s is gone; not relaunching it.\n' "$OWNER_APP_BUNDLE" >&2
    return 0
  fi
  # LOCALVOXTRAL_DATA_HOME too: the owner's app must reopen on the owner's
  # History, not on the lane's folder that is deleted after the run (#985).
  # LOCALVOXTRAL_DEFAULTS_SUITE: and on the owner's preferences (#1029).
  if env -u RUNNER_TRACKING_ID -u LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN -u LOCALVOXTRAL_DOGFOOD_AUDIO_FILE \
    -u LOCALVOXTRAL_DATA_HOME -u LOCALVOXTRAL_DEFAULTS_SUITE open "$OWNER_APP_BUNDLE"; then
    printf "Relaunched the owner's app at %s.\n" "$OWNER_APP_BUNDLE"
  else
    printf 'WARNING: failed to relaunch the owner app at %s.\n' "$OWNER_APP_BUNDLE" >&2
  fi
}
