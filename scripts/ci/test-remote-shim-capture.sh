#!/usr/bin/env bash
# Regression test for quick capture's two asks both remote shims answer
# (#745): `X-Lvx-Readme: wanted` and `X-Lvx-Draft: <id>` on a hook's 200
# reply make the Claude Code plugin's hooks/post.sh or the Vibe remote
# post.sh start capture.sh detached. capture.sh posts the README's opening to
# /v1/readme, or drafts: from a Mac with first drafts (#918) it asks
# /v1/draft/words, posts its context bundle to /v1/draft/context and polls
# /v1/draft/check for the check's prompt; from an older Mac (404 on the
# words) it lists the open issues and fetches the prompt from
# /v1/draft/prompt. Then it runs the agent and posts its output to /v1/draft.
#
# A stub curl plays the Mac, a stub gh lists two issues, and stub `claude`
# and `vibe` record their argv and environment and wait for a release file
# before answering, so "one draft at a time" is an ordering, not a stopwatch.
#
# Needs git and python3 (the Vibe shim's compactor), no network:
#   ./scripts/ci/test-remote-shim-capture.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLAUDE_HOOKS="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks"
VIBE_DIR_SRC="$ROOT_DIR/integrations/vibe/remote"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-capture-test.XXXXXX")"
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
wait_gone() {
  local i=0
  while [ -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ ! -e "$1" ]
}

# --- Fixtures ----------------------------------------------------------------
git init -q "$TMP_DIR/repo"
mkdir -p "$TMP_DIR/repo/Sources"
echo 'enum Quillmark {}' >"$TMP_DIR/repo/Sources/Quillmark.swift"
{
  printf '# Quill\n\nQuill typesets Markdown.\n\n'
  head -c 20000 /dev/zero | tr '\0' 'x'
} >"$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add -A
git -C "$TMP_DIR/repo" commit -q -m init
# A fork: gh alone would list the upstream's issues (#919).
git -C "$TMP_DIR/repo" remote add origin git@github.com:me/quill.git
git -C "$TMP_DIR/repo" remote add upstream https://github.com/upstream/quill

# A checkout whose README.md and AGENTS.md link to a file outside it (#1272),
# beside a regular README and CLAUDE.md.
{
  echo OUTSIDE-SENTINEL
  head -c 400 /dev/zero | tr '\0' 's'
  echo
} >"$TMP_DIR/outside-secret"
LINKED="$TMP_DIR/linked"
git init -q "$LINKED"
ln -s "$TMP_DIR/outside-secret" "$LINKED/README.md"
ln -s "$TMP_DIR/outside-secret" "$LINKED/AGENTS.md"
echo 'Linked plain README.' >"$LINKED/README"
{
  echo 'Linked plain guide.'
  head -c 400 /dev/zero | tr '\0' 'g'
  echo
} >"$LINKED/CLAUDE.md"
git -C "$LINKED" add -A
git -C "$LINKED" commit -q -m init

STUB="$TMP_DIR/stub"
AGENTS="$TMP_DIR/agents"
mkdir -p "$STUB" "$AGENTS"
DRAFT_ID=0123456789abcdef0123456789abcdef

# The Mac: 200 to every hook, with the asks in $LVX_T/asks; each capture
# route keeps its header file and body under the route's name. The prompt
# reply is $LVX_T/prompt with status $LVX_T/prompt-status.
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
keep() {
  cp "$header" "$LVX_T/$1-header.tmp" && mv "$LVX_T/$1-header.tmp" "$LVX_T/$1-header"
  cp "$data" "$LVX_T/$1-body.tmp" && mv "$LVX_T/$1-body.tmp" "$LVX_T/$1-body"
}
case "$url" in
*/v1/readme) keep readme; printf 200 ;;
*/v1/draft/words)
  keep words
  [ "$out" = /dev/null ] || cp "$LVX_T/words" "$out" 2>/dev/null || :
  printf '%s' "$(cat "$LVX_T/words-status" 2>/dev/null || echo 404)"
  ;;
*/v1/draft/context) keep context; printf 200 ;;
*/v1/draft/check)
  keep check
  status="$(head -n 1 "$LVX_T/check-statuses" 2>/dev/null)"
  tail -n +2 "$LVX_T/check-statuses" >"$LVX_T/check-statuses.tmp" 2>/dev/null && mv "$LVX_T/check-statuses.tmp" "$LVX_T/check-statuses"
  echo "$status" >>"$LVX_T/check-log"
  [ "$status" != 200 ] || [ "$out" = /dev/null ] || cp "$LVX_T/prompt" "$out"
  printf '%s' "${status:-404}"
  ;;
*/v1/draft/prompt)
  keep prompt
  [ "$out" = /dev/null ] || cp "$LVX_T/prompt" "$out"
  printf '%s' "$(cat "$LVX_T/prompt-status" 2>/dev/null || echo 200)"
  ;;
*/v1/draft) keep answer; printf 200 ;;
*)
  if [ -n "$dump" ]; then
    printf 'HTTP/1.1 200 OK\r\nX-Lvx-Session: joined\r\n' >"$dump"
    [ ! -e "$LVX_T/asks" ] || cat "$LVX_T/asks" >>"$dump"
    printf '\r\n' >>"$dump"
  fi
  [ -n "$out" ] && [ "$out" != /dev/null ] && printf '{"suppressOutput":true}' >"$out"
  printf 200
  ;;
esac
EOF
sed "s|\$LVX_T|$TMP_DIR|g" "$STUB/curl" >"$STUB/curl.tmp" && mv "$STUB/curl.tmp" "$STUB/curl"
chmod +x "$STUB/curl"

cat >"$STUB/gh" <<EOF
#!/bin/sh
for arg in "\$@"; do printf '%s\n' "\$arg"; done >"$TMP_DIR/gh-argv"
pwd -P >"$TMP_DIR/gh-cwd"
printf '[{"number":12,"title":"Kerning","body":"Te pairs"}]'
EOF
chmod +x "$STUB/gh"

for agent in claude vibe; do
  cat >"$AGENTS/$agent" <<EOF
#!/bin/sh
env >"$TMP_DIR/$agent-env"
pwd -P >"$TMP_DIR/$agent-cwd"
for arg in "\$@"; do printf '%s\n' "\$arg"; done >"$TMP_DIR/$agent-argv"
: >"$TMP_DIR/$agent-started"
i=0
while [ ! -e "$TMP_DIR/release" ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
printf '{"title":"t","body":"b","relation":"none","issue":null}'
exit 3
EOF
  chmod +x "$AGENTS/$agent"
done

VIBE_DIR="$TMP_DIR/vibe-remote"
mkdir -p "$VIBE_DIR" "$TMP_DIR/.vibe"
cp "$VIBE_DIR_SRC/post.sh" "$VIBE_DIR_SRC/compact.py" "$CLAUDE_HOOKS/terms.sh" "$CLAUDE_HOOKS/capture.sh" "$VIBE_DIR/"
echo vibetoken >"$VIBE_DIR/token"
echo 18473 >"$VIBE_DIR/port"
echo 'model = "x"' >"$TMP_DIR/.vibe/config.toml"
TRANSCRIPT="$TMP_DIR/messages.jsonl"
echo '{"role": "user", "content": "rename the enum", "injected": false}' >"$TRANSCRIPT"
VIBE_PAYLOAD="{\"session_id\":\"7f4aefdf\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"/srv/app\",\"parent_session_id\":null,\"hook_event_name\":\"post_agent\"}"

LOCK="$TMP_DIR/run/localvoxtral/capture/draft-running"

reset_state() {
  touch "$TMP_DIR/release"
  wait_gone "$LOCK" || fail "a draft from the previous case still holds the lock"
  rm -rf "$TMP_DIR/run" "$TMP_DIR"/claude-* "$TMP_DIR"/vibe-env "$TMP_DIR"/vibe-cwd \
    "$TMP_DIR"/vibe-argv "$TMP_DIR"/vibe-started "$TMP_DIR/release" "$TMP_DIR"/gh-* \
    "$TMP_DIR"/readme-* "$TMP_DIR"/prompt* "$TMP_DIR"/answer-* "$TMP_DIR/asks" "$TMP_DIR"/words* \
    "$TMP_DIR"/context-* "$TMP_DIR"/check-*
  mkdir -p "$TMP_DIR/run"
  printf 'The owner of quill dictated this idea.\n<capture>\nitalic kerning\n</capture>' >"$TMP_DIR/prompt"
}

run_hook() {
  local agent="$1" dir="$2" path="${3-$STUB:$AGENTS:$PATH}" status=0
  (
    cd "$dir"
    if [ "$agent" = claude ]; then
      printf '{"session_id":"sess-1"}' | env -i PATH="$path" HOME="$TMP_DIR" \
        LANG=C.UTF-8 USER=tester XDG_RUNTIME_DIR="$TMP_DIR/run" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token CLAUDE_PLUGIN_OPTION_PORT=18473 \
        CLAUDE_CODE_SESSION_ID=leak CLAUDECODE=1 \
        "$SH" "$CLAUDE_HOOKS/post.sh" UserPromptSubmit >"$TMP_DIR/stdout"
    else
      printf '%s' "$VIBE_PAYLOAD" | env -i PATH="$path" HOME="$TMP_DIR" \
        LANG=C.UTF-8 USER=tester XDG_RUNTIME_DIR="$TMP_DIR/run" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        LOCALVOXTRAL_VIBE_REMOTE_DIR="$VIBE_DIR" LOCALVOXTRAL_VIBE_WATCHER=off \
        CLAUDE_CODE_SESSION_ID=leak "$SH" "$VIBE_DIR/post.sh" >"$TMP_DIR/stdout"
    fi
  ) || status=$?
  [ "$status" = 0 ] || fail "$agent shim under $SH_NAME exited $status"
  local want=""
  [ "$agent" = claude ] && want='{"suppressOutput":true}'
  [ "$(cat "$TMP_DIR/stdout")" = "$want" ] || fail "$agent shim under $SH_NAME printed '$(cat "$TMP_DIR/stdout")'"
}

session_of() { [ "$1" = claude ] && echo sess-1 || echo 7f4aefdf; }
token_of() { [ "$1" = claude ] && echo unit-test-token || echo vibetoken; }

check_request() {
  local label="$1" agent="$2" file="$3"
  grep -qx "X-Lvx-Capture-Session: $(session_of "$agent")" "$file" || fail "$label: no session header"
  grep -qx "Authorization: Bearer $(token_of "$agent")" "$file" || fail "$label: not authenticated"
  if [ "$agent" = vibe ]; then grep -qx 'X-Lvx-Agent: vibe' "$file" || fail "$label: no agent header"; fi
}

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

  # 1. The README ask posts the first 16 KiB of the repository's README,
  #    once per project per day.
  reset_state
  printf 'X-Lvx-Readme: wanted\r\n' >"$TMP_DIR/asks"
  run_hook "$agent" "$TMP_DIR/repo/Sources"
  wait_for "$TMP_DIR/readme-body" || fail "$label: the README never reached /v1/readme"
  [ "$(wc -c <"$TMP_DIR/readme-body" | tr -d ' ')" = 16384 ] || fail "$label: the README was not cut at 16 KiB"
  head -n 3 "$TMP_DIR/readme-body" | grep -qx 'Quill typesets Markdown.' || fail "$label: posted another file"
  check_request "$label" "$agent" "$TMP_DIR/readme-header"
  rm -f "$TMP_DIR/readme-body"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/readme-body" ] || fail "$label: a second README within the day"
  pass "$label: README opening posted once a day"

  # 2. The draft ask: issues listed, prompt fetched, agent run in the
  #    repository root on that prompt, output posted with its exit status.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  run_hook "$agent" "$TMP_DIR/repo/Sources"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: the draft ask started no run"
  [ -d "$LOCK" ] || fail "$label: the run holds no lock"
  [ "$(cat "$TMP_DIR/gh-cwd")" = "$TMP_DIR/repo" ] || fail "$label: gh ran outside the repository root"
  grep -qx -- '--jq' "$TMP_DIR/gh-argv" && grep -qx create "$TMP_DIR/gh-argv" && fail "$label: gh was asked to create"
  grep -A1 -x -- '--repo' "$TMP_DIR/gh-argv" | grep -qx me/quill || fail "$label: gh listed another repository than origin's"
  [ "$(cat "$TMP_DIR/prompt-body")" = '[{"number":12,"title":"Kerning","body":"Te pairs"}]' ] \
    || fail "$label: posted issues '$(cat "$TMP_DIR/prompt-body")'"
  check_request "$label" "$agent" "$TMP_DIR/prompt-header"
  grep -qx "X-Lvx-Draft-Id: $DRAFT_ID" "$TMP_DIR/prompt-header" || fail "$label: the prompt request names no draft"
  [ "$(cat "$TMP_DIR/$agent-cwd")" = "$TMP_DIR/repo" ] || fail "$label: the run's cwd is not the repository root"
  grep -qx '<capture>' "$TMP_DIR/$agent-argv" || fail "$label: the run did not get the Mac's prompt"
  if [ "$agent" = claude ]; then
    grep -qx dontAsk "$TMP_DIR/claude-argv" && grep -qx 'Read(./\*\*)' "$TMP_DIR/claude-argv" \
      || fail "$label: reads are not confined to the checkout"
  else
    grep -qx 'Sources/Quillmark.swift' "$TMP_DIR/vibe-argv" || fail "$label: the prompt lists no files"
    run_home="$(sed -n 's/^VIBE_HOME=//p' "$TMP_DIR/vibe-env")"
    [ "$run_home" = "$TMP_DIR/.vibe/localvoxtral/remote/vibe-home/draft-$DRAFT_ID" ] \
      || fail "$label: the run's Vibe home is $run_home"
  fi
  extra="$(grep -v -e '^HOME=' -e '^PATH=' -e '^LANG=' -e '^USER=' -e '^LOGNAME=' -e '^PWD=' -e '^SHLVL=' -e '^_=' \
    -e '^OLDPWD=' -e '^VIBE_HOME=' "$TMP_DIR/$agent-env" || true)"
  [ -z "$extra" ] || fail "$label: the run inherited: $extra"
  ! grep -q "$(token_of "$agent")" "$TMP_DIR/$agent-env" "$TMP_DIR/$agent-argv" || fail "$label: the token reached the run"

  # 3. One draft at a time: a second ask while the first runs starts nothing.
  rm -f "$TMP_DIR/$agent-started"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] || fail "$label: a second draft ran beside the first"
  touch "$TMP_DIR/release"
  wait_for "$TMP_DIR/answer-body" || fail "$label: the output never reached /v1/draft"
  grep -qx 'X-Lvx-Draft-Exit: 3' "$TMP_DIR/answer-header" || fail "$label: the exit status was not posted"
  grep -qx "X-Lvx-Draft-Id: $DRAFT_ID" "$TMP_DIR/answer-header" || fail "$label: the answer names no draft"
  check_request "$label" "$agent" "$TMP_DIR/answer-header"
  [ "$(cat "$TMP_DIR/answer-body")" = '{"title":"t","body":"b","relation":"none","issue":null}' ] \
    || fail "$label: posted '$(cat "$TMP_DIR/answer-body")'"
  wait_gone "$LOCK" || fail "$label: the lock outlived the run"
  if [ "$agent" = vibe ]; then
    wait_gone "$run_home" || fail "$label: the draft's Vibe home was left behind"
  fi
  pass "$label: one draft at a time, prompt from the Mac, output and exit posted, lock released"

  # 4. Twenty drafts a day, then none.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  mkdir -p "$TMP_DIR/run/localvoxtral/capture"
  now="$(date +%s)"
  for i in $(seq 1 20); do echo $((now - 100 * i)); done >"$TMP_DIR/run/localvoxtral/capture/draft-starts"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/$agent-started" ] && [ ! -e "$TMP_DIR/prompt-body" ] || fail "$label: a 21st draft in a day ran"
  [ ! -e "$LOCK" ] || fail "$label: the refused draft kept the lock"
  echo $((now - 90000)) >"$TMP_DIR/run/localvoxtral/capture/draft-starts"
  touch "$TMP_DIR/release"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/answer-body" || fail "$label: a day-old start still counted"
  [ "$(wc -l <"$TMP_DIR/run/localvoxtral/capture/draft-starts" | tr -d ' ')" = 1 ] \
    || fail "$label: starts older than a day were kept"
  pass "$label: at most 20 drafts a day"

  # 5. A malformed id starts nothing; a refused prompt runs no agent.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "0123456789ABCDEF0123456789ABCDEF" >"$TMP_DIR/asks"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/prompt-body" ] && [ ! -e "$LOCK" ] || fail "$label: an uppercase id was taken"
  printf 'X-Lvx-Draft: %s\r\n' "${DRAFT_ID}0" >"$TMP_DIR/asks"
  run_hook "$agent" "$TMP_DIR/repo"
  sleep 0.5
  [ ! -e "$TMP_DIR/prompt-body" ] || fail "$label: a 33-digit id was taken"
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  echo 409 >"$TMP_DIR/prompt-status"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/prompt-body" || fail "$label: the prompt was never asked for"
  wait_gone "$LOCK" || fail "$label: a refused prompt kept the lock"
  [ ! -e "$TMP_DIR/$agent-started" ] && [ ! -e "$TMP_DIR/answer-body" ] || fail "$label: ran without the Mac's prompt"
  pass "$label: a malformed id or a refused prompt runs nothing"

  # 6. No gh: an empty issue list. No agent: `missing`.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  mkdir -p "$TMP_DIR/curl-only"
  ln -sf "$STUB/curl" "$TMP_DIR/curl-only/curl"
  run_hook "$agent" "$TMP_DIR/repo" "$TMP_DIR/curl-only:/usr/bin:/bin"
  wait_for "$TMP_DIR/answer-body" || fail "$label: nothing posted without gh and the agent"
  [ ! -s "$TMP_DIR/prompt-body" ] || fail "$label: an issue list without gh"
  grep -qx 'X-Lvx-Draft-Exit: missing' "$TMP_DIR/answer-header" || fail "$label: a missing agent was not reported"
  pass "$label: no gh lists nothing, no agent reports missing"

  # 7. An origin off GitHub: no list, though gh would pick the upstream.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  git -C "$TMP_DIR/repo" remote set-url origin https://gitlab.com/me/quill.git
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: an origin off GitHub started no run"
  git -C "$TMP_DIR/repo" remote set-url origin git@github.com:me/quill.git
  [ ! -e "$TMP_DIR/gh-argv" ] || fail "$label: gh listed issues for an origin off GitHub"
  [ ! -s "$TMP_DIR/prompt-body" ] || fail "$label: posted issues for an origin off GitHub"
  pass "$label: an origin off GitHub lists nothing"

  # 8. An ssh origin with a port still names its repository.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  git -C "$TMP_DIR/repo" remote set-url origin ssh://git@GitHub.com:22/me/quill.git
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: an ssh origin with a port started no run"
  git -C "$TMP_DIR/repo" remote set-url origin git@github.com:me/quill.git
  grep -A1 -x -- '--repo' "$TMP_DIR/gh-argv" | grep -qx me/quill || fail "$label: an ssh origin with a port lost its repository"
  pass "$label: an ssh origin with a port names its repository"

  # 9. A Mac with first drafts (#918): the words it sends are grepped (one
  #    that reads as an option is dropped), the bundle carries the README,
  #    the guide, the hits and gh's lists, and the check's prompt comes
  #    after a 202.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  # The Mac's reply has no final newline: the last word counts too.
  printf 'kerning\n--output=/tmp/x\nquillmark' >"$TMP_DIR/words"
  echo 200 >"$TMP_DIR/words-status"
  printf '202\n200\n' >"$TMP_DIR/check-statuses"
  run_hook "$agent" "$TMP_DIR/repo/Sources"
  wait_for "$TMP_DIR/$agent-started" || fail "$label: the check's prompt started no run"
  check_request "$label" "$agent" "$TMP_DIR/context-header"
  grep -qx "X-Lvx-Draft-Id: $DRAFT_ID" "$TMP_DIR/context-header" || fail "$label: the context names no draft"
  bundle="$TMP_DIR/context-body"
  grep -qx '@@lvx readme' "$bundle" && grep -qx 'Quill typesets Markdown.' "$bundle" || fail "$label: no README in the bundle"
  grep -qx 'Sources/Quillmark.swift:1:enum Quillmark {}' "$bundle" || fail "$label: no grep hit for a word"
  ! grep -q -- '--output' "$bundle" || fail "$label: an option-like word reached git"
  grep -qx '@@lvx open' "$bundle" && grep -qx '@@lvx closed' "$bundle" && grep -qx '@@lvx merged' "$bundle" \
    || fail "$label: gh's lists are missing"
  [ "$(wc -c <"$bundle" | tr -d ' ')" -le 98304 ] || fail "$label: the bundle is over 96 KiB"
  [ ! -e "$TMP_DIR/prompt-body" ] || fail "$label: asked for the old prompt too"
  [ "$(tr '\n' ' ' <"$TMP_DIR/check-log")" = '202 200 ' ] || fail "$label: polled '$(cat "$TMP_DIR/check-log")'"
  grep -qx '<capture>' "$TMP_DIR/$agent-argv" || fail "$label: the run did not get the check's prompt"
  touch "$TMP_DIR/release"
  wait_for "$TMP_DIR/answer-body" || fail "$label: the check's output never reached /v1/draft"
  wait_gone "$LOCK" || fail "$label: the lock outlived the check"
  pass "$label: context bundle posted, check prompt polled, agent run"

  # 10. No check due (204): no agent runs, the lock goes.
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  printf 'quillmark\n' >"$TMP_DIR/words"
  echo 200 >"$TMP_DIR/words-status"
  printf '204\n' >"$TMP_DIR/check-statuses"
  run_hook "$agent" "$TMP_DIR/repo"
  wait_for "$TMP_DIR/check-log" || fail "$label: never polled for the check"
  wait_gone "$LOCK" || fail "$label: a 204 kept the lock"
  [ ! -e "$TMP_DIR/$agent-started" ] && [ ! -e "$TMP_DIR/answer-body" ] || fail "$label: ran an agent with no check due"
  pass "$label: no check due runs nothing"

  # 11. A README or guide that is a symlink is skipped, even to a file
  #     outside the checkout (#1272): the next regular name is read instead.
  reset_state
  printf 'X-Lvx-Readme: wanted\r\n' >"$TMP_DIR/asks"
  run_hook "$agent" "$LINKED"
  wait_for "$TMP_DIR/readme-body" || fail "$label: the linked checkout's README never reached /v1/readme"
  ! grep -q OUTSIDE-SENTINEL "$TMP_DIR/readme-body" || fail "$label: posted a symlinked README's outside target"
  grep -qx 'Linked plain README.' "$TMP_DIR/readme-body" || fail "$label: skipped the regular README too"
  reset_state
  printf 'X-Lvx-Draft: %s\r\n' "$DRAFT_ID" >"$TMP_DIR/asks"
  printf 'quillmark\n' >"$TMP_DIR/words"
  echo 200 >"$TMP_DIR/words-status"
  printf '204\n' >"$TMP_DIR/check-statuses"
  run_hook "$agent" "$LINKED"
  wait_for "$TMP_DIR/context-body" || fail "$label: the linked checkout posted no context"
  wait_gone "$LOCK" || fail "$label: the linked checkout's draft kept the lock"
  ! grep -q OUTSIDE-SENTINEL "$TMP_DIR/context-body" || fail "$label: the bundle carries a symlink's outside target"
  grep -qx 'Linked plain README.' "$TMP_DIR/context-body" || fail "$label: no regular README in the bundle"
  grep -qx 'Linked plain guide.' "$TMP_DIR/context-body" || fail "$label: no regular CLAUDE.md in the bundle"
  pass "$label: symlinked README and guide skipped, regular ones posted"
done
done
echo "remote shim capture: all checks passed"
