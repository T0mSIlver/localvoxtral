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
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        if os.path.exists(body_file + ".failed"):
            with open(body_file + ".failed") as f:
                self.send_header("X-Lvx-Doctor-Failed", f.read().strip())
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
printf '1. [ok  ] App: localvoxtral 1.4.0.\n2. [FAIL] Accessibility: Not allowed.\n\n1 failed, 0 to look at.\n' \
  >"$TMP_DIR/mac-fail.txt"
printf '{"cli":1,"ok":true,"doctor":{"checks":[{"id":"app","state":"ok","title":"App","detail":"localvoxtral 1.4.0."}]}}\n' \
  >"$TMP_DIR/mac-ok.json"
printf '{"cli":1,"ok":true,"doctor":{"checks":[{"id":"app","state":"ok","title":"App","detail":"localvoxtral 1.4.0."},{"id":"accessibility","state":"failed","title":"Accessibility","detail":"Not allowed."}]}}\n' \
  >"$TMP_DIR/mac-fail.json"
printf '1. [ok  ] App: localvoxtral 1.4.0.\n\nNo problems found.\n' >"$TMP_DIR/mac-ok.txt"
echo 0 >"$TMP_DIR/mac-ok.failed"
echo 1 >"$TMP_DIR/mac-fail.failed"
# A report whose wording the host does not know, and a Mac older than the
# X-Lvx-Doctor-Failed header (no .failed file): the exit status comes from
# the header, and only without it from the report.
printf '1. [ok  ] App: localvoxtral 1.4.0.\n2. [broken] Accessibility: Not allowed.\n' >"$TMP_DIR/mac-reworded.txt"
echo 1 >"$TMP_DIR/mac-reworded.failed"
cp "$TMP_DIR/mac-fail.txt" "$TMP_DIR/mac-old.txt"

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
write_installed() {
  printf '{"version":2,"plugins":{"localvoxtral-remote@localvoxtral":[{"scope":"user","version":"%s","installPath":"x"}]}}\n' \
    "$1" >"$CLAUDE_DIR/plugins/installed_plugins.json"
}
write_installed 1.22.0
HOOK_VERSION="$(sed -n 's/^PLUGIN_VERSION=//p' "$PLUGIN/hooks/post.sh")"
[ -n "$HOOK_VERSION" ] || fail "post.sh has no PLUGIN_VERSION"
SESSION_ID="0b5e7d1c-9a3f-4e2b-8c6d-1f2e3a4b5c6d"
# write_session_record PID SESSION_ID [SKEW]: Claude Code's record of a live
# session. On Linux it carries the process start time, off by SKEW ticks to
# stand for a pid reused since; without /proc a reused pid cannot be faked.
write_session_record() {
  _start=""
  if [ -r "/proc/$1/stat" ]; then
    _start="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat")"
    _start=$((_start + ${3:-0}))
  elif [ -n "${3:-}" ]; then
    _start=1
  fi
  mkdir -p "$CLAUDE_DIR/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.286","kind":"interactive"}\n' \
    "$1" "$2" "$_start" >"$CLAUDE_DIR/sessions/$1.json"
}
# A stand-in for a running Claude Code: a copy of sleep named claude, since
# without /proc the doctor takes only a claude command for a session.
mkdir -p "$TMP_DIR/bin"
cp "$(command -v sleep)" "$TMP_DIR/bin/claude"
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

# A here-string, not a pipe: grep -q exits at its first match, and under
# pipefail a printf still writing the rest fails the check (#976).
expect_line() {
  grep -qF -- "$1" <<<"$OUT" || fail "$SH_NAME, $2: no line '$1' in:
$OUT"
}

# expect_state SECTION ID STATE CASE: `doctor --json` reports check ID in
# SECTION (host, or mac for the Mac's own checks) as STATE. The prose
# assertions pin what a person reads; this pins the same verdict in the form
# a program reads, so a reword breaks only the prose half.
expect_state() {
  local line_out="$OUT"
  run_doctor --json
  python3 -c '
import json, sys
section, want_id, want_state = sys.argv[1:4]
doc = json.load(sys.stdin)
checks = doc["host"]["checks"] if section == "host" else doc["mac"]["doctor"]["checks"]
states = {c["id"]: c["state"] for c in checks}
sys.exit(0 if states.get(want_id) == want_state else "%s.%s is %r, want %r" % (section, want_id, states.get(want_id), want_state))
' "$1" "$2" "$3" <<<"$OUT" || fail "$SH_NAME, $4, --json:
$OUT"
  OUT="$line_out"
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
  expect_state host tunnel failed "no listener"
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
  expect_state host tunnel ok "healthy"
  expect_state host token ok "healthy"
  expect_state mac app ok "healthy"
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
  expect_state mac accessibility failed "Mac fails"
  expect_state host token ok "Mac fails"
  pass "$SH_NAME: a Mac check that fails exits 4"
  stop_server

  start_server mac-reworded
  run_doctor
  [ "$STATUS" = 4 ] || fail "$SH_NAME, Mac fails, report reworded: exit $STATUS, want 4"
  pass "$SH_NAME: the Mac's failed count sets the exit status, whatever the report says"
  stop_server

  start_server mac-old
  run_doctor
  [ "$STATUS" = 4 ] || fail "$SH_NAME, Mac without the header fails: exit $STATUS, want 4"
  pass "$SH_NAME: a Mac without the failed-count header still fails the run on its report"
  stop_server
  start_server mac-fail

  # A token the Mac does not know.
  write_token "rotated-token"
  run_doctor
  expect_line "[FAIL] Token: Refused" "wrong token"
  expect_line "Update Host…" "wrong token"
  expect_state host token failed "wrong token"
  pass "$SH_NAME: a refused token names Update Host…"
  write_token "$TOKEN"

  # A session still on the old plugin, and the plugin turned off.
  "$TMP_DIR/bin/claude" 60 &
  SLEEPER_PID=$!
  : >"$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.21.0/.in_use/$SLEEPER_PID"
  run_doctor
  expect_line "running sessions still on older versions (version:pid): 1.21.0:$SLEEPER_PID" "old session"
  expect_state host claude-plugin warning "old session"
  pass "$SH_NAME: a live session on an older plugin is named"
  # After `/reload-plugins` the same session also has a marker under the
  # installed version.
  : >"$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.22.0/.in_use/$SLEEPER_PID"
  run_doctor
  expect_line "[ok  ] Claude Code plugin: 1.22.0 installed; 1 running session(s), none on an older version." "reloaded session"
  expect_state host claude-plugin ok "reloaded session"
  pass "$SH_NAME: a session reloaded onto the installed plugin is current"
  rm -f "$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.22.0/.in_use/"*
  rm -f "$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote/1.21.0/.in_use/"*

  # Claude Code 2.1.280 and later write no marker (#1159): the session is
  # in Claude Code's sessions/<pid>.json, and its version in the record the
  # plugin's hook keeps under its session id.
  write_session_record "$SLEEPER_PID" "$SESSION_ID"
  run_doctor
  expect_line "running sessions with no plugin version recorded (pid): $SLEEPER_PID." "unrecorded session"
  expect_state host claude-plugin warning "unrecorded session"
  pass "$SH_NAME: a live session that recorded no plugin version is named"
  mkdir -p "$TMP_DIR/run/localvoxtral/plugin-version"
  printf '1.21.0\n' >"$TMP_DIR/run/localvoxtral/plugin-version/$SESSION_ID"
  run_doctor
  expect_line "running sessions still on older versions (version:pid): 1.21.0:$SLEEPER_PID." "recorded old session"
  expect_state host claude-plugin warning "recorded old session"
  pass "$SH_NAME: a live session whose hook recorded an older plugin is named"
  # The shipped hook records its own version; installed, that is current.
  printf '{"hook_event_name":"SessionStart","session_id":"%s"}' "$SESSION_ID" \
    | env -i PATH="$PATH" HOME="$HOME_DIR" XDG_RUNTIME_DIR="$TMP_DIR/run" "$SH" "$PLUGIN/hooks/post.sh" SessionStart
  write_installed "$HOOK_VERSION"
  run_doctor
  expect_line "[ok  ] Claude Code plugin: $HOOK_VERSION installed; 1 running session(s), none on an older version." "recorded current session"
  expect_state host claude-plugin ok "recorded current session"
  pass "$SH_NAME: the hook's own record makes its session current"
  write_installed 1.22.0
  # A pid reused by another process is not the session.
  write_session_record "$SLEEPER_PID" "$SESSION_ID" 1
  run_doctor
  expect_line "[ok  ] Claude Code plugin: 1.22.0 installed; 0 running session(s), none on an older version." "reused pid"
  pass "$SH_NAME: a session record whose pid was reused counts nothing"
  rm -f "$CLAUDE_DIR/sessions/"* "$TMP_DIR/run/localvoxtral/plugin-version/"*
  kill "$SLEEPER_PID" 2>/dev/null || true
  wait "$SLEEPER_PID" 2>/dev/null || true
  SLEEPER_PID=""
  write_settings false
  run_doctor
  expect_line "[FAIL] Claude Code plugin: 1.22.0 is installed but turned off" "disabled"
  expect_state host claude-plugin failed "disabled"
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
grep -qF "run on the Mac" <<<"$OUT" || fail "history on a host: $OUT"
pass "other commands say they run on the Mac"
