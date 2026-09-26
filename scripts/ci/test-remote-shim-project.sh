#!/usr/bin/env bash
# Regression test for the X-Lvx-Env-Project header both remote shims send
# (#652): the Claude Code plugin's hooks/post.sh and the Vibe remote post.sh.
#
# Builds real repositories with git (a main checkout, a worktree inside it, one
# outside it, a submodule, a bare repository's worktree, and names outside the
# label charset), runs each shim from inside them with a stub curl that keeps
# the header file it was handed, and checks the header's value, or that there
# is none.
#
# Needs git and python3 (the Vibe shim's compactor), no network:
#   ./scripts/ci/test-remote-shim-project.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLAUDE_SHIM="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh"
VIBE_DIR_SRC="$ROOT_DIR/integrations/vibe/remote"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-project-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Git that ignores the runner's own configuration and identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

new_repo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

# --- Fixtures ----------------------------------------------------------------
new_repo "$TMP_DIR/work/repo"
mkdir -p "$TMP_DIR/work/repo/Sources/deep"
git -C "$TMP_DIR/work/repo" worktree add -q "$TMP_DIR/work/repo/.claude/worktrees/bold-bose" 2>/dev/null
git -C "$TMP_DIR/work/repo" worktree add -q "$TMP_DIR/elsewhere/repo-fix" 2>/dev/null
mkdir -p "$TMP_DIR/elsewhere/repo-fix/Sources"

new_repo "$TMP_DIR/work/lib"
git -C "$TMP_DIR/work/repo" -c protocol.file.allow=always \
  submodule add -q "$TMP_DIR/work/lib" vendor/lib 2>/dev/null

new_repo "$TMP_DIR/seed"
git clone -q --bare "$TMP_DIR/seed" "$TMP_DIR/work/api.git"
git -C "$TMP_DIR/work/api.git" worktree add -q "$TMP_DIR/work/api-feature" 2>/dev/null

new_repo "$TMP_DIR/work/my repo"
new_repo "$TMP_DIR/work/.dotted"
mkdir -p "$TMP_DIR/plain/dir"

# --- Stub curl: keeps the header file, answers 200 ----------------------------
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

# --- Vibe shim's private dir ---------------------------------------------------
VIBE_DIR="$TMP_DIR/vibe"
mkdir -p "$VIBE_DIR"
cp "$VIBE_DIR_SRC/post.sh" "$VIBE_DIR_SRC/compact.py" "$VIBE_DIR/"
echo token >"$VIBE_DIR/token"
echo 18473 >"$VIBE_DIR/port"
TRANSCRIPT="$TMP_DIR/messages.jsonl"
echo '{"role": "user", "content": "rename the wire enum", "injected": false}' >"$TRANSCRIPT"
VIBE_PAYLOAD="{\"session_id\":\"7f4aefdf\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"/srv/app\",\"parent_session_id\":null,\"hook_event_name\":\"post_agent\"}"

# Each shim runs under /bin/sh and under bash: macOS's /bin/sh is bash 3.2,
# which a Linux /bin/sh (dash) says nothing about, and bash in sh mode shares
# most of its parser.
SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

# project_header <claude|vibe> <cwd>: the header's value, empty when absent.
project_header() {
  local capture="$TMP_DIR/capture-$1"
  rm -f "$capture"
  (
    cd "$2"
    if [ "$1" = claude ]; then
      printf '{"session_id":"s1"}' | env -i PATH="$STUB:$PATH" HOME="$TMP_DIR" \
        XDG_RUNTIME_DIR="$TMP_DIR/run" CAPTURE="$capture" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token LVX_PROJECT=inherited \
        "$SH" "$CLAUDE_SHIM" Stop >/dev/null
    else
      printf '%s' "$VIBE_PAYLOAD" | env -i PATH="$STUB:$PATH" HOME="$TMP_DIR" \
        XDG_RUNTIME_DIR="$TMP_DIR/run" CAPTURE="$capture" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        LOCALVOXTRAL_VIBE_REMOTE_DIR="$VIBE_DIR" LOCALVOXTRAL_VIBE_WATCHER=off \
        LVX_PROJECT=inherited "$SH" "$VIBE_DIR/post.sh" >/dev/null
    fi
  )
  [ -r "$capture" ] || fail "$1 shim in $2 never reached curl"
  sed -n 's/^X-Lvx-Env-Project: //p' "$capture"
}

expect() {
  local agent="$1" dir="$2" want="$3" got
  got="$(project_header "$agent" "$dir")"
  [ "$got" = "$want" ] \
    || fail "$agent shim under $SH_NAME in ${dir#"$TMP_DIR"/}: X-Lvx-Env-Project '$got', want '$want'"
  pass "$agent shim under $SH_NAME in ${dir#"$TMP_DIR"/}: '${want}'"
}

for SH in "${SHELLS[@]}"; do
case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac
for agent in claude vibe; do
  expect "$agent" "$TMP_DIR/work/repo" repo
  expect "$agent" "$TMP_DIR/work/repo/Sources/deep" repo
  expect "$agent" "$TMP_DIR/work/repo/.claude/worktrees/bold-bose" repo
  expect "$agent" "$TMP_DIR/elsewhere/repo-fix/Sources" repo
  expect "$agent" "$TMP_DIR/work/repo/vendor/lib" lib
  expect "$agent" "$TMP_DIR/work/api-feature" api.git
  # No repository, or a name outside the label charset: no header, and an
  # inherited LVX_PROJECT is never sent in its place.
  expect "$agent" "$TMP_DIR/plain/dir" ""
  expect "$agent" "$TMP_DIR/work/my repo" ""
  expect "$agent" "$TMP_DIR/work/.dotted" ""
done
done

# The Mac reads the header under this exact name (ClaudeRemoteEnvironmentField).
grep -q 'case .project: return "X-Lvx-Env-Project"' \
  "$ROOT_DIR/Sources/ClaudeContextWire/ClaudeRemoteSessionEnvironment.swift" \
  || fail "the Swift allowlist no longer reads X-Lvx-Env-Project"
pass "the header name matches the Swift allowlist"
