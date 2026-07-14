#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec xcrun swift "$ROOT_DIR/scripts/render-agent-eval-report.swift" "$@"
