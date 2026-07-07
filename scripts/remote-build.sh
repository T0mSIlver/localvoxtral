#!/usr/bin/env bash
set -euo pipefail

# Build/test this repo on the Mac build host. The app targets macOS, so on a
# non-Mac dev box this is the compile/test inner loop: it rsyncs the working
# tree (no commit needed) and runs the toolchain remotely over SSH.
#
# Usage:
#   ./scripts/remote-build.sh [build|test|integration|integration-polishd|eval-llm|package|exec|diag|applog|voxlog|svc-status] [extra args...]
#     build        swift build
#     test         swift build + unit tests (default; skips live-backend suites)
#     integration  realtime pipeline tests against the live voxmlx service
#     integration-polishd
#                  spawn the bundled polishing helper (built by `package`)
#                  with the real model and score it against the polish eval
#                  baseline + parent-pid tether
#     eval-llm     default-polish-prompt eval against a live mlx-lm server;
#                  optional arg = chat/completions endpoint (default
#                  http://127.0.0.1:8080/v1/chat/completions, the
#                  com.localvoxtral.mlxlm service — runbook scripts/mac/README.md)
#     package      ./scripts/package_app.sh release
#     exec         run the extra args verbatim in the remote work dir
#     diag         build-host diagnostic summary (gate v2 required)
#     applog       unified log for process == "localvoxtral" (gate v2 required)
#     voxlog       tail ~/Library/Logs/voxmlx.log (gate v2 required)
#     svc-status   launchctl status for com.localvoxtral.voxmlx (gate v2 required)
#
# Examples:
#   ./scripts/remote-build.sh
#   ./scripts/remote-build.sh test --filter TextMergingAlgorithmsTests
#   ./scripts/remote-build.sh exec swift test --list-tests
#
# The build host is machine-local configuration, never committed. Resolution
# order:
#   1. LV_BUILD_HOST env var (ssh destination, e.g. user@host or an ssh alias)
#   2. git config localvoxtral.buildhost   (set once per clone, lives in .git/config)
# Optional: LV_BUILD_DIR — remote work dir, ~-relative. Defaults to a
# per-worktree name derived from the local checkout path, so parallel agents
# in separate worktrees never contend on remote build state or its SwiftPM
# lock. The full remote output of every run is also written to
# .build/last-remote.log, so a crash mid-run can never eat the failing test's
# name (don't pipe this script straight into grep — grep the log file).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${LV_BUILD_HOST:-$(git -C "$ROOT_DIR" config --get localvoxtral.buildhost || true)}"

TREE_SLUG="$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
TREE_SLUG="${TREE_SLUG%-}"
TREE_HASH="$(printf '%s' "$ROOT_DIR" | md5sum | cut -c1-8)"
DIR="${LV_BUILD_DIR:-work/localvoxtral-${TREE_SLUG}-${TREE_HASH}}"

REMOTE_LOG="$ROOT_DIR/.build/last-remote.log"

run_remote() {
  local remote_command="$1"
  local status=0
  mkdir -p "$(dirname "$REMOTE_LOG")"
  echo "==> Running on $HOST: $remote_command"
  ssh "$HOST" "$remote_command" 2>&1 | tee "$REMOTE_LOG" || status=$?
  echo "==> Full output: $REMOTE_LOG"
  return "$status"
}

if [[ -z "$HOST" ]]; then
  cat >&2 <<'MSG'
No build host configured. Point this script at a Mac with the Swift toolchain
and SSH key auth, either persistently for this clone:

  git config localvoxtral.buildhost <ssh-destination>

or per invocation:

  LV_BUILD_HOST=<ssh-destination> ./scripts/remote-build.sh ...

<ssh-destination> can be user@host or a Host alias from ~/.ssh/config.
MSG
  exit 1
fi

CMD="${1:-test}"
if [[ $# -gt 0 ]]; then shift; fi

quote_remote_command() {
  local first="${1:?}"
  shift
  printf '%q' "$first"
  if [[ $# -gt 0 ]]; then
    printf ' %q' "$@"
  fi
}

case "$CMD" in
  diag|svc-status)
    if [[ $# -ne 0 ]]; then
      echo "$CMD does not accept extra arguments" >&2
      exit 1
    fi
    run_remote "$(quote_remote_command "$CMD")"
    exit $?
    ;;
  applog|voxlog)
    if [[ $# -gt 1 ]]; then
      echo "$CMD accepts at most one numeric argument" >&2
      exit 1
    fi
    run_remote "$(quote_remote_command "$CMD" "$@")"
    exit $?
    ;;
esac

UNIT_TEST_SKIPS=(--skip RealtimeAPIVLLMIntegrationTests --skip LLMPolishPromptEvalTests
  --skip PolishHelperIntegrationTests)

case "$CMD" in
  build)   REMOTE_CMD=(swift build "$@") ;;
  test)    REMOTE_CMD=(swift test "${UNIT_TEST_SKIPS[@]}" "$@") ;;
  integration)
    REMOTE_CMD=(env VLLM_REALTIME_TEST_ENABLE=1
      VLLM_REALTIME_TEST_MODEL=T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit
      swift test --filter RealtimeAPIVLLMIntegrationTests "$@")
    ;;
  integration-polishd)
    # Same marker-through-the-tree pattern as eval-llm (the gate pins env
    # prefixes per-command). Requires a helper binary from a prior
    # `./scripts/remote-build.sh package` run — the remote PolishHelper/.build
    # tree survives rsync (excluded from --delete).
    if [[ $# -ne 0 ]]; then
      echo "integration-polishd does not accept extra arguments" >&2
      exit 1
    fi
    POLISHD_MARKER="$ROOT_DIR/.polishd-integration-enable.json"
    trap 'rm -f "$POLISHD_MARKER"' EXIT
    printf '{"helperPath": "%s"}\n' \
      "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd" \
      >"$POLISHD_MARKER"
    REMOTE_CMD=(swift test --filter PolishHelperIntegrationTests)
    ;;
  eval-llm)
    # Enablement travels as a gitignored marker file inside the synced tree
    # (removed again on exit): the build gate only allowlists exact
    # `swift test ...` payloads, so env prefixes can't be passed per-run.
    if [[ $# -gt 1 ]]; then
      echo "eval-llm accepts at most one argument (the chat/completions endpoint)" >&2
      exit 1
    fi
    EVAL_ENDPOINT="${1:-http://127.0.0.1:8080/v1/chat/completions}"
    EVAL_MARKER="$ROOT_DIR/.llm-polish-eval-enable.json"
    # Trap registered before the marker exists, so no kill window leaves a
    # stale marker behind.
    trap 'rm -f "$EVAL_MARKER"' EXIT
    printf '{"endpoint": "%s"}\n' "$EVAL_ENDPOINT" >"$EVAL_MARKER"
    REMOTE_CMD=(swift test --filter LLMPolishPromptEvalTests)
    ;;
  package) REMOTE_CMD=(./scripts/package_app.sh release "$@") ;;
  exec)
    if [[ $# -eq 0 ]]; then
      echo "exec requires a command, e.g.: $0 exec swift test --list-tests" >&2
      exit 1
    fi
    REMOTE_CMD=("$@")
    ;;
  *)
    echo "Usage: $0 [build|test|integration|integration-polishd|eval-llm|package|exec|diag|applog|voxlog|svc-status] [extra args...]" >&2
    exit 1
    ;;
esac

echo "==> Syncing working tree to $HOST:$DIR"
ssh "$HOST" "mkdir -p $(printf '%q' "$DIR")"
# .build/ and dist/ are excluded from deletion too, so the remote incremental
# build state survives between runs.
rsync -az --delete \
  --exclude '.git/' --exclude '.build/' --exclude 'dist/' \
  "$ROOT_DIR/" "$HOST:$DIR/"

run_remote "cd $(printf '%q' "$DIR") && $(printf '%q ' "${REMOTE_CMD[@]}")"
