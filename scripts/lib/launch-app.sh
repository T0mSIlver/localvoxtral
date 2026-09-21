# Shared launch shim for the lanes that open the packaged app on the owner's
# Mac. Source it, then call `lv_open` wherever the script would call `open` on
# the bundle.
#
# `open` hands the bundle to LaunchServices, which does NOT give it this shell's
# environment. LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN has to be passed explicitly
# or a lane that sets it still gets the modal keychain prompt it set the flag to
# avoid (see Sources/localvoxtral/StartupPermissionSuppression.swift). The same
# goes for LOCALVOXTRAL_DOGFOOD_AUDIO_FILE, the WAV a dogfood build dictates
# from in place of the microphone (docs/dogfood-builds.md).
#
# Written for the runner's bash 3.2: no arrays, no `${x[@]}` under `set -u`.
lv_open() {
  if [ -n "${LOCALVOXTRAL_DOGFOOD_AUDIO_FILE:-}" ]; then
    set -- --env "LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=$LOCALVOXTRAL_DOGFOOD_AUDIO_FILE" "$@"
  fi
  if [ "${LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN:-}" = "1" ]; then
    set -- --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 "$@"
  fi
  open "$@"
}
