#!/bin/sh
# localvoxtral quick capture runner (#745) — strict POSIX sh, needs curl.
#
# The Mac asked on a hook's reply, and the hook shim started this script
# detached, in a clean environment (`env -i HOME PATH LANG USER LOGNAME`),
# with stdin carrying the host token and nothing else. Two asks:
#
#   capture.sh readme <agent> <port> <session-id> <project-dir>
#   capture.sh draft <agent> <port> <session-id> <project-dir> <draft-id> <lock-dir> [<user-vibe-dir>]
#   capture.sh repository
#
# The draft's lock directory is the shim's one-draft-at-a-time lock; this
# script removes it when it ends.
#
# readme posts the first 16 KiB of the project's README to `/v1/readme`; the
# Mac keeps a summary of it for quick capture's router.
#
# draft first asks `/v1/draft/words` for the capture's search words, then
# posts the project's context to `/v1/draft/context` (#918): the README and
# AGENTS.md (or CLAUDE.md) openings, `git grep` hits for those words, and the
# open issues, recent closed issues and merged PRs when gh works here. The
# Mac writes the first draft from it; `/v1/draft/check` answers 202 while it
# does, 204 when no check is due (not an issue), or the check's prompt. A Mac
# from before #918 answers the words with an error, and the script falls back
# to posting the open issues to `/v1/draft/prompt` for the prompt to draft
# from scratch. Either way it runs the session's own agent headless in the
# project with the Mac's local drafting flags (QuickCaptureDraft.swift):
# read-only tools confined to the checkout, hooks and MCP off, 20 turns, a
# cost cap and a 360 s watchdog. The agent's output goes to `/v1/draft`.
# Nothing is filed: gh only lists issues and PRs, git only greps, and the
# agent has no shell.
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

# github_repo <remote-url>: its owner/name when it is a github.com URL
# (https, ssh with or without a port, git@github.com:), with or without
# `.git`; nothing otherwise. QuickCaptureFiling.repository(fromRemoteURL:)
# reads the same shapes on the Mac.
github_repo() {
  case "$1" in
  https://* | http://* | ssh://* | git://*)
    rest="${1#*://}"
    host="${rest%%/*}"
    path="${rest#"$host"}"
    host="${host##*@}"
    host="${host%%:*}"
    ;;
  *:*)
    host="${1%%:*}"
    host="${host##*@}"
    path="${1#*:}"
    ;;
  *) return 0 ;;
  esac
  [ "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" = github.com ] || return 0
  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  case "$path" in
  */*/* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-]*) ;;
  ?*/?*) echo "$path" ;;
  esac
}

# repository prints the owner/name of the current directory's origin when it
# is on github.com, and nothing otherwise: the hook shim sends it as
# X-Lvx-Env-Repository (#926), so the Mac files and describes the project
# without asking. It reads no token and starts nothing.
if [ "${1:-}" = repository ]; then
  ORIGIN="$(git remote get-url origin 2>/dev/null)" || exit 0
  github_repo "$ORIGIN"
  exit 0
fi

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

# The repository is origin's (#919): in a fork with an `upstream` remote,
# gh's own pick is the upstream. No origin: gh's pick. An origin off
# GitHub: no list.
REPO=""
if ORIGIN="$(git remote get-url origin 2>/dev/null)"; then
  REPO="$(github_repo "$ORIGIN")"
  [ -n "$REPO" ] || REPO="-"
fi

# bounded <seconds> <out-file> <command...>: runs the command into the file
# under the watchdog; an error, a timeout or no output leaves the file empty.
bounded() {
  seconds="$1"
  out="$2"
  shift 2
  "$@" >"$out" 2>/dev/null &
  BOUNDED=$!
  watch "$BOUNDED" "$seconds"
  if ! wait "$BOUNDED" || [ -e "$WORK/timedout" ]; then : >"$out"; fi
  rm -f "$WORK/timedout"
}

# Open issues, trimmed to what the prompt quotes: 60 issues, 200-character
# titles, 240-character bodies (QuickCaptureDraft.prompt). No gh, no login,
# no GitHub remote: an empty list, and the prompt says it could not be read.
: >"$WORK/issues"
if [ "$REPO" != - ] && command -v gh >/dev/null 2>&1; then
  bounded 20 "$WORK/issues.raw" gh issue list ${REPO:+--repo "$REPO"} --state open --limit 60 --json number,title,body \
    --jq '[.[] | {number, title: .title[0:200], body: (.body // "")[0:240]}]'
  head -c 49152 "$WORK/issues.raw" >"$WORK/issues" 2>/dev/null || : >"$WORK/issues"
fi

: >"$WORK/empty"
STATUS="$(post /v1/draft/words "$WORK/empty" "$WORK/words")" || STATUS=""
if [ "$STATUS" = 200 ]; then
  # The context bundle (QuickCaptureContext.parse): sections opened by an
  # `@@lvx <name>` line, each capped, the whole at 96 KiB.
  {
    echo '@@lvx readme'
    for name in README.md README readme.md README.markdown Readme.md; do
      if [ -f "$name" ] && [ -r "$name" ]; then
        head -c 16384 "$name" 2>/dev/null
        break
      fi
    done
    echo
    echo '@@lvx guide'
    for name in AGENTS.md CLAUDE.md; do
      if [ -f "$name" ] && [ -r "$name" ] && [ "$(wc -c <"$name" 2>/dev/null | tr -d '[:space:]')" -gt 200 ]; then
        head -c 32768 "$name" 2>/dev/null
        break
      fi
    done
    echo
  } >"$WORK/bundle" 2>/dev/null
  echo '@@lvx grep' >>"$WORK/bundle"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # The Mac's words: 8 at most, each a lowercase letter or digit, then
    # letters, digits, `_`, `.` or `-`, so none reads as an option.
    head -n 8 "$WORK/words" 2>/dev/null | while IFS= read -r word || [ -n "$word" ]; do
      case "$word" in
      [abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
      *) continue ;;
      esac
      case "$word" in
      *[!abcdefghijklmnopqrstuvwxyz0123456789_.-]*) continue ;;
      esac
      [ "${#word}" -le 40 ] || continue
      bounded 20 "$WORK/hits" git grep -n -I -i -F --max-count 2 -e "$word" --
      head -n 4 "$WORK/hits" 2>/dev/null | cut -c 1-400
    done >>"$WORK/bundle" 2>/dev/null
  fi
  echo '@@lvx open' >>"$WORK/bundle"
  cat "$WORK/issues" >>"$WORK/bundle" 2>/dev/null
  echo >>"$WORK/bundle"
  if [ "$REPO" != - ] && command -v gh >/dev/null 2>&1; then
    bounded 20 "$WORK/closed" gh issue list ${REPO:+--repo "$REPO"} --state closed --limit 40 --json number,title \
      --jq '[.[] | {number, title: .title[0:200]}]'
    bounded 20 "$WORK/merged" gh pr list ${REPO:+--repo "$REPO"} --state merged --limit 20 --json number,title \
      --jq '[.[] | {number, title: .title[0:200]}]'
    { echo '@@lvx closed'; head -c 16384 "$WORK/closed"; echo; echo '@@lvx merged'; head -c 8192 "$WORK/merged"; echo; } \
      >>"$WORK/bundle" 2>/dev/null
  fi
  head -c 98304 "$WORK/bundle" >"$WORK/bundle.capped" 2>/dev/null || exit 0
  STATUS="$(post /v1/draft/context "$WORK/bundle.capped" /dev/null)" || STATUS=""
  [ "$STATUS" = 200 ] || exit 0
  # The first draft takes up to 120 s on the Mac: poll every 3 s, 3 minutes.
  i=0
  while :; do
    STATUS="$(post /v1/draft/check "$WORK/empty" "$WORK/prompt")" || STATUS=""
    [ "$STATUS" = 202 ] || break
    i=$((i + 1))
    [ "$i" -lt 60 ] || exit 0
    sleep 3
  done
else
  STATUS="$(post /v1/draft/prompt "$WORK/issues" "$WORK/prompt")" || STATUS=""
fi
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
    --json-schema '{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"relation":{"type":"string","enum":["none","duplicate","extends"]},"issue":{"type":["integer","null"]},"files":{"type":"array","items":{"type":"string"}}},"required":["title","body","relation","issue","files"],"additionalProperties":false}' \
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
watch "$RUN" 360
wait "$RUN"
CODE=$?
[ ! -e "$WORK/timedout" ] || answer timeout
SIZE="$({ wc -c <"$WORK/out"; } 2>/dev/null | tr -d '[:space:]')"
case "$SIZE" in "" | *[!0-9]*) SIZE=0 ;; esac
[ "$SIZE" -le 61440 ] || answer capped
cp "$WORK/out" "$WORK/answer" 2>/dev/null || exit 0
answer "$CODE"
