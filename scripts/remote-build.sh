#!/usr/bin/env bash
set -euo pipefail

# Build/test this repo on the Mac build host. The app targets macOS, so on a
# non-Mac dev box this is the compile/test inner loop: it rsyncs the working
# tree (no commit needed) and runs the toolchain remotely over SSH.
#
# Usage:
#   ./scripts/remote-build.sh [build|test|integration|package|exec] [extra args...]
#     build        swift build
#     test         swift build + unit tests (default; skips live-backend suites)
#     integration  realtime pipeline tests against the live voxmlx service
#     package      ./scripts/package_app.sh release
#     exec         run the extra args verbatim in the remote work dir
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
# Optional: LV_BUILD_DIR — remote work dir, ~-relative (default: work/localvoxtral-remote)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${LV_BUILD_HOST:-$(git -C "$ROOT_DIR" config --get localvoxtral.buildhost || true)}"
DIR="${LV_BUILD_DIR:-work/localvoxtral-remote}"

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

UNIT_TEST_SKIPS=(--skip RealtimeAPIVLLMIntegrationTests --skip MlxAudioTranscriptionIntegrationTests)

case "$CMD" in
  build)   REMOTE_CMD=(swift build "$@") ;;
  test)    REMOTE_CMD=(swift test "${UNIT_TEST_SKIPS[@]}" "$@") ;;
  integration)
    REMOTE_CMD=(env VLLM_REALTIME_TEST_ENABLE=1
      VLLM_REALTIME_TEST_MODEL=T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit
      swift test --filter RealtimeAPIVLLMIntegrationTests "$@")
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
    echo "Usage: $0 [build|test|integration|package|exec] [extra args...]" >&2
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

echo "==> Running on $HOST: ${REMOTE_CMD[*]}"
ssh "$HOST" "cd $(printf '%q' "$DIR") && $(printf '%q ' "${REMOTE_CMD[@]}")"
