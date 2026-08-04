#!/usr/bin/env bash
set -euo pipefail

# Build/test this repo on the Mac build host. The app targets macOS, so on a
# non-Mac dev box this is the compile/test inner loop: it rsyncs the working
# tree (no commit needed) and runs the toolchain remotely over SSH.
#
# Usage:
#   ./scripts/remote-build.sh [build|test|integration|integration-polishd|integration-speechd|speechd-bench|eval-llm|eval-e2e|dogfood|dogfood-package|package|exec|diag|applog|voxlog|svc-status|disk|gc] [extra args...]
#     build        swift build
#     test         swift build + unit tests (default; skips live-backend suites)
#     integration  realtime pipeline tests against the live speechd STT service
#     integration-polishd
#                  spawn the bundled polishing helper (built by `package`)
#                  with the real model and score it against the polish eval
#                  baseline + parent-pid tether
#     integration-speechd
#                  spawn the packaged speech helper (built by `package`),
#                  transcribe real audio through the production websocket
#                  client, and assert accuracy + delta + parent-pid contracts
#     speechd-bench run the packaged speech helper's streaming benchmark;
#                  optional args = seconds (default 60), cadence ms
#                  (default 100 = the production step cadence), and
#                  cache-limit-mb (default = the helper's built-in limit);
#                  requires a prior `package`
#     eval-llm     default-polish-prompt eval against a live chat/completions
#                  server (the bundled polishd test service by default);
#                  optional args = chat/completions endpoint and external
#                  model alias (default endpoint
#                  http://127.0.0.1:8080/v1/chat/completions, the
#                  com.localvoxtral.testpolishd service — runbook scripts/mac/README.md)
#     eval-e2e     agent-dictation end-to-end eval: human WAVs or TTS -> live
#                  voxmlx ASR -> bundled polishd via the production stop-commit
#                  path, scored against EvalCorpus/agent-dictation (run
#                  `package` first; optional arg = a complete recording-set
#                  directory made by scripts/record-agent-eval.sh)
#     dogfood      build the instrumented (LOCALVOXTRAL_DOGFOOD) tree and run
#                  the context-capture suite; the capture is a compile gate, so
#                  no other lane ever builds it
#     dogfood-package
#                  package an instrumented .app for hand-dogfooding (same
#                  bundle id, so the Accessibility grant survives; the artifact
#                  is identifiable by LVXDogfoodCapture in its Info.plist)
#     package      ./scripts/package_app.sh release
#     exec         run the extra args verbatim in the remote work dir
#     diag         build-host diagnostic summary (gate v2 required)
#     applog       unified log for process == "localvoxtral" (gate v2 required)
#     voxlog       tail the STT test-service log (gate v2 required; VOXLOG_FILE
#                  in the gate's conf, default the speechd service log)
#     svc-status   launchctl/process/port status for the speechd/polishd test
#                  services (gate v2 required)
#     disk         df + du of the remote build work dirs (gate v4 required;
#                  du over the build trees can take a while)
#     gc           delete remote work dirs unused > 14 days (gate v4 required;
#                  also fired automatically, best-effort, after every run —
#                  EvalRecordings inside a stale dir are always preserved)
#
# Examples:
#   ./scripts/remote-build.sh
#   ./scripts/remote-build.sh test --filter TextMergingAlgorithmsTests
#   ./scripts/remote-build.sh eval-e2e EvalRecordings/agent-dictation/owner
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

REMOTE_LOG="${LOCALVOXTRAL_REMOTE_LOG:-$ROOT_DIR/.build/last-remote.log}"
REMOTE_PAYLOAD_ACTIVE=0
REMOTE_REAP_ATTEMPTED=0

run_remote() {
  local remote_command="$1"
  local status=0
  mkdir -p "$(dirname "$REMOTE_LOG")"
  echo "==> Running on $HOST: $remote_command"
  ssh "$HOST" "$remote_command" 2>&1 | tee "$REMOTE_LOG" || status=$?
  echo "==> Full output: $REMOTE_LOG"
  return "$status"
}

reap_remote_workdir() {
  [[ "$REMOTE_REAP_ATTEMPTED" == "0" ]] || return 0
  REMOTE_REAP_ATTEMPTED=1
  echo "==> Reaping interrupted test processes in $HOST:$DIR"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "$HOST" "reap $(printf '%q' "$DIR")"; then
    echo "==> WARN: remote process cleanup unavailable; install the current" \
      "build gate + reaper from scripts/mac/README.md." >&2
  fi
}

handle_remote_signal() {
  local status="$1"
  # A second Ctrl-C while the best-effort reap SSH is running must not skip
  # existing EXIT traps that remove transient eval markers.
  trap '' HUP INT TERM
  if [[ "$REMOTE_PAYLOAD_ACTIVE" == "1" ]]; then
    reap_remote_workdir
  fi
  exit "$status"
}

run_remote_payload() {
  local remote_command="$1" status=0
  REMOTE_PAYLOAD_ACTIVE=1
  if run_remote "$remote_command"; then
    status=0
  else
    status=$?
  fi
  REMOTE_PAYLOAD_ACTIVE=0
  if (( status != 0 )); then
    reap_remote_workdir
  fi
  return "$status"
}

trap 'handle_remote_signal 129' HUP
trap 'handle_remote_signal 130' INT
trap 'handle_remote_signal 143' TERM

# Bring an on-demand test server up (and warm) before a suite that needs it.
# The build host's speechd (8000, STT) and polishd (8080, chat/completions)
# launchd test services are launch-on-demand (scripts/mac/lv-test-servers.sh)
# so their model weights are not resident 24/7; this asks the SSH build gate's
# `ensure` verb to touch the trigger and block until the port is healthy. It
# also resets the idle window, so a burst of runs reuses the warm process.
#
# Names: we send the current name (speechd/polishd) first, then fall back to the
# deprecated alias (voxmlx/mlxlm) if the INSTALLED gate is old and denies the
# new one — the new gate accepts both, an un-reinstalled gate accepts only the
# old ones, so this bridges the reinstall window either way.
#
# Best-effort: warming is an optimization, not the gate — the test suite itself
# fails loudly if the server is actually unreachable. During rollout the
# on-demand infra is a one-time owner install (scripts/mac/README.md); until
# then the gate's `ensure` errors (run dir absent) but the server still serves
# the suite, so a warm failure must NOT abort the run.
ensure_remote_server() {
  local name="$1" alias=""
  case "$name" in
    speechd) alias="voxmlx" ;;
    polishd) alias="mlxlm" ;;
  esac
  echo "==> Ensuring on-demand test server '$name' is warm on $HOST"
  if ssh "$HOST" "ensure $name"; then
    return 0
  fi
  if [[ -n "$alias" ]]; then
    echo "==> '$name' not accepted; retrying with deprecated alias '$alias' (old gate)"
    if ssh "$HOST" "ensure $alias"; then
      return 0
    fi
  fi
  echo "==> WARN: could not warm '$name' on-demand (infra not installed, or gate" \
       "lacks the ensure verb). Continuing — the suite will fail if it's really down." >&2
}

# Transient enable markers ride the rsynced tree because the gate can't pass
# env vars per-run. Their EXIT trap must clean BOTH sides: removing only the
# local copy leaves the marker in the remote work dir, where any later direct
# `swift test` (or an interrupted run reusing the dir before a fresh sync)
# would silently enable the marker-gated live suite. The gate allowlists no
# `rm`, so remote cleanup is a second rsync of the now-marker-free tree —
# byte-identical client invocation to the main sync, so the gate's pinned
# server-argument check still passes and --delete drops the marker. Skipped
# when the main sync never ran (nothing was uploaded); best-effort (|| true)
# because a host that died mid-run must not wedge the exit path — the next
# real sync deletes the marker anyway.
TREE_SYNCED=0
cleanup_transient_marker() {
  local marker="$1"
  rm -f "$marker"
  if [[ "$TREE_SYNCED" == "1" ]]; then
    # A recording set may exist only in the remote Mac checkout. Protect it
    # from --delete during marker cleanup just as in the main tree sync.
    rsync -az --delete \
      --filter='P /.lv-last-used' \
      --filter='P EvalRecordings/***' \
      --exclude '.git/' --exclude '.build/' --exclude 'dist/' \
      "$ROOT_DIR/" "$HOST:$DIR/" 2>/dev/null || true
  fi
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
  diag|svc-status|disk|gc)
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
  --skip PolishHelperIntegrationTests --skip SpeechHelperIntegrationTests
  --skip SpeechdStreamingBenchTests --skip AgentDictationE2EEvalTests)

# On-demand test server to warm before the suite runs (empty = none). The
# build host's speechd/polishd launchd test services are launch-on-demand to
# keep their weights out of RAM when idle; the lanes that hit them ask the gate
# to start and warm them first. See scripts/mac/lv-test-servers.sh + README.md.
ENSURE_SERVER=""

case "$CMD" in
  build)   REMOTE_CMD=(swift build "$@") ;;
  test)    REMOTE_CMD=(swift test "${UNIT_TEST_SKIPS[@]}" "$@") ;;
  integration)
    ENSURE_SERVER="speechd"
    REMOTE_CMD=(env VLLM_REALTIME_TEST_ENABLE=1
      VLLM_REALTIME_TEST_MODEL=T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead
      swift test --filter RealtimeAPIVLLMIntegrationTests "$@")
    ;;
  integration-polishd)
    # Same marker-through-the-tree pattern as eval-llm (the gate pins env
    # prefixes per-command). Requires a helper binary from a prior
    # `./scripts/remote-build.sh package` run — the remote PolishHelper/.build
    # tree survives rsync (excluded from --delete).
    # Optional arg: HF repo to hold to the eval baseline instead of the
    # default polishing model (the suite self-provisions missing weights into
    # the build user's HF cache) — the per-model gate for PolishModelCatalog
    # additions.
    if [[ $# -gt 1 ]]; then
      echo "integration-polishd accepts at most one argument (HF model repo)" >&2
      exit 1
    fi
    POLISHD_MODEL="${1:-}"
    POLISHD_MARKER="$ROOT_DIR/.polishd-integration-enable.json"
    trap 'cleanup_transient_marker "$POLISHD_MARKER"' EXIT
    if [[ -n "$POLISHD_MODEL" ]]; then
      printf '{"helperPath": "%s", "model": "%s"}\n' \
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd" \
        "$POLISHD_MODEL" \
        >"$POLISHD_MARKER"
    else
      printf '{"helperPath": "%s"}\n' \
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd" \
        >"$POLISHD_MARKER"
    fi
    REMOTE_CMD=(swift test --filter PolishHelperIntegrationTests)
    ;;
  integration-speechd)
    # Enablement travels in the rsynced tree because the SSH gate cannot pass
    # arbitrary env prefixes. Requires the packaged binary and resources from
    # a prior `./scripts/remote-build.sh package` run; dist survives rsync.
    if [[ $# -gt 1 ]]; then
      echo "integration-speechd accepts at most one argument (HF model repo)" >&2
      exit 1
    fi
    SPEECHD_MODEL="${1:-}"
    SPEECHD_MARKER="$ROOT_DIR/.speechd-integration-enable.json"
    trap 'cleanup_transient_marker "$SPEECHD_MARKER"' EXIT
    if [[ -n "$SPEECHD_MODEL" ]]; then
      printf '{"helperPath": "%s", "model": "%s"}\n' \
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd" \
        "$SPEECHD_MODEL" \
        >"$SPEECHD_MARKER"
    else
      printf '{"helperPath": "%s"}\n' \
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd" \
        >"$SPEECHD_MARKER"
    fi
    REMOTE_CMD=(swift test --filter SpeechHelperIntegrationTests)
    ;;
  speechd-bench)
    # The SSH gate does not allow arbitrary packaged-binary execution. A marker-gated
    # root XCTest launches the xcodebuild-produced helper and relays its BENCH output.
    if [[ $# -gt 3 ]]; then
      echo "speechd-bench accepts optional seconds, cadence-ms, and cache-limit-mb arguments" >&2
      exit 1
    fi
    SPEECHD_BENCH_SECONDS="${1:-60}"
    SPEECHD_BENCH_CADENCE="${2:-100}"
    SPEECHD_BENCH_CACHE_MB="${3:-}"
    if [[ ! "$SPEECHD_BENCH_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
      echo "speechd-bench seconds must be a positive integer" >&2
      exit 1
    fi
    if [[ ! "$SPEECHD_BENCH_CADENCE" =~ ^[1-9][0-9]*$ ]]; then
      echo "speechd-bench cadence-ms must be a positive integer" >&2
      exit 1
    fi
    if [[ -n "$SPEECHD_BENCH_CACHE_MB" && ! "$SPEECHD_BENCH_CACHE_MB" =~ ^[1-9][0-9]*$ ]]; then
      echo "speechd-bench cache-limit-mb must be a positive integer" >&2
      exit 1
    fi
    SPEECHD_BENCH_MARKER="$ROOT_DIR/.speechd-bench-enable.json"
    trap 'cleanup_transient_marker "$SPEECHD_BENCH_MARKER"' EXIT
    if [[ -n "$SPEECHD_BENCH_CACHE_MB" ]]; then
      printf '{"helperPath":"%s","seconds":%s,"cadenceMilliseconds":%s,"cacheLimitMB":%s}\n' \
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd" \
        "$SPEECHD_BENCH_SECONDS" \
        "$SPEECHD_BENCH_CADENCE" \
        "$SPEECHD_BENCH_CACHE_MB" \
        >"$SPEECHD_BENCH_MARKER"
    else
      printf '{"helperPath":"%s","seconds":%s,"cadenceMilliseconds":%s}\n' \
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd" \
        "$SPEECHD_BENCH_SECONDS" \
        "$SPEECHD_BENCH_CADENCE" \
        >"$SPEECHD_BENCH_MARKER"
    fi
    REMOTE_CMD=(swift test --filter SpeechdStreamingBenchTests)
    ;;
  eval-e2e)
    # Agent-dictation end-to-end eval (nightly + manual, never tier 0):
    # human WAVs (when supplied) or TTS -> live speechd ASR -> bundled polishd
    # helper through the production stop-commit path, scored against
    # EvalCorpus/agent-dictation. Requires a helper binary from a prior
    # `./scripts/remote-build.sh package` run.
    # Marker-through-the-tree, same as eval-llm/integration-polishd (the gate
    # pins env prefixes per-command). Expect many minutes: ~150 TTS+ASR cases
    # plus live 4B polish inference (synthesized WAVs are cached on the host
    # under ~/Library/Caches/localvoxtral-eval/wav, so reruns skip TTS).
    if [[ $# -gt 1 ]]; then
      echo "eval-e2e accepts at most one argument (recording-set directory)" >&2
      exit 1
    fi
    E2E_RECORDING_DIR="${1:-}"
    if [[ -n "$E2E_RECORDING_DIR" ]]; then
      # Keep the marker JSON trivially safe and make operator mistakes fail
      # before waking/model-loading the Mac. Human mode is strict: the Swift
      # harness validates completeness, corpus binding, WAV format, and hashes.
      if [[ ! "$E2E_RECORDING_DIR" =~ ^EvalRecordings/agent-dictation/[A-Za-z0-9._-]+$ ]]; then
        echo "eval-e2e recording directory must be EvalRecordings/agent-dictation/<set>" >&2
        exit 1
      fi
      if [[ ! -f "$ROOT_DIR/$E2E_RECORDING_DIR/manifest.json" ]]; then
        echo "recording manifest not found: $E2E_RECORDING_DIR/manifest.json" >&2
        echo "Create or resume it with: ./scripts/record-agent-eval.sh" >&2
        exit 1
      fi
    fi
    ENSURE_SERVER="speechd"
    E2E_MARKER="$ROOT_DIR/.agent-eval-e2e-enable.json"
    # Trap registered before the marker exists, so no kill window leaves a
    # stale marker behind (locally or in the remote work dir).
    trap 'cleanup_transient_marker "$E2E_MARKER"' EXIT
    if [[ -n "$E2E_RECORDING_DIR" ]]; then
      printf '{"helperPath": "%s", "asrModel": "%s", "recordingDirectory": "%s"}\n' \
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd" \
        "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead" \
        "$E2E_RECORDING_DIR" \
        >"$E2E_MARKER"
    else
      printf '{"helperPath": "%s", "asrModel": "%s"}\n' \
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd" \
        "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead" \
        >"$E2E_MARKER"
    fi
    REMOTE_CMD=(swift test --filter AgentDictationE2EEvalTests)
    ;;
  eval-llm)
    # Enablement travels as a gitignored marker file inside the synced tree
    # (removed again on exit): the build gate only allowlists exact
    # `swift test ...` payloads, so env prefixes can't be passed per-run.
    if [[ $# -gt 2 ]]; then
      echo "eval-llm accepts an optional chat/completions endpoint and model alias" >&2
      exit 1
    fi
    EVAL_ENDPOINT="${1:-http://127.0.0.1:8080/v1/chat/completions}"
    EVAL_MODEL="${2:-}"
    # Only warm the local on-demand polishd service when the eval targets it; a
    # custom endpoint is the caller's own server and we must not touch it.
    if [[ "$EVAL_ENDPOINT" == *"127.0.0.1:8080"* || "$EVAL_ENDPOINT" == *"localhost:8080"* ]]; then
      ENSURE_SERVER="polishd"
    fi
    EVAL_MARKER="$ROOT_DIR/.llm-polish-eval-enable.json"
    # Trap registered before the marker exists, so no kill window leaves a
    # stale marker behind (locally or in the remote work dir).
    trap 'cleanup_transient_marker "$EVAL_MARKER"' EXIT
    if [[ "$EVAL_MODEL" == llamacpp/* ]]; then
      # Bifrost requires the passthrough opt-in for llama.cpp-specific fields;
      # current llama.cpp disables Qwen 3.5 reasoning per request with a zero
      # thinking budget. Keep the production catalog's enable_thinking=false
      # kwargs too, so this remains the same prompt/sampling request shape.
      printf '{"endpoint": "%s", "model": "%s", "useDefaultRequestShape": true, "thinkingBudgetTokens": 0, "passthroughExtraParameters": true}\n' \
        "$EVAL_ENDPOINT" "$EVAL_MODEL" >"$EVAL_MARKER"
    elif [[ -n "$EVAL_MODEL" ]]; then
      printf '{"endpoint": "%s", "model": "%s", "useDefaultRequestShape": true}\n' \
        "$EVAL_ENDPOINT" "$EVAL_MODEL" >"$EVAL_MARKER"
    else
      printf '{"endpoint": "%s"}\n' "$EVAL_ENDPOINT" >"$EVAL_MARKER"
    fi
    REMOTE_CMD=(swift test --filter LLMPolishPromptEvalTests)
    ;;
  dogfood|dogfood-package)
    # The dogfooding capture is a COMPILE gate (Package.swift), and the build
    # gate allowlists exact payloads, so enablement travels as the same kind of
    # gitignored marker the eval lanes use rather than an env prefix.
    #
    # `dogfood`         — build + run the capture suite in an instrumented tree.
    # `dogfood-package` — package an instrumented .app for hand-dogfooding.
    #                     The bundle identifier is unchanged (the TCC grant is
    #                     part of what is being exercised); the artifact
    #                     identifies itself through Info.plist's
    #                     LVXDogfoodCapture, which Settings > About reports.
    DOGFOOD_MARKER="$ROOT_DIR/.dogfood-capture-enable"
    # Registered before the marker exists, so no kill window can leave an
    # instrumented tree behind — locally or in the remote work dir.
    trap 'cleanup_transient_marker "$DOGFOOD_MARKER"' EXIT
    printf 'dogfood capture build marker; removed automatically\n' >"$DOGFOOD_MARKER"
    if [[ "$CMD" == "dogfood-package" ]]; then
      REMOTE_CMD=(./scripts/package_app.sh release "$@")
    else
      REMOTE_CMD=(swift test --filter Dogfood "$@")
    fi
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
    echo "Usage: $0 [build|test|integration|integration-polishd|integration-speechd|speechd-bench|eval-llm|eval-e2e|dogfood|dogfood-package|package|exec|diag|applog|voxlog|svc-status] [extra args...]" >&2
    exit 1
    ;;
esac

if [[ -n "$ENSURE_SERVER" ]]; then
  ensure_remote_server "$ENSURE_SERVER"
fi

echo "==> Syncing working tree to $HOST:$DIR"
ssh "$HOST" "mkdir -p $(printf '%q' "$DIR")"
# .build/ and dist/ are excluded from deletion too, so the remote incremental
# build state survives between runs. EvalRecordings is receiver-protected:
# private human WAVs may live only on the Mac and must survive a Linux sync.
# .lv-last-used is the gate's per-use staleness stamp (never in the source
# tree) — without the protect, --delete would strip it and the gc verb's age
# decision would fall back to rsync-preserved (old) source mtimes.
rsync -az --delete \
  --filter='P /.lv-last-used' \
  --filter='P EvalRecordings/***' \
  --exclude '.git/' --exclude '.build/' --exclude 'dist/' \
  "$ROOT_DIR/" "$HOST:$DIR/"
# From here on the marker (if any) exists remotely too; the EXIT trap's
# cleanup rsync now has something to delete.
TREE_SYNCED=1

PAYLOAD_STATUS=0
run_remote_payload "cd $(printf '%q' "$DIR") && $(printf '%q ' "${REMOTE_CMD[@]}")" \
  || PAYLOAD_STATUS=$?

# Opportunistic remote work-dir GC (gate v4 `gc` verb): reclaim stale sibling
# dirs while the host is known awake — the disk only fills when agents build,
# which is exactly when this fires. Backgrounded and best-effort: it must
# never delay the inner loop or fail the run, and a pre-v4 gate just denies
# the verb. Output lands in .build/last-gc.log for the curious.
GC_LOG="${LOCALVOXTRAL_GC_LOG:-$ROOT_DIR/.build/last-gc.log}"
(
  mkdir -p "$(dirname "$GC_LOG")" 2>/dev/null || true
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" gc >"$GC_LOG" 2>&1 || true
) &

exit "$PAYLOAD_STATUS"
