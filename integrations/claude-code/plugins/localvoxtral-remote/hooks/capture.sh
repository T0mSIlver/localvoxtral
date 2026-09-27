#!/bin/sh
# localvoxtral quick capture runner (#745) — strict POSIX sh, needs curl.
#
# The Mac asked on a hook's reply, and the hook shim started this script
# detached, in a clean environment (`env -i HOME PATH LANG USER LOGNAME`),
# with stdin carrying the host token and nothing else. Two asks:
#
#   capture.sh readme <agent> <port> <session-id> <project-dir>
#   capture.sh draft <agent> <port> <session-id> <project-dir> <draft-id> <lock-dir> [<user-vibe-dir>]
#
# The draft's lock directory is the shim's one-draft-at-a-time lock; this
# script removes it when it ends.
#
# readme posts the first 16 KiB of the project's README to `/v1/readme`; the
# Mac keeps a summary of it for quick capture's router.
#
# draft posts the project's open issues (`gh issue list`, when gh works here)
# to `/v1/draft/prompt` and gets the drafting prompt back, with the dictated
# idea in it. It runs the session's own agent headless in the project with
# the Mac's local drafting flags (QuickCaptureDraft.swift): read-only tools
# confined to the checkout, hooks and MCP off, 20 turns, a cost cap and a
# 240 s watchdog. The agent's output goes to `/v1/draft`. Nothing is filed:
# gh only lists issues, and the agent has no shell.
#
# The prompt comes from whatever answers on the port, which is normally the
# Mac but can be another local user who bound it first. That is why the
# agent's reads stay inside the checkout, and why the shim allows one draft
# at a time and 20 a day.
#
# Everything is silent and fail-open.
set -u
# The token is read into a shell variable that is never exported: the agent
# below must never see it.
set +a
unset TOKEN
umask 077

MODE="${1:-}"
AGENT="${2:-}"
PORT="${3:-}"
SESSION_ID="${4:-}"
PROJECT="${5:-}"
DRAFT_ID="${6:-}"
LOCK="${7:-}"
USER_VIBE="${8:-}"

TOKEN=""
IFS= read -r TOKEN 2>/dev/null || :
exec </dev/null >/dev/null 2>&1

# The shim's draft lock goes when this ends, however it ends.
case "$LOCK" in /*/capture/draft-running) ;; *) LOCK="" ;; esac
WORK=""
CLEANUP='[ -z "$WORK" ] || rm -rf "$WORK"; [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null'
trap 'eval "$CLEANUP"' EXIT
trap 'eval "$CLEANUP"; exit 0' HUP INT TERM
[ "$MODE" = readme ] || [ -n "$LOCK" ] || exit 0

case "$MODE" in readme | draft) ;; *) exit 0 ;; esac
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
[ -d "$PROJECT" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

WORK="$(mktemp -d 2>/dev/null)" || exit 0
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

# Heredoc through a redirected `cat`, not printf/echo: an external printf
# would put the token into an argv.
cat >"$WORK/header" <<HEADER || exit 0
Authorization: Bearer $TOKEN
X-Lvx-Capture-Session: $SESSION_ID
HEADER
if [ "$AGENT" = vibe ]; then
  echo 'X-Lvx-Agent: vibe' >>"$WORK/header" || exit 0
fi

# post <path> <body-file> <reply-file>: prints the HTTP status.
post() {
  curl --silent --output "$3" --write-out '%{http_code}' \
    --max-time 10 --max-filesize 65536 --request POST \
    --header 'Content-Type: application/octet-stream' \
    --header @"$WORK/header" \
    --data-binary @"$2" \
    "http://127.0.0.1:$PORT$1" 2>/dev/null
}

if [ "$MODE" = readme ]; then
  : >"$WORK/readme"
  for name in README.md README readme.md README.markdown Readme.md; do
    if [ -f "$name" ] && [ -r "$name" ]; then
      head -c 16384 "$name" >"$WORK/readme" 2>/dev/null || : >"$WORK/readme"
      break
    fi
  done
  post /v1/readme "$WORK/readme" /dev/null >/dev/null
  exit 0
fi

# --- draft --------------------------------------------------------------------
case "$DRAFT_ID" in
"" | *[!0123456789abcdef]*) exit 0 ;;
esac
[ "${#DRAFT_ID}" -eq 32 ] || exit 0
echo "X-Lvx-Draft-Id: $DRAFT_ID" >>"$WORK/header" || exit 0

# watch <pid> <seconds>: TERM, then KILL, once the time is up; writes
# $WORK/timedout when it had to. It polls, so it ends with the run.
watch() {
  (
    i=0
    while [ "$i" -lt "$2" ] && kill -0 "$1" 2>/dev/null; do
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$1" 2>/dev/null; then
      : >"$WORK/timedout"
      kill -TERM "$1" 2>/dev/null
      sleep 5
      kill -KILL "$1" 2>/dev/null
    fi
  ) &
}

# Open issues, trimmed to what the prompt quotes: 60 issues, 200-character
# titles, 240-character bodies (QuickCaptureDraft.prompt). No gh, no login,
# no GitHub remote: an empty list, and the prompt says it could not be read.
: >"$WORK/issues"
if command -v gh >/dev/null 2>&1; then
  gh issue list --state open --limit 60 --json number,title,body \
    --jq '[.[] | {number, title: .title[0:200], body: (.body // "")[0:240]}]' \
    >"$WORK/issues.raw" 2>/dev/null &
  GH=$!
  watch "$GH" 20
  if wait "$GH" && [ ! -e "$WORK/timedout" ]; then
    head -c 49152 "$WORK/issues.raw" >"$WORK/issues" 2>/dev/null || : >"$WORK/issues"
  fi
  rm -f "$WORK/timedout"
fi

STATUS="$(post /v1/draft/prompt "$WORK/issues" "$WORK/prompt")" || STATUS=""
[ "$STATUS" = 200 ] && [ -s "$WORK/prompt" ] || exit 0

# answer <exit>: posts the capped output with how the run ended, and a Vibe
# run's token counts.
answer() {
  echo "X-Lvx-Draft-Exit: $1" >>"$WORK/header" || exit 0
  if [ "$AGENT" = vibe ] && [ -n "${VIBE_RUN_HOME:-}" ]; then
    USAGE="$(vibe_usage "$VIBE_RUN_HOME")"
    case "$USAGE" in
    [0-9]*" "[0-9]*" "[0-9]*) echo "X-Lvx-Usage: $USAGE" >>"$WORK/header" || exit 0 ;;
    esac
  fi
  post /v1/draft "$WORK/answer" /dev/null >/dev/null
  exit 0
}
: >"$WORK/answer"

# The agent's CLI: PATH first, then where its installers put it.
BIN="$(command -v "$AGENT" 2>/dev/null)" || BIN=""
for candidate in "$HOME/.local/bin/$AGENT" "$HOME/.claude/local/$AGENT" /opt/homebrew/bin/"$AGENT" /usr/local/bin/"$AGENT"; do
  [ -z "$BIN" ] || break
  [ -x "$candidate" ] && BIN="$candidate"
done
[ -n "$BIN" ] || answer missing

if [ "$AGENT" = claude ]; then
  # QuickCaptureDraft.claudeArguments, flag for flag (RemoteQuickCaptureTests).
  "$BIN" -p "$(cat "$WORK/prompt")" \
    --model sonnet \
    --system-prompt "You draft GitHub issues from a developer's dictated ideas. You cannot file anything. Reply only with the requested JSON." \
    --tools 'Read,Glob,Grep' \
    --permission-mode dontAsk \
    --allowedTools 'Read(./**)' \
    --settings '{"disableAllHooks":true}' \
    --strict-mcp-config \
    --no-session-persistence \
    --max-turns 20 \
    --max-budget-usd 0.50 \
    --output-format json \
    --json-schema '{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"relation":{"type":"string","enum":["none","duplicate","extends"]},"issue":{"type":["integer","null"]}},"required":["title","body","relation","issue"],"additionalProperties":false}' \
    </dev/null >"$WORK/out" 2>/dev/null &
else
  # Vibe has no flag to skip hooks: a home of its own, holding only links to
  # the user's model config and key, keeps every hooks.toml hook out, ours
  # included, and keeps the run out of the user's Vibe history. One per
  # draft, so two runs never share links.
  case "$USER_VIBE" in /*) ;; *) exit 0 ;; esac
  VIBE_RUN_HOME="$HOME/.vibe/localvoxtral/remote/vibe-home/draft-$DRAFT_ID"
  mkdir -p "$VIBE_RUN_HOME" || exit 0
  CLEANUP="$CLEANUP"'; rm -rf "$VIBE_RUN_HOME"'
  for name in config.toml .env; do
    link="$VIBE_RUN_HOME/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then exit 0; fi
    rm -f "$link"
    [ -e "$USER_VIBE/$name" ] && ln -s "$USER_VIBE/$name" "$link"
  done
  # With bash refused, the unified harness has no listing tool: the prompt
  # names the tracked files (the directory's own files outside git), 200 at
  # most, as QuickCaptureDraft.vibeArguments does. Text output, unlike the
  # Mac's run: the JSON transcript carries every file the agent read and
  # would not fit the answer's cap.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -c core.quotePath=false ls-files 2>/dev/null | head -n 200 >"$WORK/files"
  else
    for file in *; do [ -f "$file" ] && echo "$file"; done | head -n 200 >"$WORK/files"
  fi
  if [ -s "$WORK/files" ]; then
    PROMPT_TEXT="$(cat "$WORK/prompt")

Tracked files (read_file takes these paths):
$(cat "$WORK/files")"
  else
    PROMPT_TEXT="$(cat "$WORK/prompt")"
  fi
  VIBE_HOME="$VIBE_RUN_HOME" "$BIN" --experimental-harness --auto-approve \
    -p "$PROMPT_TEXT" \
    --enabled-tools 're:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$' \
    --max-turns 20 \
    --max-price 0.30 \
    --output text \
    </dev/null >"$WORK/out" 2>/dev/null &
fi
RUN=$!
watch "$RUN" 240
wait "$RUN"
CODE=$?
[ ! -e "$WORK/timedout" ] || answer timeout
SIZE="$({ wc -c <"$WORK/out"; } 2>/dev/null | tr -d '[:space:]')"
case "$SIZE" in "" | *[!0-9]*) SIZE=0 ;; esac
[ "$SIZE" -le 61440 ] || answer capped
cp "$WORK/out" "$WORK/answer" 2>/dev/null || exit 0
answer "$CODE"
