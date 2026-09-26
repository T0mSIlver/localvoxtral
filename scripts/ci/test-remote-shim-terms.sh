#!/usr/bin/env bash
# Regression test for the project-terms ask both remote shims answer (#641):
# `X-Lvx-Terms: wanted` on a hook's 200 reply makes the Claude Code plugin's
# hooks/post.sh or the Vibe remote post.sh start terms.sh detached, once per
# project per 24 hours, and terms.sh posts the agent's answer to /v1/terms.
#
# A stub curl plays the Mac (it answers hooks with the header when $ASK exists
# and records what reaches /v1/terms), and stub `claude` and `vibe` record
# their argv and environment and wait for a release file before answering, so
# "the hook returned before the run finished" is an ordering, not a stopwatch.
#
# Needs git and python3 (the Vibe shim's compactor), no network:
#   ./scripts/ci/test-remote-shim-terms.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLAUDE_HOOKS="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks"
VIBE_DIR_SRC="$ROOT_DIR/integrations/vibe/remote"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-terms-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  touch "$TMP_DIR/release" 2>/dev/null || :
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# Bounded wait for a file the detached runner writes: 10 s, never a verdict
# by itself (the caller fails with its own message).
wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# --- Fixtures ----------------------------------------------------------------
git init -q "$TMP_DIR/repo"
mkdir -p "$TMP_DIR/repo/Sources"
echo 'enum Quillmark {}' >"$TMP_DIR/repo/Sources/Quillmark.swift"
git -C "$TMP_DIR/repo" add -A
git -C "$TMP_DIR/repo" commit -q -m init
mkdir -p "$TMP_DIR/plain"
echo notes >"$TMP_DIR/plain/notes.txt"

STUB="$TMP_DIR/stub"
AGENTS="$TMP_DIR/agents"
mkdir -p "$STUB" "$AGENTS"

# The Mac: 200 to every hook, with the ask when $ASK exists; /v1/terms answers
# $TERMS_STATUS and keeps the body and the header file.
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
dump="" out="" header="" data="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --dump-header) dump="$2"; shift ;;
  --output) out="$2"; shift ;;
  --header) case "$2" in @*) header="${2#@}" ;; esac; shift ;;
  --data-binary) data="${2#@}"; shift ;;
  --write-out | --max-time | --max-filesize | --request) shift ;;
  http://*) url="$1" ;;
  esac
  shift
done
case "$url" in
*/v1/terms)
  # posted-body is what the suite waits for, so it lands last, and each file
  # appears whole by rename (#767).
  cp "$header" "$LVX_T/posted-header.tmp" && mv "$LVX_T/posted-header.tmp" "$LVX_T/posted-header"
  cp "$data" "$LVX_T/posted-body.tmp" && mv "$LVX_T/posted-body.tmp" "$LVX_T/posted-body"
  echo >>"$LVX_T/runs-posted"
  printf '%s' "$(cat "$LVX_T/terms-status" 2>/dev/null || echo 200)"
  ;;
*)
  if [ -n "$dump" ]; then
    printf 'HTTP/1.1 200 OK\r\nX-Lvx-Session: joined\r\n' >"$dump"
    [ -e "$LVX_T/ask" ] && printf 'X-Lvx-Terms: wanted\r\n' >>"$dump"
    printf '\r\n' >>"$dump"
  fi
  [ -n "$out" ] && [ "$out" != /dev/null ] && printf '{"suppressOutput":true}' >"$out"
  printf 200
  ;;
esac
EOF
# The runner's environment is empty, so the stub's state directory is baked in.
sed "s|\$LVX_T|$TMP_DIR|g" "$STUB/curl" >"$STUB/curl.tmp" && mv "$STUB/curl.tmp" "$STUB/curl"
chmod +x "$STUB/curl"

# The agents: record argv, cwd and environment, wait for the release file,
# answer. LVX_T is baked in because the runner's environment is empty.
for agent in claude vibe; do
  cat >"$AGENTS/$agent" <<EOF
#!/bin/sh
env >"$TMP_DIR/$agent-env"
pwd -P >"$TMP_DIR/$agent-cwd"
for arg in "\$@"; do printf '%s\n' "\$arg"; done >"$TMP_DIR/$agent-argv"
: >"$TMP_DIR/$agent-started"
echo >>"$TMP_DIR/runs-started"
i=0
while [ ! -e "$TMP_DIR/release" ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
printf '{"terms":["Quillmark"]}'
EOF
  chmod +x "$AGENTS/$agent"
done

VIBE_DIR="$TMP_DIR/vibe-remote"
mkdir -p "$VIBE_DIR" "$TMP_DIR/.vibe"
cp "$VIBE_DIR_SRC/post.sh" "$VIBE_DIR_SRC/compact.py" "$CLAUDE_HOOKS/terms.sh" "$VIBE_DIR/"
echo vibetoken >"$VIBE_DIR/token"
echo 18473 >"$VIBE_DIR/port"
echo 'model = "x"' >"$TMP_DIR/.vibe/config.toml"
TRANSCRIPT="$TMP_DIR/messages.jsonl"
echo '{"role": "user", "content": "rename the enum", "injected": false}' >"$TRANSCRIPT"
VIBE_PAYLOAD="{\"session_id\":\"7f4aefdf\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"/srv/app\",\"parent_session_id\":null,\"hook_event_name\":\"post_agent\"}"

# Every run the stub agents start ends by posting (their answer is never
# empty), so equal counts mean no detached run from the previous case can
# still write into the next one (#767).
runs_drained() {
  [ "$(($(cat "$TMP_DIR/runs-started" 2>/dev/null | wc -l)))" \
    = "$(($(cat "$TMP_DIR/runs-posted" 2>/dev/null | wc -l)))" ]
}

reset_state() {
  local i=0
  while ! runs_drained && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  runs_drained || fail "a run from the previous case never posted"
  rm -rf "$TMP_DIR/run" "$TMP_DIR"/claude-* "$TMP_DIR"/vibe-env "$TMP_DIR"/vibe-cwd \
    "$TMP_DIR"/vibe-argv "$TMP_DIR"/vibe-started "$TMP_DIR/release" \
    "$TMP_DIR"/posted-body* "$TMP_DIR"/posted-header* "$TMP_DIR/ask" "$TMP_DIR/terms-status"
  mkdir -p "$TMP_DIR/run"
}

# run_hook <claude|vibe> <cwd> [agent path dir]: one hook, stdout to
# $TMP_DIR/stdout, exit status checked. The environment carries what a real
# hook inherits that the run must NOT: Claude Code's session variables and
# the plugin's token option.
run_hook() {
  local agent="$1" dir="$2" agents="${3-$AGENTS}" status=0
  (
    cd "$dir"
    if [ "$agent" = claude ]; then
      printf '{"session_id":"sess-1"}' | env -i PATH="$STUB:$agents:$PATH" HOME="$TMP_DIR" \
        LANG=C.UTF-8 USER=tester XDG_RUNTIME_DIR="$TMP_DIR/run" LVX_T="$TMP_DIR" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token CLAUDE_PLUGIN_OPTION_PORT=18473 \
        CLAUDE_CODE_SESSION_ID=leak CLAUDECODE=1 \
        "$SH" "$CLAUDE_HOOKS/post.sh" UserPromptSubmit >"$TMP_DIR/stdout"
    else
      printf '%s' "$VIBE_PAYLOAD" | env -i PATH="$STUB:$agents:$PATH" HOME="$TMP_DIR" \
        LANG=C.UTF-8 USER=tester XDG_RUNTIME_DIR="$TMP_DIR/run" LVX_T="$TMP_DIR" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        LOCALVOXTRAL_VIBE_REMOTE_DIR="$VIBE_DIR" LOCALVOXTRAL_VIBE_WATCHER=off \
        CLAUDE_CODE_SESSION_ID=leak "$SH" "$VIBE_DIR/post.sh" >"$TMP_DIR/stdout"
    fi
  ) || status=$?
  [ "$status" = 0 ] || fail "$agent shim under $SH_NAME exited $status"
}

session_of() { [ "$1" = claude ] && echo sess-1 || echo 7f4aefdf; }
token_of() { [ "$1" = claude ] && echo unit-test-token || echo vibetoken; }
expected_stdout() { [ "$1" = claude ] && printf '{"suppressOutput":true}' || :; }

check_stdout() {
  [ "$(cat "$TMP_DIR/stdout")" = "$(expected_stdout "$1")" ] \
    || fail "$1 shim under $SH_NAME printed '$(cat "$TMP_DIR/stdout")'"
}

stamp_dirs() { find "$TMP_DIR/run/localvoxtral/terms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

for SH in "${SHELLS[@]}"; do
case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac
for agent in claude vibe; do
  label="$agent shim under $SH_NAME"

  # 1. The ask starts one run in the repository root, and the hook returns
  #    with its usual stdout before the run ends.
  reset_state
  touch "$TMP_DIR/ask"
  run_hook "$agent" "$TMP_DIR/repo/Sources"
  check_stdout "$agent"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: the ask started no run"
  [ ! -e "$TMP_DIR/posted-body" ] || fail "$label: posted before the run ended"
  pass "$label: the hook returned while the run was still going"
  [ "$(cat "$TMP_DIR/$agent-cwd")" = "$TMP_DIR/repo" ] \
    || fail "$label: the run's cwd is $(cat "$TMP_DIR/$agent-cwd"), not the repository root"
  touch "$TMP_DIR/release"
  wait_for "$TMP_DIR/posted-body" || fail "$label: the answer never reached /v1/terms"
  [ "$(cat "$TMP_DIR/posted-body")" = '{"terms":["Quillmark"]}' ] \
    || fail "$label: posted '$(cat "$TMP_DIR/posted-body")'"
  grep -qx "X-Lvx-Terms-Session: $(session_of "$agent")" "$TMP_DIR/posted-header" \
    || fail "$label: the answer does not name the session"
  grep -qx "Authorization: Bearer $(token_of "$agent")" "$TMP_DIR/posted-header" \
    || fail "$label: the answer is not authenticated"
  if [ "$agent" = vibe ]; then
    grep -qx 'X-Lvx-Agent: vibe' "$TMP_DIR/posted-header" || fail "$label: no agent header"
  fi
  wait_for "$(find "$TMP_DIR/run/localvoxtral/terms" -mindepth 1 -maxdepth 1 -type d | head -n 1)/done" \
    || fail "$label: a 200 did not mark the project done"
  pass "$label: one run, answer posted with the session and token, project marked done"

  # 2. The run's environment: HOME, PATH, LANG (and Vibe's own home), nothing
  #    Claude Code or the plugin exported, and never the token.
  extra="$(grep -v -e '^HOME=' -e '^PATH=' -e '^LANG=' -e '^USER=' -e '^LOGNAME=' -e '^PWD=' -e '^SHLVL=' -e '^_=' \
    -e '^OLDPWD=' -e '^VIBE_HOME=' "$TMP_DIR/$agent-env" || true)"
  [ -z "$extra" ] || fail "$label: the run inherited: $extra"
  ! grep -q "$(token_of "$agent")" "$TMP_DIR/$agent-env" "$TMP_DIR/$agent-argv" \
    || fail "$label: the token reached the run"
  if [ "$agent" = vibe ]; then
    run_home="$(sed -n 's/^VIBE_HOME=//p' "$TMP_DIR/vibe-env")"
    [ "$run_home" = "$TMP_DIR/.vibe/localvoxtral/remote/vibe-home/$(basename "$(find "$TMP_DIR/run/localvoxtral/terms" -mindepth 1 -maxdepth 1 -type d)")" ] \
      || fail "$label: the run's Vibe home is $run_home, not one of its own"
    [ "$(readlink "$run_home/config.toml")" = "$TMP_DIR/.vibe/config.toml" ] \
      || fail "$label: the Vibe home does not link the user's config"
    grep -qx 'Sources/Quillmark.swift' "$TMP_DIR/vibe-argv" || fail "$label: the prompt lists no files"
  else
    grep -qx -- '--output-format' "$TMP_DIR/claude-argv" && grep -qx text "$TMP_DIR/claude-argv" \
      || fail "$label: claude does not print text"
  fi
  grep -qx 'USER=tester' "$TMP_DIR/$agent-env" || fail "$label: the run lost USER (macOS keychain logins need it)"
  pass "$label: the run saw only HOME, PATH, LANG, USER and LOGNAME"

  # 3. A done project is never asked again.
  rm -f "$TMP_DIR/$agent-started"
  run_hook "$agent" "$TMP_DIR/repo"
  check_stdout "$agent"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] || fail "$label: a done project ran again"
  pass "$label: a done project is not asked again"

  # 4. A failed run (the Mac refused) keeps only its attempt time: no second
  #    run within 24 hours, one after.
  reset_state
  touch "$TMP_DIR/ask" "$TMP_DIR/release"
  echo 400 >"$TMP_DIR/terms-status"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/posted-body" || fail "$label: the refused run never posted"
  stamp="$(find "$TMP_DIR/run/localvoxtral/terms" -mindepth 1 -maxdepth 1 -type d)"
  sleep 0.3
  [ ! -e "$stamp/done" ] || fail "$label: a refused answer marked the project done"
  rm -f "$TMP_DIR/$agent-started"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] || fail "$label: a second run started within 24 hours"
  echo $(($(date +%s) - 90000)) >"$stamp/attempt"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: no run a day after a failure"
  [ "$(stamp_dirs)" = 1 ] || fail "$label: the retry left $(stamp_dirs) stamps"
  pass "$label: a failure retries after 24 hours, not before"

  # 4b. A claim whose attempt time is not written yet belongs to another hook
  #     that is still starting its run; only one a day old is taken over.
  rm -f "$stamp/attempt" "$TMP_DIR/$agent-started"
  touch "$stamp"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] || fail "$label: a fresh claim was taken over"
  touch -t "$(date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-2d +%Y%m%d%H%M)" "$stamp"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: a dead claim blocked the project"
  pass "$label: a claim still starting is left alone, a dead one is taken over"

  # 5. No ask, no run.
  reset_state
  touch "$TMP_DIR/release"
  run_hook "$agent" "$TMP_DIR/repo"
  check_stdout "$agent"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] && [ "$(stamp_dirs)" = 0 ] || fail "$label: ran without the ask"
  pass "$label: no header, no run"

  # 6. Outside git, the run's directory is the hook's cwd.
  reset_state
  touch "$TMP_DIR/ask" "$TMP_DIR/release"
  run_hook "$agent" "$TMP_DIR/plain"
  wait_for "$TMP_DIR/posted-body" || fail "$label: no run outside git"
  [ "$(cat "$TMP_DIR/$agent-cwd")" = "$TMP_DIR/plain" ] || fail "$label: wrong directory outside git"
  pass "$label: outside git the run uses the hook's cwd"

  # 7. No agent CLI and a dead tunnel: silent, exit 0, nothing posted.
  reset_state
  touch "$TMP_DIR/ask"
  mkdir -p "$TMP_DIR/empty"
  NO_AGENT_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do
    [ -x "$d/$agent" ] || printf '%s:' "$d"; done)"
  PATH="$NO_AGENT_PATH" run_hook "$agent" "$TMP_DIR/repo" "$TMP_DIR/empty"
  check_stdout "$agent"
  sleep 0.5
  [ ! -e "$TMP_DIR/posted-body" ] || fail "$label: posted without an agent"
  reset_state
  touch "$TMP_DIR/ask" "$TMP_DIR/release"
  echo 000 >"$TMP_DIR/terms-status"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/posted-body" || fail "$label: the run never tried to post"
  sleep 0.3
  [ -z "$(find "$TMP_DIR/run/localvoxtral/terms" -name done)" ] || fail "$label: a dead tunnel marked done"
  pass "$label: no agent or a dead tunnel fails silently"
done
done
