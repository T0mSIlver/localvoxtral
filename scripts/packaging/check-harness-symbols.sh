#!/usr/bin/env bash
# Checks whether a built localvoxtral binary contains the e2e test harness: the
# control socket that starts dictations and the WAV file that stands in for the
# microphone (docs/agent/invariants.md, "The control socket"). A release build
# must contain neither; package_app.sh runs this on every bundle it makes.
#
#   check-harness-symbols.sh <binary> absent    # release: no harness symbol
#   check-harness-symbols.sh <binary> present   # harness build: all of them
#
# Swift keeps type names in plain bytes (mangled symbols, type descriptors,
# reflection strings), so a byte search finds a type even in a stripped
# binary, which `nm` would not list. The search must also find a type every
# build has; otherwise a wrong path or a changed encoding would pass as clean.
set -euo pipefail

BINARY="${1:-}"
EXPECT="${2:-}"
if [[ -z "$BINARY" || ( "$EXPECT" != absent && "$EXPECT" != present ) ]]; then
  echo "usage: $0 <binary> absent|present" >&2
  exit 2
fi
if [[ ! -f "$BINARY" ]]; then
  echo "Harness symbol check: no binary at $BINARY" >&2
  exit 2
fi

# The socket's three types, the WAV source, the socket's runtime switch and the
# WAV's launch variable. Each is compiled only under
# `DEBUG || LOCALVOXTRAL_E2E_HARNESS`.
HARNESS_TOKENS=(
  DogfoodControlSocket
  DogfoodControlService
  DogfoodControlProtocol
  DogfoodAudioFileSource
  dogfood_control_socket_enabled
  LOCALVOXTRAL_DOGFOOD_AUDIO_FILE
)
CONTROL_TOKEN=DictationSessionController

count_of() { # grep exits 1 on no match, which pipefail would turn fatal
  { LC_ALL=C grep -a -o -F -- "$1" "$BINARY" || true; } | wc -l | tr -d ' '
}

if [[ "$(count_of "$CONTROL_TOKEN")" == 0 ]]; then
  echo "Harness symbol check: $CONTROL_TOKEN not found in $BINARY, so the search cannot see type names; is this the app binary?" >&2
  exit 1
fi

found=()
missing=()
for token in "${HARNESS_TOKENS[@]}"; do
  n="$(count_of "$token")"
  if [[ "$n" == 0 ]]; then
    missing+=("$token")
  else
    found+=("${token}×${n}")
  fi
done

if [[ "$EXPECT" == absent ]]; then
  if (( ${#found[@]} > 0 )); then
    echo "Harness symbol check FAILED: a release binary contains test-harness code: ${found[*]}" >&2
    echo "Keep it under #if DEBUG || LOCALVOXTRAL_E2E_HARNESS." >&2
    exit 1
  fi
  echo "Harness symbol check: none of ${#HARNESS_TOKENS[@]} harness names in $(basename "$BINARY") ($CONTROL_TOKEN found, so the search works)"
else
  if (( ${#missing[@]} > 0 )); then
    echo "Harness symbol check FAILED: a harness build lacks ${missing[*]}" >&2
    exit 1
  fi
  echo "Harness symbol check: harness build carries ${found[*]}"
fi
