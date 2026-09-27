#!/usr/bin/env bash
# Regression test for scripts/packaging/check-harness-symbols.sh. The binaries
# are byte files built here, so it runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECK="$ROOT_DIR/scripts/packaging/check-harness-symbols.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-harness-symbols-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# binary <name> <token>... writes a file holding the tokens between NUL and
# other bytes, the way a Mach-O string table does.
binary() {
  local path="$TMP_DIR/$1"
  shift
  printf '\x00\xcf\xfa\xed\xfe' >"$path"
  local token
  for token in "$@"; do
    printf '$s12localvoxtral%s\x00junk\x00' "$token" >>"$path"
  done
  printf '%s' "$path"
}

# expect <exit> <description> <binary> <mode>
expect() {
  local expected="$1" description="$2" path="$3" mode="$4" status=0
  "$CHECK" "$path" "$mode" >"$TMP_DIR/out" 2>&1 || status=$?
  [[ "$status" == "$expected" ]] \
    || fail "$description: exit $status, expected $expected: $(cat "$TMP_DIR/out")"
}

ALL=(DogfoodControlSocketC DogfoodControlServiceC DogfoodControlProtocolO
  DogfoodAudioFileSourceC dogfood_control_socket_enabled LOCALVOXTRAL_DOGFOOD_AUDIO_FILE)

clean="$(binary clean 26DictationSessionControllerC 9SomethingV)"
expect 0 "a release binary without harness names passes" "$clean" absent
expect 1 "a clean binary is not a harness build" "$clean" present

for token in "${ALL[@]}"; do
  leaked="$(binary "leak-$token" 26DictationSessionControllerC "$token")"
  expect 1 "a release binary holding $token fails" "$leaked" absent
done

# An unstripped binary lists each object file that contributed code, for
# dsymutil. With whole-module optimization a gated-out file's object can hold
# compiler-made code, so its path names the file but no harness type.
objpath() {
  local path="$TMP_DIR/$1"
  binary "$1" 26DictationSessionControllerC >/dev/null
  printf '/w/.build/release/localvoxtral.build/%s.swift.o\x00' "$2" >>"$path"
  printf '%s' "$path"
}
pathonly="$(objpath pathonly DogfoodAudioFileSource)"
expect 0 "an object-file path that only names a harness file passes absent" "$pathonly" absent
pathandtype="$(objpath pathandtype DogfoodAudioFileSource)"
printf '$s12localvoxtral22DogfoodAudioFileSourceC\x00' >>"$pathandtype"
expect 1 "the type itself beside that path still fails absent" "$pathandtype" absent

harness="$(binary harness 26DictationSessionControllerC "${ALL[@]}")"
expect 0 "a harness binary with every name passes present" "$harness" present
expect 1 "a harness binary fails absent" "$harness" absent

partial="$(binary partial 26DictationSessionControllerC DogfoodControlSocketC)"
expect 1 "a harness binary missing the WAV source fails present" "$partial" present

blind="$(binary blind 9SomethingV)"
expect 1 "a file without the control type fails, rather than passing as clean" "$blind" absent
expect 2 "a missing binary is a usage error" "$TMP_DIR/nope" absent
expect 2 "an unknown mode is a usage error" "$clean" maybe

grep -q "none of 6 harness names" < <("$CHECK" "$clean" absent) \
  || fail "the pass line names how many names it searched"

echo "harness symbol check tests: PASS"
