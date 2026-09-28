# Shared launch shim for the lanes that open the packaged app on the owner's
# Mac. Source it, then call `lv_open` wherever the script would call `open` on
# the bundle.
#
# `open` hands the bundle to LaunchServices, which does NOT give it this shell's
# environment. LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN has to be passed explicitly
# or a lane that sets it still gets the modal keychain prompt it set the flag to
# avoid (see Sources/localvoxtralCore/StartupPermissionSuppression.swift). The same
# goes for LOCALVOXTRAL_DOGFOOD_AUDIO_FILE, the WAV a harness build dictates
# from in place of the microphone (docs/test-harness.md), and for
# LOCALVOXTRAL_DATA_HOME, the data folder that keeps a lane off the owner's
# History and other stores (#985).
#
# Written for the runner's bash 3.2: no arrays, no `${x[@]}` under `set -u`.
lv_open() {
  if [ -n "${LOCALVOXTRAL_DOGFOOD_AUDIO_FILE:-}" ]; then
    set -- --env "LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=$LOCALVOXTRAL_DOGFOOD_AUDIO_FILE" "$@"
  fi
  if [ -n "${LOCALVOXTRAL_DATA_HOME:-}" ]; then
    set -- --env "LOCALVOXTRAL_DATA_HOME=$LOCALVOXTRAL_DATA_HOME" "$@"
  fi
  if [ "${LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN:-}" = "1" ]; then
    set -- --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 "$@"
  fi
  open "$@"
}
