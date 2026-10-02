#!/usr/bin/env bash
# Regression test for the X-Lvx-Agent-Projects header the Claude Code remote
# shim sends on SessionStart (#1027).
#
# agent-projects.sh runs against a home folder of Claude Code transcripts
# whose `cwd` points at fixture repositories: one with an origin, a worktree
# of it, an old transcript, a repository without origin, a cwd that is gone,
# names the Mac refuses and a transcript quoting `"cwd":"/evil"` in a message
# before its real key. post.sh then runs from a copy of the hooks folder whose
# agent-projects.sh is a stub recording that it was started, with a stub curl
# that keeps the header file it was handed.
#
# Needs git, no network:
#   ./scripts/ci/test-remote-shim-agent-projects.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOKS="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-agent-projects-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

NOW="$(date +%s)"
DAY=86400
# set_mtime <file> <epoch>: GNU date reads `-d @epoch`, BSD date `-r epoch`.
set_mtime() {
  local stamp
  stamp="$(date -d "@$2" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$2" +%Y%m%d%H%M.%S)"
  touch -t "$stamp" "$1"
}

# --- Fixture repositories ----------------------------------------------------
SRC="$TMP_DIR/src"
mkdir -p "$SRC"
repo() {
  git init -q "$SRC/$1"
  git -C "$SRC/$1" commit -q --allow-empty -m init
  [ -z "${2:-}" ] || git -C "$SRC/$1" remote add origin "$2"
}
repo alpha https://github.com/acme/alpha.git
git -C "$SRC/alpha" worktree add -q -b feature "$SRC/alpha-feature"
repo beta git@gitlab.com:team/beta.git
repo gamma https://github.com/acme/gamma.git
repo delta
repo "bad name" https://github.com/acme/badname.git
repo .hidden https://github.com/acme/hidden.git

# --- Fixture transcripts -----------------------------------------------------
HOME_DIR="$TMP_DIR/home"
PROJECTS="$HOME_DIR/.claude/projects"
# transcript <folder> <file> <epoch> <line>...: a transcript with those lines.
transcript() {
  local dir="$PROJECTS/$1" file="$2" epoch="$3"
  shift 3
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/$file"
  set_mtime "$dir/$file" "$epoch"
}
record() { printf '{"parentUuid":null,"isSidechain":false,"cwd":"%s","sessionId":"s","message":{"cwd":"/nested"}}' "$1"; }
SNAPSHOT='{"type":"file-history-snapshot","messageId":"m"}'

E_ALPHA=$((NOW - 2 * DAY))
E_WORKTREE=$((NOW - 1 * DAY))
E_BETA=$((NOW - 3 * DAY))
# The main checkout, and an older transcript in the same folder pointing at
# gamma: only the folder's newest transcript counts.
transcript "-src-alpha" a1.jsonl "$E_ALPHA" "$SNAPSHOT" "$(record "$SRC/alpha")"
transcript "-src-alpha" a0.jsonl $((NOW - 4 * DAY)) "$(record "$SRC/gamma")"
# A worktree of alpha: same name, newer, so its epoch wins.
transcript "-src-alpha-feature" w.jsonl "$E_WORKTREE" "$(record "$SRC/alpha-feature")"
# An escaped "cwd" inside a message comes first; the real key follows.
transcript "-src-beta" b.jsonl "$E_BETA" \
  '{"type":"summary","summary":"say \"cwd\":\"/evil\" here","x":"\\"}' "$(record "$SRC/beta")"
# Older than 30 days.
transcript "-src-gamma" g.jsonl $((NOW - 40 * DAY)) "$(record "$SRC/gamma")"
# No origin, gone, outside the charset, a dot name, an escaped value.
transcript "-src-delta" d.jsonl "$NOW" "$(record "$SRC/delta")"
transcript "-src-gone" x.jsonl "$NOW" "$(record "$SRC/gone")"
transcript "-src-bad-name" n.jsonl "$NOW" "$(record "$SRC/bad name")"
transcript "-src--hidden" h.jsonl "$NOW" "$(record "$SRC/.hidden")"
transcript "-src-escaped" e.jsonl "$NOW" '{"cwd":"C:\\src\\alpha"}'
# A folder with no transcript at all.
mkdir -p "$PROJECTS/-src-empty"

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi
DASH_BIN="$(command -v dash || true)"
if [ -n "$DASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$DASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/dash-as-sh"
  ln -s "$DASH_BIN" "$TMP_DIR/dash-as-sh/sh"
  SHELLS+=("$TMP_DIR/dash-as-sh/sh")
fi

WANT="$E_WORKTREE:alpha:acme/alpha,$E_BETA:beta:gitlab.com/team/beta"

# --- The hooks folder post.sh runs from: a stub scan ------------------------
SHIM_DIR="$TMP_DIR/hooks"
mkdir -p "$SHIM_DIR"
cp "$HOOKS/post.sh" "$HOOKS/capture.sh" "$SHIM_DIR/"
cat >"$SHIM_DIR/agent-projects.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$TMP_DIR/scan-args.tmp" && mv "$TMP_DIR/scan-args.tmp" "$TMP_DIR/scan-args"
EOF

STUB="$TMP_DIR/stub"
mkdir -p "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
  --header) case "$2" in @*) cp "${2#@}" "$CAPTURE" ;; esac; shift ;;
  esac
  shift
done
printf '200'
EOF
chmod +x "$STUB/curl"

RUN="$TMP_DIR/run"
CACHE="$RUN/localvoxtral/agent-projects"
LOCK="$CACHE-running"

# run_shim <event>: the header file the shim handed curl is left in
# $TMP_DIR/capture.
run_shim() {
  rm -f "$TMP_DIR/capture"
  (
    cd "$SRC/alpha"
    printf '{"session_id":"s1"}' | env -i PATH="$STUB:$PATH" HOME="$HOME_DIR" \
      XDG_RUNTIME_DIR="$RUN" CAPTURE="$TMP_DIR/capture" \
      CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token "$SH" "$SHIM_DIR/post.sh" "$1" >"$TMP_DIR/stdout"
  )
  [ -r "$TMP_DIR/capture" ] || fail "shim under $SH_NAME ($1) never reached curl"
  [ ! -s "$TMP_DIR/stdout" ] || fail "shim under $SH_NAME ($1) printed something"
}
sent() { sed -n 's/^X-Lvx-Agent-Projects: //p' "$TMP_DIR/capture"; }
reset_state() {
  rm -rf "$RUN" "$TMP_DIR/scan-args"
  mkdir -p "$RUN/localvoxtral"
  chmod 700 "$RUN" "$RUN/localvoxtral"
}
write_cache() { printf '%s\n%s\n' "$1" "$2" >"$CACHE"; }

for SH in "${SHELLS[@]}"; do
  case "$SH" in
  */bash-as-sh/sh) SH_NAME=bash ;;
  */dash-as-sh/sh) SH_NAME=dash ;;
  *) SH_NAME=/bin/sh ;;
  esac

  # The scan itself.
  got="$(env -i PATH="$PATH" HOME="$HOME_DIR" "$SH" "$HOOKS/agent-projects.sh")"
  [ "$got" = "$WANT" ] || fail "agent-projects.sh under $SH_NAME printed '$got', want '$WANT'"
  pass "agent-projects.sh under $SH_NAME: '$got'"
  got="$(env -i PATH="$PATH" HOME="$TMP_DIR/nowhere" "$SH" "$HOOKS/agent-projects.sh")"
  [ -z "$got" ] || fail "agent-projects.sh under $SH_NAME without transcripts printed '$got'"
  pass "agent-projects.sh under $SH_NAME without transcripts prints nothing"

  # The refresh writes the cache and drops the lock.
  reset_state
  mkdir "$LOCK"
  env -i PATH="$PATH" HOME="$HOME_DIR" "$SH" "$HOOKS/agent-projects.sh" refresh "$CACHE" "$LOCK"
  [ ! -e "$LOCK" ] || fail "refresh under $SH_NAME left its lock"
  { IFS= read -r scanned && IFS= read -r value; } <"$CACHE" || fail "refresh under $SH_NAME wrote no cache"
  [ "$scanned" -ge "$NOW" ] || fail "refresh under $SH_NAME stamped '$scanned'"
  [ "$value" = "$WANT" ] || fail "refresh under $SH_NAME cached '$value'"
  [ "$(LC_ALL=C ls -l "$CACHE" | cut -c1-10)" = "-rw-------" ] || fail "refresh under $SH_NAME: cache not 0600"
  pass "refresh under $SH_NAME writes the cache and drops the lock"

  # A fresh cache is sent on SessionStart and starts no scan.
  reset_state
  write_cache "$NOW" "$WANT"
  run_shim SessionStart
  [ "$(sent)" = "$WANT" ] || fail "fresh cache under $SH_NAME sent '$(sent)'"
  [ ! -e "$LOCK" ] || fail "fresh cache under $SH_NAME started a scan"
  pass "fresh cache under $SH_NAME: sent, no scan"

  # Other events never send it, and never scan, even with a stale cache that
  # SessionStart would both send and rescan.
  for event in UserPromptSubmit Stop SessionEnd; do
    reset_state
    write_cache $((NOW - 7 * 3600)) "$WANT"
    run_shim "$event"
    [ -z "$(sent)" ] || fail "$event under $SH_NAME sent '$(sent)'"
    [ ! -e "$LOCK" ] || fail "$event under $SH_NAME started a scan"
  done
  pass "other events under $SH_NAME: nothing sent, no scan"

  # A stale cache is still sent, and starts one detached scan.
  reset_state
  write_cache $((NOW - 7 * 3600)) "$WANT"
  run_shim SessionStart
  [ "$(sent)" = "$WANT" ] || fail "stale cache under $SH_NAME sent '$(sent)'"
  [ -d "$LOCK" ] || fail "stale cache under $SH_NAME took no lock"
  wait_for "$TMP_DIR/scan-args" || fail "stale cache under $SH_NAME started no scan"
  [ "$(cat "$TMP_DIR/scan-args")" = "$(printf 'refresh\n%s\n%s' "$CACHE" "$LOCK")" ] \
    || fail "stale cache under $SH_NAME started the scan with '$(cat "$TMP_DIR/scan-args")'"
  pass "stale cache under $SH_NAME: sent, scan started"

  # A held lock starts no second scan; a lock 10 minutes old is taken over.
  rm -f "$TMP_DIR/scan-args"
  run_shim SessionStart
  [ -d "$LOCK" ] || fail "held lock under $SH_NAME vanished"
  [ ! -e "$TMP_DIR/scan-args" ] || fail "held lock under $SH_NAME: a second scan started"
  set_mtime "$LOCK" $((NOW - 11 * 60))
  run_shim SessionStart
  wait_for "$TMP_DIR/scan-args" || fail "stale lock under $SH_NAME was not taken over"
  pass "lock under $SH_NAME: one scan at a time, a dead one taken over"

  # No cache: nothing sent, a scan started.
  reset_state
  run_shim SessionStart
  [ -z "$(sent)" ] || fail "no cache under $SH_NAME sent '$(sent)'"
  wait_for "$TMP_DIR/scan-args" || fail "no cache under $SH_NAME started no scan"
  pass "no cache under $SH_NAME: nothing sent, scan started"

  # A damaged value sends nothing; a damaged stamp rescans.
  for bad in "$NOW:alpha:acme/alpha x" "$NOW:alpha:acme/alpha;rm" "$(printf '%s\r' "$WANT")"; do
    reset_state
    write_cache "$NOW" "$bad"
    run_shim SessionStart
    [ -z "$(sent)" ] || fail "damaged cache under $SH_NAME sent '$(sent)'"
  done
  reset_state
  write_cache "$NOW$NOW$NOW" "$WANT"
  run_shim SessionStart
  wait_for "$TMP_DIR/scan-args" || fail "damaged stamp under $SH_NAME started no scan"
  pass "damaged cache under $SH_NAME: nothing sent; damaged stamp rescans"
done
