#!/bin/sh
# localvoxtral project-terms runner (#641) — strict POSIX sh, needs curl.
#
# The Mac asked for this project's terms (`X-Lvx-Terms: wanted` on a hook's
# reply), and the hook shim started this script detached, in a clean
# environment (`env -i HOME PATH LANG USER LOGNAME`), with stdin carrying the host token
# and nothing else. It runs the session's own agent headless in the project,
# read-only and with hooks off, exactly as the app does for a local project
# (ProjectTermProposal.swift), and posts the agent's answer to the Mac's
# `/v1/terms` route. Nothing but that answer crosses the tunnel: Claude Code's
# result object (the terms and the run's usage), or Vibe's text with its
# token counts in a header.
#
# It ships in this plugin, and the app installs the same file next to the Vibe
# hooks' shim on an enrolled host (VibeRemoteHooksFiles).
#
#   terms.sh <claude|vibe> <port> <session-id> <project-dir> <stamp-dir> [<user-vibe-dir>]
#
# Everything is silent and fail-open: a missing agent, a failed run, a dead
# tunnel all end here with nothing printed. The stamp directory then keeps its
# attempt time, and the hook shim will not start another run for this project
# for 24 hours. A 200 from the Mac writes `done`, and it never runs again.
set -u
# The token is read into a shell variable. A shell exports a variable it
# imported from its environment, or any assignment under `allexport`; the
# environment is empty here, but the agent below must never see the token.
set +a
unset TOKEN
umask 077

AGENT="${1:-}"
PORT="${2:-}"
SESSION_ID="${3:-}"
PROJECT="${4:-}"
STATE="${5:-}"
USER_VIBE="${6:-}"

TOKEN=""
IFS= read -r TOKEN 2>/dev/null || :
exec </dev/null >/dev/null 2>&1

case "$AGENT" in claude | vibe) ;; *) exit 0 ;; esac
case "$PORT" in "" | *[!0-9]* | 0* | ??????*) exit 0 ;; esac
case "$SESSION_ID" in
"" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*) exit 0 ;;
esac
[ "${#SESSION_ID}" -le 64 ] || exit 0
case "$TOKEN" in
"" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) exit 0 ;;
esac
[ "${#TOKEN}" -le 128 ] || exit 0
case "$PROJECT" in /*) ;; *) exit 0 ;; esac
case "$STATE" in /*) ;; *) exit 0 ;; esac
[ -d "$PROJECT" ] && [ -d "$STATE" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# The agent's CLI: PATH first, then where its installers put it.
BIN="$(command -v "$AGENT" 2>/dev/null)" || BIN=""
for candidate in "$HOME/.local/bin/$AGENT" "$HOME/.claude/local/$AGENT" /opt/homebrew/bin/"$AGENT" /usr/local/bin/"$AGENT"; do
  [ -z "$BIN" ] || break
  [ -x "$candidate" ] && BIN="$candidate"
done
[ -n "$BIN" ] || exit 0

WORK="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 0' HUP INT TERM

cd "$PROJECT" || exit 0

# vibe_usage <vibe-home>: the newest run's token counts under that home, as
# "<input> <cached input> <output>", or nothing. Vibe's unified harness keeps
# them in the session log (VibeSessionUsage.swift); the same file holds the
# prompt, so only the three numbers are read out of it.
vibe_usage() {
  current="$(ls -t "$1"/logs/session/unified/*/CURRENT 2>/dev/null | head -n 1)"
  [ -n "$current" ] || return 0
  generation="$(sed -n 's/.*"generation":"\([0-9]\{1,20\}\)".*/\1/p' "$current" 2>/dev/null | head -n 1)"
  [ -n "$generation" ] || return 0
  sed -n 's/.*"tokenUsage":{"cachedInputTokens":\([0-9]\{1,10\}\),"inputTokens":\([0-9]\{1,10\}\),"outputTokens":\([0-9]\{1,10\}\)[,}].*/\2 \1 \3/p' \
    "${current%/CURRENT}/generations/$generation/projection-state.json" 2>/dev/null | head -n 1
}

# ProjectTermProposal.prompt, word for word (RemoteProjectTermsTests).
prompt() {
  cat <<'PROMPT'
List the names someone would say aloud about this project that a speech recognizer is likely to misspell. Picture a builder who talks to coding agents and rarely reads the code: they say the project's name and its parts as its docs name them, the products, tools, services, libraries and models it uses, people and teams, and words of its domain. They never say class, function or variable names, file names, paths, flags or environment variables: leave those out, and leave out common English words. Also describe the project in one sentence of at most 200 characters: what it is, then the features and parts someone would name when filing an idea for it. Read at most six files, the README first. Spell each name as the project's docs write it. Reply with JSON only: {"terms": [...], "description": "..."}, at most 40 terms.
PROMPT
}

if [ "$AGENT" = claude ]; then
  # The result object: the answer in `structured_output`, beside the run's
  # usage and cost, parsed on the Mac as a local run's is.
  "$BIN" -p "$(prompt)" \
    --model sonnet \
    --system-prompt 'You list the names people say when they talk about a code project, and describe it, for a dictation app. Reply only with the requested JSON.' \
    --tools 'Read,Glob,Grep' \
    --settings '{"disableAllHooks":true}' \
    --strict-mcp-config \
    --no-session-persistence \
    --max-turns 12 \
    --max-budget-usd 0.50 \
    --output-format json \
    --json-schema '{"type":"object","properties":{"terms":{"type":"array","items":{"type":"string"},"maxItems":40},"description":{"type":"string"}},"required":["terms","description"],"additionalProperties":false}' \
    </dev/null >"$WORK/out" 2>/dev/null &
else
  # Vibe has no flag to skip hooks: a home of its own, holding only links to
  # the user's model config and key, keeps every hooks.toml hook out, ours
  # included, and keeps the run out of the user's Vibe history.
  case "$USER_VIBE" in /*) ;; *) exit 0 ;; esac
  # One per project stamp: two runs at once never share, or rewrite, the
  # other's links.
  VIBE_RUN_HOME="$HOME/.vibe/localvoxtral/remote/vibe-home/${STATE##*/}"
  mkdir -p "$VIBE_RUN_HOME" || exit 0
  for name in config.toml .env; do
    link="$VIBE_RUN_HOME/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then exit 0; fi
    rm -f "$link"
    [ -e "$USER_VIBE/$name" ] && ln -s "$USER_VIBE/$name" "$link"
  done
  # With bash refused, the unified harness has no listing tool: the prompt
  # names the tracked files (the directory's own files outside git), 200 at
  # most.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -c core.quotePath=false ls-files 2>/dev/null | head -n 200 >"$WORK/files"
  else
    for file in *; do [ -f "$file" ] && echo "$file"; done | head -n 200 >"$WORK/files"
  fi
  if [ -s "$WORK/files" ]; then
    PROMPT_TEXT="$(prompt)

Tracked files (read_file takes these paths):
$(cat "$WORK/files")"
  else
    PROMPT_TEXT="$(prompt)"
  fi
  VIBE_HOME="$VIBE_RUN_HOME" "$BIN" --experimental-harness --auto-approve \
    -p "$PROMPT_TEXT" \
    --enabled-tools 're:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$' \
    --max-turns 12 \
    --max-price 0.30 \
    --output text \
    </dev/null >"$WORK/out" 2>/dev/null &
fi
RUN=$!

# Watchdog: 180 s, then TERM, then KILL. It polls, so it ends with the run.
(
  i=0
  while [ "$i" -lt 180 ] && kill -0 "$RUN" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$RUN" 2>/dev/null; then
    kill -TERM "$RUN" 2>/dev/null
    sleep 5
    kill -KILL "$RUN" 2>/dev/null
  fi
) &
wait "$RUN" || exit 0

# The answer alone, capped. Whether it is one is the Mac's call.
head -c 16384 "$WORK/out" >"$WORK/answer" 2>/dev/null || exit 0
[ -s "$WORK/answer" ] || exit 0

# Heredoc through a redirected `cat`, not printf/echo: an external printf
# would put the token into an argv.
cat >"$WORK/header" <<HEADER || exit 0
Authorization: Bearer $TOKEN
X-Lvx-Terms-Session: $SESSION_ID
HEADER
if [ "$AGENT" = vibe ]; then
  echo 'X-Lvx-Agent: vibe' >>"$WORK/header" || exit 0
  USAGE="$(vibe_usage "$VIBE_RUN_HOME")"
  case "$USAGE" in
  [0-9]*" "[0-9]*" "[0-9]*) echo "X-Lvx-Usage: $USAGE" >>"$WORK/header" || exit 0 ;;
  esac
fi
STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 --request POST \
  --header 'Content-Type: application/json' \
  --header @"$WORK/header" \
  --data-binary @"$WORK/answer" \
  "http://127.0.0.1:$PORT/v1/terms" 2>/dev/null)" || STATUS=""
[ "$STATUS" = 200 ] || exit 0
: >"$STATE/done" 2>/dev/null || :
exit 0
