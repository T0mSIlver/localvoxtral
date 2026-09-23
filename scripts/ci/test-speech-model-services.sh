#!/usr/bin/env bash
# Regression tests for the per-model speech test services (#487): one
# LaunchAgent and port per row of scripts/mac/test-speech-models.tsv, warmed by
# lv-test-servers.sh, by the build gate's `ensure` verb, and by
# `remote-build.sh eval-e2e --asr <name>`. Voxtral must keep its pre-list
# trigger, label, port and log, which CI and an older gate still use.
#
# launchctl, nc, curl, ssh and rsync are stubbed to log their arguments.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SERVERS="$ROOT_DIR/scripts/mac/lv-test-servers.sh"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-speech-services-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

VOXTRAL_REVISION=247f2eeccf962fbcaf85e361731a5e75b2d8cac1
NEMOTRON_REVISION=7279359e4481b5e9e185a318bd618e429c6d86cd
LIST="$TMP_DIR/models.tsv"
cat >"$LIST" <<LIST
# name	port	repo	revision
voxtral	8000	T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead	$VOXTRAL_REVISION
nemotron	8001	mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit	$NEMOTRON_REVISION
LIST

CALLS="$TMP_DIR/calls.log"
mkdir -p "$TMP_DIR/bin"
# nc succeeds, so every port looks warm; curl fails, so polishd looks down.
for tool in launchctl nc ssh rsync; do
  cat >"$TMP_DIR/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"$CALLS"
exit 0
STUB
done
cat >"$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$TMP_DIR/bin/"*

RUN="$TMP_DIR/run"
AGENTS="$TMP_DIR/LaunchAgents"
INSTALLED="$TMP_DIR/testservers/speech-models.tsv"
mkdir -p "$RUN" "$AGENTS"
servers() {
  env PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
    LV_TEST_SPEECH_MODELS="$LIST" \
    LV_TEST_SPEECH_MODELS_INSTALLED="$INSTALLED" \
    LV_TEST_LAUNCH_AGENTS_DIR="$AGENTS" \
    LV_TEST_SERVER_RUN_DIR="$RUN" \
    LV_TEST_SERVER_LOG_DIR="$TMP_DIR/logs" \
    LV_TEST_SERVER_APP="$TMP_DIR/app/localvoxtral.app" \
    bash "$SERVERS" "$@"
}
assert_has() {
  grep -qF -- "$2" "$1" || fail "$1 lacks \"$2\": $(cat "$1")"
}

# ---- install-speech-models ---------------------------------------------------

# A plist from a row that was removed since the last install.
touch "$AGENTS/com.localvoxtral.testspeechd-retired.plist" "$RUN/speechd-retired.want"
: >"$CALLS"
servers install-speech-models >"$TMP_DIR/out" 2>&1 || fail "install failed: $(cat "$TMP_DIR/out")"

voxtral_plist="$AGENTS/com.localvoxtral.testspeechd.plist"
nemotron_plist="$AGENTS/com.localvoxtral.testspeechd-nemotron.plist"
[[ -f "$voxtral_plist" && -f "$nemotron_plist" ]] || fail "install wrote $(ls "$AGENTS")"
assert_has "$voxtral_plist" "<key>$RUN/voxmlx.want</key>"
assert_has "$voxtral_plist" "<string>8000</string>"
assert_has "$voxtral_plist" "<string>$VOXTRAL_REVISION</string>"
assert_has "$voxtral_plist" "<string>$TMP_DIR/logs/speechd.log</string>"
assert_has "$voxtral_plist" "<string>$TMP_DIR/app/localvoxtral.app/Contents/MacOS/localvoxtral-speechd</string>"
assert_has "$nemotron_plist" "<string>com.localvoxtral.testspeechd-nemotron</string>"
assert_has "$nemotron_plist" "<key>$RUN/speechd-nemotron.want</key>"
assert_has "$nemotron_plist" "<string>8001</string>"
assert_has "$nemotron_plist" "<string>mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit</string>"
assert_has "$nemotron_plist" "<string>$TMP_DIR/logs/speechd-nemotron.log</string>"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$voxtral_plist" "$nemotron_plist" >/dev/null || fail "plutil rejects a written plist"
fi
assert_has "$CALLS" "launchctl bootstrap gui/$(id -u) $nemotron_plist"
assert_has "$CALLS" "launchctl bootout gui/$(id -u)/com.localvoxtral.testspeechd-retired"
[[ ! -e "$AGENTS/com.localvoxtral.testspeechd-retired.plist" && ! -e "$RUN/speechd-retired.want" ]] \
  || fail "a removed row's plist or trigger survived the install"
cmp -s "$LIST" "$INSTALLED" || fail "the gate's copy of the list differs from the source"
assert_has "$TMP_DIR/out" "hf download mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit --revision $NEMOTRON_REVISION"

# One row only: the other plists stay as they are.
rm "$voxtral_plist"
servers install-speech-models nemotron >"$TMP_DIR/out" 2>&1 || fail "single-row install failed"
[[ ! -e "$voxtral_plist" ]] || fail "a single-row install rewrote another row"
status=0
servers install-speech-models bogus >"$TMP_DIR/out" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "install of an unknown row exited $status, expected 2"

# A malformed row fails the whole install instead of dropping that model.
cp "$LIST" "$TMP_DIR/good.tsv"
printf 'bad\t80;id\towner/repo\t%s\n' "$NEMOTRON_REVISION" >>"$LIST"
rm -f "$AGENTS"/*.plist
status=0
servers install-speech-models >"$TMP_DIR/out" 2>&1 || status=$?
[[ "$status" != 0 ]] || fail "a malformed row was accepted"
[[ -z "$(ls "$AGENTS")" ]] || fail "a malformed list still wrote plists"
cp "$TMP_DIR/good.tsv" "$LIST"

# ---- ensure / status ---------------------------------------------------------

: >"$CALLS"
servers ensure speechd-nemotron >"$TMP_DIR/out" 2>&1 || fail "ensure speechd-nemotron failed: $(cat "$TMP_DIR/out")"
[[ -e "$RUN/speechd-nemotron.want" && -e "$RUN/speechd-nemotron.seen.$(id -u)" ]] \
  || fail "ensure speechd-nemotron made no trigger or stamp: $(ls "$RUN")"
assert_has "$CALLS" "127.0.0.1 8001"
servers ensure speechd >"$TMP_DIR/out" 2>&1 || fail "ensure speechd failed"
[[ -e "$RUN/voxmlx.want" ]] || fail "ensure speechd did not use the voxmlx trigger"
assert_has "$CALLS" "127.0.0.1 8000"
status=0
servers ensure speechd-bogus >"$TMP_DIR/out" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "ensure of an unknown service exited $status, expected 2"

servers status >"$TMP_DIR/out" 2>&1 || fail "status failed"
for line in 'speechd-voxtral' 'speechd-nemotron' 'port 8001: up' 'polishd'; do
  assert_has "$TMP_DIR/out" "$line"
done

# ---- build gate --------------------------------------------------------------

gate_home="$TMP_DIR/gate-home"
mkdir -p "$gate_home/Library/Logs" "$TMP_DIR/gate-run"
cat >"$gate_home/.localvoxtral-gate.conf" <<CONF
LV_RUN_DIR=$TMP_DIR/gate-run
LV_SPEECH_MODELS_FILE=$INSTALLED
CONF
gate() {
  env PATH="$TMP_DIR/bin:$PATH" HOME="$gate_home" SSH_ORIGINAL_COMMAND="$1" bash "$GATE"
}

: >"$CALLS"
gate 'ensure speechd-nemotron' >"$TMP_DIR/out" 2>&1 || fail "gate ensure speechd-nemotron failed: $(cat "$TMP_DIR/out")"
[[ -e "$TMP_DIR/gate-run/speechd-nemotron.want" ]] || fail "gate made no speechd-nemotron trigger"
assert_has "$CALLS" "127.0.0.1 8001"
for name in speechd speechd-voxtral; do
  : >"$CALLS"
  gate "ensure $name" >"$TMP_DIR/out" 2>&1 || fail "gate ensure $name failed"
  [[ -e "$TMP_DIR/gate-run/voxmlx.want" ]] || fail "gate ensure $name missed the voxmlx trigger"
  assert_has "$CALLS" "127.0.0.1 8000"
done

# Voxtral does not depend on the installed list.
mv "$INSTALLED" "$INSTALLED.away"
gate 'ensure speechd' >"$TMP_DIR/out" 2>&1 || fail "gate ensure speechd needs the list"
mv "$INSTALLED.away" "$INSTALLED"

assert_gate_denied() {
  local status=0
  gate "$1" >/dev/null 2>&1 || status=$?
  [[ "$status" == 126 ]] || fail "gate '$1' exited $status instead of 126"
}
assert_gate_denied 'ensure speechd-bogus'
assert_gate_denied 'ensure speechd-Nemotron'
assert_gate_denied 'ensure speechd-'
assert_gate_denied 'ensure speechd-../x'
printf 'evil\t80;id\towner/repo\t%s\n' "$NEMOTRON_REVISION" >>"$INSTALLED"
assert_gate_denied 'ensure speechd-evil'
cp "$LIST" "$INSTALLED"

# ---- remote-build.sh eval-e2e --asr -------------------------------------------

marker="$ROOT_DIR/.agent-eval-e2e-enable.json"
[[ ! -e "$marker" ]] || fail "a stale $marker exists; remove it before running this test"
cat >"$TMP_DIR/bin/rsync" <<STUB
#!/usr/bin/env bash
printf 'rsync %s\n' "\$*" >>"$CALLS"
[[ -f "$marker" ]] && cat "$marker" >>"$CALLS"
exit 0
STUB
chmod +x "$TMP_DIR/bin/rsync"
remote_build() {
  env PATH="$TMP_DIR/bin:$PATH" LV_BUILD_HOST=fake-host \
    LV_BUILD_DIR=work/localvoxtral-speech-services-test \
    LV_TEST_SPEECH_MODELS="$LIST" \
    LOCALVOXTRAL_REMOTE_LOG="$TMP_DIR/remote-build.log" \
    LOCALVOXTRAL_GC_LOG="$TMP_DIR/last-gc.log" \
    "$REMOTE_BUILD" eval-e2e "$@"
}

: >"$CALLS"
remote_build --asr nemotron >"$TMP_DIR/out" 2>&1 || fail "eval-e2e --asr nemotron failed: $(cat "$TMP_DIR/out")"
assert_has "$CALLS" "ssh fake-host ensure speechd-nemotron"
assert_has "$CALLS" '"voxmlxEndpoint": "ws://127.0.0.1:8001/v1/realtime"'
assert_has "$CALLS" '"asrModel": "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"'
[[ ! -e "$marker" ]] || fail "eval-e2e left its marker behind"

: >"$CALLS"
remote_build >"$TMP_DIR/out" 2>&1 || fail "eval-e2e without --asr failed"
assert_has "$CALLS" "ssh fake-host ensure speechd"
assert_has "$CALLS" '"voxmlxEndpoint": "ws://127.0.0.1:8000/v1/realtime"'
assert_has "$CALLS" '"asrModel": "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"'

assert_eval_refused() {
  local expected="$1" status=0
  shift
  : >"$CALLS"
  MISTRAL_API_KEY=unused remote_build "$@" >"$TMP_DIR/out" 2>&1 || status=$?
  [[ "$status" == 1 ]] || fail "eval-e2e $* exited $status, expected 1"
  [[ ! -s "$CALLS" ]] || fail "refused eval-e2e $* still reached the host: $(cat "$CALLS")"
  assert_has "$TMP_DIR/out" "$expected"
}
assert_eval_refused "no speech model 'bogus'" --asr bogus
assert_eval_refused "--provider mistral uses none" --asr nemotron --provider mistral

printf 'PASS: speech test services follow the model list, in lv-test-servers, the gate and eval-e2e\n'
