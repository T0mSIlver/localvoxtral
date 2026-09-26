#!/usr/bin/env bash
# voxtral-vllm.sh: Voxtral Realtime on vLLM, on demand, on a Linux box with an
# NVIDIA GPU. It serves ws://127.0.0.1:$PORT/v1/realtime for the ASR evals, so
# heavy speech inference stays off the Mac. It is not the shipped engine: the
# app runs the 4-bit MLX conversion through localvoxtral-speechd (see
# scripts/linux/README.md for how far the two differ).
#
#   voxtral-vllm.sh install   create the venv and download the pinned weights
#   voxtral-vllm.sh up        start if down, block until healthy, reset idle
#   voxtral-vllm.sh down      stop now
#   voxtral-vllm.sh status    state, port, idle time, GPU memory
#   voxtral-vllm.sh logs [-f] server log
#
# `up` also starts an idle reaper that stops the server after IDLE_SECONDS
# without a token generated or an `up`, then exits. Nothing runs when idle.
set -euo pipefail

VLLM_HOME="${VOXTRAL_VLLM_HOME:-$HOME/work/voxtral-vllm}"
PORT="${VOXTRAL_VLLM_PORT:-8000}"
IDLE_SECONDS="${VOXTRAL_VLLM_IDLE_SECONDS:-600}"
# 2048 tokens is 164 s of audio per take (one token per 80 ms), enough for
# every eval case. A longer take ends its generation at the limit and the
# next one starts mid-word (#516), so raise it for long-form benches; the KV
# cache must grow with it (4096 needs about 4.6 GB).
MAX_MODEL_LEN="${VOXTRAL_VLLM_MAX_MODEL_LEN:-2048}"
KV_CACHE_BYTES="${VOXTRAL_VLLM_KV_CACHE_BYTES:-2600M}"
# The GPU is shared with processes whose use moves by several GB, so the
# footprint is fixed (weights 8.4 GB + KV cache + activations, about 11.8 GB)
# rather than a share of the card. `up` refuses below this much free memory.
NEED_FREE_MIB="${VOXTRAL_VLLM_NEED_FREE_MIB:-12500}"
# 1 = torch.compile + piecewise CUDA graphs: about 7% faster decode, 2.5 s
# slower start. Eager is the default because eval runs are short.
COMPILE="${VOXTRAL_VLLM_COMPILE:-0}"

MODEL="mistralai/Voxtral-Mini-4B-Realtime-2602"
MODEL_REVISION="2769294da9567371363522aac9bbcfdd19447add"
MODEL_FILES=(consolidated.safetensors params.json tekken.json config.json generation_config.json processor_config.json)
# The PyPI vllm wheel pulls CUDA 13 torch, which needs driver 580+. The cu129
# build runs on driver 550 (CUDA 12.4) through CUDA minor-version compatibility.
VLLM_WHEEL="https://github.com/vllm-project/vllm/releases/download/v0.30.0/vllm-0.30.0+cu129-cp38-abi3-manylinux_2_28_x86_64.whl"
TORCH_BACKEND="cu129"

VENV="$VLLM_HOME/.venv"
RUN_DIR="$VLLM_HOME/run"
PID_FILE="$RUN_DIR/server.pid"
REAPER_PID_FILE="$RUN_DIR/reaper.pid"
STAMP="$RUN_DIR/last-up"
LOG="$RUN_DIR/server.log"
HEALTH_URL="http://127.0.0.1:$PORT/health"
UP_TIMEOUT_SECONDS=240

die() { echo "voxtral-vllm: $*" >&2; exit 1; }

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

healthy() { curl -sf -o /dev/null --max-time 2 "$HEALTH_URL"; }

snapshot_dir() {
  echo "${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}/snapshots/$MODEL_REVISION"
}

gpu_free_mib() {
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' '
}

cmd_install() {
  command -v uv >/dev/null || die "uv is not on PATH"
  mkdir -p "$VLLM_HOME"
  [[ -x "$VENV/bin/python" ]] || uv venv -p 3.12 "$VENV"
  uv pip install -p "$VENV/bin/python" --torch-backend="$TORCH_BACKEND" "vllm[audio] @ $VLLM_WHEEL"
  uv pip install -p "$VENV/bin/python" huggingface_hub websockets
  "$VENV/bin/hf" download "$MODEL" --revision "$MODEL_REVISION" "${MODEL_FILES[@]}"
  echo "installed: $VENV, weights in $(snapshot_dir)"
}

serve_args() {
  local args=(serve "$MODEL" --revision "$MODEL_REVISION"
    --host 127.0.0.1 --port "$PORT"
    --max-model-len "$MAX_MODEL_LEN" --max-num-seqs 8
    # vLLM checks free memory against the utilization share before it reads
    # the fixed KV size, so keep the share below what the fixed size needs.
    --gpu-memory-utilization 0.3 --kv-cache-memory-bytes "$KV_CACHE_BYTES")
  if [[ "$COMPILE" == 1 ]]; then
    args+=(--compilation_config '{"cudagraph_mode": "PIECEWISE"}')
  else
    args+=(--enforce-eager)
  fi
  printf '%s\n' "${args[@]}"
}

start_server() {
  [[ -x "$VENV/bin/vllm" ]] || die "no vLLM in $VENV; run: $0 install"
  [[ -f "$(snapshot_dir)/consolidated.safetensors" ]] || die "weights missing; run: $0 install"
  local free
  free="$(gpu_free_mib)"
  ((free >= NEED_FREE_MIB)) \
    || die "only ${free} MiB free on the GPU, need ${NEED_FREE_MIB}; another process holds the rest (nvidia-smi)"

  local args
  mapfile -t args < <(serve_args)
  # FlashInfer's sampler JIT-compiles with nvcc, which this box does not have.
  # setsid: the server leads its own process group, so `down` stops the
  # engine core with it.
  HF_HUB_OFFLINE=1 VLLM_USE_FLASHINFER_SAMPLER=0 \
    setsid "$VENV/bin/vllm" "${args[@]}" >"$LOG" 2>&1 </dev/null 9>&- &
  echo $! >"$PID_FILE"
}

start_reaper() {
  alive "$REAPER_PID_FILE" && return
  setsid "$0" _reap >>"$RUN_DIR/reaper.log" 2>&1 </dev/null 9>&- &
  echo $! >"$REAPER_PID_FILE"
}

# Every lifecycle change runs under this lock on fd 9, so up, down and the
# reaper never act on a half-started or half-stopped server.
take_lock() {
  mkdir -p "$RUN_DIR"
  exec 9>"$RUN_DIR/up.lock"
  flock 9
}

cmd_up() {
  take_lock
  touch "$STAMP"
  local started=$SECONDS
  if ! alive "$PID_FILE"; then
    healthy && die "port $PORT answers but no server of ours runs; stop that one first"
    start_server
  fi
  # Before the health wait: an up interrupted during startup still leaves a
  # reaper to stop the server.
  start_reaper
  until healthy; do
    if ! alive "$PID_FILE"; then
      tail -n 30 "$LOG" >&2
      die "server exited during startup; full log: $LOG"
    fi
    if ((SECONDS - started > UP_TIMEOUT_SECONDS)); then
      stop_server >/dev/null
      die "not healthy after ${UP_TIMEOUT_SECONDS}s, stopped it; log: $LOG"
    fi
    sleep 0.5
  done
  ((SECONDS > started)) && echo "healthy after $((SECONDS - started))s"
  echo "ready: ws://127.0.0.1:$PORT/v1/realtime model=$MODEL (idle stop after ${IDLE_SECONDS}s)"
}

cmd_down() {
  take_lock
  stop_server
}

stop_server() {
  if alive "$PID_FILE"; then
    local pid
    pid="$(cat "$PID_FILE")"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
    for _ in $(seq 1 60); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pid" 2>/dev/null
    echo "stopped pid $pid"
  else
    echo "not running"
  fi
  rm -f "$PID_FILE"
}

# Sum of the token counters plus running requests: it moves whenever a
# realtime session decodes. Realtime sessions never reach request_success_total.
# Fails when the scrape fails, so a flapping endpoint never counts as activity.
activity_counter() {
  local metrics
  metrics="$(curl -sf --max-time 5 "http://127.0.0.1:$PORT/metrics")" || return 1
  awk '/^vllm:(prompt_tokens_total|generation_tokens_total|num_requests_running)\{/ { s += $NF } END { printf "%d", s }' <<<"$metrics"
}

# Seconds since the later of the last decode and the last `up`.
idle_for() {
  local stamp latest=$last_active
  stamp="$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
  ((stamp > latest)) && latest=$stamp
  echo $(($(date +%s) - latest))
}

cmd_reap() {
  local last_counter="" last_active counter idle
  last_active="$(date +%s)"
  while alive "$PID_FILE"; do
    if counter="$(activity_counter)" && [[ "$counter" != "$last_counter" ]]; then
      last_counter="$counter"
      last_active="$(date +%s)"
    fi
    if (($(idle_for) >= IDLE_SECONDS)); then
      # Decide again under the lock: an up may have just reset the clock.
      take_lock
      idle="$(idle_for)"
      if ((idle >= IDLE_SECONDS)); then
        echo "$(date -Is) idle for ${idle}s, stopping"
        stop_server
        break
      fi
      exec 9>&-
    fi
    sleep 30
  done
  rm -f "$REAPER_PID_FILE"
}

cmd_status() {
  if alive "$PID_FILE"; then
    local pid state=starting
    pid="$(cat "$PID_FILE")"
    healthy && state=healthy
    echo "server: $state, pid $pid, up $(ps -o etime= -p "$pid" | tr -d ' ')"
    echo "endpoint: ws://127.0.0.1:$PORT/v1/realtime model=$MODEL"
    echo "last up: $(($(date +%s) - $(stat -c %Y "$STAMP"))) s ago; idle stop after ${IDLE_SECONDS}s of no decoding"
    alive "$REAPER_PID_FILE" || echo "reaper: NOT running (run up again)"
  else
    echo "server: down"
  fi
  nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader | sed 's/^/gpu used, free: /'
  echo "log: $LOG"
}

cmd_logs() {
  [[ -f "$LOG" ]] || die "no log yet at $LOG"
  if [[ "${1:-}" == -f ]]; then tail -n 50 -f "$LOG"; else tail -n 100 "$LOG"; fi
}

case "${1:-}" in
  install) cmd_install ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  _reap) cmd_reap ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
