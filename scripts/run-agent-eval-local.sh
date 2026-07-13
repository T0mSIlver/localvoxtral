#!/usr/bin/env bash
set -euo pipefail

# Run the wide agent-dictation eval directly from a Mac checkout. This is the
# natural companion to record-agent-eval.sh: voice data stays on the Mac where
# it was captured, while the env gate avoids creating a transient marker.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECORDING_DIR="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [EvalRecordings/agent-dictation/<set>]" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-agent-eval-local.sh must run from a macOS checkout" >&2
  echo "From Linux, use: ./scripts/remote-build.sh eval-e2e [recording-set]" >&2
  exit 1
fi
if [[ -n "$RECORDING_DIR" ]]; then
  if [[ ! "$RECORDING_DIR" =~ ^EvalRecordings/agent-dictation/[A-Za-z0-9._-]+$ ]]; then
    echo "recording directory must be EvalRecordings/agent-dictation/<set>" >&2
    exit 1
  fi
  if [[ ! -f "$ROOT_DIR/$RECORDING_DIR/manifest.json" ]]; then
    echo "recording manifest not found: $RECORDING_DIR/manifest.json" >&2
    exit 1
  fi
fi

HELPER="$ROOT_DIR/PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd"
if [[ ! -x "$HELPER" ]]; then
  echo "packaged polishing helper not found; run this first:" >&2
  echo "  ./scripts/package_app.sh release" >&2
  exit 1
fi

# Match remote-build.sh's best-effort warmup. The live test still fails loudly
# if voxmlx is unavailable, so missing on-demand infrastructure is not masked.
if ! "$ROOT_DIR/scripts/mac/lv-test-servers.sh" ensure voxmlx; then
  echo "WARN: could not warm voxmlx on demand; continuing to the live suite" >&2
fi

cd "$ROOT_DIR"
if [[ -n "$RECORDING_DIR" ]]; then
  env \
    LV_AGENT_EVAL_E2E_ENABLE=1 \
    LV_AGENT_EVAL_E2E_RECORDING_DIRECTORY="$RECORDING_DIR" \
    swift test --filter AgentDictationE2EEvalTests
else
  env LV_AGENT_EVAL_E2E_ENABLE=1 \
    swift test --filter AgentDictationE2EEvalTests
fi
