#!/usr/bin/env bash
# Regression test for the X-Lvx-Skills header both remote shims send (#1024):
# the Claude Code plugin's hooks/post.sh on SessionStart, the Vibe remote
# post.sh at a turn's end.
#
# Builds a home folder with skills, commands, a plugin's skills and names the
# Mac refuses, runs each shim with a stub curl that keeps the header file it
# was handed, and checks the header's value, or that there is none.
#
# Needs python3 (the Vibe shim's compactor), no network:
#   ./scripts/ci/test-remote-shim-skills.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLAUDE_SHIM="$ROOT_DIR/integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh"
VIBE_DIR_SRC="$ROOT_DIR/integrations/vibe/remote"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-shim-skills-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# --- Fixtures ----------------------------------------------------------------
HOME_DIR="$TMP_DIR/home"
skill() { mkdir -p "$HOME_DIR/$1" && : >"$HOME_DIR/$1/SKILL.md"; }
skill .claude/skills/unslop
skill .claude/skills/gh-stack
skill .codex/skills/unslop
skill .config/opencode/skills/test-audit
skill .claude/plugins/cache/official/frontend-design/1.0.0/skills/frontend-design
skill ".claude/skills/two words"
skill .claude/skills/.hidden
skill .claude/skills/-dash
mkdir -p "$HOME_DIR/.claude/skills/synced" "$HOME_DIR/.claude/commands"
: >"$HOME_DIR/.claude/skills/README.md"
: >"$HOME_DIR/.claude/commands/ship.md"
: >"$HOME_DIR/.claude/commands/README.md"
PROJECT="$TMP_DIR/project"
mkdir -p "$PROJECT/.claude/skills/release"
: >"$PROJECT/.claude/skills/release/SKILL.md"
EMPTY_HOME="$TMP_DIR/empty-home"
mkdir -p "$EMPTY_HOME"

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

VIBE_DIR="$TMP_DIR/vibe"
mkdir -p "$VIBE_DIR"
cp "$VIBE_DIR_SRC/post.sh" "$VIBE_DIR_SRC/compact.py" "$VIBE_DIR/"
echo token >"$VIBE_DIR/token"
echo 18473 >"$VIBE_DIR/port"
TRANSCRIPT="$TMP_DIR/messages.jsonl"
echo '{"role": "user", "content": "ship it", "injected": false}' >"$TRANSCRIPT"
vibe_payload() {
  printf '{"session_id":"7f4aefdf","transcript_path":"%s","cwd":"/srv/app","parent_session_id":null,"hook_event_name":"%s"}' \
    "$TRANSCRIPT" "$1"
}

SHELLS=(/bin/sh)
BASH_BIN="$(command -v bash || true)"
if [ -n "$BASH_BIN" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$BASH_BIN")" ]; then
  mkdir -p "$TMP_DIR/bash-as-sh"
  ln -s "$BASH_BIN" "$TMP_DIR/bash-as-sh/sh"
  SHELLS+=("$TMP_DIR/bash-as-sh/sh")
fi

# run_shim <claude|vibe> <event> <home>: the header file the shim handed curl
# is left in $TMP_DIR/capture.
run_shim() {
  local capture="$TMP_DIR/capture"
  rm -f "$capture"
  (
    cd "$PROJECT"
    if [ "$1" = claude ]; then
      printf '{"session_id":"s1"}' | env -i PATH="$STUB:$PATH" HOME="$3" \
        XDG_RUNTIME_DIR="$TMP_DIR/run" CAPTURE="$capture" \
        CLAUDE_PLUGIN_OPTION_TOKEN=unit-test-token "$SH" "$CLAUDE_SHIM" "$2" >/dev/null
    else
      vibe_payload "$2" | env -i PATH="$STUB:$PATH" HOME="$3" \
        XDG_RUNTIME_DIR="$TMP_DIR/run" CAPTURE="$capture" \
        LOCALVOXTRAL_VIBE_REMOTE_DIR="$VIBE_DIR" LOCALVOXTRAL_VIBE_WATCHER=off "$SH" "$VIBE_DIR/post.sh" >/dev/null
    fi
  )
  [ -r "$capture" ] || fail "$1 shim ($2) never reached curl"
}

expect() {
  local agent="$1" event="$2" home="$3" want="$4" got
  run_shim "$agent" "$event" "$home"
  got="$(sed -n 's/^X-Lvx-Skills: //p' "$TMP_DIR/capture")"
  [ "$got" = "$want" ] || fail "$agent shim under $SH_NAME ($event): X-Lvx-Skills '$got', want '$want'"
  pass "$agent shim under $SH_NAME ($event): '$want'"
}

ALL="gh-stack,unslop,test-audit,frontend-design,ship,release"
for SH in "${SHELLS[@]}"; do
  case "$SH" in */bash-as-sh/sh) SH_NAME=bash ;; *) SH_NAME=/bin/sh ;; esac
  expect claude SessionStart "$HOME_DIR" "$ALL"
  expect claude Stop "$HOME_DIR" ""
  expect claude SessionStart "$EMPTY_HOME" "release"
  expect vibe post_agent "$HOME_DIR" "$ALL"
  expect vibe post_tool "$HOME_DIR" ""
done

# The Mac reads the header under this exact name (AgentSkillNamesCodec).
grep -q 'headerName = "X-Lvx-Skills"' "$ROOT_DIR/Sources/ClaudeContextWire/AgentSkillNamesCodec.swift" \
  || fail "the Swift codec no longer reads X-Lvx-Skills"
pass "the header name matches the Swift codec"
