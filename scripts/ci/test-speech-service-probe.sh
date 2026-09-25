#!/usr/bin/env bash
# e2e-dictation.sh calls a failure NOT RUN only when speech-service-probe.py
# finds the shared speech service lagging (#548). This runs the probe against
# a fake service that answers on time, late, with an error, and not at all,
# and pins the limit to the app constant it is derived from.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT_DIR/scripts/e2e/speech-service-probe.py"
FAKE="$ROOT_DIR/scripts/ci/fake-speech-service.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-speech-probe-test.XXXXXX")"
PIDS=()
cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# One second of 16 kHz mono PCM16, what `say -o … LEI16@16000` writes.
python3 - "$WORK/clip.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"\x01\x00" * 16000)
PY

start_fake() {
  # start_fake <lag-seconds> [error]: sets PORT.
  local port_file="$WORK/port.$RANDOM"
  python3 "$FAKE" "$port_file" "$@" &
  PIDS+=("$!")
  local tries=0
  while [ ! -s "$port_file" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "the fake service did not start"
    python3 -c 'import time; time.sleep(0.05)'
  done
  PORT="$(cat "$port_file")"
}

probe() {
  # probe <port>: sets OUT and STATUS. 2 s of silence, like the check.
  set +e
  OUT="$(LV_E2E_PROBE_TIMEOUT=15 python3 "$PROBE" "ws://127.0.0.1:$1/v1/realtime" test-model "$WORK/clip.wav" 2 2>&1)"
  STATUS=$?
  set -e
}

lag_of() { sed -n 's/^lag=\([-0-9.]*\) .*/\1/p' <<<"$1"; }

# The limit e2e-dictation.sh compares against: its post-drain silence plus the
# app's minimum finalization wait, which must stay the app's real value.
minimum_open="$(sed -n 's/^APP_FINALIZATION_MINIMUM_OPEN_SECONDS=//p' "$ROOT_DIR/scripts/e2e-dictation.sh")"
app_value="$(sed -n 's/.*static let finalizationMinimumOpen: TimeInterval = \([0-9.]*\).*/\1/p' \
  "$ROOT_DIR/Sources/localvoxtral/TimingConstants.swift")"
[ -n "$app_value" ] || fail "TimingConstants.finalizationMinimumOpen not found"
[ "$minimum_open" = "$app_value" ] \
  || fail "e2e-dictation.sh assumes a $minimum_open s minimum finalization wait; the app has $app_value s"
echo "PASS: the lag limit uses the app's minimum finalization wait ($app_value s)"

start_fake 0.2
probe "$PORT"
[ "$STATUS" -eq 0 ] || fail "a service on time: exit $STATUS: $OUT"
lag="$(lag_of "$OUT")"
awk -v l="$lag" 'BEGIN { exit !(l >= 1.8 && l < 3.0) }' \
  || fail "a service 0.2 s behind after 2 s of silence measured lag '$lag': $OUT"
grep -q "text=word0" <<<"$OUT" || fail "the final transcript was not printed: $OUT"
echo "PASS: a service on time measures $lag s (the 2 s of silence plus its 0.2 s)"

start_fake 4
probe "$PORT"
[ "$STATUS" -eq 0 ] || fail "a late service: exit $STATUS: $OUT"
lag="$(lag_of "$OUT")"
awk -v l="$lag" 'BEGIN { exit !(l >= 5.5 && l < 7.0) }' \
  || fail "a service 4 s behind after 2 s of silence measured lag '$lag': $OUT"
echo "PASS: a late service measures $lag s"

start_fake 0 error
probe "$PORT"
[ "$STATUS" -eq 2 ] || fail "a service error exited $STATUS, want 2: $OUT"
grep -q "engine failed" <<<"$OUT" || fail "the service's error was not reported: $OUT"
echo "PASS: a service error measures nothing (exit 2)"

closed_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
probe "$closed_port"
[ "$STATUS" -eq 2 ] || fail "a closed port exited $STATUS, want 2: $OUT"
echo "PASS: no service measures nothing (exit 2)"

echo "speech service probe tests passed"
