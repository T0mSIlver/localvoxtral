# Shared launch shim for the lanes that open the packaged app on the owner's
# Mac. Source it, then call `lv_open` wherever the script would call `open` on
# the bundle.
#
# `open` hands the bundle to LaunchServices, which does NOT give it this shell's
# environment. LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN has to be passed explicitly
# or a lane that sets it still gets the modal keychain prompt it set the flag to
# avoid (see Sources/localvoxtral/StartupPermissionSuppression.swift).
#
# Written for the runner's bash 3.2: no arrays, no `${x[@]}` under `set -u`.
lv_open() {
  if [ "${LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN:-}" = "1" ]; then
    open --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 "$@"
  else
    open "$@"
  fi
}
