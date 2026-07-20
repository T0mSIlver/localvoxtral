#!/usr/bin/env bash
# Mac-side runner for the PRIVATE term-recall ASR-corruption miner.
# Warms voxmlx through the on-demand gate (same best-effort pattern as
# run-agent-eval-local.sh), then runs the Swift miner. See the header of
# scripts/mine-term-recall-asr.swift for inputs/outputs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Best-effort warmup: the miner still fails loudly per-case if voxmlx is
# unavailable, so missing on-demand infrastructure is not masked.
if ! "$ROOT_DIR/scripts/mac/lv-test-servers.sh" ensure voxmlx; then
  echo "WARN: could not warm voxmlx on demand; continuing to the miner" >&2
fi

cd "$ROOT_DIR"
exec xcrun swift "$ROOT_DIR/scripts/mine-term-recall-asr.swift" "$@"
