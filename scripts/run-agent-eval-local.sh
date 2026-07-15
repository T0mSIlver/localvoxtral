#!/usr/bin/env bash
set -euo pipefail

# Run the wide agent-dictation eval directly from a Mac checkout. This is the
# natural companion to record-agent-eval.sh: voice data stays on the Mac where
# it was captured, while the env gate avoids creating a transient marker.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECORDING_DIR=""
RECORDING_SUBSET=0
POLISH_ENDPOINT=""
POLISH_MODEL=""
CASE_IDS=()

usage() {
  cat <<EOF
Usage: $0 [options] [EvalRecordings/agent-dictation/<set>]

  --subset                 Score only cases present in the recording manifest
  --polish-endpoint URL    Use an external OpenAI chat/completions endpoint
  --polish-model MODEL     Request model/alias for the external endpoint
  --case ID                Score one corpus case (repeat for a focused batch)

After the eval, a skim-friendly HTML report is written beside human WAVs and
opened in the default browser. It includes audio, ASR, polish, final text, and
ground truth. The report is still generated when a scored assertion fails.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subset)
      RECORDING_SUBSET=1
      shift
      ;;
    --polish-endpoint)
      [[ $# -ge 2 ]] || { echo "--polish-endpoint needs a URL" >&2; exit 1; }
      POLISH_ENDPOINT="$2"
      shift 2
      ;;
    --polish-model)
      [[ $# -ge 2 ]] || { echo "--polish-model needs a model name" >&2; exit 1; }
      POLISH_MODEL="$2"
      shift 2
      ;;
    --case)
      [[ $# -ge 2 ]] || { echo "--case needs an ID" >&2; exit 1; }
      [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid --case ID: $2" >&2; exit 1; }
      CASE_IDS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      [[ -z "$RECORDING_DIR" ]] || { echo "only one recording directory is allowed" >&2; exit 1; }
      RECORDING_DIR="$1"
      shift
      ;;
  esac
done
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
if [[ "$RECORDING_SUBSET" == "1" && -z "$RECORDING_DIR" ]]; then
  echo "--subset requires a recording-set directory" >&2
  exit 1
fi
if [[ -n "$POLISH_ENDPOINT" && ! "$POLISH_ENDPOINT" =~ ^https?:// ]]; then
  echo "--polish-endpoint must be an http:// or https:// URL" >&2
  exit 1
fi

HELPER="$ROOT_DIR/PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd"
if [[ -z "$POLISH_ENDPOINT" && ! -x "$HELPER" ]]; then
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
ENV_ARGS=(env LV_AGENT_EVAL_E2E_ENABLE=1)
if [[ -n "$RECORDING_DIR" ]]; then
  ENV_ARGS+=(LV_AGENT_EVAL_E2E_RECORDING_DIRECTORY="$RECORDING_DIR")
fi
if [[ "$RECORDING_SUBSET" == "1" ]]; then
  ENV_ARGS+=(LV_AGENT_EVAL_E2E_RECORDING_SUBSET=1)
fi
if [[ -n "$POLISH_ENDPOINT" ]]; then
  ENV_ARGS+=(LV_AGENT_EVAL_E2E_POLISH_ENDPOINT="$POLISH_ENDPOINT")
fi
if [[ -n "$POLISH_MODEL" ]]; then
  ENV_ARGS+=(LV_AGENT_EVAL_E2E_POLISH_MODEL="$POLISH_MODEL")
fi
if [[ ${#CASE_IDS[@]} -gt 0 ]]; then
  CASE_ID_LIST="$(IFS=,; echo "${CASE_IDS[*]}")"
  ENV_ARGS+=(LV_AGENT_EVAL_E2E_CASE_IDS="$CASE_ID_LIST")
fi

mkdir -p .build
LOG_FILE="$ROOT_DIR/.build/agent-eval-local.log"
echo "Full eval output: $LOG_FILE"
set +e
"${ENV_ARGS[@]}" swift test --filter AgentDictationE2EEvalTests 2>&1 | tee "$LOG_FILE"
TEST_STATUS=${PIPESTATUS[0]}
set -e

REPORT_ARGS=(--open "$LOG_FILE")
if [[ -n "$RECORDING_DIR" ]]; then
  REPORT_ARGS+=("$ROOT_DIR/$RECORDING_DIR")
fi
if ! "$ROOT_DIR/scripts/render-agent-eval-report.sh" "${REPORT_ARGS[@]}"; then
  echo "WARN: eval finished but the HTML report could not be generated" >&2
fi
exit "$TEST_STATUS"
