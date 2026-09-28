#!/usr/bin/env bash
# Regression test for the remote host's `localvoxtral doctor` (#910): the
# remote plugin's hooks/doctor.sh, reached through bin/localvoxtral.
#
# Runs it in an isolated HOME against a fake listener (python3, loopback, an
# unused port) that answers like the Mac's: 401 without the token, the Mac's
# checks with it. Checks each dead end names its fix, the exit status, the
# JSON form, and that the token never reaches curl's argv or the output.
#
# Needs python3 and curl, no network:
#   ./scripts/ci/test-remote-doctor.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PLUGIN="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote"
TOKEN="unit-test-token-Zq8"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-doctor-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
SERVER_PID=""
SLEEPER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  [ -z "$SLEEPER_PID" ] || kill "$SLEEPER_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

command -v curl >/dev/null || fail "needs curl"
command -v python3 >/dev/null || fail "needs python3"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# --- Fake listener: the Mac's answers ------------------------------------------
cat >"$TMP_DIR/server.py" <<'EOF'
import http.server, os, sys
token, body_file = sys.argv[2], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer " + token:
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
        json = "application/json" in (self.headers.get("Accept") or "")
        with open(body_file + (".json" if json else ".txt"), "rb") as f:
            body = f.read()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
printf '1. [ok  ] App: localvoxtral 1.4.0.\n2. [FAIL] Accessibility: Not allowed.\n\n1 failed, 0 to look at.\n' \
  >"$TMP_DIR/mac-fail.txt"
printf '{"cli":1,"ok":true,"doctor":{"checks":[{"id":"app","state":"ok","title":"App","detail":"localvoxtral 1.4.0."}]}}\n' \
  >"$TMP_DIR/mac-ok.json"
printf '1. [ok  ] App: localvoxtral 1.4.0.\n\nNo problems found.\n' >"$TMP_DIR/mac-ok.txt"

start_server() {
  python3 "$TMP_DIR/server.py" "$PORT" "$TOKEN" "$TMP_DIR/$1" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "the fake listener did not start"
}
stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

# --- The host: an isolated HOME -------------------------------------------------
HOME_DIR="$TMP_DIR/home"
CLAUDE_DIR="$HOME_DIR/.claude"
mkdir -p "$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.21.0/.in_use" \
  "$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.22.0/.in_use" "$TMP_DIR/run/localvoxtral"
write_settings() {
  cat >"$CLAUDE_DIR/settings.json" <<EOF
{
  "enabledPlugins": { "localvoxtral-remote@localvoxtral": $1 },
  "pluginConfigs": { "localvoxtral-remote@localvoxtral": { "options": { "port": "$PORT" } } }
}
EOF
}
write_token() {
  printf '{"claudeAiOauth":{"accessToken":"not-ours"},"pluginSecrets":{"localvoxtral-remote@localvoxtral":{"token":"%s"}}}' \
    "$1" >"$CLAUDE_DIR/.credentials.json"
}
cat >"$CLAUDE_DIR/plugins/installed_plugins.json" <<'EOF'
{"version":2,"plugins":{"localvoxtral-remote@localvoxtral":[{"scope":"user","version":"1.22.0","installPath":"x"}]}}
EOF
echo "ok $(date +%s)" >"$TMP_DIR/run/localvoxtral/hook-status"

# A curl that logs its argv, then runs the real one.
REAL_CURL="$(command -v curl)"
mkdir -p "$TMP_DIR/stub"
cat >"$TMP_DIR/stub/curl" <<EOF
#!/bin/sh
echo "\$*" >>"$TMP_DIR/argv.log"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$TMP_DIR/stub/curl"

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

# run_doctor [args]: prints the output, sets STATUS.
run_doctor() {
  set +e
  OUT="$(env -i PATH="$TMP_DIR/stub:$PATH" HOME="$HOME_DIR" XDG_RUNTIME_DIR="$TMP_DIR/run" \
    "$SH" "$PLUGIN/bin/localvoxtral" doctor "$@" 2>&1)"
  STATUS=$?
  set -e
  case "$OUT" in *"$TOKEN"*) fail "$SH_NAME: the token is in doctor's output" ;; esac
}

expect_line() {
  printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "$SH_NAME, $2: no line '$1' in:
$OUT"
}

for SH in "${SHELLS[@]}"; do
  case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac
  rm -f "$TMP_DIR/argv.log"
  write_settings true
  write_token "$TOKEN"

  # Nothing listens: no ssh session holds the forward.
  run_doctor
  expect_line "[FAIL] Tunnel: Nothing listens on 127.0.0.1:$PORT" "no listener"
  expect_line "Keep the tunnel open" "no listener"
  [ "$STATUS" = 4 ] || fail "$SH_NAME, no listener: exit $STATUS, want 4"
  pass "$SH_NAME: nothing listening fails the tunnel check, exit 4"

  # The Mac answers, and its own checks come through.
  start_server mac-ok
  run_doctor
  expect_line "[ok  ] Tunnel: 127.0.0.1:$PORT reaches localvoxtral" "healthy"
  expect_line "[ok  ] Token: Accepted (from $CLAUDE_DIR/.credentials.json)." "healthy"
  expect_line "[ok  ] Claude Code plugin: 1.22.0 installed; 0 running session(s)" "healthy"
  expect_line "The Mac:" "healthy"
  expect_line "No problems found." "healthy"
  [ "$STATUS" = 0 ] || fail "$SH_NAME, healthy: exit $STATUS, want 0:
$OUT"
  pass "$SH_NAME: a healthy host prints both halves, exit 0"

  run_doctor --json
  printf '%s' "$OUT" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["ok"] is True
assert [c["id"] for c in doc["host"]["checks"]] == ["tunnel", "token", "claude-plugin", "vibe-hooks", "last-hook"], doc
assert doc["mac"]["doctor"]["checks"][0]["id"] == "app", doc
' || fail "$SH_NAME, --json: not the expected document:
$OUT"
  pass "$SH_NAME: --json nests the Mac's answer under mac"
  stop_server

  # A failed check on the Mac fails the host's run too.
  start_server mac-fail
  run_doctor
  expect_line "2. [FAIL] Accessibility: Not allowed." "Mac fails"
  [ "$STATUS" = 4 ] || fail "$SH_NAME, Mac fails: exit $STATUS, want 4"
  pass "$SH_NAME: a Mac check that fails exits 4"

  # A token the Mac does not know.
  write_token "rotated-token"
  run_doctor
  expect_line "[FAIL] Token: Refused" "wrong token"
  expect_line "Update Host…" "wrong token"
  pass "$SH_NAME: a refused token names Update Host…"
  write_token "$TOKEN"

  # A session still on the old plugin, and the plugin turned off.
  sleep 60 &
  SLEEPER_PID=$!
  : >"$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.21.0/.in_use/$SLEEPER_PID"
  run_doctor
  expect_line "running sessions still on older versions (version:pid): 1.21.0:$SLEEPER_PID" "old session"
  pass "$SH_NAME: a live session on an older plugin is named"
  kill "$SLEEPER_PID" 2>/dev/null || true
  wait "$SLEEPER_PID" 2>/dev/null || true
  SLEEPER_PID=""
  rm -f "$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.21.0/.in_use/"*
  write_settings false
  run_doctor
  expect_line "[FAIL] Claude Code plugin: 1.22.0 is installed but turned off" "disabled"
  pass "$SH_NAME: a disabled plugin fails its check"
  stop_server

  # The token stays out of every argv and out of the output.
  if grep -qF "$TOKEN" "$TMP_DIR/argv.log"; then fail "$SH_NAME: the token reached curl's argv"; fi
  pass "$SH_NAME: the token never reached an argv"
done

# Other verbs point at the Mac.
set +e
OUT="$(sh "$PLUGIN/bin/localvoxtral" history last 2>&1)"
STATUS=$?
set -e
[ "$STATUS" = 2 ] || fail "history on a host: exit $STATUS, want 2"
printf '%s' "$OUT" | grep -qF "run on the Mac" || fail "history on a host: $OUT"
pass "other commands say they run on the Mac"
