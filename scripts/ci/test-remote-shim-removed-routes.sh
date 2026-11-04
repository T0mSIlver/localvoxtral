#!/usr/bin/env bash
# Regression test for removing quick capture: a host keeps running the remote
# shim it was enrolled with until the plugin updates, and that shim's
# capture.sh (plugin 1.45.0, frozen in fixtures/remote-shim-1.45.0) still
# posts to the routes quick capture served: /v1/readme and /v1/draft/*.
# The Mac's listener answers them 410 now (RemoteProjectReportsTests pins the
# status). This runs the frozen script against a listener that answers 410,
# the way the old shim's two asks reach it, and requires what a host user
# sees: exit status 0 and not one byte on stdout or stderr, whatever the
# route said.
#
# Needs python3, curl and git, no network:
#   ./scripts/ci/test-remote-shim-removed-routes.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
OLD_CAPTURE="$ROOT_DIR/scripts/ci/fixtures/remote-shim-1.45.0/capture.sh"
TOKEN="unit-test-token-Rr7"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-removed-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
LISTENER_PID=""
cleanup() {
  [ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

command -v curl >/dev/null || fail "needs curl"
command -v python3 >/dev/null || fail "needs python3"
[ -r "$OLD_CAPTURE" ] || fail "the frozen 1.45.0 capture.sh is missing"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# A listener that answers every POST with 410 and logs "<path> <authorized>".
cat >"$TMP_DIR/listener.py" <<'PY'
import http.server, sys
port_file, log_file, token = sys.argv[1:4]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length: self.rfile.read(length)
        auth = "token" if self.headers.get("Authorization") == "Bearer " + token else "no-token"
        with open(log_file, "a") as f:
            f.write("%s %s\n" % (self.path, auth))
        self.send_response(410)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f: f.write(str(server.server_address[1]))
import os; os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY
python3 "$TMP_DIR/listener.py" "$TMP_DIR/port" "$TMP_DIR/log" "$TOKEN" &
LISTENER_PID=$!
i=0
while [ ! -s "$TMP_DIR/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$TMP_DIR/port" ] || fail "the listener did not start"
PORT="$(cat "$TMP_DIR/port")"
: >"$TMP_DIR/log"

git init -q "$TMP_DIR/repo"
printf '# Quill\n\nQuill typesets Markdown.\n' >"$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add -A
git -C "$TMP_DIR/repo" commit -q -m init
mkdir -p "$TMP_DIR/home" "$TMP_DIR/lock"

# run_old <mode args...>: the old script as the old shim starts it, in a clean
# environment with the token on stdin. Prints its exit status; stdout and
# stderr land in files.
run_old() {
  local status=0
  (
    cd "$TMP_DIR/repo"
    printf '%s\n' "$TOKEN" | env -i HOME="$TMP_DIR/home" PATH="$PATH" LANG=C.UTF-8 USER=tester \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      sh "$OLD_CAPTURE" "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
  ) || status=$?
  printf '%s' "$status"
}

SESSION=6f1c2d3e-aaaa-bbbb-cccc-0123456789ab
DRAFT_ID=0123456789abcdef0123456789abcdef

# 1. The README ask.
status="$(run_old readme claude "$PORT" "$SESSION" "$TMP_DIR/repo")"
[ "$status" = 0 ] || fail "readme ask: exit status $status"
[ ! -s "$TMP_DIR/stdout" ] && [ ! -s "$TMP_DIR/stderr" ] || fail "readme ask printed something"
grep -qx '/v1/readme token' "$TMP_DIR/log" || fail "readme ask: the old shim did not reach /v1/readme:
$(cat "$TMP_DIR/log")"
pass "the old README ask gets 410, exits 0 and prints nothing"

# 2. The draft ask, which falls back from the words route to the prompt route.
: >"$TMP_DIR/log"
mkdir -p "$TMP_DIR/lock/capture/draft-running"
status="$(run_old draft claude "$PORT" "$SESSION" "$TMP_DIR/repo" "$DRAFT_ID" "$TMP_DIR/lock/capture/draft-running")"
[ "$status" = 0 ] || fail "draft ask: exit status $status"
[ ! -s "$TMP_DIR/stdout" ] && [ ! -s "$TMP_DIR/stderr" ] || fail "draft ask printed something"
grep -qx '/v1/draft/words token' "$TMP_DIR/log" && grep -qx '/v1/draft/prompt token' "$TMP_DIR/log" \
  || fail "draft ask: the old shim did not try both routes:
$(cat "$TMP_DIR/log")"
if grep -qx '/v1/draft token' "$TMP_DIR/log"; then fail "draft ask: an answer was posted with no prompt"; fi
[ ! -d "$TMP_DIR/lock/capture/draft-running" ] || fail "draft ask: the shim's draft lock was left behind"
pass "the old draft ask gets 410 on both routes, exits 0, prints nothing and frees its lock"

echo "remote shim removed routes: all checks passed"
