#!/usr/bin/env bash
# Regression test for #1281: the remote hooks reach the Mac at 127.0.0.1, and
# curl sends even a loopback request through http_proxy, all_proxy or
# ALL_PROXY, or a proxy from ~/.curlrc. That proxy would get the bearer token
# and the prompt outside the ssh tunnel.
#
# Runs the Claude Code shim, the Vibe shim, capture.sh (through the README ask)
# and the doctor with real curl, every proxy variable set and a ~/.curlrc,
# against two loopback listeners: the Mac and a proxy. The Mac must get every
# request, the proxy none, and the ~/.curlrc must not be read. Then checks
# that every curl call in the remote hooks and the Mac's ssh probes bypasses
# proxies, so a call added later cannot leak either.
#
# Needs python3, curl and git, no network:
#   ./scripts/ci/test-remote-shim-proxy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PLUGIN="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote"
VIBE_DIR_SRC="$ROOT_DIR/integrations/vibe/remote"
TOKEN="unit-test-token-Px1"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-proxy-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
MAC_PID=""
PROXY_PID=""
cleanup() {
  [ -z "$MAC_PID" ] || kill "$MAC_PID" 2>/dev/null || true
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

command -v curl >/dev/null || fail "needs curl"
command -v python3 >/dev/null || fail "needs python3"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

wait_for() {
  local i=0
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q -- "$2" "$1" 2>/dev/null
}

# --- Listeners -----------------------------------------------------------------
# Each binds port 0, writes its port to a file, and logs one line per request:
# the request line and whether it carried the token. The Mac answers every
# hook with the README ask and the doctor with its report; the proxy answers
# 200 to anything, so a shim that went through it would still see success.
cat >"$TMP_DIR/listener.py" <<'EOF'
import http.server, sys
role, port_file, log_file, token = sys.argv[1:5]
class Handler(http.server.BaseHTTPRequestHandler):
    def handle_one(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length: self.rfile.read(length)
        auth = "token" if self.headers.get("Authorization") == "Bearer " + token else "no-token"
        with open(log_file, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, auth))
        doctor = role == "mac" and self.path == "/v1/doctor"
        body = b"1. [ok  ] App: localvoxtral.\n\nNo problems found.\n" if doctor else b"{}"
        self.send_response(401 if doctor and auth != "token" else 200)
        if role == "mac" and "/v1/hook/" in self.path:
            self.send_header("X-Lvx-Readme", "wanted")
        if doctor:
            self.send_header("X-Lvx-Doctor-Failed", "0")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_POST = do_GET = do_CONNECT = handle_one
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f: f.write(str(server.server_address[1]))
import os; os.rename(port_file + ".tmp", port_file)
server.serve_forever()
EOF
start_listener() {
  python3 "$TMP_DIR/listener.py" "$1" "$TMP_DIR/$1.port" "$TMP_DIR/$1.log" "$TOKEN" &
  local pid=$! i=0
  while [ ! -s "$TMP_DIR/$1.port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$TMP_DIR/$1.port" ] || fail "the $1 listener did not start"
  eval "$2=$pid"
}
start_listener mac MAC_PID
start_listener proxy PROXY_PID
PORT="$(cat "$TMP_DIR/mac.port")"
PROXY="http://127.0.0.1:$(cat "$TMP_DIR/proxy.port")"
: >"$TMP_DIR/mac.log"
: >"$TMP_DIR/proxy.log"

# --- The host ------------------------------------------------------------------
HOME_DIR="$TMP_DIR/home"
mkdir -p "$HOME_DIR/.claude" "$TMP_DIR/run"
# A ~/.curlrc that proxies and traces every request: -q must keep curl from
# reading it, or the token lands in the trace file.
printf 'proxy = "%s"\ntrace-ascii = "%s"\n' "$PROXY" "$TMP_DIR/curlrc-trace" >"$HOME_DIR/.curlrc"
cat >"$HOME_DIR/.claude/settings.json" <<EOF
{
  "enabledPlugins": { "localvoxtral-remote@localvoxtral": true },
  "pluginConfigs": { "localvoxtral-remote@localvoxtral": { "options": { "port": "$PORT" } } }
}
EOF
printf '{"pluginSecrets":{"localvoxtral-remote@localvoxtral":{"token":"%s"}}}' "$TOKEN" \
  >"$HOME_DIR/.claude/.credentials.json"

git init -q "$TMP_DIR/repo"
printf '# Quill\n\nQuill typesets Markdown.\n' >"$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add -A
git -C "$TMP_DIR/repo" commit -q -m init

VIBE_DIR="$TMP_DIR/vibe-remote"
mkdir -p "$VIBE_DIR" "$HOME_DIR/.vibe"
cp "$VIBE_DIR_SRC/post.sh" "$VIBE_DIR_SRC/compact.py" "$PLUGIN/hooks/terms.sh" "$PLUGIN/hooks/capture.sh" "$VIBE_DIR/"
echo "$TOKEN" >"$VIBE_DIR/token"
echo "$PORT" >"$VIBE_DIR/port"
echo 'model = "x"' >"$HOME_DIR/.vibe/config.toml"
TRANSCRIPT="$TMP_DIR/messages.jsonl"
echo '{"role": "user", "content": "rename the enum", "injected": false}' >"$TRANSCRIPT"
VIBE_PAYLOAD="{\"session_id\":\"7f4aefdf\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"$TMP_DIR/repo\",\"parent_session_id\":null,\"hook_event_name\":\"post_agent\"}"

# host_env CMD...: runs CMD in the repository with only a host's environment
# and every proxy variable curl reads pointing at the proxy.
host_env() {
  (
    cd "$TMP_DIR/repo"
    env -i PATH="$PATH" HOME="$HOME_DIR" LANG=C.UTF-8 USER=tester XDG_RUNTIME_DIR="$TMP_DIR/run" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      http_proxy="$PROXY" HTTP_PROXY="$PROXY" all_proxy="$PROXY" ALL_PROXY="$PROXY" \
      LOCALVOXTRAL_VIBE_REMOTE_DIR="$VIBE_DIR" LOCALVOXTRAL_VIBE_WATCHER=off \
      CLAUDE_PLUGIN_OPTION_TOKEN="$TOKEN" CLAUDE_PLUGIN_OPTION_PORT="$PORT" \
      "$@"
  )
}

expect_no_leak() {
  [ ! -s "$TMP_DIR/proxy.log" ] || fail "$1: the proxy received:
$(cat "$TMP_DIR/proxy.log")"
  [ ! -e "$TMP_DIR/curlrc-trace" ] || fail "$1: curl read ~/.curlrc"
}

# 1. The Claude Code shim: the prompt and the README the ask starts.
printf '{"session_id":"sess-1","prompt":"rename the enum"}' \
  | host_env sh "$PLUGIN/hooks/post.sh" UserPromptSubmit >/dev/null || fail "claude shim exited $?"
expect_no_leak "claude shim"
wait_for "$TMP_DIR/mac.log" "POST /v1/readme token" || fail "claude shim: no README reached the Mac:
$(cat "$TMP_DIR/mac.log")"
grep -q "POST /v1/hook/UserPromptSubmit token" "$TMP_DIR/mac.log" || fail "claude shim: no prompt reached the Mac"
expect_no_leak "claude shim"
pass "claude shim and capture.sh reach the Mac, never the proxy"

# 2. The Vibe shim, from a fresh state so its README ask runs too.
: >"$TMP_DIR/mac.log"
rm -rf "$TMP_DIR/run"
mkdir -p "$TMP_DIR/run"
printf '%s' "$VIBE_PAYLOAD" | host_env sh "$VIBE_DIR/post.sh" >/dev/null || fail "vibe shim exited $?"
expect_no_leak "vibe shim"
wait_for "$TMP_DIR/mac.log" "POST /v1/readme token" || fail "vibe shim: no README reached the Mac:
$(cat "$TMP_DIR/mac.log")"
grep -q "POST /v1/hook/UserPromptSubmit token" "$TMP_DIR/mac.log" || fail "vibe shim: no prompt reached the Mac"
expect_no_leak "vibe shim"
pass "vibe shim and capture.sh reach the Mac, never the proxy"

# 3. The doctor, with and without the token.
: >"$TMP_DIR/mac.log"
host_env sh "$PLUGIN/bin/localvoxtral" doctor >"$TMP_DIR/doctor.out" 2>&1 || :
expect_no_leak "doctor"
grep -q "POST /v1/doctor no-token" "$TMP_DIR/mac.log" && grep -q "POST /v1/doctor token" "$TMP_DIR/mac.log" \
  || fail "doctor: did not reach the Mac twice:
$(cat "$TMP_DIR/mac.log")
$(cat "$TMP_DIR/doctor.out")"
expect_no_leak "doctor"
pass "doctor reaches the Mac, never the proxy"

# 4. Every curl call: the hooks, the Vibe shim, and the probes the Mac runs
#    over ssh. A call starts with `curl -q --noproxy '*'`; -q only counts as
#    curl's first argument.
calls="$(grep -nE '(^|[^-[:alnum:]_])curl +-' \
  "$PLUGIN"/hooks/*.sh "$VIBE_DIR_SRC"/*.sh \
  "$ROOT_DIR/Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardOwnership.swift" \
  "$ROOT_DIR/Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+Verification.swift" \
  | grep -vE ':[0-9]+: *(#|///?)' || true)"
[ -n "$calls" ] || fail "found no curl calls to check"
bad="$(grep -vF "curl -q --noproxy '*' " <<<"$calls" || true)"
[ -z "$bad" ] || fail "curl calls that honour proxies or ~/.curlrc:
$bad"
pass "every remote curl call starts with -q --noproxy '*' ($(wc -l <<<"$calls" | tr -d ' ') calls)"

echo "remote shim proxy: all checks passed"
