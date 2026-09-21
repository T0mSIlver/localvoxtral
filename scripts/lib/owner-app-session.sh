# Shared by the lanes that borrow the owner's localvoxtral on the GUI Mac
# (ui-smoke.sh, e2e-dictation.sh): snapshot and restore the app's defaults
# domain, quit the owner's running instance and bring it back afterwards.
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
# Written for the runner's bash 3.2.
PERSISTENT_DEFAULTS_BACKUP="${HOME}/.localvoxtral-ui-smoke.pre.plist"
PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN="${PERSISTENT_DEFAULTS_BACKUP}.had-domain"

restore_defaults() {
  if [[ ! -f "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    return
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -f "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN" ]]; then
    defaults import "$BUNDLE_ID" "$PERSISTENT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 1
  fi
  rm -f "$PERSISTENT_DEFAULTS_BACKUP" "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
}

recover_previous_defaults_backup() {
  if [[ ! -f "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    rm -f "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
    return 0
  fi

  printf 'WARNING: found %s from a previous interrupted run; restoring owner defaults before continuing.\n' "$PERSISTENT_DEFAULTS_BACKUP" >&2
  if restore_defaults; then
    printf 'WARNING: previous defaults backup restored and removed.\n' >&2
    return 0
  fi

  record_fail "Could not restore previous defaults backup at $PERSISTENT_DEFAULTS_BACKUP; refusing to mutate owner defaults."
  return 1
}

write_empty_defaults_backup() {
  cat >"$PERSISTENT_DEFAULTS_BACKUP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
}

snapshot_defaults() {
  rm -f "$PERSISTENT_DEFAULTS_BACKUP" "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
  if defaults export "$BUNDLE_ID" "$PERSISTENT_DEFAULTS_BACKUP" >/dev/null 2>&1; then
    : >"$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN" || return 1
  elif defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    return 1
  else
    write_empty_defaults_backup || return 1
  fi
  [[ -f "$PERSISTENT_DEFAULTS_BACKUP" ]] || return 1
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
  if open "$OWNER_APP_BUNDLE"; then
    printf "Relaunched the owner's app at %s.\n" "$OWNER_APP_BUNDLE"
  else
    printf 'WARNING: failed to relaunch the owner app at %s.\n' "$OWNER_APP_BUNDLE" >&2
  fi
}
