#!/usr/bin/env bash
# THROWAWAY SPIKE runner — executes ON the Mac build host (via remote-build.sh exec).
#
# Builds the Voxtral streaming spike with xcodebuild (SwiftPM CLI cannot compile
# mlx-swift's Metal kernels — see AGENTS.md) and runs it against `say`-synthesized
# audio, reusing the exact phrase and scoring approach of the tier-1 integration test.
set -euo pipefail

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

printf '%s' "$EN" > "$OUT_DIR/en.txt"
printf '%s' "$FR" > "$OUT_DIR/fr.txt"

# Arg shape copied verbatim from the tier-1 test (makeSpokenPCM16Data): the phrase
# is a positional arg — `--file` makes `say` fail with "Opening output file failed".
echo "==> Synthesizing audio with /usr/bin/say"
say -o "$OUT_DIR/en.wav" --file-format=WAVE --data-format=LEI16@16000 "$EN"
say -v Thomas -o "$OUT_DIR/fr.wav" --file-format=WAVE --data-format=LEI16@16000 "$FR" \
  || say -o "$OUT_DIR/fr.wav" --file-format=WAVE --data-format=LEI16@16000 "$FR"

if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal toolchain missing: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

echo "==> Building spike (xcodebuild; log: $SPIKE_DIR/.build/xcodebuild.log)"
mkdir -p "$SPIKE_DIR/.build"
(
  cd "$SPIKE_DIR"
  xcodebuild \
    -scheme VoxtralSpike \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build > "$SPIKE_DIR/.build/xcodebuild.log" 2>&1
) || { echo "xcodebuild FAILED; last 40 lines:"; tail -40 "$SPIKE_DIR/.build/xcodebuild.log"; exit 1; }

[[ -x "$BIN" ]] || { echo "no binary at $BIN"; tail -40 "$SPIKE_DIR/.build/xcodebuild.log"; exit 1; }

echo "==> EN: delay sweep (chunk 80 ms)"
"$BIN" --repo "$MODEL_REPO" --wav "$OUT_DIR/en.wav" --expected "$OUT_DIR/en.txt" \
  --chunk-ms 80 --delays "default,480,240,160,80" --label en \
  | tee "$OUT_DIR/en.json"

echo "==> FR: accented text (delta-integrity smoke)"
"$BIN" --repo "$MODEL_REPO" --wav "$OUT_DIR/fr.wav" --expected "$OUT_DIR/fr.txt" \
  --chunk-ms 80 --delays "default" --label fr \
  | tee "$OUT_DIR/fr.json"

echo "==> done"
