#!/usr/bin/env bash
# THROWAWAY SPIKE runner — executes ON the Mac build host (self-hosted CI).
#
# Builds the Voxtral streaming spike with xcodebuild (SwiftPM CLI cannot compile
# mlx-swift's Metal kernels — see AGENTS.md) and runs it against `say`-synthesized
# audio, reusing the exact phrase and scoring approach of the tier-1 integration test.
#
# Usage: run-spike.sh [build|run|all]   (default: all)
set -euo pipefail

PHASE="${1:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPIKE_DIR="$ROOT_DIR/spikes/VoxtralSpike"
OUT_DIR="$ROOT_DIR/spikes/out"
DERIVED="$SPIKE_DIR/.build/xcode"
BIN="$DERIVED/Build/Products/Release/voxtral-spike"
MODEL_REPO="${MODEL_REPO:-mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit}"

mkdir -p "$OUT_DIR"

# The tier-1 phrase, verbatim (Tests/.../RealtimeAPIVLLMIntegrationTests.swift:226).
EN="hello from localvoxtral realtime test. this is a longer synthetic audio passage for integration testing. we are verifying that the vllm realtime server performs generation and returns transcript text. the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks. if this transcript is non empty, end to end processing is confirmed."
# Accented French: the trigger for the suspected multi-byte-UTF-8 re-emit bug.
FR="le café était très élégant et la crème brûlée façonnée à Noël. nous répétons: éàçùôî, garçon, français."

do_build() {
  if ! xcrun metal --version >/dev/null 2>&1; then
    echo "Metal toolchain missing: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi

  mkdir -p "$SPIKE_DIR/.build"
  local log="$SPIKE_DIR/.build/xcodebuild.log"
  echo "==> xcodebuild (cold builds compile mlx-swift's C++/Metal core; log: $log)"

  # Heartbeat: xcodebuild is quiet for a long time on a cold MLX build, and a silent
  # step that later times out leaves NO log to diagnose (runs 3 and 4).
  ( while true; do sleep 60; echo "    … still building ($(date +%H:%M:%S))"; done ) &
  local hb=$!
  trap 'kill '"$hb"' 2>/dev/null || true' EXIT

  local rc=0
  ( cd "$SPIKE_DIR"
    xcodebuild \
      -scheme VoxtralSpike \
      -destination 'platform=macOS,arch=arm64' \
      -configuration Release \
      -derivedDataPath "$DERIVED" \
      build > "$log" 2>&1
  ) || rc=$?
  kill "$hb" 2>/dev/null || true

  if (( rc != 0 )); then
    echo "xcodebuild FAILED (rc=$rc); last 40 lines:"
    tail -40 "$log"
    exit "$rc"
  fi
  [[ -x "$BIN" ]] || { echo "no binary at $BIN"; tail -40 "$log"; exit 1; }
  echo "==> build ok: $BIN"
}

do_run() {
  printf '%s' "$EN" > "$OUT_DIR/en.txt"
  printf '%s' "$FR" > "$OUT_DIR/fr.txt"

  # Arg shape copied verbatim from the tier-1 test (makeSpokenPCM16Data): the phrase
  # is a positional arg — `--file` makes `say` fail with "Opening output file failed".
  echo "==> Synthesizing audio with /usr/bin/say"
  say -o "$OUT_DIR/en.wav" --file-format=WAVE --data-format=LEI16@16000 "$EN"
  say -v Thomas -o "$OUT_DIR/fr.wav" --file-format=WAVE --data-format=LEI16@16000 "$FR" \
    || say -o "$OUT_DIR/fr.wav" --file-format=WAVE --data-format=LEI16@16000 "$FR"

  [[ -x "$BIN" ]] || { echo "spike binary missing — run the build phase first"; exit 1; }

  # Warm the on-demand Python voxmlx (port 8000) so the SAME binary can measure it as a
  # baseline: same audio, same chunking, same clock, same GPU contention. Without this
  # the Swift RTF is unjudgeable — the owner's app may be holding two 4B models resident.
  WS_ARGS=()
  if [[ -d /Users/Shared/localvoxtral/run ]] && ./scripts/mac/lv-test-servers.sh ensure voxmlx; then
    WS_ARGS=(--ws "ws://127.0.0.1:8000/v1/realtime")
    echo "==> Python voxmlx baseline enabled (port 8000)"
  else
    echo "==> WARNING: no on-demand voxmlx — Swift RTF will have no baseline to compare against"
  fi

  # Chunk sweep FIRST: the engine pays its fixed per-step cost once per chunk (and
  # recomputes the conv stem over all audio each step), so RTF should fall as chunks
  # grow. If a realistic chunk size already lands under RTF 1.0, no engine surgery
  # is needed. The Python baseline rides along at the first chunk size.
  echo "==> EN: chunk sweep, model $MODEL_REPO"
  "$BIN" --repo "$MODEL_REPO" --wav "$OUT_DIR/en.wav" --expected "$OUT_DIR/en.txt" \
    --chunks "80,160,240,480,960" --delays "default" --label en-chunks "${WS_ARGS[@]}" \
    | tee "$OUT_DIR/en-chunks.json"

  echo "==> EN: delay sweep at 80 ms chunks"
  "$BIN" --repo "$MODEL_REPO" --wav "$OUT_DIR/en.wav" --expected "$OUT_DIR/en.txt" \
    --chunks "80" --delays "default,480,240,160,80" --label en-delays \
    | tee "$OUT_DIR/en-delays.json"

  echo "==> FR: accented text (delta-integrity smoke)"
  "$BIN" --repo "$MODEL_REPO" --wav "$OUT_DIR/fr.wav" --expected "$OUT_DIR/fr.txt" \
    --chunks "80,480" --delays "default" --label fr \
    | tee "$OUT_DIR/fr.json"

  echo "==> done"
}

case "$PHASE" in
  build) do_build ;;
  run)   do_run ;;
  all)   do_build; do_run ;;
  *) echo "usage: $0 [build|run|all]" >&2; exit 2 ;;
esac
