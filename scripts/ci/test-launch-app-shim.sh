#!/usr/bin/env bash
# `lv_open` (scripts/lib/launch-app.sh) hands the app the env LaunchServices
# would otherwise drop. Nothing in tier 0 launches an app, so the shim's argv is
# asserted here against a stubbed `open`, the way test-runner-node-resign.sh
# stubs codesign.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/open" <<'STUB'
#!/bin/sh
printf 'open %s\n' "$*" > "$ARGV_LOG"
STUB
chmod +x "$WORK/open"
PATH="$WORK:$PATH"
export ARGV_LOG="$WORK/argv"

# shellcheck source=scripts/lib/launch-app.sh
source "$ROOT_DIR/scripts/lib/launch-app.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# An ordinary run is plain `open` — a developer's own launch keeps their keys.
unset LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN
lv_open -n /tmp/localvoxtral.app
[ "$(cat "$ARGV_LOG")" = "open -n /tmp/localvoxtral.app" ] \
  || fail "unflagged launch changed: $(cat "$ARGV_LOG")"

# A flagged lane passes the variable through, before the caller's own flags.
LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 lv_open -n /tmp/localvoxtral.app
[ "$(cat "$ARGV_LOG")" = "open --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 -n /tmp/localvoxtral.app" ] \
  || fail "flagged launch did not forward the env: $(cat "$ARGV_LOG")"

# Only the exact opt-in counts: a stray empty or "0" must not silence the app's
# keychain on a lane that meant to use it.
for value in "" "0" "true"; do
  LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN="$value" lv_open /tmp/localvoxtral.app
  [ "$(cat "$ARGV_LOG")" = "open /tmp/localvoxtral.app" ] \
    || fail "value '$value' was treated as the opt-in: $(cat "$ARGV_LOG")"
done

# Every lane that opens the bundle must go through the shim.
unset LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN
LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=/tmp/a.wav lv_open -n /tmp/localvoxtral.app
[ "$(cat "$ARGV_LOG")" = "open --env LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=/tmp/a.wav -n /tmp/localvoxtral.app" ] \
  || fail "audio file was not forwarded: $(cat "$ARGV_LOG")"

LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=/tmp/a.wav lv_open /tmp/localvoxtral.app
[ "$(cat "$ARGV_LOG")" = "open --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 --env LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=/tmp/a.wav /tmp/localvoxtral.app" ] \
  || fail "both flags were not forwarded: $(cat "$ARGV_LOG")"

LOCALVOXTRAL_DOGFOOD_AUDIO_FILE="" lv_open /tmp/localvoxtral.app
[ "$(cat "$ARGV_LOG")" = "open /tmp/localvoxtral.app" ] \
  || fail "an empty audio file was forwarded: $(cat "$ARGV_LOG")"

for script in scripts/ui-smoke.sh scripts/e2e-dictation.sh scripts/record-demo.sh scripts/capture-readme-assets.sh; do
  if grep -nE '^[[:space:]]*open (-n )?"\$APP' "$ROOT_DIR/$script"; then
    fail "$script opens the app bundle directly; use lv_open"
  fi
  grep -q 'lib/launch-app.sh' "$ROOT_DIR/$script" || fail "$script does not source the shim"
done

echo "PASS: launch-app shim"
